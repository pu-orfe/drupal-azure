#!/usr/bin/env bash
###############################################################################
# azure-up.sh — Deploy / Update the Bicep infrastructure stack
#
# Usage: ./scripts/azure-up.sh [--what-if]
#
# Environment variable overrides (skip prompts when set):
#   AZURE_SUBSCRIPTION    — Azure subscription ID
#   AZURE_LOCATION        — Azure region (default: eastus)
#   AZURE_BASE_NAME       — Resource name prefix (default: drupal, max 11 chars)
#   AZURE_ENVIRONMENT     — Deployment environment (dev|staging|prod)
#   AZURE_PLATFORM        — appservice (default) | containerapps
#   DRUPAL_TRUSTED_HOSTS  — comma-separated custom domains
#   MIN_REPLICAS          — 0 to enable scale-to-zero (default 1)
#
# ON SECRETS: this script does NOT prompt for the MySQL password or the Drupal
# hash salt, and there is no placeholder default for either.
#
# It generates them on the first run and stores them in Key Vault; on every
# subsequent run it passes empty values, which the template treats as "leave the
# vault's existing secrets alone". Nothing is ever typed, pasted, echoed or held
# in a shell variable that outlives the deployment.
#
# The reason is a specific failure: a CHANGEME-style default that nothing forces
# you to replace becomes the production credential, and then it is committed to
# the repository. A prompt is better but still ends up in a password manager, a
# terminal scrollback, or a colleague's message. The hash salt is the worse half
# — Drupal derives CSRF tokens and one-time login links from it, so a known salt
# is a forgery route needing no foothold at all.
#
# To rotate later: scripts/rotate-secrets.sh
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Shared libraries ──
source "$SCRIPT_DIR/lib/prompt.sh"
source "$SCRIPT_DIR/lib/secrets.sh"
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

# ── Parse args ──
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

# ── Interactive prompts (skipped when env vars are set) ──
step "Configuration"

prompt_subscription

prompt_val AZURE_LOCATION "Azure region" "eastus"
LOCATION="$AZURE_LOCATION"

prompt_val AZURE_BASE_NAME "Resource name prefix" "drupal"
BASE_NAME="$AZURE_BASE_NAME"

prompt_select AZURE_ENVIRONMENT "Deployment environment" "prod" "staging" "dev"
ENVIRONMENT="$AZURE_ENVIRONMENT"

# ── Platform ───────────────────────────────────────────────────────────────
# App Service is the default. It is what both production deployments this
# template is modelled on actually run, and the reasoning is in
# docs/choosing-a-platform.md — briefly: Drupal is a stateful application with a slow
# boot and a filesystem, and App Service's persistent /home share, authenticated
# Kudu command channel and always-warm single instance match that. Container Apps
# is the better answer when you need horizontal scale or gated per-revision
# traffic, and its template is kept alongside for exactly that case.
prompt_select AZURE_PLATFORM "Hosting platform" "appservice" "containerapps"
TEMPLATE="$PROJECT_ROOT/$(platform_template)"
info "Template: ${TEMPLATE#"$PROJECT_ROOT"/}"

