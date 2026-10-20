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
  *)
    echo "[ОШИБКА] Укажите роль узла явно:"
    echo "  sudo $0 --master   (запускается на node1)"
    echo "  sudo $0 --standby  (запускается на node2)"
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

# 5. Скрипт проверки роли для балансировщика
cat << 'EOF' > /usr/local/bin/db-role-check.sh
#!/bin/bash
DB_PORT="${DB_PORT:-5432}"
SQL="SET statement_timeout='1500ms'; SELECT pg_is_in_recovery();"
OUT=$(timeout 2 psql -p "$DB_PORT" -d postgres -tAc "$SQL" -X 2>/dev/null || echo "err")
OUT=$(echo "$OUT" | tr -d '[:space:]')

if [[ "$OUT" == "f" ]]; then
  IS_RO=$(timeout 2 psql -p "$DB_PORT" -d postgres -tAc "SHOW transaction_read_only;" -X 2>/dev/null || echo "on")
  IS_RO=$(echo "$IS_RO" | tr -d '[:space:]')
  if [[ "$IS_RO" == "off" ]]; then
    printf "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 6\r\nConnection: close\r\n\r\nMaster"
    exit 0
  fi
fi
printf "HTTP/1.1 503 Service Unavailable\r\nContent-Type: text/plain\r\nContent-Length: 5\r\nConnection: close\r\n\r\nSlave"
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
EnvironmentFile=/etc/default/ha-cluster
ExecStart=/usr/local/bin/db-role-check.sh
StandardInput=socket
StandardOutput=socket
StandardError=null
LogLevelMax=warning
LimitNOFILE=65536
EOF

# 7. Конфигурация HAProxy (локальный порт HAPROXY_DB_BIND_PORT -> 5432)
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

# Функция записи кластерных директив в postgresql.conf и pg_hba.conf
configure_postgres_files() {
  sed -i '/# --- HA-CLUSTER-PG-BEGIN ---/,/# --- HA-CLUSTER-PG-END ---/d' "${PGDATA}/postgresql.conf"
  cat << EOF >> "${PGDATA}/postgresql.conf"
# --- HA-CLUSTER-PG-BEGIN ---
listen_addresses = '*'
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
idle_in_transaction_session_timeout = '15000ms'
statement_timeout = '30000ms'
lock_timeout = '5000ms'
tcp_keepalives_idle = 15
tcp_keepalives_interval = 5
tcp_keepalives_count = 3
# --- HA-CLUSTER-PG-END ---
EOF

  sed -i '/# --- HA-REPLICATION-RULES ---/,/# --- HA-REPLICATION-END ---/d' "${PGDATA}/pg_hba.conf"
  cat << EOF >> "${PGDATA}/pg_hba.conf"
# --- HA-REPLICATION-RULES ---
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    all             all             10.0.0.0/24             md5
host    all             all             192.168.0.0/16          md5
host    replication     ${REPL_USER}    127.0.0.1/32            md5
host    replication     ${REPL_USER}    10.0.0.0/24             md5
host    replication     ${REPL_USER}    192.168.0.0/16          md5
# --- HA-REPLICATION-END ---
EOF
}

# 8. Ветвление подготовки базы по переданному флагу
systemctl stop postgresql "postgresql@${PG_VERSION}-main" 2>/dev/null || true

if [[ "$NODE_ROLE" == "MASTER" ]]; then
  echo "--- [MASTER] Инициализация каталога PGDATA и создание ролей ---"
  if [[ ! -f "$PGDATA/PG_VERSION" ]]; then
    mkdir -p "$(dirname "$PGDATA")"
    rm -rf "$PGDATA"
    sudo -u postgres "$PGBIN/initdb" -D "$PGDATA" -k -E UTF8 --locale=C.UTF-8
  fi

  configure_postgres_files

  # Запуск временного инстанса PostgreSQL для генерации слотов и ролей
  sudo -u postgres "$PGBIN/pg_ctl" -D "$PGDATA" -o "-p $DB_PORT -c listen_addresses='*'" start -w -t 60

  sudo -u postgres "$PGBIN/psql" -p "$DB_PORT" -d postgres -c "
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
  SELECT pg_create_physical_replication_slot('${REPL_SLOT_NODE1}', true) WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = '${REPL_SLOT_NODE1}');
  SELECT pg_create_physical_replication_slot('${REPL_SLOT_NODE2}', true) WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = '${REPL_SLOT_NODE2}');
  "

  echo "[INFO] Мастер временно запущен на порту $DB_PORT для возможности снятия pg_basebackup нодой standby."

elif [[ "$NODE_ROLE" == "STANDBY" ]]; then
  echo "--- [STANDBY] Клонирование базы данных с мастера ($NODE1_RING0_IP) ---"
  
  TARGET_MASTER_IP="$NODE1_RING0_IP"
  echo "Проверка доступности порта $DB_PORT на мастере $TARGET_MASTER_IP..."
  for i in {1..15}; do
    if timeout 2 bash -c "</dev/tcp/${TARGET_MASTER_IP}/${DB_PORT}" 2>/dev/null; then
      break
    fi
    echo "Попытка $i/15: порт $DB_PORT на $TARGET_MASTER_IP ещё недоступен, ждем..."
    sleep 2
  done

  rm -rf "${PGDATA:?}"/*
  mkdir -p "$PGDATA"
  chown postgres:postgres "$PGDATA"
  chmod 0700 "$PGDATA"

  sudo -u postgres PGPASSFILE="$PGPASS_FILE" "$PGBIN/pg_basebackup" \
    -h "$TARGET_MASTER_IP" \
    -p "$DB_PORT" \
    -U "$REPL_USER" \
    -D "$PGDATA" \
    -Fp -Xs -R \
    -S "$REPL_SLOT_NODE2"

  touch "$PGDATA/standby.signal"
  chown postgres:postgres "$PGDATA/standby.signal"

  configure_postgres_files
fi

# 9. Фиксация служб в systemd: отключаем прямой автозапуск того, чем будет рулить Pacemaker
systemctl daemon-reload
for svc in postgresql "postgresql@${PG_VERSION}-main" haproxy; do
  systemctl disable "$svc" 2>/dev/null || true
  systemctl stop "$svc" 2>/dev/null || true
done

systemctl enable --now db-role-check.socket pcsd.service 2>/dev/null || true

echo "====================================================================="
echo "[УСПЕХ] Узел $(hostname) успешно настроен в роли $NODE_ROLE!"
echo "====================================================================="