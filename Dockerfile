# syntax=docker/dockerfile:1
# =============================================================================
# Stage 1: Install Composer dependencies (no dev)
# Must run first — Vite needs vendor/filament CSS at build time.
# =============================================================================
FROM composer:2 AS vendor

WORKDIR /app

COPY composer.json composer.lock ./

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

COPY --from=vendor /app/vendor ./vendor

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
# Stage 3: Unified App Server (PHP-FPM + Nginx via Supervisor)
# =============================================================================
FROM php:8.4-fpm-bookworm AS runtime

# System dependencies (Added nginx, supervisor, and gettext-base for envsubst)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpng-dev \
    libjpeg62-turbo-dev \
    libfreetype6-dev \
    libzip-dev \
    libicu-dev \
    libonig-dev \
    libsqlite3-dev \
    libssl-dev \
    jpegoptim \
    optipng \
    pngquant \
    gifsicle \
    webp \
    unzip \
    curl \
    nginx \
    supervisor \
    gettext-base \
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

# phpredis
RUN pecl install redis \
    && docker-php-ext-enable redis

# Configure PHP
COPY docker/php/php.ini /usr/local/etc/php/conf.d/99-custom.ini
COPY docker/php/www.conf /usr/local/etc/php-fpm.d/zz-docker-listen.conf

WORKDIR /var/www/html

# Copy application files
COPY --chown=www-data:www-data . .
COPY --from=vendor --chown=www-data:www-data /app/vendor ./vendor
COPY --from=frontend --chown=www-data:www-data /app/public/build ./public/build

# Setup initial build directory
RUN cp -a /var/www/html/public/build /var/www/html/public/build_init

# Set Permissions
RUN mkdir -p /var/www/html/bootstrap/cache \
    && chmod -R 775 /var/www/html/storage \
    && chmod -R 775 /var/www/html/bootstrap/cache \
    && chown -R www-data:www-data /var/www/html/bootstrap/cache

# Copy Nginx templates and configuration
COPY docker/nginx/templates /etc/nginx/templates

# Create Supervisor Configuration (Runs both services)
RUN echo '[supervisord]\n\
nodaemon=true\n\
user=root\n\
\n\
[program:php-fpm]\n\
command=php-fpm\n\
stdout_logfile=/dev/stdout\n\
stdout_logfile_maxbytes=0\n\
stderr_logfile=/dev/stderr\n\
stderr_logfile_maxbytes=0\n\
\n\
[program:nginx]\n\
command=nginx -g "daemon off;"\n\
stdout_logfile=/dev/stdout\n\
stdout_logfile_maxbytes=0\n\
stderr_logfile=/dev/stderr\n\
stderr_logfile_maxbytes=0' > /etc/supervisor/conf.d/supervisord.conf

# Copy original entrypoints
COPY docker/php/entrypoint.sh /php-entrypoint.sh
COPY docker/nginx/entrypoint.sh /nginx-entrypoint.sh
RUN chmod +x /php-entrypoint.sh /nginx-entrypoint.sh

# Create a Unified Wrapper Script
RUN echo '#!/bin/sh\n\
# Execute PHP setup script (make sure it does not end with exec "$@")\n\
/php-entrypoint.sh\n\
# Execute Nginx setup script (like envsubst)\n\
/nginx-entrypoint.sh\n\
# Start Supervisor to run both processes\n\
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf' > /start.sh \
    && chmod +x /start.sh

# Expose HTTP port
EXPOSE 80

# Start the unified container
ENTRYPOINT ["/start.sh"]
