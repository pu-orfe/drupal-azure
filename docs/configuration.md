# Configuration reference

**Read this if** you need to change a setting, or you are trying to work out
where a value comes from.

Everything here is an environment variable on the app, set by the Bicep template
and overridable per deployment. Nothing here is a secret: the two secrets arrive
as Key Vault references — see **[Secrets](secrets.md)**.

## Where a value comes from

```
scripts/azure-up.sh                  reads AZURE_*/MYSQL_* from your shell
  └─ infra/<platform>/main.bicepparam    maps them to template parameters
       └─ infra/<platform>/main.bicep         passes them to the modules
            └─ infra/modules/appservice.bicep      sets them as app settings
                 └─ the container's environment
                      └─ docker/drupal/settings.azure.php   reads them with getenv()
                      └─ docker-entrypoint.sh               reads them too
```

So there are two places to change something, and which you want depends on
whether the change should persist:

| | Command | Persists a redeploy? |
|---|---|---|
| Permanent | `MYSQL_COLLATION=… ./scripts/azure-up.sh` | Yes — it is in the template's inputs |
| One-off | `az webapp config appsettings set …` | **No** — the next `azure-up.sh` overwrites it |

## Deployment inputs (`scripts/azure-up.sh`)

Set these in your shell before deploying. **None of them is a secret** — there is
no password to supply, because `azure-up.sh` generates the two credentials and
puts them straight into Key Vault. If you find yourself wanting to `export` a
password, see [Secrets](secrets.md#reading-a-secret-you-actually-need).

| Variable | Default | |
|---|---|---|
| `AZURE_PLATFORM` | `appservice` | or `containerapps` — see [Choosing a platform](choosing-a-platform.md) |
| `AZURE_LOCATION` | `eastus` | Any region with MySQL Flexible Server and your chosen host |
| `AZURE_BASE_NAME` | `drupal` | **Max 11 characters.** Longer produces an invalid storage account name, and the deployment fails after creating half the infrastructure |
| `AZURE_ENVIRONMENT` | `prod` | `dev` \| `staging` \| `prod`. Part of the resource group name |
| `AZURE_SUBSCRIPTION` | *(prompted)* | |
| `AZURE_IP_ALLOW_LIST` | *(open)* | JSON array of allow rules. See [Restricting access](#restricting-access) below |
| `DRUPAL_TRUSTED_HOSTS` | *(empty)* | Comma-separated custom domains |
| `APP_SERVICE_SKU` | `B1` | App Service only. `S1` adds deployment slots and autoscale |
| `MIN_REPLICAS` / `MAX_REPLICAS` | `1` / `3` | Container Apps only |
| `MYSQL_SKU_NAME` | `Standard_B1ms` | |
| `MYSQL_STORAGE_GB` | `32` | Auto-grow is on, so this is a floor not a ceiling |
| `MYSQL_VERSION` | `8.0.21` | Pinned deliberately — see [database.md](database.md#engine-version-pinned) |
| `MYSQL_COLLATION` | `utf8mb4_general_ci` | **Must match your data.** Run `./scripts/migrate.sh --audit` first |
| `PUBLIC_SHARE_QUOTA_GB` / `PRIVATE_SHARE_QUOTA_GB` | `100` / `100` | A ceiling, not an allocation — you pay for what is used |
| `LOG_RETENTION_DAYS` | `30` | 30 is the free allowance |
| `DRUPAL_CRON_EXPRESSION` | `*/15 * * * *` | |
| `DEPLOY_EMAIL` | `true` | `false` skips the mail Logic App. See [email.md](email.md) |

## Read by the settings overlay (`docker/drupal/settings.azure.php`)

| Variable | Default | |
|---|---|---|
| `DRUPAL_HASH_SALT` | **required** | A Key Vault reference, set by the template. Missing → the overlay exits. See [secrets.md](secrets.md) |
| `DRUPAL_DB_PASSWORD` | **required** | A Key Vault reference, set by the template. Never a literal |
| `DRUPAL_DB_HOST` / `_NAME` / `_USER` | **required** | Set by the template. Missing → the overlay exits |
| `DRUPAL_DB_PORT` | `3306` | |
| `DRUPAL_DB_DRIVER` | `mysql` | |
| `DRUPAL_DB_PREFIX` | *(none)* | Set only if migrating a prefixed database |
| `DRUPAL_DB_COLLATION` | `utf8mb4_general_ci` | **Must match the database default.** See database.md |
| `DRUPAL_DB_ISOLATION_LEVEL` | `READ COMMITTED` | |
| `DRUPAL_DB_SSL_MODE` | `verify` | `verify` \| `on` \| `off` |
| `DRUPAL_DB_SSL_CA` | system CA bundle | Only for a private CA |
| `DRUPAL_TRUSTED_HOSTS` | *(empty)* | Comma-separated. The Container Apps domain is always allowed |
| `DRUPAL_FILE_PUBLIC_PATH` | `sites/default/files` | Must match the Bicep mount path |
| `DRUPAL_FILE_PRIVATE_PATH` | `/var/www/html/private` | Must match the Bicep mount path |
| `DRUPAL_REVERSE_PROXY_ADDRESSES` | *(the requesting proxy)* | Explicit allow-list, if you have one |
| `DRUPAL_FORCE_HTTPS` | `1` | `0` only for a deployment genuinely served over HTTP |
| `DRUPAL_SESSION_COOKIE_SECURE` | `1` | |
| `DRUPAL_SESSION_COOKIE_SAMESITE` | `Lax` | `None` only for genuine cross-site embedding, and it requires Secure |
| `DRUPAL_SESSION_COOKIE_DOMAIN` | *(host-only)* | e.g. `.example.edu` to share a session across subdomains |
| `DRUPAL_ERROR_LEVEL` | `hide` | `verbose` locally only |
| `DRUPAL_ENVIRONMENT` | *(unset)* | Label for the environment indicator |
| `AZURE_LOGIC_APP_MAIL_URL` | *(unset)* | Set by `setup-email.sh`. Unset means Drupal falls back to a mail system that **accepts and discards** — see [email.md](email.md) |

## Read by the entrypoint (`docker-entrypoint.sh`)

| Variable | Default | |
|---|---|---|
| `CONTAINER_VERSION` | `unknown` | Set by `--build-arg COMMIT_SHA`. `unknown` makes the deploy sequence run on **every** replica start |
| `DRUPAL_SKIP_DEPLOY_TASKS` | `0` | `1` on the cron and drush jobs, so they can never race the web container's schema work |
| `DRUPAL_FORCE_DEPLOY_TASKS` | `0` | `1` runs the sequence regardless of the marker — and keeps doing so until removed |
| `DRUPAL_BACKUP_DIR` | `…/private/.deploy-backups` | Must be on a mounted share to outlive the replica |
| `DRUPAL_REQUIRE_BACKUP` | `1` | `1` refuses to run schema updates if the pre-deploy dump failed. Set `0` only for a first deploy with no share yet |
| `DRUPAL_BACKUP_KEEP` | `10` | Older dumps are pruned. Unbounded dumps silently fill the share, and a full share breaks uploads, not just backups |
| `DRUPAL_DB_WAIT_SECONDS` | `120` | |
| `DRUPAL_LOCK_WAIT_SECONDS` | `600` | How long a non-winning replica waits before serving anyway |
| `DRUPAL_LOCK_STALE_SECONDS` | `1800` | After this, a held lock may be taken over — covers a replica evicted mid-run. Must exceed the longest plausible `updb` |

## Restricting access

```bash
AZURE_IP_ALLOW_LIST='[{"name":"campus","ipAddress":"192.0.2.0/24","priority":100,"action":"Allow"}]' \
  ./scripts/azure-up.sh
```

The two platforms differ in a way that will catch you out:

| | Default when no rule matches | Consequence |
|---|---|---|
| **App Service** | **Allow** | An allow-list needs a terminal deny-all rule, or it allows everything. The Bicep appends one automatically |
| **Container Apps** | **Deny** | Every rule in the list must share one action; a mixed list is rejected |

On App Service the Kudu endpoint is deliberately **not** covered by these rules
(`scmIpSecurityRestrictionsUseMain: false`). Locking the ops channel to the same
allow-list as the site means losing access to the site exactly when its network
configuration is what broke.

After changing the list, confirm it actually bites:

```bash
./scripts/verify-site.sh https://<host> --expect-block
```

That asserts the *opposite* of the usual check — that the request is refused
before reaching the application. Without it, "the allow-list is in force" is not
something you can demonstrate.

## Things that must agree with each other

Four values appear in more than one place and must match. `tests/shell/run.sh`
asserts all four, so a mismatch fails CI rather than production.

| Value | Places | If they diverge |
|---|---|---|
| PHP version | `Dockerfile`, `Dockerfile.dev`, `composer.json` `config.platform.php`, CI `php-version` | CI validates a runtime that is not the one serving requests |
| Collation | `settings.azure.php`, `mysql.bicep`, `docker-compose.yml` | A later `drush updb` creates tables that cannot be joined to the existing ones |
| Private files path | `settings.azure.php`, the platform Bicep module's mount path | Private files are written to an ephemeral filesystem and vanish, with no error |
| `clear_env = no` | `docker/php-fpm/www.conf` | `getenv()` returns nothing in a web request while working perfectly under drush |

## See also

- **[Secrets](secrets.md)** — the two values that are *not* here, and why.
- **[Database settings](database.md)** — what the database values actually do.
- **[Operations](operations.md)** — changing these on a running deployment.
