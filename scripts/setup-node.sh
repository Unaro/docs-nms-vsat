#!/usr/bin/env bash
# =============================================================================
# ПОДГОТОВКА ИНФРАСТРУКТУРЫ УЗЛА КЛАСТЕРА (ТОЛЬКО СИСТЕМА, PGSQL, HAPROXY)
# Управление ролью: явный флаг --master или --standby
# =============================================================================
set -euo pipefail

ENV_FILE="/etc/default/ha-cluster"
LOG_FILE="/var/log/setup-node.log"

exec > >(tee -a "$LOG_FILE") 2>&1

# 1. Валидация аргументов запуска
NODE_ROLE=""
case "${1:-}" in
  --master)
    NODE_ROLE="MASTER"
    ;;
  --standby)
    NODE_ROLE="STANDBY"
    ;;
  --stop-master)
    NODE_ROLE="STOP_MASTER"
    ;;
  *)
    echo "[ОШИБКА] Укажите роль узла явно:"
    echo "  sudo $0 --master       (node1, инициализация и временный запуск master)"
    echo "  sudo $0 --standby      (node2, pg_basebackup с node1)"
    echo "  sudo $0 --stop-master  (node1, остановить временный master после standby)"
    exit 1
    ;;
esac

if [[ $EUID -ne 0 ]]; then
  echo "[ОШИБКА] Скрипт должен запускаться с правами root!"
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "[ОШИБКА] Файл $ENV_FILE не найден! Сначала выполните configure-ha.sh."
  exit 1
fi
source "$ENV_FILE"

if [[ "$NODE_ROLE" == "STOP_MASTER" ]]; then
  echo "====================================================================="
  echo " Остановка временного master на $(hostname)"
  echo "====================================================================="

  sudo -u postgres "$PGBIN/pg_ctl" \
    -D "$PGDATA" \
    stop -m fast -w -t 60 2>/dev/null || true

  if sudo -u postgres "$PGBIN/pg_ctl" -D "$PGDATA" status >/dev/null 2>&1; then
    echo "[WARN] PostgreSQL всё ещё запущен, применяю immediate stop..."
    sudo -u postgres "$PGBIN/pg_ctl" \
      -D "$PGDATA" \
      stop -m immediate -w -t 30 2>/dev/null || true
  fi

  if pgrep -u postgres -f "postgres -D $PGDATA" >/dev/null 2>&1; then
    echo "[ОШИБКА] Не удалось остановить временный master."
    exit 1
  fi

  echo "[УСПЕХ] Временный master остановлен."
  exit 0
fi

echo "====================================================================="
echo " Запуск настройки узла $(hostname) в роли: $NODE_ROLE"
echo "====================================================================="

# 2. Очистка и фиксация /etc/hosts
sed -i '/127.0.1.1/d' /etc/hosts
sed -i '/# --- HA-CLUSTER-HOSTS-BEGIN ---/,/# --- HA-CLUSTER-HOSTS-END ---/d' /etc/hosts
cat << EOF >> /etc/hosts
# --- HA-CLUSTER-HOSTS-BEGIN ---
$NODE1_RING0_IP    ${NODE1_NAME}-ring0 $NODE1_NAME
$NODE2_RING0_IP    ${NODE2_NAME}-ring0 $NODE2_NAME
$NODE1_RING1_IP    ${NODE1_NAME}-ring1
$NODE2_RING1_IP    ${NODE2_NAME}-ring1
# --- HA-CLUSTER-HOSTS-END ---
EOF

# 3. Тюнинг ядра для отказоустойчивости
cat << 'EOF' > /etc/sysctl.d/99-ha-cluster.conf
kernel.hung_task_timeout_secs = 45
kernel.hung_task_panic = 1
kernel.panic = 5
kernel.panic_on_oops = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_mtu_probing = 1
fs.file-max = 2097152
EOF
sysctl --system >/dev/null 2>&1 || true

# 4. Файл паролей .pgpass и пароль для pcsd
mkdir -p "$(dirname "$PGPASS_FILE")"
echo "*:${DB_PORT}:*:${REPL_USER}:${REPL_PASS}" > "$PGPASS_FILE"
chown postgres:postgres "$PGPASS_FILE" 2>/dev/null || true
chmod 0600 "$PGPASS_FILE"

echo "hacluster:${HACLUSTER_PASS}" | chpasswd 2>/dev/null || true

# 5. Скрипт проверки роли для балансировщика (с вычитыванием stdin и чистым ответом)
cat << 'EOF' > /usr/local/bin/db-role-check.sh
#!/bin/bash
# 1. Вычитываем входящий HTTP-запрос из stdin для предотвращения TCP RST в HAProxy
while read -r line; do
  line=$(echo "$line" | tr -d '\r')
  [[ -z "$line" ]] && break
