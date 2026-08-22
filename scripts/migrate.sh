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
# Usage:
#   ./migrate.sh --audit    Inspect the source database and REPORT ONLY. Run this
#                           first, always: it tells you the collation and engine
#                           the data is actually on, which decides how the target
#                           must be configured.
#   ./migrate.sh            Full migration.
#
# Environment variable overrides (skip prompts when set):
#   CPANEL_HOST, CPANEL_USER, CPANEL_DB_NAME, CPANEL_DB_USER, CPANEL_DB_PASS
#   CPANEL_DRUPAL_ROOT (default: /home/$CPANEL_USER/public_html)
#   AZURE_RG
#
# ON THE AZURE SIDE, YOU ARE ASKED FOR NOTHING BUT THE RESOURCE GROUP.
#
# The host, the admin login, the database name and the storage account are all
# read back from Azure, and the password is read from Key Vault. Earlier guidance
# for this script was:
#
#   export AZURE_MYSQL_USER=drupaladmin
#   export AZURE_MYSQL_PASS="$MYSQL_ADMIN_PASSWORD"
#
# Both lines are now unnecessary and were actively harmful: `export` puts the
# credential in the shell history and in every child process for the rest of the
# session, and asking a human to supply a value the deployment already knows
# invites them to keep a copy of it somewhere. See scripts/lib/secrets.sh.
#
# Each is still honoured if set, so CI can inject one and an unusual deployment
# can override the discovery.
#
# NOTE: the MySQL server this template provisions has NO public endpoint — it is
# on a delegated subnet with public access disabled. So the import step below can
# only run from inside the VNet. Two options:
#   * Run this script from a VM or Container Apps job inside the VNet, or
#   * temporarily allow your address, import, then remove the rule.
# The second is quicker and is what most people do; do not forget the removal.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Shared libraries ──
source "$SCRIPT_DIR/lib/prompt.sh"
source "$SCRIPT_DIR/lib/secrets.sh"

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

AUDIT_ONLY=false
if [[ "${1:-}" == "--audit" ]]; then
  AUDIT_ONLY=true
fi

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

# Working directory for temporary files
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

###############################################################################
# Phase 0: Audit the source.
#
# This runs before anything else, every time, and it is the step whose absence
# causes the migration failure that is hardest to diagnose — because it does not
# appear during the migration at all.
#
# Drupal's schema layer appends COLLATE to CREATE TABLE from the collation set in
# settings.php. If the DATABASE default on the target does not match the data you
# are importing, everything works right up until the first `drush updb` creates a
# new table — which gets the target's default — and then any query joining that
# table to an imported one fails outright with:
#
#   ERROR 1267 Illegal mix of collations ... for operation '='
#
# On MySQL 8 the server default is utf8mb4_0900_ai_ci. A site coming off cPanel
# is typically utf8mb4_general_ci (Drupal's own default) or utf8mb4_unicode_ci
# (common in older or migrated sites). Those are three different answers and only
# the source data knows which one is right.
###############################################################################
step "Phase 0: Auditing the source database"

AUDIT_SQL="
SELECT 'default_collation', @@collation_database
UNION ALL SELECT 'default_charset', @@character_set_database;
SELECT table_collation, COUNT(*) AS tables
  FROM information_schema.tables
 WHERE table_schema = DATABASE() GROUP BY table_collation ORDER BY tables DESC;
SELECT engine, COUNT(*) AS tables
  FROM information_schema.tables
 WHERE table_schema = DATABASE() GROUP BY engine;
SELECT 'server_version', VERSION();
"
# ---------------------------------------------------------------------------
# The cPanel password is delivered over STDIN, never in the command.
#
# `mysql -p<password>` puts the credential in the remote host's argv, where any
# other user on the box can read it with `ps`. On shared hosting — which is
# exactly what this script migrates away from — that is not hypothetical.
# Interpolating it into the ssh command string is no better: the remote shell is
# invoked as `sh -c '<the whole string>'`, so the password appears in that
# process's argv too.
#
# So: the remote command is a fixed string containing no secret, its first line
# of stdin is the password, and everything after that first line is the SQL the
# client reads. MYSQL_PWD keeps it in the process environment, which on Linux is
# readable only by the same user or root.
#
# The non-secret values are still %q-escaped, because a database name with a
# shell metacharacter in it would otherwise break the remote command.
#
# `IFS= read -r` and not `read -r`: the latter strips leading and trailing
# whitespace, so a password that begins or ends with a space would arrive
# corrupted — and the failure would present as a wrong password.
_esc_user=$(printf '%q' "$CPANEL_DB_USER")
_esc_db=$(printf '%q' "$CPANEL_DB_NAME")

AUDIT_OUT=$(
  { printf '%s\n' "$CPANEL_DB_PASS"; printf '%s\n' "$AUDIT_SQL"; } \
    | ssh "${CPANEL_USER}@${CPANEL_HOST}" \
        "IFS= read -r _pw; MYSQL_PWD=\"\$_pw\" mysql -t -u ${_esc_user} ${_esc_db}" \
        2>/dev/null || true
)

