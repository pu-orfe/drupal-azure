#!/usr/bin/env bash
###############################################################################
# prompt.sh — Shared interactive prompt helpers for Azure scripts
#
# Source this file from any script:
#   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#   source "$SCRIPT_DIR/lib/prompt.sh"
#
# All functions respect existing environment variables — if a variable is
# already set, the prompt is skipped and the current value is displayed.
# This keeps scripts CI-friendly: set all env vars and no prompts appear.
###############################################################################

# Guard against double-sourcing
[[ -n "${_PROMPT_LIB_LOADED:-}" ]] && return 0
_PROMPT_LIB_LOADED=1

# Colors (safe to re-declare; scripts may source this before defining their own)
_P_YELLOW='\033[1;33m'
_P_BLUE='\033[0;34m'
_P_GREEN='\033[0;32m'
_P_CYAN='\033[0;36m'
_P_BOLD='\033[1m'
_P_NC='\033[0m'

###############################################################################
# prompt_val VAR_NAME "Prompt text" ["default"]
#
# If $VAR_NAME is already set, prints "Using VAR_NAME: <value>" and returns.
# Otherwise prompts the user. Pressing Enter accepts the default (if given).
# The result is exported into the caller's environment.
###############################################################################
prompt_val() {
  local var_name="$1"
  local prompt_text="$2"
  local default="${3:-}"

  # If the variable is already set and non-empty, skip the prompt
  local current="${!var_name:-}"
  if [[ -n "$current" ]]; then
    echo -e "  ${_P_GREEN}Using${_P_NC} ${var_name}=${_P_BOLD}${current}${_P_NC}"
    return 0
  fi

  # Build the prompt string
  local display="$prompt_text"
  if [[ -n "$default" ]]; then
    display="${display} [${default}]"
  fi

  echo -en "  ${_P_YELLOW}${display}: ${_P_NC}"
  read -r value
  value="${value:-$default}"

  if [[ -z "$value" ]]; then
    echo -e "  ${_P_YELLOW}[WARN]${_P_NC} No value provided for ${var_name}." >&2
    return 1
  fi

  export "$var_name"="$value"
  return 0
}

###############################################################################
# prompt_secret VAR_NAME "Prompt text"
#
# Like prompt_val but hides input (read -rs). No default is shown.
###############################################################################
prompt_secret() {
  local var_name="$1"
  local prompt_text="$2"

  local current="${!var_name:-}"
  if [[ -n "$current" ]]; then
    echo -e "  ${_P_GREEN}Using${_P_NC} ${var_name}=${_P_BOLD}(set)${_P_NC}"
    return 0
  fi

  echo -en "  ${_P_YELLOW}${prompt_text}: ${_P_NC}"
  read -rs value
  echo ""  # newline after hidden input

  if [[ -z "$value" ]]; then
    echo -e "  ${_P_YELLOW}[WARN]${_P_NC} No value provided for ${var_name}." >&2
    return 1
  fi

  export "$var_name"="$value"
  return 0
}

###############################################################################
# prompt_select VAR_NAME "Prompt text" option1 option2 ...
#
# Shows a numbered list. The user picks by number. If $VAR_NAME is already
# set (and matches one of the options), the prompt is skipped.
###############################################################################
prompt_select() {
  local var_name="$1"
  local prompt_text="$2"
  shift 2
  local options=("$@")

  local current="${!var_name:-}"
  if [[ -n "$current" ]]; then
    echo -e "  ${_P_GREEN}Using${_P_NC} ${var_name}=${_P_BOLD}${current}${_P_NC}"
    return 0
  fi

  echo -e "  ${_P_CYAN}${prompt_text}:${_P_NC}"
  local i
  for i in "${!options[@]}"; do
    echo -e "    ${_P_BOLD}$((i + 1)))${_P_NC} ${options[$i]}"
  done

  local choice
  while true; do
    echo -en "  ${_P_YELLOW}Select [1-${#options[@]}]: ${_P_NC}"
    read -r choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
      break
    fi
    echo -e "  ${_P_YELLOW}[WARN]${_P_NC} Invalid selection. Enter a number between 1 and ${#options[@]}."
  done

  export "$var_name"="${options[$((choice - 1))]}"
  return 0
}

