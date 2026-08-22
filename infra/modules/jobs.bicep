// ---------------------------------------------------------------------------
// Container Apps Jobs: scheduled Drupal cron, and an on-demand drush runner.
// ---------------------------------------------------------------------------
// WHY JOBS RATHER THAN DRUPAL'S OWN CRON
//
// Drupal's automated_cron runs cron at the end of a web request. On a single
// always-on host that is fine. On Container Apps it is not:
//
//   * With minReplicas 0 and no traffic, nothing ever triggers it. Search
//     indexing, queue processing, log pruning and update checks simply stop —
//     silently, because nothing reports a cron that never ran.
//   * With traffic, it runs on whichever replica served the request, so a long
//     cron run makes one user's page load slow and can be cut short by that
//     replica being scaled in mid-run.
//
// The usual workaround is a scheduled GitHub Action calling `/cron/<key>` over
// the internet. That puts the site's availability, the ingress allow-list and a
// long-lived cron key on the critical path for a maintenance task that has no
// business being reachable from outside.
//
// A Container Apps Job runs the same image, with the same secrets and the same
// file share mounts, on a schedule, inside the environment. It is a separate
// scaling unit, so a 20-minute cron cannot affect a single web request. It also
// gets its own execution history and exit codes, which is what makes a failed
// cron visible instead of merely absent.
// ---------------------------------------------------------------------------
param location string
param environmentId string
param jobNamePrefix string

param acrLoginServer string
param imageName string
param imageTag string
param managedIdentityId string

param mysqlHost string
param mysqlUser string
param mysqlDatabase string
param mysqlCollation string
param mysqlPasswordSecretUri string
param hashSaltSecretUri string
param trustedHosts string

param privateStorageName string
param publicStorageName string

param jobCpu string = '0.5'
param jobMemory string = '1Gi'

@description('Cron expression in UTC. Every 15 minutes matches what most Drupal sites want from automated_cron.')
param cronExpression string = '*/15 * * * *'

@description('''
Hard timeout for a cron run, in seconds.

Without it a wedged queue worker holds a replica indefinitely and the next
scheduled run stacks on top of it. 1800s is generous for cron and short enough
that a stuck run is visible within the hour.
''')
param cronTimeoutSeconds int = 1800

var commonEnv = [
  { name: 'DRUPAL_DB_HOST', value: mysqlHost }
  { name: 'DRUPAL_DB_PORT', value: '3306' }
  { name: 'DRUPAL_DB_NAME', value: mysqlDatabase }
  { name: 'DRUPAL_DB_USER', value: mysqlUser }
  { name: 'DRUPAL_DB_PASSWORD', secretRef: 'mysql-password' }
  { name: 'DRUPAL_DB_COLLATION', value: mysqlCollation }
  { name: 'DRUPAL_DB_ISOLATION_LEVEL', value: 'READ COMMITTED' }
  { name: 'DRUPAL_DB_SSL_MODE', value: 'verify' }
  { name: 'DRUPAL_HASH_SALT', secretRef: 'drupal-hash-salt' }
  { name: 'DRUPAL_TRUSTED_HOSTS', value: trustedHosts }
  { name: 'DRUPAL_FILE_PRIVATE_PATH', value: '/var/www/html/private' }
  // Critical: the job must NEVER run the deploy sequence. Two concurrent
  // `drush updb` runs — one from a starting web replica, one from a cron job —
  // is the failure this flag exists to prevent. The web container owns schema
  // changes; the job only ever consumes the schema.
  { name: 'DRUPAL_SKIP_DEPLOY_TASKS', value: '1' }
]

var commonSecrets = [
  {
    name: 'mysql-password'
    keyVaultUrl: mysqlPasswordSecretUri
    identity: managedIdentityId
  }
  {
    name: 'drupal-hash-salt'
    keyVaultUrl: hashSaltSecretUri
    identity: managedIdentityId
  }
]

