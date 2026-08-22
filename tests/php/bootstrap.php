<?php

/**
 * @file
 * Test bootstrap.
 *
 * Deliberately does NOT load Drupal. The settings overlay runs before Drupal
 * exists — it is included from settings.php during bootstrap — so testing it
 * through a Drupal kernel would test something other than what production runs,
 * and would need a database to do it.
 */

declare(strict_types=1);

require_once __DIR__ . '/../../vendor/autoload.php';

define('ACA_REPO_ROOT', dirname(__DIR__, 2));
define('ACA_SETTINGS_OVERLAY', ACA_REPO_ROOT . '/docker/drupal/settings.azure.php');
