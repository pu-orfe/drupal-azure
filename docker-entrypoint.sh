#!/usr/bin/env bash
###############################################################################
# docker-entrypoint.sh — Drupal container boot sequence for Azure Container Apps
#
# Runs the deploy-time database work *inside the container*, once per image, then
# hands off to the web server (`exec "$@"`).
#
# WHY THIS EXISTS AT ALL
#
# The previous pipeline ran `drush updb` and `drush cr` from GitHub Actions via
# `az containerapp exec` after the revision went live. Three problems with that:
#
#   1. `az containerapp exec` opens an interactive websocket to *some* replica.
#      It is not a job runner: it has no exit-code contract the workflow can
#      trust, so the steps were written `|| echo "failed"` and a failed schema
#      update produced a green deploy.
#   2. It never ran `drush config:import`, so exported configuration in
#      config/sync was baked into the image and then ignored. The site's actual
#      config drifted from the repo indefinitely.
#   3. It runs *after* traffic has shifted, so requests hit the new code against
#      the old schema for the duration.
#
# Doing it in the entrypoint fixes all three: the work happens before the
# container starts listening, a non-zero exit fails the revision, and Container
# Apps will not shift traffic to a revision that never became healthy.
#
# THE TWO THINGS THAT MAKE THIS SAFE ON CONTAINER APPS
#
# Container Apps runs N replicas and scales to zero, so unlike a single-instance
# App Service this entrypoint can run concurrently on several containers and can
# run on a cold start that is not a deploy at all. Hence:
#
#   * A version marker in the database. Deploy tasks run only when the image's
#     CONTAINER_VERSION differs from the recorded one. A scale-up on an unchanged
#     image skips straight to serving. Keeping the marker in the database rather
#     than on disk matters: a replica's filesystem is not shared, so a file
#     marker would make every replica re-run updb, and the marker belongs with
#     the schema it describes anyway.
#   * A database-backed lock. Exactly one replica performs the work; the others
#     wait for it to finish and then serve. Without this, two replicas can run
#     `drush updb` against the same schema simultaneously.
#
# See docs/operations.md for the operator-facing side of this (forcing a run,
# reading the marker, recovering a stuck lock).
###############################################################################
# DB_HOST, DB_PORT, DB_USER, DB_PASSWORD, DB_NAME and MYSQL_TLS_ARGS are read by
# db_flags_init() and the guards in docker/entrypoint-lib.sh. shellcheck cannot
# follow them across a `source`, so it reports each as unused.
#
# This directive must appear BEFORE the first command to apply to the whole file.
# Placed later it silently covers only the next line — which is how it stopped
# working once a block was inserted after it.
# shellcheck disable=SC2034

# -E so an ERR trap would inherit into functions; -o pipefail because the backup
# guards depend on it. Without pipefail, `if mysqldump | gzip > f; then` tests
# GZIP's exit status and a failed dump reports success — see entrypoint-lib.sh.
set -Eeuo pipefail

# Guards for the destructive and secret-handling paths, in their own file so a
# test can drive them. tests/shell/entrypoint-guards.sh does exactly that.
LIB_DIR="${LIB_DIR:-/usr/local/lib/drupal-azure}"
# shellcheck source=docker/entrypoint-lib.sh
source "${LIB_DIR}/entrypoint-lib.sh"

die() { printf '[entrypoint] ERROR: %s\n' "$*" >&2; exit 1; }

APP_ROOT="${APP_ROOT:-/var/www/html}"
DRUSH="${APP_ROOT}/vendor/bin/drush"
CONTAINER_VERSION="${CONTAINER_VERSION:-unknown}"

DB_HOST="${DRUPAL_DB_HOST:-}"
DB_PORT="${DRUPAL_DB_PORT:-3306}"
DB_NAME="${DRUPAL_DB_NAME:-drupal}"
DB_USER="${DRUPAL_DB_USER:-}"
DB_PASSWORD="${DRUPAL_DB_PASSWORD:-}"
DB_PREFIX="${DRUPAL_DB_PREFIX:-}"