if (( ${#BASE_NAME} > 11 )); then
  # Enforced here as well as in the template. The storage account name is
  # st<baseName><13-char uniqueString> against Azure's 24-character cap, so a
  # longer base name produces an invalid name — and without this check the
  # deployment fails at the storage step, after the VNet and the MySQL server
  # have already been created.
  err "AZURE_BASE_NAME must be 11 characters or fewer (got ${#BASE_NAME}: '$BASE_NAME')."
  exit 1
fi

prompt_val DRUPAL_TRUSTED_HOSTS "Custom domains Drupal should accept (comma-separated, blank for none)" ""

# Ingress allow-list, as a JSON array. Empty means open to the internet.
# Container Apps requires every rule to share one action, so an Allow list
# implicitly denies everything else:
#   AZURE_IP_ALLOW_LIST='[{"name":"campus","ipAddressRange":"192.0.2.0/24","action":"Allow"}]'
IP_ALLOW_LIST="${AZURE_IP_ALLOW_LIST:-[]}"
if ! python3 -c "import json,sys;json.loads(sys.argv[1])" "$IP_ALLOW_LIST" 2>/dev/null; then
  err "AZURE_IP_ALLOW_LIST is not valid JSON. Nothing was deployed."
  exit 1
fi
if [[ "$IP_ALLOW_LIST" != "[]" ]]; then
  info "Ingress allow-list: $IP_ALLOW_LIST"
  warn "Everything not listed will be refused, including your own address unless it is in there."
fi

# ── Secret material ─────────────────────────────────────────────────────────
step "Secrets"


# Does a vault for this deployment already hold the secrets? If so this is a
# redeploy and the existing values must be left alone: passing empty parameters
# makes the template skip the secret resources entirely.
EXISTING_KV=$(az keyvault list \
  --query "[?starts_with(name, 'kv-${BASE_NAME}-')].name | [0]" -o tsv 2>/dev/null || true)

# Secret names come from lib/secrets.sh, so the vault, this script and
# rotate-secrets.sh cannot drift apart — a mismatch there presents as "the vault
# does not have it", which sends you looking at permissions instead of at a typo.
if [[ -n "${EXISTING_KV:-}" ]] && \
   MYSQL_ADMIN_PASSWORD="$(keyvault_get "$EXISTING_KV" "$KV_SECRET_DB_PASSWORD")" && \
   [[ -n "$MYSQL_ADMIN_PASSWORD" ]]; then
  ok "Key Vault '$EXISTING_KV' already holds the secrets — reusing them."
  # The MySQL resource needs the literal password at deploy time (an ARM resource
  # cannot read a Key Vault reference for that property), so it is read back
  # rather than reset. Passing a NEW password here would reset the server's admin
  # password on every redeploy and break the running app at its next restart.
  DRUPAL_HASH_SALT=""
elif [[ -n "${EXISTING_KV:-}" ]]; then
  # A vault exists but its secret cannot be read. Stopping is the only safe
  # option: generating a fresh password here would reset the server's while the
  # app keeps trying the old one.
  err "Key Vault '$EXISTING_KV' exists but '$KV_SECRET_DB_PASSWORD' could not be read."
  err "You need 'Key Vault Secrets User' on it. Do not guess a value — an empty or"
  err "new password would be written to the server and take the site down."
  err "See docs/secrets.md."
  exit 1
else
  info "First deployment: generating a MySQL password and a Drupal hash salt."
  MYSQL_ADMIN_PASSWORD="$(generate_secret)"
  DRUPAL_HASH_SALT="$(openssl rand -hex 32)"
  ok "Generated. They go straight into Key Vault and are never printed."
fi

# The deploying principal needs data-plane access to seed the vault. Subscription
# Owner is not enough: Owner is a control-plane role, and Key Vault secret access
# is a separate data-plane role. Without this grant a fresh deployment creates a
# vault it cannot write to.
DEPLOYER_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)
if [[ -z "$DEPLOYER_OBJECT_ID" ]]; then
  # Service principal (CI) rather than a user.
  DEPLOYER_APP_ID=$(az account show --query "user.name" -o tsv 2>/dev/null || true)
  DEPLOYER_OBJECT_ID=$(az ad sp show --id "$DEPLOYER_APP_ID" --query id -o tsv 2>/dev/null || true)
fi
[[ -n "$DEPLOYER_OBJECT_ID" ]] \
  && info "Granting Key Vault Secrets Officer to the deploying principal." \
  || warn "Could not determine the deploying principal; you may need to grant Key Vault access by hand."

# ── Deploy ──
step "Deploying Bicep template"

info "Location:    $LOCATION"
info "Base name:   $BASE_NAME"
info "Environment: $ENVIRONMENT"
info "Trusted hosts: ${DRUPAL_TRUSTED_HOSTS:-<container apps domain only>}"

DEPLOY_CMD=(
  az deployment sub create
  --location "$LOCATION"
  --name "drupal-${AZURE_PLATFORM}-${ENVIRONMENT}-$(date -u +%Y%m%d%H%M%S)"
  --template-file "$TEMPLATE"
  --parameters baseName="$BASE_NAME"
  --parameters environment="$ENVIRONMENT"
  --parameters mysqlAdminPassword="$MYSQL_ADMIN_PASSWORD"
  --parameters drupalHashSalt="$DRUPAL_HASH_SALT"
  --parameters deployerPrincipalId="$DEPLOYER_OBJECT_ID"
  --parameters trustedHosts="${DRUPAL_TRUSTED_HOSTS:-}"
  --parameters ipAllowList="$IP_ALLOW_LIST"
)

# Platform-specific parameters. Kept out of the shared list because passing a
# parameter a template does not declare is a hard deployment error, not a warning.
if [[ "$AZURE_PLATFORM" == "containerapps" ]]; then
  DEPLOY_CMD+=(--parameters minReplicas="${MIN_REPLICAS:-1}")
else
  DEPLOY_CMD+=(--parameters appServiceSku="${APP_SERVICE_SKU:-B1}")
fi

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

  # The secrets must not survive this process. They are in Key Vault; anything
  # still in the environment ends up in a subshell, a `set` dump, or a core file.
  unset MYSQL_ADMIN_PASSWORD DRUPAL_HASH_SALT

  ACR=$(echo "$OUTPUT" | python3 -c "import sys,json;print(json.load(sys.stdin)['properties']['outputs']['acrName']['value'])" 2>/dev/null || true)
  APP=$(echo "$OUTPUT" | python3 -c "
import sys, json
out = json.load(sys.stdin)['properties']['outputs']
# containerAppName on the ACA template, appName on the App Service one.
print((out.get('appName') or out.get('containerAppName') or {}).get('value',''))" 2>/dev/null || true)
  RG=$(echo "$OUTPUT" | python3 -c "import sys,json;print(json.load(sys.stdin)['properties']['outputs']['resourceGroupName']['value'])" 2>/dev/null || true)

  echo ""
  echo -e "${YELLOW}${BOLD}Next: build and push the first image.${NC}"
  echo ""
  echo "The app was created pointing at an image tag that does not exist yet, so it"
  echo "will not serve until you push one. That is expected on a first deployment"
  echo "and is not a failure."
  echo ""
  echo "  # Builds in Azure — no local Docker needed, and the build runs next to"
  echo "  # the registry rather than pushing gigabytes up from a laptop."
  echo "  az acr build --registry ${ACR:-<acr>} \\"
  echo "    --image drupal:\$(git rev-parse --short=12 HEAD) \\"
  echo "    --image drupal:latest \\"
  echo "    --build-arg COMMIT_SHA=\$(git rev-parse --short=12 HEAD) ."
  echo ""
  echo "  ./scripts/rollback.sh --current   # confirm what is running"
  echo "  ./scripts/azure-logs.sh           # watch the boot sequence"
  echo ""
  if [[ "$AZURE_PLATFORM" == "appservice" ]]; then
    echo "  # App Service does not pick up a new tag on its own — point it at the image:"
    echo "  az webapp config container set -n ${APP:-<app>} -g ${RG:-<rg>} \\"
    echo "    --container-image-name ${ACR:-<acr>}.azurecr.io/drupal:\$(git rev-parse --short=12 HEAD)"
    echo "  az webapp restart -n ${APP:-<app>} -g ${RG:-<rg>}"
  fi
  echo ""
  echo -e "${YELLOW}Then wire up GitHub Actions:${NC} see docs/github-actions.md"
  echo "  Repository variables:"
  echo "    AZURE_RESOURCE_GROUP=${RG:-?}"
  echo "    AZURE_ACR_NAME=${ACR:-?}"
  echo "    AZURE_APP_NAME=${APP:-?}"
  echo "    AZURE_PLATFORM=${AZURE_PLATFORM}"
  echo ""
fi
