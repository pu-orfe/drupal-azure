// ---------------------------------------------------------------------------
// Key Vault holding the deployment's secrets.
// ---------------------------------------------------------------------------
// WHY A VAULT AT ALL, when Container Apps has its own secret store
//
// A container app secret is a value written into the app's configuration. That
// means: it is readable by anyone with Contributor on the resource group, it
// appears in `az containerapp show` output and in exported ARM templates,
// rotating it is a revision-creating configuration change, and — the part that
// bites — the deployment tooling has to *hold* the plaintext in order to write
// it, so it passes through a shell history, a CI log, or a Bicep parameter file.
//
// A Key Vault reference inverts that. The app stores a URI; the value is fetched
// at runtime with the managed identity. Rotation is `az keyvault secret set` and
// a restart, with no deployment and no commit, and the value never transits CI.
// ---------------------------------------------------------------------------
param location string
param keyVaultName string

@description('Object ID of the principal running the deployment. Granted Key Vault Secrets Officer so it can seed secrets.')
param deployerPrincipalId string = ''

@secure()
@description('MySQL administrator password. Seeded only when non-empty; an existing secret is never overwritten by a redeploy.')
param mysqlAdminPassword string = ''

@secure()
@description('Drupal hash salt. Seeded only when non-empty.')
param drupalHashSalt string = ''

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId

    // RBAC rather than the legacy access-policy model. Access policies are
    // per-vault ACLs that no other Azure resource uses, so they drift out of
    // whatever the rest of the estate manages access with, and they cannot be
    // granted before the principal exists.
    enableRbacAuthorization: true

    // Soft delete is mandatory now; purge protection is not, and is left OFF
    // deliberately. With it ON the vault name is unusable for 90 days after a
    // teardown and cannot be released early, which makes `azure-nuke.sh`
    // followed by `azure-up.sh` — the exact loop this template exists to
    // support — fail on a name collision that no one can clear.
    //
    // Turn it ON for a vault holding anything you cannot regenerate.
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enablePurgeProtection: null

    // -----------------------------------------------------------------------
    // Network access stays open, on purpose, and this is worth being explicit
    // about because locking it down looks like an obvious improvement.
    //
    // Container Apps resolves a Key Vault secret reference from the platform,
    // not from inside the replica. The request does not originate in the app
    // subnet, so a `defaultAction: Deny` vault with a VNet rule for that subnet
    // refuses it — and the failure surfaces as the revision never becoming
    // healthy, with no message naming the vault.
    //
    // What actually protects the vault is that reading a secret requires the
    // Key Vault Secrets User role. Authorisation, not network position.
    // -----------------------------------------------------------------------
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

// Let whoever is running the deployment write secrets. Without this, a fresh
// `azure-up.sh` creates a vault it cannot seed — even as subscription Owner,
// because Owner grants control-plane rights and Key Vault data-plane access is
// a separate role.
var kvSecretsOfficerRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')

resource deployerGrant 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(deployerPrincipalId)) {
  scope: vault
  name: guid(vault.id, deployerPrincipalId, kvSecretsOfficerRoleId)
  properties: {
    roleDefinitionId: kvSecretsOfficerRoleId
    principalId: deployerPrincipalId
  }
}

// -------------------------------------------------------------------------
// Seeded secrets.
//
// Conditional on a non-empty value so a redeploy that does not supply the
// password leaves the stored one alone. Writing an empty secret here would take
// the site down at the next replica start, and it is exactly what happens if the
// parameter is omitted on a second run.
// -------------------------------------------------------------------------
resource dbSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (!empty(mysqlAdminPassword)) {
  parent: vault
  name: 'mysql-admin-password'
  properties: {
    value: mysqlAdminPassword
    contentType: 'MySQL administrator password'
  }
}

resource saltSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (!empty(drupalHashSalt)) {
  parent: vault
  name: 'drupal-hash-salt'
  properties: {
    value: drupalHashSalt
    contentType: 'Drupal hash salt'
  }
}

output keyVaultId string = vault.id
output keyVaultName string = vault.name
output keyVaultUri string = vault.properties.vaultUri
// Secret URIs WITHOUT a version. Container Apps then picks up a rotated value on
// the next replica start; a versioned URI pins the app to the old value and
// makes rotation silently ineffective.
#disable-next-line outputs-should-not-contain-secrets
output mysqlPasswordSecretUri string = '${vault.properties.vaultUri}secrets/mysql-admin-password'
#disable-next-line outputs-should-not-contain-secrets
output hashSaltSecretUri string = '${vault.properties.vaultUri}secrets/drupal-hash-salt'