done

DB_PORT="${DB_PORT:-5432}"
PGBIN="${PGBIN:-/usr/lib/postgresql/16/bin}"
PSQL_CMD="$PGBIN/psql"
if ! command -v "$PSQL_CMD" >/dev/null 2>&1; then
  PSQL_CMD="psql"
fi

# 2. Таймаут через PGOPTIONS исключает паразитный вывод команды SET
OUT=$(timeout 2 env PGOPTIONS="-c statement_timeout=1500ms" "$PSQL_CMD" \
  -h /var/run/postgresql -p "$DB_PORT" -U postgres -d postgres -tAc \
  "SELECT pg_is_in_recovery();" -X 2>/dev/null | tail -n 1 || echo "err")
OUT=$(echo "$OUT" | tr -d '[:space:]')

if [[ "$OUT" == "f" ]]; then
  IS_RO=$(timeout 2 env PGOPTIONS="-c statement_timeout=1500ms" "$PSQL_CMD" \
    -h /var/run/postgresql -p "$DB_PORT" -U postgres -d postgres -tAc \
    "SHOW transaction_read_only;" -X 2>/dev/null | tail -n 1 || echo "on")
  IS_RO=$(echo "$IS_RO" | tr -d '[:space:]')
  if [[ "$IS_RO" == "off" ]]; then
    printf "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 8\r\nConnection: close\r\n\r\nMaster\r\n"
    exit 0
  fi
fi

printf "HTTP/1.1 503 Service Unavailable\r\nContent-Type: text/plain\r\nContent-Length: 7\r\nConnection: close\r\n\r\nSlave\r\n"
exit 1
EOF
chmod +x /usr/local/bin/db-role-check.sh

# 6. Сокет db-role-check (порт DB_CHECK_PORT)
cat << EOF > /etc/systemd/system/db-role-check.socket
[Unit]
Description=PostgreSQL Role Check Socket for HAProxy
[Socket]
ListenStream=${DB_CHECK_PORT}
Accept=yes
LogLevelMax=warning
[Install]
WantedBy=sockets.target
EOF

cat << 'EOF' > /etc/systemd/system/db-role-check@.service
[Unit]
Description=PostgreSQL Role Check Handler
Requires=db-role-check.socket
[Service]
User=postgres
Group=postgres
EnvironmentFile=/etc/default/ha-cluster
ExecStart=/usr/local/bin/db-role-check.sh
StandardInput=socket
StandardOutput=socket
StandardError=null
LogLevelMax=warning
LimitNOFILE=65536
EOF

# 7. Конфигурация HAProxy
cat << EOF > /etc/haproxy/haproxy.cfg
global
  log /dev/log local0 warning
  maxconn 500
  user haproxy
  group haproxy
  daemon

defaults
  log     global
  mode    tcp
  option  tcplog
  retries 3
  timeout queue   1m
  timeout connect 5s
  timeout client  30m
  timeout server  30m
  timeout check   2s

listen postgres_master
  bind 127.0.0.1:${HAPROXY_DB_BIND_PORT}
  mode tcp
  option httpchk GET /
  http-check expect status 200
  default-server inter 2s fall 2 rise 2 on-marked-down shutdown-sessions

  server node1_db_r0 ${NODE1_RING0_IP}:${DB_PORT} maxconn 100 check port ${DB_CHECK_PORT}
  server node2_db_r0 ${NODE2_RING0_IP}:${DB_PORT} maxconn 100 check port ${DB_CHECK_PORT}
  server node1_db_r1 ${NODE1_RING1_IP}:${DB_PORT} maxconn 100 check port ${DB_CHECK_PORT} backup
  server node2_db_r1 ${NODE2_RING1_IP}:${DB_PORT} maxconn 100 check port ${DB_CHECK_PORT} backup
EOF

