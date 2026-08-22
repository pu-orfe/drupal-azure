// ---------------------------------------------------------------------------
// Azure Database for MySQL Flexible Server, VNet-integrated (no public endpoint).
// ---------------------------------------------------------------------------
param location string
param mysqlName string
param adminLogin string
@secure()
param adminPassword string
param skuName string
param skuTier string = 'Burstable'
param storageSizeGB int
param vnetSubnetId string
param vnetId string
param databaseName string = 'drupal'

@description('''
Engine version, PINNED.

Without an explicit version Azure provisions whatever its current default is, so
a disaster-recovery rebuild of "the same" infrastructure can land on an engine
nothing here has been tested against — and the CLI/ARM accepted values are
specific strings, not "8.0". The gap between 8.0 and 8.4 includes changes to
default authentication and to reserved words that a Drupal site notices.

Change this deliberately, and rehearse it. See docs/database.md.
''')
param mysqlVersion string = '8.0.21'

@description('Character set for the database. utf8mb4 is required by Drupal; utf8 (3-byte) breaks on any 4-byte character, i.e. emoji.')
param charset string = 'utf8mb4'

@description('''
Collation for the database — the DEFAULT that a bare CREATE TABLE inherits.

This must match the `collation` pinned in docker/drupal/settings.azure.php.
utf8mb4_general_ci is what Drupal uses for a fresh install. A site migrated from
an existing MySQL 8 dump is often utf8mb4_unicode_ci instead; if the two
disagree, tables created by a later `drush updb` refuse to join the imported
ones with "ERROR 1267 Illegal mix of collations". Audit before deciding:
`scripts/migrate.sh --audit`.
''')
param collation string = 'utf8mb4_general_ci'

param backupRetentionDays int = 7
param geoRedundantBackup string = 'Disabled'

@description('Zone-redundant or same-zone HA. Not available on the Burstable tier.')
param highAvailability string = 'Disabled'

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
      // Passed in explicitly rather than derived by string-splitting the subnet
      // ID. The previous version used split(vnetSubnetId, '/subnets/')[0], which
      // works right up until the subnet lives in another resource group or the
      // ID casing differs, and then fails as an unresolvable resource.
      id: vnetId
    }
  }
}

resource mysql 'Microsoft.DBforMySQL/flexibleServers@2023-12-30' = {
  name: mysqlName
  location: location
  sku: {
    name: skuName
    tier: skuTier
  }
  properties: {
    version: mysqlVersion
    administratorLogin: adminLogin
    administratorLoginPassword: adminPassword
    storage: {
      storageSizeGB: storageSizeGB
      // A full MySQL disk does not degrade the site, it stops it: writes fail,
      // and because Drupal writes on nearly every request (sessions, cache,
      // watchdog) the site is down rather than read-only. 20 GB on a Burstable
      // tier fills faster than expected once watchdog and cache tables grow.
      // Auto-grow costs nothing until it triggers.
      autoGrow: 'Enabled'
      autoIoScaling: 'Enabled'
    }
    network: {
      delegatedSubnetResourceId: vnetSubnetId
      privateDnsZoneResourceId: privateDnsZone.id
      publicNetworkAccess: 'Disabled'
    }
    backup: {
      backupRetentionDays: backupRetentionDays
      geoRedundantBackup: geoRedundantBackup
    }
    highAvailability: {
      mode: highAvailability
    }
  }
  dependsOn: [dnsVnetLink]
}

resource drupalDb 'Microsoft.DBforMySQL/flexibleServers/databases@2023-12-30' = {
  parent: mysql
  name: databaseName
  properties: {
    charset: charset
    collation: collation
  }
}

// ---------------------------------------------------------------------------
// Server parameters.
//
// Set as resources rather than left at the Azure defaults, because three of the
// defaults are wrong for Drupal in ways that only appear under load or during a
// migration.
// ---------------------------------------------------------------------------

// Keep TLS mandatory. A great many Azure + Drupal writeups tell you to turn this
// off to "fix" a connection error; that removes transport encryption for every
// client of the server rather than fixing the client's CA configuration. The
// image trusts Azure's chain out of the box — see settings.azure.php.
resource requireSecureTransport 'Microsoft.DBforMySQL/flexibleServers/configurations@2023-12-30' = {
  parent: mysql
  name: 'require_secure_transport'
  properties: {
    value: 'ON'
    source: 'user-override'
  }
  dependsOn: [drupalDb]
}

// Drupal's cache and config tables hold rows well past the 4 MB default, and
// mysqldump/restore of a real site exceeds it easily. The failure is "MySQL
// server has gone away" mid-import, which reads as a network problem.
resource maxAllowedPacket 'Microsoft.DBforMySQL/flexibleServers/configurations@2023-12-30' = {
  parent: mysql
  name: 'max_allowed_packet'
  properties: {
    value: '536870912'
    source: 'user-override'
  }
  dependsOn: [requireSecureTransport]
}

// MySQL 8's default sql_mode includes ONLY_FULL_GROUP_BY, which several
// long-standing contrib modules' Views queries violate. Drupal core's own
// requirements check flags it. Removing just that flag keeps every other strict
// check in place, rather than the usual advice of emptying sql_mode entirely.
resource sqlMode 'Microsoft.DBforMySQL/flexibleServers/configurations@2023-12-30' = {
  parent: mysql
  name: 'sql_mode'
  properties: {
    value: 'STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION'
    source: 'user-override'
  }
  dependsOn: [maxAllowedPacket]
}

output fqdn string = mysql.properties.fullyQualifiedDomainName
output mysqlId string = mysql.id
output databaseName string = drupalDb.name
output collation string = collation
