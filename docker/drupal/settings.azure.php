<?php

/**
 * @file
 * Azure Container Apps settings overlay for Drupal.
 *
 * Included from web/sites/default/settings.php, which is tracked in git — so
 * what production runs can be read from the repository. Everything
 * environment-specific arrives as an environment variable injected by the
 * Container App (see infra/modules/aca.bicep).
 *
 * Every value here that is not obvious carries the reason it is set. Several of
 * them look like tuning and are not.
 */

// ---------------------------------------------------------------------------
// Secrets: fail closed.
// ---------------------------------------------------------------------------
// An earlier version of this file read
//
//   'password' => getenv('DRUPAL_DB_PASSWORD') ?: '',
//
// and set the hash salt only `if ($salt = getenv(...))`. Both are silent
// failures, and the hash salt one is the dangerous half: with no salt Drupal
// falls back to a value derived from the site path, which is identical on every
// deployment of this template. Drupal derives CSRF tokens and one-time login
// links from the salt, so a predictable salt is a route to forging them without
// needing any foothold.
//
// A missing credential must stop the request, loudly, at boot — not produce a
// site that appears to work and is quietly forgeable. Placeholder defaults are
// worse still: a CHANGEME default that nothing forces you to replace becomes the
// production credential, and then it is published in the repository.
/**
 * An UNRESOLVED managed-secret reference must be rejected too, not just an empty
 * value.
 *
 * When the platform cannot resolve a Key Vault reference — a lost
 * managed-identity grant, a deleted secret version, a vault firewall change —
 * the container does not receive an empty string. It receives the LITERAL
 * reference text, "@Microsoft.KeyVault(SecretUri=...)": a plausible-looking
 * eighty-character value that passes every emptiness check.
 *
 * Used as a database password it fails authentication while looking entirely
 * reasonable, and surfaces as "access denied for user" — pointing at the
 * credential rather than at the resolution. Used as the hash salt it silently
 * BECOMES the salt: a value identical across every deployment sharing that vault
 * name, which then changes without warning the moment resolution starts working
 * again, invalidating every session and every reset link.
 *
 * A length check is not merely insufficient here, it actively reassures — the
 * reference text is longer than most real secrets.
 */
$aca_is_unresolved_reference = static function ($value): bool {
  return is_string($value) && str_starts_with($value, '@Microsoft.KeyVault(');
};

$aca_require_env = function (string $name) use ($aca_is_unresolved_reference): string {
  $value = getenv($name);
  if ($aca_is_unresolved_reference($value)) {
    error_log(
      "FATAL: {$name} is an UNRESOLVED Key Vault reference. The container is holding the "
      . 'reference text, not the secret. Check that the app identity still has '
      . '"Key Vault Secrets User" on the vault and that the secret exists. See docs/secrets.md.'
    );
    if (PHP_SAPI !== 'cli') {
      http_response_code(500);
      print "Configuration error. See the container logs.\n";
    }
    exit(1);
  }
  if ($value === FALSE || $value === '') {
    // Container Apps captures stderr into Log Analytics, so this is findable.
    error_log("FATAL: required environment variable {$name} is not set. See docs/secrets.md.");
    if (PHP_SAPI !== 'cli') {
      http_response_code(500);
      // Deliberately does not name the variable in the response body — the
      // detail belongs in the log; a configuration error page that enumerates
      // its own missing settings is a reconnaissance aid.
      print "Configuration error. See the container logs.\n";
    }
    // exit(1), not exit("message"). Passing a STRING to exit prints it and exits
    // with status ZERO, so a fatal misconfiguration reports as a successful run
    // — which matters because docker-entrypoint.sh and the deploy workflow both
    // branch on drush's exit code.
    exit(1);
  }
  return $value;
};

$settings['hash_salt'] = $aca_require_env('DRUPAL_HASH_SALT');

