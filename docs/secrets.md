# Secrets

**Read this if** you need to rotate a credential, or you are wondering where the
database password actually lives.

**You do not need it to deploy** — `scripts/azure-up.sh` generates both secrets
and never asks you for one.

Two secrets matter in this deployment:

| Secret | Key Vault name | What it protects |
|---|---|---|
| MySQL administrator password | `mysql-admin-password` | The database |
| Drupal hash salt | `drupal-hash-salt` | CSRF tokens and one-time login links |

The second is the one people underestimate, and it is the more dangerous of the
two. The MySQL server has no public endpoint — it is on a delegated subnet with
public network access disabled — so exploiting a leaked password requires an
existing foothold in the VNet or the container. Bad, but it is missing
defence-in-depth rather than an open door. Drupal derives CSRF tokens and
password-reset links from the hash salt, and the site is reachable from the
internet, so a known salt is a route to forging those with **no foothold at
all**.

---

## How they get there

`scripts/azure-up.sh` generates both on the first deployment and writes them
straight into Key Vault. It does not prompt, and there is no default value.

That is a deliberate design decision, from a specific failure: a `CHANGEME`-style
placeholder default that nothing forces you to replace **becomes** the production
credential — and then it is committed to the repository, byte for byte identical
to the live value, with nobody having decided that should happen.

A prompt is better than a default, and still worse than generation. A typed
secret ends up in a shell history, a terminal scrollback, a password manager, or
a colleague's chat window. A generated one is written to the vault and then
`unset` before the script exits.

Both generators produce 48 characters from an alphabet chosen to be safe inside a
shell, a MySQL client invocation and a URI — no quotes, backslash, dollar,
backtick, `@`, colon, slash or percent — and the result is *checked* against
Azure MySQL's three-of-four character-class requirement rather than assumed to
satisfy it.

---

## How the app reads them

The container app stores **references**, not values:

```jsonc
"secrets": [
  { "name": "mysql-password", "keyVaultUrl": "https://kv-….vault.azure.net/secrets/mysql-admin-password", "identity": "…" }
]
```

resolved at replica start with the user-assigned managed identity, which holds
**Key Vault Secrets User** on the vault and nothing else.

### Why not a Container Apps secret directly

A container app secret is a value stored in the app's configuration. It is
readable by anyone with Contributor on the resource group, it appears in
`az containerapp show` output and in exported ARM templates, and rotating it is a
configuration change. Worse: the tooling has to *hold* the plaintext in order to
write it, so it passes through a shell history, a CI log, or a Bicep parameter
file on the way in.

A vault reference stores a URI. Rotation is a secret write plus a restart — no
deployment, no commit, and the value never transits CI.

### Why the reference is unversioned

`infra/modules/keyvault.bicep` emits `…/secrets/mysql-admin-password` with no
version suffix, so a new secret version is picked up at the next replica start. A
versioned URI pins the app to the old value and makes rotation **silently
ineffective** — the rotation appears to succeed, the site keeps working, and
nothing indicates that the app is still using the previous secret.

### Why the vault is not network-restricted

`publicNetworkAccess: 'Enabled'`, and this looks like something to fix. It is
not.

Container Apps resolves a Key Vault reference from the platform, not from inside
the replica. The request does not originate in the app subnet, so a
`defaultAction: Deny` vault with a VNet rule for that subnet refuses it — and the
failure surfaces as a revision that never becomes healthy, with no message naming
the vault. What protects the vault is that reading a secret requires the Key
Vault Secrets User role: authorisation, not network position.

### Why purge protection is off

Key Vault soft delete is mandatory and cannot be disabled, so deleting the
resource group leaves the vault *name* reserved for the retention period. With
purge protection **on**, nothing can release it early — so
`azure-nuke.sh` followed by `azure-up.sh`, the exact loop this template exists to
support, fails on a name conflict that mentions nothing about soft delete.

`azure-nuke.sh` offers to purge it. Turn purge protection **on** for a vault
holding anything you cannot regenerate.

---

## One unavoidable plaintext

The MySQL resource needs the literal password at creation time: an ARM resource
cannot read a Key Vault reference for `administratorLoginPassword`. So on a first
deployment the value exists in the deployment's parameters.

Consequences worth knowing:

- **`az deployment sub show` does not return it.** The parameter is `@secure()`,
  so ARM stores it as `null` in the deployment record.
- **A redeploy does not reset it.** `azure-up.sh` detects an existing vault,
  reads the current password back out, and passes *that* — because passing a
  newly generated one would reset the server admin password on every redeploy and
  break every running replica at its next restart.
- **If the script cannot read the vault, it stops.** It does not fall back to
  generating a value, because writing a new password to the server while the
  vault holds the old one is a self-inflicted outage.

---

## Rotating

```bash
./scripts/rotate-secrets.sh --list
./scripts/rotate-secrets.sh --rotate db   [--dry-run]
./scripts/rotate-secrets.sh --rotate salt [--dry-run]
```

### The database password

Order is load-bearing: **vault first, then the server.**

If the server update fails after the vault write, the vault holds a password the
server does not accept and the site breaks at its next restart — but the fix is
one command with a value you still have. The other order leaves the site working
until its next restart and then broken with the correct password *nowhere*,
because the server no longer accepts the old one and nothing recorded the new
one.

