#!/usr/bin/env bash
###############################################################################
# rotate-secrets.sh — rotate the deployment's secrets in Key Vault
#
#   ./scripts/rotate-secrets.sh --list
#   ./scripts/rotate-secrets.sh --rotate db    [--dry-run]
#   ./scripts/rotate-secrets.sh --rotate salt  [--dry-run]
#
# WHY SECRETS LIVE IN KEY VAULT AND NOT IN THE CONTAINER APP
#
# A container app secret is a value stored in the app's configuration: readable
# by anyone with Contributor on the resource group, visible in
# `az containerapp show`, and rotated only by a configuration change. Worse, the
# tooling has to HOLD the plaintext to write it, so it passes through a shell
# history, a CI log or a parameter file on the way in.
#
# A Key Vault reference stores a URI. The app fetches the value at replica start
# with its managed identity. Rotation is a secret write plus a restart — no
# deployment, no commit, and the value never transits CI.
#
# The reference is deliberately UNVERSIONED (see infra/modules/keyvault.bicep),
# so a new secret version is picked up on the next replica start. A versioned URI
# pins the app to the old value and makes rotation silently ineffective.
#
# ON GENERATED VALUES RATHER THAN TYPED ONES
#
# This script never asks a human for a secret and has no placeholder defaults.
# Both rules come from the same failure: a CHANGEME-style default that nothing
# forces you to replace becomes the production credential, and then it is
# committed to the repository. A hash salt is the worse half of that — Drupal
# derives CSRF tokens and one-time login links from it, so a known salt is a
# route to forging them with no foothold required.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/prompt.sh"
source "$SCRIPT_DIR/lib/secrets.sh"
source "$SCRIPT_DIR/lib/platform.sh"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
info() { printf '%s[INFO]%s  %s\n' "$BLUE" "$NC" "$*"; }
ok()   { printf '%s[OK]%s    %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s[WARN]%s  %s\n' "$YELLOW" "$NC" "$*"; }
err()  { printf '%s[ERROR]%s %s\n' "$RED" "$NC" "$*" >&2; }

# From lib/secrets.sh, so the vault, azure-up.sh and this script agree.
DB_SECRET="$KV_SECRET_DB_PASSWORD"
SALT_SECRET="$KV_SECRET_HASH_SALT"

MODE=""; WHICH=""; DRY_RUN=no
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)    MODE=list; shift ;;
    --rotate)  MODE=rotate; WHICH="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=yes; shift ;;
    -h|--help) sed -n '2,34p' "$0"; exit 0 ;;
    *) err "Unknown argument: $1"; exit 1 ;;
  esac
done

# Fail closed rather than guessing a target. A rotation script that defaults its
# target is the same class of mistake as a credential that defaults to CHANGEME.
[[ -n "$MODE" ]] || { err "Refusing to run without --list or --rotate. Nothing changed."; sed -n '2,8p' "$0"; exit 1; }
if [[ "$MODE" == "rotate" ]]; then
  case "$WHICH" in db|salt) ;; *) err "--rotate must be 'db' or 'salt' (got '${WHICH:-}')"; exit 1 ;; esac
fi

prompt_resource_group
RG="$AZURE_RESOURCE_GROUP"
prompt_val AZURE_KEY_VAULT_NAME "Key Vault name" \
  "$(az keyvault list -g "$RG" --query '[0].name' -o tsv 2>/dev/null || true)"
KV="$AZURE_KEY_VAULT_NAME"
platform_resolve || exit 1
APP="${AZURE_APP_NAME:?no app found in $AZURE_RESOURCE_GROUP}"


if [[ "$MODE" == "list" ]]; then
  printf '\n%s%sSecrets in %s%s\n\n' "$BOLD" "$BLUE" "$KV" "$NC"
  for s in "$DB_SECRET" "$SALT_SECRET"; do
    line=$(az keyvault secret show --vault-name "$KV" --name "$s" \
      --query "{updated:attributes.updated, version:id}" -o tsv 2>/dev/null || true)
    if [[ -z "$line" ]]; then
      printf '  %-24s %s(absent)%s\n' "$s" "$YELLOW" "$NC"
    else
      # Never print a value. Only metadata.
      printf '  %-24s updated %s\n' "$s" "$(cut -f1 <<<"$line")"
    fi
  done
  printf '\n%sThe container app references these by unversioned URI, so a rotation takes\n' "$BLUE"
  printf 'effect at the next replica restart.%s\n\n' "$NC"
  exit 0
