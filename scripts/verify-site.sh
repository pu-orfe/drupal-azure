#!/usr/bin/env bash
###############################################################################
# verify-site.sh — post-deploy smoke test
#
# Usage:
#   ./scripts/verify-site.sh https://host
#   ./scripts/verify-site.sh https://host --expect 503        # during maintenance
#   ./scripts/verify-site.sh https://host --endpoints /=403,/user/login=302
#   ./scripts/verify-site.sh https://host --allow-inconclusive
#   ./scripts/verify-site.sh https://host --expect-block      # assert the allow-list bites
#
# THREE OUTCOMES, NOT TWO
#
#   0  PASS          the application answered, with the expected status and a
#                    clean body
#   1  FAIL          the application answered, and something is wrong
#   2  INCONCLUSIVE  the request never reached the application, so NOTHING was
#                    verified. Deliberately distinct from PASS.
#
# Two separate lessons produced that third outcome, and both are cases where the
# obvious check can only ever come back "fine".
#
# 1. The status code is not enough. The naive check
#
#        code=$(curl -s -o /dev/null -w '%{http_code}' "$url")
#        [ "$code" -ge 200 ] && [ "$code" -lt 400 ] && echo healthy
#
#    passes on every interesting Drupal failure. A PHP fatal during render
#    returns 200 with a blank or partial body — Drupal has already sent headers
#    by then, so there is no status left to change. A missing database returns
#    Drupal's own "unable to connect" page, which is a themed 200 on purpose.
#
# 2. The status code cannot say WHO ANSWERED, and on an access-restricted site
#    that is the question that matters. Measured against a real deployment:
#
#      off allow-list   403, no application headers, ~1.9 KB platform error page.
#                       Azure's front end answered. NOTHING was learned — not
#                       even for a URL that does not exist.
#      through the      403, X-Drupal-Cache and X-Generator present, 15 KB
#      allow-list       rendered page. DRUPAL answered: the site is SSO-gated, so
#                       403 to an anonymous request is correct behaviour and
#                       proves the application is up.
#
#    Treating the first as a pass is a false pass; treating the second as a
#    failure invents an outage. The code is identical in both. So the test keys
#    on the presence of application headers, and only then does the status mean
#    anything.
#
# WHY --expect EXISTS
#
# During a maintenance window the site should return 503, and the checker has to
# tell "503 because we turned on maintenance mode" (keep going) apart from "503
# because it broke" (fail). Hardcoding 200 rebuilds the same
# can-only-say-fine bug facing the other way.
#
# WHY A DRUPAL FINGERPRINT IS NOT A HEALTH SIGNAL
#
# Drupal's maintenance page carries the same X-Generator header as a healthy
# page, so "looks like Drupal" cannot mean "is serving". The fingerprint here
# answers only "which server replied"; the expected status is asserted
# separately, and body signatures are skipped for an EXPECTED 5xx because the
# maintenance page contains "Service Unavailable", which is in the error list.
###############################################################################
set -Eeuo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'

BASE_URL=""
EXPECT="200"
EXPECT_EXPLICIT=0
ALLOW_INCONCLUSIVE=0
EXPECT_BLOCK=0
ATTEMPTS="${VERIFY_ATTEMPTS:-10}"
INTERVAL="${VERIFY_INTERVAL:-10}"
TIMEOUT="${VERIFY_TIMEOUT:-30}"
# Both prove Drupal rendered. `/` is the front page; `/user/login` exercises form
# building and the CSRF/session path, which is where a bad hash salt or a broken
# reverse-proxy configuration shows up and the front page does not.
ENDPOINTS_CSV="/,/user/login"

