#!/usr/bin/env bash
###############################################################################
# azure-nuke.sh — Tear down the Azure infrastructure stack
#
# WARNING: destructive. It deletes the entire resource group.
#
# Usage: ./scripts/azure-nuke.sh [--keep-storage]
#
#   --keep-storage   Move the storage account out of the resource group first, so
#                    the file shares survive the teardown. Use this for the
#                    "tear down to save money, rebuild later" loop, where the
#                    uploaded files are the one thing that cannot be rebuilt from
#                    the repository.
#
# Environment variable overrides (skip prompts when set):
#   AZURE_RESOURCE_GROUP — Azure resource group name
#   NUKE_KEEP_RG         — resource group to move preserved resources into
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
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

KEEP_STORAGE=false
if [[ "${1:-}" == "--keep-storage" ]]; then
  KEEP_STORAGE=true
fi

echo -e "${BOLD}${RED}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║          ⚠  DANGER: Infrastructure Teardown  ⚠              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Interactive prompts (skipped when env vars are set) ──
prompt_resource_group

RESOURCE_GROUP="$AZURE_RESOURCE_GROUP"

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
#
# NOTE ON WHAT THIS BACKUP IS WORTH HERE.
#
# The MySQL on-demand backup and the file share snapshots both live INSIDE the
# resource group, so deleting the group destroys them along with everything else.
# They are useful for "I tore down the wrong environment and caught it in the
# next thirty seconds" and worth nothing afterwards.
#
# The only artifact that survives is the logical dump, and only if you download
# it before proceeding. That is why the prompt below is separate.
echo ""
warn "Creating a safety backup before deletion..."
if [[ -f "$SCRIPT_DIR/azure-backup.sh" ]]; then
  bash "$SCRIPT_DIR/azure-backup.sh" || warn "Backup failed — proceeding with deletion anyway"
else
  warn "Backup script not found — skipping pre-deletion backup"
fi

echo ""
warn "The PITR point and the share snapshots just taken live inside this resource"
warn "group and will be destroyed with it. Only a downloaded logical dump survives."
read -rp "$(echo -e "${YELLOW}Have you downloaded anything you need to keep? (type 'yes'): ${NC}")" confirm_backup
if [[ "$confirm_backup" != "yes" ]]; then
  info "Aborted. Nothing was deleted. See docs/operations.md for how to download the dump."
  exit 0
fi

# ── Optionally preserve the storage account ──
if $KEEP_STORAGE; then
  echo ""
  info "Preserving the storage account (--keep-storage)"
  KEEP_RG="${NUKE_KEEP_RG:-${RESOURCE_GROUP}-preserved}"
  STORAGE_ID=$(az storage account list -g "$RESOURCE_GROUP" --query '[0].id' -o tsv 2>/dev/null || true)
  if [[ -z "$STORAGE_ID" ]]; then
    warn "No storage account found to preserve."
  else
    LOC=$(az group show -n "$RESOURCE_GROUP" --query location -o tsv)
    az group create --name "$KEEP_RG" --location "$LOC" --output none
    info "Moving $(basename "$STORAGE_ID") to $KEEP_RG (this can take a few minutes)"
    # The account's network rules reference the VNet that is about to be deleted.
    # Left in place, the moved account becomes unreachable from anything — a
    # default-deny account whose only allowed subnet no longer exists. Open it to
    # Azure services so a later rebuild can read the shares back.
    az storage account update --ids "$STORAGE_ID" \
      --default-action Allow --output none 2>/dev/null || \
      warn "Could not relax the network rules; the preserved account may be unreachable until you do."
    if az resource move --destination-group "$KEEP_RG" --ids "$STORAGE_ID" --output none; then
      ok "Storage account preserved in $KEEP_RG"
      warn "It is now open to the internet at the network level (key-authenticated only)."
      warn "Re-lock it after the rebuild: azure-up.sh sets default-deny plus a subnet rule."
    else
      err "Move failed. Aborting rather than deleting a resource group that still contains your files."
      exit 1
    fi
  fi
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

# ── Soft-deleted Key Vault ──
#
# Key Vault soft delete is mandatory and cannot be turned off, so deleting the
# resource group leaves the vault NAME reserved for the retention period. A
# rebuild with the same base name then fails with a name conflict that says
# nothing about soft delete — which is a confusing way to discover this.
#
# infra/modules/keyvault.bicep deliberately leaves purge protection OFF so the
# name can be released here; with it on, nothing can release it early.
KV_NAME=$(az keyvault list-deleted --query "[?properties.vaultId!=null && contains(properties.vaultId, '/resourceGroups/${RESOURCE_GROUP}/')].name | [0]" -o tsv 2>/dev/null || true)
if [[ -n "${KV_NAME:-}" ]]; then
  warn "Key Vault '$KV_NAME' is soft-deleted; its name stays reserved until purged."
  read -rp "$(echo -e "${YELLOW}Purge it now, so the name can be reused? (type 'yes'): ${NC}")" purge_kv
  if [[ "$purge_kv" == "yes" ]]; then
    if az keyvault purge --name "$KV_NAME" --output none 2>/dev/null; then
      ok "Key Vault purged; the name is free."
    else
      warn "Purge failed (purge protection may be enabled). The name is unusable until retention expires."
    fi
  else
    info "Left soft-deleted. Recover it later with: az keyvault recover --name $KV_NAME"
  fi
fi
echo ""
