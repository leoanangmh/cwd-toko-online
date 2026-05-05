# syntax=docker/dockerfile:1

# =============================================================================
# Stage 1: Composer dependencies
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
# Stage 2: Vite frontend assets
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
# Stage 3: Runtime — PHP-FPM + Nginx + Reverb + Horizon via Supervisor
# =============================================================================
FROM php:8.4-fpm-bookworm AS runtime

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
    redis-server \
    && rm -rf /var/lib/apt/lists/*

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

RUN pecl install redis \
    && docker-php-ext-enable redis

COPY docker/php/php.ini /usr/local/etc/php/conf.d/99-custom.ini
COPY docker/php/www.conf /usr/local/etc/php-fpm.d/zz-docker-listen.conf

# Create PHP-FPM socket directory
RUN mkdir -p /run/php && chown www-data:www-data /run/php

WORKDIR /var/www/html

COPY --chown=www-data:www-data . .
COPY --from=vendor  --chown=www-data:www-data /app/vendor        ./vendor
COPY --from=frontend --chown=www-data:www-data /app/public/build ./public/build

RUN cp -a /var/www/html/public/build /var/www/html/public/build_init

RUN mkdir -p /var/www/html/bootstrap/cache \
    && chmod -R 775 /var/www/html/storage \
    && chmod -R 775 /var/www/html/bootstrap/cache \
    && chown -R www-data:www-data /var/www/html/bootstrap/cache

# Nginx templates
COPY docker/nginx/templates /etc/nginx/templates

# Remove all pre-baked nginx site configs
RUN rm -f /etc/nginx/conf.d/default.conf \
          /etc/nginx/sites-enabled/default \
          /etc/nginx/sites-available/default

# Supervisor config
COPY docker/supervisor/supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Single unified entrypoint
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 80

ENTRYPOINT ["/entrypoint.sh"]