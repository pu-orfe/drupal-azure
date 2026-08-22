#!/usr/bin/env bash
###############################################################################
# Shell tests. No framework: a handful of assertions over the scripts whose
# behaviour is easy to get wrong and impossible to notice from the outside.
###############################################################################
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; NC=$'\033[0m'
PASSED=0; FAILED=0
ok()   { printf '%s  ✓%s %s\n' "$GREEN" "$NC" "$1"; PASSED=$((PASSED + 1)); }
no()   { printf '%s  ✗%s %s\n' "$RED" "$NC" "$1"; FAILED=$((FAILED + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1 (expected '$3', got '$2')"; fi; }

TMP="$(mktemp -d)"
cleanup_all() { stop_serve; rm -rf "$TMP"; }
trap cleanup_all EXIT

# ---------------------------------------------------------------------------
# composer-retry.sh
#
# The retry loop is the difference between a deploy that survives a transient
# GitHub 429 and one that does not, so it is worth asserting that it retries,
# that it converges, and that it gives up non-zero rather than silently
# continuing.
# ---------------------------------------------------------------------------
printf '\ncomposer-retry.sh\n'

mkdir -p "$TMP/bin"
cat > "$TMP/bin/composer" <<'FAKE'
#!/bin/sh
# Stand-in for composer: fails until the attempt counter reaches
# FAKE_SUCCEED_ON, then succeeds. No network, no real composer.
count_file="${FAKE_COUNT_FILE:-/tmp/fake-composer-count}"
n=$(cat "$count_file" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$count_file"
echo "fake composer attempt $n: $*"
[ "$n" -ge "${FAKE_SUCCEED_ON:-1}" ] && exit 0
exit 1
FAKE
chmod +x "$TMP/bin/composer"

run_retry() {
  env PATH="$TMP/bin:$PATH" \
      FAKE_COUNT_FILE="$TMP/count" \
      FAKE_SUCCEED_ON="$1" \
      COMPOSER_RETRY_ATTEMPTS="$2" \
      COMPOSER_RETRY_MAX_DELAY=0 \
    ./scripts/composer-retry.sh install >"$TMP/out" 2>&1
  echo "$?"
}

rm -f "$TMP/count"
check "succeeds first time without retrying" "$(run_retry 1 5)" "0"
check "ran exactly one attempt" "$(cat "$TMP/count")" "1"

rm -f "$TMP/count"
# Convergence across attempts is the point: composer caches what it already
# fetched, so each attempt only retries the stragglers.
check "retries until success" "$(run_retry 3 5)" "0"
check "took three attempts" "$(cat "$TMP/count")" "3"

rm -f "$TMP/count"
# Must fail non-zero. A retry wrapper that exits 0 after exhausting its attempts
# would let the Dockerfile ship an image with no vendor directory.
check "gives up non-zero after exhausting attempts" "$(run_retry 99 3)" "1"
check "made exactly the configured number of attempts" "$(cat "$TMP/count")" "3"

if grep -q 'failed after 3 attempts' "$TMP/out"; then
  ok "reports how many attempts it made"
else
  no "failure message does not say how many attempts were made"
fi

env PATH="$TMP/bin:$PATH" ./scripts/composer-retry.sh >/dev/null 2>&1
check "refuses to run with no composer command" "$?" "2"

# ---------------------------------------------------------------------------
# verify-site.sh
#
# This script exists because Drupal answers a fatal error with HTTP 200 and a
# broken body, so a status-code check passes on a dead site. These cases assert
# that it looks at the body.
#
# The fixture server's output is redirected away deliberately: leaving its stdout
# attached to the caller makes any command substitution around this helper block
# until the server exits, which is a deadlock rather than a slow test.
# ---------------------------------------------------------------------------
printf '\nverify-site.sh\n'

SERVER_PID=""
SERVER_PORT=""

# APP_HEADERS=0 makes the fixture answer WITHOUT application headers, which is
# how Azure's front end answers when the ingress allow-list refuses a request.
# That distinction — who answered, not which status — is what the script keys on.
serve() {
  local body_file="$1" status="${2:-200}"
  SERVER_PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
  python3 - "$body_file" "$status" "$SERVER_PORT" "${APP_HEADERS:-1}" >/dev/null 2>&1 <<'PYSERVE' &
import sys, http.server, socketserver
body = open(sys.argv[1], 'rb').read()
status = int(sys.argv[2])
port = int(sys.argv[3])
app_headers = sys.argv[4] == '1'

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(status)
        self.send_header('Content-Type', 'text/html')
        self.send_header('Content-Length', str(len(body)))
        if app_headers:
            # What the container emits.
            self.send_header('X-Generator', 'Drupal 10 (https://www.drupal.org)')
            self.send_header('X-Drupal-Cache', 'MISS')
        else:
            # What Azure's front end emits when the allow-list refuses a request:
            # its own marker and no application headers at all.
            self.send_header('x-ms-forbidden-ip', 'The IP address is not allowed')
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass

socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", port), Handler) as httpd:
    httpd.serve_forever()
PYSERVE
  SERVER_PID=$!
  # Wait for the port to accept, rather than sleeping a guessed interval.
  local attempt
  for attempt in $(seq 1 60); do
    : "$attempt"
    if python3 -c "
import socket, sys
s = socket.socket(); s.settimeout(0.2)
sys.exit(0 if s.connect_ex(('127.0.0.1', ${SERVER_PORT})) == 0 else 1)" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  no "fixture server on port $SERVER_PORT never started"
  return 1
}

stop_serve() {
  [[ -n "${SERVER_PID:-}" ]] || return 0
  kill "$SERVER_PID" 2>/dev/null
  wait "$SERVER_PID" 2>/dev/null
  SERVER_PID=""
}

verify() {
  env VERIFY_ATTEMPTS=1 VERIFY_INTERVAL=0 VERIFY_TIMEOUT=5 \
    ./scripts/verify-site.sh "http://127.0.0.1:${SERVER_PORT}" --endpoints / "$@" >/dev/null 2>&1
  echo "$?"
}

# expect_verify <label> <fixture> <status> <expected-exit> [extra verify args...]
expect_verify() {
  local label="$1" fixture="$2" status="$3" want="$4"; shift 4
  serve "$fixture" "$status" || return
  check "$label" "$(verify "$@")" "$want"
  stop_serve
}

printf '<html><head><meta name="Generator" content="Drupal 10 (https://www.drupal.org)"></head><body>Hello</body></html>' > "$TMP/good.html"
expect_verify "passes a rendered Drupal page" "$TMP/good.html" 200 0

# The exact case the old status-code check got wrong.
printf '<html><body><h1>The website encountered an unexpected error. Try again later.</h1></body></html>' > "$TMP/wsod.html"
expect_verify "fails a Drupal error page served as HTTP 200" "$TMP/wsod.html" 200 1

: > "$TMP/empty.html"
expect_verify "fails an empty body served as HTTP 200 (white screen)" "$TMP/empty.html" 200 1

printf '<html><body>Fatal error: Uncaught Error: Class not found</body></html>' > "$TMP/fatal.html"
expect_verify "fails a PHP fatal in the body" "$TMP/fatal.html" 200 1

printf '<html><body>PDOException: SQLSTATE[HY000] [2002] Connection refused</body></html>' > "$TMP/pdo.html"
expect_verify "fails a database exception in the body" "$TMP/pdo.html" 200 1

# A page that is not our application at all — a proxy default page, a parked
# placeholder, a CDN error page. It carries no application headers, so nothing
# has been learned about whether Drupal renders: INCONCLUSIVE, not a pass.
#
# Deliberately not FAIL either. A 200 from something that is not the container is
# a statement about the network path, not about the site, and calling it a
# failure invents an outage — the mirror image of calling it a pass.
printf '<html><body>It works!</body></html>' > "$TMP/notdrupal.html"
APP_HEADERS=0 expect_verify \
  "a 200 from something that is not the application is INCONCLUSIVE" \
  "$TMP/notdrupal.html" 200 2

printf 'Internal Server Error' > "$TMP/500.html"
expect_verify "fails an unexpected 5xx" "$TMP/500.html" 500 1

# ---------------------------------------------------------------------------
# The three-outcome model. These are the cases a status-code check cannot get
# right in either direction, because the platform's refusal and Drupal's own
# access denial are BOTH 403.
# ---------------------------------------------------------------------------
printf '<html><body>Web App - Unavailable</body></html>' > "$TMP/platform403.html"
APP_HEADERS=0 expect_verify \
  "a platform 403 with no application headers is INCONCLUSIVE (exit 2), not a pass" \
  "$TMP/platform403.html" 403 2

APP_HEADERS=0 expect_verify \
  "--allow-inconclusive downgrades that to exit 0 without calling it a pass" \
  "$TMP/platform403.html" 403 0 --allow-inconclusive

APP_HEADERS=0 expect_verify \
  "--expect-block turns the platform refusal into the thing being asserted" \
  "$TMP/platform403.html" 403 0 --expect-block

# Drupal's OWN 403 — same status, application headers present. On an SSO-gated
# site this is correct behaviour and proves the application is up.
printf '<html><head><meta name="Generator" content="Drupal 10"></head><body>Access denied</body></html>' > "$TMP/drupal403.html"
expect_verify "Drupal's own 403 passes when expected" "$TMP/drupal403.html" 403 0 --expect 403
expect_verify "and fails when 200 was expected" "$TMP/drupal403.html" 403 1

# --expect-block must FAIL when the application answers: otherwise "the
# allow-list is in force" is not something the script can actually assert.
expect_verify "--expect-block fails when the application answered" "$TMP/good.html" 200 1 --expect-block

# A maintenance window legitimately returns 503, and the body contains "Service
# Unavailable" — which is in the error-signature list. Checking signatures on an
# EXPECTED 5xx would fail every correct maintenance response.
printf '<html><head><meta name="Generator" content="Drupal 10"></head><body>Service Unavailable</body></html>' > "$TMP/maint.html"
expect_verify "an expected 503 passes despite 'Service Unavailable' in the body" "$TMP/maint.html" 503 0 --expect 503
expect_verify "an unexpected 503 still fails" "$TMP/maint.html" 503 1

# ---------------------------------------------------------------------------
# Cross-file consistency.
#
# Values that must agree across the Dockerfile, the Bicep templates, the compose
# file and the settings overlay. Each has exactly one failure mode: they silently
# disagree, and the consequence surfaces somewhere else entirely.
# ---------------------------------------------------------------------------
printf '\nconsistency\n'

php_prod=$(grep -m1 '^ARG PHP_VERSION=' Dockerfile | cut -d= -f2)
php_dev=$(grep -m1 '^ARG PHP_VERSION=' Dockerfile.dev | cut -d= -f2)
check "Dockerfile and Dockerfile.dev pin the same PHP" "$php_dev" "$php_prod"

php_platform=$(python3 -c "import json;print(json.load(open('composer.json'))['config']['platform']['php'])")
check "composer platform PHP matches the image" "$php_platform" "$php_prod"

php_ci=$(grep -m1 -oE "php-version: '[0-9.]+'" .github/workflows/pull-request.yml | grep -oE '[0-9.]+')
check "CI resolves dependencies on the image's PHP" "$php_ci" "$php_prod"

# The private-files path appears in the Bicep mount, the settings overlay default
# and the entrypoint's backup directory. If they diverge, private files are
# written to the replica's ephemeral filesystem and vanish with it — with no
# error at any point.
for m in infra/modules/aca.bicep infra/modules/appservice.bicep; do
  if grep -q "mountPath: '/var/www/html/private'" "$m"; then
    ok "$(basename "$m") mounts the private share at /var/www/html/private"
  else
    no "$(basename "$m") does not mount the private share at /var/www/html/private"
  fi
done

# Both platform templates must exist and both must be referenced by the platform
# library, or `AZURE_PLATFORM=<x>` silently deploys the wrong thing.
for t in infra/appservice/main.bicep infra/containerapps/main.bicep; do
  [[ -f "$t" ]] && ok "$t exists" || no "$t is missing"
  grep -q "$t" scripts/lib/platform.sh && ok "platform.sh resolves $t" \
    || no "platform.sh does not reference $t"
done

# The entrypoint must take its state paths from the environment, not hard-code
# them — that is what lets one image boot correctly on both platforms, writing to
# /home on App Service and to a mounted share on Container Apps.
for v in DRUPAL_BACKUP_DIR DRUPAL_BOOT_RESULT DRUPAL_FILE_PRIVATE_PATH; do
  case "$v" in
    DRUPAL_FILE_PRIVATE_PATH) f=docker/drupal/settings.azure.php ;;
    *)                        f=docker-entrypoint.sh ;;
  esac
  grep -q "$v" "$f" && ok "$v is read from the environment in $(basename "$f")" \
    || no "$v is not read from the environment"
done
if grep -q "'/var/www/html/private'" docker/drupal/settings.azure.php; then
  ok "the settings overlay defaults to the same private path"
else
  no "the settings overlay's private path does not match the Bicep mount path"
fi

# The collation appears in three places and all three must agree, or tables
# created by a later updb refuse to join the existing ones.
coll_bicep=$(grep -m1 "^param collation string = " infra/modules/mysql.bicep | sed "s/.*'\(.*\)'.*/\1/")
coll_settings=$(grep -m1 "DRUPAL_DB_COLLATION') ?: '" docker/drupal/settings.azure.php | sed "s/.*?: '\([^']*\)'.*/\1/")
coll_compose=$(grep -m1 -- '--collation-server=' docker-compose.yml | sed 's/.*=//')
check "mysql.bicep and the settings overlay agree on the collation" "$coll_settings" "$coll_bicep"
check "docker-compose agrees on the collation" "$coll_compose" "$coll_bicep"

# php-fpm must not clear the environment. Asserted here as well as in the image
# gate, because it is the one setting whose absence gives a site that works
# perfectly under drush and cannot connect over HTTP.
if grep -qE '^clear_env *= *no' docker/php-fpm/www.conf; then
  ok "php-fpm clear_env = no"
else
  no "php-fpm clear_env is not 'no': getenv() would return nothing in a web request"
fi

# opcache must keep docblocks, or Drupal's annotation-based plugin discovery
# breaks with errors that point nowhere near the cause.
if grep -qE '^opcache\.save_comments *= *1' docker/php/opcache.ini; then
  ok "opcache.save_comments = 1"
else
  no "opcache.save_comments is not 1: Drupal plugin discovery would break"
fi

# The deploy steps must go through run_step, which records the exit code and
# withholds the version marker on a critical failure. The failure mode this
# guards is `drush updb || true`, under which a failed schema update and a
# successful one produce indistinguishable logs and the deploy is marked done.
for step in updb config_import cache_rebuild; do
  if grep -qE "run_step critical +$step\b" docker-entrypoint.sh; then
    ok "entrypoint runs $step as a critical step"
  else
    no "entrypoint does not run $step through 'run_step critical'"
  fi
done

if grep -nE '(updb|config:import|cache:rebuild).*\|\| *(true|echo)' docker-entrypoint.sh; then
  no "a deploy step's exit code is swallowed with '|| true' or '|| echo'"
else
  ok "no deploy step swallows its exit code"
fi

# ---------------------------------------------------------------------------
# settings.php must contain no credential literals.
#
# Drupal's installer appends a literal $databases array and a generated
# $settings['hash_salt'] to settings.php whenever it is writable — and the local
# compose stack bind-mounts the checkout, so that lands in the working tree
# ready to be committed. The scripts make the file read-only for the duration of
# an install; this asserts the result, because the control failing silently is
# the whole problem.
# ---------------------------------------------------------------------------
printf '\nsettings.php hygiene\n'

if grep -q '= array (' web/sites/default/settings.php; then
  no "settings.php contains an installer-written array — credentials are in the working tree"
else
  ok "settings.php has no installer-written credential array"
fi

if grep -qE "hash_salt'\\]? *= *'" web/sites/default/settings.php; then
  no "settings.php contains a literal hash salt"
else
  ok "settings.php has no literal hash salt"
fi

if grep -qE "^ *'password' *=>" web/sites/default/settings.php; then
  no "settings.php contains a literal database password"
else
  ok "settings.php has no literal database password"
fi

# The settings files must carry no placeholder credential. Comment lines are
# excluded deliberately — the overlay EXPLAINS at length why placeholders are
# forbidden, and a naive grep flags that explanation as the thing it warns about.
if grep -vE '^\s*(//|\*|/\*|#)' docker/drupal/settings.azure.php web/sites/default/settings.php \
     | grep -qiE 'CHANGEME|placeholder-|REPLACE_ME'; then
  no "a placeholder credential is present in executable code — that is how a placeholder becomes the production credential"
else
  ok "no placeholder credentials in the settings files"
fi

# And the required-variable helper must exit NON-ZERO. `exit("message")` prints
# the string and exits ZERO, so a fatal misconfiguration reports as success —
# which matters because the entrypoint and the deploy workflow branch on exit
# codes. Covered by a unit test too; asserted here because it is a one-character
# regression.
if grep -qE '^\s*exit\(1\);' docker/drupal/settings.azure.php; then
  ok "the settings overlay exits non-zero on a missing required variable"
else
  no "the settings overlay does not exit(1) — a string argument to exit() exits ZERO"
fi

# An unresolved Key Vault reference must be rejected, not merely an empty value.
if grep -q '@Microsoft.KeyVault(' docker/drupal/settings.azure.php; then
  ok "the settings overlay rejects an unresolved Key Vault reference"
else
  no "the settings overlay does not check for an unresolved Key Vault reference"
fi

# ---------------------------------------------------------------------------
# Documentation links.
#
# A docs map with a dead link in it is worse than no map: it sends a newcomer
# somewhere that does not exist and costs them the trust to follow the next one.
# Renames are the usual cause, and they are exactly the change nobody re-checks
# by hand.
#
# Checks both halves — the file exists, AND the #anchor matches a real heading.
# ---------------------------------------------------------------------------
printf '\ndocumentation links\n'

link_report=$(python3 - <<'PYLINKS'
import os, re, glob, sys

def anchors(path):
    # Headings inside code fences are shell comments, not headings.
    txt = re.sub(r'```.*?```', '', open(path).read(), flags=re.S)
    out = set()
    for line in txt.split('\n'):
        m = re.match(r'^#{1,6}\s+(.*)', line)
        if m:
            h = m.group(1).replace('`', '')
            out.add(re.sub(r'[^\w\s-]', '', h).strip().lower().replace(' ', '-'))
    return out

# Our own documentation only. A bare '*/README.md' glob picks up Drupal's
# scaffolded web/README.md, whose links point into core/ and are not ours to fix.
files = ['README.md', 'scripts/README.md', 'config/sync/README.md'] + sorted(glob.glob('docs/*.md'))
cache, broken = {}, []
for f in sorted(set(files)):
    if not os.path.exists(f):
        continue
    base = os.path.dirname(f)
    for m in re.finditer(r'\[([^\]]+)\]\(([^)\s]+)\)', open(f).read()):
        target = m.group(2)
        if target.startswith(('http://', 'https://', 'mailto:', '#!')):
            continue
        path, _, frag = target.partition('#')
        resolved = os.path.normpath(os.path.join(base, path)) if path else f
        if not os.path.exists(resolved):
            broken.append(f'{f}: missing file -> {target}')
            continue
        if frag:
            cache.setdefault(resolved, anchors(resolved))
            if frag not in cache[resolved]:
                broken.append(f'{f}: missing anchor -> {target}')
for b in broken:
    print(b)
PYLINKS
)
if [[ -z "$link_report" ]]; then
  ok "every internal documentation link resolves"
else
  no "broken documentation links:"
  # Line by line: the report contains spaces, so an unquoted printf would split
  # each message into one line per word.
  while IFS= read -r line; do
    printf '      %s\n' "$line"
  done <<< "$link_report"
fi

# Every document should be reachable from the map, or it is invisible.
unreferenced=""
for d in docs/*.md; do
  base="$(basename "$d")"
  [[ "$base" == "README.md" ]] && continue
  if ! grep -qr "$base" README.md docs/README.md; then
    unreferenced="$unreferenced $base"
  fi
done
if [[ -z "$unreferenced" ]]; then
  ok "every document is linked from the README or the docs index"
else
  no "documents not reachable from the map:$unreferenced"
fi

# ---------------------------------------------------------------------------
# No internal system is named.
#
# This is a template that may be published. The lessons in
# docs/production-learnings.md came from specific internal deployments, and
# naming one alongside its operational state — "mid-migration", "currently
# failing its gate" — publishes a description of somebody's infrastructure
# posture. The lesson does not need the name to be true.
#
# Enforced as a test rather than a convention, because the temptation is to add
# a name back in to make a claim feel better sourced.
# ---------------------------------------------------------------------------
printf '\ninternal system names\n'

# Extend this list when a new internal deployment informs the template.
INTERNAL_NAMES='graddb|thesis-system|thesis_system|oiwps|orfe-thesis|orfe-graddb|orfethesis|orfegraddb'

named=$(grep -rInE "$INTERNAL_NAMES" \
          --exclude-dir=.git --exclude-dir=vendor --exclude-dir=core \
          --exclude=run.sh . 2>/dev/null \
        | grep -v '^./web/core' || true)
if [[ -z "$named" ]]; then
  ok "no internal deployment is named anywhere in the tree"
else
  no "an internal deployment is named:"
  while IFS= read -r line; do
    printf '      %s\n' "$line"
  done <<< "$named"
fi

# Hostnames, resource groups and domains identify a system as surely as its name.
identifying=$(grep -rInE '[a-z0-9-]+\.(azurewebsites|scm\.azurewebsites)\.net' \
                --exclude-dir=.git --exclude-dir=vendor --exclude-dir=core . 2>/dev/null \
              | grep -v '^./web/core' \
              | grep -vE '\$\{|\$[A-Z_]|<[a-z-]+>|appName|APP_NAME' || true)
if [[ -z "$identifying" ]]; then
  ok "no concrete Azure hostname is committed (only variables and placeholders)"
else
  no "a concrete Azure hostname is committed:"
  while IFS= read -r line; do
    printf '      %s\n' "$line"
  done <<< "$identifying"
fi

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[[ "$FAILED" -eq 0 ]]
