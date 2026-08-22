# App Service or Container Apps

**Read this once, before your first deploy.** It is the one architectural
decision the template leaves to you.

**Short answer: take the default (App Service)** unless you know that a
restart-length downtime during a deploy is unacceptable, or that you need
horizontal autoscaling. The rest of this page is the evidence.

This template supports both and **defaults to App Service**. Below: why, what the
trade is, and when to pick the other one.

The short version: Drupal is a stateful application with a slow boot and a
filesystem. App Service's model — one warm instance, a persistent share, an
authenticated command channel into the running container — matches that. Container
Apps' model — many ephemeral replicas, no persistence, no ops channel — is a
better fit for stateless services, and most of the machinery a Drupal deployment
needs there exists to compensate for the mismatch.

---

## What actually differs

| | App Service (Linux container) | Container Apps |
|---|---|---|
| **Persistent writable storage** | `/home`, mounted automatically, shared across instances, survives restarts and deploys | None. Every path is ephemeral unless you provision a storage account and mount an Azure Files share |
| **Ops channel into the container** | Kudu: a filesystem API (browse, upload, download) and a command runner **that returns an exit code**. Gated by Entra RBAC, no open port | `az containerapp exec` — a terminal. No exit code, no file transfer, needs a running replica |
| **Instances** | One, by default and by design at B1 | N, autoscaling, and zero if you let it |
| **Keeping warm** | `alwaysOn`: one instance stays up | `minReplicas: 1` costs the same as always-on and still cold-starts on every new revision |
| **Deploy model** | Repoint the image tag, restart in place. A slot gives a warm swap target — but slots need **Standard (S1)** | Revisions: create at 0% traffic, health-check, shift. Genuine blue/green at the base tier |
| **Rollback** | Repoint at the previous tag and restart: an image pull plus a container start | A traffic weight change: seconds, nothing pulled, nothing restarted |
| **Scheduled work** | No first-class job runner for Linux containers. Cron is a scheduled workflow driving Kudu | Container Apps Jobs: same image, own replica, schedule, execution history, exit code |
| **Key Vault references** | Resolved and then **cached**; the status API says "Resolved" whether or not the running container has the newest version | Resolved at replica start. A restart genuinely re-reads |
| **Cost, one small site** | B1 ≈ $13/month flat, managed certificates free | Comparable at `minReplicas: 1`, plus a storage account you would not otherwise need |

---

## Why App Service wins for this workload

### `/home` is the thing you keep discovering you needed

A Drupal deployment accumulates a list of things that must outlive a container:
pre-deploy database dumps, a boot report, an import staging area, trigger files
for long operations, the private files directory. App Service gives you a
persistent, instance-shared, writable path for all of it with one app setting.

On Container Apps every one of those needs a storage account, a file share, a
mount, and a network rule — and the marker recording which image has been
deployed cannot go on disk at all, because a replica's filesystem is not shared
with its siblings. It goes in the database instead. That is a fine design and it
is more work for the same result.

### The ops channel is the difference between "diagnosable" and "not"

The MySQL server has no public endpoint. Neither does the storage account. So
anything that touches production data has to run **inside** the deployment, and
the question is what tool you have for that.

Kudu gives you a real one: push a file in, run a command, read its exit code,
pull a file out. Every operational script in the two live deployments this
template is modelled on is built on it — pull a database dump, upload a
private-files archive, drop a trigger file and read back the report.

`az containerapp exec` gives you a terminal. It cannot move a file, it has no
exit-code contract, and the command dies with the websocket — which for a schema
update means a half-migrated database from a dropped laptop connection. Getting
back to parity means building a manual-trigger Job for commands and using
`az storage file` against the mounted share for transfers.

### One instance means the concurrency problem does not exist

The deploy lock in `docker-entrypoint.sh` exists because Container Apps can start
several replicas of a new revision simultaneously, each of which would otherwise
run `drush updb` against the same schema at the same time. On a single App
Service instance that cannot happen.

The lock stays in the code — it is cheap, it is tested, and it costs one `UPDATE`
per boot — but on App Service it is belt-and-braces rather than load-bearing.

### The cold start is real and Drupal makes it worse

A Drupal container is not warm when the process starts. PHP has to build its
service container, populate opcache and warm the cache tables before the first
response. A first request after a restart has been measured at **93 seconds** on
one of these deployments, settling to under half a second afterwards.

`alwaysOn` keeps one instance past that. `minReplicas: 0` walks straight into it
on every idle period, and even `minReplicas: 1` pays it once per revision.

