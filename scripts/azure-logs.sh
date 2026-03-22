#!/usr/bin/env bash
###############################################################################
# azure-logs.sh — Stream real-time logs from the Drupal Container App
#
# Usage: ./scripts/azure-logs.sh [--tail N] [--follow] [--no-follow]
#
# Environment variable overrides (skip prompts when set):
#   AZURE_RESOURCE_GROUP      — Azure resource group name
#   AZURE_CONTAINER_APP_NAME  — Container app name
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Shared prompt library ──
source "$SCRIPT_DIR/lib/prompt.sh"

# ── Colors ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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
prompt_container_app

# ── Stream logs ──
info "Streaming logs (last $TAIL_LINES lines)..."
echo ""

FOLLOW_ARGS=()
if $FOLLOW; then
  FOLLOW_ARGS+=(--follow)
fi

az containerapp logs show \
  --name "$AZURE_CONTAINER_APP_NAME" \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --tail "$TAIL_LINES" \
  "${FOLLOW_ARGS[@]}" \
  --type console