# Where the pre-deploy dump goes. Must be a mounted share to survive the
# replica; /var/www/html/private is the drupal-private Azure Files mount.
# ---------------------------------------------------------------------------
# Where boot state goes.
#
# App Service provides /home: persistent, shared across instances, and mounted
# automatically when WEBSITES_ENABLE_APP_SERVICE_STORAGE is on. Container Apps
# provides nothing of the kind, so the equivalent is a directory on the mounted
# private Azure Files share.
#
# WEBSITE_SITE_NAME is set by App Service and by nothing else, which makes it a
# reliable platform discriminator. The Bicep templates set both variables
# explicitly; this detection is the fallback that keeps a manual `docker run` and
# an ad-hoc container correct rather than silently writing to a path that
# disappears.
# ---------------------------------------------------------------------------
if [[ -n "${WEBSITE_SITE_NAME:-}" ]]; then
  _default_state_dir="/home"
else
  _default_state_dir="${APP_ROOT}/private"
fi

BACKUP_DIR="${DRUPAL_BACKUP_DIR:-${_default_state_dir}/deploy-backups}"

# A machine-readable record of what this boot did, with a per-step exit code and
# a fingerprint of each secret the container is holding. Written to the shared
# private mount so it outlives the replica and so an operator can answer "did
# the config import actually run, and is this replica using the rotated
# password?" without reading a log. Logs answer neither reliably.
BOOT_RESULT_PATH="${DRUPAL_BOOT_RESULT:-${_default_state_dir}/boot-result-${HOSTNAME:-local}.json}"

# How long a waiting replica will sit behind the lock before giving up and
# serving anyway. A replica that serves the previous schema is strictly better
# than a replica that never becomes healthy; the ingress still has the old
# revision to fall back on.
LOCK_WAIT_SECONDS="${DRUPAL_LOCK_WAIT_SECONDS:-600}"
# After this long a held lock is presumed abandoned (replica evicted mid-run)
# and may be taken over. Must exceed the longest plausible updb.
LOCK_STALE_SECONDS="${DRUPAL_LOCK_STALE_SECONDS:-1800}"

DB_WAIT_SECONDS="${DRUPAL_DB_WAIT_SECONDS:-120}"

# The lock/marker table. Deliberately outside Drupal's prefix and schema so
# `drush updb`, a config import, or a full database restore never touches it.
LOCK_TABLE="azure_deploy_state"

# A stable-enough identity for the lock holder. HOSTNAME is the replica name
# under Container Apps.
LOCK_OWNER="${HOSTNAME:-unknown}-$$"

###############################################################################
# TLS for the mysql/mysqldump clients.
#
# Azure Database for MySQL Flexible Server ships with require_secure_transport
# ON, and it should stay on — the connection crosses a VNet, not a loopback.
# Turning it off (which is a documented workaround in a lot of Azure/Drupal
# writeups) removes transport encryption for every client of the server, not
# just this one.
#
# DRUPAL_DB_SSL_MODE:
#   verify  (default) encrypt and verify the server certificate against the
#           system CA bundle. Azure's chain roots in DigiCert Global Root, which
#           is in ca-certificates, so this needs no downloaded PEM.
#   on      encrypt without verifying — for a server presenting a private CA.
#   off     no TLS. Only for a local MariaDB in docker-compose.
###############################################################################
MYSQL_TLS_ARGS=()
case "${DRUPAL_DB_SSL_MODE:-verify}" in
  verify) MYSQL_TLS_ARGS=(--ssl-ca="${DRUPAL_DB_SSL_CA:-/etc/ssl/certs/ca-certificates.crt}" --ssl-verify-server-cert) ;;
  on)     MYSQL_TLS_ARGS=(--ssl) ;;
  off)    MYSQL_TLS_ARGS=(--skip-ssl) ;;
  *)      die "DRUPAL_DB_SSL_MODE must be verify, on or off (got '${DRUPAL_DB_SSL_MODE}')" ;;
esac

# Exported once, for every mysql/mysqldump invocation below and inside the
# guards. Via the environment, never argv: argv is world-readable in /proc, so
# `mysql -p"$PASSWORD"` publishes the credential to every process in the
# container for the lifetime of the command.
export MYSQL_PWD="$DB_PASSWORD"
db_flags_init

run_sql() {
  local sql="$1"
  mysql "${DB_FLAGS[@]}" --batch --skip-column-names "$DB_NAME" -e "$sql"
}

###############################################################################
# 0. Reject secrets that did not resolve.
#
# Before anything tries to USE them, because the failure modes are quiet: an
# unresolved Key Vault reference arrives as its own literal text, which
# authenticates as nothing and hashes as something.
###############################################################################
require_resolved_secret DRUPAL_DB_PASSWORD "$DB_PASSWORD" \
  || die "DRUPAL_DB_PASSWORD did not resolve. See docs/secrets.md."
