#!/usr/bin/env bash
# =============================================================================
# РАЗВЕРТЫВАНИЕ ТЕСТОВОЙ НАГРУЗКИ (APP + DAEMON)
# Запускается независимо от инфраструктурных скриптов
# =============================================================================
set -euo pipefail

ENV_FILE="/etc/default/ha-cluster"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

HAPROXY_PORT="${HAPROXY_DB_BIND_PORT:-5000}"
APP_SERVICE="${APP_SERVICE:-my-app}"
DAEMON_SERVICE="${DAEMON_SERVICE:-my-daemon}"

echo "[1/3] Установка Python зависимостей..."
apt-get update -qq && apt-get install -y -qq python3 python3-psycopg2 >/dev/null

echo "[2/3] Создание исполняемых файлов приложения и демона..."

# Демон генерации записей
cat << EOF > /usr/local/bin/my-daemon.py
#!/usr/bin/env python3
import time, socket, psycopg2, sys

HOSTNAME = socket.gethostname()
DB_CONFIG = {"host": "127.0.0.1", "port": ${HAPROXY_PORT}, "user": "postgres", "dbname": "postgres", "connect_timeout": 3}

while True:
    try:
        conn = psycopg2.connect(**DB_CONFIG)
        conn.autocommit = True
        with conn.cursor() as cur:
            cur.execute("INSERT INTO cluster_heartbeats (node_name, payload) VALUES (%s, %s);",
                        (HOSTNAME, f"Heartbeat from {HOSTNAME}"))
        conn.close()
    except Exception as e:
        print(f"[{HOSTNAME}] Демон: ошибка записи в БД: {e}", file=sys.stderr, flush=True)
    time.sleep(3)
EOF
chmod +x /usr/local/bin/my-daemon.py

# Веб-сайт
cat << EOF > /usr/local/bin/my-app.py
#!/usr/bin/env python3
import socket, psycopg2
from http.server import HTTPServer, BaseHTTPRequestHandler

HOSTNAME = socket.gethostname()
DB_CONFIG = {"host": "127.0.0.1", "port": ${HAPROXY_PORT}, "user": "postgres", "dbname": "postgres", "connect_timeout": 3}

class AppHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        records = []
        db_status = "OK"
        try:
            conn = psycopg2.connect(**DB_CONFIG)
            with conn.cursor() as cur:
                cur.execute("SELECT id, created_at, node_name, payload FROM cluster_heartbeats ORDER BY id DESC LIMIT 10;")
                records = cur.fetchall()
            conn.close()
        except Exception as e:
            db_status = f"Ошибка: {e}"

        rows = "".join(f"<tr><td>{r[0]}</td><td>{r[1]}</td><td><b>{r[2]}</b></td><td>{r[3]}</td></tr>" for r in records)
        html = f"""<!DOCTYPE html><html><head><meta charset="utf-8"><title>HA App</title><meta http-equiv="refresh" content="3">
<style>body{{font-family:sans-serif;margin:40px;background:#eceff1}}.card{{background:#fff;padding:24px;border-radius:8px}}
table{{width:100%;border-collapse:collapse;margin-top:15px}}th,td{{border:1px solid #cfd8dc;padding:8px;text-align:left}}</style></head>
<body><div class="card"><h2>Обслуживающий узел: {HOSTNAME}</h2><p>Статус БД через HAProxy ({HAPROXY_PORT}): <b>{db_status}</b></p>
<table><tr><th>ID</th><th>Время</th><th>Нода</th><th>Данные</th></tr>{rows}</table></div></body></html>"""

        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(html.encode("utf-8"))

    def log_message(self, format, *args): return

if __name__ == '__main__':
    HTTPServer(('0.0.0.0', 8080), AppHandler).serve_forever()
EOF
chmod +x /usr/local/bin/my-app.py

echo "[3/3] Регистрация systemd юнитов (без автозапуска)..."
cat << EOF > /etc/systemd/system/${DAEMON_SERVICE}.service
[Unit]
Description=Cluster Test Heartbeat Daemon
After=network.target haproxy.service
[Service]
Type=simple
User=postgres
ExecStart=/usr/local/bin/my-daemon.py
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF

cat << EOF > /etc/systemd/system/${APP_SERVICE}.service
[Unit]
Description=Cluster Test Web App
After=network.target haproxy.service
[Service]
Type=simple
User=postgres
ExecStart=/usr/local/bin/my-app.py
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF

# Инициализируем схему в БД (только если сейчас подключены к живому мастеру)
if timeout 2 bash -c "</dev/tcp/127.0.0.1/5432" 2>/dev/null; then
  sudo -u postgres psql -p 5432 -d postgres -c "
    CREATE TABLE IF NOT EXISTS cluster_heartbeats (
        id SERIAL PRIMARY KEY,
        created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT clock_timestamp(),
        node_name VARCHAR(64) NOT NULL,
        payload TEXT NOT NULL
    );
  " 2>/dev/null || true
fi

systemctl daemon-reload
systemctl disable "$APP_SERVICE" "$DAEMON_SERVICE" 2>/dev/null || true
systemctl stop "$APP_SERVICE" "$DAEMON_SERVICE" 2>/dev/null || true

echo "[УСПЕХ] Тестовые сервисы $APP_SERVICE и $DAEMON_SERVICE развернуты."