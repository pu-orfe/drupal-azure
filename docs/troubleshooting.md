# Troubleshooting

**Start here when something is wrong.** Symptoms first — most of the failures
this template guards against announce themselves as something other than their
cause.

## When the site is down: the five-minute version

1. **`./scripts/verify-site.sh https://<fqdn>`** — it inspects the response body,
   so it distinguishes a Drupal error page (HTTP 200 with a fatal in the body)
   from a genuine outage. A status-code check cannot.
2. **`./scripts/rollback.sh --list`** — is traffic on the revision you expect? A
   failed deploy should have left it on the previous one.
3. **`./scripts/azure-logs.sh --tail 200`** — the entrypoint narrates its
   decisions, so the boot sequence is legible.
4. **Recently deployed?** `./scripts/rollback.sh --previous`. Recovering first
   and diagnosing afterwards is nearly always right; the previous revision is
   still running.
5. **Database?** `./scripts/drush.sh status`. If it cannot connect, the boot
   result names the cause: the entrypoint rejects an unresolved Key Vault
   reference by name rather than letting it fail later as "access denied for
   user". On App Service a reference can also resolve to a *stale cached* value
   after a rotation — compare the fingerprints in the boot result.
6. **Disk?** A full MySQL disk stops the site rather than degrading it, because
   Drupal writes on nearly every request. Auto-grow is enabled, but check:
   `az mysql flexible-server show … --query storage`.

---

---

## By symptom

### The site returns 200 but the page is blank or broken

Drupal has already sent headers by the time a PHP fatal happens, so there is no
status code left to change. A status-code health check passes on a dead site;
this is why `verify-site.sh` inspects the body.

```bash
./scripts/verify-site.sh https://<host>          # names what it found
./scripts/azure-logs.sh --tail 200 --no-follow
```

### The deploy said it succeeded but nothing changed

Check whether the entrypoint thought it had already run:

```bash
./scripts/drush.sh sql:query "SELECT deployed_version, deployed_at FROM azure_deploy_state WHERE id = 1"
```

If `deployed_version` matches the image you just built, the deploy sequence was
skipped by design — that is the marker doing its job on a scale-up. If it does
*not* match, the schema work did not complete; read the boot result:

```bash
./scripts/kudu.sh cat /home/boot-result.json | python3 -m json.tool   # App Service
```