require_resolved_secret DRUPAL_HASH_SALT "${DRUPAL_HASH_SALT:-}" \
  || die "DRUPAL_HASH_SALT did not resolve. See docs/secrets.md."
log "Secrets resolved. db_password=$(secret_fingerprint "$DB_PASSWORD") hash_salt=$(secret_fingerprint "${DRUPAL_HASH_SALT:-}")"


###############################################################################
# 1. Wait for the database.
#
# The readiness probe is an authenticated `SELECT 1`, not a ping. A ping (or a
# bare TCP connect) succeeds against a server that is up but not yet accepting
# this account — most visibly against the temporary server MySQL's own container
# entrypoint runs while it initialises a fresh data directory. Gating on ping
# therefore races, and the next statement fails with "Access denied".
###############################################################################
db_ready=no
if [[ -n "$DB_HOST" ]]; then
  log "Waiting up to ${DB_WAIT_SECONDS}s for ${DB_HOST}:${DB_PORT}/${DB_NAME}"
  deadline=$(( SECONDS + DB_WAIT_SECONDS ))
  while (( SECONDS < deadline )); do
    if run_sql "SELECT 1" >/dev/null 2>&1; then
      db_ready=yes
      break
    fi
    sleep 3
  done
  if [[ "$db_ready" == "yes" ]]; then
    log "Database reachable."
  else
    # Not fatal. The container should still come up and serve Drupal's own
    # "database unavailable" page, which is diagnosable; a crash-looping replica
    # with no HTTP surface is not. The deploy tasks below are skipped.
    warn "Database not reachable after ${DB_WAIT_SECONDS}s. Starting the web server without running deploy tasks."
  fi
else
  warn "DRUPAL_DB_HOST is unset; skipping all database work."
fi

###############################################################################
# 2. Decide whether this boot needs to run deploy tasks.
###############################################################################
needs_deploy=no
lock_held=no

