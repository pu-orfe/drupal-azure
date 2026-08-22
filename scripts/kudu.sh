#!/usr/bin/env bash
###############################################################################
# kudu.sh — the App Service operational channel
#
#   ./scripts/kudu.sh ls   /home
#   ./scripts/kudu.sh cat  /home/boot-result.json
#   ./scripts/kudu.sh get  /home/deploy-backups/pre-deploy-x.sql.gz ./local.sql.gz
#   ./scripts/kudu.sh put  ./import.sql.gz /home/import.sql.gz
#   ./scripts/kudu.sh rm   /home/FORCE-DEPLOY
#   ./scripts/kudu.sh run  "drush status"
#
# WHAT THIS IS, AND WHY IT IS WORTH HAVING
#
# The SCM (Kudu) endpoint is a sidecar next to the app container that exposes a
# small HTTP API: a virtual filesystem over the instance's disk, and a command
# runner that returns the command's EXIT CODE.
#
# It is the single biggest operational advantage App Service has over Container
# Apps for this workload, and the reason is not convenience:
#
#   * It can move FILES. Pulling a multi-gigabyte private-files archive off the
#     instance, or pushing a database dump onto it, has no equivalent on
#     Container Apps at all — `az containerapp exec` is a terminal, not a
#     transport.
#   * Its command runner returns an exit code, so a script can branch on the
#     result. `az containerapp exec` does not, which is why every post-deploy
#     step written against it ends up as `|| echo "failed"`.
#   * Combined with /home being persistent, it makes the trigger-file pattern
#     work: drop a marker, restart, the entrypoint acts on it, read the report
#     back. That is how you drive a long operation inside a container whose
#     database has no public endpoint.
#
# SECURITY POSTURE
#
# Access is gated by Azure RBAC on the control plane: every call carries an Entra
# bearer token tied to an identity that has rights on the app. There is no open
# port (no SSH, nothing on 2222), no static credential, and no separate password
# to rotate. The app's own IP restrictions deliberately do NOT apply here
# (`scmIpSecurityRestrictionsUseMain: false` in the Bicep), because locking the
# ops channel to the same allow-list as the site would mean losing access to a
# site exactly when its network configuration is what broke.
###############################################################################
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/prompt.sh"
source "$SCRIPT_DIR/lib/platform.sh"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
info() { printf '%s[INFO]%s  %s\n' "$BLUE" "$NC" "$*" >&2; }
ok()   { printf '%s[OK]%s    %s\n' "$GREEN" "$NC" "$*" >&2; }
err()  { printf '%s[ERROR]%s %s\n' "$RED" "$NC" "$*" >&2; }

usage() { sed -n '2,12p' "$0"; }

[[ $# -ge 1 ]] || { usage; exit 2; }
ACTION="$1"; shift

prompt_resource_group
platform_resolve || exit 1

if [[ "$AZURE_PLATFORM" != "appservice" ]]; then
  err "Kudu is an App Service feature; this deployment is $AZURE_PLATFORM."
  printf '  Container Apps equivalents:\n'
  printf '    run a command   ./scripts/drush.sh <args>        (a Job, with a real exit code)\n'
  printf '    move a file     az storage file upload/download  (against the mounted share)\n'
  printf '    read state      ./scripts/drush.sh sql:query ... (the deploy-state table)\n'
  exit 1
fi

[[ -n "${AZURE_APP_NAME:-}" ]] || { err "No web app found in $AZURE_RESOURCE_GROUP."; exit 1; }
SCM="$AZURE_SCM_URL"

# A fresh token per invocation. Short-lived by construction, and never written
# anywhere — the alternative, a Kudu publishing profile password, is a long-lived
# static credential that ends up in a config file.
TOKEN=$(az account get-access-token --resource https://management.azure.com/ --query accessToken -o tsv)
[[ -n "$TOKEN" ]] || { err "Could not obtain an access token. Run 'az login'."; exit 1; }

auth=(-H "Authorization: Bearer $TOKEN")

# Kudu's VFS API maps a container path onto /api/vfs/<path-without-leading-slash>.
vfs_url() { printf '%s/api/vfs/%s' "$SCM" "${1#/}"; }

case "$ACTION" in
  ls)
    path="${1:-/home}"
    # A trailing slash is what makes the VFS return a directory LISTING rather
    # than the file at that path. Without it a directory request 404s, which
    # reads as "the directory does not exist".
    curl -fsS "${auth[@]}" "$(vfs_url "${path%/}/")" \
      | python3 -c '
import json, sys
for e in sorted(json.load(sys.stdin), key=lambda x: (x["mime"] != "inode/directory", x["name"])):
    kind = "d" if e["mime"] == "inode/directory" else "-"
    print(f"{kind} {e.get(\"size\", 0):>12}  {e.get(\"mtime\", \"\")[:19]}  {e[\"name\"]}")'
    ;;

  cat)
    [[ $# -ge 1 ]] || { err "cat needs a path"; exit 2; }
    curl -fsS "${auth[@]}" "$(vfs_url "$1")"
    ;;

  get)
    [[ $# -ge 1 ]] || { err "get needs a remote path"; exit 2; }
    dest="${2:-$(basename "$1")}"
    info "Downloading $1 -> $dest"
    curl -fS --progress-bar "${auth[@]}" -o "$dest" "$(vfs_url "$1")"
    ok "$dest ($(du -h "$dest" | cut -f1))"
    ;;

  put)
    [[ $# -ge 2 ]] || { err "put needs a local path and a remote path"; exit 2; }
    [[ -f "$1" ]] || { err "no such file: $1"; exit 1; }
    info "Uploading $1 -> $2"
    # If-Match: * because the VFS API refuses an overwrite without an ETag,
    # returning 412 with no explanation of what is missing.
    curl -fS --progress-bar "${auth[@]}" -H 'If-Match: *' \
      -T "$1" "$(vfs_url "$2")"
    ok "uploaded"
    ;;

  rm)
    [[ $# -ge 1 ]] || { err "rm needs a path"; exit 2; }
    curl -fsS -X DELETE "${auth[@]}" -H 'If-Match: *' "$(vfs_url "$1")" >/dev/null
    ok "deleted $1"
    ;;

  touch)
    # For trigger files, whose CONTENT may carry an argument for the entrypoint.
    [[ $# -ge 1 ]] || { err "touch needs a path"; exit 2; }
    printf '%s' "${2:-}" | curl -fsS "${auth[@]}" -H 'If-Match: *' \
      -H 'Content-Type: application/octet-stream' \
      --data-binary @- "$(vfs_url "$1")" >/dev/null
    ok "wrote $1"
    ;;

  run)
    [[ $# -ge 1 ]] || { err "run needs a command"; exit 2; }
    payload=$(python3 -c '
import json, sys
print(json.dumps({"command": sys.argv[1], "dir": sys.argv[2]}))' "$1" "${2:-/var/www/html}")
    response=$(curl -fsS -X POST "${auth[@]}" -H 'Content-Type: application/json' \
      -d "$payload" "$SCM/api/command")
    # The exit code comes back in the body, and propagating it is the whole point
    # of using this endpoint rather than a terminal.
    python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
sys.stdout.write(d.get("Output", ""))
sys.stderr.write(d.get("Error", ""))
sys.exit(int(d.get("ExitCode", 1)))' <<<"$response"
    ;;

  -h|--help)
    usage
    ;;

  *)
    err "Unknown action: $ACTION"
    usage
    exit 2
    ;;
esac
