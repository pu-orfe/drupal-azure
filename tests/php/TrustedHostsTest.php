<?php

declare(strict_types=1);

namespace Drupal\Tests\Aca;

/**
 * The trusted-host patterns are a security control, so the interesting
 * assertions are the negative ones: which hosts are REFUSED.
 *
 * A wrong pattern here does not break the site, it opens it — Drupal uses the
 * Host header to build absolute URLs, including password-reset links, so a host
 * that passes this check can be used to send a user a working reset link
 * pointing at an attacker's domain.
 */
final class TrustedHostsTest extends SettingsOverlayTestCase {

  public function testContainerAppsDomainIsAlwaysTrusted(): void {
    // Always allowed regardless of configuration: it is how the health probes,
    // the deploy smoke test and the revision-label URLs reach the site. A
    // custom-domain cutover must not silently break the deploy pipeline.
    [$settings] = $this->loadOverlay(['DRUPAL_TRUSTED_HOSTS' => NULL]);
    $this->assertTrue($this->hostIsTrusted(
      $settings['trusted_host_patterns'],
      'app-drupal.happyfield-1a2b3c4d.eastus.azurecontainerapps.io'
    ));
  }

  public function testCustomDomainsFromTheEnvironmentAreTrusted(): void {
    [$settings] = $this->loadOverlay([
      'DRUPAL_TRUSTED_HOSTS' => 'example.edu, www.example.edu',
    ]);
    $patterns = $settings['trusted_host_patterns'];
    $this->assertTrue($this->hostIsTrusted($patterns, 'example.edu'));
    // Whitespace around a comma-separated entry must be tolerated; it is the
    // most likely thing a human typing this into a parameter gets wrong.
    $this->assertTrue($this->hostIsTrusted($patterns, 'www.example.edu'));
  }

  public function testUnlistedHostIsRefused(): void {
    [$settings] = $this->loadOverlay(['DRUPAL_TRUSTED_HOSTS' => 'example.edu']);
    $this->assertFalse($this->hostIsTrusted($settings['trusted_host_patterns'], 'evil.test'));
  }

  public function testDotsAreEscaped(): void {
    // The failure this guards: a hand-written pattern '^example.edu$' treats the
    // dot as "any character", so exampleXedu — a domain an attacker can register
    // — passes the check.
    [$settings] = $this->loadOverlay(['DRUPAL_TRUSTED_HOSTS' => 'example.edu']);
    $this->assertFalse($this->hostIsTrusted($settings['trusted_host_patterns'], 'exampleXedu'));
  }

  public function testPatternsAreAnchored(): void {
    // Without anchors, any host CONTAINING the trusted name passes:
    // example.edu.evil.test would be accepted.
    [$settings] = $this->loadOverlay(['DRUPAL_TRUSTED_HOSTS' => 'example.edu']);
    $patterns = $settings['trusted_host_patterns'];
    $this->assertFalse($this->hostIsTrusted($patterns, 'example.edu.evil.test'));
    $this->assertFalse($this->hostIsTrusted($patterns, 'notexample.edu'));
  }

  public function testWildcardMatchesSubdomainsOnly(): void {
    [$settings] = $this->loadOverlay(['DRUPAL_TRUSTED_HOSTS' => '*.example.edu']);
    $patterns = $settings['trusted_host_patterns'];
    $this->assertTrue($this->hostIsTrusted($patterns, 'www.example.edu'));
    $this->assertFalse($this->hostIsTrusted($patterns, 'example.edu.evil.test'));
  }

  public function testEmptyConfigurationDoesNotProduceAnEmptyPatternList(): void {
    // An empty trusted_host_patterns makes Drupal accept EVERY host. A
    // misconfigured variable must therefore leave a closed door, not an open
    // one — so the list is never empty.
    [$settings] = $this->loadOverlay(['DRUPAL_TRUSTED_HOSTS' => '']);
    $this->assertNotEmpty($settings['trusted_host_patterns']);
    $this->assertFalse($this->hostIsTrusted($settings['trusted_host_patterns'], 'anything.test'));
  }

  public function testNoPatternIsAnUnboundedWildcard(): void {
    [$settings] = $this->loadOverlay(['DRUPAL_TRUSTED_HOSTS' => 'example.edu']);
    foreach ($settings['trusted_host_patterns'] as $pattern) {
      $this->assertNotSame('^.*$', $pattern);
      $this->assertStringStartsWith('^', $pattern, "pattern '$pattern' is not anchored at the start");
      $this->assertStringEndsWith('$', $pattern, "pattern '$pattern' is not anchored at the end");
    }
  }

}
