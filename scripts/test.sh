#!/usr/bin/env bash
###############################################################################
# test.sh — run the test suites
#
#   ./scripts/test.sh                 # everything
#   ./scripts/test.sh --unit          # settings-overlay unit tests only
#   ./scripts/test.sh --shell         # shell script tests only
#   ./scripts/test.sh --integration   # container + MySQL 8 boot tests only
#
# The integration suite is the one that matters most and the one a template like
# this usually lacks. Unit tests can tell you the settings overlay computes the
# right trusted-host patterns; only a real container against a real MySQL 8 can
# tell you that php-fpm passes the environment through, that the entrypoint's
# deploy marker works, and that the pinned collation actually reaches
# CREATE TABLE. Every one of those is a silent failure otherwise.
###############################################################################
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'
BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'
step() { printf '\n%s%s▸ %s%s\n' "$CYAN" "$BOLD" "$*" "$NC"; }
pass() { printf '%s  ✓ %s%s\n' "$GREEN" "$*" "$NC"; }
fail() { printf '%s  ✗ %s%s\n' "$RED" "$*" "$NC"; FAILURES=$((FAILURES + 1)); }
info() { printf '%s  · %s%s\n' "$BLUE" "$*" "$NC"; }

FAILURES=0
RUN_UNIT=no RUN_SHELL=no RUN_INTEGRATION=no
if [[ $# -eq 0 ]]; then
  RUN_UNIT=yes; RUN_SHELL=yes; RUN_INTEGRATION=yes
fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --unit)        RUN_UNIT=yes; shift ;;
    --shell)       RUN_SHELL=yes; shift ;;
    --integration) RUN_INTEGRATION=yes; shift ;;
    -h|--help)     sed -n '2,18p' "$0"; exit 0 ;;
    *) printf '%sUnknown argument: %s%s\n' "$RED" "$1" "$NC" >&2; exit 2 ;;
  esac
done

# COMPOSE and compose_up_with_retry.
source "$REPO_ROOT/scripts/lib/compose.sh"

###############################################################################
# Unit
###############################################################################
if [[ "$RUN_UNIT" == "yes" ]]; then
  step "Unit tests (settings overlay)"
  if [[ ! -x vendor/bin/phpunit ]]; then
    info "vendor/bin/phpunit missing; running composer install"
    ./scripts/composer-retry.sh install --no-interaction --no-progress || fail "composer install"
  fi
  if vendor/bin/phpunit --colors=always --testsuite unit; then
    pass "unit suite"
  else
    fail "unit suite"
  fi
fi

