#!/usr/bin/env bash
###############################################################################
# rollback.sh — shift traffic back to a previous revision
#
#   ./scripts/rollback.sh --list
#   ./scripts/rollback.sh --current
#   ./scripts/rollback.sh --to <revision-or-image-tag> [--yes]
#   ./scripts/rollback.sh --previous [--yes]
#
# WHAT "ROLL BACK" MEANS ON EACH PLATFORM
#
#   Container Apps  a traffic weight change between revisions that are already
#                   running. Seconds, no pull, no restart.
#   App Service     repointing the app at a previous image TAG in the registry
#                   and restarting. Slower — an image pull and a container start,
#                   which on B1 is the site's downtime window — but it needs no
#                   rebuild, because the tag is still there.
#
# WHY THIS IS THE FASTEST RECOVERY, AND WHAT IT DOES NOT RECOVER
#
# Container Apps revisions in Multiple mode mean the previous revision is still
# running with 0% traffic. Rolling back is a traffic weight change: seconds, no
# rebuild, no image pull, no container start. That is why the deploy workflow
# keeps the last few revisions active instead of letting Azure retire them.
#
# WHAT ROLLS BACK
#   * Application code — the older revision's image.
#   * Exported configuration — the older image carries the older config/sync, and
#     because its CONTAINER_VERSION differs from the recorded marker, its
#     entrypoint re-runs config:import. So a config change IS undone, including
#     re-enabling a module that the newer revision uninstalled.
#
# WHAT DOES NOT ROLL BACK
#   * Data destroyed by a schema change. `drush updb` is one-directional and
#     uninstalling a module that owns an entity type DROPS its tables.
#     Re-enabling gives the schema back, empty.
#   * Anything outside the image and the database: the file shares, app settings,
#     Key Vault contents.
#
# For a deploy that carries a destructive schema change, the recovery path is the
# pre-deploy dump the entrypoint took (on the private share under
# .deploy-backups/, timestamped per deploy — not a single overwritten slot,
# precisely so a two-deploy change does not destroy the snapshot taken before the
# first), or point-in-time restore on the MySQL server. See docs/operations.md.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/prompt.sh"
source "$SCRIPT_DIR/lib/platform.sh"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'
info() { printf '%s[INFO]%s  %s\n' "$BLUE" "$NC" "$*"; }
ok()   { printf '%s[OK]%s    %s\n' "$GREEN" "$NC" "$*"; }
err()  { printf '%s[ERROR]%s %s\n' "$RED" "$NC" "$*" >&2; }

MODE=""; TARGET=""; ASSUME_YES=no
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)     MODE=list; shift ;;
    --current)  MODE=current; shift ;;
    --previous) MODE=previous; shift ;;
    --to)       MODE=to; TARGET="${2:-}"; shift 2 ;;
    --yes|-y)   ASSUME_YES=yes; shift ;;
    -h|--help)  sed -n '2,40p' "$0"; exit 0 ;;
    *) err "Unknown argument: $1"; exit 1 ;;
  esac
done
[[ -n "$MODE" ]] || { sed -n '2,10p' "$0"; exit 1; }

prompt_resource_group
platform_resolve || exit 1
RG="$AZURE_RESOURCE_GROUP"
APP="${AZURE_APP_NAME:?no app found in $AZURE_RESOURCE_GROUP}"

