<?php

/**
 * @file
 * Drupal settings for this deployment.
 *
 * Tracked in git and shipped in the image, so the configuration production runs
 * can be read from the repository. It contains no secrets: everything
 * environment-specific is read from environment variables by the overlay below.
 *
 * An earlier version of this template appended the overlay include to this file
 * during the Docker build with a series of `echo >>` lines. That is not
 * idempotent, it silently did nothing when this file was absent, and it left the
 * shipped settings.php different from the one in git. Including the overlay
 * explicitly here is the same behaviour, visible.
 *
 * ---------------------------------------------------------------------------
 * WARNING: `drush site:install` APPENDS to this file.
 *
 * Drupal's installer writes a literal $databases array and a generated
 * $settings['hash_salt'] to the end of settings.php whenever the file is
 * writable. Appended after the include below, those literals WIN — so the
 * site silently stops reading its configuration from the environment, and a
 * hash salt ends up in a git-tracked file.
 *
 * scripts/local-dev.sh and scripts/test.sh therefore make this file read-only
 * for the duration of an install, and tests/shell/run.sh asserts that no
 * credential literal has crept in.
 * ---------------------------------------------------------------------------
 */

$databases = [];
$settings = [];
$config = [];

/**
 * Azure Container Apps overlay: database, trusted hosts, file paths, proxy and
 * session handling.
 *
 * TWO CANDIDATE PATHS, and the order matters.
 *
 *   1. Next to this file. The production Dockerfile copies the overlay to
 *      web/sites/default/settings.azure.php, which is where Drupal conventionally
 *      looks and what scripts/verify-production-image.sh asserts is present.
 *   2. docker/drupal/settings.azure.php in the repository. This is the path that
 *      matters for local development: docker-compose bind-mounts the checkout
 *      over /var/www/html, which SHADOWS anything the image placed inside
 *      web/sites/default. Without this fallback the local stack silently has no
 *      database configuration at all — `drush status` prints no database row,
 *      and `drush site:install` fails with "Call to a member function
 *      getInstallTasks() on null", which names neither the cause nor the file.
 *
 * The fallback is not merely convenient. It means local development exercises
 * the exact same overlay production runs, rather than a second copy that can
 * drift from it — which is the whole reason the overlay is one file.
 */
$aca_overlay_candidates = [
  $app_root . '/' . $site_path . '/settings.azure.php',
  dirname($app_root) . '/docker/drupal/settings.azure.php',
];
foreach ($aca_overlay_candidates as $aca_overlay) {
  if (file_exists($aca_overlay)) {
    include $aca_overlay;
    break;
  }
}
unset($aca_overlay_candidates, $aca_overlay);
