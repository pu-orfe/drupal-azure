// ---------------------------------------------------------------------------
// Container Apps environment + the Drupal container app.
// ---------------------------------------------------------------------------
param location string
param acaEnvName string
param acaAppName string
param logWorkspaceCustomerId string
@secure()
param logWorkspaceKey string
param infraSubnetId string

param acrLoginServer string
param imageName string
param imageTag string = 'latest'

param managedIdentityId string

param storageName string
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

param appCpu string
param appMemory string
param minReplicas int
param maxReplicas int
param concurrentRequests string = '50'

@description('Comma-separated custom domains Drupal should accept as a Host header. The Container Apps default domain is always allowed.')
param trustedHosts string = ''

@description('Environment label, surfaced to Drupal for the environment indicator.')
param environmentName string = 'prod'

@description('''
Ingress allow-list. Empty means open to the internet.

Each entry: { name: string, ipAddressRange: 'CIDR', action: 'Allow' }.
Container Apps requires every rule in the list to share the same action — a
mixed Allow/Deny list is rejected — so an Allow list is implicitly
"deny everything else".
''')
param ipAllowList array = []

@description('''
Seconds the startup probe will tolerate before Container Apps gives up on a
replica.

This is sized for the entrypoint, not for nginx. docker-entrypoint.sh runs
`drush updb`, `config:import` and `cache:rebuild` BEFORE starting the web
server, so on a deploy that carries schema updates nothing listens on port 80
for minutes. A default-length startup probe kills the replica part-way through a
schema update — which is how a half-migrated database happens.

Liveness and readiness only begin after the startup probe succeeds, so a
generous value here does not slow down failure detection later.
''')
param startupProbeTimeoutSeconds int = 900

// ---------------------------------------------------------------------------
// Environment
// ---------------------------------------------------------------------------
resource acaEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: acaEnvName
  location: location
  properties: {
    vnetConfiguration: {
      infrastructureSubnetId: infraSubnetId
      internal: false
    }
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logWorkspaceCustomerId
        sharedKey: logWorkspaceKey
      }
    }
    zoneRedundant: false
  }
}

// ---------------------------------------------------------------------------
// Azure Files, attached to the environment so the app can mount them.
// ---------------------------------------------------------------------------
resource publicStorage 'Microsoft.App/managedEnvironments/storages@2024-03-01' = {
  parent: acaEnv
  name: 'drupal-public'
  properties: {
    azureFile: {
      accountName: storageName
      accountKey: storageAccountKey
      shareName: publicShareName
      accessMode: 'ReadWrite'
    }
  }
}

resource privateStorage 'Microsoft.App/managedEnvironments/storages@2024-03-01' = {
  parent: acaEnv
  name: 'drupal-private'
  properties: {
    azureFile: {
      accountName: storageName
      accountKey: storageAccountKey
      shareName: privateShareName
      accessMode: 'ReadWrite'
    }
  }
}

