#!/usr/bin/env bash
# =============================================================================
# РАЗВЕРТЫВАНИЕ ТЕСТОВОЙ НАГРУЗКИ (APP + DAEMON)
# Только тестовые данные и тестовые сервисы.
# =============================================================================
set -euo pipefail

ENV_FILE="/etc/default/ha-cluster"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "[ОШИБКА] Файл $ENV_FILE не найден. Сначала выполните generate-ha-config.sh."
  exit 1
fi

source "$ENV_FILE"

HAPROXY_PORT="${HAPROXY_DB_BIND_PORT:-5000}"
APP_SERVICE="${APP_SERVICE:-my-app}"
APP_SERVICE="${APP_SERVICE%.service}"
DAEMON_SERVICE="${DAEMON_SERVICE:-my-daemon}"
DAEMON_SERVICE="${DAEMON_SERVICE%.service}"

PGBIN="${PGBIN:-/usr/lib/postgresql/16/bin}"
DB_PORT="${DB_PORT:-5432}"

# Тестовый пользователь приложения
APP_DB_USER="${APP_DB_USER:-app_user}"
APP_DB_PASS="${APP_DB_PASS:-AppSecretPass!}"
PGPASS_DEMO="/var/lib/postgresql/.pgpass.demo"

echo "[1/5] Установка Python зависимостей..."
apt-get update -qq && apt-get install -y python3 python3-psycopg2

echo "[2/5] Создание .pgpass для тестового приложения..."
cat > "$PGPASS_DEMO" <<EOF
127.0.0.1:${HAPROXY_PORT}:*:${APP_DB_USER}:${APP_DB_PASS}
localhost:${HAPROXY_PORT}:*:${APP_DB_USER}:${APP_DB_PASS}
*:${HAPROXY_PORT}:*:${APP_DB_USER}:${APP_DB_PASS}
*:5432:*:${APP_DB_USER}:${APP_DB_PASS}
EOF

chown postgres:postgres "$PGPASS_DEMO"
chmod 0600 "$PGPASS_DEMO"

echo "[3/5] Создание тестовой схемы, если локальный PostgreSQL сейчас является master..."

LOCAL_MASTER="no"
if sudo -u postgres "$PGBIN/psql" \
     -h /var/run/postgresql \
     -p "$DB_PORT" \
     -d postgres \
     -tAc "SELECT pg_is_in_recovery();" 2>/dev/null | grep -qx "f"; then
  LOCAL_MASTER="yes"
fi

if [[ "$LOCAL_MASTER" == "yes" ]]; then
  echo "[INFO] Локальный узел является master. Создаю тестового пользователя и таблицу."

  sudo -u postgres "$PGBIN/psql" -h /var/run/postgresql -p "$DB_PORT" -d postgres -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${APP_DB_USER}') THEN
    CREATE ROLE ${APP_DB_USER} LOGIN PASSWORD '${APP_DB_PASS}' SUPERUSER;
  ELSE
    ALTER ROLE ${APP_DB_USER} LOGIN PASSWORD '${APP_DB_PASS}' SUPERUSER;
  END IF;
END
\$\$;

CREATE TABLE IF NOT EXISTS public.cluster_heartbeats (
    id BIGSERIAL PRIMARY KEY,
    created_at TIMESTAMPTZ DEFAULT clock_timestamp(),
    node_name VARCHAR(64) NOT NULL,
    payload TEXT DEFAULT ''
);

GRANT ALL ON SCHEMA public TO ${APP_DB_USER};
GRANT ALL ON TABLE public.cluster_heartbeats TO ${APP_DB_USER};
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO ${APP_DB_USER};
SQL

  echo "[УСПЕХ] Тестовая схема создана."
else
  echo "[INFO] Локальный PostgreSQL не активен как master."
  echo "[INFO] Схема будет получена с master через репликацию."
fi

echo "[4/5] Создание исполняемых файлов приложения и демона..."

