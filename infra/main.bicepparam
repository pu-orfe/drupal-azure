using './main.bicep'

param location = 'eastus'
param baseName = 'drupal'
param environment = 'prod'
param mysqlAdminLogin = 'drupaladmin'
// Set via: az deployment sub create ... --parameters mysqlAdminPassword='<your-password>'
param mysqlAdminPassword = readEnvironmentVariable('MYSQL_ADMIN_PASSWORD', '')
param mysqlSkuName = 'Standard_B1ms'
param mysqlStorageSizeGB = 20
param appCpu = '0.5'
param appMemory = '1Gi'
param minReplicas = 0
param maxReplicas = 3
