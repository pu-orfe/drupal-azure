<?php

declare(strict_types=1);

namespace Drupal\Tests\Aca;

use PHPUnit\Framework\TestCase;

/**
 * A missing credential must stop the request, not produce a site that appears to
 * work.
 *
 * Run in a subprocess because the overlay calls exit() — which is the behaviour
 * under test. The previous implementation instead did
 * `getenv('DRUPAL_DB_PASSWORD') ?: ''` and set the hash salt only when present,
 * so a missing hash salt gave every deployment of this template the same
 * predictable fallback. Drupal derives CSRF tokens and one-time login links from
 * the salt, so that is a forgery route requiring no foothold at all.
 */
final class FailClosedTest extends TestCase {

  /**
   * @return array<string, array{string}>
   */
  public static function requiredVariables(): array {
    return [
      'hash salt' => ['DRUPAL_HASH_SALT'],
      'database host' => ['DRUPAL_DB_HOST'],
      'database name' => ['DRUPAL_DB_NAME'],
      'database user' => ['DRUPAL_DB_USER'],
      'database password' => ['DRUPAL_DB_PASSWORD'],
    ];
  }

  /**
   * @dataProvider requiredVariables
   */
  public function testOverlayRefusesToLoadWithoutTheVariable(string $missing): void {
    [$status, $output] = $this->loadInSubprocess($missing);

    $this->assertNotSame(0, $status, "the overlay loaded successfully with $missing unset");
    $this->assertStringContainsString(
      $missing,
      $output,
      'the failure must name the missing variable; a generic error sends the reader looking in the wrong place'
    );
  }

  public function testOverlayLoadsWhenEverythingIsPresent(): void {
    [$status] = $this->loadInSubprocess(NULL);
    $this->assertSame(0, $status, 'the overlay failed to load with a complete environment');
  }

  /**
   * Includes the overlay in a fresh PHP process with one variable removed.
   *
   * @return array{int, string}
   */
  private function loadInSubprocess(?string $unset): array {
    $env = [
      'DRUPAL_HASH_SALT' => str_repeat('a', 64),
      'DRUPAL_DB_HOST' => 'db.invalid',
      'DRUPAL_DB_NAME' => 'drupal',
      'DRUPAL_DB_USER' => 'drupal',
      'DRUPAL_DB_PASSWORD' => 'pw',
    ];
    if ($unset !== NULL) {
      unset($env[$unset]);
    }

    $script = <<<'PHP_SCRIPT'
      $app_root = getenv('ACA_APP_ROOT');
      $site_path = 'sites/default';
      $settings = [];
      $databases = [];
      $config = [];
      require getenv('ACA_OVERLAY');
      exit(0);
      PHP_SCRIPT;

    $env['ACA_OVERLAY'] = ACA_SETTINGS_OVERLAY;
    $env['ACA_APP_ROOT'] = ACA_REPO_ROOT . '/web';
    // Keep stderr, where error_log() writes, in the captured output.
    $env['PATH'] = getenv('PATH') ?: '/usr/bin:/bin';

    $descriptors = [1 => ['pipe', 'w'], 2 => ['pipe', 'w']];
    $process = proc_open(
      [PHP_BINARY, '-d', 'error_log=', '-r', $script],
      $descriptors,
      $pipes,
      ACA_REPO_ROOT,
      $env
    );
    $this->assertIsResource($process);

    $output = stream_get_contents($pipes[1]) . stream_get_contents($pipes[2]);
    fclose($pipes[1]);
    fclose($pipes[2]);

    return [proc_close($process), $output];
  }

}