if [[ -z "$AUDIT_OUT" ]]; then
  warn "Could not audit the source database. Proceeding blind is a bad idea —"
  warn "verify the credentials and re-run with --audit."
else
  echo "$AUDIT_OUT"
fi

SRC_COLLATION=$(grep -oE 'utf8mb[34]_[a-z0-9_]+' <<< "$AUDIT_OUT" | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
if [[ -n "${SRC_COLLATION:-}" ]]; then
  echo ""
  ok "Dominant source collation: ${BOLD}${SRC_COLLATION}${NC}"
  echo ""
  echo -e "${YELLOW}Set BOTH of these to that value before deploying, or the first${NC}"
  echo -e "${YELLOW}drush updb after the migration will create untraversable tables:${NC}"
  echo ""
  echo "  infra/<platform>/main.bicepparam   param mysqlCollation = '${SRC_COLLATION}'"
  echo "  (or)  export MYSQL_COLLATION='${SRC_COLLATION}' before ./scripts/azure-up.sh"
  echo ""
  echo "The container app passes it through as DRUPAL_DB_COLLATION, so the"
  echo "settings overlay and the database default stay in agreement."
  echo ""
fi

# MyISAM tables are worth naming explicitly: Azure MySQL Flexible Server supports
# the engine but it has no transactions and no crash recovery, and Drupal has
# assumed InnoDB for a decade. A cPanel site frequently has a few left over.
if grep -qi 'MyISAM' <<< "$AUDIT_OUT"; then
  warn "The source has MyISAM tables. Convert them to InnoDB before or after the"
  warn "import, or they will silently be excluded from --single-transaction's"
  warn "consistency guarantee during the dump:"
  warn "  ALTER TABLE <name> ENGINE=InnoDB;"
fi

if $AUDIT_ONLY; then
  ok "Audit complete. No changes were made."
  exit 0
fi

# ── Azure destination ──
#
# Resolved only now, after the audit. `--audit` is the step you run first and
# repeatedly, and it has no business touching the target at all.
step "Azure destination"

# The one thing a human has to supply, because it is a choice rather than a fact.
prompt_val AZURE_RG "Azure resource group"

# Everything else is a fact about the deployment, so read it rather than ask.
# AZURE_RESOURCE_GROUP is what the shared libraries look at.
export AZURE_RESOURCE_GROUP="$AZURE_RG"
discover_deployment "$AZURE_RG" || exit 1

# And the password comes from Key Vault. The operator never sees it, and it is
# unset again as soon as the import is done.
resolve_secret AZURE_MYSQL_PASS "$KV_SECRET_DB_PASSWORD" \
  "Azure MySQL admin password" "$AZURE_RG" || exit 1
require_secret AZURE_MYSQL_PASS "importing into the target database" || exit 1

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

info "Exporting database from cPanel via SSH..."
# --no-tablespaces: without it, mysqldump 8 emits a TABLESPACE clause and needs
# the PROCESS privilege, which a shared-hosting database user does not have. The
# dump fails with "Access denied; you need the PROCESS privilege", which reads
# like a credentials problem and is not.
#
# --default-character-set=utf8mb4: mysqldump's default is utf8 (3-byte) on older
# clients, which mangles any 4-byte character — emoji, some CJK — into '?' with
# no error. The corruption is only visible if you go looking for it.
#
# --hex-blob: keeps binary column contents intact through the text dump.
#
# The password goes over stdin, for the reason explained at the audit above: it
# must not appear in the remote host's process list.
printf '%s\n' "$CPANEL_DB_PASS" \
  | ssh "${CPANEL_USER}@${CPANEL_HOST}" \
      "IFS= read -r _pw; MYSQL_PWD=\"\$_pw\" mysqldump --single-transaction --quick \
        --routines --triggers --no-tablespaces --default-character-set=utf8mb4 \
        --hex-blob -u ${_esc_user} ${_esc_db}" \
  > "$DB_DUMP"

DUMP_SIZE=$(du -h "$DB_DUMP" | cut -f1)
ok "Database export complete ($DUMP_SIZE)"

info "Sanitizing dump..."
# DEFINER clauses name a user that does not exist on the target, and the import
# fails with "The user specified as a definer does not exist" — on Azure it
# cannot exist, because SUPER is not granted to the admin account so a definer
# cannot be created either.
#
# ROW_FORMAT=FIXED is invalid for InnoDB and is a leftover from MyISAM-era dumps.
sed -i '.bak' \
  -e 's/DEFINER=[^ ]* / /g' \
  -e 's/ROW_FORMAT=FIXED//g' \
  "$DB_DUMP"

# Report rather than rewrite the collation. An earlier approach piped the dump
# through `sed s/utf8mb4_0900_ai_ci/utf8mb4_unicode_ci/g`, which was protective
# while the target was MySQL 5.7 — 5.7 does not know 0900_ai_ci at all and fails
# outright. Against a MySQL 8 target it protects nothing: it silently changes the
# comparison and sort semantics of the incoming data, with no warning and no
# record of what was altered. Detecting and telling the operator is the right
# behaviour, because the decision is theirs.
if grep -qi 'utf8mb4_0900_ai_ci' "$DB_DUMP"; then
  warn "The dump contains utf8mb4_0900_ai_ci."
  warn "If the target database default is something else, those tables will land on a"
  warn "different collation from the rest and joins between them will fail with"
  warn "ERROR 1267. Importing unchanged — decide deliberately, then normalise with:"
  warn "  ALTER TABLE <name> CONVERT TO CHARACTER SET utf8mb4 COLLATE <target>;"
fi
ok "Sanitization complete"

info "Importing database to Azure MySQL ($AZURE_MYSQL_HOST)..."
# NO_AUTO_VALUE_ON_ZERO is required, not optional. Drupal's anonymous user is
# uid 0, and without this flag MySQL treats an inserted 0 in an AUTO_INCREMENT
# column as "assign the next value" — so the anonymous user silently becomes
# uid 1 (or whatever is next), colliding with the site's admin account. The
# symptom is that anonymous visitors appear to be logged in as the administrator.
# It is a data-integrity failure that the import reports as complete success.
{
  echo "SET SESSION sql_mode='NO_AUTO_VALUE_ON_ZERO';"
  echo "SET SESSION FOREIGN_KEY_CHECKS=0;"
  cat "$DB_DUMP"
} | MYSQL_PWD="$AZURE_MYSQL_PASS" mysql \
  -h "$AZURE_MYSQL_HOST" \
  -u "$AZURE_MYSQL_USER" \
  --ssl-mode=REQUIRED \
  --default-character-set=utf8mb4 \
  "$AZURE_MYSQL_DB"

ok "Database imported"

# Verify the thing the flag above protects, rather than assuming it worked.
info "Verifying the anonymous user survived the import as uid 0..."
ANON=$(MYSQL_PWD="$AZURE_MYSQL_PASS" mysql -h "$AZURE_MYSQL_HOST" -u "$AZURE_MYSQL_USER" \
  --ssl-mode=REQUIRED --batch --skip-column-names "$AZURE_MYSQL_DB" \
  -e "SELECT COUNT(*) FROM users WHERE uid = 0" 2>/dev/null || echo "?")
if [[ "$ANON" == "1" ]]; then
  ok "Anonymous user is uid 0."
elif [[ "$ANON" == "?" ]]; then
  warn "Could not verify (non-default table prefix?). Check by hand:"
  warn "  SELECT uid FROM <prefix>users ORDER BY uid LIMIT 3;   -- must start at 0"
else
  err "The anonymous user is NOT uid 0 (found $ANON rows). Anonymous visitors would"
  err "be treated as another account. Fix before serving traffic:"
  err "  SET SESSION sql_mode='NO_AUTO_VALUE_ON_ZERO';"
  err "  UPDATE users SET uid = 0 WHERE uid NOT IN (SELECT uid FROM users_field_data);"
fi

# Report the resulting collation spread, so a mismatch is caught now rather than
# at the first module update months later.
info "Post-import collation check..."
MYSQL_PWD="$AZURE_MYSQL_PASS" mysql -h "$AZURE_MYSQL_HOST" -u "$AZURE_MYSQL_USER" \
  --ssl-mode=REQUIRED -t "$AZURE_MYSQL_DB" \
  -e "SELECT @@collation_database AS db_default;
      SELECT table_collation, COUNT(*) AS tables FROM information_schema.tables
       WHERE table_schema = DATABASE() GROUP BY table_collation;" 2>/dev/null || true
echo ""
warn "Every row above must show the SAME collation, and it must equal db_default."
warn "If not, see docs/migrating-a-site.md before deploying." 

# The database work is done, so the credentials are no longer needed. Unset them
# before the file phase: nothing below touches MySQL, and a credential that does
# not exist cannot leak into a subshell or a core file.
forget_secrets AZURE_MYSQL_PASS CPANEL_DB_PASS

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
echo "  1. Set the collation to match the source (see the Phase 0 audit above):"
echo "       export MYSQL_COLLATION='<from the audit>'"
echo "  2. Deploy the infrastructure:  ./scripts/azure-up.sh"
echo "  3. Build the first image:      az acr build --registry <acr> --image drupal:latest \\"
echo "                                   --build-arg COMMIT_SHA=\$(git rev-parse --short=12 HEAD) ."
echo ""
echo "  There is deliberately no step for running drush updb by hand. The container"
echo "  entrypoint runs updb, config:import and cache:rebuild on the first boot of a"
echo "  new image, under a lock, with a pre-deploy backup — see docker-entrypoint.sh."
echo ""
echo "  If you temporarily opened the MySQL firewall to run this import, close it now."
echo ""
