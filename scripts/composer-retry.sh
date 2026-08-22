#!/bin/sh
###############################################################################
# composer-retry.sh — run a composer command with bounded retries
#
#   scripts/composer-retry.sh install --no-dev --optimize-autoloader
#   scripts/composer-retry.sh update  --no-interaction --no-progress
#
# WHY THIS EXISTS
#
# Composer fetches package archives from GitHub, and because preferred-install
# defaults to `dist` it does NOT fall back to cloning when a download fails — it
# reports "Source fallback is disabled. Not trying alternative sources." and
# aborts. A single transient failure on any ONE of the ~200 packages a Drupal
# site pulls therefore kills the entire install, and with it the deploy.
#
# Both observed failure modes are transient:
#
#   HTTP 504 from api.github.com       upstream degradation
#   HTTP 429 from codeload.github.com  anonymous per-IP rate limit, which shared
#                                      CI runners hit routinely
#
# During a GitHub incident this cost three consecutive production deploys, each
# dying on a different package. At even a 2% per-request failure rate a
# 200-package build has roughly a 2% chance of completing, so "just re-run it"
# is not a strategy.
#
# Retrying converges rather than restarting: Composer caches archives it already
# fetched, so each attempt only needs the packages still missing.
#
# For 429 specifically, retries are the SECOND line of defence. The first is
# authenticating via COMPOSER_AUTH, which lifts the anonymous rate limit
# entirely — see .github/workflows/*.yml.
#
# Deliberately NOT enabling source fallback via preferred-install: that would
# make the contents of vendor/ depend on which transport happened to win, and
# non-determinism in what ships is worse than a slow build.
###############################################################################
set -eu

if [ "$#" -eq 0 ]; then
  echo "composer-retry: expected a composer command, e.g. 'install --no-dev'" >&2
  exit 2
fi

# Twelve attempts. Because Composer caches what it already fetched, the packages
# still outstanding roughly halve each attempt, so the attempts needed are about
# log2(N):
#
#   200 -> 100 -> 50 -> 25 -> 12 -> 6 -> 3 -> 1
#
# log2(200) is ~7.6, so five attempts was never going to be enough and eight
# only just reaches the expected value with no margin. A real build with five
# attempts died with exactly two stragglers left, matching that curve. Twelve
# leaves comfortable headroom.
#
# The cost is bounded and only paid when downloads are actually failing: the
# loop exits the moment composer succeeds.
attempts="${COMPOSER_RETRY_ATTEMPTS:-12}"
max_delay="${COMPOSER_RETRY_MAX_DELAY:-60}"
i=1

while [ "$i" -le "$attempts" ]; do
  if composer "$@"; then
    exit 0
  fi

  if [ "$i" -lt "$attempts" ]; then
    delay=$((i * 15))
    [ "$delay" -gt "$max_delay" ] && delay="$max_delay"
    echo "composer-retry: 'composer $*' failed (attempt $i/$attempts); retrying in ${delay}s" >&2
    sleep "$delay"
  fi

  i=$((i + 1))
done

echo "composer-retry: 'composer $*' failed after $attempts attempts" >&2
exit 1