`status: degraded` with `critical_failed: false` means a *tolerated* step failed.
`steps` names which. See [Operations](operations.md#what-is-running).

### Everything works under `drush` but web requests cannot reach the database

`clear_env`. PHP-FPM's default wipes the environment before a worker handles a
request, so `getenv()` returns nothing in a web request while working perfectly
on the command line. `docker/php-fpm/www.conf` sets `clear_env = no`; if you have
replaced that file, put it back.

```bash
./scripts/verify-production-image.sh <image>   # asserts this among other things
```

### `ERROR 1267 Illegal mix of collations`

A table created later is on a different collation from the ones created earlier.
Almost always: the `collation` key was not set in `settings.php` when the table
was created, so it inherited the *character set's* default rather than the
database's.

Full mechanism and the repair — which is **not** a blanket
`ALTER TABLE ... CONVERT TO CHARACTER SET` — in
[database.md](database.md#collation-the-one-that-will-bite-you).

### Anonymous visitors appear to be logged in as the administrator

The anonymous user is not `uid 0` any more. An import without
`NO_AUTO_VALUE_ON_ZERO` renumbers it to 1, colliding with the admin account.

```sql
SELECT COUNT(*) FROM users WHERE uid = 0;   -- must be exactly 1
```

Repair in [database.md](database.md#no_auto_value_on_zero--not-optional).

### `MySQL server has gone away` during an import or a dump

`max_allowed_packet`. The 4 MB default is smaller than rows Drupal's cache and
config tables routinely hold. The Bicep sets it to 512 MB; a server created some
other way will not have that.

### `Access denied; you need the PROCESS privilege` from mysqldump

Add `--no-tablespaces`. It reads like a credentials problem and is not.

### `Access denied for user` right after a secret rotation

Two different causes, and the boot result distinguishes them:

- **The reference did not resolve.** The container is holding the literal text
  `@Microsoft.KeyVault(SecretUri=…)`. The entrypoint rejects this by name rather
  than letting it fail later — check the logs for "UNRESOLVED".
- **App Service cached the old value.** Compare `db_password_fingerprint` in
  `/home/boot-result.json` before and after. If it did not change, the container
  is still on the previous secret. See [secrets.md](secrets.md#applying-it).

### The smoke test says INCONCLUSIVE

Not a failure and not a pass: the request never reached the container, so nothing
was verified. On an access-restricted site, Azure's front end answers 403 for
every path including ones that do not exist.

Run it from inside the allow-list, or add the caller's address. `--expect-block`
asserts the refusal deliberately when that is what you want to test.

### A replica or instance is up but every request is 502

php-fpm has died and the web server has not. The supervisor event listener kills
PID 1 when either process goes `FATAL` precisely so the platform replaces the
instance instead of leaving it reporting healthy — if you are seeing sustained
502s, check that listener is still in `supervisord.conf`.

### The first request after a deploy takes 60–90 seconds

Expected on a cold Drupal container: PHP builds its service container, warms
opcache and populates the cache tables before the first response. One deployment
measured 93 seconds.

App Service `alwaysOn` keeps one instance past it. On Container Apps,
`minReplicas: 0` walks into it on every idle period — which is why the default
here is 1.

### The local stack fails with `db ... exited (139)`

`mysql:8.0` on arm64 intermittently segfaults while initialising a fresh data
directory — observed on Apple Silicon under Docker Desktop, roughly one attempt
in several on an empty volume. It is the image misbehaving on that platform, not
a problem with this configuration: the same compose file comes up healthy on a
retry with nothing changed.

`local-dev.sh` and `test.sh` already retry it (up to three times, wiping the
volume between attempts — a half-initialised data directory must not be
inherited). If it fails on every attempt, that is not the flake:

```bash
docker-compose logs db | tail -40
```

Check Docker's memory allocation first; MySQL 8 needs more than the default on
some setups.

### Email is not arriving, and nothing is failing

The most likely cause is that nothing is configured, because the failure is
**silent by construction**: Drupal's default mail system accepts every message and
a container with no MTA delivers none. No error, no bounce, nothing in a log.

```bash
./scripts/setup-email.sh --status
```

That reports whether the endpoint is set, whether the Office 365 connection has
been authorised, and whether the trigger's access controls are in place. The most
common answer is that the one manual consent step was never done. See
[email.md](email.md#verifying) for the run-history query and a symptom table.

### `composer install` failed on a package that exists

A transient 429 or 504 from GitHub. `scripts/composer-retry.sh` retries twelve
times because Composer caches what it already fetched, so the stragglers roughly
halve each attempt. If it still fails, set `COMPOSER_AUTH` with a GitHub token —
that lifts the anonymous rate limit and is the actual first line of defence.

### The deployment failed partway through, after creating some resources

Re-run it. Every template here is idempotent, and `azure-up.sh` reuses the
existing Key Vault secrets rather than regenerating them.

The one case that needs attention: if `AZURE_BASE_NAME` is longer than 11
characters the storage account name is invalid, and the failure comes *after* the
VNet and the MySQL server exist. The script now refuses before provisioning
anything.

### `azure-up.sh` fails on a Key Vault name conflict after a teardown

Key Vault soft delete is mandatory, so the name stays reserved. `azure-nuke.sh`
offers to purge it; if you deleted the resource group by hand:

```bash
az keyvault list-deleted -o table
az keyvault purge --name <name>
```

### A deploy step is waiting on the deploy lock

Expected briefly on Container Apps when several replicas of a new revision start
together — one does the work, the others wait. It self-heals after
`DRUPAL_LOCK_STALE_SECONDS` (default 1800). Clearing it early is documented in
[Operations](operations.md#clearing-a-stuck-deploy-lock), with the warning that
two concurrent `updb` runs are exactly what it prevents.

---

## Getting more detail

```bash
./scripts/azure-logs.sh                      # live
./scripts/rollback.sh --current              # what is actually deployed
./scripts/rollback.sh --list                 # what you could go back to
./scripts/drush.sh status                    # Drupal's own view
./scripts/verify-site.sh https://<host>      # pass / fail / inconclusive
./scripts/verify-production-image.sh <image> # structural checks on the image
```

Historical logs — from the deploy that broke something three weeks ago — are in
Log Analytics, not on the instance. The query is in
[Operations](operations.md#reading-logs).

## See also

- **[Operations](operations.md)** — the full runbook, including restores.
- **[Production learnings](production-learnings.md)** — why each of these checks
  exists, and what it cost to find out.
