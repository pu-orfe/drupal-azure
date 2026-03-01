#!/usr/bin/env bash
###############################################################################
# azure-up.sh — Deploy / Update the Bicep infrastructure stack
#
# Usage: ./scripts/azure-up.sh [--what-if]
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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

# ── Defaults ──
LOCATION="${AZURE_LOCATION:-eastus}"
BASE_NAME="${AZURE_BASE_NAME:-drupal}"
ENVIRONMENT="${AZURE_ENVIRONMENT:-prod}"
WHAT_IF=false

if [[ "${1:-}" == "--what-if" ]]; then
  WHAT_IF=true
  warn "Running in what-if mode (no changes will be made)"
fi

echo -e "${BOLD}${CYAN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║              Azure Infrastructure Deployment                ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Pre-flight checks ──
step "Pre-flight checks"

if ! command -v az &>/dev/null; then
  err "Azure CLI (az) not found. Install: https://aka.ms/install-azure-cli"
  exit 1
fi

ACCOUNT=$(az account show --query '{name:name, id:id}' -o tsv 2>/dev/null || true)
if [[ -z "$ACCOUNT" ]]; then
  err "Not logged in to Azure. Run: az login"
  exit 1
fi
ok "Logged in to Azure: $ACCOUNT"

# ── Prompt for MySQL password if not set ──
if [[ -z "${MYSQL_ADMIN_PASSWORD:-}" ]]; then
  echo -en "${YELLOW}Enter MySQL admin password: ${NC}"
  read -rs MYSQL_ADMIN_PASSWORD
  echo ""
  export MYSQL_ADMIN_PASSWORD
fi

# ── Deploy ──
step "Deploying Bicep template"

DEPLOY_CMD=(
  az deployment sub create
  --location "$LOCATION"
  --template-file "$PROJECT_ROOT/infra/main.bicep"
  --parameters baseName="$BASE_NAME"
  --parameters environment="$ENVIRONMENT"
  --parameters mysqlAdminPassword="$MYSQL_ADMIN_PASSWORD"
)

if $WHAT_IF; then
  "${DEPLOY_CMD[@]}" --what-if
  ok "What-if complete (no changes made)"
else
  echo ""
  info "This will create/update resources in subscription."
  read -rp "$(echo -e "${YELLOW}Proceed? (y/N): ${NC}")" confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }

  OUTPUT=$("${DEPLOY_CMD[@]}" -o json)

  ok "Deployment complete!"
  echo ""
  echo -e "${GREEN}${BOLD}Outputs:${NC}"
  echo "$OUTPUT" | python3 -c "
import sys, json
out = json.load(sys.stdin).get('properties',{}).get('outputs',{})
for k, v in out.items():
    print(f'  {k}: {v[\"value\"]}')
" 2>/dev/null || echo "$OUTPUT" | jq '.properties.outputs | to_entries[] | "  \(.key): \(.value.value)"' -r 2>/dev/null || true
fi
