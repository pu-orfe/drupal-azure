<?php

declare(strict_types=1);

namespace Drupal\Tests\Aca;

use PHPUnit\Framework\TestCase;

/**
 * Includes the real settings overlay under a controlled environment.
 *
 * The overlay reads everything through getenv() and writes into $settings,
 * $databases and $config. Including it in an isolated scope with a known
 * environment and then inspecting those arrays tests the file production
 * actually ships, rather than a reimplementation of its logic.
 */
abstract class SettingsOverlayTestCase extends TestCase {

  /**
   * Environment variables set by the current test, to be unset afterwards.
   */
  private array $applied = [];

  protected function tearDown(): void {
    foreach ($this->applied as $name) {
      putenv($name);
      unset($_ENV[$name], $_SERVER[$name]);
    }
    $this->applied = [];
    unset($_SERVER['REMOTE_ADDR'], $_SERVER['HTTP_X_FORWARDED_PROTO'], $_SERVER['HTTPS'], $_SERVER['SERVER_PORT']);
    parent::tearDown();
  }

  /**
   * The minimum environment the overlay needs to load at all.
   *
   * Anything absent from here is a variable the overlay treats as required and
   * exits on — which is itself asserted by a test.
   */
  protected function baseEnv(): array {
    return [
      'DRUPAL_HASH_SALT' => str_repeat('a', 64),
      'DRUPAL_DB_HOST' => 'mysql.example.invalid',
      'DRUPAL_DB_NAME' => 'drupal',
      'DRUPAL_DB_USER' => 'drupaladmin',
      'DRUPAL_DB_PASSWORD' => 'not-a-real-password',
    ];
  }

  /**
   * Loads the overlay and returns [$settings, $databases, $config].
   *
   * @param array $env
   *   Environment overrides merged over baseEnv(). A value of NULL removes the
   *   variable entirely, which is how the "required variable is missing" cases
   *   are expressed.
   * @param array $server
   *   $_SERVER entries to set for the duration of the include.
   */
  protected function loadOverlay(array $env = [], array $server = []): array {
    $merged = array_merge($this->baseEnv(), $env);
    foreach ($merged as $name => $value) {
      $this->applied[] = $name;
      if ($value === NULL) {
        putenv($name);
        continue;
      }
      putenv("$name=$value");
    }
    foreach ($server as $key => $value) {
      $_SERVER[$key] = $value;
    }

    // The overlay expects these to exist, as they do inside settings.php.
    $app_root = ACA_REPO_ROOT . '/web';
    $site_path = 'sites/default';
    $settings = [];
    $databases = [];
    $config = [];

    require ACA_SETTINGS_OVERLAY;

    return [$settings, $databases, $config];
  }

  /**
   * The PDO attribute keys, resolved the same way the overlay resolves them.
   *
   * PHP 8.5 deprecated PDO::MYSQL_* in favour of Pdo\Mysql::*; the overlay
   * handles both, so the test must ask for whichever one is in play rather than
   * hard-coding the old name and emitting the very deprecation it is testing
   * around.
   */
  protected function sslCaAttribute(): int {
    return defined('Pdo\\Mysql::ATTR_SSL_CA') ? \Pdo\Mysql::ATTR_SSL_CA : \PDO::MYSQL_ATTR_SSL_CA;
  }

  protected function sslVerifyAttribute(): int {
    return defined('Pdo\\Mysql::ATTR_SSL_VERIFY_SERVER_CERT')
      ? \Pdo\Mysql::ATTR_SSL_VERIFY_SERVER_CERT
      : \PDO::MYSQL_ATTR_SSL_VERIFY_SERVER_CERT;
  }

  /**
   * Asserts a host is accepted by the generated trusted_host_patterns.
   */
  protected function hostIsTrusted(array $patterns, string $host): bool {
    foreach ($patterns as $pattern) {
      if (preg_match('/' . $pattern . '/i', $host)) {
        return TRUE;
      }
    }
    return FALSE;
  }

}