// ---------------------------------------------------------------------------
// The app
// ---------------------------------------------------------------------------
resource app 'Microsoft.App/containerApps@2024-03-01' = {
  name: acaAppName
  location: location
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
    managedEnvironmentId: acaEnv.id
    configuration: {
      // Multiple, so a new revision can be created, health-checked and only
      // then given traffic — and so the previous revision is still there to roll
      // back to. In Single mode the old revision is deactivated the moment the
      // new one is provisioned, which means the rollback path is "rebuild and
      // redeploy" rather than "shift traffic back".
      activeRevisionsMode: 'Multiple'

      ingress: {
        external: true
        targetPort: 80
        transport: 'auto'
        allowInsecure: false
        // Bootstrap only. .github/workflows/deploy.yml pins traffic to an
        // explicit revision before it creates a new one, precisely so the new
        // revision does NOT receive traffic until it has passed a smoke test.
        // Leaving latestRevision:true in place would shift 100% of traffic onto
        // an unproven revision the instant it is created, which is what made
        // this template's "zero-downtime blue/green" claim untrue.
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
        ipSecurityRestrictions: ipAllowList
        stickySessions: {
          // Drupal keeps sessions in its own database table, so any replica can
          // serve any authenticated user. Sticky sessions would only concentrate
          // load and make a drain worse.
          affinity: 'none'
        }
      }

      // Image pull by managed identity. No registry username, no password
      // secret, nothing to rotate.
      registries: [
        {
          server: acrLoginServer
          identity: managedIdentityId
        }
      ]

      // Key Vault references, resolved at replica start with the managed
      // identity. The value is never in this template, in a parameter file, or
      // in `az containerapp show` output.
      secrets: [
        {
          name: 'mysql-password'
          keyVaultUrl: mysqlPasswordSecretUri
          identity: managedIdentityId
        }
        {
          name: 'drupal-hash-salt'
          keyVaultUrl: hashSaltSecretUri
          identity: managedIdentityId
        }
      ]
    }

    template: {
      // Give a draining replica time to finish in-flight requests. Supervisor
      // stops nginx first with SIGQUIT, then php-fpm; the default 30s can cut a
      // slow authenticated page off mid-render.
      terminationGracePeriodSeconds: 60

      containers: [
        {
          name: 'drupal'
          image: '${acrLoginServer}/${imageName}:${imageTag}'
          resources: {
            cpu: json(appCpu)
            memory: appMemory
          }
          env: [
            { name: 'DRUPAL_DB_HOST', value: mysqlHost }
            { name: 'DRUPAL_DB_PORT', value: '3306' }
            { name: 'DRUPAL_DB_NAME', value: mysqlDatabase }
            { name: 'DRUPAL_DB_USER', value: mysqlUser }
            { name: 'DRUPAL_DB_PASSWORD', secretRef: 'mysql-password' }
            { name: 'DRUPAL_DB_DRIVER', value: 'mysql' }
            // Must match infra/modules/mysql.bicep's database collation. See
            // the comment there and in settings.azure.php for what breaks if they
            // diverge.
            { name: 'DRUPAL_DB_COLLATION', value: mysqlCollation }
            { name: 'DRUPAL_DB_ISOLATION_LEVEL', value: 'READ COMMITTED' }
            { name: 'DRUPAL_DB_SSL_MODE', value: 'verify' }
            { name: 'DRUPAL_HASH_SALT', secretRef: 'drupal-hash-salt' }
            { name: 'DRUPAL_TRUSTED_HOSTS', value: trustedHosts }
            { name: 'DRUPAL_FILE_PRIVATE_PATH', value: '/var/www/html/private' }
            { name: 'DRUPAL_ENVIRONMENT', value: environmentName }
            // Pre-deploy dumps land on the private share, so they outlive the
            // replica that took them.
            { name: 'DRUPAL_BACKUP_DIR', value: '/var/www/html/private/.deploy-backups' }
          ]
          volumeMounts: [
            { volumeName: 'public-files', mountPath: '/var/www/html/web/sites/default/files' }
            { volumeName: 'private-files', mountPath: '/var/www/html/private' }
          ]
          probes: [
            {
              // Covers the entrypoint's database work. failureThreshold x
              // periodSeconds is the budget.
              type: 'Startup'
              httpGet: { path: '/nginx-health', port: 80 }
              periodSeconds: 10
              timeoutSeconds: 5
              failureThreshold: startupProbeTimeoutSeconds / 10
            }
            {
              // nginx-level, no PHP and no database. A liveness probe that hits
              // Drupal restarts every replica at once when the database blips,
              // turning a recoverable outage into a crash loop.
              type: 'Liveness'
              httpGet: { path: '/nginx-health', port: 80 }
              periodSeconds: 15
              timeoutSeconds: 5
              failureThreshold: 3
            }
            {
              // Readiness DOES go through Drupal, because "should this replica
              // receive traffic" genuinely depends on whether Drupal can serve.
              // A replica with a broken database drops out of the pool instead
              // of returning 500s.
              type: 'Readiness'
              httpGet: { path: '/', port: 80 }
              initialDelaySeconds: 5
              periodSeconds: 20
              timeoutSeconds: 10
              failureThreshold: 3
              successThreshold: 1
            }
          ]
        }
      ]

      volumes: [
        { name: 'public-files', storageName: publicStorage.name, storageType: 'AzureFile' }
        { name: 'private-files', storageName: privateStorage.name, storageType: 'AzureFile' }
      ]

      scale: {
        // minReplicas: 0 saves money and costs a cold start of tens of seconds
        // on the first request — plus, in the worst case, the full startup-probe
        // window if the boot also has deploy tasks to run. For anything
        // user-facing, set 1. See README "Scaling".
        minReplicas: minReplicas
        maxReplicas: maxReplicas
        rules: [
          {
            name: 'http-scaling'
            http: {
              metadata: {
                concurrentRequests: concurrentRequests
              }
            }
          }
        ]
      }
    }
  }
}

output fqdn string = app.properties.configuration.ingress.fqdn
output appId string = app.id
output appName string = app.name
output environmentId string = acaEnv.id
output environmentDefaultDomain string = acaEnv.properties.defaultDomain
// The address the environment egresses from. Needed to allow-list this app at
// anything outside it — the email Logic App, or another service's firewall.
output outboundIp string = acaEnv.properties.staticIp
// The principal a client_id-less managed-identity token belongs to. The email
// Logic App pins its `sub` claim to this.
output systemAssignedPrincipalId string = app.identity.principalId
