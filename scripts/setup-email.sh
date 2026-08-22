#!/usr/bin/env bash
###############################################################################
# setup-email.sh — finish wiring up outbound email
#
#   ./scripts/setup-email.sh            # configure, then print the consent steps
#   ./scripts/setup-email.sh --status   # is it authorised and working?
#   ./scripts/setup-email.sh --test you@example.edu
#
# WHAT IS AND IS NOT AUTOMATED
#
# The Logic App and the Office 365 connection are created by `azure-up.sh`, from
# infra/modules/email.bicep. This script does the two things that cannot happen
# during a template deployment:
#
#   1. Reads the workflow's callback URL — which only exists after the workflow
#      does — strips its SAS signature, and stores the result on the app.
#   2. Tells you where to click to authorise the connection.
#
# Step 2 is irreducibly manual, and that is the point rather than a gap: the
# consent proves a human controls the mailbox being sent from. No service
# principal can assert that on their behalf, which is exactly why this approach
# needs no mailbox credential and no tenant-wide Mail.Send grant.
###############################################################################
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/prompt.sh"
source "$SCRIPT_DIR/lib/platform.sh"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'
info() { printf '%s[INFO]%s  %s\n' "$BLUE" "$NC" "$*"; }
ok()   { printf '%s[OK]%s    %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s[WARN]%s  %s\n' "$YELLOW" "$NC" "$*"; }
err()  { printf '%s[ERROR]%s %s\n' "$RED" "$NC" "$*" >&2; }
step() { printf '\n%s%s▸ %s%s\n' "$CYAN" "$BOLD" "$*" "$NC"; }

MODE="configure"
TEST_TO=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --status)  MODE="status"; shift ;;
    --test)    MODE="test"; TEST_TO="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) err "Unknown argument: $1"; exit 1 ;;
  esac
done

prompt_resource_group
platform_resolve || exit 1
RG="$AZURE_RESOURCE_GROUP"
[[ -n "${AZURE_APP_NAME:-}" ]] || { err "No app found in $RG. Deploy first: ./scripts/azure-up.sh"; exit 1; }

SUB_ID=$(az account show --query id -o tsv)

# Discover rather than ask — these are facts about the deployment.
LOGIC_APP="${AZURE_LOGIC_APP_NAME:-$(az resource list -g "$RG" \
  --resource-type Microsoft.Logic/workflows --query '[0].name' -o tsv 2>/dev/null || true)}"
CONNECTION="${AZURE_MAIL_CONNECTION_NAME:-$(az resource list -g "$RG" \
  --resource-type Microsoft.Web/connections --query '[0].name' -o tsv 2>/dev/null || true)}"

if [[ -z "$LOGIC_APP" || -z "$CONNECTION" ]]; then
  err "No Logic App or Office 365 connection found in '$RG'."
  err "They are created by the infrastructure deployment. If you deployed with"
  err "deployEmail=false, re-run: ./scripts/azure-up.sh"
  exit 1
fi

###############################################################################
# Is the connection authorised?
#
# `properties.statuses[].status` reports "Connected" once someone has consented,
# and "Error" until then. Worth checking rather than assuming, because an
# unauthorised connection fails at SEND time — the first anyone notices is a
# password-reset email that never arrived.
###############################################################################
connection_status() {
  az resource show -g "$RG" --resource-type Microsoft.Web/connections --name "$CONNECTION" \
    --query "properties.statuses[0].status" -o tsv 2>/dev/null || echo "Unknown"
}

print_consent_instructions() {
  local conn_id
  conn_id=$(az resource show -g "$RG" --resource-type Microsoft.Web/connections \
    --name "$CONNECTION" --query id -o tsv)
  printf '\n%s%s' "$YELLOW$BOLD" "══════════════════════════════════════════════════════════════"
  printf '\n  ACTION REQUIRED — authorise the Office 365 connection\n'
  printf '══════════════════════════════════════════════════════════════%s\n\n' "$NC"
  printf 'This cannot be scripted. Signing in is how a human proves they control\n'
  printf 'the mailbox this site will send as — which is the reason the deployment\n'
  printf 'needs no mailbox password and no tenant-wide Mail.Send permission.\n\n'
  printf '  1. Open:\n'
  printf '     %shttps://portal.azure.com/#@/resource%s/edit%s\n\n' "$CYAN" "$conn_id" "$NC"
  printf '  2. Click %sAuthorize%s.\n' "$BOLD" "$NC"
  printf '  3. Sign in as the account the site should send mail AS.\n'
  printf '     Every message will come from this mailbox, so use a shared or\n'
  printf '     service mailbox — not a person who might leave.\n'
  printf '  4. Click %sSave%s at the bottom of the blade.\n\n' "$BOLD" "$NC"
  printf 'Then confirm and send yourself a test:\n'
  printf '  %s./scripts/setup-email.sh --status%s\n' "$CYAN" "$NC"
  printf '  %s./scripts/setup-email.sh --test you@example.edu%s\n\n' "$CYAN" "$NC"
}

