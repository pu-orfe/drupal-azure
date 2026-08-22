// ---------------------------------------------------------------------------
// App Service Plan + Linux container Web App.
// ---------------------------------------------------------------------------
param location string
param planName string
param appName string
param appSubnetId string

@description('''
Plan SKU.

B1 is what both live deployments this template is modelled on actually run, and
it is the right starting point: one instance, Always On available, ~$13/month
flat. Two things it does NOT give you, worth knowing before you pick it:

  * deployment SLOTS require Standard (S1) or higher. Without a slot there is no
    warm target to swap, so a deploy restarts the one instance in place. See
    docs/choosing-a-platform.md.
  * autoscale requires Standard. B1 scales manually only.

For a departmental Drupal site serving tens to low hundreds of users, neither is
usually worth 3x the cost. For anything where a restart's downtime matters, S1
plus a staging slot is the upgrade to make.
''')
param skuName string = 'B1'

param acrLoginServer string
param imageName string
param imageTag string
param managedIdentityId string
param managedIdentityClientId string

param storageAccountName string
@secure()
param storageAccountKey string
param publicShareName string
param privateShareName string

param mysqlHost string
param mysqlUser string
param mysqlDatabase string
param mysqlCollation string
param mysqlPasswordSecretUri string
param hashSaltSecretUri string

param trustedHosts string = ''
param environmentName string = 'prod'
param logWorkspaceId string

@description('''
IP restrictions. Each entry: { name, ipAddress (CIDR), priority, action }.

Empty means open to the internet. Unlike Container Apps, App Service allows a
mixed Allow/Deny list ordered by priority — so an allow-list needs an explicit
low-priority Deny-all at the end, which is added automatically below when any
rule is supplied.
''')
param ipAllowList array = []

@description('''
Seconds App Service waits for the container to start listening before killing it.

Sized for the entrypoint, not for nginx. docker-entrypoint.sh runs `drush updb`,
`config:import` and `cache:rebuild` BEFORE starting the web server, so on a deploy
carrying schema updates nothing listens on port 80 for minutes. The platform
default is 230 seconds, and a real dump/restore/normalise cycle has been measured
at 222 — one observed run finished just inside the window and the next was killed
part-way through dropping tables.

Maximum accepted is 1800.
''')
@minValue(230)
@maxValue(1800)
param containerStartTimeLimit int = 900

resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planName
  location: location
  sku: {
    name: skuName
  }
  kind: 'linux'
  properties: {
    reserved: true // 'reserved' is how ARM spells "Linux".
  }
}