###############################################################################
# prompt_subscription
#
# Lists Azure subscriptions. If only one exists, selects it automatically.
# If >1, presents a numbered list. Stores the result in AZURE_SUBSCRIPTION.
# Also sets the chosen subscription as the active az CLI subscription.
###############################################################################
prompt_subscription() {
  local current="${AZURE_SUBSCRIPTION:-}"
  if [[ -n "$current" ]]; then
    echo -e "  ${_P_GREEN}Using${_P_NC} AZURE_SUBSCRIPTION=${_P_BOLD}${current}${_P_NC}"
    az account set --subscription "$current" 2>/dev/null || true
    return 0
  fi

  local subs_json
  subs_json=$(az account list --query "[].{name:name, id:id, isDefault:isDefault}" -o json 2>/dev/null)
  local count
  count=$(echo "$subs_json" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)

  if [[ "$count" -eq 0 ]]; then
    echo -e "  ${_P_YELLOW}[WARN]${_P_NC} No Azure subscriptions found. Run: az login" >&2
    return 1
  fi

  if [[ "$count" -eq 1 ]]; then
    AZURE_SUBSCRIPTION=$(echo "$subs_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['id'])")
    local name
    name=$(echo "$subs_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['name'])")
    echo -e "  ${_P_GREEN}Subscription:${_P_NC} ${name} (${AZURE_SUBSCRIPTION})"
    export AZURE_SUBSCRIPTION
    return 0
  fi

  echo -e "  ${_P_CYAN}Select Azure subscription:${_P_NC}"
  local names ids defaults
  names=()
  ids=()
  defaults=()
  while IFS=$'\t' read -r name id is_default; do
    names+=("$name")
    ids+=("$id")
    defaults+=("$is_default")
  done < <(echo "$subs_json" | python3 -c "
import sys, json
for s in json.load(sys.stdin):
    dflt = '*' if s['isDefault'] else ' '
    print(f\"{s['name']}\t{s['id']}\t{dflt}\")
")

  local i
  for i in "${!names[@]}"; do
    local marker=""
    [[ "${defaults[$i]}" == "*" ]] && marker=" ${_P_GREEN}(current)${_P_NC}"
    echo -e "    ${_P_BOLD}$((i + 1)))${_P_NC} ${names[$i]}  ${ids[$i]}${marker}"
  done

  local choice
  while true; do
    echo -en "  ${_P_YELLOW}Select [1-${#ids[@]}]: ${_P_NC}"
    read -r choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#ids[@]} )); then
      break
    fi
    echo -e "  ${_P_YELLOW}[WARN]${_P_NC} Invalid selection."
  done

  AZURE_SUBSCRIPTION="${ids[$((choice - 1))]}"
  export AZURE_SUBSCRIPTION
  az account set --subscription "$AZURE_SUBSCRIPTION" 2>/dev/null || true
  echo -e "  ${_P_GREEN}Set subscription:${_P_NC} ${names[$((choice - 1))]}"
  return 0
}

###############################################################################
# prompt_resource_group [filter_prefix]
#
# Lists resource groups (optionally filtered by prefix, default "rg-").
# Lets user pick from the list or type a name manually.
# Stores the result in AZURE_RESOURCE_GROUP.
###############################################################################
prompt_resource_group() {
  local prefix="${1:-rg-}"

  local current="${AZURE_RESOURCE_GROUP:-}"
  if [[ -n "$current" ]]; then
    echo -e "  ${_P_GREEN}Using${_P_NC} AZURE_RESOURCE_GROUP=${_P_BOLD}${current}${_P_NC}"
    return 0
  fi

  local rgs
  rgs=$(az group list --query "[?starts_with(name,'${prefix}')].name" -o tsv 2>/dev/null | sort)
  local rg_array=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && rg_array+=("$line")
  done <<< "$rgs"

  if [[ ${#rg_array[@]} -eq 0 ]]; then
    echo -e "  ${_P_YELLOW}No resource groups found matching '${prefix}*'.${_P_NC}"
    echo -en "  ${_P_YELLOW}Enter resource group name: ${_P_NC}"
    read -r AZURE_RESOURCE_GROUP
    if [[ -z "$AZURE_RESOURCE_GROUP" ]]; then
      echo -e "  ${_P_YELLOW}[WARN]${_P_NC} No resource group provided." >&2
      return 1
    fi
    export AZURE_RESOURCE_GROUP
    return 0
  fi

  if [[ ${#rg_array[@]} -eq 1 ]]; then
    AZURE_RESOURCE_GROUP="${rg_array[0]}"
    echo -e "  ${_P_GREEN}Resource group:${_P_NC} ${_P_BOLD}${AZURE_RESOURCE_GROUP}${_P_NC}"
    export AZURE_RESOURCE_GROUP
    return 0
  fi

  echo -e "  ${_P_CYAN}Select resource group:${_P_NC}"
  local i
  for i in "${!rg_array[@]}"; do
    echo -e "    ${_P_BOLD}$((i + 1)))${_P_NC} ${rg_array[$i]}"
  done
  echo -e "    ${_P_BOLD}$((${#rg_array[@]} + 1)))${_P_NC} Enter a different name..."

  local choice
  while true; do
    echo -en "  ${_P_YELLOW}Select [1-$((${#rg_array[@]} + 1))]: ${_P_NC}"
    read -r choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#rg_array[@]} + 1 )); then
      break
    fi
    echo -e "  ${_P_YELLOW}[WARN]${_P_NC} Invalid selection."
  done

  if (( choice <= ${#rg_array[@]} )); then
    AZURE_RESOURCE_GROUP="${rg_array[$((choice - 1))]}"
  else
    echo -en "  ${_P_YELLOW}Enter resource group name: ${_P_NC}"
    read -r AZURE_RESOURCE_GROUP
  fi

  if [[ -z "$AZURE_RESOURCE_GROUP" ]]; then
    echo -e "  ${_P_YELLOW}[WARN]${_P_NC} No resource group provided." >&2
    return 1
  fi

  export AZURE_RESOURCE_GROUP
  return 0
}

###############################################################################
# prompt_container_app
#
# SUPERSEDED by platform_resolve() in lib/platform.sh, which resolves the app
# name on either platform and sets AZURE_APP_URL alongside it. Kept because it is
# a documented entry point and costs nothing; new scripts should source
# lib/platform.sh instead.
#
#
# Lists container apps in AZURE_RESOURCE_GROUP. Auto-selects if only one.
# Stores the result in AZURE_CONTAINER_APP_NAME.
###############################################################################
prompt_container_app() {
  local current="${AZURE_CONTAINER_APP_NAME:-}"
  if [[ -n "$current" ]]; then
    echo -e "  ${_P_GREEN}Using${_P_NC} AZURE_CONTAINER_APP_NAME=${_P_BOLD}${current}${_P_NC}"
    return 0
  fi

  local apps
  apps=$(az containerapp list -g "$AZURE_RESOURCE_GROUP" --query "[].name" -o tsv 2>/dev/null | sort)
  local app_array=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && app_array+=("$line")
  done <<< "$apps"

  if [[ ${#app_array[@]} -eq 0 ]]; then
    echo -e "  ${_P_YELLOW}No container apps found in ${AZURE_RESOURCE_GROUP}.${_P_NC}"
    echo -en "  ${_P_YELLOW}Enter container app name: ${_P_NC}"
    read -r AZURE_CONTAINER_APP_NAME
    if [[ -z "$AZURE_CONTAINER_APP_NAME" ]]; then
      echo -e "  ${_P_YELLOW}[WARN]${_P_NC} No container app name provided." >&2
      return 1
    fi
    export AZURE_CONTAINER_APP_NAME
    return 0
  fi

  if [[ ${#app_array[@]} -eq 1 ]]; then
    AZURE_CONTAINER_APP_NAME="${app_array[0]}"
    echo -e "  ${_P_GREEN}Container app:${_P_NC} ${_P_BOLD}${AZURE_CONTAINER_APP_NAME}${_P_NC}"
    export AZURE_CONTAINER_APP_NAME
    return 0
  fi

  echo -e "  ${_P_CYAN}Select container app:${_P_NC}"
  local i
  for i in "${!app_array[@]}"; do
    echo -e "    ${_P_BOLD}$((i + 1)))${_P_NC} ${app_array[$i]}"
  done

  local choice
  while true; do
    echo -en "  ${_P_YELLOW}Select [1-${#app_array[@]}]: ${_P_NC}"
    read -r choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#app_array[@]} )); then
      break
    fi
    echo -e "  ${_P_YELLOW}[WARN]${_P_NC} Invalid selection."
  done

  AZURE_CONTAINER_APP_NAME="${app_array[$((choice - 1))]}"
  export AZURE_CONTAINER_APP_NAME
  return 0
}
