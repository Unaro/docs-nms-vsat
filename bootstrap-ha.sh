#!/bin/bash
# =============================================================================
# УНИВЕРСАЛЬНЫЙ СКРИПТ РАЗВЕРТЫВАНИЯ ДВУХУЗЛОВОГО HA-КЛАСТЕРА (NODE1 / NODE2)
# Оптимизирован под целевую нагрузку 30–60 устройств (максимум до 100 устройств)
# Стек: Corosync (2 кольца) + Pacemaker + HAProxy + PostgreSQL 16 (PAF)
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
# ЕДИНЫЙ КОНФИГ ПАРАМЕТРОВ КЛАСТЕРА (ИДЕНТИЧЕН НА ОБОИХ СЕРВЕРАХ)
# Профиль нагрузки: 30–60 устройств (до 100 max)
# =========================================================================

# 1. Имена узлов и сетевые интерфейсы
NODE1_NAME="node1"
NODE2_NAME="node2"
RING0_NIC="eth1"                # Интерфейс прямого патч-корда между серверами (Ring 0)
CLUSTER_VIP_NIC="eth0"          # Интерфейс в сторону маршрутизатора (Ring 1 и VIP)

# 2. IP-адреса узлов (Кольцо 0 — прямой кабель, Кольцо 1 — сеть маршрутизатора)
NODE1_RING0_IP="10.0.0.1"
NODE2_RING0_IP="10.0.0.2"
NODE1_RING1_IP="192.168.1.11"
NODE2_RING1_IP="192.168.1.12"

# 3. Маршрутизатор (псевдо-арбитр) и плавающий Виртуальный IP (VIP)
ROUTER_IPS="192.168.1.1"
CLUSTER_VIP="192.168.1.100"
CLUSTER_VIP_CIDR="24"

# 4. Параметры PostgreSQL и HAProxy (профиль: 30–60 устройств)
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
MAX_SLOT_WAL_KEEP_SIZE="5GB"    # Оптимально для умеренного потока WAL
WAL_KEEP_SIZE="512MB"           # Достаточно для часов автономности без раздувания диска
MAX_CONNECTIONS="100"           # С запасом покрывает пул 30-60 устройств

# 5. Имена systemd-сервисов вашего приложения и демона
APP_SERVICE="my-app"
DAEMON_SERVICE="my-daemon"
APP_MEMORY_MAX="75%"
APP_CPU_QUOTA="80%"

# 6. Таймауты и пороги безопасности
COROSYNC_TOKEN_MS="3000"        # 3 сек (защита от пауз ВМ при бэкапах гипервизора)
MIN_FREE_DISK_PCT="5"           # Минимум 5% свободного места и свободных inodes
MIN_FREE_CIB_MB="500"           # Минимум 500 МБ в /var/lib/pacemaker
COLD_START_TIMEOUT_SEC="180"    # 3 минуты ожидания соседа при плановом старте
CRASH_TIMEOUT_SEC="900"         # 15 минут ожидания соседа после сбоя питания
NODE2_ASYMMETRIC_DELAY_SEC="120"# Сдвиг +2 мин на node2 против Split-Brain
FAILURE_TIMEOUT_SEC="900s"      # 15 минут до сброса fail-count (против пинг-понга)

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

# Безопасные дефолты параметров для профиля нагрузки 30–60 устройств
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
LOCAL_IPS=$(hostname -I)
if [[ " $LOCAL_IPS " == *" $NODE1_RING0_IP "* ]] || [[ " $LOCAL_IPS " == *" $NODE1_RING1_IP "* ]]; then
    CURRENT_NODE="$NODE1_NAME"
    PEER_NODE="$NODE2_NAME"
    PEER_RING0_IP="$NODE2_RING0_IP"
    PEER_RING1_IP="$NODE2_RING1_IP"
    MY_SLOT="$REPL_SLOT_NODE1"
elif [[ " $LOCAL_IPS " == *" $NODE2_RING0_IP "* ]] || [[ " $LOCAL_IPS " == *" $NODE2_RING1_IP "* ]]; then
    CURRENT_NODE="$NODE2_NAME"
    PEER_NODE="$NODE1_NAME"
    PEER_RING0_IP="$NODE1_RING0_IP"
    PEER_RING1_IP="$NODE1_RING1_IP"
    MY_SLOT="$REPL_SLOT_NODE2"
