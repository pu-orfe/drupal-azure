#!/usr/bin/env bash
###############################################################################
# Drive docker/entrypoint-lib.sh directly.
#
# These guards protect a data-destroying operation. A safety net that no test
# ever executes is not a safety net — and the specific case that matters is the
# one every naive check accepts: a FAILED `mysqldump | gzip` leaves behind a
# perfectly valid gzip of about twenty bytes, which passes `[ -s "$f" ]` and
# passes `gzip -t`.
#
# Run standalone, or via scripts/test.sh --shell. Database-backed cases are
# skipped when no MySQL is reachable, and reported as skipped rather than passed.
###############################################################################
# The library reads these across a `source`, which shellcheck cannot follow.
# Must precede the first command to apply file-wide.
# shellcheck disable=SC2034

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; NC=$'\033[0m'
PASSED=0; FAILED=0; SKIPPED=0
ok()   { printf '%s  ✓%s %s\n' "$GREEN" "$NC" "$1"; PASSED=$((PASSED + 1)); }
no()   { printf '%s  ✗%s %s\n' "$RED" "$NC" "$1"; FAILED=$((FAILED + 1)); }
skip() { printf '%s  ~%s %s (skipped)\n' "$YELLOW" "$NC" "$1"; SKIPPED=$((SKIPPED + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The library requires these; set before sourcing so `set -u` inside it is happy.
set -Eeuo pipefail
DB_HOST=""; DB_PORT=3306; DB_USER=""; DB_PASSWORD=""; DB_NAME=""
CONTAINER_VERSION="guardtest"
DUMP_MIN_BYTES=1000
MYSQL_TLS_ARGS=()
# shellcheck source=docker/entrypoint-lib.sh
source docker/entrypoint-lib.sh
db_flags_init
set +e

# ---------------------------------------------------------------------------
# validate_dump — the whole reason this file exists.
# ---------------------------------------------------------------------------
printf '\nvalidate_dump\n'

# The exact artifact a failed `mysqldump | gzip` produces: gzip of an error
# message, or of nothing at all. Valid gzip, non-empty file, no data.
: | gzip > "$TMP/stub.sql.gz"
size=$(wc -c < "$TMP/stub.sql.gz" | tr -d ' ')
if validate_dump "$TMP/stub.sql.gz" stub >/dev/null 2>&1; then
  no "a ${size}-byte gzip stub was ACCEPTED — this is the case that drops a database and reports success"
else
  ok "rejects the ${size}-byte gzip stub a failed mysqldump leaves behind"
fi

# `[ -s "$f" ]` and `gzip -t` both pass it, which is why neither is sufficient.
if [[ -s "$TMP/stub.sql.gz" ]] && gzip -t "$TMP/stub.sql.gz" 2>/dev/null; then
  ok "and the stub does pass both '[ -s ]' and 'gzip -t' — so neither check is sufficient"
else
  no "test fixture is wrong: the stub should pass -s and gzip -t"
fi

validate_dump "$TMP/missing.sql.gz" x >/dev/null 2>&1 \
  && no "accepted a file that does not exist" \
  || ok "rejects a missing file"

# Big enough to clear the floor, but not a gzip.
head -c 4000 /dev/zero > "$TMP/notgzip.sql.gz"
validate_dump "$TMP/notgzip.sql.gz" x >/dev/null 2>&1 \
  && no "accepted a non-gzip file" \
  || ok "rejects a file that is not a gzip container"

# The subtle one: a VALID gzip of a TRUNCATED dump. Passes the size floor and
# gzip -t, and restoring from it silently loses whatever came after the cut.
#
# The payload is /dev/urandom, not repeated characters: repeated characters gzip
# to a few dozen bytes and would trip the size floor instead, so the test would
# pass for the wrong reason and stop covering the trailer check at all.
{ echo "-- MySQL dump"; head -c 8000 /dev/urandom | base64; } | gzip > "$TMP/trunc.sql.gz"
validate_dump "$TMP/trunc.sql.gz" x >/dev/null 2>&1 \
  && no "accepted a valid gzip of a TRUNCATED dump" \
  || ok "rejects a complete gzip of an incomplete dump (no '-- Dump completed' trailer)"

# A well-formed dump: over the floor, valid gzip, trailer present.
{ echo "-- MySQL dump"; head -c 8000 /dev/urandom | base64; echo; echo "-- Dump completed on 2026-08-22"; } \
  | gzip > "$TMP/good.sql.gz"
validate_dump "$TMP/good.sql.gz" x >/dev/null 2>&1 \
  && ok "accepts a complete dump" \
  || no "rejected a complete dump"

# ---------------------------------------------------------------------------
# is_unresolved_secret / require_resolved_secret
# ---------------------------------------------------------------------------
printf '\nunresolved secret references\n'

REF='@Microsoft.KeyVault(SecretUri=https://kv-x.vault.azure.net/secrets/db-password/)'

is_unresolved_secret "$REF" \
  && ok "recognises an unresolved Key Vault reference" \
  || no "did not recognise an unresolved Key Vault reference"

is_unresolved_secret "an-ordinary-password" \
  && no "flagged an ordinary value as unresolved" \
  || ok "leaves an ordinary value alone"

require_resolved_secret DB_PASSWORD "$REF" >/dev/null 2>&1 \
  && no "ACCEPTED the reference text as a password — it authenticates as nothing while looking plausible" \
  || ok "refuses the reference text as a password"

# The check that a length heuristic gets backwards: the reference text is LONGER
# than most real secrets, so "looks long enough" is not merely insufficient, it
# actively reassures.
if (( ${#REF} > 40 )); then
  ok "and the reference is ${#REF} characters — longer than a real secret, so a length check would pass it"
else
  no "test fixture is wrong: the reference should be long"
fi

require_resolved_secret DB_PASSWORD "" >/dev/null 2>&1 \
  && no "accepted an empty secret" \
  || ok "refuses an empty secret"

require_resolved_secret DB_PASSWORD "a-real-value" >/dev/null 2>&1 \
  && ok "accepts a resolved secret" \
  || no "rejected a resolved secret"

# ---------------------------------------------------------------------------
# secret_fingerprint
# ---------------------------------------------------------------------------
printf '\nsecret_fingerprint\n'

fp_a=$(secret_fingerprint "value-a")
fp_b=$(secret_fingerprint "value-b")
[[ "$fp_a" != "$fp_b" ]] && ok "different values fingerprint differently" \
                         || no "two different values produced the same fingerprint"
[[ "$fp_a" == "$(secret_fingerprint "value-a")" ]] && ok "the same value fingerprints stably" \
                                                   || no "fingerprint is not stable"
[[ "$fp_a" != *"value-a"* ]] && ok "the fingerprint does not contain the secret" \
                             || no "the fingerprint leaks the secret"
[[ "$(secret_fingerprint "")" == "unset" ]] && ok "reports an unset secret as 'unset'" \
                                            || no "did not report an unset secret distinctly"

# ---------------------------------------------------------------------------
# run_step: critical vs tolerated
# ---------------------------------------------------------------------------
printf '\nrun_step\n'

BOOT_STATUS=ok; CRITICAL_FAILED=false; BOOT_STEPS=()
run_step tolerated always_fine true >/dev/null 2>&1
[[ "$BOOT_STATUS" == "ok" && "$CRITICAL_FAILED" == "false" ]] \
  && ok "a successful step leaves the boot clean" \
  || no "a successful step changed the boot status"

BOOT_STATUS=ok; CRITICAL_FAILED=false; BOOT_STEPS=()
run_step tolerated offsite_upload false >/dev/null 2>&1
if [[ "$BOOT_STATUS" == "degraded" && "$CRITICAL_FAILED" == "false" ]]; then
  # This is the distinction that stops a routinely-failing non-blocking step from
  # withholding the version marker — which would make every replica start re-run
  # updb and take a fresh backup, overwriting the previous deploy's rollback
  # point.
  ok "a failed TOLERATED step degrades the boot but does not force a retry"
else
  no "a failed tolerated step set CRITICAL_FAILED (status=$BOOT_STATUS critical=$CRITICAL_FAILED)"
fi

BOOT_STATUS=ok; CRITICAL_FAILED=false; BOOT_STEPS=()
run_step critical config_import false >/dev/null 2>&1
[[ "$BOOT_STATUS" == "degraded" && "$CRITICAL_FAILED" == "true" ]] \
  && ok "a failed CRITICAL step forces the next boot to retry" \
  || no "a failed critical step did not set CRITICAL_FAILED"

BOOT_STATUS=ok; CRITICAL_FAILED=false; BOOT_STEPS=()
run_step critical exits_with_seven bash -c 'exit 7' >/dev/null 2>&1
if [[ "${BOOT_STEPS[0]:-}" == *'"exits_with_seven": 7'* ]]; then
  ok "records the actual exit code, not merely 'failed'"
else
  no "did not record the exit code (got '${BOOT_STEPS[0]:-nothing}')"
fi

# ---------------------------------------------------------------------------
# boot_result_write
# ---------------------------------------------------------------------------
printf '\nboot_result_write\n'

BOOT_STATUS=ok; CRITICAL_FAILED=false; BOOT_STEPS=()
DRUPAL_HASH_SALT="a-salt" DB_PASSWORD="a-password"
run_step critical updb true >/dev/null 2>&1
run_step critical cache_rebuild bash -c 'exit 3' >/dev/null 2>&1
boot_result_write "$TMP/boot.json" degraded >/dev/null 2>&1

if python3 -c "
import json, sys
d = json.load(open('$TMP/boot.json'))
assert d['status'] == 'degraded', d['status']
assert d['steps']['updb'] == 0, d['steps']
assert d['steps']['cache_rebuild'] == 3, d['steps']
assert d['critical_failed'] is True, d
assert 'a-salt' not in json.dumps(d), 'secret leaked into the boot result'
assert 'a-password' not in json.dumps(d), 'secret leaked into the boot result'
assert d['hash_salt_fingerprint'] not in ('', 'unset'), d['hash_salt_fingerprint']
" 2>/dev/null; then
  ok "writes valid JSON with per-step exit codes and fingerprints, and no secrets"
else
  no "boot result JSON is wrong or leaks a secret:"
  sed 's/^/      /' "$TMP/boot.json" 2>/dev/null | head -20
fi

# ---------------------------------------------------------------------------
# safe_dump and require_db, against a real server when one is reachable.
# ---------------------------------------------------------------------------
printf '\nsafe_dump / require_db (needs a database)\n'

# Overridable so this file runs unchanged on the host (against the published
# port) and inside the web container (against the compose service name).
DB_HOST="${GUARD_DB_HOST:-127.0.0.1}"; DB_PORT="${GUARD_DB_PORT:-13306}"
DB_USER="${GUARD_DB_USER:-drupal}"; DB_PASSWORD="${GUARD_DB_PASSWORD:-drupal}"
DB_NAME="${GUARD_DB_NAME:-drupal}"
MYSQL_TLS_ARGS=(--skip-ssl)
export MYSQL_PWD="$DB_PASSWORD"
db_flags_init

if ! command -v mysql >/dev/null 2>&1; then
  skip "no mysql client available"
elif ! db_online; then
  skip "no database at ${DB_HOST}:${DB_PORT} (bring one up with docker-compose up -d db)"
else
  ok "db_online succeeds against a reachable, authenticated database"

  # require_db must refuse when the server is wrong, because every check that
  # comes after it is destructive. "Assert 0 tables remain" verifies that a drop
  # succeeded and says nothing about which server was dropped.
  saved_host="$DB_HOST"; saved_port="$DB_PORT"
  DB_HOST="127.0.0.1"; DB_PORT=1; db_flags_init
  require_db "a destructive step" >/dev/null 2>&1 \
    && no "require_db passed against an unreachable server" \
    || ok "require_db refuses an unreachable server"
  # Restore from the SAVED values, not from a literal. An earlier version wrote
  # `DB_PORT=13306` here, which was right on the host and wrong inside the
  # container — so every later case silently ran against nothing and the failure
  # was reported as "safe_dump failed" rather than "the test broke its own
  # connection".
  DB_HOST="$saved_host"; DB_PORT="$saved_port"; db_flags_init

  # A real dump of a real database must validate.
  DUMP_MIN_BYTES=100
  if safe_dump "$TMP/real.sql.gz" "real dump" >/dev/null 2>&1; then
    ok "safe_dump produces a dump that validates"
    [[ ! -f "$TMP/real.sql.gz.partial" ]] && ok "and leaves no .partial behind" \
                                          || no "left a .partial file behind"
  else
    no "safe_dump failed against a reachable database"
  fi

  # The property that matters: a FAILED dump must not overwrite the good one.
  printf 'PREVIOUS-GOOD-BACKUP' > "$TMP/keep.sql.gz"
  saved_name="$DB_NAME"
  DB_NAME="a_database_that_does_not_exist"
  safe_dump "$TMP/keep.sql.gz" "doomed dump" >/dev/null 2>&1
  if [[ "$(cat "$TMP/keep.sql.gz")" == "PREVIOUS-GOOD-BACKUP" ]]; then
    ok "a failed dump leaves the previous backup intact"
  else
    no "a failed dump DESTROYED the previous backup — the safety net at the moment it is needed"
  fi
  [[ -f "$TMP/keep.sql.gz.rejected" ]] \
    && ok "and keeps the rejected attempt under a name no restore path reads" \
    || skip "no .rejected file (acceptable if mysqldump wrote nothing at all)"
  DB_NAME="$saved_name"
fi

printf '\n%d passed, %d failed, %d skipped\n' "$PASSED" "$FAILED" "$SKIPPED"
[[ "$FAILED" -eq 0 ]]
