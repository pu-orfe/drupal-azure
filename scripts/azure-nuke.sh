#!/usr/bin/env bash
###############################################################################
# azure-nuke.sh — Tear down the Azure infrastructure stack
#
# WARNING: This is destructive! It deletes the entire resource group.
#
# Usage: ./scripts/azure-nuke.sh
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
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── Configuration ──
RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-}"

echo -e "${BOLD}${RED}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║          ⚠  DANGER: Infrastructure Teardown  ⚠              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Auto-detect resource group ──
if [[ -z "$RESOURCE_GROUP" ]]; then
  info "Detecting resource group..."
  RESOURCE_GROUP=$(az group list --query "[?starts_with(name,'rg-drupal')].name | [0]" -o tsv)
  if [[ -z "$RESOURCE_GROUP" ]]; then
    err "Could not detect resource group. Set AZURE_RESOURCE_GROUP."
    exit 1
  fi
fi

echo -e "  Resource Group: ${RED}${BOLD}${RESOURCE_GROUP}${NC}"
echo ""

# ── Show what will be deleted ──
info "Resources that will be PERMANENTLY DELETED:"
echo ""
az resource list -g "$RESOURCE_GROUP" --query "[].{Name:name, Type:type}" -o table
echo ""

# ── Safety prompts ──
echo -e "${RED}${BOLD}This action is IRREVERSIBLE. All data will be lost.${NC}"
echo ""
read -rp "$(echo -e "${YELLOW}Type the resource group name to confirm deletion: ${NC}")" confirm_name
if [[ "$confirm_name" != "$RESOURCE_GROUP" ]]; then
  err "Name does not match. Aborting."
  exit 1
fi

echo ""
read -rp "$(echo -e "${RED}Are you ABSOLUTELY sure? (type 'DELETE' to confirm): ${NC}")" confirm_delete
if [[ "$confirm_delete" != "DELETE" ]]; then
  info "Aborted. No resources were deleted."
  exit 0
fi

# ── Create a backup first ──
echo ""
warn "Creating a safety backup before deletion..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$SCRIPT_DIR/azure-backup.sh" ]]; then
  bash "$SCRIPT_DIR/azure-backup.sh" || warn "Backup failed — proceeding with deletion anyway"
else
  warn "Backup script not found — skipping pre-deletion backup"
fi

# ── Delete resource group ──
echo ""
info "Deleting resource group: $RESOURCE_GROUP"
info "This may take several minutes..."

az group delete \
  --name "$RESOURCE_GROUP" \
  --yes \
  --no-wait

ok "Deletion initiated (running in background)"
echo ""
echo -e "${YELLOW}Check status with:${NC}"
echo "  az group show -n $RESOURCE_GROUP --query 'properties.provisioningState' -o tsv"
echo ""