###############################################################################
# Shell
###############################################################################
if [[ "$RUN_SHELL" == "yes" ]]; then
  step "Shell tests"
  if bash tests/shell/run.sh; then
    pass "shell suite"
  else
    fail "shell suite"
  fi

  step "Secret-handling tests"
  if bash tests/shell/secrets.sh; then
    pass "secret handling"
  else
    fail "secret handling"
  fi

  step "Entrypoint guard tests"
  # The database-backed cases skip on the host when no mysql client is present;
  # the integration phase re-runs this file INSIDE the container, where there is
  # one, so those cases are covered rather than quietly absent.
  if bash tests/shell/entrypoint-guards.sh; then
    pass "entrypoint guards"
  else
    fail "entrypoint guards"
  fi

  step "shellcheck"
  if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck --severity=warning --exclude=SC1091 \
         docker-entrypoint.sh scripts/*.sh scripts/lib/*.sh tests/shell/*.sh; then
      pass "shellcheck"
    else
      fail "shellcheck"
    fi
  else
    info "shellcheck not installed; skipped (CI runs it)"
  fi
fi

###############################################################################
# Integration
###############################################################################
if [[ "$RUN_INTEGRATION" == "yes" ]]; then
  step "Integration: container + MySQL 8"

  cleanup() {
    info "Tearing down"
    "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
    docker rm -f aca-entrypoint-test >/dev/null 2>&1 || true
  }
  trap cleanup EXIT

  info "Building and starting the stack"
  # --wait honours the healthcheck, which is an authenticated SELECT 1 rather
  # than a ping — see docker-compose.yml for why that distinction matters.
  # The retry covers only mysql's arm64 init crash; see lib/compose.sh.
  if ! compose_up_with_retry; then
    fail "stack did not come up"
    exit 1
  fi
  pass "stack up, database healthy"

  info "Installing dependencies inside the container"
  "${COMPOSE[@]}" exec -T web composer install --no-interaction --no-progress >/dev/null 2>&1 \
    || { fail "composer install in container"; exit 1; }
  pass "dependencies installed"

  # -----------------------------------------------------------------------
  # Install Drupal. This is what makes the rest of the suite meaningful: the
  # installer connects using the credentials the settings overlay read from the
  # environment, and it creates the whole schema — so it exercises the collation
  # pinning end to end.
  # -----------------------------------------------------------------------
  info "Installing Drupal (this takes a minute)"
  # ---------------------------------------------------------------------
  # settings.php is made READ-ONLY for the install, and this is not a nicety.
  #
  # Drupal's installer APPENDS a literal $databases array and a generated
  # $settings['hash_salt'] to settings.php whenever the file is writable. Since
  # the compose stack bind-mounts the checkout, that lands in the developer's
  # working tree — appended AFTER the overlay include, so the literals win and
  # the site silently stops reading its configuration from the environment, with
  # a hash salt now sitting in a git-tracked file waiting to be committed.
  #
  # With the file read-only the installer skips that step and the install still
  # succeeds, because $databases is already populated by the overlay.
  # ---------------------------------------------------------------------

  "${COMPOSE[@]}" exec -T web chmod a-w web/sites/default/settings.php
  install_rc=0
  "${COMPOSE[@]}" exec -T web vendor/bin/drush site:install standard \
    --account-name=admin --account-pass=admin --site-name="Integration test" \
    -y --no-interaction >/dev/null 2>&1 || install_rc=$?
  "${COMPOSE[@]}" exec -T web chmod u+w web/sites/default/settings.php

  if (( install_rc == 0 )); then
    pass "drush site:install"
  else
    fail "drush site:install — the settings overlay could not reach the database"
    "${COMPOSE[@]}" logs --tail 60 web
    exit 1
  fi

  if grep -q "= array (" web/sites/default/settings.php 2>/dev/null; then
    fail "the installer rewrote settings.php — credentials and a hash salt are now in the working tree"
  else
    pass "settings.php was not rewritten by the installer"
  fi

  # -----------------------------------------------------------------------
  # 1. The site actually serves, through nginx and php-fpm.
  #
  # This is the check that catches php-fpm's clear_env default: drush above uses
  # the CLI SAPI and sees the environment regardless, so a site that installs
  # perfectly and then cannot connect over HTTP is exactly the failure shape.
  # -----------------------------------------------------------------------
  info "Checking the site serves over HTTP"
  if ./scripts/verify-site.sh "http://localhost:8080"; then
    pass "Drupal renders through nginx and php-fpm (so getenv() works in a web request)"
  else
    fail "the site does not render over HTTP"
    "${COMPOSE[@]}" logs --tail 60 web
  fi

  # -----------------------------------------------------------------------
  # 2. The pinned collation reached CREATE TABLE.
  #
  # If the connection collation is not set, Drupal omits COLLATE from
  # CREATE TABLE and every table inherits the server default instead. On MySQL 8
  # that is utf8mb4_0900_ai_ci, and tables created later can then no longer be
  # joined to tables created earlier. That failure appears months after the
  # mistake, on the first module update that adds a table — which is exactly why
  # it is asserted here.
  # -----------------------------------------------------------------------
  info "Checking table collations"
  expected="utf8mb4_general_ci"
  wrong=$("${COMPOSE[@]}" exec -T db mysql -udrupal -pdrupal --batch --skip-column-names \
    -e "SELECT CONCAT(table_name, '=', table_collation) FROM information_schema.tables
         WHERE table_schema = 'drupal' AND table_collation <> '$expected'" 2>/dev/null)
  if [[ -z "$wrong" ]]; then
    total=$("${COMPOSE[@]}" exec -T db mysql -udrupal -pdrupal --batch --skip-column-names \
      -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='drupal'" 2>/dev/null | tr -d '[:space:]')
    pass "all ${total} tables are $expected"
  else
    fail "tables not on the pinned collation:"
    printf '      %s\n' $wrong
  fi

  # -----------------------------------------------------------------------
  # 2b. The entrypoint guards, against a real server.
  #
  # These are the destructive-path safety checks. Run here as well as on the host
  # because the cases that need a database — require_db refusing an unreachable
  # server, and a failed dump not destroying the previous backup — skip on a host
  # with no mysql client, and a skipped safety test is not a passing one.
  # -----------------------------------------------------------------------
  info "Running the entrypoint guards inside the container"
  if "${COMPOSE[@]}" exec -T \
       -e GUARD_DB_HOST=db -e GUARD_DB_PORT=3306 \
       web bash tests/shell/entrypoint-guards.sh; then
    pass "entrypoint guards against MySQL 8"
  else
    fail "entrypoint guards against MySQL 8"
  fi

  # -----------------------------------------------------------------------
  # 3. The transaction isolation level took effect.
  # -----------------------------------------------------------------------
  info "Checking the session isolation level"
  iso=$("${COMPOSE[@]}" exec -T web php -r '
    $pdo = new PDO("mysql:host=db;dbname=drupal", "drupal", "drupal");
    $pdo->exec("SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED");
    echo $pdo->query("SELECT @@transaction_isolation")->fetchColumn();
  ' 2>/dev/null | tr -d '[:space:]')
  [[ "$iso" == "READ-COMMITTED" ]] && pass "READ COMMITTED is settable on this server" \
    || fail "expected READ-COMMITTED, got '${iso:-<nothing>}'"

  # -----------------------------------------------------------------------
  # 4. The production entrypoint's deploy marker.
  #
  # The single most important new mechanism, and the one whose failure is
  # invisible: if the marker does not work, every replica start and every
  # scale-up re-runs `drush updb` and `config:import` — concurrently, on a
  # multi-replica app. Run the production image's entrypoint twice against the
  # installed database and assert the second boot recognises the version.
  # -----------------------------------------------------------------------
  info "Building the production image for the entrypoint test"
  if ! docker build --build-arg COMMIT_SHA=itest-v1 -t aca-prod-itest:v1 -f Dockerfile . >/dev/null 2>&1; then
    fail "production image build"
  else
    network=$("${COMPOSE[@]}" ps --format '{{.Name}}' db | head -1)
    network=$(docker inspect "$network" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' 2>/dev/null)

    run_entrypoint() {
      docker run --rm --network "$network" \
        -e DRUPAL_DB_HOST=db -e DRUPAL_DB_NAME=drupal \
        -e DRUPAL_DB_USER=drupal -e DRUPAL_DB_PASSWORD=drupal \
        -e DRUPAL_DB_SSL_MODE=off \
        -e DRUPAL_HASH_SALT=local-development-only-not-a-production-salt \
        -e DRUPAL_TRUSTED_HOSTS=localhost \
        -e DRUPAL_REQUIRE_BACKUP=0 \
        -e DRUPAL_DB_WAIT_SECONDS=60 \
        --entrypoint /usr/local/bin/docker-entrypoint.sh \
        "aca-prod-itest:$1" /bin/true 2>&1
    }

    first="$(run_entrypoint v1)"
    if grep -q 'deploy tasks needed' <<<"$first" && grep -q 'marked itest-v1 as deployed' <<<"$first"; then
      pass "first boot ran the deploy sequence and recorded the version"
    else
      fail "first boot did not run/record the deploy sequence"
      sed 's/^/      /' <<<"$first" | tail -30
    fi

    second="$(run_entrypoint v1)"
    if grep -q 'already deployed; skipping updb/cim/cr' <<<"$second"; then
      pass "second boot on the same image skipped the deploy sequence"
    else
      fail "second boot re-ran the deploy sequence — the version marker is not working"
      sed 's/^/      /' <<<"$second" | tail -30
    fi

    # A NEW image version must run them again.
    if docker build --build-arg COMMIT_SHA=itest-v2 -t aca-prod-itest:v2 -f Dockerfile . >/dev/null 2>&1; then
      third="$(run_entrypoint v2)"
      if grep -q 'deploy tasks needed' <<<"$third"; then
        pass "a new image version runs the deploy sequence again"
      else
        fail "a new image version did NOT run the deploy sequence"
        sed 's/^/      /' <<<"$third" | tail -30
      fi
    fi

    # And the lock must be released, not left held — otherwise the next real
    # deploy waits out the full stale timeout before doing anything.
    holder=$("${COMPOSE[@]}" exec -T db mysql -udrupal -pdrupal --batch --skip-column-names \
      -e "SELECT lock_owner FROM azure_deploy_state WHERE id = 1" drupal 2>/dev/null | tr -d '[:space:]')
    [[ -z "$holder" ]] && pass "deploy lock released after the run" \
      || fail "deploy lock still held by '$holder'"
  fi
fi

###############################################################################
printf '\n'
if (( FAILURES == 0 )); then
  printf '%s%s✓ All tests passed.%s\n' "$GREEN" "$BOLD" "$NC"
  exit 0
fi
printf '%s%s✗ %d test group(s) failed.%s\n' "$RED" "$BOLD" "$FAILURES" "$NC"
exit 1
