#!/usr/bin/env bash
###############################################################################
# verify-production-image.sh — structural gate on the image production runs
#
# Usage:
#   ./scripts/verify-production-image.sh              # builds it, then checks
#   ./scripts/verify-production-image.sh <image-ref>  # checks an existing image
#
# WHY THIS EXISTS
#
# The production image was previously built only by the deploy workflow. Nothing
# before merge touched it, so a breakage in the Dockerfile, the entrypoint, the
# settings overlay or .dockerignore first surfaced in production.
#
# The image installs --no-dev, so phpunit is absent and the test suites cannot
# run inside it. What can be checked from outside is its STRUCTURE, and each
# check below corresponds to a specific failure that has actually shipped
# somewhere:
#
#   1. PHP version matches the Dockerfile        a bumped FROM served from a
#                                                cached layer
#   2. Required extensions present               a PECL extension with no build
#                                                for the new PHP
#   3. The application actually installed        a composer failure the retry
#                                                wrapper reported but a later
#                                                step ignored
#   4. No dev dependencies                       phpunit/phpstan shipped to
#                                                production
#   5. No build-context leakage into the docroot  a database dump in a
#                                                developer's checkout becoming a
#                                                routable URL
#   6. Entrypoint present and executable         container starts without ever
#                                                running updb/cim
#   7. CONTAINER_VERSION set                     entrypoint re-runs the deploy
#                                                sequence on every replica start
#   8. Settings overlay wired up                 image ships a settings.php that
#                                                never includes the overlay, so
#                                                the database is unconfigured
#   9. clear_env off in php-fpm                  getenv() returns nothing in a
#                                                web request while working
#                                                perfectly in drush
###############################################################################
set -uo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
FAILURES=0
fail() { printf '%s✗ %s%s\n' "$RED" "$1" "$NC"; FAILURES=$((FAILURES + 1)); }
pass() { printf '%s✓ %s%s\n' "$GREEN" "$1" "$NC"; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

IMAGE="${1:-}"
if [[ -z "$IMAGE" ]]; then
  IMAGE="drupal-azure-verify:local"
  printf '%sBuilding the production Dockerfile...%s\n' "$BLUE" "$NC"
  # --pull matters. Docker reports a successful build while reusing a cached
  # layer for a changed FROM, which leaves the image on the previous PHP and
  # makes check 1 the only thing that would have caught it.
  if ! docker build --pull --build-arg COMMIT_SHA=verify -t "$IMAGE" -f Dockerfile . >/dev/null; then
    fail "image does not build"
    exit 1
  fi
  pass "image builds"
fi

run() { docker run --rm --entrypoint sh "$IMAGE" -c "$1" 2>/dev/null; }
exists() { run "test -e '$1' && echo ok" | grep -q ok; }

printf '%sVerifying %s%s\n' "$BLUE" "$IMAGE" "$NC"

# ── 1. PHP version parity with the Dockerfile ───────────────────────────────
want_php="$(grep -m1 '^ARG PHP_VERSION=' Dockerfile | cut -d= -f2)"
got_php="$(run 'php -r "echo PHP_MAJOR_VERSION.\".\".PHP_MINOR_VERSION;"')"
if [[ -n "$want_php" && "$got_php" == "$want_php" ]]; then
  pass "PHP $got_php matches the Dockerfile"
else
  fail "PHP mismatch: Dockerfile declares '${want_php:-?}', image runs '${got_php:-?}'"
fi

# Keep the CI matrix honest too: resolving dependencies on a different PHP than
# production runs produces a lock file the runtime may not satisfy.
ci_php="$(grep -hm1 -oE "php-version: '[0-9.]+'" .github/workflows/pull-request.yml | grep -oE '[0-9.]+' || true)"
if [[ -n "$ci_php" && "$ci_php" == "$want_php" ]]; then
  pass "CI resolves dependencies on PHP $ci_php, the same as the image"
elif [[ -n "$ci_php" ]]; then
  fail "CI uses PHP $ci_php but the image is $want_php: CI would validate the wrong runtime"
fi

# ── 2. Extensions ───────────────────────────────────────────────────────────
# The list is captured ONCE rather than per extension. Starting a container per
# extension and piping into `grep -q` interacts with `set -o pipefail` and can
# report a present extension as missing.
modules="$(run 'php -m')"
if [[ -z "$modules" ]]; then
  fail "could not read the extension list from the image"
else
  for ext in gd pdo_mysql zip intl apcu uploadprogress; do
    if grep -qix "$ext" <<<"$modules"; then
      pass "extension $ext"
    else
      fail "extension $ext missing"
      # Show what WAS there; an absence reported without evidence sends the
      # reader looking in the wrong place.
      printf '      found: %s\n' "$(tr '\n' ' ' <<<"$modules" | cut -c1-200)"
    fi
  done
  grep -qi 'zend opcache' <<<"$modules" && pass "extension opcache" || fail "extension opcache missing"
fi

# ── 3. Application installed ────────────────────────────────────────────────
for path in \
  /var/www/html/vendor/autoload.php \
  /var/www/html/vendor/bin/drush \
  /var/www/html/web/core/lib/Drupal.php \
  /var/www/html/web/index.php
do
  exists "$path" && pass "present: $path" || fail "missing: $path"
done

# ── 4. --no-dev really means no dev ─────────────────────────────────────────
# Dead weight, and extra attack surface reachable under the docroot.
for devbin in /var/www/html/vendor/bin/phpunit /var/www/html/vendor/bin/phpstan; do
  exists "$devbin" && fail "dev dependency shipped to production: $devbin" \
                   || pass "absent from production: $(basename "$devbin")"
done

# ── 5. Build-context hygiene, asserted on the artifact ──────────────────────
# .dockerignore is the control; this is the verification that the control worked.
# Asserting on the artifact rather than on the ignore file is the point: the
# single-star patterns in .dockerignore do not cross '/', so a rule that looks
# like it covers the repository only ever covered its top level.
leaks="$(run "find /var/www/html -maxdepth 3 \
  \( -name '*.sql' -o -name '*.sql.gz' -o -name '*.tar.gz' -o -name '*.tgz' \
     -o -name '*.zip' -o -name '*.dump' -o -name '.env' -o -name 'settings.local.php' \) \
  -not -path '*/vendor/*' -not -path '*/core/*' -print" || true)"
if [[ -z "$leaks" ]]; then
  pass "no dumps, archives, .env or local settings under the app root"
else
  fail "build context leaked into the image:"
  sed 's/^/      /' <<<"$leaks"
fi

# ── 6. Entrypoint ──────────────────────────────────────────────────────────
if run "test -x /usr/local/bin/docker-entrypoint.sh && echo ok" | grep -q ok; then
  pass "entrypoint present and executable"
else
  fail "entrypoint missing or not executable — the container would start without running updb/cim/cr"
fi

# ── 7. CONTAINER_VERSION ───────────────────────────────────────────────────
cv="$(run 'printf %s "$CONTAINER_VERSION"')"
if [[ -n "$cv" && "$cv" != "unknown" ]]; then
  pass "CONTAINER_VERSION is set ($cv)"
else
  fail "CONTAINER_VERSION is '${cv:-empty}': the entrypoint cannot tell a deploy from a scale-up and would run schema updates on every replica start. Build with --build-arg COMMIT_SHA=<sha>."
fi

# ── 8. Settings overlay wired up ───────────────────────────────────────────
if exists /var/www/html/web/sites/default/settings.azure.php; then
  pass "settings overlay shipped"
else
  fail "settings.azure.php missing from the image"
fi
if run "grep -q 'settings.azure.php' /var/www/html/web/sites/default/settings.php && echo ok" | grep -q ok; then
  pass "settings.php includes the overlay"
else
  fail "settings.php does not include settings.azure.php: the database would be unconfigured at runtime"
fi

# Prove the wiring end to end rather than trusting the grep: load settings.php in
# the image with a synthetic environment and check a database connection actually
# came out of it. This is the check that would have caught the overlay being
# present, referenced, and still not producing a $databases entry.
probe=$(docker run --rm --entrypoint php \
  -e DRUPAL_HASH_SALT=verify -e DRUPAL_DB_HOST=db.invalid -e DRUPAL_DB_NAME=d \
  -e DRUPAL_DB_USER=u -e DRUPAL_DB_PASSWORD=p \
  "$IMAGE" -r '
    $app_root = "/var/www/html/web"; $site_path = "sites/default";
    $databases = []; $settings = []; $config = [];
    include "/var/www/html/web/sites/default/settings.php";
    echo ($databases["default"]["default"]["host"] ?? "NONE") . "|" .
         ($settings["hash_salt"] ?? "NONE") . "|" .
         (empty($settings["trusted_host_patterns"]) ? "NONE" : "SET");
  ' 2>/dev/null || true)
case "$probe" in
  "db.invalid|verify|SET") pass "settings.php produces a database connection, a hash salt and trusted hosts" ;;
  *) fail "loading settings.php in the image yielded '${probe:-nothing}' (expected 'db.invalid|verify|SET')" ;;
esac

# ── 9. php-fpm passes the environment through ──────────────────────────────
# PHP-FPM's default is clear_env=yes, which wipes every environment variable
# before a worker handles a request. The settings overlay reads all of its
# configuration with getenv(), so with the default the site cannot connect to its
# database while drush in the same container connects fine.
if run "php-fpm -tt 2>&1 | grep -qi \"clear_env.*value: 'no'\" && echo ok" | grep -q ok; then
  pass "php-fpm clear_env is off, so getenv() sees the container environment"
elif run "grep -rqi '^ *clear_env *= *no' /usr/local/etc/php-fpm.d/ && echo ok" | grep -q ok; then
  pass "php-fpm clear_env = no is configured"
else
  fail "php-fpm clear_env is not disabled: getenv() would return nothing in a web request"
fi

echo
if (( FAILURES == 0 )); then
  printf '%sAll production image checks passed.%s\n' "$GREEN" "$NC"
  exit 0
fi
printf '%s%d production image check(s) failed.%s\n' "$RED" "$FAILURES" "$NC"
printf '%sThis is the image production would run. Do not deploy it.%s\n' "$YELLOW" "$NC"
exit 1
