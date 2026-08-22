#!/usr/bin/env bash
###############################################################################
# compose.sh — bringing the local stack up, reliably
#
# Source it, then use "${COMPOSE[@]}" instead of a bare docker-compose:
#   source "$SCRIPT_DIR/lib/compose.sh"
#   compose_up_with_retry
###############################################################################

[[ -n "${_COMPOSE_LIB_LOADED:-}" ]] && return 0
_COMPOSE_LIB_LOADED=1

_C_GREEN=$'\033[0;32m'; _C_YELLOW=$'\033[1;33m'; _C_BLUE=$'\033[0;34m'; _C_NC=$'\033[0m'

# The project convention is `docker-compose`; fall back to the plugin form so
# this works on a machine that only has `docker compose`.
COMPOSE=(docker-compose)
command -v docker-compose >/dev/null 2>&1 || COMPOSE=(docker compose)
export COMPOSE

###############################################################################
# compose_up_with_retry [extra docker-compose up args...]
#
# WHY A RETRY, AND WHY ONLY HERE
#
# `mysql:8.0` on arm64 intermittently exits 139 (SIGSEGV) while initialising a
# fresh data directory. Observed on Apple Silicon under Docker Desktop: roughly
# one attempt in several on an empty volume, and a retry on a clean volume then
# succeeds. It is a fault in the image's behaviour on that platform, not in this
# configuration — the same compose file comes up healthy on the retry with
# nothing changed.
#
# This is worth papering over precisely because of WHO hits it: someone running
# `./scripts/local-dev.sh` for the first time, who has no way to tell a flaky
# container from a broken template and will reasonably conclude the latter.
#
# It is bounded, it is loud, and it only ever retries after wiping the volume —
# a half-initialised data directory is exactly what the next attempt must not
# inherit. If it still fails, it says so and shows the logs rather than looping.
###############################################################################
compose_up_with_retry() {
  local attempts="${COMPOSE_UP_ATTEMPTS:-3}" attempt

  for (( attempt = 1; attempt <= attempts; attempt++ )); do
    if "${COMPOSE[@]}" up -d --build --wait "$@" 2>&1 | tail -5; then
      return 0
    fi

    # Only the database's own initialisation crash is worth retrying. Anything
    # else — a build failure, a port clash, a bad compose file — will fail
    # identically next time, and retrying it just hides the message.
    local db_exit
    db_exit=$("${COMPOSE[@]}" ps -a --format '{{.ExitCode}}' db 2>/dev/null | head -1)
    if [[ "$db_exit" != "139" ]]; then
      printf '%s  the stack failed for a reason a retry will not fix (db exit=%s)%s\n' \
        "$_C_YELLOW" "${db_exit:-unknown}" "$_C_NC" >&2
      "${COMPOSE[@]}" logs --tail 40 2>&1 | tail -40 >&2
      return 1
    fi

    if (( attempt < attempts )); then
      printf '%s  mysql exited 139 (SIGSEGV) initialising its data directory — a known\n' "$_C_YELLOW"
      printf '  arm64 flake. Wiping the volume and retrying (%d/%d).%s\n' \
        "$attempt" "$attempts" "$_C_NC" >&2
      "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
    fi
  done

  printf '%s  the database crashed on every one of %d attempts.%s\n' "$_C_YELLOW" "$attempts" "$_C_NC" >&2
  printf '  That is more than a flake. Check Docker'"'"'s available memory, and see\n' >&2
  printf '  docs/troubleshooting.md.\n' >&2
  "${COMPOSE[@]}" logs --tail 40 db 2>&1 | tail -40 >&2
  return 1
}
