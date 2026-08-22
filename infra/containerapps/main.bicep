// ============================================================================
// Drupal on Azure Container Apps — full infrastructure
//
// Deploy: az deployment sub create --location <region> --template-file infra/main.bicep
//         (or use scripts/azure-up.sh, which supplies the parameters and seeds
//          Key Vault)
// ============================================================================

targetScope = 'subscription'

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------
@description('Azure region for all resources.')
param location string = 'eastus'

@description('''
Base name used to derive every resource name.

Capped at 11 characters, not 16. The storage account name is
`st<baseName><13-char uniqueString>` and Azure caps storage account names at 24
characters, so a 16-character baseName produces an invalid name and the whole
deployment fails at the storage step — after the VNet and MySQL server have
already been created. The cap is enforced here so the failure is a parameter
validation error before anything is provisioned.
''')
@minLength(3)
@maxLength(11)
param baseName string = 'drupal'

@description('Environment tag.')
@allowed(['dev', 'staging', 'prod'])
param environment string = 'prod'

// ── Secrets ────────────────────────────────────────────────────────────────
// Both are seeded into Key Vault, and the container app reads them from there.
// Empty means "leave whatever is already in the vault alone", so a redeploy that
// does not supply them is safe.
@secure()
@description('MySQL administrator password. Required on first deployment.')
param mysqlAdminPassword string = ''

@secure()
@description('Drupal hash salt. Required on first deployment. Generate with: openssl rand -hex 32')
param drupalHashSalt string = ''

@description('Object ID of the principal running this deployment, granted Key Vault Secrets Officer so it can seed and rotate secrets.')
param deployerPrincipalId string = ''

// ── Database ───────────────────────────────────────────────────────────────
param mysqlAdminLogin string = 'drupaladmin'
param mysqlSkuName string = 'Standard_B1ms'
param mysqlSkuTier string = 'Burstable'
param mysqlStorageSizeGB int = 32
param mysqlVersion string = '8.0.21'
param mysqlCollation string = 'utf8mb4_general_ci'
param mysqlBackupRetentionDays int = 7

// ── App ────────────────────────────────────────────────────────────────────
param appCpu string = '0.5'
param appMemory string = '1Gi'

@description('0 enables scale-to-zero. Use 1 for anything user-facing — see README "Scaling".')
param minReplicas int = 1
param maxReplicas int = 3

@description('Container image repository name inside the registry.')
param imageName string = 'drupal'
param imageTag string = 'latest'

@description('Comma-separated custom domains Drupal accepts as a Host header.')
param trustedHosts string = ''

@description('Ingress allow-list; empty means open. See infra/modules/aca.bicep.')
param ipAllowList array = []

// ── Storage ────────────────────────────────────────────────────────────────
param publicShareQuotaGB int = 100
param privateShareQuotaGB int = 100

param logRetentionDays int = 30

@description('Cron expression (UTC) for the scheduled Drupal cron job. See infra/modules/jobs.bicep for why cron is a Job rather than automated_cron.')
param cronExpression string = '*/15 * * * *'

@description('Set false to skip the cron and drush jobs (e.g. a dev environment that does not need them).')
param deployJobs bool = true

// ---------------------------------------------------------------------------
// Derived names
// ---------------------------------------------------------------------------
var suffix = uniqueString(subscription().subscriptionId, baseName, environment)
var rgName = 'rg-${baseName}-${environment}'
var vnetName = 'vnet-${baseName}-${suffix}'
var acrName = 'acr${baseName}${suffix}'
// take() rather than trusting the baseName cap alone: uniqueString is 13
// characters, 'st' is 2, so this is only safe up to an 11-character baseName and
// the truncation makes that explicit at the point of use.
var storageName = take('st${baseName}${suffix}', 24)
var keyVaultName = take('kv-${baseName}-${suffix}', 24)
var mysqlName = 'mysql-${baseName}-${suffix}'
var acaEnvName = 'acaenv-${baseName}-${suffix}'
var acaAppName = 'app-${baseName}'
var logWorkspaceName = 'log-${baseName}-${suffix}'
var identityName = 'id-${baseName}-${suffix}'

var commonTags = {
  project: baseName
  environment: environment
  managedBy: 'bicep'
}

resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: rgName
  location: location
  tags: commonTags
}

module networking '../modules/networking.bicep' = {
  scope: rg
  name: 'networking'
  params: {
    location: location
    vnetName: vnetName
    appSubnetDelegation: 'Microsoft.App/environments'
  }
}

module logging '../modules/logging.bicep' = {
  scope: rg
  name: 'logging'
  params: {
    location: location
    workspaceName: logWorkspaceName
    retentionInDays: logRetentionDays
  }
}

module acr '../modules/acr.bicep' = {
  scope: rg
  name: 'acr'
  params: {
    location: location
    acrName: acrName
  }
}

module keyvault '../modules/keyvault.bicep' = {
  scope: rg
  name: 'keyvault'
  params: {
    location: location
    keyVaultName: keyVaultName
    deployerPrincipalId: deployerPrincipalId
    mysqlAdminPassword: mysqlAdminPassword
    drupalHashSalt: drupalHashSalt
  }
}

// The identity and its role grants are a separate module so they complete before
// the container app is created — see modules/identity.bicep for why that
// ordering is what makes a first deployment succeed.
module identity '../modules/identity.bicep' = {
  scope: rg
  name: 'identity'
  params: {
    location: location
    identityName: identityName
    acrId: acr.outputs.acrId
    keyVaultId: keyvault.outputs.keyVaultId
  }
}

module storage '../modules/storage.bicep' = {
  scope: rg
  name: 'storage'
  params: {
    location: location
    storageName: storageName
    appSubnetId: networking.outputs.appSubnetId
    publicShareQuotaGB: publicShareQuotaGB
    privateShareQuotaGB: privateShareQuotaGB
  }
}

module mysql '../modules/mysql.bicep' = {
  scope: rg
  name: 'mysql'
  params: {
    location: location
    mysqlName: mysqlName
    adminLogin: mysqlAdminLogin
    // The MySQL resource needs the literal at create time; it cannot read a Key
    // Vault reference. This is the one place the plaintext is unavoidable, which
    // is why azure-up.sh generates it and never asks a human to paste one.
    adminPassword: mysqlAdminPassword
    skuName: mysqlSkuName
    skuTier: mysqlSkuTier
    storageSizeGB: mysqlStorageSizeGB
    mysqlVersion: mysqlVersion
    collation: mysqlCollation
    backupRetentionDays: mysqlBackupRetentionDays
    vnetSubnetId: networking.outputs.dbSubnetId
    vnetId: networking.outputs.vnetId
  }
}

module aca '../modules/aca.bicep' = {
  scope: rg
  name: 'aca'
  params: {
    location: location
    acaEnvName: acaEnvName
    acaAppName: acaAppName
    logWorkspaceCustomerId: logging.outputs.workspaceCustomerId
    logWorkspaceKey: logging.outputs.workspaceKey
    infraSubnetId: networking.outputs.appSubnetId
    acrLoginServer: acr.outputs.loginServer
    imageName: imageName
    imageTag: imageTag
    managedIdentityId: identity.outputs.identityId
    storageName: storage.outputs.accountName
    storageAccountKey: storage.outputs.accountKey
    publicShareName: storage.outputs.publicShareName
    privateShareName: storage.outputs.privateShareName
    mysqlHost: mysql.outputs.fqdn
    mysqlUser: mysqlAdminLogin
    mysqlDatabase: mysql.outputs.databaseName
    mysqlCollation: mysql.outputs.collation
    mysqlPasswordSecretUri: keyvault.outputs.mysqlPasswordSecretUri
    hashSaltSecretUri: keyvault.outputs.hashSaltSecretUri
    appCpu: appCpu
    appMemory: appMemory
    minReplicas: minReplicas
    maxReplicas: maxReplicas
    trustedHosts: trustedHosts
    environmentName: environment
    ipAllowList: ipAllowList
  }
}

module jobs '../modules/jobs.bicep' = if (deployJobs) {
  scope: rg
  name: 'jobs'
  params: {
    location: location
    environmentId: aca.outputs.environmentId
    jobNamePrefix: acaAppName
    acrLoginServer: acr.outputs.loginServer
    imageName: imageName
    imageTag: imageTag
    managedIdentityId: identity.outputs.identityId
    mysqlHost: mysql.outputs.fqdn
    mysqlUser: mysqlAdminLogin
    mysqlDatabase: mysql.outputs.databaseName
    mysqlCollation: mysql.outputs.collation
    mysqlPasswordSecretUri: keyvault.outputs.mysqlPasswordSecretUri
    hashSaltSecretUri: keyvault.outputs.hashSaltSecretUri
    trustedHosts: trustedHosts
    publicStorageName: 'drupal-public'
    privateStorageName: 'drupal-private'
    cronExpression: cronExpression
  }
}

// ---------------------------------------------------------------------------
// Outputs. scripts/azure-up.sh prints these and the workflows consume them.
// ---------------------------------------------------------------------------
output resourceGroupName string = rg.name
output acrName string = acr.outputs.acrName
output acrLoginServer string = acr.outputs.loginServer
output containerAppName string = aca.outputs.appName
output containerAppFqdn string = aca.outputs.fqdn
output containerAppEnvironmentDomain string = aca.outputs.environmentDefaultDomain
output mysqlFqdn string = mysql.outputs.fqdn
output mysqlDatabase string = mysql.outputs.databaseName
output storageAccountName string = storage.outputs.accountName
output keyVaultName string = keyvault.outputs.keyVaultName
output managedIdentityClientId string = identity.outputs.clientId
output imageReference string = '${acr.outputs.loginServer}/${imageName}:${imageTag}'
output cronJobName string = deployJobs ? jobs!.outputs.cronJobName : ''
output drushJobName string = deployJobs ? jobs!.outputs.drushJobName : ''