// ---------------------------------------------------------------------------
// Database.
// ---------------------------------------------------------------------------
$databases['default']['default'] = [
  'driver'   => getenv('DRUPAL_DB_DRIVER') ?: 'mysql',
  'host'     => $aca_require_env('DRUPAL_DB_HOST'),
  'port'     => getenv('DRUPAL_DB_PORT') ?: '3306',
  'database' => $aca_require_env('DRUPAL_DB_NAME'),
  'username' => $aca_require_env('DRUPAL_DB_USER'),
  'password' => $aca_require_env('DRUPAL_DB_PASSWORD'),
  'prefix'   => getenv('DRUPAL_DB_PREFIX') ?: '',

  // -------------------------------------------------------------------------
  // Pinning the connection collation is not cosmetic. The mechanism is narrower
  // than it looks, and getting it wrong produces a failure that appears months
  // after the mistake:
  //
  //   * Drupal's schema layer always emits `DEFAULT CHARACTER SET utf8mb4` for a
  //     new table, and appends `COLLATE <value>` ONLY when this key is set.
  //   * A CREATE TABLE that names a CHARACTER SET but no COLLATE takes the
  //     CHARACTER SET's default collation — NOT the database's. On MySQL 8 that
  //     is utf8mb4_0900_ai_ci. This is the part that catches people out:
  //     `ALTER DATABASE ... COLLATE utf8mb4_unicode_ci`, and even
  //     `--collation-server=utf8mb4_unicode_ci`, do NOT change it, because the
  //     charset default wins over both. Nor does setting the session collation.
  //   * Joining a utf8mb4_unicode_ci table to a utf8mb4_0900_ai_ci one fails
  //     outright: "ERROR 1267 Illegal mix of collations ... for operation '='".
  //   * So the risk is not literal comparisons (MySQL coerces those to the
  //     column's collation and they work). It is that tables created LATER — by
  //     a `drush updb` after a module update — arrive on the charset default and
  //     then refuse to join everything that came before.
  //
  // Measured, not theorised: loading a production dump into mysql:8.0.46
  // reproduced it. Three tables whose CREATE TABLE declared CHARSET=utf8mb4 with
  // no COLLATE landed on utf8mb4_0900_ai_ci while the other 190 stayed
  // utf8mb4_unicode_ci — with --collation-server set to unicode_ci throughout.
  //
  // Setting this key is therefore the only thing that fixes it, which is why
  // scripts/test.sh --integration asserts that every table Drupal created really
  // did get it.
  //
  // Drupal's schema layer appends `COLLATE <this value>` to CREATE TABLE only
  // when a collation is set here (mysql/src/Driver/Database/mysql/Schema.php),
  // which is what makes this the correct place to fix it rather than the server
  // parameter.
  //
  // Set this to whatever the EXISTING data uses, and make the Bicep database
  // default match (infra/modules/mysql.bicep). utf8mb4_general_ci is Drupal's
  // own default for a fresh install. A site migrated from a MySQL 8 dump is
  // frequently utf8mb4_unicode_ci or utf8mb4_0900_ai_ci instead — check before
  // assuming, with scripts/migrate.sh --audit.
  'collation' => getenv('DRUPAL_DB_COLLATION') ?: 'utf8mb4_general_ci',

  // Drupal recommends READ COMMITTED and flags its absence on the status
  // report. MySQL's default is REPEATABLE READ, under which InnoDB takes gap
  // locks on range scans — which turns ordinary concurrent writes into lock
  // waits and deadlocks. That matters more here than on a single-instance host:
  // Container Apps runs several replicas writing concurrently by design.
  //
  // Drupal issues SET SESSION per connection, so this changes only our sessions;
  // the server default is untouched and nothing else sharing the server is
  // affected.
  'isolation_level' => getenv('DRUPAL_DB_ISOLATION_LEVEL') ?: 'READ COMMITTED',

  // -------------------------------------------------------------------------
  // TLS. Azure MySQL Flexible Server has require_secure_transport ON by
  // default and it should stay on — the connection crosses a VNet.
  //
  // The previous version of this file paired MYSQL_ATTR_SSL_CA with
  // MYSQL_ATTR_SSL_VERIFY_SERVER_CERT => FALSE, which is self-cancelling: it
  // encrypts but accepts any certificate, so it stops a passive listener and
  // not an active one. Azure's chain roots in DigiCert Global Root CA, which is
  // in the image's ca-certificates bundle, so verification costs nothing.
  //
  // DRUPAL_DB_SSL_MODE=off exists for the local docker-compose MariaDB only.
  'pdo' => (function (): array {
    $mode = getenv('DRUPAL_DB_SSL_MODE') ?: 'verify';
    if ($mode === 'off') {
      return [];
    }
    $ca = getenv('DRUPAL_DB_SSL_CA') ?: '/etc/ssl/certs/ca-certificates.crt';
    // PHP 8.5 deprecated the PDO::MYSQL_* constants in favour of Pdo\Mysql::*.
    // Resolving both keeps this file working on the PHP the image pins today and
    // on the one it will be bumped to, without a deprecation notice on every
    // request in between.
    $ca_attr = defined('Pdo\\Mysql::ATTR_SSL_CA')
      ? \Pdo\Mysql::ATTR_SSL_CA
      : \PDO::MYSQL_ATTR_SSL_CA;
    $verify_attr = defined('Pdo\\Mysql::ATTR_SSL_VERIFY_SERVER_CERT')
      ? \Pdo\Mysql::ATTR_SSL_VERIFY_SERVER_CERT
      : \PDO::MYSQL_ATTR_SSL_VERIFY_SERVER_CERT;
    return [
      $ca_attr => $ca,
      $verify_attr => ($mode === 'verify'),
    ];
  })(),
];

