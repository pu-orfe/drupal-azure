// Log Analytics workspace. Required by the Container Apps environment, and the
// only place a destroyed replica's logs survive.
param location string
param workspaceName string

@description('''
Retention. 30 days is the free allowance; beyond that it is billed per GB-month.

Worth raising for a production site: the logs you need are the ones from the
deploy that broke something three weeks ago, and Container Apps replicas keep
nothing locally.
''')
param retentionInDays int = 30

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
    features: {
      // Anything reading these logs goes through Azure RBAC on the workspace.
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

output workspaceId string = workspace.id
output workspaceCustomerId string = workspace.properties.customerId
#disable-next-line outputs-should-not-contain-secrets
output workspaceKey string = workspace.listKeys().primarySharedKey
