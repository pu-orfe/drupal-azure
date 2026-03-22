#!/usr/bin/env bash
###############################################################################
# azure-backup.sh — On-demand backup of Database and File Shares
#
# Usage: ./scripts/azure-backup.sh
#
# Environment variable overrides (skip prompts when set):
#   AZURE_RESOURCE_GROUP — Azure resource group name
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
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()  { echo -e "\n${CYAN}${BOLD}▸ $*${NC}"; }

# ── Configuration ──
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

echo -e "${BOLD}${CYAN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                   Azure Backup Utility                      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Interactive prompts (skipped when env vars are set) ──
prompt_resource_group

RESOURCE_GROUP="$AZURE_RESOURCE_GROUP"
ok "Resource group: $RESOURCE_GROUP"

###############################################################################
# 1. MySQL Backup (on-demand)
###############################################################################
step "Backing up MySQL database"

MYSQL_SERVER=$(az mysql flexible-server list -g "$RESOURCE_GROUP" --query "[0].name" -o tsv)
if [[ -z "$MYSQL_SERVER" ]]; then
  err "No MySQL Flexible Server found in $RESOURCE_GROUP"
  exit 1
fi

BACKUP_NAME="manual-backup-${TIMESTAMP}"
info "Triggering on-demand backup: $BACKUP_NAME"

az mysql flexible-server backup create \
  --resource-group "$RESOURCE_GROUP" \
  --server-name "$MYSQL_SERVER" \
  --backup-name "$BACKUP_NAME"

ok "MySQL backup initiated: $BACKUP_NAME"

###############################################################################
# 2. File Share Snapshots
###############################################################################
step "Creating File Share snapshots"

STORAGE_ACCOUNT=$(az storage account list -g "$RESOURCE_GROUP" --query "[0].name" -o tsv)
if [[ -z "$STORAGE_ACCOUNT" ]]; then
  err "No storage account found in $RESOURCE_GROUP"
  exit 1
fi

STORAGE_KEY=$(az storage account keys list \
  --account-name "$STORAGE_ACCOUNT" \
  --query "[0].value" -o tsv)

for SHARE in drupal-public drupal-private; do
  info "Snapshotting share: $SHARE"
  SNAPSHOT=$(az storage share snapshot \
    --name "$SHARE" \
    --account-name "$STORAGE_ACCOUNT" \
    --account-key "$STORAGE_KEY" \
    --query "snapshot" -o tsv)
  ok "Snapshot created: $SHARE @ $SNAPSHOT"
done

###############################################################################
# Summary
###############################################################################
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════╗"
echo "║                    Backup Complete!                          ║"
echo "╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  MySQL backup:     $BACKUP_NAME"
echo "  File snapshots:   drupal-public, drupal-private"
echo "  Timestamp:        $TIMESTAMP"
echo ""
