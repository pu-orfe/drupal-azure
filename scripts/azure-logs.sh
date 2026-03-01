#!/usr/bin/env bash
###############################################################################
# azure-logs.sh — Stream real-time logs from the Drupal Container App
#
# Usage: ./scripts/azure-logs.sh [--tail N] [--follow]
###############################################################################
set -euo pipefail

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
RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-}"
CONTAINER_APP="${AZURE_CONTAINER_APP_NAME:-}"
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

# ── Auto-detect resource group and app name ──
if [[ -z "$RESOURCE_GROUP" ]]; then
  info "Detecting resource group..."
  RESOURCE_GROUP=$(az group list --query "[?starts_with(name,'rg-drupal')].name | [0]" -o tsv)
  if [[ -z "$RESOURCE_GROUP" ]]; then
    err "Could not detect resource group. Set AZURE_RESOURCE_GROUP."
    exit 1
  fi
  ok "Resource group: $RESOURCE_GROUP"
fi

if [[ -z "$CONTAINER_APP" ]]; then
  info "Detecting container app..."
  CONTAINER_APP=$(az containerapp list -g "$RESOURCE_GROUP" --query "[0].name" -o tsv)
  if [[ -z "$CONTAINER_APP" ]]; then
    err "Could not detect container app. Set AZURE_CONTAINER_APP_NAME."
    exit 1
  fi
  ok "Container app: $CONTAINER_APP"
fi

# ── Stream logs ──
info "Streaming logs (last $TAIL_LINES lines)..."
echo ""

FOLLOW_ARGS=()
if $FOLLOW; then
  FOLLOW_ARGS+=(--follow)
fi

az containerapp logs show \
  --name "$CONTAINER_APP" \
  --resource-group "$RESOURCE_GROUP" \
  --tail "$TAIL_LINES" \
  "${FOLLOW_ARGS[@]}" \
  --type console
