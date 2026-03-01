// Azure Storage Account with SMB File Shares for Drupal
param location string
param storageName string

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageName
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource fileServices 'Microsoft.Storage/storageAccounts/fileServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
}

resource publicShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-01-01' = {
  parent: fileServices
  name: 'drupal-public'
  properties: {
    shareQuota: 10
  }
}

resource privateShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-01-01' = {
  parent: fileServices
  name: 'drupal-private'
  properties: {
    shareQuota: 5
  }
}

output accountName string = storageAccount.name
output accountKey string = storageAccount.listKeys().keys[0].value