usage() { sed -n '2,60p' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --expect)             EXPECT="$2"; EXPECT_EXPLICIT=1; shift 2 ;;
    --endpoints)          ENDPOINTS_CSV="$2"; shift 2 ;;
    --allow-inconclusive) ALLOW_INCONCLUSIVE=1; shift ;;
    --expect-block)       EXPECT_BLOCK=1; shift ;;
    --timeout)            TIMEOUT="$2"; shift 2 ;;
    --attempts)           ATTEMPTS="$2"; shift 2 ;;
    -h|--help)            usage; exit 0 ;;
    -*)                   printf '%sUnknown option: %s%s\n' "$RED" "$1" "$NC" >&2; exit 2 ;;
    *)                    BASE_URL="$1"; shift ;;
  esac
done

if [[ -z "$BASE_URL" ]]; then
  usage >&2
  exit 2
fi

IFS=',' read -r -a ENDPOINT_SPECS <<< "$ENDPOINTS_CSV"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ERROR_SIGNATURES='Fatal error|Parse error|Uncaught (Exception|Error|TypeError|ArgumentCountError)|PDOException|DatabaseConnectionRefusedException|The website encountered an unexpected error|Additional uncaught exception|Error establishing a database connection|Unable to connect to your database server|RuntimeException'

# Headers only the container emits. Azure's front end emits none of them.
APP_HEADERS='^(x-drupal|x-generator|x-powered-by|server: *(nginx|apache))'

FAILED=0
INCONCLUSIVE=0

status_expected() { # status_expected <code> <csv>
  local code="$1" want
  local -a codes
  IFS=',' read -r -a codes <<< "$2"
  for want in "${codes[@]}"; do
    [[ "$code" == "$want" ]] && return 0
  done
  return 1
}

printf '%sVerifying %s%s\n' "$BOLD" "$BASE_URL" "$NC"