// ---------------------------------------------------------------------------
// File paths.
// ---------------------------------------------------------------------------
// Both are Azure Files (SMB) mounts; see infra/modules/aca.bicep for the mount
// paths, which must agree with these.
$settings['file_public_path']  = getenv('DRUPAL_FILE_PUBLIC_PATH') ?: 'sites/default/files';
$settings['file_private_path'] = getenv('DRUPAL_FILE_PRIVATE_PATH') ?: '/var/www/html/private';

// Drupal writes aggregated CSS/JS and image derivatives under the public path.
// On SMB every one of those is a network round trip, so keeping the assets path
// explicit (Drupal 10.1+) documents where that cost lands and gives you one
// place to move it if you later front the share with a CDN.
$settings['file_assets_path'] = $settings['file_public_path'];

$settings['file_chmod_directory'] = 0775;
$settings['file_chmod_file'] = 0664;

// Azure Files SMB shares are mounted with a fixed uid/gid/mode from the mount
// options; chmod on them is a no-op that returns success or fails outright
// depending on the mount. Drupal's install-time permission hardening tries to
// chmod the site directory and reports a scary, permanent warning on the status
// report when it cannot. The directory's permissions come from the image and the
// mount, which is the correct place for them in an immutable deployment.
$settings['skip_permissions_hardening'] = TRUE;

// Relative to the web root, so this is /var/www/html/config/sync — inside the
// image, therefore immutable and versioned. docker-entrypoint.sh runs
// `drush config:import` from it on every new image.
$settings['config_sync_directory'] = '../config/sync';

// ---------------------------------------------------------------------------
// Trusted hosts.
// ---------------------------------------------------------------------------
// Built from a plain comma-separated host list rather than hand-written regex,
// because hand-written trusted_host_patterns are wrong in both directions: an
// unescaped dot in '^app.azurecontainerapps.io$' matches any character, and a
// forgotten anchor matches any host containing the string.
//
// The Container Apps default domain is always allowed, because that FQDN is how
// health probes, the deploy smoke test and `az containerapp exec` reach the
// site — losing it means a custom-domain cutover silently breaks the deploy
// pipeline. Custom domains come from DRUPAL_TRUSTED_HOSTS.
//
// Note what is NOT here: no wildcard, and no fallback to $_SERVER['HTTP_HOST'].
// An empty pattern list makes Drupal accept every host, so a misconfigured
// variable must produce a closed door, not an open one.
$aca_hosts = array_filter(array_map('trim', explode(',', getenv('DRUPAL_TRUSTED_HOSTS') ?: '')));
$aca_hosts[] = '*.azurecontainerapps.io';
$aca_hosts[] = 'localhost';
$aca_hosts[] = '127.0.0.1';

