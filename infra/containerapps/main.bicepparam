using './main.bicep'

// ---------------------------------------------------------------------------
// Defaults for scripts/azure-up.sh. Everything here is overridable by an
// environment variable so nothing needs editing for a normal deployment.
//
// NOTE ON THE SECRETS: they are read from the environment and default to EMPTY,
// not to a placeholder. An empty value means "leave the vault's existing secret
// alone", which makes a redeploy safe; a placeholder default would mean the
// first deployment silently ships a known credential and nothing ever forces it
// to be replaced. azure-up.sh generates real values on the first run.
// ---------------------------------------------------------------------------
param location = readEnvironmentVariable('AZURE_LOCATION', 'eastus')
param baseName = readEnvironmentVariable('AZURE_BASE_NAME', 'drupal')
param environment = readEnvironmentVariable('AZURE_ENVIRONMENT', 'prod')

param mysqlAdminPassword = readEnvironmentVariable('MYSQL_ADMIN_PASSWORD', '')
param drupalHashSalt = readEnvironmentVariable('DRUPAL_HASH_SALT', '')
param deployerPrincipalId = readEnvironmentVariable('AZURE_DEPLOYER_PRINCIPAL_ID', '')

param mysqlAdminLogin = readEnvironmentVariable('MYSQL_ADMIN_LOGIN', 'drupaladmin')
param mysqlSkuName = readEnvironmentVariable('MYSQL_SKU_NAME', 'Standard_B1ms')
param mysqlSkuTier = readEnvironmentVariable('MYSQL_SKU_TIER', 'Burstable')
param mysqlStorageSizeGB = int(readEnvironmentVariable('MYSQL_STORAGE_GB', '32'))
param mysqlVersion = readEnvironmentVariable('MYSQL_VERSION', '8.0.21')
param mysqlCollation = readEnvironmentVariable('MYSQL_COLLATION', 'utf8mb4_general_ci')

param appCpu = readEnvironmentVariable('APP_CPU', '0.5')
param appMemory = readEnvironmentVariable('APP_MEMORY', '1Gi')
param minReplicas = int(readEnvironmentVariable('MIN_REPLICAS', '1'))
param maxReplicas = int(readEnvironmentVariable('MAX_REPLICAS', '3'))

param imageName = readEnvironmentVariable('IMAGE_NAME', 'drupal')
param imageTag = readEnvironmentVariable('IMAGE_TAG', 'latest')

param trustedHosts = readEnvironmentVariable('DRUPAL_TRUSTED_HOSTS', '')

param publicShareQuotaGB = int(readEnvironmentVariable('PUBLIC_SHARE_QUOTA_GB', '100'))
param privateShareQuotaGB = int(readEnvironmentVariable('PRIVATE_SHARE_QUOTA_GB', '100'))
param logRetentionDays = int(readEnvironmentVariable('LOG_RETENTION_DAYS', '30'))
param cronExpression = readEnvironmentVariable('DRUPAL_CRON_EXPRESSION', '*/15 * * * *')
param deployJobs = bool(readEnvironmentVariable('DEPLOY_JOBS', 'true'))