---

## Why you might still pick Container Apps

These are not consolation prizes. Two of them are genuinely better than anything
App Service offers below Standard tier.

### Revision traffic gating is real blue/green

Create the revision, let it become healthy, smoke-test it on its own labelled
URL, and only then move traffic. A failed deploy never touches production, and a
rollback is a weight change measured in seconds.

App Service's equivalent needs S1 and a deployment slot. At B1 a deploy restarts
the live instance — which, with the entrypoint's schema work in front of it, is a
downtime window of tens of seconds to minutes. **If that window is unacceptable,
either use Container Apps or budget for S1 plus a slot.** That is the single
strongest argument in the other direction and it should be weighed on its merits,
not waved away.

### Jobs are the correct answer for cron

Drupal's `automated_cron` runs at the end of a web request, which on any
autoscaling platform is wrong in both directions: with no traffic it never fires,
and with traffic it lands on a replica that may be scaled in mid-run. A scheduled
Container Apps Job runs the same image on a schedule with its own execution
history and exit code.

On App Service, cron is a scheduled GitHub workflow calling Kudu. That works, and
it puts a CI system on the critical path for a maintenance task.

### Horizontal scale, if you will ever need it

You probably will not — these are departmental sites — but if you do, it is the
difference between a configuration change and a migration.

### Key Vault reference caching

App Service caches the resolved value of a reference, and the status API reports
"Resolved" regardless of whether the running container holds the newest version.
So "the secret was rotated" and "the container is using the new secret" are
different statements the platform will not distinguish.

The entrypoint works around this by publishing a truncated **fingerprint** of each
secret it is holding to its boot result, so the second statement can be checked
directly. That is a workaround for a platform behaviour Container Apps does not
have.

---

## How to choose

Pick **App Service** — the default — when:

- the site serves tens to low hundreds of users, which is the usual case;
- a restart of tens of seconds during a deploy is acceptable;
- you want the operational surface (file transfer, commands with exit codes,
  `/home`) without building it.

Pick **Container Apps** when:

- deploys must be zero-downtime and you are not willing to pay for S1;
- you genuinely need horizontal autoscaling;
- you want cron and one-off maintenance as first-class platform jobs rather than
  as CI tasks.

Pick **App Service on S1 with a staging slot** when you want App Service's
operational model *and* a warm swap. This is the upgrade path, and it is a plan
SKU change plus a slot — not a re-platform.

---

## What is shared, and what is not

Almost everything is shared, which is what makes switching a real option rather
than a rewrite:

```
shared (platform-independent)
  Dockerfile, Dockerfile.dev, docker-compose.yml
  docker-entrypoint.sh, docker/entrypoint-lib.sh
  docker/drupal/settings.azure.php     <- reads paths from the environment
  docker/nginx, docker/php, docker/php-fpm, docker/supervisor
  scripts/  (platform differences live in scripts/lib/platform.sh)
  tests/, docs/
  infra/modules/{networking,logging,acr,identity,keyvault,storage,mysql}.bicep

platform-specific
  infra/appservice/main.bicep      + infra/modules/appservice.bicep
  infra/containerapps/main.bicep   + infra/modules/{aca,jobs}.bicep
  scripts/kudu.sh                  (App Service only)
  the two rollout jobs in .github/workflows/deploy.yml
```

The entrypoint takes every path from an environment variable —
`DRUPAL_BACKUP_DIR`, `DRUPAL_BOOT_RESULT`, `DRUPAL_FILE_PRIVATE_PATH` — so the
same image boots correctly on both, writing to `/home` on App Service and to a
mounted share on Container Apps.

### Switching

```bash
AZURE_PLATFORM=containerapps ./scripts/azure-up.sh    # or appservice
```

The scripts detect the platform from the resource group when `AZURE_PLATFORM` is
unset, and refuse to guess when a resource group somehow contains both.

Note what a switch does **not** carry across: the database and the file shares
belong to the resource group, not to the compute, so deploying the other platform
into the *same* resource group reuses them. Deploying into a new one starts
empty, and the data has to be migrated — see [database.md](database.md).

---

## See also

- **[Getting started](getting-started.md)** — deploying, once you have decided.
- **[Operations](operations.md)** — the day-two commands, marked where they differ.
- **[Design notes](design-notes.md)** — why the deploy sequence is shaped the way
  it is on both.
- **[Production learnings](production-learnings.md)** — the platform-shaped
  failures behind this comparison.