else
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

# Создаем .pgpass с правами 0600 для беспарольной работы репликации, pg_rewind и pg_basebackup
mkdir -p "$(dirname "$PGPASS_FILE")"
echo "*:${DB_PORT}:*:${REPL_USER}:${REPL_PASS}" > "$PGPASS_FILE"
chown postgres:postgres "$PGPASS_FILE" 2>/dev/null || true
chmod 0600 "$PGPASS_FILE"

# -----------------------------------------------------------------------------
# ШАГ 3. Базовые настройки ядра (sysctl), диска и сброса зависших TCP-сессий
# -----------------------------------------------------------------------------
cat << 'EOF' > /etc/sysctl.d/99-ha-cluster.conf
# Самострел (Reboot) при зависании диска и процесса БД в D-state дольше 45 секунд
kernel.hung_task_timeout_secs = 45
kernel.hung_task_panic = 1
kernel.panic = 5
kernel.panic_on_oops = 1

# Быстрое переиспользование сокетов TIME_WAIT и автоподбор MTU (для устройств опроса)
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_mtu_probing = 1
fs.file-max = 2097152
EOF
sysctl --system >/dev/null 2>&1 || true

# Резервируем 2% блоков диска под root/pacemaker, чтобы CIB не завис при переполнении диска
ROOT_DEV=$(findmnt -n -o SOURCE /var/lib/pacemaker 2>/dev/null || findmnt -n -o SOURCE / 2>/dev/null || true)
if [[ "$ROOT_DEV" == /dev/* ]]; then
    tune2fs -m 2 "$ROOT_DEV" >/dev/null 2>&1 || true
fi

# Отправка TCP RST для мгновенного переподключения клиентов после переезда VIP
if command -v iptables >/dev/null 2>&1; then
    if ! iptables -C INPUT -p tcp -m conntrack --ctstate INVALID -j REJECT --reject-with tcp-reset 2>/dev/null; then
        iptables -I INPUT 1 -p tcp -m conntrack --ctstate INVALID -j REJECT --reject-with tcp-reset 2>/dev/null || true
        command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save 2>/dev/null || true
    fi
fi

# Настройки в postgresql.conf, оптимизированные под нагрузку 30–60 устройств
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
synchronous_commit = remote_write
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
# ШАГ 4. Создание 3 рабочих скриптов кластера (без костыля graceful_shutdown)
# -----------------------------------------------------------------------------
echo "[INFO] Создаю рабочие скрипты кластера..."

# 4.1 Скрипт проверки роли БД для HAProxy (/usr/local/bin/db-role-check.sh)
cat << 'EOF' > /usr/local/bin/db-role-check.sh
#!/bin/bash
source /etc/default/ha-cluster

SQL="SET statement_timeout='1500ms'; SELECT pg_is_in_recovery() || '|' || current_setting('transaction_read_only');"
OUT=$(timeout 2 psql -p "${DB_PORT:-5432}" -U postgres -d postgres -tAc "$SQL" 2>/dev/null | tail -n 1 || echo "err")

if [[ "$OUT" == "f|off" ]]; then
    printf "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 6\r\n\r\nMaster"
    exit 0
else
    printf "HTTP/1.1 503 Service Unavailable\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nSlave"
    exit 1
fi
EOF
chmod +x /usr/local/bin/db-role-check.sh

# 4.2 Предстартовый анализатор дисков и нативного состояния PostgreSQL (/usr/local/sbin/cluster-boot-analyzer.sh)
cat << 'EOF' > /usr/local/sbin/cluster-boot-analyzer.sh
#!/bin/bash
set -euo pipefail
source /etc/default/ha-cluster

log_msg() { timeout 2 logger -t cluster-precheck "$1" || true; }

rm -f "$BOOT_MODE_FILE"

# 1. Гарантируем корректные права на ключ Corosync и .pgpass
if [[ -f /etc/corosync/authkey ]]; then
    chown root:root /etc/corosync/authkey
    chmod 0400 /etc/corosync/authkey
fi
if [[ -f "$PGPASS_FILE" ]]; then
    chown postgres:postgres "$PGPASS_FILE" 2>/dev/null || true
    chmod 0600 "$PGPASS_FILE"
fi

# 2. Проверка монтирования, записи (Read-Only), места (df) и индексных дескрипторов (df -i)
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

# 3. Если сосед уже работает как Master, а наш слот WAL утерян (lost) — делаем авто-pg_basebackup
LOCAL_IPS=$(hostname -I)
if [[ " $LOCAL_IPS " == *" $NODE1_RING0_IP "* ]] || [[ " $LOCAL_IPS " == *" $NODE1_RING1_IP "* ]]; then
    PEER_IP="$NODE2_RING0_IP"
    MY_SLOT="$REPL_SLOT_NODE1"
else
    PEER_IP="$NODE1_RING0_IP"
    MY_SLOT="$REPL_SLOT_NODE2"
fi

if curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "http://${PEER_IP}:${DB_CHECK_PORT}" | grep -q "200"; then
    if sudo -u postgres PGPASSFILE="$PGPASS_FILE" PGCONNECT_TIMEOUT=3 \
       psql -w -h "$PEER_IP" -p "$DB_PORT" -U "$REPL_USER" -d postgres -tAc "SELECT 1;" >/dev/null 2>&1; then
        SLOT_STATUS=$(sudo -u postgres PGPASSFILE="$PGPASS_FILE" PGCONNECT_TIMEOUT=3 \
            psql -w -h "$PEER_IP" -p "$DB_PORT" -U "$REPL_USER" -d postgres -tAc \
            "SELECT wal_status FROM pg_replication_slots WHERE slot_name='${MY_SLOT}';" 2>/dev/null || echo "ok")
        if [[ "$SLOT_STATUS" == "lost" ]]; then
            log_msg "Слот $MY_SLOT имеет статус lost. Пересоздаю реплику через pg_basebackup --no-password..."
            rm -rf "${PGDATA:?}"/*
            timeout 600 sudo -u postgres PGPASSFILE="$PGPASS_FILE" pg_basebackup --no-password \
                -h "$PEER_IP" -p "$DB_PORT" -U "$REPL_USER" -D "$PGDATA" -Fp -Xs -R -S "$MY_SLOT"
        fi
    fi
fi

# 4. Определение режима старта и роли напрямую из pg_controldata и standby.signal
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
    log_msg "Диски исправны. СЦЕНАРИЙ: Штатный холодный старт (БД: '$DB_STATE', Роль: $DETECTED_ROLE, таймаут ${COLD_START_TIMEOUT_SEC}с)."
else
    echo "MODE=CRASH_RECOVERY" > "$BOOT_MODE_FILE"
    echo "LAST_ROLE=$DETECTED_ROLE" >> "$BOOT_MODE_FILE"
    echo "DB_RAW_STATE=${DB_STATE:-UNKNOWN}" >> "$BOOT_MODE_FILE"
    echo "UNBLOCK_TIMEOUT_SEC=$CRASH_TIMEOUT_SEC" >> "$BOOT_MODE_FILE"
    log_msg "Диски исправны. ВНИМАНИЕ: Старт после СБОЯ ПИТАНИЯ (БД: '$DB_STATE', Роль: $DETECTED_ROLE, таймаут ${CRASH_TIMEOUT_SEC}с)."
fi
EOF
chmod +x /usr/local/sbin/cluster-boot-analyzer.sh

# 4.3 Сторож таймаута и выхода в режим деградации (/usr/local/sbin/cluster-degraded-unblock.sh)
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

# Предохранитель №1: Проверка маршрутизатора (ICMP ping + резервная L2 ARP-проверка)
ROUTER_OK="no"
for rip in $ROUTER_IPS; do
    if ping -c 2 -W 1 "$rip" >/dev/null 2>&1 || arping -I "$CLUSTER_VIP_NIC" -c 2 -w 2 "$rip" >/dev/null 2>&1; then
        ROUTER_OK="yes"
        break
    fi
done
if [[ "$ROUTER_OK" != "yes" ]]; then
    log_msg "ОШИБКА: Маршрутизатор ($ROUTER_IPS) недоступен ни по ICMP, ни по ARP! Разблокировка отменена."
    exit 1
fi

# Предохранитель №2: Проверка молчания соседа по ICMP и TCP на обоих кольцах
for pip in "$PEER_RING0_IP" "$PEER_RING1_IP"; do
    if ping -c 2 -W 1 "$pip" >/dev/null 2>&1; then
        log_msg "Сосед ($pip) отвечает по ICMP! Отмена принудительной разблокировки."
        exit 1
    fi
    for pport in "$DB_CHECK_PORT" "$DB_PORT" 22; do
        if timeout 2 bash -c "</dev/tcp/${pip}/${pport}" 2>/dev/null; then
            log_msg "Сосед ($pip:$pport) отвечает по TCP! Отмена принудительной разблокировки."
            exit 1
        fi
    done
done

# Предохранитель №3: Проверка отсутствия активного VIP в сети роутера
if ping -c 2 -W 1 "$CLUSTER_VIP" >/dev/null 2>&1 || arping -D -I "$CLUSTER_VIP_NIC" -c 2 -w 2 "$CLUSTER_VIP" 2>&1 | grep -q "Received [1-9]"; then
    log_msg "КРИТИЧЕСКАЯ ОШИБКА: VIP ($CLUSTER_VIP) уже занят в сети! Защита от Split-Brain сработала."
    exit 1
fi

# Предохранитель №4: Разрешаем одиночный старт только бывшему Master (по данным pg_controldata)
if [[ "${LAST_ROLE:-}" == "MASTER" ]]; then
    log_msg "Узел до остановки/сбоя был MASTER (MODE=${MODE:-}, DB=${DB_RAW_STATE:-}). Разблокировка кворума (pcs quorum unblock)!"
    pcs quorum unblock --yes
else
    log_msg "СТОП: Узел до выключения/аварии был SLAVE (MODE=${MODE:-}, DB=${DB_RAW_STATE:-}). Одиночный старт запрещен во избежание потери данных."
    exit 1
fi
EOF
chmod +x /usr/local/sbin/cluster-degraded-unblock.sh

# -----------------------------------------------------------------------------
# ШАГ 5. Генерация systemd-юнитов, лимитов OOM/NOFILE и конфига HAProxy
# -----------------------------------------------------------------------------
echo "[INFO] Настраиваю systemd-юниты и HAProxy (профиль: 30–60 устройств)..."

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
ExecStart=-/usr/local/bin/db-role-check.sh
StandardInput=socket
StandardOutput=socket
StandardError=null
LogLevelMax=warning
LimitNOFILE=65536
EOF

# 5.2 Конфигурация HAProxy (ИСПРАВЛЕНО: переменные подставляются при генерации файла)
cat << EOF > /etc/haproxy/haproxy.cfg
global
    log /dev/log local0 warning
    maxconn 300
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
    # Основные маршруты через прямой кабель (Ring 0)
    server node1_db_r0 ${NODE1_RING0_IP}:${DB_PORT} maxconn 100 check port ${DB_CHECK_PORT}
    server node2_db_r0 ${NODE2_RING0_IP}:${DB_PORT} maxconn 100 check port ${DB_CHECK_PORT}
    # Резервные маршруты через сеть роутера (Ring 1) на случай обрыва прямого кабеля
    server node1_db_r1 ${NODE1_RING1_IP}:${DB_PORT} maxconn 100 check port ${DB_CHECK_PORT} backup
    server node2_db_r1 ${NODE2_RING1_IP}:${DB_PORT} maxconn 100 check port ${DB_CHECK_PORT} backup
EOF

# 5.3 Юниты анализатора загрузки и таймера деградации (ИСПРАВЛЕНО: TimeoutStartSec=infinity)
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
Unit=cluster-degraded-unblock.service

[Install]
WantedBy=multi-user.target
EOF

# Удаляем старый юнит маркера выключения, если он остался от прошлой версии
systemctl disable --now cluster-shutdown-marker.service 2>/dev/null || true
rm -f /etc/systemd/system/cluster-shutdown-marker.service /usr/local/sbin/cluster-mark-shutdown.sh

# 5.4 Защита от OOM-Killer, лимиты дескрипторов (LimitNOFILE) и RT-приоритет для Corosync
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

for app_svc in "$APP_SERVICE" "$DAEMON_SERVICE"; do
    mkdir -p "/etc/systemd/system/${app_svc}.service.d"
    cat << EOF > "/etc/systemd/system/${app_svc}.service.d/ha-limits.conf"
[Service]
MemoryMax=${APP_MEMORY_MAX}
CPUQuota=${APP_CPU_QUOTA}
OOMScoreAdjust=500
LimitNOFILE=65536
EOF
done

# Ограничиваем размер системного журнала до 500 МБ
mkdir -p /etc/systemd/journald.conf.d
cat << 'EOF' > /etc/systemd/journald.conf.d/ha-limits.conf
[Journal]
SystemMaxUse=500M
RuntimeMaxUse=100M
EOF

# -----------------------------------------------------------------------------
# ШАГ 6. Применение правил автозагрузки systemd
# -----------------------------------------------------------------------------
systemctl daemon-reload
systemctl restart systemd-journald 2>/dev/null || true

for svc in postgresql "postgresql@${PG_VERSION}-main" haproxy "$APP_SERVICE" "$DAEMON_SERVICE"; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}.service"; then
        systemctl disable "${svc}.service" 2>/dev/null || true
    fi
done

systemctl enable --now db-role-check.socket pcsd.service 2>/dev/null || true
systemctl enable cluster-boot-analyzer.service \
                 cluster-degraded-unblock.timer 2>/dev/null || true

echo "hacluster:${HACLUSTER_PASS}" | chpasswd 2>/dev/null || true

# -----------------------------------------------------------------------------
# ШАГ 7. Инициализация кластера Pacemaker/Corosync (при запуске с --init-pcs)
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

    pcs property set stonith-enabled=false
    pcs property set no-quorum-policy=stop
    pcs property set start-failure-is-fatal=true
    pcs resource defaults update migration-threshold=3 failure-timeout="$FAILURE_TIMEOUT_SEC" resource-stickiness=100

    # Псевдо-арбитр (мониторинг маршрутизатора)
    pcs resource create ping-gateway ocf:pacemaker:ping \
        host_list="$ROUTER_IPS" multiplier=1000 dampen=10s \
        op monitor interval=5s timeout=10s clone meta interleave=true

    # СУБД PostgreSQL 16 (ИСПРАВЛЕНО: современный синтаксис PAF без recovery_template)
    pcs resource create pgsql ocf:heartbeat:pgsqlms \
        bindir="$PGBIN" pgdata="$PGDATA" pghost="/var/run/postgresql" pgport="$DB_PORT" \
        primary_conninfo_opt="user=${REPL_USER} passfile=${PGPASS_FILE} connect_timeout=5 keepalives_idle=15 keepalives_interval=5 keepalives_count=3" \
        op start timeout=60s op stop timeout=60s \
        op promote timeout=30s op demote timeout=120s \
        op monitor interval=15s timeout=10s role="Master" \
        op monitor interval=16s timeout=10s role="Slave" \
        op notify timeout=15s \
        promotable notify=true

    # Виртуальный IP с активным обнаружением ARP-коллизий
    pcs resource create vip ocf:heartbeat:IPaddr2 \
        ip="$CLUSTER_VIP" cidr_netmask="$CLUSTER_VIP_CIDR" nic="$CLUSTER_VIP_NIC" \
        run_arping=true arp_interval=500 arp_count=5 arp_bg=true \
        op monitor interval=5s timeout=20s

    # Критическое ядро (HAProxy + Приложение) в группе, демон — отдельным зависимым ресурсом
    pcs resource create haproxy-svc systemd:haproxy op monitor interval=10s --group core-app-stack
    pcs resource create app-svc "systemd:${APP_SERVICE}" op monitor interval=10s --group core-app-stack
    pcs resource create daemon-svc "systemd:${DAEMON_SERVICE}" op monitor interval=10s

    # Правила размещения и связки (Constraints)
    pcs constraint location vip rule score-attribute=pingd pingd gt 0
    pcs constraint location pgsql-clone rule role=Master score-attribute=pingd pingd gt 0
    pcs constraint colocation add core-app-stack with vip INFINITY
    pcs constraint colocation add daemon-svc with core-app-stack INFINITY
    pcs constraint colocation add vip with master pgsql-clone 500
    pcs constraint order start vip then start core-app-stack
    pcs constraint order start core-app-stack then start daemon-svc symmetrical=false

    echo "[УСПЕХ] Кластер полностью настроен и запущен! Проверьте: pcs status"
else
    echo "[УСПЕХ] Узел $CURRENT_NODE полностью подготовлен (профиль 30–60 устройств)."
    echo "Для первичной инициализации кластера выполните на $NODE1_NAME:"
    echo "  sudo $0 --init-pcs"
fi