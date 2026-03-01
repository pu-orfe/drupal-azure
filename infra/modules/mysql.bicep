// Azure Database for MySQL Flexible Server (VNet-integrated)
param location string
param mysqlName string
param adminLogin string
@secure()
param adminPassword string
param skuName string
param storageSizeGB int
param vnetSubnetId string

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: '${mysqlName}.private.mysql.database.azure.com'
  location: 'global'
}

resource dnsVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: '${mysqlName}-vnet-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: split(vnetSubnetId, '/subnets/')[0]
    }
  }
}

resource mysql 'Microsoft.DBforMySQL/flexibleServers@2023-06-30' = {
  name: mysqlName
  location: location
  sku: {
    name: skuName
    tier: 'Burstable'
  }
  properties: {
    version: '8.0.21'
    administratorLogin: adminLogin
    administratorLoginPassword: adminPassword
    storage: {
      storageSizeGB: storageSizeGB
    }
    network: {
      delegatedSubnetResourceId: vnetSubnetId
      privateDnsZoneResourceId: privateDnsZone.id
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
  }
  dependsOn: [dnsVnetLink]
}

// Create the drupal database
resource drupalDb 'Microsoft.DBforMySQL/flexibleServers/databases@2023-06-30' = {
  parent: mysql
  name: 'drupal'
  properties: {
    charset: 'utf8mb4'
    collation: 'utf8mb4_general_ci'
  }
}

output fqdn string = mysql.properties.fullyQualifiedDomainName
output mysqlId string = mysql.id
