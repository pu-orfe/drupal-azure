# Operations runbook

**Read this when you are running the thing.** Day-two tasks: logs, rollbacks,
restores, drush, secrets, scaling.

**If something is broken right now**, start at
**[Troubleshooting](troubleshooting.md)** instead — it is organised by symptom.

## Before you start

Everything here assumes `az login` and, unless stated, that these are exported:

```bash
export AZURE_RESOURCE_GROUP=rg-drupal-prod
export AZURE_PLATFORM=appservice      # or containerapps; detected if unset
export AZURE_APP_NAME=app-drupal-abc  # detected if unset
```

Every script reads them from the environment and prompts only when they are
absent, so setting them once makes the whole toolkit non-interactive — and the
same scripts run unchanged in CI.

`scripts/lib/platform.sh` detects the platform from what is actually in the
resource group when `AZURE_PLATFORM` is unset, and **refuses to guess** if it
finds both a web app and a container app. Where a command differs by platform it
is marked below; where it is not marked, it is the same.

---

## Reading logs

```bash
./scripts/azure-logs.sh                # follow
./scripts/azure-logs.sh --tail 200 --no-follow
```

**App Service** also keeps the container's recent output where Kudu can read it,
which is often faster than either the stream or a Log Analytics query:

```bash
./scripts/kudu.sh ls  /home/LogFiles
./scripts/kudu.sh cat /home/LogFiles/<name>_docker.log | tail -100
```

The container's stdout is the entrypoint's boot narration plus nginx and php-fpm
output — everything is deliberately routed to stdout/stderr rather than to files
inside the replica, because a replica's filesystem does not survive it.

For a revision that has already gone away, or to search across time, the logs are
in Log Analytics:

```bash
WS=$(az monitor log-analytics workspace list -g "$AZURE_RESOURCE_GROUP" --query '[0].customerId' -o tsv)
az monitor log-analytics query --workspace "$WS" --analytics-query "
  ContainerAppConsoleLogs_CL
  | where ContainerAppName_s == 'app-drupal'
  | where TimeGenerated > ago(2h)
  | where Log_s contains 'entrypoint'
  | project TimeGenerated, RevisionName_s, Log_s
  | order by TimeGenerated asc
" -o table
```

Filtering on `entrypoint` gives the boot sequence for every replica start: what
the deploy marker said, whether the lock was taken, what `updb` did.

---

## What is running

```bash
./scripts/rollback.sh --current    # live revision and its image
./scripts/rollback.sh --list       # all revisions, traffic weights, states
```

The deployed schema version, as the entrypoint recorded it:

```bash
./scripts/drush.sh sql:query "SELECT deployed_version, deployed_at FROM azure_deploy_state WHERE id = 1"
```

And what the last boot actually did — per-step exit codes, and a fingerprint of
each secret the container is holding:

```bash
# App Service
./scripts/kudu.sh cat /home/boot-result.json | python3 -m json.tool

# Container Apps: on the private share, one file per replica
az storage file list --account-name "$STORAGE" --account-key "$KEY" \
  --share-name drupal-private --path . -o table
```

```jsonc
{
  "status": "degraded",           // ok | degraded | failed
  "container_version": "a1b2c3d4e5f6",
  "critical_failed": false,
  "hash_salt_fingerprint": "9f2c…",   // NOT the secret — see below
  "db_password_fingerprint": "41ae…",
  "steps": { "pre_deploy_backup": 0, "updb": 0, "config_import": 3, "cache_rebuild": 0 }
}
```

`status: degraded` with `critical_failed: false` means something failed that does
not force a retry. Read `steps` to see what — that is the whole reason the file
exists, because a log line saying "warning: config import failed" and one saying
nothing look identical when you are scrolling.

The **fingerprints** answer a question the platform will not: not "was the secret
rotated" but "is the value *this container holds* the new one". App Service caches
resolved Key Vault references and reports "Resolved" either way. Compare the
fingerprint before and after a rotation; if it did not change, the container is
still on the old value. See [secrets.md](secrets.md).

If `deployed_version` does not match the image the live revision is running, the
last deploy's schema work did not complete. Check that revision's logs before
doing anything else.

---

## Rolling back

```bash
./scripts/rollback.sh --list
./scripts/rollback.sh --previous
./scripts/rollback.sh --to <revision-or-tag> --yes
```

| | What happens | Cost |
|---|---|---|
| Container Apps | Traffic weight moves to a revision already running | Seconds. No pull, no restart |
| App Service | The app is repointed at a previous image tag and restarted | An image pull plus a container start — on B1 that is the site's downtime |

Neither needs a rebuild: on Container Apps the deploy workflow keeps the last
three revisions active rather than letting Azure retire them, and on App Service
the previous tag is still in the registry. `--list` shows what is available.

App Service note: `--previous` skips the `latest` tag deliberately. Rolling back
"to latest" is meaningless — `latest` is what the broken deploy just moved.

**What rolls back:** application code, and exported configuration — the older
image carries the older `config/sync`, and because its `CONTAINER_VERSION`
differs from the recorded marker its entrypoint re-runs `config:import`. So a
config change is undone, including re-enabling a module the newer revision
uninstalled.

