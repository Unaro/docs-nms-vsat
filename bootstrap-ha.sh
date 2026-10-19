#!/bin/bash
# =============================================================================
# УНИВЕРСАЛЬНЫЙ СКРИПТ РАЗВЕРТЫВАНИЯ ДВУХУЗЛОВОГО HA-КЛАСТЕРА (NODE1 / NODE2)
# =============================================================================
set -euo pipefail

ENV_FILE="/etc/default/ha-cluster"

if [[ $EUID -ne 0 ]]; then
  echo "[ОШИБКА] Запустите скрипт с правами root: sudo $0"
  exit 1
fi

# -----------------------------------------------------------------------------
# ШАГ 1. Создание шаблона /etc/default/ha-cluster (при первом запуске)
# -----------------------------------------------------------------------------
if [[ ! -f "$ENV_FILE" ]]; then
  echo "[INFO] Файл $ENV_FILE не найден. Создаю шаблон конфигурации..."
  cat << 'EOF' > "$ENV_FILE"
# =========================================================================
# ЕДИНЫЙ КОНФИГ ПАРАМЕТРОВ КЛАСТЕРА
# =========================================================================
# 1. Имена узлов и сетевые интерфейсы
NODE1_NAME="node1"
NODE2_NAME="node2"
RING0_NIC="eth1"                # Интерфейс прямого патч-корда между серверами (Ring 0)
CLUSTER_VIP_NIC="eth0"          # Интерфейс в сторону маршрутизатора (Ring 1 и VIP)

# 2. IP-адреса узлов (Кольцо 0 - прямой кабель, Кольцо 1 - сеть маршрутизатора)
NODE1_RING0_IP="10.0.0.1"
NODE2_RING0_IP="10.0.0.2"
NODE1_RING1_IP="192.168.1.11"
NODE2_RING1_IP="192.168.1.12"

# 3. Маршрутизатор (псевдо-арбитр) и плавающий Виртуальный IP (VIP)
ROUTER_IPS="192.168.1.1"
CLUSTER_VIP="192.168.1.100"
CLUSTER_VIP_CIDR="24"

# 4. Параметры PostgreSQL и HAProxy
PG_VERSION="16"
PGDATA="/var/lib/postgresql/16/main"
PGBIN="/usr/lib/postgresql/16/bin"
DB_PORT="5432"
DB_CHECK_PORT="9200"
HAPROXY_DB_BIND_PORT="5000"
REPL_USER="repl_user"
REPL_PASS="ReplSecretPass!"
PGPASS_FILE="/var/lib/postgresql/.pgpass"
REPL_SLOT_NODE1="slot_node1"
REPL_SLOT_NODE2="slot_node2"
MAX_SLOT_WAL_KEEP_SIZE="5GB"
WAL_KEEP_SIZE="512MB"
MAX_CONNECTIONS="100"

# 5. Имена systemd-сервисов вашего приложения и демона
APP_SERVICE="my-app"
DAEMON_SERVICE="my-daemon"
APP_MEMORY_MAX="75%"
APP_CPU_QUOTA="80%"

# 6. Таймауты и пороги безопасности
COROSYNC_TOKEN_MS="3000"
MIN_FREE_DISK_PCT="5"
MIN_FREE_CIB_MB="500"
COLD_START_TIMEOUT_SEC="180"
CRASH_TIMEOUT_SEC="900"
NODE2_ASYMMETRIC_DELAY_SEC="120"
FAILURE_TIMEOUT_SEC="900s"

# 7. Служебный файл режима загрузки и пароль кластера
BOOT_MODE_FILE="/run/cluster_boot_mode"
HACLUSTER_PASS="StrongClusterPass123!"
EOF
  chmod 600 "$ENV_FILE"
  echo "[ГОТОВО] Создан шаблон $ENV_FILE."
  echo "Проверьте в нем IP-адреса и названия ваших сервисов, затем запустите скрипт повторно!"
  exit 0
fi

source "$ENV_FILE"