# Демон генерации heartbeat-записей
cat << EOF > /usr/local/bin/my-daemon.py
#!/usr/bin/env python3
import time, socket, psycopg2, sys

HOSTNAME = socket.gethostname()
DB_CONFIG = {
    "host": "127.0.0.1",
    "port": ${HAPROXY_PORT},
    "user": "${APP_DB_USER}",
    "dbname": "postgres",
    "connect_timeout": 5
}

while True:
    conn = None
    try:
        conn = psycopg2.connect(**DB_CONFIG)
        conn.autocommit = True
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO public.cluster_heartbeats (node_name, payload) VALUES (%s, %s);",
                (HOSTNAME, f"Heartbeat from {HOSTNAME}")
            )
    except Exception as e:
        print(f"[{HOSTNAME}] Демон: ошибка записи в БД через HAProxy: {e}", file=sys.stderr, flush=True)
    finally:
        if conn:
            try:
                conn.close()
            except Exception:
                pass

    time.sleep(3)
EOF

chmod +x /usr/local/bin/my-daemon.py

# Многопоточное веб-приложение
cat << EOF > /usr/local/bin/my-app.py
#!/usr/bin/env python3
import html
import os
import socket
import subprocess
import time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import psycopg2
from psycopg2.extras import RealDictCursor

HOSTNAME = socket.gethostname()
ENV_FILE = "/etc/default/ha-cluster"
BOOT_MODE_FILE = "/run/cluster_boot_mode"

# 1. Читаем переменные из окружения, переданного systemd
CLUSTER_ENV = dict(os.environ)

# Запасной вариант, если запущен вручную
if os.path.exists(ENV_FILE):
    try:
        with open(ENV_FILE, "r") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    if k not in CLUSTER_ENV:
                        CLUSTER_ENV[k] = v.strip('"\'')
    except (PermissionError, OSError):
        pass

HAPROXY_PORT = int(CLUSTER_ENV.get("HAPROXY_DB_BIND_PORT", 5000))
CLUSTER_VIP = CLUSTER_ENV.get("CLUSTER_VIP", "")
APP_DB_USER = CLUSTER_ENV.get("APP_DB_USER", "app_user")

DB_CONFIG = {
    "host": "127.0.0.1",
    "port": HAPROXY_PORT,
    "user": APP_DB_USER,
    "dbname": "postgres",
    "connect_timeout": 3
}

def get_local_vip_status():
    if not CLUSTER_VIP:
        return "UNKNOWN"
    try:
        out = subprocess.check_output(["ip", "-4", "addr", "show"], text=True)
        return "BOUND (Active on this node)" if CLUSTER_VIP in out else "NOT BOUND"
    except Exception:
        return "ERR"

def get_boot_mode_info():
    if os.path.exists(BOOT_MODE_FILE):
        try:
            with open(BOOT_MODE_FILE, "r") as f:
                return dict(line.strip().split("=", 1) for line in f if "=" in line)
        except (PermissionError, OSError):
            return {}
    return {}

class AppHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/favicon.ico':
            self.send_response(204)
            self.send_header("Connection", "close")
            self.end_headers()
            return

        db_connected = False
        db_err = ""
        pg_info = {}
        slots = []
        repl_clients = []
        recent_records = []
        node_stats = {}
        split_brain_alert = False
        write_lag_sec = None

        boot_info = get_boot_mode_info()
        vip_status = get_local_vip_status()

        try:
            conn = psycopg2.connect(**DB_CONFIG)
            conn.autocommit = True
            db_connected = True
            with conn.cursor(cursor_factory=RealDictCursor) as cur:
                # 1. Параметры бэкенда
                cur.execute("""
                    SELECT 
                        inet_server_addr() AS srv_addr,
                        inet_server_port() AS srv_port,
                        pg_is_in_recovery() AS in_recovery,
                        timeline_id,
                        checkpoint_lsn,
                        clock_timestamp() AS db_now
                    FROM pg_control_checkpoint();
                """)
                pg_info = cur.fetchone()

                # 2. Слоты репликации
                cur.execute("""
                    SELECT slot_name, plugin, active, wal_status
                    FROM pg_replication_slots;
                """)
                slots = cur.fetchall()

                # 3. Подключенные standby
                cur.execute("""
                    SELECT application_name, client_addr, state, sync_state, replay_lag
                    FROM pg_stat_replication;
                """)
                repl_clients = cur.fetchall()

                # 4. Последние heartbeats
                cur.execute("""
                    SELECT id, created_at, node_name, payload,
                           ROUND(EXTRACT(EPOCH FROM (clock_timestamp() - created_at))::numeric, 1) as age_sec
                    FROM public.cluster_heartbeats
                    ORDER BY id DESC
                    LIMIT 12;
                """)
                recent_records = cur.fetchall()

                # 5. Split-Brain проверка за 60 сек
                cur.execute("""
                    SELECT node_name, COUNT(*) as cnt
                    FROM public.cluster_heartbeats
                    WHERE created_at >= clock_timestamp() - INTERVAL '60 seconds'
                    GROUP BY node_name;
                """)
                for r in cur.fetchall():
                    node_stats[r['node_name']] = r['cnt']

                if len(node_stats) > 1:
                    split_brain_alert = True

                if recent_records:
                    write_lag_sec = recent_records[0]['age_sec']

            conn.close()
        except Exception as e:
            db_err = str(e)

        # Подготовка блока PostgreSQL
        if db_connected:
            srv_addr = pg_info.get('srv_addr')
            srv_port = pg_info.get('srv_port')
            tli = pg_info.get('timeline_id')
            lsn = pg_info.get('checkpoint_lsn')
            if pg_info.get('in_recovery'):
                mode_badge = '<span class="badge yellow">STANDBY (Read-Only)</span>'
            else:
                mode_badge = '<span class="badge green">PRIMARY (Read-Write)</span>'

            pg_details_html = f"""
            <div class="stat-row">
                <span class="stat-label">Реальный бэкенд СУБД:</span>
                <code>{srv_addr}:{srv_port}</code>
            </div>
            <div class="stat-row">
                <span class="stat-label">Режим экземпляра:</span>
                <span>{mode_badge}</span>
            </div>
            <div class="stat-row">
                <span class="stat-label">Timeline ID / LSN:</span>
                <b>TLI: {tli}</b> <span class="muted">({lsn})</span>
            </div>
            """
            conn_badge = '<span class="badge green">CONNECTED</span>'
        else:
            pg_details_html = f'<p class="muted" style="color:var(--red);">{html.escape(db_err)}</p>'
            conn_badge = '<span class="badge red">DISCONNECTED</span>'

        # Подготовка таблицы слотов
        slots_rows = []
        for s in slots:
            slot_active = '<span class="badge green">ACTIVE</span>' if s['active'] else '<span class="badge red">INACTIVE</span>'
            wal_cls = 'red' if s['wal_status'] == 'lost' else 'green'
            wal_badge = f"<span class='badge {wal_cls}'>{s['wal_status']}</span>"
            slots_rows.append(
                f"<tr><td><code>{s['slot_name']}</code></td><td>{slot_active}</td><td>{wal_badge}</td></tr>"
            )
        slots_html = "".join(slots_rows) if slots_rows else "<tr><td colspan='3' class='muted'>Слоты не зарегистрированы</td></tr>"

        # Подготовка таблицы репликации
        repl_rows = []
        for rc in repl_clients:
            lag = rc['replay_lag'] if rc['replay_lag'] is not None else '0s'
            repl_rows.append(
                f"<tr><td><b>{rc['application_name']}</b></td><td>{rc['client_addr']}</td>"
                f"<td>{rc['state']} / {rc['sync_state']}</td><td>{lag}</td></tr>"
            )
        repl_html = "".join(repl_rows) if repl_rows else "<tr><td colspan='4' class='muted'>Нет подключенных standby-узлов</td></tr>"

        # Подготовка журнала heartbeat
        record_rows = []
        for r in recent_records:
            time_str = r['created_at'].strftime('%H:%M:%S')
            record_rows.append(
                f"<tr><td>{r['id']}</td><td>{time_str}</td>"
                f"<td><span class=\"node-tag\">{r['node_name']}</span></td>"
                f"<td>{r['payload']}</td><td>{r['age_sec']}s назад</td></tr>"
            )
        rows_html = "".join(record_rows) if record_rows else "<tr><td colspan='5' class='muted'>Таблица пуста</td></tr>"

        # Баннеры
        split_brain_banner = ""
        if split_brain_alert:
            split_brain_banner = f"""
            <div class="alert danger">
                ⚠️ <b>ВНИМАНИЕ: ОБНАРУЖЕН ПРИЗНАК SPLIT-BRAIN!</b><br>
                За последние 60 секунд в базу поступали записи от нескольких узлов одновременно: {node_stats}.
            </div>
            """

        freeze_banner = ""
        if write_lag_sec is not None and float(write_lag_sec) > 6.0:
            freeze_banner = f"""
            <div class="alert warning">
                ⏳ <b>ЗАДЕРЖКА ЗАПИСИ (FAILOVER / RTO):</b> Последняя запись была {write_lag_sec} сек. назад (норма &le; 3s).
            </div>
            """

        boot_mode = boot_info.get('MODE', 'STANDALONE')
        last_role = boot_info.get('LAST_ROLE', 'N/A')

        html_body = f"""<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="utf-8">
<title>HA Cluster Observability ({HOSTNAME})</title>
<meta http-equiv="refresh" content="2">
<style>
  :root {{ --bg: #0f172a; --card: #1e293b; --border: #334155; --text: #f8fafc; --muted: #94a3b8; --green: #10b981; --red: #ef4444; --yellow: #f59e0b; --blue: #38bdf8; }}
  body {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 0; padding: 24px; background: var(--bg); color: var(--text); }}
  .container {{ max-width: 1200px; margin: 0 auto; display: flex; flex-direction: column; gap: 20px; }}
  .grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(360px, 1fr)); gap: 16px; }}
  .card {{ background: var(--card); border: 1px solid var(--border); border-radius: 8px; padding: 18px; }}
  h2, h3 {{ margin-top: 0; margin-bottom: 12px; font-size: 1.15rem; font-weight: 600; }}
  .badge {{ padding: 3px 8px; border-radius: 4px; font-size: 0.75rem; font-weight: 700; text-transform: uppercase; }}
  .badge.green {{ background: rgba(16, 185, 129, 0.2); color: var(--green); border: 1px solid var(--green); }}
  .badge.red {{ background: rgba(239, 68, 68, 0.2); color: var(--red); border: 1px solid var(--red); }}
  .badge.yellow {{ background: rgba(245, 158, 11, 0.2); color: var(--yellow); border: 1px solid var(--yellow); }}
  .badge.blue {{ background: rgba(56, 189, 248, 0.2); color: var(--blue); border: 1px solid var(--blue); }}
  .stat-row {{ display: flex; justify-content: space-between; padding: 6px 0; border-bottom: 1px solid rgba(255,255,255,0.05); font-size: 0.9rem; }}
  .stat-row:last-child {{ border-bottom: none; }}
  .stat-label {{ color: var(--muted); }}
  table {{ width: 100%; border-collapse: collapse; font-size: 0.85rem; margin-top: 8px; }}
  th, td {{ padding: 8px; text-align: left; border-bottom: 1px solid var(--border); }}
  th {{ color: var(--muted); font-weight: 600; }}
  .alert {{ padding: 12px 16px; border-radius: 6px; font-size: 0.9rem; }}
  .alert.danger {{ background: rgba(239, 68, 68, 0.15); border: 1px solid var(--red); color: #fca5a5; }}
  .alert.warning {{ background: rgba(245, 158, 11, 0.15); border: 1px solid var(--yellow); color: #fde68a; }}
  .node-tag {{ background: rgba(255,255,255,0.1); padding: 2px 6px; border-radius: 4px; font-family: monospace; }}
  .muted {{ color: var(--muted); }}
</style>
</head>
<body>
<div class="container">
    {split_brain_banner}
    {freeze_banner}

    <div class="grid">
        <div class="card">
            <h3>🌐 Окружение Веб-Хоста</h3>
            <div class="stat-row">
                <span class="stat-label">Сервер, отдавший HTTP:</span>
                <b>{HOSTNAME}</b>
            </div>
            <div class="stat-row">
                <span class="stat-label">Статус плавающего VIP:</span>
                <span><b>{vip_status}</b></span>
            </div>
            <div class="stat-row">
                <span class="stat-label">Режим анализатора (Boot Mode):</span>
                <span><span class="badge blue">{boot_mode}</span></span>
            </div>
            <div class="stat-row">
                <span class="stat-label">Роль до перезагрузки:</span>
                <span>{last_role}</span>
            </div>
        </div>

        <div class="card">
            <h3>🗄️ Бэкенд PostgreSQL (via HAProxy :{HAPROXY_PORT})</h3>
            <div class="stat-row">
                <span class="stat-label">Подключение к пулу:</span>
                <span>{conn_badge}</span>
            </div>
            {pg_details_html}
        </div>
    </div>

    <div class="grid">
        <div class="card">
            <h3>📡 Физические слоты (pg_replication_slots)</h3>
            <table>
                <tr><th>Имя слота</th><th>Активность</th><th>WAL Status</th></tr>
                {slots_html}
            </table>
        </div>
        <div class="card">
            <h3>👥 Подключенные Standby (pg_stat_replication)</h3>
            <table>
                <tr><th>Application</th><th>IP</th><th>Состояние</th><th>Lag</th></tr>
                {repl_html}
            </table>
        </div>
    </div>

    <div class="card">
        <h3>💓 Последние записи демона heartbeat (интервал: 3 сек.)</h3>
        <table>
            <tr><th>ID</th><th>Время БД</th><th>Пишущий узел</th><th>Payload</th><th>Возраст записи</th></tr>
            {rows_html}
        </table>
    </div>
</div>
</body>
</html>"""

        encoded = html_body.encode("utf-8")
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(encoded)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(encoded)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, format, *args):
        return

