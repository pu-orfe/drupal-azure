// ============================================================================
// Drupal on Azure App Service — full infrastructure
//
// The DEFAULT platform for this template. See docs/choosing-a-platform.md for why,
// and infra/containerapps/main.bicep for the alternative.
//
// Deploy: ./scripts/azure-up.sh          (AZURE_PLATFORM=appservice, the default)
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
@description('App Service Plan SKU. B1 is what both live deployments run; S1 adds deployment slots and autoscale. See infra/modules/appservice.bicep.')
param appServiceSku string = 'B1'

@description('Seconds the platform waits for the container to start listening. Sized for the entrypoint\'s schema work, not for nginx.')
param containerStartTimeLimit int = 900

@description('Container image repository name inside the registry.')
param imageName string = 'drupal'
param imageTag string = 'latest'

@description('Comma-separated custom domains Drupal accepts as a Host header.')
param trustedHosts string = ''

@description('IP restrictions; empty means open. See infra/modules/appservice.bicep — App Service defaults to ALLOW when no rule matches, so a terminal Deny is appended automatically.')
param ipAllowList array = []

// ── Storage ────────────────────────────────────────────────────────────────
param publicShareQuotaGB int = 100
param privateShareQuotaGB int = 100

param logRetentionDays int = 30
@description('Provision the outbound-email Logic App and Office 365 connection. Requires one interactive consent afterwards — see docs/email.md.')
param deployEmail bool = true


@description('Cron expression (UTC) for Drupal cron. On App Service this drives a scheduled GitHub workflow rather than a platform job — see docs/operations.md.')
param cronExpression string = '*/15 * * * *'

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
var planName = 'plan-${baseName}-${environment}'
// Globally unique: the default hostname is <appName>.azurewebsites.net.
var appName = 'app-${baseName}-${suffix}'
var logWorkspaceName = 'log-${baseName}-${suffix}'
var identityName = 'id-${baseName}-${suffix}'
var logicAppName = 'logic-${baseName}-mail-${environment}'
var mailConnectionName = 'conn-${baseName}-o365-${environment}'

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
    appSubnetDelegation: 'Microsoft.Web/serverFarms'
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

module appservice '../modules/appservice.bicep' = {
  scope: rg
  name: 'appservice'
  params: {
    location: location
    planName: planName
    appName: appName
    skuName: appServiceSku
    appSubnetId: networking.outputs.appSubnetId
    acrLoginServer: acr.outputs.loginServer
    imageName: imageName
    imageTag: imageTag
    managedIdentityId: identity.outputs.identityId
    managedIdentityClientId: identity.outputs.clientId
    storageAccountName: storage.outputs.accountName
    storageAccountKey: storage.outputs.accountKey
    publicShareName: storage.outputs.publicShareName
    privateShareName: storage.outputs.privateShareName
    mysqlHost: mysql.outputs.fqdn
    mysqlUser: mysqlAdminLogin
    mysqlDatabase: mysql.outputs.databaseName
    mysqlCollation: mysql.outputs.collation
    mysqlPasswordSecretUri: keyvault.outputs.mysqlPasswordSecretUri
    hashSaltSecretUri: keyvault.outputs.hashSaltSecretUri
    trustedHosts: trustedHosts
    environmentName: environment
    ipAllowList: ipAllowList
    logWorkspaceId: logging.outputs.workspaceId
    containerStartTimeLimit: containerStartTimeLimit
  }
}

module email '../modules/email.bicep' = if (deployEmail) {
  scope: rg
  name: 'email'
  params: {
    location: location
    connectionName: mailConnectionName
    logicAppName: logicAppName
    connectionDisplayName: 'Office 365 for ${baseName} (${environment}) — authorise me'
    // The app's own egress, so the allow-list is right in one deployment rather
    // than needing a follow-up script to discover it.
    // map() rather than a for-comprehension: a for-expression's collection must
    // be known when the deployment starts, and this one is another module's
    // output. map() is evaluated at deployment time, so it can consume it.
    allowedCallerIps: map(
      split(appservice.outputs.possibleOutboundIps, ','),
      ip => { addressRange: '${trim(ip)}/32' }
    )
    // Pins the trigger to this app's identity, not merely to the tenant.
    //
    // The SYSTEM-assigned principal, not the user-assigned one: the mail plugin
    // requests a token without a client_id, so that is the identity the token is
    // actually issued to. Pinning the user-assigned principal here would look
    // correct and reject every send with a 401.
    callerPrincipalId: appservice.outputs.systemAssignedPrincipalId
  }
}

// ---------------------------------------------------------------------------
// Outputs. scripts/azure-up.sh prints these and the workflows consume them.
// ---------------------------------------------------------------------------
output platform string = 'appservice'
output resourceGroupName string = rg.name
output acrName string = acr.outputs.acrName
output acrLoginServer string = acr.outputs.loginServer
output appName string = appservice.outputs.appName
output appHostName string = appservice.outputs.defaultHostName
output appUrl string = 'https://${appservice.outputs.defaultHostName}'
output scmUrl string = appservice.outputs.scmHostName
output mysqlFqdn string = mysql.outputs.fqdn
output mysqlDatabase string = mysql.outputs.databaseName
output storageAccountName string = storage.outputs.accountName
output keyVaultName string = keyvault.outputs.keyVaultName
output managedIdentityClientId string = identity.outputs.clientId
output emailLogicAppName string = deployEmail ? email!.outputs.logicAppName : ''
output emailConnectionName string = deployEmail ? email!.outputs.connectionName : ''
output emailAuthorizeUrl string = deployEmail ? email!.outputs.authorizeUrl : ''
output imageReference string = '${acr.outputs.loginServer}/${imageName}:${imageTag}'
// The addresses the app can egress from. Needed when allow-listing it at a
// firewall elsewhere, and when adding it to another service's rules.
output outboundIps string = appservice.outputs.possibleOutboundIps
output cronExpression string = cronExpression
