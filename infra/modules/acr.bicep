// ---------------------------------------------------------------------------
// Azure Container Registry.
// ---------------------------------------------------------------------------
param location string
param acrName string

@allowed(['Basic', 'Standard', 'Premium'])
param sku string = 'Basic'

resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: acrName
  location: location
  sku: {
    name: sku
  }
  properties: {
    // ---------------------------------------------------------------------
    // The admin account is OFF.
    //
    // It was enabled so the Container App could pull with a username and
    // password stored as an app secret. That is a single shared credential with
    // push rights as well as pull, it appears in the container app's secret
    // list, it cannot be scoped or attributed to a caller, and it has to be
    // rotated by hand. The managed identity in identity.bicep replaces it with
    // an AcrPull-only grant that Azure rotates itself.
    //
    // If you re-enable this, the app stops using the identity path and starts
    // depending on a secret that nothing renews.
    // ---------------------------------------------------------------------
    adminUserEnabled: false

    // Deleting a manifest is how you actually reclaim space; without this a
    // deleted tag leaves the layers behind and Basic's 10 GB fills up after a
    // few hundred revisions.
    policies: {
      retentionPolicy: sku == 'Premium' ? { status: 'enabled', days: 30 } : null
    }
  }
}

output loginServer string = acr.properties.loginServer
output acrId string = acr.id
output acrName string = acr.name