ensure_state_table() {
  # Single row, id=1. `owner=''` means unlocked.
  run_sql "
    CREATE TABLE IF NOT EXISTS \`${LOCK_TABLE}\` (
      id TINYINT UNSIGNED NOT NULL PRIMARY KEY,
      lock_owner VARCHAR(190) NOT NULL DEFAULT '',
      locked_at DATETIME NULL,
      deployed_version VARCHAR(190) NOT NULL DEFAULT '',
      deployed_at DATETIME NULL
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    INSERT IGNORE INTO \`${LOCK_TABLE}\` (id) VALUES (1);
  "
}

deployed_version() {
  run_sql "SELECT deployed_version FROM \`${LOCK_TABLE}\` WHERE id = 1"
}

# Atomic acquire. The UPDATE takes a row lock, so of N replicas issuing it
# concurrently exactly one sees ROW_COUNT() = 1. Reading ROW_COUNT() in the same
# session as the UPDATE is what makes "did I win?" answerable without a race.
acquire_lock() {
  local won
  won=$(run_sql "
    UPDATE \`${LOCK_TABLE}\`
       SET lock_owner = '${LOCK_OWNER}', locked_at = UTC_TIMESTAMP()
     WHERE id = 1
       AND (lock_owner = ''
            OR locked_at IS NULL
            OR locked_at < UTC_TIMESTAMP() - INTERVAL ${LOCK_STALE_SECONDS} SECOND);
    SELECT ROW_COUNT();
  " | tail -n1)
  [[ "$won" == "1" ]]
}

release_lock() {
  [[ "$lock_held" == "yes" ]] || return 0
  # Scoped to this owner so a stale-takeover by another replica is not undone.
  run_sql "UPDATE \`${LOCK_TABLE}\` SET lock_owner = '', locked_at = NULL
            WHERE id = 1 AND lock_owner = '${LOCK_OWNER}'" >/dev/null 2>&1 || true
  lock_held=no
}
trap release_lock EXIT

if [[ "$db_ready" == "yes" ]]; then
  if [[ "${DRUPAL_SKIP_DEPLOY_TASKS:-0}" == "1" ]]; then
    log "DRUPAL_SKIP_DEPLOY_TASKS=1; not running deploy tasks."
  elif [[ ! -x "$DRUSH" ]]; then
    warn "$DRUSH is missing or not executable; cannot run deploy tasks."
  else
    ensure_state_table
    recorded="$(deployed_version || true)"

    if [[ "${DRUPAL_FORCE_DEPLOY_TASKS:-0}" == "1" ]]; then
      log "DRUPAL_FORCE_DEPLOY_TASKS=1; deploy tasks will run."
      needs_deploy=yes
    elif [[ "$CONTAINER_VERSION" == "unknown" ]]; then
      # An image built without --build-arg COMMIT_SHA cannot be compared, so it
      # must be treated as new. Erring towards running is the safe direction: a
      # redundant updb is a no-op, a skipped one ships code against a stale
      # schema.
      warn "CONTAINER_VERSION is 'unknown' (image built without COMMIT_SHA); running deploy tasks unconditionally."
      needs_deploy=yes
    elif [[ "$CONTAINER_VERSION" != "$recorded" ]]; then
      log "Image version ${CONTAINER_VERSION} != deployed ${recorded:-<none>}; deploy tasks needed."
      needs_deploy=yes
    else
      log "Image version ${CONTAINER_VERSION} already deployed; skipping updb/cim/cr."
    fi
  fi
fi

###############################################################################
# 3. Run them, under the lock.
###############################################################################
if [[ "$needs_deploy" == "yes" ]]; then
  if acquire_lock; then
    lock_held=yes
    log "Deploy lock acquired by ${LOCK_OWNER}."

    # ── 3a. Recover a container that cannot bootstrap ────────────────────────
    # A cached service container built by a previous image can be structurally
    # incompatible with the new code, and Drupal cannot clear that cache without
    # first bootstrapping through it. Truncating the cache tables directly is
    # the way out. Restricted to Drupal's own cache tables via the configured
    # prefix so it cannot touch anything else sharing the database.
    if ! drupal_bootstraps "$DRUSH"; then
      warn "Drupal did not bootstrap. Truncating cache tables to clear a stale service container."
      truncations="$(run_sql "SHOW TABLES LIKE '${DB_PREFIX}cache\\_%'" 2>/dev/null \
        | awk -v q='`' '{print "TRUNCATE TABLE " q $1 q ";"}' || true)"
      if [[ -n "$truncations" ]]; then
        run_sql "$truncations" || warn "Cache truncation did not complete; continuing."
      else
        warn "No cache tables found to truncate."
      fi
    fi

    if drupal_bootstraps "$DRUSH"; then
      # ── 3b. Pre-deploy backup ─────────────────────────────────────────────
      # Timestamped, not a single overwritten slot. A single slot is worthless
      # for the case that actually needs it: a two-deploy change where the
      # second deploy destroys the snapshot taken before the first.
      #
      # Taken through safe_dump, which writes to a .partial and publishes only
      # after the archive VALIDATES. The naive form —
      #
      #     if mysqldump ... | gzip > "$dump"; then log "backed up"; fi
      #
      # is wrong twice over. Without `pipefail` it tests gzip's exit status, and
      # gzip happily compresses mysqldump's error message; and even with
      # pipefail, writing straight to the destination means a failed dump
      # overwrites the last good backup with a valid, useless ~20-byte gzip.
      backup_ok=no
      if mkdir -p "$BACKUP_DIR" 2>/dev/null; then
        dump="${BACKUP_DIR}/pre-deploy-$(date -u '+%Y%m%dT%H%M%SZ')-${CONTAINER_VERSION:0:12}.sql.gz"
        log "Taking pre-deploy backup to ${dump}"
        if require_db "pre-deploy backup" && safe_dump "$dump" "pre-deploy backup"; then
          backup_ok=yes
          # Keep the last N. Unbounded dumps silently fill the file share, and a
          # full share breaks uploads, not just backups.
          keep="${DRUPAL_BACKUP_KEEP:-10}"
          ls -1t "$BACKUP_DIR"/pre-deploy-*.sql.gz 2>/dev/null \
            | tail -n "+$((keep + 1))" | xargs -r rm -f
        fi
      else
        warn "Backup directory ${BACKUP_DIR} is not writable."
      fi

      if [[ "$backup_ok" != "yes" ]]; then
        # Refusing is the point. Running one-directional schema updates with no
        # verified way back is the single thing worth stopping a boot over.
        # DRUPAL_REQUIRE_BACKUP=0 exists for a first deploy with no share yet.
        if [[ "${DRUPAL_REQUIRE_BACKUP:-1}" == "1" ]]; then
          record_step "pre_deploy_backup" 1
          boot_result_write "$BOOT_RESULT_PATH" failed
          die "No validated pre-deploy backup, and DRUPAL_REQUIRE_BACKUP=1. Refusing to run schema updates."
        fi
        warn "Continuing without a validated backup because DRUPAL_REQUIRE_BACKUP=0."
        record_step "pre_deploy_backup" 1
        BOOT_STATUS=degraded
      else
        record_step "pre_deploy_backup" 0
      fi

      # ── 3c. The deploy sequence ───────────────────────────────────────────
      # Order is load-bearing: updb brings the schema up to what the new code
      # expects, cim then applies configuration against that schema, cr rebuilds
      # the container last. Running cim before updb fails whenever a config
      # change depends on a schema change.
      #
      # Every step is `critical`, which means a failure records its exit code AND
      # withholds the version marker, so the next boot retries rather than
      # skipping. Nothing is `|| true`: a failed updb and a successful one must
      # not produce identical logs.
      run_step critical updb          "$DRUSH" updb -y --no-cache-clear

      if [[ -d "${APP_ROOT}/config/sync" ]] && compgen -G "${APP_ROOT}/config/sync/*.yml" >/dev/null; then
        run_step critical config_import "$DRUSH" config:import -y
      else
        log "config/sync is empty; skipping config:import."
        record_step "config_import" 0
      fi

      run_step critical cache_rebuild "$DRUSH" cache:rebuild

      # ── 3d. Record the outcome ────────────────────────────────────────────
      # The marker is stamped ONLY if no critical step failed, so a partial
      # deploy is retried by the next boot rather than remembered as done.
      if [[ "$CRITICAL_FAILED" == "true" ]]; then
        boot_result_write "$BOOT_RESULT_PATH" failed
        die "A critical deploy step failed. The version marker was NOT stamped; the next boot will retry. See $BOOT_RESULT_PATH."
      fi

      run_sql "UPDATE \`${LOCK_TABLE}\`
                  SET deployed_version = '${CONTAINER_VERSION}', deployed_at = UTC_TIMESTAMP()
                WHERE id = 1"
      log "Deploy tasks complete; marked ${CONTAINER_VERSION} as deployed."
      boot_result_write "$BOOT_RESULT_PATH" "$BOOT_STATUS"
    else
      warn "Drupal still cannot bootstrap. Not running updb/cim/cr; the site is probably uninstalled."
      warn "Install it or import a database, then restart the revision. See docs/operations.md."
    fi

    release_lock
  else
    # ── Another replica is doing the work. Wait for it, then serve. ──────────
    log "Another replica holds the deploy lock; waiting up to ${LOCK_WAIT_SECONDS}s."
    deadline=$(( SECONDS + LOCK_WAIT_SECONDS ))
    while (( SECONDS < deadline )); do
      sleep 5
      if [[ "$(deployed_version || true)" == "$CONTAINER_VERSION" ]]; then
        log "Peer replica finished the deploy."
        break
      fi
    done
    if [[ "$(deployed_version || true)" != "$CONTAINER_VERSION" ]]; then
      warn "Deploy did not complete within ${LOCK_WAIT_SECONDS}s. Serving anyway; check the peer replica's logs."
    fi
  fi
fi

###############################################################################
# 4. Permissions, then hand off.
###############################################################################
# Ensure the mount points exist and are writable. Deliberately NOT `chown -R`.
#
# Two reasons, and the first is the expensive one:
#
#   * These are SMB mounts. A recursive chown walks and stats every file over the
#     network, so on a share holding a few hundred thousand uploads it takes
#     minutes — on EVERY replica start, including a scale-up that has no other
#     work to do. It is a straightforward way to make autoscaling useless.
#   * It would not achieve anything anyway. An Azure Files SMB share is mounted
#     with a fixed uid/gid/mode from the mount options; chown on it is a no-op
#     that returns success, or fails outright, depending on the mount.
#
# So: create the directory if it is missing (which matters when no share is
# mounted, as in a local `docker run` or the image gate), and verify writability
# rather than trying to impose it. Drupal's own status report is the right place
# to notice a genuinely unwritable files directory.
for d in "${APP_ROOT}/web/sites/default/files" "${APP_ROOT}/private"; do
  mkdir -p "$d" 2>/dev/null || true
  # Only chown when the directory is empty — i.e. it was just created, or no
  # share is mounted over it. Cheap, and it covers the case the recursive form
  # was there for.
  if [[ -d "$d" ]] && [[ -z "$(ls -A "$d" 2>/dev/null)" ]]; then
    chown www-data:www-data "$d" 2>/dev/null || true
  fi
  if ! su -s /bin/sh -c "test -w '$d'" www-data 2>/dev/null; then
    warn "$d is not writable by www-data. Uploads and aggregated assets will fail."
  fi
done

log "Starting: $*"
exec "$@"
