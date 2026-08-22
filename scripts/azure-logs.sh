#!/usr/bin/env bash
###############################################################################
# azure-logs.sh — Stream real-time logs from the Drupal Container App
#
# Usage: ./scripts/azure-logs.sh [--tail N] [--follow] [--no-follow]
#
# Environment variable overrides (skip prompts when set):
#   AZURE_RESOURCE_GROUP      — Azure resource group name
#   AZURE_PLATFORM            — appservice (default) | containerapps
#   AZURE_APP_NAME            — web app or container app name (detected if unset)
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Shared prompt library ──
source "$SCRIPT_DIR/lib/prompt.sh"
source "$SCRIPT_DIR/lib/platform.sh"

# ── Colors ──
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── Configuration ──
TAIL_LINES=100
FOLLOW=true

# Parse args
while [[ $# -gt 0 ]]; do
  case $1 in
    --tail)    TAIL_LINES="$2"; shift 2 ;;
    --follow)  FOLLOW=true; shift ;;
    --no-follow) FOLLOW=false; shift ;;
    *) shift ;;
  esac
done

echo -e "${BOLD}${CYAN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                 Container App Log Viewer                    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Interactive prompts (skipped when env vars are set) ──
prompt_resource_group
platform_resolve || exit 1
if [[ -z "${AZURE_APP_NAME:-}" ]]; then
  err "No app found in $AZURE_RESOURCE_GROUP. Deploy first, or set AZURE_APP_NAME."
  exit 1
fi
info "Platform: $AZURE_PLATFORM   App: $AZURE_APP_NAME"

# ── Stream logs ──
info "Streaming logs (last $TAIL_LINES lines)..."
echo ""

if $FOLLOW; then
  platform_logs "$TAIL_LINES" yes
else
  platform_logs "$TAIL_LINES" no
fi

# Both platforms stream only what is happening now, and a destroyed instance or
# replica takes its buffer with it. The logs from the deploy that broke something
# three weeks ago are in Log Analytics — see docs/operations.md for the query.
