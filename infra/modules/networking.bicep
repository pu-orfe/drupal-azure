// ---------------------------------------------------------------------------
// VNet with subnets for Container Apps and MySQL Flexible Server.
// ---------------------------------------------------------------------------
param location string
param vnetName string

@description('Address space for the VNet.')
param addressPrefix string = '10.0.0.0/16'

@description('''
Which service the app subnet is delegated to. A subnet can be delegated to
exactly one service, and the delegation cannot be changed while anything is
using it.

  Microsoft.Web/serverFarms       App Service regional VNet integration
  Microsoft.App/environments      Container Apps environment
''')
@allowed(['Microsoft.Web/serverFarms', 'Microsoft.App/environments'])
param appSubnetDelegation string = 'Microsoft.Web/serverFarms'

@description('''
Subnet for the application.

Size cannot be changed later without recreating whatever is delegated to it, so
it is sized for the larger consumer:

  App Service regional integration  /27 minimum, /26 recommended
  Container Apps (Consumption)      /23 minimum
  Container Apps (workload profiles) /27 minimum

/23 satisfies all three. Container Apps in particular consumes addresses per
replica AND per revision, so a /27 that looks generous for "3 replicas" runs out
during a rolling revision swap with several revisions still draining.
''')
param appSubnetPrefix string = '10.0.0.0/23'

@description('Delegated subnet for MySQL Flexible Server. Cannot be shared with anything else.')
param dbSubnetPrefix string = '10.0.2.0/24'

var appSubnetName = 'snet-app'
var dbSubnetName = 'snet-db'

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [addressPrefix]
    }
    subnets: [
      {
        name: appSubnetName
        properties: {
          addressPrefix: appSubnetPrefix
          delegations: [
            {
              name: 'app-delegation'
              properties: {
                serviceName: appSubnetDelegation
              }
            }
          ]
          // ---------------------------------------------------------------
          // Service endpoints are what let the storage account and key vault
          // refuse the public internet while still accepting this subnet.
          //
          // Without Microsoft.Storage here, locking the storage account to the
          // VNet (see storage.bicep) breaks the Azure Files mounts and Drupal
          // loses its entire files directory — which presents as every uploaded
          // image 404ing rather than as a network error.
          // ---------------------------------------------------------------
          serviceEndpoints: [
            { service: 'Microsoft.Storage' }
            { service: 'Microsoft.KeyVault' }
          ]
        }
      }
      {
        name: dbSubnetName
        properties: {
          addressPrefix: dbSubnetPrefix
          delegations: [
            {
              name: 'mysql-delegation'
              properties: {
                serviceName: 'Microsoft.DBforMySQL/flexibleServers'
              }
            }
          ]
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output vnetName string = vnet.name
output appSubnetId string = vnet.properties.subnets[0].id
output dbSubnetId string = vnet.properties.subnets[1].id
