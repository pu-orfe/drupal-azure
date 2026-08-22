# Drupal on Azure

A production-ready deployment template for a Composer-based Drupal site on Azure.

```bash
git clone --recurse-submodules <this repo> && cd drupal-azure
./scripts/local-dev.sh          # Drupal on http://localhost:8080, admin/admin
```

That needs Docker and nothing else. When you are ready for Azure:
**[Getting started](docs/getting-started.md)**.

---

## Is this for you?

**Yes, if** you are running a departmental or institutional Drupal site — tens to
low hundreds of users — and you want it on Azure with the database off the public
internet, secrets in Key Vault, one immutable image per commit, and deploys that
fail loudly instead of quietly.

**Probably not, if** you need multi-site, thousands of concurrent users, or a
provider-neutral setup. This is deliberately Azure-shaped.

**Note:** logins are **Entra ID only**. There are no working local passwords. See
**[Authentication](docs/authentication.md)**.

## What you get

| | |
|---|---|
| **MySQL Flexible Server** | Delegated subnet, no public endpoint, TLS required, version pinned |
| **Azure Files** | Public and private upload shares, default-deny, VNet-scoped |
| **Key Vault** | Secrets read by managed identity, generated not typed, never in the app config |
| **Container Registry** | Pull by managed identity; the admin account is off |
| **One image per commit** | Rollback is repointing a tag or shifting traffic — never a rebuild |
| **A deploy that checks itself** | Validated pre-deploy backup, schema updates before the app goes live, a smoke test that reads the response body |
| **Local dev that matches** | MySQL 8 with production's collation and `sql_mode` |
| **A real test suite** | Unit tests for the settings logic, shell tests for the destructive-path guards, and an integration suite that boots the production image against real MySQL 8 |

Two hosting platforms are supported and **App Service is the default** —
[why](docs/choosing-a-platform.md). Switching is one environment variable, not a
rewrite.

---

## Documentation

Also available as an index: [`docs/`](docs/README.md).

**Start here**

| | |
|---|---|
| **[Getting started](docs/getting-started.md)** | Local → deployed, end to end |
| **[Choosing a platform](docs/choosing-a-platform.md)** | App Service or Container Apps. The one real decision |

**Running it**

| | |
|---|---|
| **[Troubleshooting](docs/troubleshooting.md)** | Start here when something breaks. Organised by symptom |
| **[Operations](docs/operations.md)** | Logs, rollbacks, restores, drush, scaling |
| **[Configuration](docs/configuration.md)** | Every variable, and where it comes from |

**Setting things up**

| | |
|---|---|
| **[Authentication](docs/authentication.md)** | Entra-only logins, and why `genpass` is not optional |
| **[Secrets](docs/secrets.md)** | Key Vault, rotation, and proving a rotation took effect |
| **[GitHub Actions](docs/github-actions.md)** | OIDC federation — no stored credentials |
| **[Migrating a site](docs/migrating-a-site.md)** | Bringing an existing Drupal site in |

**Understanding it**

| | |
|---|---|
| **[Design notes](docs/design-notes.md)** | Why the image, entrypoint and probes are shaped this way |
| **[Database settings](docs/database.md)** | Collation, isolation, and the traps |
| **[Production learnings](docs/production-learnings.md)** | The incidents behind the decisions. Read before "simplifying" anything |

---

## How a deploy works

```
push to main
  └─ build the image, tagged with the commit SHA
  └─ verify it structurally                     scripts/verify-production-image.sh
  └─ roll it out
       └─ entrypoint, inside the container:
            reject any secret that did not resolve
            wait for the database (authenticated query, not a ping)
            take the deploy lock                one instance does the work
            take a VALIDATED pre-deploy backup  size + gzip + trailer checked
            drush updb → config:import → cache:rebuild, each exit code recorded
            record the image version            so a restart skips all of this
  └─ smoke-test it                              scripts/verify-site.sh
  └─ roll back on failure
```

Four properties are worth naming, because they are what most Drupal-on-Azure
pipelines get wrong:

**Schema updates run before the app is live, not after traffic moves.** Running
`drush updb` from CI afterwards means requests hit new code against an old schema
— and `az containerapp exec` gives no exit code a workflow can trust, so a failed
schema update produced a *green* deploy.

**They run once per image, not once per start.** The entrypoint records the
image's version in the database and skips the sequence when it matches, so
restarts and scale-ups boot fast. A lock covers several replicas starting at once.

**The backup is validated, not assumed.** A failed `mysqldump | gzip` writes a
*valid* ~20-byte gzip, and writing straight to the destination destroys the
previous good backup. If the dump does not validate, the boot refuses to run
schema updates.

**The smoke test reads the body, and checks who answered.** Drupal returns 200
with a blank page for a fatal error, and an access-restricted site returns 403 for
every path including ones that do not exist. `verify-site.sh` has three outcomes:
pass, fail, and **inconclusive**.

---

## Common commands

```bash
./scripts/local-dev.sh                  # local stack
./scripts/test.sh                       # all suites
./scripts/azure-up.sh                   # deploy/update infrastructure
./scripts/azure-logs.sh                 # stream logs
./scripts/rollback.sh --previous        # roll back
./scripts/drush.sh cache:rebuild        # drush, with a real exit code
./scripts/kudu.sh cat /home/boot-result.json    # what the last boot did
./scripts/azure-backup.sh               # backup
./scripts/rotate-secrets.sh --rotate db # rotate a secret
./scripts/azure-nuke.sh --keep-storage  # tear down, keep the files
```

Every script reads its configuration from the environment and prompts only when a
value is missing, so the same script works interactively and in CI. Full list:
[`scripts/README.md`](scripts/README.md).

---

## Repository layout

```
Dockerfile  Dockerfile.dev  docker-compose.yml
docker-entrypoint.sh          boot: secrets, lock, backup, updb/cim/cr, marker
docker/
  entrypoint-lib.sh           the destructive-path guards, separately testable
  drupal/settings.azure.php   the settings overlay — the file to read first
  nginx/  php/  php-fpm/  supervisor/
infra/
  appservice/                 default platform
  containerapps/              alternative platform
  modules/                    shared building blocks
scripts/                      see scripts/README.md
tests/
  php/                        settings-overlay unit tests
  shell/                      scripts, guards, cross-file consistency
docs/                         see the table above
```

---

## Things this template deliberately does not do

- **No Redis or Memcached.** Drupal's database cache is adequate to a surprisingly
  high traffic level, and adding a cache service before measuring a need buys an
  extra failure mode.
- **No CDN in front of the files share.** Azure Files over SMB is a round trip per
  asset — fine at low volume, worth fronting if you serve many large files.
- **No custom domain automation.** Two `az` commands, but it needs DNS records
  this template cannot create. Remember to add the domain to
  `DRUPAL_TRUSTED_HOSTS`.
- **No horizontal scaling on App Service.** It needs shared session and cache
  handling that is not set up here; without it users get randomly dropped
  sessions. Scale vertically, or use Container Apps.