# Функция записи директив PostgreSQL
configure_postgres_files() {
  if [[ ! -f "${PGDATA}/postgresql.conf" || ! -f "${PGDATA}/pg_hba.conf" ]]; then
    echo "[ОШИБКА] В PGDATA=${PGDATA} отсутствуют postgresql.conf или pg_hba.conf."
    exit 1
  fi

  # Удаляем старые блоки параметров
  sed -i '/# --- HA-CLUSTER-PG-BEGIN ---/,/# --- HA-CLUSTER-PG-END ---/d' "${PGDATA}/postgresql.conf"
  sed -i '/unix_socket_directories/d' "${PGDATA}/postgresql.conf"

  cat << EOF >> "${PGDATA}/postgresql.conf"
# --- HA-CLUSTER-PG-BEGIN ---
listen_addresses = '*'
unix_socket_directories = '/var/run/postgresql, /tmp'
max_connections = ${MAX_CONNECTIONS}
shared_buffers = 256MB
wal_level = replica
wal_log_hints = on
full_page_writes = on
track_commit_timestamp = on
hot_standby = on
hot_standby_feedback = on
superuser_reserved_connections = 3
max_slot_wal_keep_size = ${MAX_SLOT_WAL_KEEP_SIZE}
wal_keep_size = ${WAL_KEEP_SIZE}
password_encryption = scram-sha-256
idle_in_transaction_session_timeout = '15000ms'
statement_timeout = '30000ms'
lock_timeout = '5000ms'
tcp_keepalives_idle = 15
tcp_keepalives_interval = 5
tcp_keepalives_count = 3
# --- HA-CLUSTER-PG-END ---
EOF

  # Полная чистая перезапись pg_hba.conf
  cat << EOF > "${PGDATA}/pg_hba.conf"
# --- HA-REPLICATION-RULES ---
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust

host    all             all             10.0.0.0/24             trust
host    all             all             192.168.0.0/16          trust

local   replication     all                                     trust
host    replication     ${REPL_USER}    127.0.0.1/32            trust
host    replication     ${REPL_USER}    ::1/128                 trust
host    replication     ${REPL_USER}    10.0.0.0/24             trust
host    replication     ${REPL_USER}    192.168.0.0/16          trust
# --- HA-REPLICATION-END ---
EOF
}

# Гарантируем права на каталог сокетов Unix
mkdir -p /var/run/postgresql
chown -R postgres:postgres /var/run/postgresql
chmod 2775 /var/run/postgresql

# Останавливаем системные демоны перед началом работ
systemctl stop postgresql "postgresql@${PG_VERSION}-main" 2>/dev/null || true

# 8. Ветвление подготовки базы по переданному флагу
if [[ "$NODE_ROLE" == "MASTER" ]]; then
  echo "--- [MASTER] Инициализация каталога PGDATA и создание репликационной роли ---"

  if [[ ! -f "$PGDATA/PG_VERSION" || ! -f "$PGDATA/postgresql.conf" || ! -f "$PGDATA/pg_hba.conf" ]]; then
    echo "[INFO] Инициализирую PostgreSQL в каталоге: $PGDATA"
    mkdir -p "$(dirname "$PGDATA")"
    rm -rf "$PGDATA"
    mkdir -p "$PGDATA"
    chown postgres:postgres "$PGDATA"
    chmod 0700 "$PGDATA"

    sudo -u postgres "$PGBIN/initdb" \
      -D "$PGDATA" \
      -k \
      -E UTF8 \
      --locale=C
  else
    echo "[INFO] Каталог $PGDATA уже инициализирован, обновляю параметры HA..."
  fi

  configure_postgres_files

  touch "$PGDATA/postgresql.auto.conf"
  sed -i '/primary_conninfo/d' "$PGDATA/postgresql.auto.conf" 2>/dev/null || true
  cat << EOF >> "$PGDATA/postgresql.auto.conf"
primary_conninfo = 'host=${NODE2_RING0_IP} port=${DB_PORT} user=${REPL_USER} passfile=${PGPASS_FILE} application_name=${NODE1_NAME}'
EOF
  chown postgres:postgres "$PGDATA/postgresql.auto.conf"
  chmod 0600 "$PGDATA/postgresql.auto.conf"

  echo "[INFO] Запускаю временный master для создания репликации и slots..."
  if ! sudo -u postgres "$PGBIN/pg_ctl" \
    -D "$PGDATA" \
    -l "$PGDATA/setup-master.log" \
    -o "-p $DB_PORT -c listen_addresses='*'" \
    start -w -t 60; then
    echo "=== ОШИБКА ЗАПУСКА POSTGRESQL ==="
    cat "$PGDATA/setup-master.log" 2>/dev/null || true
    exit 1
  fi

  sudo -u postgres "$PGBIN/psql" -h /var/run/postgresql -p "$DB_PORT" -d postgres -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${REPL_USER}') THEN
      CREATE ROLE ${REPL_USER} WITH REPLICATION LOGIN PASSWORD '${REPL_PASS}';
  ELSE
      ALTER ROLE ${REPL_USER} WITH REPLICATION LOGIN PASSWORD '${REPL_PASS}';
  END IF;
END
\$\$;

