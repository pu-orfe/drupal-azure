// Azure Container Apps Environment + Drupal Container App
param location string
param acaEnvName string
param acaAppName string
param logWorkspaceId string
param logWorkspaceCustomerId string
@secure()
param logWorkspaceKey string
param infraSubnetId string
param acrLoginServer string
param acrName string
param storageName string
@secure()
param storageAccountKey string
param mysqlHost string
param mysqlUser string
@secure()
param mysqlPassword string
param mysqlDatabase string
param appCpu string
param appMemory string
param minReplicas int
param maxReplicas int

// ---------------------------------------------------------------------------
// Container Apps Environment
// ---------------------------------------------------------------------------
resource acaEnv 'Microsoft.App/managedEnvironments@2023-11-02-preview' = {
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
  }
}

// ---------------------------------------------------------------------------
// Mount Azure File Shares into the ACA Environment
// ---------------------------------------------------------------------------
resource publicStorage 'Microsoft.App/managedEnvironments/storages@2023-11-02-preview' = {
  parent: acaEnv
  name: 'drupal-public'
  properties: {
    azureFile: {
      accountName: storageName
      accountKey: storageAccountKey
      shareName: 'drupal-public'
      accessMode: 'ReadWrite'
    }
  }
}

resource privateStorage 'Microsoft.App/managedEnvironments/storages@2023-11-02-preview' = {
  parent: acaEnv
  name: 'drupal-private'
  properties: {
    azureFile: {
      accountName: storageName
      accountKey: storageAccountKey
      shareName: 'drupal-private'
      accessMode: 'ReadWrite'
    }
  }
}

// ---------------------------------------------------------------------------
// Container App
// ---------------------------------------------------------------------------
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

resource app 'Microsoft.App/containerApps@2023-11-02-preview' = {
  name: acaAppName
  location: location
  properties: {
    managedEnvironmentId: acaEnv.id
    configuration: {
      activeRevisionsMode: 'Multiple'
      ingress: {
        external: true
        targetPort: 80
        transport: 'auto'
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
      registries: [
        {
          server: acrLoginServer
          username: acr.listCredentials().username
          passwordSecretRef: 'acr-password'
        }
      ]
      secrets: [
        {
          name: 'acr-password'
          value: acr.listCredentials().passwords[0].value
        }
        {
          name: 'mysql-password'
          value: mysqlPassword
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'drupal'
          image: '${acrLoginServer}/${acaAppName}:latest'
          resources: {
            cpu: json(appCpu)
            memory: appMemory
          }
          env: [
            { name: 'DRUPAL_DB_HOST', value: mysqlHost }
            { name: 'DRUPAL_DB_NAME', value: mysqlDatabase }
            { name: 'DRUPAL_DB_USER', value: mysqlUser }
            { name: 'DRUPAL_DB_PASSWORD', secretRef: 'mysql-password' }
            { name: 'DRUPAL_DB_PORT', value: '3306' }
            { name: 'DRUPAL_DB_DRIVER', value: 'mysql' }
          ]
          volumeMounts: [
            { volumeName: 'public-files', mountPath: '/var/www/html/web/sites/default/files' }
            { volumeName: 'private-files', mountPath: '/var/www/html/private' }
          ]
        }
      ]
      volumes: [
        { name: 'public-files', storageName: 'drupal-public', storageType: 'AzureFile' }
        { name: 'private-files', storageName: 'drupal-private', storageType: 'AzureFile' }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
        rules: [
          {
            name: 'http-scaling'
            http: {
              metadata: {
                concurrentRequests: '50'
              }
            }
          }
        ]
      }
    }
  }
  dependsOn: [publicStorage, privateStorage]
}

output fqdn string = app.properties.configuration.ingress.fqdn
output appId string = app.id
