// ============================================================================
// Drupal 10 on Azure Container Apps — Full Infrastructure
// Deploy: az deployment sub create --location eastus --template-file main.bicep
// ============================================================================

targetScope = 'subscription'

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------
@description('Azure region for all resources')
param location string = 'eastus'

@description('Base name used to derive resource names')
@minLength(3)
@maxLength(16)
param baseName string = 'drupal'

@description('Environment tag (dev | staging | prod)')
@allowed(['dev', 'staging', 'prod'])
param environment string = 'prod'

@description('MySQL administrator login')
param mysqlAdminLogin string = 'drupaladmin'

@secure()
@description('MySQL administrator password')
param mysqlAdminPassword string

@description('MySQL SKU name')
param mysqlSkuName string = 'Standard_B1ms'

@description('MySQL storage size in GB')
param mysqlStorageSizeGB int = 20

@description('Container App CPU cores')
param appCpu string = '0.5'

@description('Container App memory')
param appMemory string = '1Gi'

@description('Minimum replicas (0 = scale to zero)')
param minReplicas int = 0

@description('Maximum replicas')
param maxReplicas int = 3

// ---------------------------------------------------------------------------
// Derived names
// ---------------------------------------------------------------------------
var suffix = uniqueString(subscription().subscriptionId, baseName, environment)
var rgName = 'rg-${baseName}-${environment}'
var vnetName = 'vnet-${baseName}-${suffix}'
var acrName = 'acr${baseName}${suffix}'
var storageName = 'st${baseName}${suffix}'
var mysqlName = 'mysql-${baseName}-${suffix}'
var acaEnvName = 'acaenv-${baseName}-${suffix}'
var acaAppName = 'app-${baseName}'
var logWorkspaceName = 'log-${baseName}-${suffix}'

// ---------------------------------------------------------------------------
// Resource Group
// ---------------------------------------------------------------------------
resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: rgName
  location: location
  tags: {
    project: baseName
    environment: environment
  }
}

// ---------------------------------------------------------------------------
// Module: Networking
// ---------------------------------------------------------------------------
module networking 'modules/networking.bicep' = {
  scope: rg
  name: 'networking'
  params: {
    location: location
    vnetName: vnetName
  }
}

// ---------------------------------------------------------------------------
// Module: Log Analytics (required by ACA Environment)
// ---------------------------------------------------------------------------
module logging 'modules/logging.bicep' = {
  scope: rg
  name: 'logging'
  params: {
    location: location
    workspaceName: logWorkspaceName
  }
}

// ---------------------------------------------------------------------------
// Module: Azure Container Registry
// ---------------------------------------------------------------------------
module acr 'modules/acr.bicep' = {
  scope: rg
  name: 'acr'
  params: {
    location: location
    acrName: acrName
  }
}

// ---------------------------------------------------------------------------
// Module: Azure Storage (File Shares for Drupal public/private)
// ---------------------------------------------------------------------------
module storage 'modules/storage.bicep' = {
  scope: rg
  name: 'storage'
  params: {
    location: location
    storageName: storageName
  }
}

// ---------------------------------------------------------------------------
// Module: Azure Database for MySQL Flexible Server
// ---------------------------------------------------------------------------
module mysql 'modules/mysql.bicep' = {
  scope: rg
  name: 'mysql'
  params: {
    location: location
    mysqlName: mysqlName
    adminLogin: mysqlAdminLogin
    adminPassword: mysqlAdminPassword
    skuName: mysqlSkuName
    storageSizeGB: mysqlStorageSizeGB
    vnetSubnetId: networking.outputs.dbSubnetId
  }
}

// ---------------------------------------------------------------------------
// Module: Container Apps Environment + App
// ---------------------------------------------------------------------------
module aca 'modules/aca.bicep' = {
  scope: rg
  name: 'aca'
  params: {
    location: location
    acaEnvName: acaEnvName
    acaAppName: acaAppName
    logWorkspaceId: logging.outputs.workspaceId
    logWorkspaceCustomerId: logging.outputs.workspaceCustomerId
    logWorkspaceKey: logging.outputs.workspaceKey
    infraSubnetId: networking.outputs.appSubnetId
    acrLoginServer: acr.outputs.loginServer
    acrName: acrName
    storageName: storageName
    storageAccountKey: storage.outputs.accountKey
    mysqlHost: mysql.outputs.fqdn
    mysqlUser: mysqlAdminLogin
    mysqlPassword: mysqlAdminPassword
    mysqlDatabase: 'drupal'
    appCpu: appCpu
    appMemory: appMemory
    minReplicas: minReplicas
    maxReplicas: maxReplicas
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output resourceGroupName string = rg.name
output acrLoginServer string = acr.outputs.loginServer
output containerAppFqdn string = aca.outputs.fqdn
output mysqlFqdn string = mysql.outputs.fqdn
output storageAccountName string = storage.outputs.accountName
