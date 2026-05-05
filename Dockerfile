# syntax=docker/dockerfile:1
# =============================================================================
# Stage 1: Install Composer dependencies (no dev)
# Must run first — Vite needs vendor/filament CSS at build time.
# =============================================================================
FROM composer:2 AS vendor

WORKDIR /app

COPY composer.json composer.lock ./

# Auth is resolved in this priority order:
#   1. COMPOSER_AUTH build ARG — explicit override (docker compose / CI)
#   2. build_env secret (Helipod) — Helipack auto-injects all dashboard variables
#      as a BuildKit secret mounted at /run/secrets/build_env (.env file format)
#   3. composer_auth secret — local docker compose, reads ./auth.json
#   4. auth.json in build context — fallback for plain docker build
ARG COMPOSER_AUTH=""
COPY docker/composer-install.sh /composer-install.sh
RUN chmod +x /composer-install.sh
RUN --mount=type=secret,id=composer_auth,dst=/run/secrets/composer_auth,required=false \
    --mount=type=secret,id=build_env,dst=/run/secrets/build_env,required=false \
    /composer-install.sh

# =============================================================================
# Stage 2: Build Vite frontend assets
# =============================================================================
FROM node:22-alpine AS frontend

WORKDIR /app

COPY package*.json ./
RUN npm ci

COPY . .

# Filament CSS files are imported from vendor/ — copy them in from the vendor stage.
COPY --from=vendor /app/vendor ./vendor

# These get baked into the JS bundle at build time.
# Reverb is proxied via Nginx on port 80 — no separate port needed from the browser.
ARG VITE_APP_NAME="CodeWithDiki Toko Online"
ARG VITE_REVERB_APP_KEY=laravel-herd
ARG VITE_REVERB_HOST=localhost
ARG VITE_REVERB_PORT=80
ARG VITE_REVERB_SCHEME=http

ENV VITE_APP_NAME=$VITE_APP_NAME \
    VITE_REVERB_APP_KEY=$VITE_REVERB_APP_KEY \
    VITE_REVERB_HOST=$VITE_REVERB_HOST \
    VITE_REVERB_PORT=$VITE_REVERB_PORT \
    VITE_REVERB_SCHEME=$VITE_REVERB_SCHEME

RUN npm run build

# =============================================================================
# Stage 3: PHP-FPM runtime (used by app, horizon, reverb services)
# =============================================================================
FROM php:8.4-fpm-bookworm AS runtime

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    # PHP extension dependencies
    libpng-dev \
    libjpeg62-turbo-dev \
    libfreetype6-dev \
    libzip-dev \
    libicu-dev \
    libonig-dev \
    libsqlite3-dev \
    libssl-dev \
    # Image optimization tools (for spatie/laravel-image-optimizer)
    jpegoptim \
    optipng \
    pngquant \
    gifsicle \
    webp \
    # Utilities
    unzip \
    curl \
    && rm -rf /var/lib/apt/lists/*

# PHP extensions
RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install \
        pdo_sqlite \
        pdo_mysql \
        gd \
        zip \
        bcmath \
        intl \
        mbstring \
        pcntl \
        opcache \
        exif

# phpredis (required: REDIS_CLIENT=phpredis in .env)
RUN pecl install redis \
    && docker-php-ext-enable redis

COPY docker/php/php.ini /usr/local/etc/php/conf.d/99-custom.ini
COPY docker/php/www.conf /usr/local/etc/php-fpm.d/zz-docker-listen.conf

WORKDIR /var/www/html

# Copy application files
COPY --chown=www-data:www-data . .
COPY --from=vendor --chown=www-data:www-data /app/vendor ./vendor
COPY --from=frontend --chown=www-data:www-data /app/public/build ./public/build

# Store a copy of the build assets as the init source.
# Entrypoint uses this to seed the shared public_build volume on first run.
RUN cp -a /var/www/html/public/build /var/www/html/public/build_init

RUN mkdir -p /var/www/html/bootstrap/cache \
    && chmod -R 775 /var/www/html/storage \
    && chmod -R 775 /var/www/html/bootstrap/cache \
    && chown -R www-data:www-data /var/www/html/bootstrap/cache

COPY docker/php/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["php-fpm"]

# =============================================================================
# Stage 4: Nginx — serves static files + proxies PHP & Reverb WebSocket
# =============================================================================
FROM nginx:1.27-alpine AS webserver

# envsubst is needed to process ssl.conf.template
RUN apk add --no-cache gettext

# Copy nginx config templates and custom entrypoint
COPY docker/nginx/templates /etc/nginx/templates
COPY docker/nginx/entrypoint.sh /docker-entrypoint-nginx.sh
RUN chmod +x /docker-entrypoint-nginx.sh

# Copy static public files (css, fonts, favicons, etc.) from runtime.
# public/build is intentionally excluded — it will be provided by the shared
# public_build Docker volume (populated by the app container on startup).
COPY --from=runtime /var/www/html/public /var/www/html/public
RUN rm -rf /var/www/html/public/build /var/www/html/public/build_init

ENTRYPOINT ["/docker-entrypoint-nginx.sh"]
EXPOSE 80