fi

if [[ "$WHICH" == "salt" ]]; then
  # Rotating the hash salt invalidates every active session and every outstanding
  # one-time login link. That is the desired effect when the salt has leaked, and
  # a surprise otherwise, so say so before doing it.
  warn "Rotating the hash salt logs out every user and invalidates outstanding password-reset links."
  new="$(generate_secret)"
  if [[ "$DRY_RUN" == "yes" ]]; then
    info "[dry-run] would set $SALT_SECRET in $KV and restart $APP"
    exit 0
  fi
  az keyvault secret set --vault-name "$KV" --name "$SALT_SECRET" --value "$new" --output none
  ok "$SALT_SECRET rotated in $KV"
  unset new
else
  new="$(generate_secret)"
  server=$(az mysql flexible-server list -g "$RG" --query '[0].name' -o tsv)
  [[ -n "$server" ]] || { err "No MySQL Flexible Server found in $RG."; exit 1; }

  if [[ "$DRY_RUN" == "yes" ]]; then
    info "[dry-run] would reset the admin password on $server, set $DB_SECRET in $KV, and restart $APP"
    exit 0
  fi

  # Order matters, and this order is the one that has a recoverable failure mode.
  #
  # Vault first, server second. If the server update then fails, the vault holds
  # a password the server does not accept and the site breaks at the next
  # restart — but the fix is a single command with a value you still have. The
  # other order (server first) leaves the site working until its next restart and
  # then broken with the correct password nowhere, because the server no longer
  # accepts the old one and nothing recorded the new one.
  az keyvault secret set --vault-name "$KV" --name "$DB_SECRET" --value "$new" --output none
  ok "$DB_SECRET written to $KV"

  info "Resetting the administrator password on $server"
  if ! az mysql flexible-server update --name "$server" --resource-group "$RG" \
        --admin-password "$new" --output none; then
    err "The server password reset FAILED, but the vault now holds the new value."
    err "Retry with: az mysql flexible-server update -n $server -g $RG --admin-password \"\$(az keyvault secret show --vault-name $KV -n $DB_SECRET --query value -o tsv)\""
    exit 1
  fi
  ok "Server password reset"
  unset new
fi

# The app only re-reads a Key Vault reference when a replica starts, so nothing
# has changed for running replicas yet. Creating a new revision is what applies
# it — and it goes through the ordinary revision machinery, so a bad rotation
# fails as an unhealthy revision rather than as a live outage.
# ---------------------------------------------------------------------------
# A running instance does not re-read a Key Vault reference, so nothing has
# changed yet. An explicit restart is what applies it — and on App Service that
# is not merely a convenience:
#
# App Service CACHES the resolved value of a Key Vault reference, and the
# reference-status API reports "Resolved" whether or not the running container
# holds the newest version. "The secret was rotated in the vault" and "the
# container is using the new secret" are therefore different statements that the
# platform will not distinguish for you.
#
# The entrypoint publishes a truncated fingerprint of each secret it is holding
# to its boot result, precisely so the second statement can be checked. Compare
# before and after: see docs/secrets.md.
# ---------------------------------------------------------------------------
info "Restarting $APP so it picks up the new value"
platform_restart
ok "$APP restarted"

info "Verifying $AZURE_APP_URL"
"$SCRIPT_DIR/verify-site.sh" "$AZURE_APP_URL" --allow-inconclusive

if [[ "$AZURE_PLATFORM" == "appservice" ]]; then
  echo ""
  info "Confirm the RUNNING container holds the new value, not a cached one:"
  echo "    ./scripts/kudu.sh cat /home/boot-result.json | python3 -m json.tool"
  echo "  and compare db_password_fingerprint / hash_salt_fingerprint with the previous boot."
fi
