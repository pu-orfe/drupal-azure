#!/usr/bin/env bash
###############################################################################
# secrets.sh — resolve credentials without a human handling them
#
# Source after lib/prompt.sh:
#   source "$SCRIPT_DIR/lib/prompt.sh"
#   source "$SCRIPT_DIR/lib/secrets.sh"
#
# THE RULE THIS LIBRARY EXISTS TO ENFORCE
#
# A credential this deployment owns should never pass through a human. Not typed,
# not pasted, not exported. The deployment already knows it — it is in Key Vault —
# so the script's job is to fetch it, use it, and forget it.
#
# The guidance this replaces was:
#
#     export MYSQL_ADMIN_PASSWORD='<strong-password>'
#     export AZURE_MYSQL_PASS="$MYSQL_ADMIN_PASSWORD"
#     ./scripts/some-script.sh
#
# which is wrong in more ways than it looks:
#
#   * it lands in shell history, and `export` makes it visible to every child
#     process for the rest of the session;
#   * it invites the operator to invent a password, or to reuse one;
#   * it invites them to keep a copy somewhere "so I have it next time", which is
#     how a credential ends up in a password manager shared by four people;
#   * and it is unnecessary, because the value already exists in a vault that the
#     operator can read on demand.
#
# A NOTE ON "ZERO-KNOWLEDGE"
#
# This is not zero-knowledge in the cryptographic sense — nothing here is a proof
# system, and an operator with Key Vault read access can obviously read the
# secret. What it provides is narrower and still worth having: the operator never
# has to *know* the value to do their job, so it never enters their shell, their
# history, their notes or their clipboard. Reading a secret becomes a deliberate,
# audited act rather than a step in a runbook.
###############################################################################

[[ -n "${_SECRETS_LIB_LOADED:-}" ]] && return 0
_SECRETS_LIB_LOADED=1

_S_RED=$'\033[0;31m'; _S_GREEN=$'\033[0;32m'; _S_YELLOW=$'\033[1;33m'
_S_BLUE=$'\033[0;34m'; _S_NC=$'\033[0m'
_s_info() { printf '%s[INFO]%s  %s\n' "$_S_BLUE" "$_S_NC" "$*" >&2; }
_s_ok()   { printf '%s[OK]%s    %s\n' "$_S_GREEN" "$_S_NC" "$*" >&2; }
_s_warn() { printf '%s[WARN]%s  %s\n' "$_S_YELLOW" "$_S_NC" "$*" >&2; }
_s_err()  { printf '%s[ERROR]%s %s\n' "$_S_RED" "$_S_NC" "$*" >&2; }

# Canonical secret names. They must match what infra/modules/keyvault.bicep
# creates — a mismatch here reads as "the vault does not have it" rather than as
# a naming bug, so they live in one place.
KV_SECRET_DB_PASSWORD="${KV_SECRET_DB_PASSWORD:-mysql-admin-password}"
KV_SECRET_HASH_SALT="${KV_SECRET_HASH_SALT:-drupal-hash-salt}"