var commonVolumes = [
  { name: 'public-files', storageName: publicStorageName, storageType: 'AzureFile' }
  { name: 'private-files', storageName: privateStorageName, storageType: 'AzureFile' }
]

var commonMounts = [
  { volumeName: 'public-files', mountPath: '/var/www/html/web/sites/default/files' }
  { volumeName: 'private-files', mountPath: '/var/www/html/private' }
]

// ---------------------------------------------------------------------------
// Scheduled cron
// ---------------------------------------------------------------------------
resource cronJob 'Microsoft.App/jobs@2024-03-01' = {
  name: '${jobNamePrefix}-cron'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentityId}': {}
    }
  }
  properties: {
    environmentId: environmentId
    configuration: {
      triggerType: 'Schedule'
      replicaTimeout: cronTimeoutSeconds
      // No retries. A failed Drupal cron is not usefully retryable — whatever
      // made it fail will make the retry fail too — and the next scheduled run
      // is the natural retry. Retrying here just multiplies the log noise.
      replicaRetryLimit: 0
      scheduleTriggerConfig: {
        cronExpression: cronExpression
        parallelism: 1
        // Exactly one run at a time. Drupal's cron takes its own lock, but a
        // second execution starting, failing to get the lock and exiting non-zero
        // reports as a failed cron when nothing is wrong.
        replicaCompletionCount: 1
      }
      registries: [
        {
          server: acrLoginServer
          identity: managedIdentityId
        }
      ]
      secrets: commonSecrets
    }
    template: {
      containers: [
        {
          name: 'drush-cron'
          image: '${acrLoginServer}/${imageName}:${imageTag}'
          // The image's ENTRYPOINT is the boot sequence, which ends in
          // `exec "$@"`. Overriding the command means the entrypoint still runs
          // (waiting for the database, skipping deploy tasks because of the flag
          // above) and then execs drush instead of supervisord.
          command: ['/usr/local/bin/docker-entrypoint.sh']
          args: ['vendor/bin/drush', 'cron', '--verbose']
          resources: {
            cpu: json(jobCpu)
            memory: jobMemory
          }
          env: commonEnv
          volumeMounts: commonMounts
        }
      ]
      volumes: commonVolumes
    }
  }
}

// ---------------------------------------------------------------------------
// On-demand drush runner.
//
// `az containerapp exec` opens an interactive shell into a live replica. It is
// useful for looking around and unfit for running anything that matters: it has
// no exit-code contract a script can rely on, it competes with real traffic on
// that replica's CPU, and a dropped websocket kills the command half-way — which
// for `drush updb` means a partially migrated database.
//
// This job runs the same image in its own replica with a real exit code.
// scripts/drush.sh wraps it. Command is supplied per execution:
//   az containerapp job start -n <name> -g <rg> \
//     --command "/usr/local/bin/docker-entrypoint.sh" --args "vendor/bin/drush,status"
// ---------------------------------------------------------------------------
resource drushJob 'Microsoft.App/jobs@2024-03-01' = {
  name: '${jobNamePrefix}-drush'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentityId}': {}
    }
  }
  properties: {
    environmentId: environmentId
    configuration: {
      triggerType: 'Manual'
      replicaTimeout: 3600
      replicaRetryLimit: 0
      manualTriggerConfig: {
        parallelism: 1
        replicaCompletionCount: 1
      }
      registries: [
        {
          server: acrLoginServer
          identity: managedIdentityId
        }
      ]
      secrets: commonSecrets
    }
    template: {
      containers: [
        {
          name: 'drush'
          image: '${acrLoginServer}/${imageName}:${imageTag}'
          command: ['/usr/local/bin/docker-entrypoint.sh']
          args: ['vendor/bin/drush', 'status']
          resources: {
            cpu: json(jobCpu)
            memory: jobMemory
          }
          env: commonEnv
          volumeMounts: commonMounts
        }
      ]
      volumes: commonVolumes
    }
  }
}

output cronJobName string = cronJob.name
output drushJobName string = drushJob.name
