[supervisord]
nodaemon=true
user=root
logfile=/dev/null
logfile_maxbytes=0
pidfile=/run/supervisord.pid

# ── Nginx ──────────────────────────────────────────────────────────────────────
[program:nginx]
command=nginx -g "daemon off;"
autostart=true
autorestart=true
priority=10
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

# ── PHP-FPM ────────────────────────────────────────────────────────────────────
[program:php-fpm]
command=php-fpm --nodaemonize
autostart=true
autorestart=true
priority=10
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

# ── Laravel Reverb (WebSocket) ─────────────────────────────────────────────────
[program:reverb]
command=php /var/www/html/artisan reverb:start
    --host=%(ENV_REVERB_SERVER_HOST)s
    --port=%(ENV_REVERB_SERVER_PORT)s
    --no-interaction
autostart=true
autorestart=true
priority=20
user=www-data
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

# ── Laravel Horizon (Queue) ────────────────────────────────────────────────────
[program:horizon]
command=php /var/www/html/artisan horizon
autostart=true
autorestart=true
priority=20
user=www-data
stopwaitsecs=3600
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0