**What does not:** anything `drush updb` did. Schema updates are
one-directional. Uninstalling a module that owns an entity type *drops its
tables*; re-enabling gives you the schema back, empty.

For a deploy that carried a destructive change, the recovery path is a database
restore — next section.

---

## Restoring the database

Three sources, in increasing order of effort and decreasing order of recency.

### 1. The pre-deploy dump the entrypoint took

Timestamped, one per deploy that ran schema work, and **validated before it was
published** — checked for a size floor, gzip integrity and a `-- Dump completed`
trailer, so a truncated or stub dump was never written over the previous good one.
A rejected attempt is kept as `*.rejected`, which no restore path reads.

**App Service** — on `/home`, so Kudu can fetch it directly:

```bash
./scripts/kudu.sh ls  /home/deploy-backups
./scripts/kudu.sh get /home/deploy-backups/pre-deploy-20260822T031500Z-abc123.sql.gz ./restore.sql.gz
```

**Container Apps** — on the private Azure Files share:

```bash
STORAGE=$(az storage account list -g "$AZURE_RESOURCE_GROUP" --query '[0].name' -o tsv)
KEY=$(az storage account keys list --account-name "$STORAGE" --query '[0].value' -o tsv)

az storage file list --account-name "$STORAGE" --account-key "$KEY" \
  --share-name drupal-private --path .deploy-backups -o table

az storage file download --account-name "$STORAGE" --account-key "$KEY" \
  --share-name drupal-private \
  --path .deploy-backups/pre-deploy-20260822T031500Z-abc123def456.sql.gz \
  --dest ./restore.sql.gz
```

> The storage account is default-deny and scoped to the app subnet, so these
> commands need `--bypass AzureServices` to already be in effect (it is) *and* a
> caller Azure trusts. From a workstation outside the VNet, add your address
> temporarily:
> ```bash
> az storage account network-rule add --account-name "$STORAGE" \
>   -g "$AZURE_RESOURCE_GROUP" --ip-address "$(curl -s ifconfig.me)"
> # ... do the download ...
> az storage account network-rule remove --account-name "$STORAGE" \
>   -g "$AZURE_RESOURCE_GROUP" --ip-address "$(curl -s ifconfig.me)"
> ```
> Do not skip the removal.

Restoring runs inside the deployment, because the MySQL server has no public
endpoint:

```bash
# App Service
./scripts/kudu.sh run "gzip -dc /home/deploy-backups/<file>.sql.gz | vendor/bin/drush sql:cli"

# Container Apps
./scripts/drush.sh -- sql:query --file=/var/www/html/private/deploy-backups/<file>.sql
```

Before restoring over a working database, take a snapshot of what you are about to
replace. The entrypoint's own restore path does this automatically and refuses to
proceed if the snapshot fails — "proceeding anyway" would discard the only copy of
the current data on the way to overwriting it.

`DRUPAL_BACKUP_KEEP` (default 10) bounds how many are retained. They are
timestamped rather than a single overwritten slot on purpose: a change that lands
as two deploys would otherwise have its "before" snapshot destroyed by the second
deploy.

### 2. Point-in-time restore

Restores **into a new server**, to any second within the retention window
(7 days by default):

```bash
SERVER=$(az mysql flexible-server list -g "$AZURE_RESOURCE_GROUP" --query '[0].name' -o tsv)
az mysql flexible-server restore \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --name "${SERVER}-restored" \
  --source-server "$SERVER" \
  --restore-time "2026-08-22T03:10:00Z"
```

Then repoint the app at it by updating `DRUPAL_DB_HOST`. Keeping the destructive
database work and the switch that makes it live as two separate steps is the
point: you can verify the restored server before anything depends on it.

### 3. A logical dump from `azure-backup.sh`

On the private share under `.backups/`. The only one of the three that is
portable to another subscription or another host.

**A backup you have never restored is a hypothesis.** Rehearse it against a
staging environment.

### Restoring files as well

A database restored to yesterday against current file shares has broken every
managed-file reference in between. Restore both, from snapshots taken at the same
time:

```bash
az storage share list --account-name "$STORAGE" --account-key "$KEY" \
  --include-snapshots -o table

az storage file copy start-batch \
  --account-name "$STORAGE" --account-key "$KEY" \
  --source-share drupal-private --source-snapshot '2026-08-22T03:00:00.0000000Z' \
  --destination-share drupal-private
```

---

## Forcing the deploy sequence to run again

The entrypoint skips `updb`/`config:import`/`cache:rebuild` when the image's
version matches the recorded marker. To make the next replica start run them
anyway — after editing configuration by hand, say, or to recover from a partial
run:

```bash
# Clear the marker, then restart. The next boot sees a mismatch and runs.
./scripts/drush.sh sql:query "UPDATE azure_deploy_state SET deployed_version = '' WHERE id = 1"

# App Service
az webapp restart -n "$AZURE_APP_NAME" -g "$AZURE_RESOURCE_GROUP"

# Container Apps
LIVE=$(az containerapp revision list -n "$AZURE_APP_NAME" -g "$AZURE_RESOURCE_GROUP" \
  --query "[?properties.trafficWeight > \`0\`] | [0].name" -o tsv)
az containerapp revision restart -n "$AZURE_APP_NAME" -g "$AZURE_RESOURCE_GROUP" --revision "$LIVE"
```