# Безопасные дефолты параметров
RING0_NIC="${RING0_NIC:-eth1}"
CLUSTER_VIP_NIC="${CLUSTER_VIP_NIC:-eth0}"
ROUTER_IPS="${ROUTER_IPS:-192.168.1.1}"
PG_VERSION="${PG_VERSION:-16}"
PGDATA="${PGDATA:-/var/lib/postgresql/16/main}"
PGBIN="${PGBIN:-/usr/lib/postgresql/16/bin}"
DB_PORT="${DB_PORT:-5432}"
DB_CHECK_PORT="${DB_CHECK_PORT:-9200}"
HAPROXY_DB_BIND_PORT="${HAPROXY_DB_BIND_PORT:-5000}"
REPL_USER="${REPL_USER:-repl_user}"
REPL_PASS="${REPL_PASS:-ReplSecretPass!}"
PGPASS_FILE="${PGPASS_FILE:-/var/lib/postgresql/.pgpass}"
REPL_SLOT_NODE1="${REPL_SLOT_NODE1:-slot_node1}"
REPL_SLOT_NODE2="${REPL_SLOT_NODE2:-slot_node2}"
MAX_SLOT_WAL_KEEP_SIZE="${MAX_SLOT_WAL_KEEP_SIZE:-5GB}"
WAL_KEEP_SIZE="${WAL_KEEP_SIZE:-512MB}"
MAX_CONNECTIONS="${MAX_CONNECTIONS:-100}"
COROSYNC_TOKEN_MS="${COROSYNC_TOKEN_MS:-3000}"
MIN_FREE_DISK_PCT="${MIN_FREE_DISK_PCT:-5}"
MIN_FREE_CIB_MB="${MIN_FREE_CIB_MB:-500}"
COLD_START_TIMEOUT_SEC="${COLD_START_TIMEOUT_SEC:-180}"
CRASH_TIMEOUT_SEC="${CRASH_TIMEOUT_SEC:-900}"
NODE2_ASYMMETRIC_DELAY_SEC="${NODE2_ASYMMETRIC_DELAY_SEC:-120}"
FAILURE_TIMEOUT_SEC="${FAILURE_TIMEOUT_SEC:-900s}"
BOOT_MODE_FILE="${BOOT_MODE_FILE:-/run/cluster_boot_mode}"

# -----------------------------------------------------------------------------
# ШАГ 2. Автоопределение узла, настройка /etc/hosts и .pgpass
# -----------------------------------------------------------------------------

CURRENT_NODE=""
for _attempt in {1..10}; do
  LOCAL_IPS=$(hostname -I 2>/dev/null || true)
  if [[ " $LOCAL_IPS " == *" $NODE1_RING0_IP "* ]] || [[ " $LOCAL_IPS " == *" $NODE1_RING1_IP "* ]]; then
    CURRENT_NODE="$NODE1_NAME"
    PEER_NODE="$NODE2_NAME"
    PEER_RING0_IP="$NODE2_RING0_IP"
    PEER_RING1_IP="$NODE2_RING1_IP"
    MY_SLOT="$REPL_SLOT_NODE1"
    break
  elif [[ " $LOCAL_IPS " == *" $NODE2_RING0_IP "* ]] || [[ " $LOCAL_IPS " == *" $NODE2_RING1_IP "* ]]; then
    CURRENT_NODE="$NODE2_NAME"
    PEER_NODE="$NODE1_NAME"
    PEER_RING0_IP="$NODE1_RING0_IP"
    PEER_RING1_IP="$NODE1_RING1_IP"
    MY_SLOT="$REPL_SLOT_NODE2"
    break
  fi
  echo "[WARN] IP ещё не определены, попытка $_attempt/10..."
  sleep 2
done

if [[ -z "$CURRENT_NODE" ]]; then
  echo "[ОШИБКА] Локальные IP ($LOCAL_IPS) не совпадают с NODE1/NODE2 в $ENV_FILE!"
  exit 1
fi

echo "[INFO] Настройка выполняется на узле: $CURRENT_NODE (сосед: $PEER_NODE)"

sed -i '/# --- HA-CLUSTER-HOSTS-BEGIN ---/,/# --- HA-CLUSTER-HOSTS-END ---/d' /etc/hosts
cat << EOF >> /etc/hosts
# --- HA-CLUSTER-HOSTS-BEGIN ---
$NODE1_RING0_IP    ${NODE1_NAME}-ring0 $NODE1_NAME
$NODE2_RING0_IP    ${NODE2_NAME}-ring0 $NODE2_NAME
$NODE1_RING1_IP    ${NODE1_NAME}-ring1
$NODE2_RING1_IP    ${NODE2_NAME}-ring1
# --- HA-CLUSTER-HOSTS-END ---
EOF

# Создаем .pgpass с правами 0600 для беспарольной работы репликации,
# pg_rewind и pg_basebackup.
# ВАЖНО: на мастере:
#   GRANT pg_read_all_data TO ${REPL_USER};
mkdir -p "$(dirname "$PGPASS_FILE")"
echo "*:${DB_PORT}:*:${REPL_USER}:${REPL_PASS}" > "$PGPASS_FILE"
chown postgres:postgres "$PGPASS_FILE" 2>/dev/null || true
chmod 0600 "$PGPASS_FILE"

# -----------------------------------------------------------------------------
# ШАГ 3. Базовые настройки ядра (sysctl), диска и сброса зависших TCP-сессий
# -----------------------------------------------------------------------------
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

