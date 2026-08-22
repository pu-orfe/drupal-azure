#!/usr/bin/env bash
###############################################################################
# Tests for scripts/lib/secrets.sh — credential resolution.
#
# The property under test is not "does it fetch a secret" but "does a human ever
# have to handle one". Azure-backed cases are stubbed: `az` is replaced on PATH,
# so these run offline and deterministically.
###############################################################################
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; NC=$'\033[0m'
PASSED=0; FAILED=0
ok()    { printf '%s  ✓%s %s\n' "$GREEN" "$NC" "$1"; PASSED=$((PASSED + 1)); }
no()    { printf '%s  ✗%s %s\n' "$RED" "$NC" "$1"; FAILED=$((FAILED + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1 (expected '$3', got '$2')"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# A stub `az`. STUB_VAULT / STUB_SECRET decide what the vault appears to hold, so
# each case can present a different Azure without touching a real subscription.
cat > "$TMP/bin/az" <<'STUB'
#!/bin/sh
case "$*" in
  "keyvault list"*)
      [ -n "${STUB_VAULT:-}" ] && printf '%s\n' "$STUB_VAULT"; exit 0 ;;
  "keyvault secret show"*)
      [ -n "${STUB_SECRET:-}" ] && printf '%s\n' "$STUB_SECRET" && exit 0
      echo "not found" >&2; exit 1 ;;
  "mysql flexible-server list"*)
      [ -n "${STUB_SERVER:-}" ] && printf '%s\n' "$STUB_SERVER"; exit 0 ;;
  "mysql flexible-server show"*)
      case "$*" in
        *fullyQualifiedDomainName*) printf '%s\n' "${STUB_SERVER}.mysql.database.azure.com" ;;
        *administratorLogin*)       printf '%s\n' "${STUB_ADMIN:-drupaladmin}" ;;
      esac; exit 0 ;;
  "mysql flexible-server db list"*) printf '%s\n' "${STUB_DB:-drupal}"; exit 0 ;;
  "storage account list"*)          printf '%s\n' "${STUB_STORAGE:-stdrupalx}"; exit 0 ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/az"
export PATH="$TMP/bin:$PATH"

# shellcheck source=scripts/lib/prompt.sh
source scripts/lib/prompt.sh
# shellcheck source=scripts/lib/secrets.sh
source scripts/lib/secrets.sh

printf '\nresolve_secret\n'

