// ---------------------------------------------------------------------------
// User-assigned managed identity for the Container App, plus its role grants.
// ---------------------------------------------------------------------------
// WHY USER-ASSIGNED RATHER THAN SYSTEM-ASSIGNED
//
// A system-assigned identity does not exist until the container app has been
// created, so its AcrPull and Key Vault grants cannot be made until after the
// app exists. But the app needs those grants to pull its image and resolve its
// secrets *at creation time*. The result is a deployment that always fails the
// first time and succeeds on the second run — which is easy to mistake for
// "Azure is eventually consistent" and hard to distinguish from a real failure.
//
// A user-assigned identity is an independent resource. It can be created and
// granted before anything consumes it, so the first deployment works.
// ---------------------------------------------------------------------------
param location string
param identityName string
param acrId string
param keyVaultId string

resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
}

// Well-known built-in role definition IDs. Referenced by GUID because the names
// are not resolvable from Bicep.
var acrPullRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
var kvSecretsUserRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')

resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' existing = {
  name: last(split(acrId, '/'))
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: last(split(keyVaultId, '/'))
}

resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: acr
  // Deterministic name, so re-running the deployment updates the same
  // assignment instead of failing with RoleAssignmentExists.
  name: guid(acr.id, uami.id, acrPullRoleId)
  properties: {
    roleDefinitionId: acrPullRoleId
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource kvSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, uami.id, kvSecretsUserRoleId)
  properties: {
    roleDefinitionId: kvSecretsUserRoleId
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

output identityId string = uami.id
output principalId string = uami.properties.principalId
output clientId string = uami.properties.clientId
// Consumers depend on this to order themselves after the grants, so the app is
// never created before it is allowed to pull its own image.
output grantsReady bool = !empty(acrPull.id) && !empty(kvSecretsUser.id)
