# Production learnings

**You do not need to read this to use the template.** It exists for one purpose:
to stop a deliberate decision being "simplified" away by someone who has not yet
hit the failure it prevents.

Every row below is a real incident from one of two live Drupal-on-Azure
deployments, both on App Service, both in production. Each names where the fix
lives and, where one exists, the test that pins it — so if you are about to
change one of those files, this tells you what you are holding.

The deep reasoning lives in the code comments next to each fix, not here. This is
the index.

The source deployments are deliberately not named, and neither are their hosts,
resource groups or domains. A lesson does not need provenance to be true, and
naming an internal system alongside its operational state — "mid-migration",
"currently failing its gate" — is a description of somebody's infrastructure
posture. If a row reads as less credible without a name, that is a sign the row
needs better evidence, not a name.

---

## Failures that report success

The worst category: something is broken and every signal says it is fine.

| The failure | Where the fix lives | Pinned by |
|---|---|---|
| `drush updb` run from CI via `az containerapp exec`, which has no exit-code contract — so the step was written `\|\| echo "failed"` and a **failed schema update produced a green deploy** | `docker-entrypoint.sh`; `scripts/drush.sh` runs drush as a job with a real exit code | integration suite |
| The deploy health check was `curl -w '%{http_code}'`. Drupal answers a PHP fatal with **HTTP 200** and a blank body, and a missing database with a themed 200 | `scripts/verify-site.sh` inspects the body | 15 cases in `tests/shell/run.sh` |
| Supervisor kept running as PID 1 after php-fpm exhausted its restarts: container "up", liveness probe passing on nginx, **every request 502** | `PROCESS_STATE_FATAL` listener in `supervisord.conf` kills PID 1 | — |
| The post-deploy steps never ran `config:import` at all, so exported config was baked into the image and **silently ignored** for months | `docker-entrypoint.sh` runs it between `updb` and `cache:rebuild` | integration suite |
| A failed `mysqldump \| gzip` writes a **valid ~20-byte gzip**. Without `pipefail` the shell tests gzip's status, not mysqldump's — and writing straight to the destination destroyed the last good backup | `validate_dump` / `safe_dump` in `docker/entrypoint-lib.sh` | `tests/shell/entrypoint-guards.sh` |
| An unresolved Key Vault reference arrives as its **literal text**, ~80 plausible characters. A length check does not merely miss it, it reassures | rejected by prefix in `settings.azure.php` and `entrypoint-lib.sh` | guards + unit tests |
| App Service **caches** a resolved Key Vault reference and reports "Resolved" either way, so a rotation can appear to work and change nothing | `secret_fingerprint` publishes a digest to the boot result | guards |
| A single boot-status flag conflated "was this clean" with "must the next boot retry". A routinely-failing *non-blocking* step then withheld the version marker, so **every restart re-ran updb and overwrote the rollback point** | `BOOT_STATUS` vs `CRITICAL_FAILED`, `run_step critical\|tolerated` | guards |
| `exit("message")` prints the string and **exits zero** — so a fatal misconfiguration reported as a successful run | `exit(1)` in `settings.azure.php` | `tests/php/FailClosedTest.php` |
| An import without `NO_AUTO_VALUE_ON_ZERO` renumbers Drupal's `uid 0`, so **anonymous visitors appear to be the administrator**. The import reports complete success | `scripts/migrate.sh` sets it *and verifies the result* | — |
| `drush site:install` **appends a hash salt to the git-tracked `settings.php`** whenever the file is writable | the install scripts make it read-only for the duration | `tests/shell/run.sh` |

## Failures that surface months later, somewhere else

| The failure | Where the fix lives | Pinned by |
|---|---|---|
| **Illegal mix of collations.** A `CREATE TABLE` naming a character set but no collation takes the *character set's* default — so `ALTER DATABASE`, `--collation-server` and the session collation **all fail to fix it**. Measured: 3 of 193 tables landed on `0900_ai_ci` with `--collation-server` set correctly throughout | the `collation` key in `settings.azure.php`, matched in `mysql.bicep` and `docker-compose.yml` | consistency + integration tests |
| A blanket `CONVERT TO CHARACTER SET` widened **48 `ascii` columns** and destroyed `_bin` collations — making values differing only in case compare equal, which is corruption | per-column `MODIFY` documented in [database.md](database.md) | — |
| A guard comparing its own before-and-after counts is blind to damage already present: a prior conversion had widened six columns and the check reported "379 → 379, passed" | expected counts taken from the **source** | — |
| A `CHANGEME` default that nothing forces you to replace **becomes** the production credential — and is then committed | no defaults, no prompts; `azure-up.sh` generates | `tests/shell/run.sh` |
| `az mysql flexible-server create` without `--version` provisions Azure's current default, so a rebuild lands on an **untested engine** | `mysqlVersion` pinned in `mysql.bicep` | — |
| A single-slot pre-deploy backup: a change landing as two deploys has its "before" snapshot destroyed by the second | timestamped dumps, `DRUPAL_BACKUP_KEEP` | — |
| A migration gate failed on **cache-table churn** (`cache_data` 73→39), not lost data. And a manifest sorted by the server diffs as noise, because the two servers order identifiers differently | measure quiescence; sort `LC_ALL=C`. [migrating-a-site.md](migrating-a-site.md) | — |
| "Assert 0 tables remain" verifies the drop **succeeded**. It says nothing about *which server* was dropped | three-way allow-list guard on any destructive target | — |

