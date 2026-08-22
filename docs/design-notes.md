# Design notes

**Read this if** you are about to change the Dockerfile, the entrypoint, the
web-server configuration or the deploy sequence — or if something in them looks
wrong and you want to know whether it is deliberate.

Most of the decisions below were made because the alternative failed in
production somewhere. Each one names the failure.

| | |
|---|---|
| [Single stage, not multi-stage](#single-stage-not-multi-stage) | The vendor tree must be built by the PHP that will run it |
| [Two `composer install` calls](#two-composer-install-calls) | The second is not redundant |
| [`install-php-extensions`](#install-php-extensions-rather-than-docker-php-ext-install) | Survives a PHP bump |
| [`clear_env = no`](#clear_env--no-in-php-fpm) | **The most consequential line in the image** |
| [opcache settings](#opcachevalidate_timestamps0-save_comments1) | One of them breaks Drupal if you get it wrong |
| [An entrypoint, not CI steps](#an-entrypoint-not-post-deploy-ci-steps) | Where the schema work belongs |
| [Three probes](#probes-three-doing-different-jobs) | Doing three different jobs |
| [Supervisor shutdown order](#supervisor-ordered-graceful-shutdown) | And why the container must die with it |
| [`.dockerignore` patterns](#dockerignore-single--does-not-cross) | A single `*` does not cross `/` |
| [Not the official image](#would-the-official-drupal-image-do) | Why not |

Related: **[Database settings](database.md)** for the database side of the same
question, and **[Production learnings](production-learnings.md)** for the full
incident catalogue.

---

## Single stage, not multi-stage

An earlier version installed dependencies in a `composer:2` stage and copied
`/app` into a `php:*-fpm` runtime. That is the usual multi-stage advice, and here
it is wrong: it builds the vendor tree with whatever PHP the composer image
happens to carry. Composer's platform checks — `config.platform.php`, `require:
php`, and every dependency's own PHP constraint — are then satisfied against a
runtime that is not the one serving requests, and any mismatch surfaces as a
fatal error on a live page rather than as a failed build.

Installing with the PHP that will run the code makes that class of drift
impossible. The cost is that the composer phar (~3 MB) ships in the image, which
is a fair trade and also means `composer show` is available when diagnosing a
running container.

`scripts/verify-production-image.sh` asserts that the image's PHP matches
`ARG PHP_VERSION`, that `Dockerfile.dev` agrees, and that CI resolves
dependencies on the same version — because CI validating a different runtime than
production runs is how a version bump ships broken.

---

## Two `composer install` calls

```dockerfile
COPY composer.json composer.lock ./
RUN composer-retry install --no-dev …      # cached until the lock file moves

COPY . .
RUN composer-retry install --no-dev …      # scaffold + custom code autoload
```

The first gives a cached dependency layer. The second is not redundant: `COPY . .`
overwrites the scaffolded web root with the repository's copy and introduces
custom modules and themes the first install never saw, so both the autoloader and
the scaffold need regenerating.

Note what it is **not**: `composer run-script post-install-cmd || true`. That was
the previous form, and the `|| true` turns a failed scaffold into a green build
that ships a broken web root.

---

## `install-php-extensions` rather than `docker-php-ext-install`

The hand-rolled form — `docker-php-ext-configure gd --with-freetype …` plus
`pecl install` plus a manual `apt-get purge` of the build dependencies — breaks on
a PHP bump whenever a PECL extension has not yet cut a compatible release.
`uploadprogress` is the one that reliably lags. And it breaks as an opaque compile
error rather than as a clear "no version available".

`mlocati/docker-php-extension-installer` resolves the `-dev` packages and the
correct extension version for the PHP in use, and removes the build dependencies
itself.

---

## `clear_env = no` in php-fpm

This is the single most consequential line in `docker/php-fpm/www.conf`, and it is
not tuning.

PHP-FPM's default is `clear_env = yes`: the master process wipes the environment
before handing a request to a worker. Every variable injected by the container app
— `DRUPAL_DB_HOST`, `DRUPAL_DB_PASSWORD`, `DRUPAL_HASH_SALT` — is therefore
invisible to `getenv()` inside a web request, while remaining perfectly visible to
the entrypoint, to drush, and to `php -r` on the command line.

That asymmetry is the whole trap. `drush status` reports a healthy database
connection, the entrypoint runs `updb` successfully, and every HTTP request fails
to connect. A settings file built around environment variables cannot work on
php-fpm without this line, and nothing in the error message points at it.

Asserted in two places: `verify-production-image.sh` checks the built image, and
`tests/shell/run.sh` checks the file.

---

## `opcache.validate_timestamps=0`, `save_comments=1`

**Timestamp validation off** because the code in this image is immutable — a new
revision is a new image, never an edit in place — so there is nothing for a stat
per included file per request to detect. The corollary: any change to PHP under
`/var/www/html` at runtime is invisible until the container restarts. That is the
intended property, and it is why hot-patching a live container does nothing.

**`save_comments=1`** because Drupal reads docblock annotations at runtime for
plugin discovery, in core and widely in contrib that has not migrated to PHP
attributes. Stripping comments breaks plugin discovery with errors that point
nowhere near the cause. It is the single most common way a generic "production PHP
tuning" snippet breaks Drupal, which is why it is set explicitly rather than left
at its (correct) default.

---

## An entrypoint, not post-deploy CI steps

`docker-entrypoint.sh` runs `drush updb`, `config:import` and `cache:rebuild`
before starting the web server. The previous design ran them from GitHub Actions
via `az containerapp exec` after the revision went live. That was wrong three
ways:

1. `az containerapp exec` has no exit-code contract, so the steps were written
   `|| echo "failed"` and a failed schema update produced a green deploy.
2. It never ran `config:import` at all, so exported configuration was baked into
   the image and then ignored, and the site's config drifted from the repository
   indefinitely.
3. It ran after traffic had shifted, so requests hit new code against an old
   schema for the duration.

In the entrypoint, a failure means the revision never becomes healthy, and
Container Apps will not send traffic to a revision that never became healthy.

The two mechanisms that make this safe on a platform with N replicas and
scale-to-zero — the database-held version marker, and the deploy lock — are
described in the script's header and in [database.md](database.md).

---

## Probes: three, doing different jobs

Declared in `infra/modules/aca.bicep`. Container Apps ignores the Dockerfile
`HEALTHCHECK`; that one exists only so a local `docker run` reports health.

| Probe | Target | Why |
|---|---|---|
| Startup | `/nginx-health` | Sized for the entrypoint's schema work — nothing listens on port 80 for minutes on a deploy that carries updates. A default-length startup probe kills the replica *part-way through a schema update* |
| Liveness | `/nginx-health` | nginx-level, no PHP, no database. A liveness probe that hits Drupal restarts every replica at once when the database blips, converting a recoverable outage into a fleet-wide crash loop |
| Readiness | `/` | Goes through Drupal, because "should this replica receive traffic" genuinely does depend on whether Drupal can serve. A replica with a broken database drops out of the pool instead of returning 500s |

---

## Supervisor: ordered, graceful shutdown

Container Apps sends SIGTERM when draining a replica. Two details:

- nginx gets **SIGQUIT** (graceful: finish in-flight requests) rather than the
  default SIGTERM (fast shutdown: drop them).
- nginx stops **first**, so no new request reaches a php-fpm that is already
  winding down and would answer 502. Supervisor's `priority` controls both start
  and stop order — lower starts earlier and stops *later* — so php-fpm (10)
  outlives nginx (20).

There is also an event listener that kills PID 1 when either program goes
`FATAL`. Without it, supervisor keeps running after php-fpm exhausts its
restarts: the container stays "up", the liveness probe on `/nginx-health` still
passes because nginx is fine, and every request returns 502 — a replica that is
broken and reports healthy, which is the worst state to be in.

---

## `.dockerignore`: single `*` does not cross `/`

`*.sql` matches only **top-level** files. A dump in `examples/` or `import/`
reaches the image despite the pattern being listed, which is how a database dump
ends up inside a production image. Every archive pattern in `.dockerignore` is
therefore written twice — bare and `**/`-prefixed.

This matters because the Dockerfile does `COPY . .` and both `docker build .` and
`az acr build .` send everything in the working directory, *including untracked
files*. A production dump left in a developer's checkout is ordinary working
debris.

`verify-production-image.sh` asserts on the built **artifact** rather than on
`.dockerignore`: the ignore file is the control, and the check is the verification
that the control worked.

---

## Would the official `drupal` image do?

For evaluation and for a mount-your-code development loop, yes. For this
architecture, no — and the reasons are structural rather than aesthetic:

| | Official image | This image |
|---|---|---|
| Web server | Apache, or `-fpm` with no server | nginx + php-fpm, one container, ordered shutdown |
| Your code | Mounted or copied in at runtime | Baked in at build time |
| Dependencies | `composer install` at boot, or a mounted `vendor/` | Pre-installed, optimised autoloader, retried against transient registry failures |
| Immutability | Depends on volume contents at start time | Fixed per image tag |
| Rollback | Revert volumes and code | Shift traffic to the previous revision |
| Deploy-time schema work | Nothing | Entrypoint, once per image, under a lock, after a backup |

Basing on `drupal:10-fpm` and adding nginx and supervisor is possible but strictly
more work than starting from `php:8.3-fpm-bookworm`, because you would be undoing
the official image's entrypoint and Apache assumptions first.

---

## See also

- **[Database settings](database.md)** — the same kind of reasoning, applied to
  MySQL.
- **[Choosing a platform](choosing-a-platform.md)** — why the deploy model differs
  between App Service and Container Apps.
- **[Production learnings](production-learnings.md)** — the incidents these
  decisions came from.
