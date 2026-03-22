#!/usr/bin/env bash
###############################################################################
# migrate.sh — cPanel to Azure Container Apps Migration
#
# Migrates:
#   1. Database: cPanel MySQL → Azure MySQL Flexible Server
#   2. Files:    cPanel public/private files → Azure File Shares via azcopy
#
# Prerequisites:
#   - az CLI logged in (az login)
#   - mysql-client installed
#   - azcopy installed (https://aka.ms/azcopy)
#   - SSH access to cPanel host
#
# Usage: ./migrate.sh
#
# Environment variable overrides (skip prompts when set):
#   CPANEL_HOST, CPANEL_USER, CPANEL_DB_NAME, CPANEL_DB_USER, CPANEL_DB_PASS
#   CPANEL_DRUPAL_ROOT (default: /home/$CPANEL_USER/public_html)
#   AZURE_RG, AZURE_MYSQL_HOST, AZURE_MYSQL_USER, AZURE_MYSQL_PASS
#   AZURE_MYSQL_DB (default: drupal), AZURE_STORAGE_ACCOUNT
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Shared prompt library ──
source "$SCRIPT_DIR/lib/prompt.sh"

# ── Colors ──────────────────────────────────────────────────────────────────
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

echo -e "${BOLD}${CYAN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         cPanel → Azure Container Apps Migration             ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Interactive prompts — cPanel source ──
step "cPanel source configuration"

prompt_val    CPANEL_HOST    "cPanel hostname (e.g. example.com)"
prompt_val    CPANEL_USER    "cPanel SSH username"
prompt_val    CPANEL_DB_NAME "cPanel database name"
prompt_val    CPANEL_DB_USER "cPanel database username"
prompt_secret CPANEL_DB_PASS "cPanel database password"

# Drupal root defaults to /home/<user>/public_html
prompt_val CPANEL_DRUPAL_ROOT "cPanel Drupal root" "/home/${CPANEL_USER}/public_html"

# ── Interactive prompts — Azure destination ──
step "Azure destination configuration"

prompt_val    AZURE_RG              "Azure resource group"
prompt_val    AZURE_MYSQL_HOST      "Azure MySQL host (e.g. mysql-drupal-xxx.mysql.database.azure.com)"
prompt_val    AZURE_MYSQL_USER      "Azure MySQL username"
prompt_secret AZURE_MYSQL_PASS      "Azure MySQL password"
prompt_val    AZURE_MYSQL_DB        "Azure MySQL database name" "drupal"
prompt_val    AZURE_STORAGE_ACCOUNT "Azure storage account name"

# Working directory for temporary files
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

echo ""
echo "  Source:  ${CPANEL_USER}@${CPANEL_HOST}"
echo "  Target:  ${AZURE_RG} (${AZURE_MYSQL_HOST})"
echo ""

read -rp "$(echo -e "${YELLOW}Continue with migration? (y/N): ${NC}")" confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }

###############################################################################
# Phase 1: Database Migration
###############################################################################
step "Phase 1: Database Migration"

DB_DUMP="$WORK_DIR/drupal_dump.sql"

info "Exporting database from cPanel via SSH tunnel..."
# Use printf %q to safely escape credentials for the remote shell
_esc_user=$(printf '%q' "$CPANEL_DB_USER")
_esc_pass=$(printf '%q' "$CPANEL_DB_PASS")
_esc_db=$(printf '%q' "$CPANEL_DB_NAME")
ssh "${CPANEL_USER}@${CPANEL_HOST}" \
  "mysqldump --single-transaction --quick --routines --triggers \
    -u ${_esc_user} -p${_esc_pass} ${_esc_db}" \
  > "$DB_DUMP"

DUMP_SIZE=$(du -h "$DB_DUMP" | cut -f1)
ok "Database export complete ($DUMP_SIZE)"

info "Sanitizing dump (removing DEFINER clauses)..."
sed -i '.bak' \
  -e 's/DEFINER=[^ ]* / /g' \
  -e 's/ROW_FORMAT=FIXED//g' \
  "$DB_DUMP"
ok "Sanitization complete"

info "Importing database to Azure MySQL ($AZURE_MYSQL_HOST)..."
mysql \
  -h "$AZURE_MYSQL_HOST" \
  -u "$AZURE_MYSQL_USER" \
  -p"$AZURE_MYSQL_PASS" \
  --ssl-mode=REQUIRED \
  "$AZURE_MYSQL_DB" < "$DB_DUMP"

ok "Database imported successfully"

###############################################################################
# Phase 2: File Migration
###############################################################################
step "Phase 2: File Migration (public files)"

info "Generating SAS token for Azure Storage..."
EXPIRY=$(date -u -v+2H +"%Y-%m-%dT%H:%MZ" 2>/dev/null || date -u -d "+2 hours" +"%Y-%m-%dT%H:%MZ")
SAS_TOKEN=$(az storage account generate-sas \
  --account-name "$AZURE_STORAGE_ACCOUNT" \
  --permissions rwdlac \
  --resource-types sco \
  --services f \
  --expiry "$EXPIRY" \
  --output tsv)

PUBLIC_DEST="https://${AZURE_STORAGE_ACCOUNT}.file.core.windows.net/drupal-public?${SAS_TOKEN}"
PRIVATE_DEST="https://${AZURE_STORAGE_ACCOUNT}.file.core.windows.net/drupal-private?${SAS_TOKEN}"

info "Syncing public files from cPanel to Azure..."
# First, rsync from cPanel to a local temp dir, then azcopy to Azure
LOCAL_PUBLIC="$WORK_DIR/public"
mkdir -p "$LOCAL_PUBLIC"

rsync -az --progress \
  "${CPANEL_USER}@${CPANEL_HOST}:${CPANEL_DRUPAL_ROOT}/web/sites/default/files/" \
  "$LOCAL_PUBLIC/"

ok "Downloaded public files from cPanel"

info "Uploading public files to Azure File Share..."
azcopy copy "$LOCAL_PUBLIC/" "$PUBLIC_DEST" --recursive
ok "Public files uploaded"

step "Phase 2b: File Migration (private files)"

CPANEL_PRIVATE="${CPANEL_PRIVATE_DIR:-${CPANEL_DRUPAL_ROOT}/private}"

LOCAL_PRIVATE="$WORK_DIR/private"
mkdir -p "$LOCAL_PRIVATE"

info "Syncing private files from cPanel..."
rsync -az --progress \
  "${CPANEL_USER}@${CPANEL_HOST}:${CPANEL_PRIVATE}/" \
  "$LOCAL_PRIVATE/" 2>/dev/null || warn "No private files found or access denied"

if [ "$(ls -A "$LOCAL_PRIVATE" 2>/dev/null)" ]; then
  info "Uploading private files to Azure File Share..."
  azcopy copy "$LOCAL_PRIVATE/" "$PRIVATE_DEST" --recursive
  ok "Private files uploaded"
else
  warn "No private files to migrate"
fi

###############################################################################
# Summary
###############################################################################
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════╗"
echo "║                   Migration Complete!                        ║"
echo "╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  Database:      $AZURE_MYSQL_DB @ $AZURE_MYSQL_HOST"
echo "  Public files:  drupal-public share in $AZURE_STORAGE_ACCOUNT"
echo "  Private files: drupal-private share in $AZURE_STORAGE_ACCOUNT"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Build & push Docker image:  docker build -t <acr>.azurecr.io/app-drupal:latest ."
echo "  2. Deploy with:                ./scripts/azure-up.sh"
echo "  3. Run Drush updates:          az containerapp exec ... --command 'drush updb -y && drush cr'"
echo ""
