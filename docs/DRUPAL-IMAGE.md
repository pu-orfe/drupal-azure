# Drupal Container Image: Custom vs. Official

## This Project Uses a Custom Image

This project builds a **custom Docker image** rather than using the [official `drupal` Docker image](https://hub.docker.com/_/drupal). Here's why and when each approach makes sense.

## Why a Custom Image?

The custom image (defined in `Dockerfile`) bundles:

- **Your site's code** — custom modules, themes, composer dependencies, and configuration baked into the image
- **PHP-FPM + Nginx** in a single container via Supervisor (Azure Container Apps works best with one container per app)
- **Drupal settings overlay** (`settings.aca.php`) that reads database credentials from environment variables
- **OPcache tuning** for production (timestamp validation disabled — code is immutable)
- **Drush** available inside the container for post-deploy tasks

This gives you **immutable, reproducible deployments**: every revision is a known-good snapshot of your code. Rolling back means pointing to a previous image tag.

## When Would You Use the Official Drupal Image?

The [official `drupal` image](https://hub.docker.com/_/drupal) is useful for:

- **Quick evaluation** — spin up Drupal in seconds without a Dockerfile
- **Development environments** — mount your code as a volume and iterate
- **Simple sites** — vanilla Drupal with mostly contrib modules and minimal custom code

However, it has limitations for production on Azure Container Apps:

| Concern | Official Image | This Custom Image |
|---------|---------------|-------------------|
| Web server | Apache (separate process model) | Nginx + PHP-FPM via Supervisor (single container) |
| Your custom code | Must be mounted or copied in at runtime | Baked into the image at build time |
| Composer dependencies | Not included; must run `composer install` on startup or mount `vendor/` | Pre-installed in build stage, optimized autoloader |
| Immutability | Mutable — depends on volume contents at start time | Immutable — code is fixed per image tag |
| Rollback | Complex (need to revert volumes and code) | Simple — deploy previous image tag |
| Startup time | Slower if running `composer install` at boot | Fast — everything is pre-built |
| Image size | Larger (includes Apache + build tools) | Smaller (multi-stage build, no build tools in runtime) |

## Building on the Official Image (Hybrid Approach)

If you prefer to base your image on the official Drupal image, you can use it as a starting point and add Nginx/Supervisor. However, the official image uses Apache by default, so you'd need to replace the entrypoint. This is more work than starting from `php:8.2-fpm-bookworm` as this project does.

A hybrid Dockerfile would look like:

```dockerfile
# NOT recommended — more complexity for no benefit over starting from php:fpm
FROM drupal:10-fpm AS base
# ... then add Nginx, Supervisor, your settings overlay, etc.
```

**Recommendation:** Continue using the custom `php:8.2-fpm-bookworm` base as this project does. It gives you full control over the image contents, smaller images, and a simpler mental model.

## How Updates Flow Through Azure

The CI/CD pipeline (`drupal-update.yml`) handles the full update lifecycle:

```
composer update → docker build → ACR push → Container App revision → Drush updb + cr
```

1. **Composer Update** — GitHub Actions runs `composer update`, commits the new `composer.lock`
2. **Docker Build** — The Dockerfile runs `composer install` (from the lock file) in a build stage, then copies the result into a clean runtime image
3. **ACR Push** — The new image is pushed to Azure Container Registry with a timestamped tag + `:latest`
4. **Deploy Revision** — `az containerapp update` creates a new Container App revision pointing to the new image tag. The old revision continues serving traffic until the new one is healthy (zero-downtime blue/green)
5. **Post-Deploy** — Drush runs `updb -y` (database migrations) and `cr` (cache rebuild) inside the new container

### What's Immutable vs. Mutable

| Layer | Immutable? | Storage |
|-------|-----------|---------|
| PHP code, Drupal core, contrib modules | Yes | Baked into Docker image |
| Custom modules and themes | Yes | Baked into Docker image |
| `composer.lock` | Yes | Baked into Docker image |
| Uploaded files (`sites/default/files/`) | No — mutable | Azure File Share (`drupal-public`) |
| Private files | No — mutable | Azure File Share (`drupal-private`) |
| Database | No — mutable | Azure MySQL Flexible Server |
| Drupal config (exported YAML) | Yes | Baked into image at `config/sync/` |