Alternatively set `DRUPAL_FORCE_DEPLOY_TASKS=1` as an environment variable on the
app — but that creates a new revision *and* makes every subsequent replica start
run the sequence, so remember to remove it.

---

## Clearing a stuck deploy lock

Symptom: replicas log `Another replica holds the deploy lock; waiting…` and never
proceed, or a deploy sits at "waiting for the revision to become healthy".

```bash
./scripts/drush.sh sql:query "SELECT lock_owner, locked_at, deployed_version FROM azure_deploy_state WHERE id = 1"
```

The lock self-heals: any holder older than `DRUPAL_LOCK_STALE_SECONDS` (default
1800) can be taken over, which covers a replica evicted mid-run. Clear it early
only if you are confident nothing is still running schema updates — two
concurrent `updb` runs are precisely what the lock exists to prevent:

```bash
./scripts/drush.sh sql:query "UPDATE azure_deploy_state SET lock_owner = '', locked_at = NULL WHERE id = 1"
```

---

## Running drush

```bash
./scripts/drush.sh status
./scripts/drush.sh cache:rebuild
./scripts/drush.sh -- sql:query "SELECT COUNT(*) FROM node"
```

Either platform, and in both cases the script's exit code **is** drush's — which
is the point, and which neither platform gives you for free:

| | Mechanism |
|---|---|
| App Service | Kudu's `/api/command`, which returns the command's exit code in the response body. Authenticated by an Entra bearer token, so no open port and no stored credential, and the call is attributable |
| Container Apps | A manual-trigger Job: its own replica, the same image, the same secrets and mounts, an execution record and an exit code |

`--exec` (Container Apps only) attaches to a live replica instead. Fine for
looking around; unfit for anything that matters — no exit code a script can rely
on, it competes with live traffic for that replica's CPU, the command dies with
the websocket, and with `minReplicas: 0` there may be no replica to attach to.

**Never run `drush updb` by hand.** It belongs to the entrypoint, under the lock,
after a validated backup.

## Moving files in and out (App Service)

The database and the storage account both refuse the public internet, so anything
touching production data runs inside the deployment. Kudu is the transport:

```bash
./scripts/kudu.sh ls   /home/deploy-backups
./scripts/kudu.sh get  /home/deploy-backups/pre-deploy-….sql.gz ./local.sql.gz
./scripts/kudu.sh put  ./import.sql.gz /home/import.sql.gz
./scripts/kudu.sh run  "gzip -dc /home/import.sql.gz | vendor/bin/drush sql:cli"
./scripts/kudu.sh rm   /home/import.sql.gz
```

Access is gated by Azure RBAC — an Entra bearer token, no open port, nothing to
rotate. The app's own IP restrictions deliberately do not apply to it, so a
network misconfiguration cannot lock you out of the tool you need to fix it.

On Container Apps the equivalent is `az storage file upload` / `download` against
the mounted share, plus `./scripts/drush.sh` for commands.

---

## Maintenance mode

```bash
./scripts/drush.sh state:set system.maintenance_mode 1
./scripts/drush.sh state:set system.maintenance_mode 0
./scripts/drush.sh cache:rebuild
```

State is in the database, so it applies to every replica at once. It is rarely
needed here: a normal deploy runs its schema work on a revision holding no
traffic, so the live revision keeps serving throughout.

---

## Scaling and cost

```bash
# App Service: change the plan SKU. B1 -> S1 also unlocks deployment slots, which
# is how you remove the restart window from a deploy.
az appservice plan update -n "$PLAN_NAME" -g "$AZURE_RESOURCE_GROUP" --sku S1

# Container Apps
az containerapp update -n "$AZURE_APP_NAME" -g "$AZURE_RESOURCE_GROUP" \
  --min-replicas 1 --max-replicas 5
```

To pause a non-production environment without destroying it — the database and
shares keep costing, but the compute does not:

```bash
az webapp stop -n "$AZURE_APP_NAME" -g "$AZURE_RESOURCE_GROUP"                    # App Service
az containerapp update -n "$AZURE_APP_NAME" -g "$AZURE_RESOURCE_GROUP" --min-replicas 0
```

`azure-nuke.sh --keep-storage` is the deeper version: it moves the storage
account out of the resource group before deleting it, so the uploaded files —
the one thing that cannot be rebuilt from the repository — survive. It also
offers to purge the soft-deleted Key Vault, because Key Vault soft delete is
mandatory and otherwise reserves the vault name, making a rebuild with the same
base name fail on a name conflict that mentions nothing about soft delete.

---

---

## See also

- **[Troubleshooting](troubleshooting.md)** — organised by symptom.
- **[Configuration](configuration.md)** — every variable, and where it comes from.
- **[Secrets](secrets.md)** — rotation, and proving it took effect.
- **[Choosing a platform](choosing-a-platform.md)** — what differs between the two.
