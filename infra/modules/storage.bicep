// ---------------------------------------------------------------------------
// Storage account with SMB file shares for Drupal's public and private files.
// ---------------------------------------------------------------------------
param location string
param storageName string
param appSubnetId string

@description('Quota (GB) for the public files share. A quota is a ceiling, not an allocation — you pay for what is used.')
param publicShareQuotaGB int = 100

@description('Quota (GB) for the private files share.')
param privateShareQuotaGB int = 100

@allowed(['Standard_LRS', 'Standard_ZRS', 'Standard_GRS'])
param sku string = 'Standard_LRS'

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  kind: 'StorageV2'
  sku: {
    name: sku
  }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true

    // Nothing in this deployment serves blobs to the public. Drupal serves its
    // own public files through the container, so an anonymously readable
    // container would only ever be an accident.
    allowBlobPublicAccess: false

    // Cannot be disabled: Container Apps mounts Azure Files with the account
    // key. This is the one credential in the stack that identity cannot replace,
    // which is why the network rules below matter more here than elsewhere.
    allowSharedKeyAccess: true

    // -------------------------------------------------------------------
    // Default deny.
    //
    // The previous version of this module set no network rules at all, so the
    // share holding every private file — on a Drupal site, typically the exact
    // documents that were made private for a reason — was reachable from the
    // internet by anyone holding the account key. The key is stored in the
    // container app's secrets and in whatever ran the deployment.
    //
    // With this, possessing the key is not enough: the caller must also be in
    // the app subnet.
    //
    // `bypass: AzureServices` is required for the Container Apps environment to
    // attach the share, and for `az storage share snapshot` from the backup
    // script to work.
    // -------------------------------------------------------------------
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      virtualNetworkRules: [
        {
          id: appSubnetId
          action: 'Allow'
        }
      ]
    }
  }
}

resource fileServices 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    // Share snapshots are the backup mechanism for the file shares
    // (scripts/azure-backup.sh). Soft delete is the recovery path for the case
    // snapshots do not cover: a deletion between snapshots.
    shareDeleteRetentionPolicy: {
      enabled: true
      days: 14
    }
    protocolSettings: {
      smb: {
        // SMB 3.1.1 with AES-256-GCM. The default permits older dialects; there
        // is no client here that needs them.
        versions: 'SMB3.1.1'
        authenticationMethods: 'NTLMv2;Kerberos'
        channelEncryption: 'AES-256-GCM'
      }
    }
  }
}

resource publicShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = {
  parent: fileServices
  name: 'drupal-public'
  properties: {
    shareQuota: publicShareQuotaGB
    enabledProtocols: 'SMB'
  }
}

resource privateShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = {
  parent: fileServices
  name: 'drupal-private'
  properties: {
    shareQuota: privateShareQuotaGB
    enabledProtocols: 'SMB'
  }
}

output accountName string = storageAccount.name
output accountId string = storageAccount.id
output publicShareName string = publicShare.name
output privateShareName string = privateShare.name
#disable-next-line outputs-should-not-contain-secrets
output accountKey string = storageAccount.listKeys().keys[0].value