for spec in "${ENDPOINT_SPECS[@]}"; do
  path="${spec%%=*}"
  if [[ "$spec" == "$path" ]]; then
    want="$EXPECT"
  else
    want="${spec#*=}"
  fi
  # An explicit --expect wins over a per-endpoint default, which is what makes
  # `--expect 503` usable across the board during a maintenance window.
  (( EXPECT_EXPLICIT )) && want="$EXPECT"

  url="${BASE_URL%/}${path}"
  outcome=""
  reason=""
  code=""

  for (( attempt = 1; attempt <= ATTEMPTS; attempt++ )); do
    # ONE request, headers and body captured together. Two separate curls could
    # observe two different states of a restarting container and report a
    # combination that never existed.
    #
    # curl's EXIT CODE is captured alongside the status: "000" alone cannot tell
    # an unreachable host from a merely slow one, and reporting a cold start as
    # "connection error" names the wrong cause.
    set +e
    code=$(curl -sS --max-time "$TIMEOUT" -D "$WORK/h" -o "$WORK/b" -w '%{http_code}' \
             -H 'Accept: text/html' -H 'User-Agent: verify-site.sh' "$url" 2>"$WORK/e")
    curl_rc=$?
    set -e
    case "$code" in [1-5][0-9][0-9]) ;; *) code="000" ;; esac

    if [[ "$code" == "000" ]]; then
      case "$curl_rc" in
        28) reason="no response within ${TIMEOUT}s (curl 28 = TIMED OUT, not unreachable — a cold Drupal container can take tens of seconds for its first request)" ;;
        6)  reason="could not resolve the host (curl 6)" ;;
        7)  reason="could not connect (curl 7)" ;;
        35|60) reason="TLS error (curl $curl_rc)" ;;
        *)  reason="no response (curl $curl_rc)" ;;
      esac
      outcome=fail

    elif grep -qi '^x-ms-forbidden-ip' "$WORK/h" || ! grep -qiE "$APP_HEADERS" "$WORK/h"; then
      # The platform answered, not the container. There is deliberately NO
      # "but the code matched" escape here: the platform's block is 403 and
      # Drupal's own anonymous denial is ALSO 403, so the code cannot separate
      # them — which is the entire reason this branch keys on who answered.
      if (( EXPECT_BLOCK )); then
        outcome=pass
        reason="blocked before reaching the application, as --expect-block requires"
      else
        outcome=inconclusive
        reason="HTTP $code with no application headers — Azure's front end answered, so nothing about whether Drupal renders has been established"
      fi

    elif (( EXPECT_BLOCK )); then
      outcome=fail
      reason="--expect-block was given, but the application answered: the ingress allow-list is not refusing this request"

    elif ! status_expected "$code" "$want"; then
      outcome=fail
      reason="HTTP $code from the application, expected one of $want"

    elif [[ "$code" -ge 500 ]]; then
      # An EXPECTED 5xx. Body signatures are deliberately not applied: Drupal's
      # maintenance page contains "Service Unavailable", which is in the error
      # list, so checking it would fail every correct maintenance-mode response.
      outcome=pass
      reason="HTTP $code from the application, explicitly expected"

    elif [[ ! -s "$WORK/b" ]] && [[ "$code" -lt 300 ]]; then
      outcome=fail
      reason="empty body with HTTP $code — a white screen: PHP died after the headers went out"

    elif grep -Eqi "$ERROR_SIGNATURES" "$WORK/b"; then
      outcome=fail
      reason="error signature in the response body (HTTP $code)"

    else
      outcome=pass
      reason="HTTP $code from the application, $(wc -c < "$WORK/b" | tr -d ' ') bytes"
    fi

    # Retry only the transient shapes. An inconclusive result is a network
    # position problem and will not improve by waiting; a genuine failure of the
    # application will not either.
    if [[ "$outcome" == "pass" || "$outcome" == "inconclusive" ]] || (( attempt == ATTEMPTS )); then
      break
    fi
    printf '  %s…%s attempt %d/%d: %s — retrying in %ds\n' "$YELLOW" "$NC" "$attempt" "$ATTEMPTS" "$reason" "$INTERVAL"
    sleep "$INTERVAL"
  done

  case "$outcome" in
    pass)
      printf '%s  ✓%s %s — %s\n' "$GREEN" "$NC" "$url" "$reason"
      ;;
    inconclusive)
      printf '%s  ?%s %s — %s\n' "$CYAN" "$NC" "$url" "$reason"
      grep -i '^x-ms-forbidden-ip' "$WORK/h" 2>/dev/null | sed 's/^/      /' || true
      INCONCLUSIVE=1
      ;;
    *)
      printf '%s  ✗%s %s — %s\n' "$RED" "$NC" "$url" "$reason"
      if [[ -s "$WORK/b" ]]; then
        printf '%s      response excerpt:%s\n' "$YELLOW" "$NC"
        { grep -Ei -m2 -A2 "$ERROR_SIGNATURES" "$WORK/b" 2>/dev/null || head -c 500 "$WORK/b"; } \
          | head -12 | sed 's/^/        /'
        echo
      fi
      FAILED=1
      ;;
  esac
done

echo
if (( FAILED )); then
  printf '%s%s✗ Smoke test FAILED.%s\n' "$RED" "$BOLD" "$NC"
  exit 1
fi

if (( INCONCLUSIVE )); then
  printf '%s%s? Smoke test INCONCLUSIVE — the application was never reached, so nothing was verified.%s\n' "$CYAN" "$BOLD" "$NC"
  printf '%sThis is NOT a pass. To actually check that Drupal renders, run from inside the%s\n' "$CYAN" "$NC"
  printf '%sallow-list, or add this host to it (see AZURE_IP_ALLOW_LIST in scripts/azure-up.sh).%s\n' "$CYAN" "$NC"
  if (( ALLOW_INCONCLUSIVE )); then
    printf '%s(--allow-inconclusive given: exiting 0. Still not a pass.)%s\n' "$CYAN" "$NC"
    exit 0
  fi
  exit 2
fi

printf '%s%s✓ Smoke test passed.%s\n' "$GREEN" "$BOLD" "$NC"
