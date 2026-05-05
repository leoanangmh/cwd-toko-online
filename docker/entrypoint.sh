#!/bin/sh
set -e

echo "[entrypoint] Preparing filesystem..."

mkdir -p \
    /var/www/html/storage/app/public \
    /var/www/html/storage/sqlite \
    /var/www/html/storage/framework/cache/data \
    /var/www/html/storage/framework/sessions \
    /var/www/html/storage/framework/views \
    /var/www/html/storage/logs \
    /var/www/html/bootstrap/cache

# Seed or refresh public/build from the baked-in copy
cp -a /var/www/html/public/build_init/. /var/www/html/public/build/

chown -R www-data:www-data \
    /var/www/html/storage \
    /var/www/html/bootstrap/cache 2>/dev/null || true

chmod -R 775 \
    /var/www/html/storage \
    /var/www/html/bootstrap/cache

# SQLite setup
if [ "${DB_CONNECTION:-sqlite}" = "sqlite" ]; then
    SQLITE_PATH="${DB_DATABASE:-/var/www/html/storage/sqlite/database.sqlite}"
    if [ ! -f "$SQLITE_PATH" ]; then
        echo "[entrypoint] Creating SQLite file at $SQLITE_PATH"
        mkdir -p "$(dirname "$SQLITE_PATH")"
        touch "$SQLITE_PATH"
        chown www-data:www-data "$SQLITE_PATH"
    fi
fi

echo "[entrypoint] Running migrations..."
php artisan migrate --force

echo "[entrypoint] Linking storage..."
php artisan storage:link --force

if [ "${APP_ENV}" = "production" ]; then
    echo "[entrypoint] Caching config/routes/views/events..."
    php artisan config:cache
    php artisan route:cache
    php artisan view:cache
    php artisan event:cache
fi

# Process Nginx template based on SSL presence
DOMAIN="${NGINX_DOMAIN:-localhost}"
export NGINX_APP_HOST="${NGINX_APP_HOST:-127.0.0.1}"
export NGINX_REVERB_HOST="${NGINX_REVERB_HOST:-127.0.0.1}"
export NGINX_REVERB_PORT="${NGINX_REVERB_PORT:-8080}"
export NGINX_RESOLVER="${NGINX_RESOLVER:-$(grep '^nameserver' /etc/resolv.conf | head -1 | awk '{print $2}')}"

if [ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]; then
    envsubst '${NGINX_DOMAIN} ${NGINX_APP_HOST} ${NGINX_REVERB_HOST} ${NGINX_REVERB_PORT} ${NGINX_RESOLVER}' \
        < /etc/nginx/templates/ssl.conf.template \
        > /etc/nginx/conf.d/default.conf
else
    envsubst '${NGINX_APP_HOST} ${NGINX_REVERB_HOST} ${NGINX_REVERB_PORT} ${NGINX_RESOLVER}' \
        < /etc/nginx/templates/http.conf \
        > /etc/nginx/conf.d/default.conf
fi

echo "[entrypoint] Starting supervisord..."
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf