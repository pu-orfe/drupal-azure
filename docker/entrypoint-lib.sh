#!/usr/bin/env bash
###############################################################################
# entrypoint-lib.sh — guard functions for docker-entrypoint.sh
#
# These live in their own sourceable file for one reason: they are the safety net
# around a data-destroying operation, and a safety net no test ever executes is
# not a safety net. tests/shell/entrypoint-guards.sh sources this file and drives
# it, including the case that matters most — the ~20-byte gzip that a FAILED
# `mysqldump | gzip` leaves behind, which every naive check accepts.
#
# Callers must already have run `set -Eeuo pipefail`. `pipefail` is not optional:
# without it,
#
#     if mysqldump ... | gzip > out; then echo "backed up"; fi
#
# tests GZIP's exit status, not mysqldump's. gzip succeeds at compressing an
# error message, so a failed dump reports success and writes a valid, tiny,
# useless archive over the top of the last good one.
###############################################################################

# Defaults, so `set -u` cannot abort a boot over an unset optional variable and
# so this file can be sourced standalone by the test harness.
: "${DB_HOST:=}"
: "${DB_PORT:=3306}"
: "${DB_USER:=}"
: "${DB_PASSWORD:=}"
: "${DB_NAME:=}"
: "${CONTAINER_VERSION:=unknown}"

# ---------------------------------------------------------------------------
# Two status variables, deliberately not one.
#
# BOOT_STATUS answers "was this boot clean?" — any failed step degrades it.
# CRITICAL_FAILED answers the narrower and more consequential question, "must the
# NEXT boot retry the schema and config work?" Only retry-worthy steps set it.
#
# Conflating them is a real defect with an expensive symptom: a tolerated step
# that fails routinely (an offsite upload, a cache warm) would prevent the image
# marker from being stamped, so every subsequent replica start re-ran
# updb/cim/cr AND took a fresh pre-deploy backup — overwriting the very rollback
# point the previous deploy left behind.
# ---------------------------------------------------------------------------
: "${BOOT_STATUS:=ok}"
: "${CRITICAL_FAILED:=false}"

# A size floor for a gzipped Drupal dump. A failed `mysqldump | gzip` writes a
# VALID gzip of about 20 bytes, so size is a genuine signal. 200 KB sits far
# below any real Drupal database (a bare standard-profile install gzips to well
# over 1 MB) and far above the stub, so ordinary growth or shrinkage never trips
# it. Override for a deliberately tiny site.
: "${DUMP_MIN_BYTES:=200000}"

declare -a BOOT_STEPS=()

log()  { printf '[entrypoint] %s\n' "$*"; }
warn() { printf '[entrypoint] WARNING: %s\n' "$*" >&2; }

# Rebuilt as a function so a test harness can repoint the guards after sourcing.
db_flags_init() {
  # Password via MYSQL_PWD (exported by the caller), never argv: argv is
  # world-readable in /proc, so `-p"$PASSWORD"` publishes the credential to every
  # process in the container for the lifetime of the command.
  DB_FLAGS=(
    --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USER"
    --default-character-set=utf8mb4
  )
  if [[ -n "${MYSQL_TLS_ARGS[*]:-}" ]]; then
    DB_FLAGS+=("${MYSQL_TLS_ARGS[@]}")
  fi
}

# ---------------------------------------------------------------------------
# A short, non-reversible fingerprint of a secret.
#
# This exists to answer a question the platform will not: not "was the secret
# rotated in the vault" but "is the value THIS CONTAINER HOLDS the new one".
# Those are different statements, and every managed-secret system blurs them —
# App Service caches a resolved Key Vault reference and reports it as "Resolved"
# whether or not the container has the newest version; Container Apps resolves at
# replica start, so a rotation is invisible to replicas that are already running.
#
# Publishing a truncated digest makes the distinction observable without ever
# printing the value: rotate, restart, compare the fingerprint. Sixteen hex
# characters is enough to tell two values apart and no more than is needed.
# ---------------------------------------------------------------------------
secret_fingerprint() { # secret_fingerprint <value>
  if [[ -z "${1:-}" ]]; then
    printf 'unset'
    return 0
  fi
  printf '%s' "$1" | sha256sum 2>/dev/null | cut -c1-16 \
    || printf '%s' "$1" | shasum -a 256 | cut -c1-16
}

record_step() { # record_step <name> <exit-code>
  BOOT_STEPS+=("    \"$1\": $2")
}

# ---------------------------------------------------------------------------
# Run a step, record its exit code, complain loudly, and do NOT abort the boot.
#
# This replaces `command || echo "warning: ..."`, which discards the exit code
# entirely — a failed `drush config:import` and a successful one produced
# indistinguishable logs and left no machine-readable record of which happened.
# ---------------------------------------------------------------------------
run_step() { # run_step <critical|tolerated> <name> <command...>
  local criticality="$1" name="$2"; shift 2
  local code=0
  log "--- step: $name ($criticality) ---"
  if "$@"; then code=0; else code=$?; fi
  record_step "$name" "$code"
  if (( code != 0 )); then
    warn "step '$name' exited $code. Recorded, not swallowed."
    BOOT_STATUS="degraded"
    if [[ "$criticality" == "critical" ]]; then
      warn "'$name' is critical — the deployed-image marker will NOT be stamped, so"
      warn "the next container start retries it instead of skipping it."
      CRITICAL_FAILED=true
    else
      log "'$name' is tolerated — it does not force a retry of the schema work."
    fi
  fi
  return 0
}

boot_result_write() { # boot_result_write <path> <status>
  local path="$1" status="$2" body="" i last
  # Joined by hand rather than with "${BOOT_STEPS[*]}" and a multi-character IFS:
  # bash joins on the FIRST character of IFS only, which collapses the whole
  # object onto one line. Valid JSON, unreadable in a log.
  last=$(( ${#BOOT_STEPS[@]} - 1 ))
  for i in "${!BOOT_STEPS[@]}"; do
    body+="${BOOT_STEPS[$i]}"
    (( i < last )) && body+=","
    body+=$'\n'
  done
  body="${body%$'\n'}"
  mkdir -p "$(dirname "$path")" 2>/dev/null || true
  cat > "$path" <<JSON || return 0
{
  "schema": 1,
  "status": "$status",
  "container_version": "$CONTAINER_VERSION",
  "replica": "${HOSTNAME:-unknown}",
  "finished_utc": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "db_host": "$DB_HOST",
  "critical_failed": $CRITICAL_FAILED,
  "hash_salt_fingerprint": "$(secret_fingerprint "${DRUPAL_HASH_SALT:-}")",
  "db_password_fingerprint": "$(secret_fingerprint "$DB_PASSWORD")",
  "steps": {
$body
  }
}
JSON
  log "Boot result ($status) written to $path"
}

# ---------------------------------------------------------------------------
# An authenticated SELECT 1 against the actual database.
#
# `mysqladmin ping` and a bare connect are both unacceptable substitutes: each
# succeeds in states where the very next statement fails. MySQL's own container
# entrypoint answers a ping from a temporary server before the application user
# exists, and a connect without a database name says nothing about the schema
# being there.
# ---------------------------------------------------------------------------
db_online() {
  [[ -n "$DB_HOST" && -n "$DB_NAME" ]] || return 1
  mysql "${DB_FLAGS[@]}" --batch --skip-column-names -e 'SELECT 1' "$DB_NAME" >/dev/null 2>&1
}

# Gate for every destructive path.
#
# Nothing may DROP or overwrite until this passes, because "assert 0 tables
# remain" verifies that a drop SUCCEEDED and says nothing about WHICH SERVER was
# dropped.
require_db() { # require_db <what-for>
  if db_online; then
    return 0
  fi
  warn "ABORT: cannot run '$1' — an authenticated 'SELECT 1' on $DB_NAME @ $DB_HOST failed."
  warn "ABORT: refusing to touch data we cannot read. Nothing has been changed."
  return 1
}

# ---------------------------------------------------------------------------
# Validate a gzipped mysqldump. All three checks are load-bearing:
#
#   size floor  catches the ~20-byte gzip a failed mysqldump leaves behind
#   gzip -t     catches a corrupted container
#   trailer     catches a TRUNCATED dump, which passes both of the above
#
# The obvious gate — `[ -s "$file" ]` — passes a 20-byte stub, and the
# almost-as-obvious `gzip -t` passes a perfectly valid gzip of half a dump.
# ---------------------------------------------------------------------------
validate_dump() { # validate_dump <file> [label]
  local f="$1" label="${2:-dump}" size trailer
  if [[ ! -f "$f" ]]; then
    warn "INVALID $label: $f does not exist."
    return 1
  fi
  size=$(wc -c < "$f" | tr -d ' ')
  if (( size < DUMP_MIN_BYTES )); then
    warn "INVALID $label: $f is $size bytes, under the ${DUMP_MIN_BYTES}-byte floor."
    warn "INVALID $label: a failed 'mysqldump | gzip' writes a valid ~20-byte gzip, so size is a real signal."
    return 1
  fi
  if ! gzip -t "$f" 2>/dev/null; then
    warn "INVALID $label: $f is not a valid gzip container."
    return 1
  fi
  # Captured into a variable rather than piped into `grep -q`: grep -q exits on
  # its first match, and the resulting SIGPIPE upstream fails the pipeline under
  # `pipefail` — so the SUCCESS case would look like a failure.
  trailer=$(gzip -dc "$f" 2>/dev/null | tail -5) || true
  case "$trailer" in
    *'-- Dump completed'*) ;;
    *)
      warn "INVALID $label: $f has no '-- Dump completed' trailer, so mysqldump never finished."
      warn "INVALID $label: it is a valid gzip of an INCOMPLETE dump. Do not restore from it."
      return 1
      ;;
  esac
  log "VALID $label: $f — $size bytes, gzip intact, '-- Dump completed' trailer present."
  return 0
}

# ---------------------------------------------------------------------------
# Dump to a .partial and publish only on validation.
#
# Writing straight to the destination means a failed dump OVERWRITES the last
# known-good backup with a stub — destroying the safety net at the exact moment
# it is needed. The rejected file is kept for diagnosis under a name no restore
# path reads.
#
# On the mysqldump flags:
#   --no-tablespaces  AVOIDS a privilege requirement. Without it mysqldump tries
#                     to dump tablespaces and needs PROCESS, which a managed
#                     MySQL admin account does not have.
#   --routines/--triggers/--events  IMPOSE privilege requirements (ROUTINE,
#                     EVENT) and mysqldump FAILS rather than warns when they are
#                     unmet. Deliberately absent: that would break the
#                     pre-deploy backup on every deploy of a site that has no
#                     routines to dump. A migration dump does need them, and
#                     verifies the privilege there.
# ---------------------------------------------------------------------------
safe_dump() { # safe_dump <outfile> [label]
  local out="$1" label="${2:-dump}" tmp="$1.partial"
  rm -f "$tmp"
  # pipefail is what makes this `if` test mysqldump rather than gzip.
  if ! mysqldump "${DB_FLAGS[@]}" --single-transaction --quick --lock-tables=false \
        --no-tablespaces "$DB_NAME" | gzip > "$tmp"; then
    warn "ERROR: mysqldump for $label failed (mysqldump's exit status, not gzip's)."
    rm -f "$tmp"
    return 1
  fi
  if ! validate_dump "$tmp" "$label"; then
    warn "ERROR: $label did not validate. NOT publishing to $out; the previous $out is left intact."
    mv -f "$tmp" "$out.rejected" 2>/dev/null || rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$out"
  log "$label published to $out"
  return 0
}

# ---------------------------------------------------------------------------
# Does Drupal bootstrap?
#
# NOT `drush status | grep -q Successful`. Under `pipefail`, grep -q exits at its
# first match and the SIGPIPE that reaches drush makes the pipeline exit
# non-zero — so a successful bootstrap can read as a failure, intermittently,
# depending on whether drush had finished writing. Capture, then match.
# ---------------------------------------------------------------------------
drupal_bootstraps() { # drupal_bootstraps <drush-path>
  local out
  out=$("$1" status --fields=bootstrap 2>/dev/null) || true
  case "$out" in
    *Successful*) return 0 ;;
    *)            return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Reject an UNRESOLVED managed-secret reference.
#
# When the platform cannot resolve a Key Vault reference, the container does not
# see an empty string — it sees the LITERAL reference text,
# "@Microsoft.KeyVault(SecretUri=...)", a plausible-looking hundred-odd character
# value. Used as a password it fails authentication while looking entirely
# reasonable; used as a hash salt it silently BECOMES the salt.
#
# So an emptiness check is not enough, and a length check is actively
# misleading — the reference text is longer than most real secrets.
# ---------------------------------------------------------------------------
is_unresolved_secret() { # is_unresolved_secret <value>
  case "${1:-}" in
    '@Microsoft.KeyVault('*) return 0 ;;
    *)                       return 1 ;;
  esac
}

require_resolved_secret() { # require_resolved_secret <name> <value>
  if is_unresolved_secret "$2"; then
    warn "ABORT: $1 is an UNRESOLVED Key Vault reference — the container holds the"
    warn "ABORT: reference text, not the secret. Check that the app's managed identity"
    warn "ABORT: still has 'Key Vault Secrets User' on the vault and that the secret exists."
    return 1
  fi
  if [[ -z "${2:-}" ]]; then
    warn "ABORT: $1 is empty. There is deliberately no fallback value: see docs/secrets.md."
    return 1
  fi
  return 0
}
