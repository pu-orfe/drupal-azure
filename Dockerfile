# ===========================================================================
# Drupal 10 — PHP-FPM + Nginx (single-container for Azure Container Apps)
# ===========================================================================
# Build:  docker build -t drupal-aca .
# Run:    docker run -p 8080:80 drupal-aca
# ===========================================================================

# ---------------------------------------------------------------------------
# Stage 1: Composer install (build dependencies, no runtime bloat)
# ---------------------------------------------------------------------------
FROM composer:2 AS composer-build

WORKDIR /app

# Copy Composer manifests first for layer caching
COPY composer.json composer.lock ./

# Install dependencies without dev packages; optimise autoloader
RUN composer install \
      --no-dev \
      --no-interaction \
      --prefer-dist \
      --optimize-autoloader \
      --no-scripts

# Copy the rest of the codebase (custom modules/themes/profiles)
COPY . .

# Run any post-install scripts (Drupal scaffold, etc.)
RUN composer run-script post-install-cmd --no-interaction || true

# ---------------------------------------------------------------------------
# Stage 2: Runtime image
# ---------------------------------------------------------------------------
FROM php:8.2-fpm-bookworm

# Install system packages and PHP extensions required by Drupal 10
RUN apt-get update && apt-get install -y --no-install-recommends \
      nginx \
      supervisor \
      libpng-dev \
      libjpeg62-turbo-dev \
      libwebp-dev \
      libfreetype6-dev \
      libzip-dev \
      libicu-dev \
      libonig-dev \
      mariadb-client \
      unzip \
      curl \
    && docker-php-ext-configure gd \
        --with-freetype \
        --with-jpeg \
        --with-webp \
    && docker-php-ext-install -j"$(nproc)" \
        gd \
        opcache \
        pdo_mysql \
        zip \
        intl \
        mbstring \
    && pecl install uploadprogress \
    && docker-php-ext-enable uploadprogress \
    && apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false \
    && rm -rf /var/lib/apt/lists/*

# Install Drush launcher (delegates to vendor/bin/drush)
RUN curl -fsSL https://github.com/drush-ops/drush-launcher/releases/latest/download/drush.phar \
      -o /usr/local/bin/drush \
    && chmod +x /usr/local/bin/drush

# ---------------------------------------------------------------------------
# PHP / OPcache tuning
# ---------------------------------------------------------------------------
RUN { \
      echo 'opcache.memory_consumption=128'; \
      echo 'opcache.interned_strings_buffer=8'; \
      echo 'opcache.max_accelerated_files=10000'; \
      echo 'opcache.revalidate_freq=0'; \
      echo 'opcache.validate_timestamps=0'; \
      echo 'opcache.enable_cli=1'; \
    } > /usr/local/etc/php/conf.d/opcache.ini \
    && { \
      echo 'upload_max_filesize=64M'; \
      echo 'post_max_size=64M'; \
      echo 'memory_limit=256M'; \
      echo 'max_execution_time=300'; \
    } > /usr/local/etc/php/conf.d/drupal.ini

# ---------------------------------------------------------------------------
# Nginx configuration
# ---------------------------------------------------------------------------
COPY docker/nginx/default.conf /etc/nginx/sites-available/default

# ---------------------------------------------------------------------------
# Supervisor (runs both nginx and php-fpm)
# ---------------------------------------------------------------------------
COPY docker/supervisor/supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# ---------------------------------------------------------------------------
# Application code
# ---------------------------------------------------------------------------
WORKDIR /var/www/html

COPY --from=composer-build /app ./

# Ensure the files directory exists (will be overridden by volume mount)
RUN mkdir -p web/sites/default/files private \
    && chown -R www-data:www-data web/sites/default/files private

# ---------------------------------------------------------------------------
# Settings: use environment-variable-driven settings
# ---------------------------------------------------------------------------
COPY docker/drupal/settings.aca.php web/sites/default/settings.aca.php

# Append the ACA settings include to settings.php if it exists
RUN if [ -f web/sites/default/settings.php ]; then \
      echo "" >> web/sites/default/settings.php; \
      echo "// Azure Container Apps settings overlay" >> web/sites/default/settings.php; \
      echo "if (file_exists(\$app_root . '/' . \$site_path . '/settings.aca.php')) {" >> web/sites/default/settings.php; \
      echo "  include \$app_root . '/' . \$site_path . '/settings.aca.php';" >> web/sites/default/settings.php; \
      echo "}" >> web/sites/default/settings.php; \
    fi

EXPOSE 80

# Healthcheck — hit the Drupal front page
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD curl -f http://localhost/ || exit 1

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
