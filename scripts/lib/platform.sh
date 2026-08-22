#!/usr/bin/env bash
###############################################################################
# platform.sh — App Service / Container Apps abstraction for the ops scripts
#
# Source after lib/prompt.sh:
#   source "$SCRIPT_DIR/lib/prompt.sh"
#   source "$SCRIPT_DIR/lib/platform.sh"
#   platform_resolve            # sets AZURE_PLATFORM and the resource names
#
# App Service is the default. Container Apps is selected with
# AZURE_PLATFORM=containerapps, or detected automatically when the resource
# group contains a container app and no web app.
#
# WHY AN ABSTRACTION RATHER THAN TWO SETS OF SCRIPTS
#
# Almost everything an operator does is platform-independent in intent and
# platform-specific in mechanics: "show me the logs", "what image is running",
# "roll back", "run drush". Two script sets means two places to fix every bug
# and a guarantee they drift. The differences that genuinely matter are named
# explicitly below rather than hidden.
###############################################################################

[[ -n "${_PLATFORM_LIB_LOADED:-}" ]] && return 0
_PLATFORM_LIB_LOADED=1

_PL_RED=$'\033[0;31m'; _PL_YELLOW=$'\033[1;33m'; _PL_BLUE=$'\033[0;34m'; _PL_NC=$'\033[0m'
_pl_warn() { printf '%s[WARN]%s  %s\n' "$_PL_YELLOW" "$_PL_NC" "$*" >&2; }
_pl_err()  { printf '%s[ERROR]%s %s\n' "$_PL_RED" "$_PL_NC" "$*" >&2; }
_pl_info() { printf '%s[INFO]%s  %s\n' "$_PL_BLUE" "$_PL_NC" "$*"; }

###############################################################################
# platform_resolve
#
# Sets, in the caller's environment:
#   AZURE_PLATFORM   appservice | containerapps
#   AZURE_APP_NAME   the web app or container app name
#   AZURE_APP_URL    https://<hostname>
###############################################################################
platform_resolve() {
  local rg="${AZURE_RESOURCE_GROUP:-}"
  [[ -n "$rg" ]] || { _pl_err "AZURE_RESOURCE_GROUP is not set; call prompt_resource_group first."; return 1; }

  if [[ -z "${AZURE_PLATFORM:-}" ]]; then
    # Detect rather than assume, because guessing wrong here means every
    # subsequent command silently targets a resource that does not exist and
    # reports "not found" without saying what it was looking for.
    local webapps containerapps
    webapps=$(az webapp list -g "$rg" --query "length(@)" -o tsv 2>/dev/null || echo 0)
    containerapps=$(az containerapp list -g "$rg" --query "length(@)" -o tsv 2>/dev/null || echo 0)

    if [[ "$webapps" -gt 0 && "$containerapps" -gt 0 ]]; then
      _pl_err "$rg contains BOTH a web app and a container app."
      _pl_err "Set AZURE_PLATFORM=appservice or AZURE_PLATFORM=containerapps explicitly."
      return 1
    elif [[ "$containerapps" -gt 0 ]]; then
      AZURE_PLATFORM=containerapps
    else
      # The default, including for an empty resource group about to be deployed.
      AZURE_PLATFORM=appservice
    fi
  fi

  case "$AZURE_PLATFORM" in
    appservice)
      if [[ -z "${AZURE_APP_NAME:-}" ]]; then
        AZURE_APP_NAME=$(az webapp list -g "$rg" --query '[0].name' -o tsv 2>/dev/null || true)
      fi
      if [[ -n "${AZURE_APP_NAME:-}" ]]; then
        AZURE_APP_URL="https://$(az webapp show -n "$AZURE_APP_NAME" -g "$rg" \
          --query defaultHostName -o tsv 2>/dev/null || echo "${AZURE_APP_NAME}.azurewebsites.net")"
        AZURE_SCM_URL="https://${AZURE_APP_NAME}.scm.azurewebsites.net"
      fi
      ;;
    containerapps)
      if [[ -z "${AZURE_APP_NAME:-}" ]]; then
        AZURE_APP_NAME=$(az containerapp list -g "$rg" --query '[0].name' -o tsv 2>/dev/null || true)
      fi
      if [[ -n "${AZURE_APP_NAME:-}" ]]; then
        AZURE_APP_URL="https://$(az containerapp show -n "$AZURE_APP_NAME" -g "$rg" \
          --query 'properties.configuration.ingress.fqdn' -o tsv 2>/dev/null || true)"
        AZURE_SCM_URL=""
      fi
      ;;
    *)
      _pl_err "AZURE_PLATFORM must be 'appservice' or 'containerapps' (got '$AZURE_PLATFORM')."
      return 1
      ;;
  esac

  export AZURE_PLATFORM AZURE_APP_NAME AZURE_APP_URL AZURE_SCM_URL
  return 0
}

# The Bicep template for the resolved platform.
platform_template() {
  case "$AZURE_PLATFORM" in
    appservice)    printf 'infra/appservice/main.bicep' ;;
    containerapps) printf 'infra/containerapps/main.bicep' ;;
  esac
}

