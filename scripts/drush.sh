#!/usr/bin/env bash
###############################################################################
# drush.sh — run a drush command against the deployment, with a real exit code
#
#   ./scripts/drush.sh status
#   ./scripts/drush.sh cache:rebuild
#   ./scripts/drush.sh -- sql:query "SELECT COUNT(*) FROM users"
#   ./scripts/drush.sh --exec cr        # run in a live replica instead of a job
#
# WHY NOT `az containerapp exec`
#
# `az containerapp exec` attaches an interactive shell to whichever replica the
# platform picks. It is genuinely useful for looking around, and unfit for
# running anything that matters:
#
#   * No exit-code contract. The command's status is not propagated, so a script
#     cannot tell success from failure — which is why the old deploy pipeline's
#     post-deploy steps were written `|| echo "failed"` and a failed schema
#     update produced a green deploy.
#   * It competes with live traffic for that replica's CPU and memory. A drush
#     command that needs 400 MB on a 1Gi replica already serving requests can
#     take the replica down.
#   * The command dies with the websocket. For `drush updb` that means a
#     partially migrated database, from a dropped laptop connection.
#   * With minReplicas 0 there may be no replica to attach to at all.
#
# So the default here is the manual-trigger Container Apps Job
# (infra/modules/jobs.bicep): its own replica, the same image, the same secrets
# and mounts, an execution record and an exit code. `--exec` is available for the
# interactive cases where that is genuinely what you want.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/prompt.sh"
source "$SCRIPT_DIR/lib/platform.sh"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
info() { printf '%s[INFO]%s  %s\n' "$BLUE" "$NC" "$*"; }
ok()   { printf '%s[OK]%s    %s\n' "$GREEN" "$NC" "$*"; }
err()  { printf '%s[ERROR]%s %s\n' "$RED" "$NC" "$*" >&2; }

USE_EXEC=no
TIMEOUT_SECONDS="${DRUSH_JOB_TIMEOUT:-900}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --exec) USE_EXEC=yes; shift ;;
    --)     shift; break ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) break ;;
  esac
done
[[ $# -gt 0 ]] || { err "No drush command given."; sed -n '2,12p' "$0"; exit 2; }

prompt_resource_group
platform_resolve || exit 1
RG="$AZURE_RESOURCE_GROUP"
APP="${AZURE_APP_NAME:?no app found in $AZURE_RESOURCE_GROUP}"

# ---------------------------------------------------------------------------
# App Service: Kudu's /api/command.
#
# It returns the command's exit code in the response body, so this is a real
# invocation rather than a terminal attachment — which is the property the
# Container Apps path has to build a whole Job to obtain. Authentication is an
# Entra bearer token against Azure RBAC: no open port, no stored credential, and
# the call is attributable to whoever ran it.
# ---------------------------------------------------------------------------
if [[ "$AZURE_PLATFORM" == "appservice" ]]; then
  info "Running via Kudu on $APP: drush $*"
  if platform_run_drush "$@"; then
    ok "drush $* succeeded"
    exit 0
  fi
  rc=$?
  err "drush $* FAILED (exit $rc)"
  exit "$rc"
fi

if [[ "$USE_EXEC" == "yes" ]]; then
  printf '%s[WARN]%s Running in a live replica. Output is not a reliable exit code — see the header.\n' "$YELLOW" "$NC"
  exec az containerapp exec --name "$APP" --resource-group "$RG" \
    --command "vendor/bin/drush $*"
fi

JOB_NAME="${DRUSH_JOB_NAME:-${APP}-drush}"
if ! az containerapp job show --name "$JOB_NAME" --resource-group "$RG" >/dev/null 2>&1; then
  err "Job '$JOB_NAME' not found in $RG."
  printf '  It is created by infra/modules/jobs.bicep. Deploy the infrastructure, or use --exec.\n'
  exit 1
fi

# Comma-separated is the CLI's format for --args, which means an argument
# containing a comma cannot be expressed. Refuse rather than silently splitting
# it into two arguments — a truncated `sql:query` is worse than an error.
for a in "$@"; do
  case "$a" in
    *,*) err "Arguments cannot contain a comma (az containerapp job --args is comma-separated): '$a'"
         printf '  Put the statement in a file on the private share and use --file, or use --exec.\n'
         exit 2 ;;
  esac
done

args="vendor/bin/drush"
for a in "$@"; do args+=",${a}"; done

info "Starting job $JOB_NAME: drush $*"
execution=$(az containerapp job start --name "$JOB_NAME" --resource-group "$RG" \
  --command "/usr/local/bin/docker-entrypoint.sh" --args "$args" \
  --query "name" -o tsv)
[[ -n "$execution" ]] || { err "Job did not start."; exit 1; }
info "Execution: $execution"

# Poll to a terminal status. The exit code of this script IS the job's outcome,
# which is the entire point of running it this way.
deadline=$(( SECONDS + TIMEOUT_SECONDS ))
status="Unknown"
while (( SECONDS < deadline )); do
  status=$(az containerapp job execution show --name "$JOB_NAME" --resource-group "$RG" \
    --job-execution-name "$execution" --query "properties.status" -o tsv 2>/dev/null || echo Unknown)
  case "$status" in
    Succeeded|Failed|Cancelled) break ;;
  esac
  sleep 5
done

printf '\n%s─── job output ───%s\n' "$BLUE" "$NC"
# Logs land in Log Analytics; the CLI's own tail is the fast path and can lag a
# few seconds behind a just-finished execution.
az containerapp job logs show --name "$JOB_NAME" --resource-group "$RG" \
  --execution "$execution" --container drush --tail 200 2>/dev/null \
  || printf '  (logs not yet available — query Log Analytics, see docs/operations.md)\n'
printf '%s──────────────────%s\n\n' "$BLUE" "$NC"

case "$status" in
  Succeeded) ok "drush $* succeeded"; exit 0 ;;
  Failed)    err "drush $* FAILED"; exit 1 ;;
  Cancelled) err "Execution cancelled"; exit 1 ;;
  *)         err "Execution did not reach a terminal status within ${TIMEOUT_SECONDS}s (last: $status)"; exit 1 ;;
esac