### The hash salt

Rotating it invalidates every active session and every outstanding password-reset
link. That is the desired effect when the salt has leaked and a surprise
otherwise, so the script says so before doing it.

### Applying it

A running replica does not re-read a vault reference. `rotate-secrets.sh`
restarts the live revision, which goes through the ordinary revision machinery —
so a bad rotation shows up as an unhealthy revision rather than as a live outage
— and then runs `verify-site.sh` against the result.

---

## Reading a secret you actually need

Every script that needs a credential this deployment owns fetches it itself, via
`scripts/lib/secrets.sh`, in this order:

1. **The environment**, if already set — so CI can inject one.
2. **Key Vault**, which is the normal path.
3. **A hidden prompt**, as a last resort.

The order is the point. Key Vault *before* the prompt means the ordinary case
involves no human at all, and being asked for a password is therefore a signal
that something is wrong — either the deployment predates the vault, or you do not
have `Key Vault Secrets User` on it. The prompt says so when it appears.

So there is no step anywhere in this repository that looks like:

```bash
export MYSQL_ADMIN_PASSWORD='<strong-password>'    # never do this
export AZURE_MYSQL_PASS="$MYSQL_ADMIN_PASSWORD"
```

That pattern is wrong in more ways than it first appears:

- it lands in shell history, and `export` exposes it to every child process for
  the rest of the session;
- it invites you to invent a password, or to reuse one;
- it invites you to keep a copy "for next time", which is how a credential ends
  up in a password manager shared by four people;
- and it is unnecessary, because the value is already in a vault you can read.

Scripts also `unset` a credential as soon as they are finished with it, so it does
not survive into a subshell or a core file.

### A note on "zero-knowledge"

This is not zero-knowledge in the cryptographic sense — nothing here is a proof
system, and anyone with Key Vault read access can obviously read the secret. What
it gives you is narrower and still worth having: **you never have to know the
value to do your job.** It never enters your shell, your history, your notes or
your clipboard, and reading it becomes a deliberate, audited act rather than a
step in a runbook.

If you do need to look at one:

```bash
az keyvault secret show --vault-name "$KV" --name mysql-admin-password \
  --query value -o tsv
```

That is a logged data-plane read against a named identity, which is exactly what
you want it to be.

### Values that are facts, not secrets

The same principle covers things that are not secret but that a human would
mistype. `discover_deployment` in `lib/secrets.sh` reads the MySQL hostname, the
admin login, the database name and the storage account back from Azure, so no
script asks for them. The admin login in particular is a *property of the server*
— `drupaladmin` is only this template's default, and assuming it is how tooling
breaks on a deployment that chose otherwise.

## Where secrets must never appear

- **Not in `infra/*/main.bicepparam`.** Both parameters read from the environment
  and default to *empty*, and empty means "leave the vault's existing secret
  alone". Committing a value here would put it in git.
- **Not in GitHub Actions.** The three `AZURE_*` repository secrets are
  *identifiers* — client id, tenant id, subscription id — not credentials. There
  is no service principal password, because authentication is OIDC federation
  (see [github-actions.md](github-actions.md)). No workflow in this repository ever
  handles the database password or the hash salt.
- **Not in argv.** `docker-entrypoint.sh` passes the password to `mysql` and
  `mysqldump` via `MYSQL_PWD`, never as `-p"$PASSWORD"`: argv is world-readable in
  `/proc`, so the second form publishes the credential to every process in the
  container for the lifetime of the command.
- **Not in argv on a REMOTE host either.** `migrate.sh` delivers the source
  database's password to cPanel over **stdin**, and the ssh command itself
  contains no secret. Both obvious alternatives leak it: `mysql -p<password>` puts
  it in the remote host's argv where any other user can `ps` it, and interpolating
  it into the ssh command string is no better, because the remote shell runs as
  `sh -c '<the whole string>'` and that argv is just as readable. On shared
  hosting — precisely what you are migrating away from — this is not
  hypothetical.
- **Not in the image.** `web/sites/default/settings.php` and
  `docker/drupal/settings.azure.php` are both tracked in git and contain no
  secrets — everything comes from the environment. That is what makes it possible
  to read what production runs out of the repository.
- **Not as a fallback.** The settings overlay *exits* on a missing required
  variable rather than substituting a default. A predictable hash salt is worse
  than a site that will not start, because a site that will not start is
  something you notice.

---

## Rotating the GitHub → Azure federation

There is no credential to rotate — that is the point of OIDC. To revoke access,
delete the federated credential:

```bash
az ad app federated-credential list --id "$APP_ID" -o table
az ad app federated-credential delete --id "$APP_ID" --federated-credential-id <id>
```

To narrow it, scope the `subject` to a GitHub environment rather than a branch,
and require an approval on that environment. `deploy.yml`'s `rollout` job already
declares `environment: production`, so adding reviewers there gates every
production deploy behind a human.

---

## See also

- **[Configuration](configuration.md)** — everything that is *not* a secret.
- **[Operations](operations.md)** — reading the boot result to confirm which value
  a running container holds.
- **[Troubleshooting](troubleshooting.md)** — `Access denied` after a rotation.
- **[GitHub Actions](github-actions.md)** — the OIDC federation, which has no
  credential to rotate.