GRANT pg_read_all_data TO ${REPL_USER};
GRANT pg_read_server_files TO ${REPL_USER};
GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text) TO ${REPL_USER};
GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean) TO ${REPL_USER};
GRANT EXECUTE ON FUNCTION pg_catalog.pg_stat_file(text, boolean) TO ${REPL_USER};
GRANT EXECUTE ON FUNCTION pg_catalog.pg_ls_dir(text, boolean, boolean) TO ${REPL_USER};


# SELECT pg_create_physical_replication_slot('${REPL_SLOT_NODE1}', true)
# WHERE NOT EXISTS (
#   SELECT 1 FROM pg_replication_slots WHERE slot_name = '${REPL_SLOT_NODE1}'
# );

# SELECT pg_create_physical_replication_slot('${REPL_SLOT_NODE2}', true)
# WHERE NOT EXISTS (
#   SELECT 1 FROM pg_replication_slots WHERE slot_name = '${REPL_SLOT_NODE2}'
# );
SQL

  echo "[INFO] Временный master запущен и слушает порт $DB_PORT."
  echo "[INFO] Теперь на node2 выполните:"
  echo "       sudo $0 --standby"
  echo "[INFO] После успешного standby вернитесь на node1 и выполните:"
  echo "       sudo $0 --stop-master"

elif [[ "$NODE_ROLE" == "STANDBY" ]]; then
  echo "--- [STANDBY] Клонирование базы данных с мастера ($NODE1_RING0_IP) ---"

  TARGET_MASTER_IP="$NODE1_RING0_IP"

  echo "Проверка доступности порта $DB_PORT на мастере $TARGET_MASTER_IP..."
  MASTER_READY=0
  for i in {1..30}; do
    if timeout 2 bash -c "</dev/tcp/${TARGET_MASTER_IP}/${DB_PORT}" 2>/dev/null; then
      MASTER_READY=1
      break
    fi
    echo "Попытка $i/30: порт $DB_PORT на $TARGET_MASTER_IP ещё недоступен, ждем..."
    sleep 2
  done

  if [[ "$MASTER_READY" -ne 1 ]]; then
    echo "[ОШИБКА] Master $TARGET_MASTER_IP:$DB_PORT недоступен."
    echo "Сначала запустите на node1: sudo $0 --master"
    exit 1
  fi

  mkdir -p "$(dirname "$PGDATA")"
  rm -rf "${PGDATA:?}"/*
  mkdir -p "$PGDATA"
  chown postgres:postgres "$PGDATA"
  chmod 0700 "$PGDATA"

  sudo -u postgres PGPASSFILE="$PGPASS_FILE" "$PGBIN/pg_basebackup" \
    -h "$TARGET_MASTER_IP" \
    -p "$DB_PORT" \
    -U "$REPL_USER" \
    -D "$PGDATA" \
    -Fp -Xs -P -R \
    -S "$REPL_SLOT_NODE2"

  if [[ ! -f "$PGDATA/PG_VERSION" ]]; then
    echo "[ОШИБКА] После pg_basebackup отсутствует $PGDATA/PG_VERSION"
    exit 1
  fi

  if [[ ! -f "$PGDATA/standby.signal" ]]; then
    touch "$PGDATA/standby.signal"
  fi

  # Фиксируем application_name для Pacemaker/pgsqlms
  touch "$PGDATA/postgresql.auto.conf"
  sed -i '/primary_conninfo/d' "$PGDATA/postgresql.auto.conf" 2>/dev/null || true
  cat << EOF >> "$PGDATA/postgresql.auto.conf"
primary_conninfo = 'host=${TARGET_MASTER_IP} port=${DB_PORT} user=${REPL_USER} passfile=${PGPASS_FILE} application_name=${NODE2_NAME}'
EOF

  configure_postgres_files

  chown -R postgres:postgres "$PGDATA"
  chmod 0700 "$PGDATA"

  echo "[УСПЕХ] Standby-каталог подготовлен на $(hostname)."
  echo "[INFO] Выполните на node1: sudo $0 --stop-master"
fi

# 9. Фиксация служб в systemd
systemctl daemon-reload

# Отключаем автозапуск системных сервисов (управление передается Pacemaker)
for svc in postgresql "postgresql@${PG_VERSION}-main" haproxy; do
  systemctl disable "$svc" 2>/dev/null || true
  if [[ "$NODE_ROLE" != "MASTER" ]]; then
    systemctl stop "$svc" 2>/dev/null || true
  fi
done

systemctl enable db-role-check.socket pcsd.service 2>/dev/null || true
systemctl restart db-role-check.socket pcsd.service 2>/dev/null || true

echo "====================================================================="
echo "[УСПЕХ] Узел $(hostname) успешно настроен в роли $NODE_ROLE!"
echo "====================================================================="