###############################################################################
# App Service
###############################################################################
if [[ "$AZURE_PLATFORM" == "appservice" ]]; then
  ACR_NAME="${AZURE_ACR_NAME:-$(az acr list -g "$RG" --query '[0].name' -o tsv 2>/dev/null || true)}"
  CURRENT_IMAGE="$(platform_current_image)"
  IMAGE_REPO="${CURRENT_IMAGE%:*}"
  CURRENT_TAG="${CURRENT_IMAGE##*:}"

  case "$MODE" in
    current)
      printf '%sPlatform:%s     App Service\n%sApp:%s          %s\n%sImage:%s        %s\n' \
        "$BLUE" "$NC" "$BLUE" "$NC" "$APP" "$BLUE" "$NC" "${CURRENT_IMAGE:-<none>}"
      exit 0
      ;;

    list)
      [[ -n "$ACR_NAME" ]] || { err "No registry found in $RG; set AZURE_ACR_NAME."; exit 1; }
      repo="${IMAGE_REPO##*/}"
      printf '\n%s%sImage tags in %s/%s (newest first)%s\n\n' "$BOLD" "$CYAN" "$ACR_NAME" "$repo" "$NC"
      az acr manifest list-metadata --registry "$ACR_NAME" --name "$repo" \
        --orderby time_desc --top 20 \
        --query "[].{tag: tags[0], created: createdTime}" -o tsv 2>/dev/null \
        | while IFS=$'\t' read -r tag created; do
            marker="  "
            [[ "$tag" == "$CURRENT_TAG" ]] && marker="->"
            printf '%s %-24s %s\n' "$marker" "${tag:-<untagged>}" "${created:0:19}"
          done
      printf '\n%s->%s marks the tag currently deployed.\n' "$GREEN" "$NC"
      printf 'Roll back with:  ./scripts/rollback.sh --to <tag>\n\n'
      exit 0
      ;;

    previous)
      repo="${IMAGE_REPO##*/}"
      # The most recent tag that is neither the running one nor the moving
      # `latest` pointer. Rolling back "to latest" is meaningless: latest is what
      # the broken deploy just moved.
      TARGET=$(az acr manifest list-metadata --registry "$ACR_NAME" --name "$repo" \
        --orderby time_desc --top 20 --query "[].tags[0]" -o tsv 2>/dev/null \
        | grep -v -e "^${CURRENT_TAG}$" -e '^latest$' | head -1)
      [[ -n "$TARGET" ]] || { err "No earlier tag found. Run --list."; exit 1; }
      ;;
  esac

  TARGET_IMAGE="${IMAGE_REPO}:${TARGET}"
  printf '\n  %sFrom%s %s\n  %sTo%s   %s\n\n' "$YELLOW" "$NC" "$CURRENT_IMAGE" "$GREEN" "$NC" "$TARGET_IMAGE"
  printf '  %sSchema and data changes made by the current image are NOT undone.%s\n' "$YELLOW" "$NC"
  printf '  %sOn B1 there is no warm swap target, so the restart below is downtime.%s\n\n' "$YELLOW" "$NC"

  if [[ "$ASSUME_YES" != "yes" ]]; then
    read -rp "$(printf '%sRepoint %s at %s and restart? (yes/no): %s' "$YELLOW" "$APP" "$TARGET" "$NC")" reply
    [[ "$reply" == "yes" ]] || { info "Aborted. Nothing changed."; exit 0; }
  fi

  platform_set_image "$TARGET_IMAGE"
  ok "Image set to $TARGET_IMAGE"
  platform_restart
  ok "Restarted"

  info "Verifying $AZURE_APP_URL"
  "$SCRIPT_DIR/verify-site.sh" "$AZURE_APP_URL" --allow-inconclusive
  exit $?
fi

###############################################################################
# Container Apps
###############################################################################
revisions_json() {
  az containerapp revision list --name "$APP" --resource-group "$RG" -o json
}

live_revision() {
  az containerapp revision list --name "$APP" --resource-group "$RG" \
    --query "[?properties.trafficWeight > \`0\`] | [0].name" -o tsv
}

case "$MODE" in
  current)
    rev="$(live_revision)"
    image=$(az containerapp revision show --name "$APP" --resource-group "$RG" --revision "$rev" \
      --query "properties.template.containers[0].image" -o tsv)
    printf '%sLive revision:%s %s\n%sImage:%s         %s\n' "$BLUE" "$NC" "$rev" "$BLUE" "$NC" "$image"
    ;;

  list)
    printf '\n%s%sRevisions (newest first)%s\n\n' "$BOLD" "$CYAN" "$NC"
    revisions_json | python3 -c '