###############################################################################
# generate_secret [length]
#
# A random credential, so no human ever chooses one.
#
# The alphabet is chosen to be safe in three places at once — a shell, a MySQL
# client invocation, and a URI — so it excludes quotes, backslash, dollar,
# backtick, @, colon, slash and percent. That is narrower than "all printable
# ASCII" and deliberately so: a password that has to be escaped differently in
# each context is a password that eventually gets mangled by one of them.
#
# Azure MySQL requires three of four character classes, so the result is CHECKED
# rather than assumed. 48 characters from a 64-symbol alphabet is ~288 bits.
#
# This lives here, once. It was previously copy-pasted into two scripts, which is
# how one copy quietly acquires a weaker alphabet or loses a class check without
# anyone noticing.
###############################################################################
generate_secret() {
  local length="${1:-48}" candidate
  while :; do
    candidate="$(LC_ALL=C tr -dc 'A-Za-z0-9._-' < /dev/urandom | head -c "$length" || true)"
    [[ ${#candidate} -eq $length ]] || continue
    [[ "$candidate" =~ [A-Z] ]] || continue
    [[ "$candidate" =~ [a-z] ]] || continue
    [[ "$candidate" =~ [0-9] ]] || continue
    printf '%s' "$candidate"
    return 0
  done
}

###############################################################################
# keyvault_name [resource-group]
#
# The vault for a deployment. Echoes the name, or nothing.
###############################################################################
keyvault_name() {
  local rg="${1:-${AZURE_RESOURCE_GROUP:-}}"
  if [[ -n "${AZURE_KEY_VAULT_NAME:-}" ]]; then
    printf '%s' "$AZURE_KEY_VAULT_NAME"
    return 0
  fi
  [[ -n "$rg" ]] || return 1
  az keyvault list -g "$rg" --query '[0].name' -o tsv 2>/dev/null
}

###############################################################################
# keyvault_get <vault> <secret-name>
#
# Echoes the secret value, or nothing. Quiet on failure: absence is a normal
# outcome that the caller decides how to handle, and an error here would be noise
# for every script that can proceed without it.
###############################################################################
keyvault_get() {
  local vault="$1" name="$2"
  [[ -n "$vault" && -n "$name" ]] || return 1
  az keyvault secret show --vault-name "$vault" --name "$name" \
    --query value -o tsv 2>/dev/null
}

###############################################################################
# resolve_secret VAR_NAME <secret-name> "prompt text" [resource-group]
#
# Fills VAR_NAME from, in order:
#   1. the environment, if already set (so CI can inject one);
#   2. Key Vault;
#   3. a hidden prompt, as a last resort.
#
# Never echoes the value, and never returns a placeholder. Exports VAR_NAME.
#
# The ORDER matters. Key Vault before the prompt means the normal path involves
# no human at all, and the prompt exists only for the genuinely-unavailable case
# (no vault yet, or no read access) rather than being the default experience.
###############################################################################
resolve_secret() {
  local var_name="$1" secret_name="$2" prompt_text="$3" rg="${4:-${AZURE_RESOURCE_GROUP:-}}"
  local current="${!var_name:-}"

  if [[ -n "$current" ]]; then
    # Deliberately reports the SOURCE and not the value.
    printf '  %sUsing%s %s from the environment\n' "$_S_GREEN" "$_S_NC" "$var_name" >&2
    export "$var_name"="$current"
    return 0
  fi

  local vault value
  vault="$(keyvault_name "$rg" || true)"
  if [[ -n "$vault" ]]; then
    value="$(keyvault_get "$vault" "$secret_name" || true)"
    if [[ -n "$value" ]]; then
      printf '  %sUsing%s %s from Key Vault %s (%s)\n' \
        "$_S_GREEN" "$_S_NC" "$var_name" "$vault" "$secret_name" >&2
      export "$var_name"="$value"
      unset value
      return 0
    fi
    _s_warn "Key Vault '$vault' has no secret named '$secret_name'."
  else
    _s_warn "No Key Vault found for ${rg:-<no resource group>}."
  fi

  # Last resort. Hidden input, and it is worth saying why we are asking, because
  # being asked for a password this tooling normally handles itself is a signal
  # that something is wrong.
  _s_warn "Falling back to a prompt. Normally this value comes from Key Vault —"
  _s_warn "if you are being asked, either the deployment predates the vault or you"
  _s_warn "lack 'Key Vault Secrets User' on it. See docs/secrets.md."
  prompt_secret "$var_name" "$prompt_text" || return 1
  return 0
}

###############################################################################
# require_secret VAR_NAME "what it is for"
#
# Fails closed with an actionable message. Call before using any credential.
###############################################################################
require_secret() {
  local var_name="$1" purpose="${2:-this operation}"
  if [[ -z "${!var_name:-}" ]]; then
    _s_err "$var_name is not set, and it is required for $purpose."
    _s_err "There is deliberately no default: a placeholder credential that nothing"
    _s_err "forces you to replace becomes the production one. See docs/secrets.md."
    return 1
  fi
  # An unresolved Key Vault reference is a non-empty, plausible-looking value that
  # authenticates as nothing. Rejected here so the failure names its cause rather
  # than surfacing later as "access denied for user".
  case "${!var_name}" in
    '@Microsoft.KeyVault('*)
      _s_err "$var_name is an UNRESOLVED Key Vault reference, not a secret."
      _s_err "The literal reference text was passed through. Check the identity's"
      _s_err "vault access. See docs/secrets.md."
      return 1
      ;;
  esac
  return 0
}

###############################################################################
# forget_secrets VAR_NAME...
#
# Unset credentials once finished with them, so they do not survive into a
# subshell, a `set` dump, or a core file. Cheap, and it bounds the window.
###############################################################################
forget_secrets() {
  local v
  for v in "$@"; do
    unset "$v"
  done
}

###############################################################################
# discover_deployment [resource-group]
#
# Fills in everything about a deployment that can be read back from Azure, so no
# script has to ask a human for a hostname they would mistype:
#
#   AZURE_MYSQL_HOST  AZURE_MYSQL_USER  AZURE_MYSQL_DB  AZURE_STORAGE_ACCOUNT
#
# Only sets what is not already set, so an explicit override always wins.
###############################################################################
discover_deployment() {
  local rg="${1:-${AZURE_RESOURCE_GROUP:-}}"
  [[ -n "$rg" ]] || { _s_err "No resource group given."; return 1; }

  local server
  server="${AZURE_MYSQL_SERVER:-$(az mysql flexible-server list -g "$rg" --query '[0].name' -o tsv 2>/dev/null)}"
  if [[ -z "$server" ]]; then
    _s_err "No MySQL Flexible Server found in '$rg'."
    _s_err "Deploy the infrastructure first: ./scripts/azure-up.sh"
    return 1
  fi
  export AZURE_MYSQL_SERVER="$server"

  : "${AZURE_MYSQL_HOST:=$(az mysql flexible-server show -g "$rg" -n "$server" \
        --query fullyQualifiedDomainName -o tsv 2>/dev/null)}"
  # The admin login is a property of the server, so it is knowable rather than
  # something to remember. `drupaladmin` is only the template's default.
  : "${AZURE_MYSQL_USER:=$(az mysql flexible-server show -g "$rg" -n "$server" \
        --query administratorLogin -o tsv 2>/dev/null)}"
  : "${AZURE_MYSQL_DB:=$(az mysql flexible-server db list -g "$rg" --server-name "$server" \
        --query "[?name!='information_schema' && name!='sys' && name!='performance_schema' && name!='mysql'] | [0].name" \
        -o tsv 2>/dev/null)}"
  : "${AZURE_STORAGE_ACCOUNT:=$(az storage account list -g "$rg" --query '[0].name' -o tsv 2>/dev/null)}"

  export AZURE_MYSQL_HOST AZURE_MYSQL_USER AZURE_MYSQL_DB AZURE_STORAGE_ACCOUNT

  _s_ok "Discovered from '$rg':"
  printf '    server   %s\n    host     %s\n    user     %s\n    database %s\n    storage  %s\n' \
    "$server" "${AZURE_MYSQL_HOST:-<not found>}" "${AZURE_MYSQL_USER:-<not found>}" \
    "${AZURE_MYSQL_DB:-<not found>}" "${AZURE_STORAGE_ACCOUNT:-<not found>}" >&2

  [[ -n "${AZURE_MYSQL_HOST:-}" && -n "${AZURE_MYSQL_USER:-}" ]] || {
    _s_err "Could not read the server's host or admin login. Check your access to '$rg'."
    return 1
  }
  return 0
}
