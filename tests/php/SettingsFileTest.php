<?php

declare(strict_types=1);

namespace Drupal\Tests\Aca;

use PHPUnit\Framework\TestCase;

/**
 * web/sites/default/settings.php must locate the overlay in both layouts.
 *
 * Production has it copied to web/sites/default/settings.azure.php by the
 * Dockerfile. Local development bind-mounts the repository over
 * /var/www/html, which SHADOWS that copy — so settings.php has to fall back to
 * docker/drupal/settings.azure.php in the checkout.
 *
 * Without the fallback the local stack silently has no database configuration:
 * `drush status` prints no database row and `drush site:install` fails with
 * "Call to a member function getInstallTasks() on null", which names neither the
 * cause nor the file. This test exists because that happened.
 */
final class SettingsFileTest extends TestCase {

  public function testRepositoryLayoutResolvesTheOverlay(): void {
    // No settings.azure.php next to settings.php in a git checkout — only the
    // canonical copy under docker/. This is the local-development case.
    $this->assertFileDoesNotExist(
      ACA_REPO_ROOT . '/web/sites/default/settings.azure.php',
      'a stray settings.azure.php in web/sites/default would mask the fallback this test covers'
    );

    [$databases, $settings] = $this->loadSettingsFile();

    $this->assertSame('db.invalid', $databases['default']['default']['host'] ?? NULL);
    $this->assertSame('a-salt', $settings['hash_salt'] ?? NULL);
    $this->assertNotEmpty($settings['trusted_host_patterns'] ?? []);
  }

  public function testSiblingOverlayWinsWhenBothExist(): void {
    // Production layout: the Dockerfile-placed copy takes precedence, so a
    // deployment is never silently served by whatever happens to be in docker/.
    $sibling = ACA_REPO_ROOT . '/web/sites/default/settings.azure.php';
    file_put_contents($sibling, "<?php\n\$settings['aca_overlay_source'] = 'sibling';\n");
    try {
      [, $settings] = $this->loadSettingsFile();
      $this->assertSame('sibling', $settings['aca_overlay_source'] ?? NULL);
    }
    finally {
      unlink($sibling);
    }
  }

  /**
   * @return array{array, array}
   */
  private function loadSettingsFile(): array {
    foreach (['DRUPAL_HASH_SALT' => 'a-salt', 'DRUPAL_DB_HOST' => 'db.invalid',
              'DRUPAL_DB_NAME' => 'd', 'DRUPAL_DB_USER' => 'u',
              'DRUPAL_DB_PASSWORD' => 'p'] as $name => $value) {
      putenv("$name=$value");
    }

    $app_root = ACA_REPO_ROOT . '/web';
    $site_path = 'sites/default';
    $databases = [];
    $settings = [];
    $config = [];

    require $app_root . '/' . $site_path . '/settings.php';

    foreach (['DRUPAL_HASH_SALT', 'DRUPAL_DB_HOST', 'DRUPAL_DB_NAME',
              'DRUPAL_DB_USER', 'DRUPAL_DB_PASSWORD'] as $name) {
      putenv($name);
    }

    return [$databases, $settings];
  }

}
