#!/usr/bin/env bash
###############################################################################
# local-dev.sh — bring up the local stack
#
#   ./scripts/local-dev.sh              # up, install dependencies, install Drupal
#   ./scripts/local-dev.sh --reset      # wipe the database volume first
#   ./scripts/local-dev.sh --import <file.sql.gz>   # import a dump instead of installing
#   ./scripts/local-dev.sh --down       # stop, keep the database
#   ./scripts/local-dev.sh --shell      # a shell inside the web container
#
# The local stack runs MySQL 8 with production's collation and sql_mode, not
# MariaDB with defaults — see docker-compose.yml for why. The point of a local
# environment is to reproduce failures, and a database that differs from
# production in exactly the ways Drupal is sensitive to cannot do that.
###############################################################################
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; RED=$'\033[0;31m'
BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'
step() { printf '\n%s%s▸ %s%s\n' "$CYAN" "$BOLD" "$*" "$NC"; }
ok()   { printf '%s  ✓ %s%s\n' "$GREEN" "$*" "$NC"; }
info() { printf '%s  · %s%s\n' "$BLUE" "$*" "$NC"; }
warn() { printf '%s  ! %s%s\n' "$YELLOW" "$*" "$NC"; }
err()  { printf '%s  ✗ %s%s\n' "$RED" "$*" "$NC" >&2; }

source "$REPO_ROOT/scripts/lib/compose.sh"

MODE=up; IMPORT_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reset)  MODE=reset; shift ;;
    --down)   MODE=down; shift ;;
    --shell)  MODE=shell; shift ;;
    --import) MODE=up; IMPORT_FILE="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) err "Unknown argument: $1"; exit 1 ;;
  esac
done

case "$MODE" in
  down)
    step "Stopping"
    # Without -v, so the database volume survives and the next `up` resumes
    # instantly. `--down` is for closing the laptop, not for starting over;
    # `--reset` is for starting over.
    "${COMPOSE[@]}" down
    ok "Stopped. The database volume was kept — use --reset to discard it."
    exit 0
    ;;
  shell)
    exec "${COMPOSE[@]}" exec web bash
    ;;
  reset)
    step "Discarding the database volume"
    "${COMPOSE[@]}" down -v
    ok "Volumes removed"
    ;;
esac

step "Starting the stack"
# --wait blocks on the healthcheck, which is an authenticated SELECT 1 rather
# than a ping: MySQL's own entrypoint runs a temporary server while it
# initialises the data directory, and a ping succeeds against that, before the
# application user exists.
#
# compose_up_with_retry rather than a bare `up`, because mysql:8.0 on arm64
# intermittently segfaults initialising a fresh volume — and a first-time user
# cannot tell that apart from a broken template. See lib/compose.sh.
compose_up_with_retry || exit 1
ok "Web and database up"

step "Installing Composer dependencies"
# Inside the container, so the vendor tree is built against the container's PHP
# and extension set rather than the host's.
"${COMPOSE[@]}" exec -T web ./scripts/composer-retry.sh install --no-interaction --no-progress
ok "Dependencies installed"

if [[ -n "$IMPORT_FILE" ]]; then
  step "Importing $IMPORT_FILE"
  [[ -f "$IMPORT_FILE" ]] || { err "No such file: $IMPORT_FILE"; exit 1; }

  # NO_AUTO_VALUE_ON_ZERO is required, not optional. Drupal's anonymous user is
  # uid 0; without it MySQL treats an inserted 0 in an AUTO_INCREMENT column as
  # "next value please" and the anonymous user silently becomes uid 1 —
  # colliding with the admin account, so anonymous visitors appear to be logged
  # in as the administrator.
  reader=(cat); [[ "$IMPORT_FILE" == *.gz ]] && reader=(gzip -dc)
  {
    echo "SET SESSION sql_mode='NO_AUTO_VALUE_ON_ZERO';"
    echo "SET SESSION FOREIGN_KEY_CHECKS=0;"
    "${reader[@]}" "$IMPORT_FILE"
  } | "${COMPOSE[@]}" exec -T db mysql -udrupal -pdrupal --default-character-set=utf8mb4 drupal
  ok "Imported"

  step "Bringing the site up to the current code"
  "${COMPOSE[@]}" exec -T web vendor/bin/drush updb -y
  if compgen -G "config/sync/*.yml" >/dev/null; then
    "${COMPOSE[@]}" exec -T web vendor/bin/drush config:import -y
  fi
  "${COMPOSE[@]}" exec -T web vendor/bin/drush cache:rebuild
  ok "Schema and configuration applied"
else
  # Is Drupal already installed in this database?
  if "${COMPOSE[@]}" exec -T web vendor/bin/drush status --fields=bootstrap 2>/dev/null | grep -q Successful; then
    info "Drupal is already installed; leaving it alone."
    step "Applying pending updates"
    "${COMPOSE[@]}" exec -T web vendor/bin/drush updb -y
    "${COMPOSE[@]}" exec -T web vendor/bin/drush cache:rebuild
  else
    step "Installing Drupal"
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
      --account-name=admin --account-pass=admin \
      --site-name="Local development" -y || install_rc=$?
    "${COMPOSE[@]}" exec -T web chmod u+w web/sites/default/settings.php
    (( install_rc == 0 )) || { err "drush site:install failed"; exit 1; }
    ok "Installed (admin / admin)"
  fi
fi

step "Verifying"
if ./scripts/verify-site.sh "http://localhost:8080"; then
  echo ""
  printf '%s%s  http://localhost:8080%s\n' "$GREEN" "$BOLD" "$NC"
  printf '  Database on 127.0.0.1:13306 (drupal / drupal)\n\n'
  printf '  drush:  %s exec web vendor/bin/drush <command>\n' "${COMPOSE[*]}"
  printf '  logs:   %s logs -f web\n' "${COMPOSE[*]}"
  printf '  shell:  ./scripts/local-dev.sh --shell\n'
  printf '  tests:  ./scripts/test.sh\n\n'
else
  warn "The stack is up but the site is not serving. Logs:"
  "${COMPOSE[@]}" logs --tail 60 web
  exit 1
fi