ROOT_DEV=$(findmnt -n -o SOURCE /var/lib/pacemaker 2>/dev/null || findmnt -n -o SOURCE / 2>/dev/null || true)
if [[ "$ROOT_DEV" == /dev/* ]]; then
  tune2fs -m 2 "$ROOT_DEV" >/dev/null 2>&1 || true
fi

if command -v iptables >/dev/null 2>&1; then
  if ! iptables -C INPUT -p tcp -m conntrack --ctstate INVALID -j REJECT --reject-with tcp-reset 2>/dev/null; then
    iptables -I INPUT 1 -p tcp -m conntrack --ctstate INVALID -j REJECT --reject-with tcp-reset 2>/dev/null || true
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save 2>/dev/null || true
  fi
fi

# Настройки в postgresql.conf
if [[ -f "${PGDATA}/postgresql.conf" ]]; then
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
fi

# -----------------------------------------------------------------------------
# ШАГ 4. Создание 3 рабочих скриптов кластера
# -----------------------------------------------------------------------------
echo "[INFO] Создаю рабочие скрипты кластера..."

# 4.1 Скрипт проверки роли БД для HAProxy
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

# 4.2 Предстартовый анализатор
cat << 'EOF' > /usr/local/sbin/cluster-boot-analyzer.sh
#!/bin/bash
set -euo pipefail
source /etc/default/ha-cluster

log_msg() { timeout 2 logger -t cluster-precheck "$1" || true; }
rm -f "$BOOT_MODE_FILE"

# 1. Права на ключ Corosync и .pgpass
if [[ -f /etc/corosync/authkey ]]; then
  chown root:root /etc/corosync/authkey
  chmod 0400 /etc/corosync/authkey
fi
if [[ -f "$PGPASS_FILE" ]]; then
  chown postgres:postgres "$PGPASS_FILE" 2>/dev/null || true
  chmod 0600 "$PGPASS_FILE"
fi

# 2. Проверка монтирования, записи, места и inodes
if [[ ! -f "$PGDATA/PG_VERSION" ]]; then
  log_msg "КРИТИЧЕСКАЯ ОШИБКА: Каталог БД ($PGDATA) отсутствует! Старт кластера заблокирован."
  exit 1
fi

TEST_FILE="$PGDATA/.cluster_rw_test"
if ! touch "$TEST_FILE" 2>/dev/null || ! rm -f "$TEST_FILE" 2>/dev/null; then
  log_msg "КРИТИЧЕСКАЯ ОШИБКА: Раздел БД ($PGDATA) в режиме Read-Only! Старт кластера заблокирован."
  exit 1
fi

USED_SPACE_PCT=$(df --output=pcent "$PGDATA" | tail -n 1 | tr -dc '0-9')
USED_INODE_PCT=$(df -i --output=ipcent "$PGDATA" | tail -n 1 | tr -dc '0-9')
if (( 100 - ${USED_SPACE_PCT:-100} < MIN_FREE_DISK_PCT )) || (( 100 - ${USED_INODE_PCT:-100} < MIN_FREE_DISK_PCT )); then
  log_msg "КРИТИЧЕСКАЯ ОШИБКА: Нехватка места (${USED_SPACE_PCT}%) или inodes (${USED_INODE_PCT}%) на диске БД!"
  exit 1
fi

CIB_FREE_MB=$(df -BM --output=avail /var/lib/pacemaker 2>/dev/null | tail -n 1 | tr -dc '0-9' || echo "1000")
if (( ${CIB_FREE_MB:-1000} < ${MIN_FREE_CIB_MB:-500} )); then
  journalctl --vacuum-size=100M >/dev/null 2>&1 || true
fi

# 3. Сверка с соседом
LOCAL_IPS=$(hostname -I)
if [[ " $LOCAL_IPS " == *" $NODE1_RING0_IP "* ]] || [[ " $LOCAL_IPS " == *" $NODE1_RING1_IP "* ]]; then
  PEER_IP="$NODE2_RING0_IP"
  PEER_ALT_IP="$NODE2_RING1_IP"
  MY_SLOT="$REPL_SLOT_NODE1"
else
  PEER_IP="$NODE1_RING0_IP"
  PEER_ALT_IP="$NODE1_RING1_IP"
  MY_SLOT="$REPL_SLOT_NODE2"
fi

ACTIVE_PEER_IP=""
for cip in "$PEER_IP" "$PEER_ALT_IP"; do
  if curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "http://${cip}:${DB_CHECK_PORT}" | grep -q "200"; then
    ACTIVE_PEER_IP="$cip"
    break
  fi
done

if [[ -n "$ACTIVE_PEER_IP" ]]; then
  log_msg "Обнаружен активный MASTER на соседе ($ACTIVE_PEER_IP). Проверяю состояние локальной реплики и WAL..."

  SLOT_STATUS=$(sudo -u postgres PGPASSFILE="$PGPASS_FILE" PGCONNECT_TIMEOUT=3 \
    psql -w -h "$ACTIVE_PEER_IP" -p "$DB_PORT" -U "$REPL_USER" -d postgres -tAc \
    "SELECT wal_status FROM pg_replication_slots WHERE slot_name='${MY_SLOT}';" 2>/dev/null || echo "ok")

  if [[ ! -f "$PGDATA/standby.signal" ]]; then
    # =================================================================
    # СЦЕНАРИЙ А: Мы до падения ТОЖЕ были MASTER
    # =================================================================
    log_msg "ВНИМАНИЕ: Локальная БД до выключения тоже была MASTER! Ищу точку расхождения с $ACTIVE_PEER_IP..."

    if [[ -f "$PGDATA/postmaster.pid" ]]; then
      OLD_PID=$(head -1 "$PGDATA/postmaster.pid")
      if ! kill -0 "$OLD_PID" 2>/dev/null; then
        rm -f "$PGDATA/postmaster.pid"
      fi
    fi

    sudo -u postgres "$PGBIN/pg_ctl" -D "$PGDATA" -o "-c listen_addresses=''" start -w -t 60 >/dev/null 2>&1 || true
    sudo -u postgres "$PGBIN/pg_ctl" -D "$PGDATA" stop -m fast -w -t 60 >/dev/null 2>&1 || true

    REWIND_OUT=$(timeout 60 sudo -u postgres PGPASSFILE="$PGPASS_FILE" "$PGBIN/pg_rewind" --dry-run \
      --target-pgdata="$PGDATA" \
      --source-server="host=$ACTIVE_PEER_IP port=$DB_PORT user=$REPL_USER dbname=postgres" 2>&1 || true)

    DIVERGE_LSN=$(echo "$REWIND_OUT" | awk '/diverged at WAL location/ {print $6}')

    if [[ -n "$DIVERGE_LSN" ]]; then
      log_msg "Обнаружено расхождение историй WAL! Последняя общая запись с Мастером: LSN $DIVERGE_LSN"
      BACKUP_DIR="/var/backups/postgresql_splitbrain"
      mkdir -p "$BACKUP_DIR"
      chown postgres:postgres "$BACKUP_DIR"
      TS=$(date +%Y%m%d_%H%M%S)
      SAFE_LSN="${DIVERGE_LSN//\//_}"
      DELTA_SQL="$BACKUP_DIR/delta_from_${SAFE_LSN}_${TS}.sql"
      FULL_DUMP="$BACKUP_DIR/full_diverged_${SAFE_LSN}_${TS}.sql.gz"

      FORK_TIME=$("$PGBIN/pg_waldump" -p "$PGDATA/pg_wal" -s "$DIVERGE_LSN" -n 200 2>/dev/null \
        | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+ [A-Z0-9+-]+' | head -n 1 || true)

      if [[ -z "$FORK_TIME" ]]; then
        LAST_HIST=$(ls -1t "$PGDATA"/pg_wal/*.history 2>/dev/null | head -n 1 || true)
        if [[ -n "$LAST_HIST" ]]; then
          FORK_TIME=$(date -d "@$(stat -c %Y "$LAST_HIST")" +"%Y-%m-%d %H:%M:%S%z")
        fi
      fi

      sudo -u postgres "$PGBIN/pg_ctl" -D "$PGDATA" -o "-c listen_addresses=''" start -w -t 60 >/dev/null 2>&1 || true

      if [[ -n "$FORK_TIME" ]]; then
        log_msg "Точка ветвления по времени: $FORK_TIME. Выгружаю дельту строк в $DELTA_SQL..."
        {
          echo "-- Автоматический дамп расхождения (Split-Brain Delta)"
          echo "-- Узел: $(hostname), Точка расхождения LSN: $DIVERGE_LSN, Время: $FORK_TIME"
          echo "SET session_replication_role = replica;"
        } > "$DELTA_SQL"

        DB_LIST=$(sudo -u postgres "$PGBIN/psql" -p "$DB_PORT" -U postgres -d postgres -tAc \
          "SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres';" 2>/dev/null || true)

        for dbname in $DB_LIST; do
          echo "\\connect $dbname" >> "$DELTA_SQL"
          sudo -u postgres "$PGBIN/psql" -p "$DB_PORT" -U postgres -d "$dbname" -tAc "
            SELECT format(
              'SELECT ''INSERT INTO %I.%I (%s) SELECT * FROM json_populate_record(NULL::%I.%I, '''' || row_to_json(t)::text || '''') ON CONFLICT DO NOTHING;'' ' ||
              'FROM %I.%I t ' ||
              'WHERE t.xmin >= 3 ' ||
              '  AND pg_xact_status(t.xmin) IS NOT NULL ' ||
              '  AND pg_xact_commit_timestamp(t.xmin) >= %L;',
              n.nspname, c.relname,
              (SELECT string_agg(quote_ident(attname), ', ' ORDER BY attnum) FROM pg_attribute WHERE attrelid = c.oid AND attnum > 0 AND NOT attisdropped),
              n.nspname, c.relname,
              n.nspname, c.relname,
              '$FORK_TIME'
            )
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind = 'r'
              AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast');
          " 2>/dev/null | while read -r export_query; do
            if [[ -n "$export_query" ]]; then
              sudo -u postgres "$PGBIN/psql" -p "$DB_PORT" -U postgres -d "$dbname" -tAc "$export_query" >> "$DELTA_SQL" 2>/dev/null || true
            fi
          done
        done
        log_msg "SQL-дельта сохранена в $DELTA_SQL"
      else
        log_msg "Транзакций после точки расхождения не найдено (пустая дельта)."
      fi

      sudo -u postgres "$PGBIN/pg_dumpall" -p "$DB_PORT" | gzip > "$FULL_DUMP" 2>/dev/null || true
      log_msg "Полный страховочный дамп сохранен в $FULL_DUMP"
      sudo -u postgres "$PGBIN/pg_ctl" -D "$PGDATA" stop -m fast -w -t 60 >/dev/null 2>&1 || true
    else
      log_msg "Точка расхождения не требует дампа (вывод pg_rewind: ${REWIND_OUT:-нет данных})."
    fi

    if [[ "$SLOT_STATUS" == "lost" ]] || ! timeout 300 sudo -u postgres PGPASSFILE="$PGPASS_FILE" "$PGBIN/pg_rewind" \
      --target-pgdata="$PGDATA" \
      --source-server="host=$ACTIVE_PEER_IP port=$DB_PORT user=$REPL_USER dbname=postgres" ; then
      log_msg "Выполняю полную пересборку реплики через pg_basebackup от $ACTIVE_PEER_IP..."
      rm -rf "${PGDATA:?}"/*
      timeout 600 sudo -u postgres PGPASSFILE="$PGPASS_FILE" pg_basebackup --no-password \
        -h "$ACTIVE_PEER_IP" -p "$DB_PORT" -U "$REPL_USER" -D "$PGDATA" -Fp -Xs -R -S "$MY_SLOT"
    fi

    touch "$PGDATA/standby.signal"
    chown postgres:postgres "$PGDATA/standby.signal"

  elif [[ "$SLOT_STATUS" == "lost" ]]; then
    # =================================================================
    # СЦЕНАРИЙ Б: Мы были SLAVE, но слот потерян
    # =================================================================
    log_msg "Слот $MY_SLOT имеет статус lost. Пересоздаю реплику через pg_basebackup..."
    rm -rf "${PGDATA:?}"/*
    timeout 600 sudo -u postgres PGPASSFILE="$PGPASS_FILE" pg_basebackup --no-password \
      -h "$ACTIVE_PEER_IP" -p "$DB_PORT" -U "$REPL_USER" -D "$PGDATA" -Fp -Xs -R -S "$MY_SLOT"
  fi
fi

# 4. Определение режима старта
DB_STATE=$(LC_ALL=C "$PGBIN/pg_controldata" "$PGDATA" 2>/dev/null | awk -F: '/Database cluster state/ {gsub(/^[ \t]+/, "", $2); print $2}')
if [[ -f "$PGDATA/standby.signal" ]] || [[ "$DB_STATE" == *"recovery"* ]]; then
  DETECTED_ROLE="SLAVE"
else
  DETECTED_ROLE="MASTER"
fi

if [[ "$DB_STATE" == "shut down" ]] || [[ "$DB_STATE" == "shut down in recovery" ]]; then
  echo "MODE=COLD_START" > "$BOOT_MODE_FILE"
  echo "LAST_ROLE=$DETECTED_ROLE" >> "$BOOT_MODE_FILE"
  echo "DB_RAW_STATE=${DB_STATE}" >> "$BOOT_MODE_FILE"
  echo "UNBLOCK_TIMEOUT_SEC=$COLD_START_TIMEOUT_SEC" >> "$BOOT_MODE_FILE"
  log_msg "СЦЕНАРИЙ: Штатный холодный старт (БД: '$DB_STATE', Роль: $DETECTED_ROLE, таймаут ${COLD_START_TIMEOUT_SEC}с)."
else
  echo "MODE=CRASH_RECOVERY" > "$BOOT_MODE_FILE"
  echo "LAST_ROLE=$DETECTED_ROLE" >> "$BOOT_MODE_FILE"
  echo "DB_RAW_STATE=${DB_STATE:-UNKNOWN}" >> "$BOOT_MODE_FILE"
  echo "UNBLOCK_TIMEOUT_SEC=$CRASH_TIMEOUT_SEC" >> "$BOOT_MODE_FILE"
  log_msg "Старт после СБОЯ ПИТАНИЯ (БД: '$DB_STATE', Роль: $DETECTED_ROLE, таймаут ${CRASH_TIMEOUT_SEC}с)."
fi
EOF
chmod +x /usr/local/sbin/cluster-boot-analyzer.sh

# 4.3 Сторож таймаута и выхода в режим деградации
cat << 'EOF' > /usr/local/sbin/cluster-degraded-unblock.sh
#!/bin/bash
set -euo pipefail
source /etc/default/ha-cluster
[[ -f "$BOOT_MODE_FILE" ]] && source "$BOOT_MODE_FILE"

log_msg() { timeout 2 logger -t cluster-watchdog "$1" || true; }

LOCAL_IPS=$(hostname -I)
if [[ " $LOCAL_IPS " == *" $NODE1_RING0_IP "* ]] || [[ " $LOCAL_IPS " == *" $NODE1_RING1_IP "* ]]; then
  PEER_RING0_IP="$NODE2_RING0_IP"
  PEER_RING1_IP="$NODE2_RING1_IP"
  EXTRA_DELAY=0
else
  PEER_RING0_IP="$NODE1_RING0_IP"
  PEER_RING1_IP="$NODE1_RING1_IP"
  EXTRA_DELAY="${NODE2_ASYMMETRIC_DELAY_SEC:-120}"
fi

TOTAL_WAIT=$(( ${UNBLOCK_TIMEOUT_SEC:-$CRASH_TIMEOUT_SEC} + EXTRA_DELAY ))
log_msg "Ожидание сбора кворума: ${TOTAL_WAIT} сек (Режим: ${MODE:-UNKNOWN}, Прошлая роль: ${LAST_ROLE:-UNKNOWN})..."
sleep "$TOTAL_WAIT"

if corosync-quorumtool -s 2>/dev/null | grep -q "Quorate:.*Yes"; then
  log_msg "Обе ноды в строю, кворум собран штатно."
  exit 0
fi

# Предохранитель №1: Маршрутизатор
ROUTER_OK="no"
for rip in $ROUTER_IPS; do
  if ping -c 2 -W 1 "$rip" >/dev/null 2>&1 || arping -I "$CLUSTER_VIP_NIC" -c 2 -w 2 "$rip" >/dev/null 2>&1; then
    ROUTER_OK="yes"
    break
  fi
done
if [[ "$ROUTER_OK" != "yes" ]]; then
  log_msg "ОШИБКА: Маршрутизатор ($ROUTER_IPS) недоступен! Разблокировка отменена."
  exit 1
fi

# Предохранитель №2: Сосед молчит
for pip in "$PEER_RING0_IP" "$PEER_RING1_IP"; do
  if ping -c 2 -W 1 "$pip" >/dev/null 2>&1; then
    log_msg "Сосед ($pip) отвечает по ICMP! Отмена разблокировки."
    exit 1
  fi
  for pport in "$DB_CHECK_PORT" "$DB_PORT" 22; do
    if timeout 2 bash -c "</dev/tcp/${pip}/${pport}" 2>/dev/null; then
      log_msg "Сосед ($pip:$pport) отвечает по TCP! Отмена разблокировки."
      exit 1
    fi
  done
done

# Предохранитель №3: VIP не занят
if ping -c 2 -W 1 "$CLUSTER_VIP" >/dev/null 2>&1; then
  log_msg "КРИТИЧЕСКАЯ ОШИБКА: VIP ($CLUSTER_VIP) отвечает на ping! Защита от Split-Brain."
  exit 1
fi
if arping -D -I "$CLUSTER_VIP_NIC" -c 2 -w 2 "$CLUSTER_VIP" >/dev/null 2>&1; then
  log_msg "КРИТИЧЕСКАЯ ОШИБКА: VIP ($CLUSTER_VIP) занят (ARP-ответ)! Защита от Split-Brain."
  exit 1
fi

# Предохранитель №4: Только бывший MASTER
if [[ "${LAST_ROLE:-}" == "MASTER" ]]; then
  log_msg "Узел был MASTER (MODE=${MODE:-}, DB=${DB_RAW_STATE:-}). Разблокировка кворума."
  pcs quorum unblock --yes

elif [[ "${LAST_ROLE:-}" == "SLAVE" ]]; then
  # Бывший SLAVE стартует, но с дополнительным ожиданием:
  # даём старому мастеру шанс появиться первым
  log_msg "Узел был SLAVE. Дополнительное ожидание ${NODE2_ASYMMETRIC_DELAY_SEC}с перед разблокировкой."
  sleep "${NODE2_ASYMMETRIC_DELAY_SEC:-120}"

  # Повторная проверка: мастер так и не появился?
  if corosync-quorumtool -s 2>/dev/null | grep -q "Quorate:.*Yes"; then
    log_msg "Кворум собран за время дополнительного ожидания."
    exit 0
  fi

  # Повторная проверка VIP
  if ping -c 2 -W 1 "$CLUSTER_VIP" >/dev/null 2>&1; then
    log_msg "VIP занят после дополнительного ожидания. Отмена."
    exit 1
  fi

  log_msg "Мастер не появился. Бывший SLAVE разблокирует кворум и будет промотирован."
  pcs quorum unblock --yes
else
  log_msg "Роль не определена (файл $BOOT_MODE_FILE отсутствует). Отказ."
  exit 1
fi
EOF
chmod +x /usr/local/sbin/cluster-degraded-unblock.sh

# -----------------------------------------------------------------------------
# ШАГ 5. Генерация systemd-юнитов, лимитов и конфига HAProxy
# -----------------------------------------------------------------------------
echo "[INFO] Настраиваю systemd-юниты и HAProxy..."

# 5.1 Сокет и сервис проверки роли БД
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

# 5.2 Конфигурация HAProxy
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

    # Группа 1: Прямой кабель (Ring 0) — основной путь
    server node1_db_r0 ${NODE1_RING0_IP}:${DB_PORT} maxconn 100 check port ${DB_CHECK_PORT}
    server node2_db_r0 ${NODE2_RING0_IP}:${DB_PORT} maxconn 100 check port ${DB_CHECK_PORT}

    # Группа 2: Сеть роутера (Ring 1) — резервный путь
    server node1_db_r1 ${NODE1_RING1_IP}:${DB_PORT} maxconn 100 check port ${DB_CHECK_PORT} backup
    server node2_db_r1 ${NODE2_RING1_IP}:${DB_PORT} maxconn 100 check port ${DB_CHECK_PORT} backup
EOF

# 5.3 Юниты анализатора и таймера деградации
cat << EOF > /etc/systemd/system/cluster-boot-analyzer.service
[Unit]
Description=Pre-flight Disk Health Check and Boot Mode Analyzer for Pacemaker
DefaultDependencies=no
After=local-fs.target systemd-fsck-root.service network-online.target
RequiresMountsFor=${PGDATA}
Before=corosync.service pacemaker.service

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=900
EnvironmentFile=/etc/default/ha-cluster
ExecStart=/usr/local/sbin/cluster-boot-analyzer.sh

[Install]
WantedBy=multi-user.target
RequiredBy=corosync.service pacemaker.service
EOF

cat << 'EOF' > /etc/systemd/system/cluster-degraded-unblock.service
[Unit]
Description=Unblock Corosync WaitForAll quorum after timeout (Degraded Mode)
After=corosync.service pacemaker.service

[Service]
Type=oneshot
TimeoutStartSec=infinity
EnvironmentFile=/etc/default/ha-cluster
ExecStart=/usr/local/sbin/cluster-degraded-unblock.sh
EOF

cat << 'EOF' > /etc/systemd/system/cluster-degraded-unblock.timer
[Unit]
Description=Start Degraded Mode Watchdog Timer after Pacemaker boot
PartOf=pacemaker.service

[Timer]
OnActiveSec=5sec
AccuracySec=1s
Unit=cluster-degraded-unblock.service

[Install]
WantedBy=multi-user.target
EOF

# Удаляем старый юнит маркера выключения
systemctl disable --now cluster-shutdown-marker.service 2>/dev/null || true
rm -f /etc/systemd/system/cluster-shutdown-marker.service /usr/local/sbin/cluster-mark-shutdown.sh

# 5.4 Защита от OOM-Killer, лимиты, RT-приоритет для Corosync
mkdir -p /etc/systemd/system/corosync.service.d
cat << 'EOF' > /etc/systemd/system/corosync.service.d/ha-hardening.conf
[Service]
OOMScoreAdjust=-1000
CPUSchedulingPolicy=rr
CPUSchedulingPriority=99
LimitNOFILE=65536
LimitMEMLOCK=infinity
EOF

for crit_svc in pacemaker postgresql "postgresql@${PG_VERSION}-main" haproxy; do
  mkdir -p "/etc/systemd/system/${crit_svc}.service.d"
  cat << 'EOF' > "/etc/systemd/system/${crit_svc}.service.d/ha-hardening.conf"
[Service]
EnvironmentFile=-/etc/default/ha-cluster
OOMScoreAdjust=-1000
LimitNOFILE=65536
EOF
done

for app_svc in $APP_SERVICE $DAEMON_SERVICE; do
  mkdir -p "/etc/systemd/system/${app_svc}.service.d"
  cat << EOF > "/etc/systemd/system/${app_svc}.service.d/ha-limits.conf"
[Service]
MemoryMax=${APP_MEMORY_MAX}
CPUQuota=${APP_CPU_QUOTA}
OOMScoreAdjust=500
LimitNOFILE=65536
EOF
done

mkdir -p /etc/systemd/journald.conf.d
cat << 'EOF' > /etc/systemd/journald.conf.d/ha-limits.conf
[Journal]
SystemMaxUse=500M
RuntimeMaxUse=100M
EOF

# -----------------------------------------------------------------------------
# ШАГ 6. Применение правил автозагрузки
# -----------------------------------------------------------------------------
systemctl daemon-reload
systemctl restart systemd-journald 2>/dev/null || true

for svc in postgresql "postgresql@${PG_VERSION}-main" haproxy $APP_SERVICE $DAEMON_SERVICE; do
  if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}.service"; then
    systemctl disable "${svc}.service" 2>/dev/null || true
  fi
done

systemctl enable --now db-role-check.socket pcsd.service 2>/dev/null || true
systemctl enable cluster-boot-analyzer.service \
                     cluster-degraded-unblock.timer 2>/dev/null || true

echo "hacluster:${HACLUSTER_PASS}" | chpasswd 2>/dev/null || true

# -----------------------------------------------------------------------------
# ШАГ 7. Инициализация кластера (при запуске с --init-pcs)
# -----------------------------------------------------------------------------
if [[ "${1:-}" == "--init-pcs" ]]; then
  echo "[INFO] Инициализирую кластер Corosync и ресурсы Pacemaker..."

  pcs host auth "$NODE1_NAME" "$NODE2_NAME" -u hacluster -p "$HACLUSTER_PASS"

  pcs cluster setup ha_cluster \
    "$NODE1_NAME" addr="$NODE1_RING0_IP" addr="$NODE1_RING1_IP" \
    "$NODE2_NAME" addr="$NODE2_RING0_IP" addr="$NODE2_RING1_IP" \
    transport knet \
    link linknumber=0 link_priority=100 mcastport=5405 \
    link linknumber=1 link_priority=50  mcastport=5406 \
    totem token="$COROSYNC_TOKEN_MS" \
          token_retransmits_before_loss_const=10 \
          consensus=3600 \
          join=60

  pcs cluster start --all
  pcs cluster enable --all

  # --- Свойства кластера ---
  pcs property set stonith-enabled=false
  pcs property set no-quorum-policy=stop
  pcs property set start-failure-is-fatal=true
  pcs resource defaults update migration-threshold=3 \
    failure-timeout="$FAILURE_TIMEOUT_SEC" resource-stickiness=100

  # --- 1. Псевдо-арбитр ---
  pcs resource create ping-gateway ocf:pacemaker:ping \
    host_list="$ROUTER_IPS" multiplier=1000 dampen=10s \
    op monitor interval=5s timeout=10s \
    clone meta interleave=true

  # --- 2. PostgreSQL (promotable) ---
  #   На мастере: GRANT pg_read_all_data TO repl_user;
  pcs resource create pgsql ocf:heartbeat:pgsqlms \
    bindir="$PGBIN" pgdata="$PGDATA" pghost="/var/run/postgresql" pgport="$DB_PORT" \
    primary_conninfo_opt="user=${REPL_USER} passfile=${PGPASS_FILE} connect_timeout=5 keepalives_idle=15 keepalives_interval=5 keepalives_count=3" \
    op start timeout=60s op stop timeout=60s \
    op promote timeout=30s op demote timeout=120s \
    op monitor interval=3s timeout=10s role="Master" \
    op monitor interval=4s timeout=10s role="Slave" \
    op notify timeout=15s \
    promotable notify=true

  # --- 3. Группа app-stack: VIP + Приложение ---
  pcs resource create vip ocf:heartbeat:IPaddr2 \
    ip="$CLUSTER_VIP" cidr_netmask="$CLUSTER_VIP_CIDR" nic="$CLUSTER_VIP_NIC" \
    run_arping=true arp_interval=500 arp_count=5 arp_bg=true \
    op monitor interval=5s timeout=20s \
    --group app-stack

  for svc in $APP_SERVICE; do
    pcs resource create "app-${svc}" "systemd:${svc}" \
      op monitor interval=10s \
      --group app-stack
  done

  # --- 4. HAProxy (clone на обоих узлах) ---
  pcs resource create haproxy-svc systemd:haproxy \
    op monitor interval=10s \
    clone meta interleave=true

  # --- 5. Группа daemon-stack ---
  for dsvc in $DAEMON_SERVICE; do
    pcs resource create "daemon-${dsvc}" "systemd:${dsvc}" \
      op monitor interval=10s \
      --group daemon-stack
  done

  # Псевдо-арбитр: группы на узле с живым роутером
  pcs constraint location app-stack rule score-attribute=pingd pingd gt 0
  pcs constraint location pgsql-clone rule role=Master score-attribute=pingd pingd gt 0
  pcs constraint location daemon-stack rule score-attribute=pingd pingd gt 0

  pcs constraint colocation add app-stack with Master pgsql-clone 500
  pcs constraint colocation add daemon-stack with Master pgsql-clone 500

  # Порядок: HAProxy стартует ДО приложения и демона
  pcs constraint order start haproxy-svc-clone then start app-stack
  pcs constraint order start haproxy-svc-clone then start daemon-stack

  echo "[УСПЕХ] Кластер полностью настроен и запущен! Проверьте: pcs status"
else
  echo "[УСПЕХ] Узел $CURRENT_NODE полностью подготовлен."
  echo "Для первичной инициализации кластера выполните на $NODE1_NAME:"
  echo "  sudo $0 --init-pcs"
fi