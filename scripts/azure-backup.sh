#!/usr/bin/env bash
###############################################################################
# azure-backup.sh — On-demand backup of the database and the file shares
#
# Usage: ./scripts/azure-backup.sh
#
# Environment variable overrides (skip prompts when set):
#   AZURE_RESOURCE_GROUP     — Azure resource group name
#   AZURE_APP_NAME           — web app or container app name (detected if unset)
#   AZURE_PLATFORM           — appservice (default) | containerapps
#   BACKUP_NON_INTERACTIVE   — set to 1 to skip every prompt (CI)
#   BACKUP_SKIP_DUMP         — set to 1 to skip the logical dump
#
# WHAT AZURE ALREADY GIVES YOU, AND WHAT IT DOES NOT
#
# MySQL Flexible Server has automated backups with point-in-time restore, and
# that covers most of what people mean by "we have backups". Three gaps:
#
#   * PITR restores INTO A NEW SERVER. It is not a file you can download, it is
#     no help if the resource group is deleted, and it cannot be inspected.
#   * `az mysql flexible-server backup create` makes an on-demand PITR point.
#     Also not downloadable. Useful before a risky change; not an archive.
#   * It restores the DATABASE ONLY. A site whose database is rolled back to
#     yesterday and whose file shares are current has broken every managed-file
#     reference in between — Drupal will render file fields pointing at files
#     that do not exist yet, or hold rows for files that were deleted.
#
# So this does all three: an on-demand PITR point, a snapshot of each file share
# taken at the same time so the two are consistent with each other, and a
# logical mysqldump via the Container Apps job, which is the only artifact of the
# three that can be restored anywhere else.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Shared prompt library ──
source "$SCRIPT_DIR/lib/prompt.sh"
source "$SCRIPT_DIR/lib/platform.sh"

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
# In CI every value arrives as an environment variable, so no prompt appears;
# BACKUP_NON_INTERACTIVE additionally makes a missing value a hard error rather
# than a prompt that would hang the run forever.
if [[ "${BACKUP_NON_INTERACTIVE:-0}" == "1" && -z "${AZURE_RESOURCE_GROUP:-}" ]]; then
  err "BACKUP_NON_INTERACTIVE=1 but AZURE_RESOURCE_GROUP is not set."
  exit 1
fi
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
  # Snapshots are incremental and near-instant, so taking both immediately after
  # the database backup point keeps the three roughly consistent. They are the
  # only recovery path for the file shares: the storage account's soft-delete
  # covers an accidental delete, not a corruption or a bad bulk edit.
  SNAPSHOT=$(az storage share snapshot \
    --name "$SHARE" \
    --account-name "$STORAGE_ACCOUNT" \
    --account-key "$STORAGE_KEY" \
    --query "snapshot" -o tsv)
  ok "Snapshot created: $SHARE @ $SNAPSHOT"
done

###############################################################################
# 3. Logical dump, via the Container Apps job.
#
# The one artifact here that is portable. It is written to the private file share
# rather than streamed to this machine, because the MySQL server has no public
# endpoint — it is on a delegated subnet with public access disabled, so a
# workstation cannot reach it at all. The job runs inside the environment, which
# can.
#
# Download it afterwards with `az storage file download` (see docs/operations.md).
###############################################################################
if [[ "${BACKUP_SKIP_DUMP:-0}" != "1" ]]; then
  step "Logical database dump"

  platform_resolve || true

  # drush sql:dump rather than a raw mysqldump: it reads the connection details
  # from the site's own settings, so it cannot dump the wrong database, and it
  # respects the table prefix.
  if [[ "${AZURE_PLATFORM:-}" == "appservice" ]]; then
    # /home is persistent and reachable over Kudu, so the artifact can actually
    # be downloaded afterwards — which is the property that distinguishes this
    # from the two Azure-internal backups above.
    DUMP_PATH="/home/backups/db-${TIMESTAMP}.sql"
    info "Dumping to ${DUMP_PATH}.gz on /home"
    if "$SCRIPT_DIR/kudu.sh" run "mkdir -p /home/backups && vendor/bin/drush sql:dump --gzip --result-file=${DUMP_PATH}"; then
      ok "Dump written. Download it with:"
      echo "    ./scripts/kudu.sh get ${DUMP_PATH}.gz ./db-${TIMESTAMP}.sql.gz"
    else
      warn "The dump command failed. The PITR point and share snapshots above still stand,"
      warn "but neither of them is portable — investigate before relying on this backup."
    fi

  elif [[ "${AZURE_PLATFORM:-}" == "containerapps" ]]; then
    JOB_NAME="${AZURE_APP_NAME}-drush"
    if ! az containerapp job show --name "$JOB_NAME" --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
      warn "Job '$JOB_NAME' not found; skipping the logical dump."
      warn "It is created by infra/modules/jobs.bicep. Without it the only backups are"
      warn "the PITR point and the share snapshots above — neither of which is portable."
    else
      DUMP_PATH="/var/www/html/private/.backups/db-${TIMESTAMP}.sql"
      info "Dumping to ${DUMP_PATH}.gz (on the drupal-private share)"
      # --args is comma-separated, so the command below must contain no commas.
      if az containerapp job start --name "$JOB_NAME" --resource-group "$RESOURCE_GROUP" \
           --command "/bin/sh" \
           --args "-c,mkdir -p /var/www/html/private/.backups && vendor/bin/drush sql:dump --gzip --result-file=${DUMP_PATH}" \
           --query name -o tsv >/dev/null 2>&1; then
        ok "Dump job started. It runs asynchronously; check it with:"
        echo "    az containerapp job execution list --name $JOB_NAME --resource-group $RESOURCE_GROUP -o table"
      else
        warn "Could not start the dump job."
      fi
    fi
  else
    warn "Could not determine the platform; skipping the logical dump."
  fi
fi

###############################################################################
# Summary
###############################################################################
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════╗"
echo "║                    Backup Complete!                          ║"
echo "╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  MySQL PITR point:  $BACKUP_NAME    (restores into a NEW server; not downloadable)"
echo "  File snapshots:    drupal-public, drupal-private"
echo "  Logical dump:      db-${TIMESTAMP}.sql.gz (portable — the only one that is)"
echo "  Timestamp:         $TIMESTAMP"
echo ""
echo -e "${YELLOW}A backup you have never restored is a hypothesis.${NC} Rehearse it: see"
echo "docs/operations.md, 'Restoring'."
echo ""