## Failures caused by the platform's shape

Container Apps runs N ephemeral replicas and can scale to zero; App Service runs
one warm instance with a persistent disk. Most Drupal deployment advice assumes
neither.

| The failure | Where the fix lives |
|---|---|
| "Run updb at boot" is safe on one instance and means **N concurrent `drush updb`** on N replicas — and it re-runs on every cold start, which is not a deploy at all | version marker **in the database** (a replica's filesystem is not shared) plus a lock acquired by one conditional `UPDATE` whose `ROW_COUNT()` is read in the same session |
| The entrypoint runs schema work before the web server starts, so nothing listens for minutes. A default startup probe **killed the replica mid-migration** — one run finished at 222s against a 230s default | `startupProbeTimeoutSeconds` / `containerStartTimeLimit`, both 900 |
| `automated_cron` fires at the end of a web request: with no traffic it never runs, with traffic it lands on a replica that may be scaled in mid-run | disabled; a Container Apps Job or a Kudu-driven workflow |
| Traffic configuration was `latestRevision: true`, so 100% of traffic moved to a new revision **before any check ran** — "blue/green" was the label on an unguarded rollout | the gated rollout in `deploy.yml` |
| Nothing retires old revisions in Multiple mode, and they eventually block new ones with an error naming neither cause | the deploy workflow keeps the last three |

## Failures with a misleading error message

| Symptom | Actual cause |
|---|---|
| Bootstrap check fails intermittently | `drush status \| grep -q` under `pipefail`: SIGPIPE makes **success look like failure** |
| `Access denied` waiting for a database | `mysqladmin ping` succeeds against MySQL's *temporary* init server, before the user exists. Every gate here is an authenticated `SELECT 1` |
| `MySQL server has gone away` mid-import | `max_allowed_packet`, not the network |
| `Access denied; you need the PROCESS privilege` | missing `--no-tablespaces`, not credentials |
| Site works under drush, cannot connect over HTTP | php-fpm's `clear_env` default wipes the environment before a worker handles a request |
| A build failing on a different package each time | Composer does not fall back to source, so one transient GitHub 429 kills it. Three consecutive production deploys died this way |
| CI green on the wrong PHP | `docker build` reuses a cached layer for a changed `FROM`. A PHP 8.4 bump nearly shipped with CI green on 8.3 |

## Security gaps that looked fine in review

| The gap | The fix |
|---|---|
| The storage account had **no network rules** — the private files share was reachable by anyone with the account key, which is in the app's configuration | `defaultAction: Deny` plus a VNet rule, which needs the `Microsoft.Storage` service endpoint on the subnet |
| `MYSQL_ATTR_SSL_CA` paired with `VERIFY_SERVER_CERT => FALSE` is self-cancelling: it stops a passive listener and not an active one, while looking secure | verification on by default; Azure's chain is already in `ca-certificates` |
| Hand-written `trusted_host_patterns` are wrong in both directions — an unescaped dot matches any character, a missing anchor matches any host *containing* the name, and an **empty list makes Drupal accept every host** | built with `preg_quote`, never empty. `tests/php/TrustedHostsTest.php`, mostly negative assertions |
| ACR's admin account: one shared push-capable credential in the app's config, unattributable, rotated by hand | `adminUserEnabled: false`, pull by managed identity |
| `mysql -p"$PASSWORD"` publishes the credential to every process via `/proc` | `MYSQL_PWD` throughout |
| `.dockerignore`'s `*.sql` matches only **top-level** files, and `docker build .` sends untracked files — so a developer's working dump shipped inside the image | patterns written twice; `verify-production-image.sh` asserts on the **artifact**, not the ignore file |

## Deployment ergonomics that cost real time

| The problem | The fix |
|---|---|
| A system-assigned identity does not exist until the app is created, but the app needs its grants **at creation time** — so the first deployment always failed and succeeded on the second, indistinguishable from a real failure | a user-assigned identity, created and granted first |
| Key Vault soft delete reserves the name, so teardown-then-rebuild — the exact loop this template supports — failed on a name conflict mentioning nothing about soft delete | purge protection off; `azure-nuke.sh` offers to purge |
| `baseName` allowed 16 characters but the storage account name caps at 24, so a long name failed **after** the VNet and MySQL server existed | `@maxLength(11)`, plus a check before provisioning |
| `composer update` committed to `main` and deployed unreviewed — a Drupal update moves core and thirty modules at once | `composer-update.yml` opens a PR with a package diff and an audit |
| An advisory published on a Tuesday sat unnoticed until the following Monday | `security-audit.yml`, daily, one tracking issue |

---

## Still in flight upstream (as of 2026-08-22)

One of the two deployments is mid-migration from **MySQL 5.7 to 8.0** and heading
for **Drupal 11**. Neither is finished, so the guidance below is provisional — but
the shape of the work is already clear, and this template is built to accommodate
it rather than having to be reworked for it.

### MySQL 5.7 → 8.0

Rehearsed repeatedly against a live production source with no risk to it, because
the destructive work and the switch that makes it live are separate steps: dump,
restore, normalise and verify against the *new* server while production keeps
serving from the old one, entirely unmodified. Only if every gate passes does
anything repoint the application.

Where it currently stands: the data movement works (dump 6s, restore 44s,
normalise 1s — a ~51-second window), collations come out clean, Drupal bootstraps
against the target. **The gate is failing on the row manifest**, and the cause is
cache-table churn rather than lost data — see "A migration gate that failed on
cache churn" above. The fix in progress is to take the manifest after maintenance
mode is on and to *measure* which tables are quiescent rather than assume.

What is already settled and reflected here:

- pin `collation` in `settings.php` **before** the move, so the migration does not
  change collation behaviour and the setting can be verified on the old server
  first, where it is a no-op;
- pin the engine version explicitly (`8.0.21`), so a rebuild cannot land on an
  untested engine;
- normalise per column, never with a blanket `CONVERT TO`;
- allow-list every destructive target.

### Drupal 11

Not started on either site. The two things this template already does to make it a
version bump rather than a project:

- **`config.platform.php` matches the image**, and CI resolves on the same
  version — so a PHP bump is caught by `verify-production-image.sh` rather than in
  production. Drupal 11 requires PHP 8.3+, which the image already runs.
- **`drupal/genpass` is constrained `^2.0 || ^3.0`** — 3.x requires Drupal 11.3+,
  2.x covers Drupal 10 — so the move is a core bump, not a module hunt.

What is worth adding before attempting it, taken from that deployment's
pipeline:

- a **deprecation scan over first-party code only**, using
  `mglaman/phpstan-drupal` and `phpstan/phpstan-deprecation-rules` (both already
  pulled in by `drupal/core-dev`). Tune the configuration so that *any* output is
  a real upgrade blocker — that is what makes failing the build on it meaningful,
  and it needs no `upgrade_status` module and no bootstrapped site;
- a **kernel-test run against MySQL 8** specifically. `scripts/test.sh
  --integration` already boots the real stack against MySQL 8 with production's
  collation, which covers the same ground for the deployment itself.

---

---

## What was already right

Worth naming, so it does not get changed by accident:

- **VNet-isolated MySQL with a private DNS zone and no public endpoint.** The
  single most valuable structural decision in the original template.
- **Immutable image revisions** rather than in-place modification.
- **Bicep at subscription scope**, so the resource group is part of the
  deployment and a teardown is genuinely complete.
- **Interactive scripts that skip every prompt when the environment supplies the
  value**, which is what makes the same script usable by a human and by CI.
- **OIDC federation** instead of a stored service-principal credential.
- **Keeping the destructive step and the switch separate**, which is what makes a
  migration rehearsable against live production data at no risk.
- **Trigger files plus an authenticated command channel** as the way to drive a
  long operation inside a container whose database has no public endpoint. This
  is the pattern App Service's `/home` and Kudu make possible, and the main
  practical reason this template defaults to App Service — see
  [choosing-a-platform.md](choosing-a-platform.md).

---

## See also

- **[Design notes](design-notes.md)** — the image and entrypoint decisions, in
  full.
- **[Database settings](database.md)** — the database ones.
- **[Troubleshooting](troubleshooting.md)** — the same failures, indexed by what
  you will actually see.