resource app 'Microsoft.Web/sites@2023-12-01' = {
  name: appName
  location: location
  kind: 'app,linux,container'
  identity: {
      // SystemAssigned AS WELL AS UserAssigned, and this is load-bearing rather
      // than belt-and-braces.
      //
      // The user-assigned identity exists so its AcrPull and Key Vault grants can
      // be made BEFORE the app is created (see modules/identity.bicep). But the
      // mail plugin requests a managed-identity token WITHOUT a client_id, and
      // with only user-assigned identities attached that request is ambiguous —
      // the platform cannot know which to issue for. Enabling the system-assigned
      // identity gives a client_id-less request one unambiguous answer, which is
      // the identity the Logic App's `sub` claim is then pinned to.
      //
      // Removing 'SystemAssigned' here breaks outbound email, and it breaks it
      // silently: the token request fails at SEND time, so the first symptom is
      // a password-reset message that never arrives.
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${managedIdentityId}': {}
    }
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    // Regional VNet integration: outbound traffic from the app enters the VNet,
    // which is what lets it reach a MySQL server that has no public endpoint.
    virtualNetworkSubnetId: appSubnetId
    // Route ALL outbound traffic through the VNet, not just RFC1918 ranges.
    // Without this the storage account's VNet rule refuses the app, because the
    // SMB mount would leave from a platform address instead of the subnet.
    vnetRouteAllEnabled: true
    clientAffinityEnabled: false

    siteConfig: {
      linuxFxVersion: 'DOCKER|${acrLoginServer}/${imageName}:${imageTag}'
      // Pull with the managed identity rather than the registry's admin
      // account: an AcrPull-only grant that Azure rotates itself, instead of a
      // shared push-capable credential stored in the app's configuration.
      acrUseManagedIdentityCreds: true
      acrUserManagedIdentityID: managedIdentityClientId

      alwaysOn: true
      http20Enabled: true
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'

      // One worker. Scaling Drupal horizontally on App Service needs shared
      // session and cache handling that this template does not set up, and
      // vertical is the right axis for this workload anyway. Raising this
      // without that work gives users randomly-dropped sessions.
      numberOfWorkers: 1

      // The health check endpoint is answered by nginx with no PHP and no
      // database, so it reports exactly one thing: the web server is up. Pointing
      // it at a Drupal URL makes a brief database outage recycle the instance,
      // turning a recoverable problem into a restart loop.
      healthCheckPath: '/nginx-health'

      ipSecurityRestrictions: empty(ipAllowList) ? null : concat(ipAllowList, [
        {
          // App Service evaluates rules by priority and DEFAULTS TO ALLOW when
          // nothing matches — the opposite of Container Apps. An allow-list
          // without this terminal rule allows everything, which is a silent
          // no-op rather than a visible error.
          name: 'deny-all'
          ipAddress: 'Any'
          action: 'Deny'
          priority: 2147483647
        }
      ])
      // The SCM (Kudu) endpoint is gated by Azure RBAC, not by these rules, and
      // the operational tooling depends on reaching it. Kept separate on purpose.
      scmIpSecurityRestrictionsUseMain: false

      appSettings: [
        // -------------------------------------------------------------------
        // /home is App Service's persistent, instance-shared file share. This
        // setting is what mounts it into a custom container, and without it
        // /home is ephemeral — which silently makes the entrypoint's boot
        // reports and pre-deploy dumps vanish with the instance.
        // -------------------------------------------------------------------
        { name: 'WEBSITES_ENABLE_APP_SERVICE_STORAGE', value: 'true' }
        { name: 'WEBSITES_CONTAINER_START_TIME_LIMIT', value: string(containerStartTimeLimit) }
        // Which port the platform sends traffic to. nginx listens on 80; without
        // this App Service probes 8080 first and the first request after every
        // restart pays a failed-probe delay.
        { name: 'WEBSITES_PORT', value: '80' }

        { name: 'DRUPAL_DB_HOST', value: mysqlHost }
        { name: 'DRUPAL_DB_PORT', value: '3306' }
        { name: 'DRUPAL_DB_NAME', value: mysqlDatabase }
        { name: 'DRUPAL_DB_USER', value: mysqlUser }
        { name: 'DRUPAL_DB_PASSWORD', value: '@Microsoft.KeyVault(SecretUri=${mysqlPasswordSecretUri})' }
        { name: 'DRUPAL_DB_DRIVER', value: 'mysql' }
        { name: 'DRUPAL_DB_COLLATION', value: mysqlCollation }
        { name: 'DRUPAL_DB_ISOLATION_LEVEL', value: 'READ COMMITTED' }
        { name: 'DRUPAL_DB_SSL_MODE', value: 'verify' }
        { name: 'DRUPAL_HASH_SALT', value: '@Microsoft.KeyVault(SecretUri=${hashSaltSecretUri})' }
        { name: 'DRUPAL_TRUSTED_HOSTS', value: trustedHosts }
        { name: 'DRUPAL_FILE_PRIVATE_PATH', value: '/var/www/html/private' }
        { name: 'DRUPAL_ENVIRONMENT', value: environmentName }
        // Both on /home, which persists across restarts and deploys. On Container
        // Apps these go to a mounted Azure Files share instead; the entrypoint
        // takes the paths from the environment either way.
        { name: 'DRUPAL_BACKUP_DIR', value: '/home/deploy-backups' }
        { name: 'DRUPAL_BOOT_RESULT', value: '/home/boot-result.json' }
      ]

      // -------------------------------------------------------------------
      // Azure Files mounts for the two Drupal file directories.
      //
      // /home would technically hold them, and that is the usual advice. Do not:
      // /home is backed by a share sized to the plan and shared with logs,
      // deployment artifacts and Kudu's own state, and Drupal's public files
      // directory grows without bound. Separate shares also mean a quota can be
      // raised for uploads without touching anything operational.
      // -------------------------------------------------------------------
      azureStorageAccounts: {
        'public-files': {
          type: 'AzureFiles'
          accountName: storageAccountName
          shareName: publicShareName
          accessKey: storageAccountKey
          mountPath: '/var/www/html/web/sites/default/files'
        }
        'private-files': {
          type: 'AzureFiles'
          accountName: storageAccountName
          shareName: privateShareName
          accessKey: storageAccountKey
          mountPath: '/var/www/html/private'
        }
      }
    }
  }
}

// Ship the container's stdout/stderr to Log Analytics. Without this the only
// place to read them is Kudu's rolling file, which is lost when the instance is
// replaced — so the logs from the deploy that broke something are gone by the
// time anyone looks.
resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: app
  name: 'to-log-analytics'
  properties: {
    workspaceId: logWorkspaceId
    logs: [
      { category: 'AppServiceConsoleLogs', enabled: true }
      { category: 'AppServiceHTTPLogs', enabled: true }
      { category: 'AppServicePlatformLogs', enabled: true }
    ]
  }
}

output appName string = app.name
output defaultHostName string = app.properties.defaultHostName
output scmHostName string = 'https://${appName}.scm.azurewebsites.net'
output appId string = app.id
output possibleOutboundIps string = app.properties.possibleOutboundIpAddresses
// The principal a client_id-less managed-identity token belongs to. The email
// Logic App pins its `sub` claim to this.
output systemAssignedPrincipalId string = app.identity.principalId