import json, sys
revs = json.load(sys.stdin)
revs.sort(key=lambda r: r["properties"].get("createdTime") or "", reverse=True)
print(f"{\"\":3} {\"REVISION\":42} {\"TRAFFIC\":>8} {\"STATE\":10} {\"ACTIVE\":7} CREATED")
for r in revs:
    p = r["properties"]
    marker = "->" if (p.get("trafficWeight") or 0) > 0 else "  "
    print(f"{marker:3} {r[\"name\"][:42]:42} {str(p.get(\"trafficWeight\") or 0)+\"%\":>8} "
          f"{(p.get(\"runningState\") or \"?\")[:10]:10} {str(p.get(\"active\")):7} {(p.get(\"createdTime\") or \"\")[:19]}")
'
    printf '\n%s->%s marks the revision currently serving traffic.\n' "$GREEN" "$NC"
    printf 'Only ACTIVE revisions can take traffic. Reactivate one with:\n'
    printf '  az containerapp revision activate --name %s --resource-group %s --revision <name>\n\n' "$APP" "$RG"
    ;;

  previous|to)
    current="$(live_revision)"
    if [[ "$MODE" == "previous" ]]; then
      # The most recently created ACTIVE revision that is not the live one. It
      # must be active: traffic cannot be sent to a deactivated revision, and the
      # CLI accepts the weight change and silently serves nothing.
      TARGET=$(revisions_json | python3 -c '
import json, sys
current = sys.argv[1]
revs = [r for r in json.load(sys.stdin)
        if r["properties"].get("active") and r["name"] != current]
revs.sort(key=lambda r: r["properties"].get("createdTime") or "", reverse=True)
print(revs[0]["name"] if revs else "")
' "$current")
      [[ -n "$TARGET" ]] || { err "No other active revision to roll back to. Run --list."; exit 1; }
    fi

    active=$(az containerapp revision show --name "$APP" --resource-group "$RG" --revision "$TARGET" \
      --query "properties.active" -o tsv 2>/dev/null || echo "")
    [[ -n "$active" ]] || { err "Revision '$TARGET' not found."; exit 1; }
    if [[ "$active" != "True" && "$active" != "true" ]]; then
      err "Revision '$TARGET' is deactivated and cannot receive traffic."
      printf '  Reactivate it first:\n    az containerapp revision activate --name %s --resource-group %s --revision %s\n' "$APP" "$RG" "$TARGET"
      exit 1
    fi

    target_image=$(az containerapp revision show --name "$APP" --resource-group "$RG" --revision "$TARGET" \
      --query "properties.template.containers[0].image" -o tsv)
    printf '\n  %sFrom%s %s\n  %sTo%s   %s\n  %sImage%s %s\n\n' \
      "$YELLOW" "$NC" "${current:-<none>}" "$GREEN" "$NC" "$TARGET" "$BLUE" "$NC" "$target_image"
    printf '  %sSchema and data changes made by the current revision are NOT undone.%s\n\n' "$YELLOW" "$NC"

    if [[ "$ASSUME_YES" != "yes" ]]; then
      read -rp "$(printf '%sShift 100%% of traffic to %s? (yes/no): %s' "$YELLOW" "$TARGET" "$NC")" reply
      [[ "$reply" == "yes" ]] || { info "Aborted. Nothing changed."; exit 0; }
    fi

    az containerapp ingress traffic set --name "$APP" --resource-group "$RG" \
      --revision-weight "$TARGET=100" --only-show-errors >/dev/null
    ok "Traffic shifted to $TARGET"

    fqdn=$(az containerapp show --name "$APP" --resource-group "$RG" \
      --query "properties.configuration.ingress.fqdn" -o tsv)
    info "Verifying https://$fqdn"
    "$SCRIPT_DIR/verify-site.sh" "https://$fqdn"
    ;;
esac