$settings['trusted_host_patterns'] = array_values(array_unique(array_map(
  static function (string $host): string {
    // Escape everything, then re-enable `*` as a wildcard. Doing it the other
    // way round (str_replace on '.' and '*') breaks on any host containing a
    // regex metacharacter.
    return '^' . str_replace('\*', '.*', preg_quote($host, '/')) . '$';
  },
  $aca_hosts
)));

// ---------------------------------------------------------------------------
// Reverse proxy.
// ---------------------------------------------------------------------------
// The Container Apps ingress terminates TLS and forwards over HTTP. Without
// reverse_proxy trust Drupal ignores X-Forwarded-*, so it sees every request as
// coming from the ingress on plain HTTP: absolute URLs come out as http://,
// and flood control / rate limiting sees one client IP for all traffic.
//
// The ingress has no stable IP the container can hard-code, so the trusted
// address is whichever proxy fronted THIS request — its address is REMOTE_ADDR
// from inside the container. DRUPAL_REVERSE_PROXY_ADDRESSES overrides with an
// explicit allow-list where one is known.
//
// The previous version used `[$_SERVER['REMOTE_ADDR'] ?? '']`, which puts an
// empty string in the list when REMOTE_ADDR is unset (CLI, drush) — an entry
// that matches nothing and quietly disables the whole mechanism.
$settings['reverse_proxy'] = TRUE;
$aca_proxies = array_filter(array_map('trim', explode(',', getenv('DRUPAL_REVERSE_PROXY_ADDRESSES') ?: '')));
if (!$aca_proxies && !empty($_SERVER['REMOTE_ADDR'])) {
  $aca_proxies = [$_SERVER['REMOTE_ADDR']];
}
$settings['reverse_proxy_addresses'] = array_values($aca_proxies);

// Normalise the HTTPS state that the ingress stripped. nginx already passes
// HTTPS through as a FastCGI param, but drush and any PHP entered outside nginx
// get nothing, and code that reads $_SERVER directly (contrib does) needs this.
if (PHP_SAPI !== 'cli') {
  if (($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '') === 'https' || (getenv('DRUPAL_FORCE_HTTPS') ?: '1') === '1') {
    $_SERVER['HTTPS'] = 'on';
    $_SERVER['SERVER_PORT'] = 443;
  }
}

// ---------------------------------------------------------------------------
// Sessions.
// ---------------------------------------------------------------------------
// Guarded: PHP refuses to change session ini settings once a session has
// started or headers have gone out, and it reports the refusal as a warning. In
// a normal request neither has happened yet, but drush, a custom PHP entry point
// and the test harness all reach this file with output already flushed — and an
// unguarded ini_set turns every one of those into log noise that looks like a
// configuration fault.
$aca_session_ini = static function (string $key, string $value): void {
  if (session_status() === PHP_SESSION_NONE && !headers_sent()) {
    ini_set($key, $value);
  }
};

// Secure by default; only a deployment that genuinely serves plain HTTP (local
// docker-compose) sets this to 0.
$aca_session_ini('session.cookie_secure', getenv('DRUPAL_SESSION_COOKIE_SECURE') ?: '1');
// Lax is the right default for a normal site. SameSite=None requires Secure
// since Chrome 80, and pairing None with a non-secure cookie makes modern
// browsers drop the session silently — which reads as "login is broken" with
// nothing in any log. Only set None if the site is genuinely embedded
// cross-site in an iframe.
$aca_session_ini('session.cookie_samesite', getenv('DRUPAL_SESSION_COOKIE_SAMESITE') ?: 'Lax');
if ($aca_cookie_domain = getenv('DRUPAL_SESSION_COOKIE_DOMAIN')) {
  $aca_session_ini('session.cookie_domain', $aca_cookie_domain);
}

