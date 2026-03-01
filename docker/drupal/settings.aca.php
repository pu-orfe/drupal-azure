<?php

/**
 * @file
 * Azure Container Apps settings overlay for Drupal 10.
 *
 * This file is auto-included from settings.php when running on ACA.
 * Database credentials and other secrets come from environment variables
 * injected by the Container App configuration.
 */

// Database connection via environment variables.
$databases['default']['default'] = [
  'database' => getenv('DRUPAL_DB_NAME') ?: 'drupal',
  'username' => getenv('DRUPAL_DB_USER') ?: 'drupal',
  'password' => getenv('DRUPAL_DB_PASSWORD') ?: '',
  'host'     => getenv('DRUPAL_DB_HOST') ?: 'localhost',
  'port'     => getenv('DRUPAL_DB_PORT') ?: '3306',
  'driver'   => getenv('DRUPAL_DB_DRIVER') ?: 'mysql',
  'prefix'   => '',
  'collation' => 'utf8mb4_general_ci',
  'pdo' => [
    // Azure MySQL requires SSL
    \PDO::MYSQL_ATTR_SSL_CA => '/etc/ssl/certs/ca-certificates.crt',
    \PDO::MYSQL_ATTR_SSL_VERIFY_SERVER_CERT => FALSE,
  ],
];

// Trusted host patterns — allow the ACA-assigned FQDN and custom domains.
$settings['trusted_host_patterns'] = [
  // Azure Container Apps default domain
  '^.+\.azurecontainerapps\.io$',
  // Localhost for healthchecks
  '^localhost$',
];

// File paths — these map to Azure File Share volume mounts.
$settings['file_public_path'] = 'sites/default/files';
$settings['file_private_path'] = '/var/www/html/private';

// Reverse proxy — ACA terminates TLS at the ingress.
$settings['reverse_proxy'] = TRUE;
$settings['reverse_proxy_addresses'] = [$_SERVER['REMOTE_ADDR'] ?? ''];

// Config sync directory.
$settings['config_sync_directory'] = '../config/sync';

// Hash salt from environment or fallback.
if ($hash_salt = getenv('DRUPAL_HASH_SALT')) {
  $settings['hash_salt'] = $hash_salt;
}
