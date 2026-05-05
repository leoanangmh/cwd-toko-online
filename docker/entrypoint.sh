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

echo "[entrypoint] Syncing public/build from image..."
cp -a /var/www/html/public/build_init/. /var/www/html/public/build/

chown -R www-data:www-data \
    /var/www/html/storage \
    /var/www/html/bootstrap/cache 2>/dev/null || true

chmod -R 775 \
    /var/www/html/storage \
    /var/www/html/bootstrap/cache

# ---------------------------------------------------------------------------
# SQLite — create database file if it doesn't exist yet
# ---------------------------------------------------------------------------
if [ "${DB_CONNECTION:-sqlite}" = "sqlite" ]; then
    SQLITE_PATH="${DB_DATABASE:-/var/www/html/storage/sqlite/database.sqlite}"
    if [ ! -f "$SQLITE_PATH" ]; then
        echo "[entrypoint] Creating SQLite database at $SQLITE_PATH ..."
        mkdir -p "$(dirname "$SQLITE_PATH")"
        touch "$SQLITE_PATH"
        chown www-data:www-data "$SQLITE_PATH"
    fi
fi

# ---------------------------------------------------------------------------
# Start Redis temporarily in background for migrations
# ---------------------------------------------------------------------------
echo "[entrypoint] Starting Redis for migrations..."
redis-server --bind 127.0.0.1 --port 6379 --loglevel warning &
REDIS_PID=$!

echo "[entrypoint] Waiting for Redis..."
until redis-cli ping 2>/dev/null | grep -q PONG; do
    sleep 0.2
done
echo "[entrypoint] Redis is ready."

# ---------------------------------------------------------------------------
# Laravel bootstrap
# ---------------------------------------------------------------------------
echo "[entrypoint] Running migrations..."
php artisan migrate --force

echo "[entrypoint] Linking storage..."
php artisan storage:link --force

if [ "${APP_ENV}" = "production" ]; then
    echo "[entrypoint] Caching config / routes / views / events..."
    php artisan config:cache
    php artisan route:cache
    php artisan view:cache
    php artisan event:cache
fi

# Stop the temporary Redis — Supervisor will start the managed one
echo "[entrypoint] Stopping temporary Redis (PID $REDIS_PID)..."
kill $REDIS_PID
wait $REDIS_PID 2>/dev/null || true
echo "[entrypoint] Temporary Redis stopped."

# ---------------------------------------------------------------------------
# Nginx config
# ---------------------------------------------------------------------------
DOMAIN="${NGINX_DOMAIN:-localhost}"
export NGINX_REVERB_PORT="${NGINX_REVERB_PORT:-8080}"

echo "[entrypoint] Configuring nginx for domain: ${DOMAIN}"

if [ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]; then
    echo "[entrypoint] SSL certificate found — enabling HTTPS mode."
    envsubst '${NGINX_DOMAIN} ${NGINX_REVERB_PORT}' \
        < /etc/nginx/templates/ssl.conf.template \
        > /etc/nginx/conf.d/default.conf
else
    echo "[entrypoint] No SSL certificate — starting in HTTP mode."
    envsubst '${NGINX_REVERB_PORT}' \
        < /etc/nginx/templates/http.conf \
        > /etc/nginx/conf.d/default.conf
fi

# ---------------------------------------------------------------------------
# Hand off to Supervisor — it will also start redis-server again as a managed
# process, which is fine: the daemonized instance above exits cleanly when
# supervisord's redis program takes over on the same port.
# ---------------------------------------------------------------------------
echo "[entrypoint] Starting supervisord..."
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf