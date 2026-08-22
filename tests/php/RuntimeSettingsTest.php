<?php

declare(strict_types=1);

namespace Drupal\Tests\Aca;

/**
 * Proxy handling, file paths and the settings whose absence is a production
 * incident rather than a misconfiguration.
 */
final class RuntimeSettingsTest extends SettingsOverlayTestCase {

  public function testReverseProxyTrustsTheRequestingProxyOnly(): void {
    [$settings] = $this->loadOverlay([], ['REMOTE_ADDR' => '100.64.3.9']);
    $this->assertTrue($settings['reverse_proxy']);
    $this->assertSame(['100.64.3.9'], $settings['reverse_proxy_addresses']);
  }

  public function testReverseProxyListNeverContainsAnEmptyEntry(): void {
    // The previous implementation was [$_SERVER['REMOTE_ADDR'] ?? ''], which on
    // CLI (drush, the entrypoint) puts an empty string in the list. An empty
    // entry matches nothing, so the whole mechanism is silently disabled — and
    // Drupal then generates http:// absolute URLs from a CLI context.
    [$settings] = $this->loadOverlay();
    $this->assertNotContains('', $settings['reverse_proxy_addresses']);
  }

  public function testExplicitProxyListOverridesTheRequestAddress(): void {
    [$settings] = $this->loadOverlay(
      ['DRUPAL_REVERSE_PROXY_ADDRESSES' => '10.0.0.4, 10.0.0.5'],
      ['REMOTE_ADDR' => '100.64.3.9']
    );
    $this->assertSame(['10.0.0.4', '10.0.0.5'], $settings['reverse_proxy_addresses']);
  }

  public function testPrivateFilePathIsOutsideTheDocroot(): void {
    // A private file directory inside the docroot is directly downloadable,
    // which defeats the point of it being private.
    [$settings] = $this->loadOverlay();
    $this->assertStringStartsWith('/', $settings['file_private_path']);
    $this->assertStringNotContainsString('/web/', $settings['file_private_path']);
  }

  public function testUpdatePhpIsNotFreelyAccessible(): void {
    [$settings] = $this->loadOverlay();
    $this->assertFalse($settings['update_free_access']);
  }

  public function testHashSaltIsTakenFromTheEnvironment(): void {
    [$settings] = $this->loadOverlay(['DRUPAL_HASH_SALT' => 'a-specific-salt-value']);
    $this->assertSame('a-specific-salt-value', $settings['hash_salt']);
  }

  public function testAutomatedCronIsDisabled(): void {
    // On Container Apps, request-terminated cron either never runs (scale to
    // zero, no traffic) or runs on an arbitrary replica that may be scaled in
    // mid-run. A scheduled Container Apps Job owns cron instead — see
    // infra/modules/jobs.bicep.
    [, , $config] = $this->loadOverlay();
    $this->assertSame(0, $config['automated_cron.settings']['interval']);
  }

  public function testErrorsAreHiddenByDefault(): void {
    [, , $config] = $this->loadOverlay();
    $this->assertSame('hide', $config['system.logging']['error_level']);
  }

  public function testPermissionsHardeningIsSkippedForSmbMounts(): void {
    // Azure Files SMB mounts take their mode from the mount options, so Drupal's
    // chmod-based hardening cannot succeed and leaves a permanent status-report
    // warning.
    [$settings] = $this->loadOverlay();
    $this->assertTrue($settings['skip_permissions_hardening']);
  }

}