if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", 8080), AppHandler)
    server.serve_forever()
EOF

chmod +x /usr/local/bin/my-app.py

echo "[5/5] Регистрация systemd юнитов (Restart=no для управления через Pacemaker)..."

# Демон heartbeat
cat << EOF > /etc/systemd/system/${DAEMON_SERVICE}.service
[Unit]
Description=Cluster Test Heartbeat Daemon
After=network.target

[Service]
Type=simple
User=postgres
EnvironmentFile=-/etc/default/ha-cluster
Environment=PGPASSFILE=${PGPASS_DEMO}
ExecStart=/usr/local/bin/my-daemon.py
Restart=no

[Install]
WantedBy=multi-user.target
EOF

# Веб-приложение
cat << EOF > /etc/systemd/system/${APP_SERVICE}.service
[Unit]
Description=Cluster Test Web App
After=network.target

[Service]
Type=simple
User=postgres
EnvironmentFile=-/etc/default/ha-cluster
Environment=PGPASSFILE=${PGPASS_DEMO}
ExecStart=/usr/local/bin/my-app.py
Restart=no

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl reset-failed "${APP_SERVICE}.service" "${DAEMON_SERVICE}.service" 2>/dev/null || true
systemctl disable "${APP_SERVICE}.service" "${DAEMON_SERVICE}.service" 2>/dev/null || true
systemctl stop "${APP_SERVICE}.service" "${DAEMON_SERVICE}.service" 2>/dev/null || true

echo "[УСПЕХ] Тестовые сервисы $APP_SERVICE и $DAEMON_SERVICE подготовлены."
echo "[INFO] Управление сервисами передается кластеру Pacemaker."