###############################################################################
# --status
###############################################################################
if [[ "$MODE" == "status" ]]; then
  step "Email delivery status"
  st="$(connection_status)"
  printf '  Logic App:   %s\n  Connection:  %s\n  Status:      ' "$LOGIC_APP" "$CONNECTION"
  case "$st" in
    Connected) printf '%sConnected%s\n' "$GREEN" "$NC" ;;
    *)         printf '%s%s%s\n' "$YELLOW" "$st" "$NC" ;;
  esac

  case "$AZURE_PLATFORM" in
    appservice)
      url=$(az webapp config appsettings list -n "$AZURE_APP_NAME" -g "$RG" \
        --query "[?name=='AZURE_LOGIC_APP_MAIL_URL'].value | [0]" -o tsv 2>/dev/null || true) ;;
    containerapps)
      url=$(az containerapp show -n "$AZURE_APP_NAME" -g "$RG" \
        --query "properties.template.containers[0].env[?name=='AZURE_LOGIC_APP_MAIL_URL'].value | [0]" -o tsv 2>/dev/null || true) ;;
  esac
  printf '  App setting: %s\n' "${url:+set}${url:-MISSING — re-run without --status}"

  # Report the two access controls, because "it works" and "anyone can send mail
  # through it" are compatible states.
  ips=$(az resource show -g "$RG" --resource-type Microsoft.Logic/workflows --name "$LOGIC_APP" \
    --query "length(properties.accessControl.triggers.allowedCallerIpAddresses)" -o tsv 2>/dev/null || echo 0)
  claims=$(az resource show -g "$RG" --resource-type Microsoft.Logic/workflows --name "$LOGIC_APP" \
    --query "properties.accessControl.triggers.openAuthenticationPolicies.policies.aad_policy.claims[].name" -o tsv 2>/dev/null | tr '\n' ' ')
  printf '  IP allow-list: %s entr%s\n' "$ips" "$([[ "$ips" == "1" ]] && echo y || echo ies)"
  printf '  AAD claims:    %s\n' "${claims:-none}"
  grep -q 'sub' <<<"$claims" \
    && ok "the trigger is pinned to a single identity" \
    || warn "no 'sub' claim: any principal in the tenant with an ARM token can trigger this"

  [[ "$st" == "Connected" ]] || { echo; print_consent_instructions; exit 2; }
  exit 0
fi

###############################################################################
# --test
###############################################################################
if [[ "$MODE" == "test" ]]; then
  [[ -n "$TEST_TO" ]] || { err "--test needs a recipient address"; exit 2; }
  step "Sending a test message to $TEST_TO"
  if [[ "$(connection_status)" != "Connected" ]]; then
    err "The connection is not authorised yet, so this would fail."
    print_consent_instructions
    exit 2
  fi
  # Through the site's own mail plugin, not by calling the Logic App directly.
  # Calling the workflow from here would prove the workflow works and say nothing
  # about whether DRUPAL can reach it — which is the part that actually breaks.
  if "$SCRIPT_DIR/drush.sh" -- php:eval \
      "\Drupal::service('plugin.manager.mail')->mail('system','test','$TEST_TO',\Drupal::languageManager()->getDefaultLanguage()->getId(),['context'=>['subject'=>'Test from setup-email.sh','message'=>'If you are reading this, outbound email works.']]);"; then
    ok "Handed to Drupal's mail system. Check the inbox."
    info "If nothing arrives, look at the Logic App's run history:"
    printf '    az rest --method get --uri "/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Logic/workflows/%s/runs?api-version=2016-06-01&\\$top=5"\n' \
      "$SUB_ID" "$RG" "$LOGIC_APP"
  else
    err "Drupal could not send. Check that the mailer module is enabled:"
    printf '    ./scripts/drush.sh pm:list --filter=logic_app_mailer\n'
    exit 1
  fi
  exit 0
fi

###############################################################################
# configure (default)
###############################################################################
step "Wiring $AZURE_APP_NAME to $LOGIC_APP"

# ---------------------------------------------------------------------------
# The callback URL, with its signature removed.
#
# listCallbackUrl returns a URL carrying a SAS signature — a bearer credential in
# a query string that grants anyone holding it the right to trigger the workflow.
# Storing that would make the AAD policy decorative: a leaked app setting would be
# enough to send mail as the institution.
#
# Stripping the query string leaves an endpoint that ONLY accepts a
# managed-identity token. The mail plugin fetches one per send from the instance
# metadata endpoint; nothing durable is stored.
# ---------------------------------------------------------------------------
info "Reading the trigger callback URL"
callback=$(az rest --method post \
  --uri "/subscriptions/${SUB_ID}/resourceGroups/${RG}/providers/Microsoft.Logic/workflows/${LOGIC_APP}/triggers/manual/listCallbackUrl?api-version=2016-06-01" \
  --query value -o tsv 2>/dev/null || true)

if [[ -z "$callback" ]]; then
  err "Could not read the callback URL for '$LOGIC_APP'."
  err "You need at least Contributor on the resource group."
  exit 1
fi

clean_url="${callback%%\?*}?api-version=2016-06-01"
if [[ "$clean_url" == *"sig="* ]]; then
  err "Refusing to store a URL that still carries a SAS signature."
  exit 1
fi
ok "SAS signature stripped; the endpoint now requires an AAD token"

info "Storing it on the app"
case "$AZURE_PLATFORM" in
  appservice)
    az webapp config appsettings set -n "$AZURE_APP_NAME" -g "$RG" \
      --settings AZURE_LOGIC_APP_MAIL_URL="$clean_url" --output none
    ;;
  containerapps)
    az containerapp update -n "$AZURE_APP_NAME" -g "$RG" \
      --set-env-vars AZURE_LOGIC_APP_MAIL_URL="$clean_url" --only-show-errors --output none
    ;;
esac
ok "AZURE_LOGIC_APP_MAIL_URL set"

st="$(connection_status)"
if [[ "$st" == "Connected" ]]; then
  ok "The Office 365 connection is already authorised — email should work."
  info "Verify: ./scripts/setup-email.sh --test you@example.edu"
else
  print_consent_instructions
fi
