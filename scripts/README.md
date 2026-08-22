# Scripts

Every script:

- **reads its configuration from the environment** and prompts only for what is
  missing, so the same script works interactively and in CI;
- **is safe to re-run** — the Azure ones are idempotent;
- **exits non-zero when it fails**, including the ones that run commands remotely.

Common variables: `AZURE_RESOURCE_GROUP`, `AZURE_PLATFORM` (`appservice` by
default), `AZURE_APP_NAME`. Export them once and nothing prompts. Full list in
[docs/configuration.md](../docs/configuration.md).

**Never export a password.** No script asks you for a credential this deployment
owns — they read it from Key Vault via `lib/secrets.sh` and unset it afterwards.
If one does prompt you for a password, that is a signal that something is wrong
with the vault or your access to it, and it says so. See
[docs/secrets.md](../docs/secrets.md).

## Day to day

| | |
|---|---|
| `local-dev.sh` | Bring up the local stack. `--reset`, `--down`, `--shell`, `--import <dump>` |
| `test.sh` | Run the suites. `--unit`, `--shell`, `--integration` |
| `azure-logs.sh` | Stream logs from the deployment |
| `drush.sh` | Run drush against the deployment, **with a real exit code** |
| `kudu.sh` | App Service ops channel: `ls`, `cat`, `get`, `put`, `run` |

## Deploying and recovering

| | |
|---|---|
| `azure-up.sh` | Create or update the infrastructure. `--what-if` previews |
| `rollback.sh` | `--list`, `--current`, `--previous`, `--to <ref>` |
| `azure-backup.sh` | PITR point + share snapshots + a portable dump |
| `azure-nuke.sh` | Tear down. `--keep-storage` preserves the uploads |
| `rotate-secrets.sh` | `--list`, `--rotate db\|salt` |
| `migrate.sh` | Existing site → Azure. **`--audit` first, always** |

## Called by other things

You will rarely run these directly; the workflows and the Dockerfile do.

| | |
|---|---|
| `verify-site.sh` | Smoke test. Exits 0 pass, 1 fail, **2 inconclusive** |
| `verify-production-image.sh` | Structural gate on the built image |
| `composer-retry.sh` | Bounded retries around composer, for transient registry failures |
| `lib/prompt.sh` | Interactive prompts that skip when a value is already set |
| `lib/platform.sh` | App Service / Container Apps abstraction |
| `lib/secrets.sh` | Resolves credentials from Key Vault so no human handles them |
| `lib/compose.sh` | `COMPOSE`, and a bounded retry around the local stack coming up |

## Reading one

Each script's header explains what it does and, where the behaviour is
non-obvious, what failure it exists to prevent. `verify-site.sh`,
`composer-retry.sh` and `../docker/entrypoint-lib.sh` are the ones most worth
reading before changing.