platform_current_image() {
  case "$AZURE_PLATFORM" in
    appservice)
      az webapp config container show -n "$AZURE_APP_NAME" -g "$AZURE_RESOURCE_GROUP" \
        --query "[?name=='DOCKER_CUSTOM_IMAGE_NAME'].value | [0]" -o tsv 2>/dev/null \
        || az webapp config show -n "$AZURE_APP_NAME" -g "$AZURE_RESOURCE_GROUP" \
             --query linuxFxVersion -o tsv 2>/dev/null | sed 's#^DOCKER|##'
      ;;
    containerapps)
      az containerapp show -n "$AZURE_APP_NAME" -g "$AZURE_RESOURCE_GROUP" \
        --query "properties.template.containers[0].image" -o tsv 2>/dev/null
      ;;
  esac
}

platform_set_image() { # platform_set_image <image-ref> [revision-suffix]
  local image="$1" suffix="${2:-}"
  case "$AZURE_PLATFORM" in
    appservice)
      az webapp config container set -n "$AZURE_APP_NAME" -g "$AZURE_RESOURCE_GROUP" \
        --container-image-name "$image" --output none
      ;;
    containerapps)
      local args=(-n "$AZURE_APP_NAME" -g "$AZURE_RESOURCE_GROUP" --image "$image")
      [[ -n "$suffix" ]] && args+=(--revision-suffix "$suffix")
      az containerapp update "${args[@]}" --only-show-errors --output none
      ;;
  esac
}

platform_restart() {
  case "$AZURE_PLATFORM" in
    appservice)
      # Restarts the single instance in place. There is no warm target on B1, so
      # this IS the downtime window — typically tens of seconds, longer when the
      # boot also runs schema updates. Upgrade to S1 and use a deployment slot if
      # that matters.
      az webapp restart -n "$AZURE_APP_NAME" -g "$AZURE_RESOURCE_GROUP" --output none
      ;;
    containerapps)
      local live
      live=$(az containerapp revision list -n "$AZURE_APP_NAME" -g "$AZURE_RESOURCE_GROUP" \
        --query "[?properties.trafficWeight > \`0\`] | [0].name" -o tsv)
      [[ -n "$live" ]] && az containerapp revision restart -n "$AZURE_APP_NAME" \
        -g "$AZURE_RESOURCE_GROUP" --revision "$live" --output none
      ;;
  esac
}

platform_logs() { # platform_logs <tail> <follow:yes|no>
  local tail="${1:-100}" follow="${2:-yes}"
  case "$AZURE_PLATFORM" in
    appservice)
      if [[ "$follow" == "yes" ]]; then
        # `az webapp log tail` streams the container's stdout. It does not
        # support a tail count, so recent history comes from the diagnostic logs
        # in Log Analytics instead — see docs/operations.md.
        az webapp log tail -n "$AZURE_APP_NAME" -g "$AZURE_RESOURCE_GROUP"
      else
        az webapp log download -n "$AZURE_APP_NAME" -g "$AZURE_RESOURCE_GROUP" \
          --log-file /dev/stdout 2>/dev/null || {
          _pl_warn "Could not download logs; query Log Analytics instead (docs/operations.md)."
          return 1
        }
      fi
      ;;
    containerapps)
      local args=(-n "$AZURE_APP_NAME" -g "$AZURE_RESOURCE_GROUP" --tail "$tail" --type console)
      [[ "$follow" == "yes" ]] && args+=(--follow)
      az containerapp logs show "${args[@]}"
      ;;
  esac
}

###############################################################################
# platform_run_drush <args...>
#
# Runs drush and returns ITS exit code, which is the whole point — both
# platforms make that harder than it should be, in different ways.
#
#   App Service    the Kudu /api/command endpoint returns the command's exit
#                  code in a JSON body. Authenticated by an Entra bearer token,
#                  so no open port and no stored credential.
#   Container Apps `az containerapp exec` has no exit-code contract at all, so
#                  a manual-trigger Job is used instead. See scripts/drush.sh.
###############################################################################
platform_run_drush() {
  case "$AZURE_PLATFORM" in
    appservice)
      local token payload response exitcode
      token=$(az account get-access-token --query accessToken -o tsv) || return 1
      payload=$(python3 -c '
import json, sys
print(json.dumps({"command": "vendor/bin/drush " + " ".join(sys.argv[1:]),
                  "dir": "/var/www/html"}))' "$@")
      response=$(curl -sS -X POST \
        -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
        -d "$payload" "${AZURE_SCM_URL}/api/command") || return 1
      python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    print("Kudu returned a non-JSON response", file=sys.stderr); sys.exit(1)
sys.stdout.write(d.get("Output", ""))
sys.stderr.write(d.get("Error", ""))
sys.exit(int(d.get("ExitCode", 1)))' <<<"$response"
      exitcode=$?
      return "$exitcode"
      ;;
    containerapps)
      _pl_err "platform_run_drush is not used on Container Apps; scripts/drush.sh starts a Job instead."
      return 1
      ;;
  esac
}
