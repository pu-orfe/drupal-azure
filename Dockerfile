# ===========================================================================
# Drupal on Azure Container Apps — PHP-FPM + Nginx (single container)
# ===========================================================================
# Build:  docker build --build-arg COMMIT_SHA="$(git rev-parse HEAD)" -t drupal-azure .
# Run:    docker run -p 8080:80 drupal-azure
#
# Single stage, on purpose. An earlier version installed dependencies in a
# `composer:2` stage and copied `/app` into a `php:*-fpm` runtime. That builds
# the vendor tree with whatever PHP the composer image happens to carry, so
# Composer's platform checks (`config.platform.php`, `require: php`) are
# satisfied against the wrong runtime and any mismatch surfaces only when a
# request hits production. Installing with the PHP that will run the code makes
# that class of drift impossible.
#
# The cost is that the composer phar (~3 MB) ships in the image. That is a fair
# trade, and it also makes `composer show` available when diagnosing a live
# container.
# ===========================================================================

# Bump both this and the CI matrix together — scripts/verify-production-image.sh
# asserts they agree, because CI testing a different PHP than production runs is
# how a version bump ships broken.
ARG PHP_VERSION=8.3

FROM php:${PHP_VERSION}-fpm-bookworm

# ---------------------------------------------------------------------------
# System packages
# ---------------------------------------------------------------------------
# mariadb-client is not optional: docker-entrypoint.sh uses mysqldump for the
# pre-deploy backup and mysql for the cache-table recovery path.
RUN apt-get update && apt-get install -y --no-install-recommends \
      nginx \
      supervisor \
      mariadb-client \
      unzip \
      git \
      curl \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# PHP extensions
# ---------------------------------------------------------------------------
# mlocati/docker-php-extension-installer rather than hand-rolled
# docker-php-ext-configure/install plus pecl. It resolves the -dev packages and
# the correct extension version for the PHP in use, and removes the build
# dependencies afterwards. The hand-rolled form breaks on a PHP bump whenever a
# PECL extension has not yet cut a compatible release — uploadprogress is the
# one that reliably lags — and it breaks as an opaque compile error rather than
# a clear "no version available".
ADD https://github.com/mlocati/docker-php-extension-installer/releases/latest/download/install-php-extensions /usr/local/bin/
RUN chmod +x /usr/local/bin/install-php-extensions \
    && install-php-extensions \
        gd \
        pdo_mysql \
        zip \
        intl \
        opcache \
        apcu \
        uploadprogress \
    && rm -f /usr/local/bin/install-php-extensions

# ---------------------------------------------------------------------------
# Composer
# ---------------------------------------------------------------------------
COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer

# ---------------------------------------------------------------------------
# PHP configuration
# ---------------------------------------------------------------------------
RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"

COPY docker/php/opcache.ini  $PHP_INI_DIR/conf.d/10-opcache.ini
COPY docker/php/drupal.ini   $PHP_INI_DIR/conf.d/20-drupal.ini
COPY docker/php-fpm/www.conf /usr/local/etc/php-fpm.d/zz-www.conf

# ---------------------------------------------------------------------------
# Nginx + Supervisor
# ---------------------------------------------------------------------------
COPY docker/nginx/default.conf              /etc/nginx/sites-available/default
COPY docker/supervisor/supervisord.conf     /etc/supervisor/conf.d/supervisord.conf

# ---------------------------------------------------------------------------
# Application
# ---------------------------------------------------------------------------
WORKDIR /var/www/html

# The image records the commit it was built from. docker-entrypoint.sh compares
# it against the marker on the shared file share to decide whether this boot
# needs to run updb/cim/cr, so a scale-up on an unchanged image starts fast
# instead of re-running a schema check per replica. An unset value is treated as
# "always run"; verify-production-image.sh fails a build that leaves it empty.
ARG COMMIT_SHA=unknown
ENV CONTAINER_VERSION=$COMMIT_SHA

# Bounded retries around composer. A single transient 429/504 from GitHub on any
# one of ~200 packages otherwise fails the whole build — see the script.
COPY scripts/composer-retry.sh /usr/local/bin/composer-retry
RUN chmod +x /usr/local/bin/composer-retry

# Manifests first, so the dependency layer is cached until the lock file moves.
COPY composer.json composer.lock ./
RUN composer-retry install \
      --no-dev \
      --no-interaction \
      --no-progress \
      --prefer-dist \
      --optimize-autoloader

# Then the codebase.
COPY . .

# Second install, deliberately. `COPY . .` overwrites the scaffolded web root
# with the repo's copy and introduces custom modules/themes that the first
# install never saw, so the autoloader and the scaffold both need regenerating.
#
# This is NOT `|| true`. An earlier version ran `composer run-script
# post-install-cmd --no-interaction || true`, which turns a failed scaffold into
# a green build that ships a broken web root.
RUN composer-retry install \
      --no-dev \
      --no-interaction \
      --no-progress \
      --prefer-dist \
      --optimize-autoloader

# ---------------------------------------------------------------------------
# Settings overlay
# ---------------------------------------------------------------------------
# Written as a real file rather than appended to settings.php at build time. The
# append form (`echo ... >> settings.php`) is not idempotent, silently no-ops
# when settings.php is absent, and leaves the shipped settings.php different
# from the one in git — so what production runs cannot be read from the repo.
COPY docker/drupal/settings.azure.php web/sites/default/settings.azure.php

# ---------------------------------------------------------------------------
# Writable paths
# ---------------------------------------------------------------------------
# Both are replaced by Azure Files mounts at runtime; creating them here means
# the image also runs standalone (local `docker run`, the production image gate).
RUN mkdir -p web/sites/default/files private \
    && chown -R www-data:www-data web/sites/default/files private

# The entrypoint and its guard library. The library is a separate file because a
# safety net no test ever executes is not a safety net — tests/shell drives it
# directly. LIB_DIR is where the entrypoint looks for it.
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY docker/entrypoint-lib.sh /usr/local/lib/drupal-azure/entrypoint-lib.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 80

# Container Apps ignores Dockerfile HEALTHCHECK — it uses the probes declared on
# the container app (see infra/modules/aca.bicep). This exists only so a local
# `docker run` still reports health, and it targets the nginx-level endpoint so
# it does not depend on a database.
HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
  CMD curl -fsS http://127.0.0.1/nginx-health || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
