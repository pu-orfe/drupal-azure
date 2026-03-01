# Drupal 10 on Azure Container Apps

Migrates a Composer-based Drupal 10 site from cPanel to Azure Container Apps with zero-downtime deployments, auto-scaling, and automated updates.

## Architecture

| Component | Azure Service |
|-----------|--------------|
| Compute | Container Apps (scale-to-zero, blue/green revisions) |
| Database | MySQL Flexible Server (VNet-integrated) |
| Files | Storage Account (SMB file shares for public/private) |
| Registry | Azure Container Registry |
| Network | VNet with dedicated app and database subnets |
| Logging | Log Analytics workspace |

Updates flow through GitHub Actions: `composer update` -> Docker build -> push to ACR -> deploy new Container App revision -> run Drush post-deploy commands. No in-place modifications.

## Repository Layout

```
.
├── Dockerfile                         # PHP 8.2-FPM + Nginx (single container)
├── docker/
│   ├── drupal/settings.aca.php        # Azure-specific Drupal settings
│   ├── nginx/default.conf             # Nginx vhost for Drupal clean URLs
│   └── supervisor/supervisord.conf    # Runs Nginx + PHP-FPM together
├── infra/
│   ├── main.bicep                     # Subscription-level orchestrator
│   ├── main.bicepparam                # Default parameter values
│   └── modules/
│       ├── aca.bicep                  # Container Apps environment + app
│       ├── acr.bicep                  # Container Registry
│       ├── logging.bicep              # Log Analytics workspace
│       ├── mysql.bicep                # MySQL Flexible Server
│       ├── networking.bicep           # VNet + subnets
│       └── storage.bicep              # Storage account + file shares
├── scripts/
│   ├── azure-up.sh                    # Deploy/update infrastructure
│   ├── azure-logs.sh                  # Stream container logs
│   ├── azure-backup.sh               # On-demand DB + file share backup
│   ├── azure-nuke.sh                 # Tear down everything (with safeguards)
│   └── migrate.sh                     # cPanel -> Azure data migration
└── .github/workflows/
    └── drupal-update.yml              # CI/CD: composer update, build, deploy
```

## Prerequisites

- **Azure CLI** (`az`) — [install](https://aka.ms/install-azure-cli)
- **Docker** — for local image builds
- **azcopy** — [install](https://aka.ms/azcopy) (migration only)
- **SSH access** to your cPanel host (migration only)
- **Drupal codebase** — `composer.json`, `composer.lock`, and `web/` directory at the repo root

## Deployment

### 1. Prepare your Drupal codebase

Copy or merge your existing Drupal project into this repo so that `composer.json`, `composer.lock`, and the `web/` directory sit at the root alongside the `Dockerfile`.

### 2. Log in to Azure

```bash
az login
```

### 3. Deploy infrastructure

Dry-run first to preview changes:

```bash
./scripts/azure-up.sh --what-if
```

When satisfied, deploy for real:

```bash
export MYSQL_ADMIN_PASSWORD='<strong-password>'
./scripts/azure-up.sh
```

The script deploys all Bicep modules (VNet, MySQL, Storage, ACR, Log Analytics, Container Apps) into a resource group named `rg-drupal-prod`. Outputs include the ACR login server, container app FQDN, and MySQL hostname.

**Tunable parameters** (set via environment variables before running):

| Variable | Default | Description |
|----------|---------|-------------|
| `AZURE_LOCATION` | `eastus` | Azure region |
| `AZURE_BASE_NAME` | `drupal` | Base name for all resources (max 9 chars recommended) |
| `AZURE_ENVIRONMENT` | `prod` | Environment tag (`dev`, `staging`, `prod`) |
| `MYSQL_ADMIN_PASSWORD` | *(prompted)* | MySQL admin password |

### 4. Build and push the Docker image

```bash
ACR_NAME=$(az acr list -g rg-drupal-prod --query '[0].name' -o tsv)
az acr login --name "$ACR_NAME"
docker build -t "$ACR_NAME.azurecr.io/app-drupal:latest" .
docker push "$ACR_NAME.azurecr.io/app-drupal:latest"
```

After the first push, the Container App will pull the image and start serving.

### 5. Migrate data from cPanel

Set the required environment variables and run the migration script:

```bash
export CPANEL_HOST=example.com
export CPANEL_USER=myuser
export CPANEL_DB_NAME=drupal_db
export CPANEL_DB_USER=drupal_user
export CPANEL_DB_PASS='db-password'

export AZURE_RG=rg-drupal-prod
export AZURE_MYSQL_HOST=$(az mysql flexible-server list -g rg-drupal-prod --query '[0].fullyQualifiedDomainName' -o tsv)
export AZURE_MYSQL_USER=drupaladmin
export AZURE_MYSQL_PASS="$MYSQL_ADMIN_PASSWORD"
export AZURE_STORAGE_ACCOUNT=$(az storage account list -g rg-drupal-prod --query '[0].name' -o tsv)

./scripts/migrate.sh
```

The script exports the database via SSH, sanitizes it (removes DEFINERs), imports to Azure MySQL, then rsyncs public and private files to Azure File Shares via azcopy.

### 6. Configure GitHub Actions

In your GitHub repository settings, add:

**Secret:**
- `AZURE_CREDENTIALS` — output of `az ad sp create-for-rbac --sdk-auth`

**Variables:**
- `AZURE_RESOURCE_GROUP` — e.g. `rg-drupal-prod`
- `AZURE_ACR_NAME` — your ACR name
- `AZURE_CONTAINER_APP_NAME` — e.g. `app-drupal`

The workflow runs weekly (Sunday 03:00 UTC) or on manual dispatch. It runs `composer update`, builds a new image, deploys it, and executes `drush updb` and `drush cr`.

## Maintenance

### View logs

```bash
./scripts/azure-logs.sh                # follow logs (default)
./scripts/azure-logs.sh --tail 50      # last 50 lines
./scripts/azure-logs.sh --no-follow    # snapshot only
```

Scripts auto-detect the resource group and container app name. Override with `AZURE_RESOURCE_GROUP` and `AZURE_CONTAINER_APP_NAME` if needed.

### Create backups

```bash
./scripts/azure-backup.sh
```

Creates an on-demand MySQL backup and snapshots both `drupal-public` and `drupal-private` file shares.

### Tear down infrastructure

```bash
./scripts/azure-nuke.sh
```

Requires typing the resource group name and `DELETE` to confirm. Automatically runs a backup before deleting. The deletion runs asynchronously — use the printed command to check status.

### Manual Drush commands

```bash
az containerapp exec \
  --name app-drupal \
  --resource-group rg-drupal-prod \
  --command "sh" -- -c "drush status"
```

### Scaling

Default configuration scales from 0 to 3 replicas. Adjust in `infra/main.bicep`:

```bicep
param minReplicas int = 0   // set to 1 to disable scale-to-zero
param maxReplicas int = 3
param appCpu string = '0.5'
param appMemory string = '1Gi'
```

Redeploy with `./scripts/azure-up.sh` after changing parameters.

## Known Limitations

- Storage account name can exceed the 24-character Azure limit if `baseName` is longer than 9 characters.
- `settings.aca.php` trusted host patterns only cover `*.azurecontainerapps.io` — add custom domains manually if needed.
- `DRUPAL_HASH_SALT` environment variable must be set on the Container App; there is no fallback.
- Drush launcher may need to be replaced with a direct symlink to `vendor/bin/drush` for Drush 12+.
