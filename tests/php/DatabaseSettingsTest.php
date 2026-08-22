<?php

declare(strict_types=1);

namespace Drupal\Tests\Aca;

/**
 * The database connection settings that have a non-obvious failure mode.
 */
final class DatabaseSettingsTest extends SettingsOverlayTestCase {

  public function testCredentialsComeFromTheEnvironment(): void {
    [, $databases] = $this->loadOverlay([
      'DRUPAL_DB_HOST' => 'mysql-x.private.mysql.database.azure.com',
      'DRUPAL_DB_NAME' => 'sitedb',
      'DRUPAL_DB_USER' => 'admin',
      'DRUPAL_DB_PASSWORD' => 's3cret',
    ]);
    $c = $databases['default']['default'];
    $this->assertSame('mysql-x.private.mysql.database.azure.com', $c['host']);
    $this->assertSame('sitedb', $c['database']);
    $this->assertSame('admin', $c['username']);
    $this->assertSame('s3cret', $c['password']);
  }

  public function testCollationIsPinned(): void {
    // Must be set for Drupal's schema layer to append COLLATE to CREATE TABLE.
    // Unset, tables created by a later `drush updb` inherit the MySQL 8 server
    // default (utf8mb4_0900_ai_ci) and then refuse to join the existing tables
    // with "Illegal mix of collations".
    [, $databases] = $this->loadOverlay();
    $this->assertArrayHasKey('collation', $databases['default']['default']);
    $this->assertNotSame('', $databases['default']['default']['collation']);
  }

  public function testCollationIsOverridable(): void {
    // A migrated site is frequently on utf8mb4_unicode_ci, and the setting has
    // to follow the data rather than the template's default.
    [, $databases] = $this->loadOverlay(['DRUPAL_DB_COLLATION' => 'utf8mb4_unicode_ci']);
    $this->assertSame('utf8mb4_unicode_ci', $databases['default']['default']['collation']);
  }

  public function testIsolationLevelIsReadCommitted(): void {
    // Drupal recommends it and flags its absence on the status report. It
    // matters more here than on a single host: several replicas write
    // concurrently by design, and REPEATABLE READ's gap locks turn that into
    // lock waits and deadlocks.
    [, $databases] = $this->loadOverlay();
    $this->assertSame('READ COMMITTED', $databases['default']['default']['isolation_level']);
  }

  public function testTlsIsVerifiedByDefault(): void {
    [, $databases] = $this->loadOverlay();
    $pdo = $databases['default']['default']['pdo'];
    $this->assertArrayHasKey($this->sslCaAttribute(), $pdo);
    // The combination this guards against is a CA plus
    // VERIFY_SERVER_CERT => FALSE, which encrypts but accepts any certificate —
    // it stops a passive listener and not an active one, while looking secure.
    $this->assertTrue($pdo[$this->sslVerifyAttribute()]);
  }

  public function testTlsCanBeDisabledOnlyExplicitly(): void {
    [, $databases] = $this->loadOverlay(['DRUPAL_DB_SSL_MODE' => 'off']);
    $this->assertSame([], $databases['default']['default']['pdo']);
  }

  public function testEncryptWithoutVerificationIsDistinctFromVerify(): void {
    [, $databases] = $this->loadOverlay(['DRUPAL_DB_SSL_MODE' => 'on']);
    $this->assertFalse($databases['default']['default']['pdo'][$this->sslVerifyAttribute()]);
  }

}