// ---------------------------------------------------------------------------
// General Drupal settings.
// ---------------------------------------------------------------------------
// update.php must not be reachable without authenticating. It is FALSE by
// default in core's settings.php, but this file is the authority for this
// deployment and the value is too important to leave implied.
$settings['update_free_access'] = FALSE;

// Drupal 11 enables the state cache by default and the 10.x status report
// recommends opting in early. The documented caveat is "unless there are too
// many state keys", because the whole collection is cached as one item — check
// the row count of the `state` key_value collection before assuming it is fine
// on a large site.
$settings['state_cache'] = TRUE;

// Entity updates run in the entrypoint, in a container with a startup-probe
// budget rather than an unbounded terminal. A smaller batch means more round
// trips but a bounded memory ceiling per batch, which is the failure mode that
// actually kills updb on a large site.
$settings['entity_update_batch_size'] = 50;
$settings['entity_update_backup'] = TRUE;

$settings['file_scan_ignore_directories'] = ['node_modules', 'bower_components'];

// Cron must not run on request in a scale-to-zero deployment: with no traffic
// nothing triggers it, and with traffic it lands on whichever replica served the
// request. Drive it externally instead — see docs/operations.md.
$config['automated_cron.settings']['interval'] = 0;

// Errors to the log, never to the browser. Duplicated from php.ini on purpose:
// this one governs Drupal's own error page, php.ini governs PHP's.
$config['system.logging']['error_level'] = getenv('DRUPAL_ERROR_LEVEL') ?: 'hide';

// Environment indicator, when the module is present. Cheap, and the cause of a
// non-trivial share of "I ran that on production by mistake".
if ($aca_env = getenv('DRUPAL_ENVIRONMENT')) {
  $config['environment_indicator.indicator']['name'] = $aca_env;
}

// ---------------------------------------------------------------------------
// Outbound email.
// ---------------------------------------------------------------------------
// Mail goes through a Logic App fronting the Office 365 connector, called with
// this container's managed identity — so there is no SMTP password, no API key,
// and no tenant-wide Mail.Send grant. See docs/email.md.
//
// Configured here rather than in exported config because the endpoint URL is
// environment-specific: staging and production have different Logic Apps, and
// baking one into config/sync would make a config import point staging at
// production's mailer.
if ($aca_mail_url = getenv('AZURE_LOGIC_APP_MAIL_URL')) {
  // Reject an unresolved reference for the same reason as the secrets above: it
  // is a plausible-looking string that would be used as a URL and fail as one.
  if (!$aca_is_unresolved_reference($aca_mail_url)) {
    // NOTE: the mail plugin reads AZURE_LOGIC_APP_MAIL_URL from the environment
    // itself — there is deliberately no $config key mirroring it here. An earlier
    // draft set one, which did nothing: the value was already in the environment
    // the plugin reads, and a config key nothing consumes is worse than no key,
    // because it looks like the place to change the endpoint.
    //
    // mailsystem routes Drupal's mail through the plugin. Both keys are needed:
    // 'sender' chooses who delivers, 'formatter' chooses who builds the body, and
    // setting only the first leaves core's formatter producing a body the plugin
    // then re-wraps.
    $config['mailsystem.settings']['defaults']['sender'] = 'logic_app_mailer';
    $config['mailsystem.settings']['defaults']['formatter'] = 'logic_app_mailer';
  }
  else {
    error_log(
      'WARNING: AZURE_LOGIC_APP_MAIL_URL is an unresolved Key Vault reference. '
      . 'Mail is NOT configured; Drupal will fall back to PHP mail(), which on a '
      . 'container with no MTA silently discards every message.'
    );
  }
}
// Deliberately no `else`. An unset variable means email was not provisioned —
// a legitimate state for a review environment — and Drupal falls back to its
// default mail system. Worth knowing that on a container with no MTA that
// default accepts every message and delivers none, so a site that should be
// sending mail must have this set. `setup-email.sh --status` checks it.

// ---------------------------------------------------------------------------
// Local overrides, last so they win.
// ---------------------------------------------------------------------------
if (file_exists($app_root . '/' . $site_path . '/settings.local.php')) {
  include $app_root . '/' . $site_path . '/settings.local.php';
}