# The normal path: the value comes from the vault, with no prompt and no human.
unset MY_SECRET
out=$(STUB_VAULT=kv-drupal-abc STUB_SECRET='s3cret-from-vault' \
        bash -c '
          source scripts/lib/prompt.sh; source scripts/lib/secrets.sh
          resolve_secret MY_SECRET mysql-admin-password "prompt" rg-x >/dev/null 2>&1
          printf "%s" "$MY_SECRET"' )
check "reads the secret from Key Vault without prompting" "$out" "s3cret-from-vault"

# The reported source must be the vault, so an operator can see where it came
# from — and the VALUE must not appear in that report.
report=$(STUB_VAULT=kv-drupal-abc STUB_SECRET='s3cret-from-vault' \
        bash -c '
          source scripts/lib/prompt.sh; source scripts/lib/secrets.sh
          resolve_secret MY_SECRET mysql-admin-password "prompt" rg-x' 2>&1)
grep -q 'Key Vault' <<<"$report" && ok "reports that the value came from Key Vault" \
                                 || no "did not say where the value came from"
grep -q 's3cret-from-vault' <<<"$report" && no "LEAKED the secret to the terminal" \
                                         || ok "does not print the secret"

# An explicit environment value wins, so CI can inject one.
out=$(STUB_VAULT=kv-drupal-abc STUB_SECRET='from-vault' MY_SECRET='from-env' \
        bash -c '
          source scripts/lib/prompt.sh; source scripts/lib/secrets.sh
          resolve_secret MY_SECRET mysql-admin-password "prompt" rg-x >/dev/null 2>&1
          printf "%s" "$MY_SECRET"' )
check "an explicit environment value takes precedence" "$out" "from-env"

# No vault: it must fall back to a HIDDEN prompt, and say why it is asking —
# being asked for a value the tooling normally handles is itself a signal.
report=$(printf 'typed-by-hand\n' | bash -c '
          source scripts/lib/prompt.sh; source scripts/lib/secrets.sh
          resolve_secret MY_SECRET mysql-admin-password "Password" rg-x
          printf "VALUE=%s" "$MY_SECRET"' 2>&1)
grep -q 'VALUE=typed-by-hand' <<<"$report" && ok "falls back to a prompt when the vault has nothing" \
                                           || no "did not fall back to a prompt"
grep -qi 'normally this value comes from key vault' <<<"$report" \
  && ok "explains why it is asking" || no "prompted without explaining why"

printf '\nrequire_secret\n'

MY_SECRET="a-real-value" require_secret MY_SECRET "a test" >/dev/null 2>&1 \
  && ok "accepts a resolved value" || no "rejected a resolved value"

( unset MY_SECRET; require_secret MY_SECRET "a test" >/dev/null 2>&1 ) \
  && no "accepted an empty value" || ok "refuses an empty value"

# The case an emptiness check misses: an unresolved reference is a long,
# plausible string that authenticates as nothing.
MY_SECRET='@Microsoft.KeyVault(SecretUri=https://kv.vault.azure.net/secrets/x/)' \
  require_secret MY_SECRET "a test" >/dev/null 2>&1 \
  && no "accepted an unresolved Key Vault reference" \
  || ok "refuses an unresolved Key Vault reference"

printf '\nforget_secrets\n'
MY_SECRET=abc OTHER=def
forget_secrets MY_SECRET OTHER
[[ -z "${MY_SECRET:-}${OTHER:-}" ]] && ok "unsets the variables it is given" \
                                    || no "left a credential set"

printf '\ndiscover_deployment\n'

report=$(STUB_SERVER=mysql-drupal-xyz STUB_ADMIN=siteadmin STUB_DB=sitedb STUB_STORAGE=stsite \
  bash -c '
    source scripts/lib/prompt.sh; source scripts/lib/secrets.sh
    discover_deployment rg-x >/dev/null 2>&1
    printf "%s|%s|%s|%s" "$AZURE_MYSQL_HOST" "$AZURE_MYSQL_USER" "$AZURE_MYSQL_DB" "$AZURE_STORAGE_ACCOUNT"')
check "reads host, admin login, database and storage account from Azure" \
  "$report" "mysql-drupal-xyz.mysql.database.azure.com|siteadmin|sitedb|stsite"

# The admin login is a property of the server, so it must be read rather than
# assumed to be the template's default.
grep -q 'siteadmin' <<<"$report" && ok "does not assume the default admin login" \
                                 || no "hardcoded the default admin login"

# An explicit override always wins over discovery.
out=$(STUB_SERVER=mysql-drupal-xyz AZURE_MYSQL_DB=override \
  bash -c '
    source scripts/lib/prompt.sh; source scripts/lib/secrets.sh
    discover_deployment rg-x >/dev/null 2>&1; printf "%s" "$AZURE_MYSQL_DB"')
check "an explicit override beats discovery" "$out" "override"

# No server: fail with a message that says what to do, rather than proceeding
# with empty values.
report=$(STUB_SERVER='' bash -c '
    source scripts/lib/prompt.sh; source scripts/lib/secrets.sh
    discover_deployment rg-x' 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "fails when there is no server to discover" \
                  || no "succeeded with nothing to discover"
grep -q 'azure-up.sh' <<<"$report" && ok "and says how to fix it" \
                                   || no "failed without saying what to do"

printf '\ngenerate_secret\n'

v1="$(generate_secret)"; v2="$(generate_secret)"
check "produces the requested length" "${#v1}" "48"
[[ "$v1" != "$v2" ]] && ok "produces a different value each time" \
                     || no "produced the same value twice"
[[ "$v1" =~ [A-Z] && "$v1" =~ [a-z] && "$v1" =~ [0-9] ]] \
  && ok "satisfies Azure MySQL's three-of-four character-class rule" \
  || no "missing a required character class"
# The alphabet has to survive a shell, a mysql invocation and a URI without
# escaping. Anything outside it eventually gets mangled by one of the three.
[[ "$v1" =~ ^[A-Za-z0-9._-]+$ ]] && ok "uses only shell/URI/mysql-safe characters" \
                                 || no "contains a character needing escaping: $v1"
v3="$(generate_secret 24)"
check "honours an explicit length" "${#v3}" "24"

# One home for the generator. Two copies is how one of them quietly loses a
# character-class check.
copies=$(grep -rl 'generate_secret()' scripts/ 2>/dev/null | wc -l | tr -d ' ')
check "exactly one definition of generate_secret in the tree" "$copies" "1"
grep -q 'generate_secret()' scripts/lib/secrets.sh \
  && ok "and it lives in lib/secrets.sh" || no "the definition is not in the library"

# The canonical secret names must not be duplicated as literals either.
for f in scripts/azure-up.sh scripts/rotate-secrets.sh; do
  if grep -qE "['\"]mysql-admin-password['\"]" "$f"; then
    no "$(basename "$f") hardcodes the secret name instead of using KV_SECRET_DB_PASSWORD"
  else
    ok "$(basename "$f") uses the shared secret-name constant"
  fi
done

printf '\nmigrate.sh credential handling\n'

# Regression guards on the calling script, since these are the properties that
# actually protect the operator.
grep -qE '^\s*resolve_secret AZURE_MYSQL_PASS' scripts/migrate.sh \
  && ok "migrate.sh resolves the Azure password from Key Vault" \
  || no "migrate.sh does not resolve the Azure password from Key Vault"

grep -qE 'prompt_(val|secret)\s+AZURE_MYSQL_(PASS|USER|HOST)' scripts/migrate.sh \
  && no "migrate.sh still asks a human for an Azure value it could discover" \
  || ok "migrate.sh asks for no Azure value it can discover"

# The password must never reach a command line, local or remote: argv is world
# readable via ps, and on shared hosting that is the whole risk.
grep -qE '\-p"?\$\{?(CPANEL_DB_PASS|AZURE_MYSQL_PASS|_esc_pass)' scripts/migrate.sh \
  && no "a password is passed on a command line" \
  || ok "no password is passed on a command line"

grep -q 'IFS= read -r _pw' scripts/migrate.sh \
  && ok "the remote password is read from stdin with IFS= (whitespace preserved)" \
  || no "the remote password is not read from stdin, or would be whitespace-stripped"

grep -qE '^forget_secrets ' scripts/migrate.sh \
  && ok "migrate.sh forgets the credentials when finished" \
  || no "migrate.sh leaves credentials set after use"

printf '\nno script asks for a secret it can fetch\n'

# azure-up.sh must never prompt for, or require, a credential. It generates them.
if grep -qE '^\s*prompt_secret' scripts/azure-up.sh; then
  no "azure-up.sh prompts for a secret — it should generate and vault them"
else
  ok "azure-up.sh prompts for no secret at all"
fi

# And no script should tell the operator to export one. The docs contain that
# pattern only as a labelled counter-example, so this checks the SCRIPTS.
if grep -rnE '^\s*(export )?(MYSQL_ADMIN_PASSWORD|AZURE_MYSQL_PASS|DRUPAL_HASH_SALT)=' \
     scripts/*.sh 2>/dev/null | grep -vE 'generate_secret|keyvault_get|openssl|=""|:-\}' ; then
  no "a script assigns a credential from a literal or an exported variable"
else
  ok "no script takes a credential from an exported variable"
fi

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[[ "$FAILED" -eq 0 ]]
