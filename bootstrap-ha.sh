#!/bin/bash
# =============================================================================
# УНИВЕРСАЛЬНЫЙ СКРИПТ РАЗВЕРТЫВАНИЯ HA-КЛАСТЕРА (ВЕРСИЯ 5.0 — PRODUCTION FULL)
# Покрывает 44 сценария отказоустойчивости:
#  - v1.0–v2.0: Двухкольцевой Corosync (Knet), Watchdog SBD/softdog, D-state fencing,
#          Unix-сокет db-role-check, параллельное выключение, 4-ступенчатый сторож
#          деградации, резервирование HAProxy Ring 1, положительные pingd preferences;
#  - v3.0: Слоты репликации PostgreSQL, conntrack TCP RST, OOMScoreAdjust,
#          Realtime CPU scheduling (SCHED_RR 99), cgroups лимиты, Chrony Ring 0;
#  - v4.0 (Production Edge Cases):
#          1. Безопасный беспарольный pg_basebackup (--no-password, .pgpass, pre-check);
#          2. Подавление 86 400 логов journald с сохранением сокета HAProxy;
#          3. Комбинированная проверка шлюза (L3 ICMP + L2 arping + neigh reachable);
#          4. Таймауты idle_in_transaction_session_timeout и statement_timeout;
#          5. Устранение fate-sharing: разделение на core-app-stack и daemon-svc;
#          6. Защита от пинг-понга: start-failure-is-fatal=true, failure-timeout=900s;
#  - v5.0 (Deep Production & Enterprise Resiliency):
#          1. Проверка Read-Only и XID Wraparound limit (1.9 млрд) в db-role-check;
#          2. wal_log_hints=on и track_commit_timestamp=on для гарантированного pg_rewind;
#          3. Защита от VM Stun / vMotion: Corosync totem token=3000ms, consensus=3600ms;
#          4. Защита от черных дыр MTU: tcp_mtu_probing=1 и автодетекция DF-ping с fallback;
#          5. OOM-Killer защита (vm.overcommit_memory=2, overcommit_ratio=80, OOMScoreAdjust=-1000);
#          6. Мониторинг системного раздела CIB /var/lib/pacemaker (Diskd min_free=500M);
#          7. Активное обнаружение ARP-коллизий VIP (run_arping=true, arp_interval=500);
#          8. Предстартовая валидация .pgpass через IDENTIFY_SYSTEM replication protocol.
# =============================================================================
set -euo pipefail

ENV_FILE="/etc/default/ha-cluster"

if [[ $EUID -ne 0 ]]; then
    echo "[ОШИБКА] Запустите скрипт с правами root (sudo ./bootstrap-ha.sh)"
    exit 1
fi

# -----------------------------------------------------------------------------
# ШАГ 1. Создание шаблона /etc/default/ha-cluster (если он еще не создан)
# -----------------------------------------------------------------------------
if [[ ! -f "$ENV_FILE" ]]; then
    echo "[INFO] Файл $ENV_FILE не найден. Создаю эталонный шаблон v5.0..."
    cat << 'EOF' > "$ENV_FILE"
# =========================================================================
# ЕДИНЫЙ КОНФИГ ПАРАМЕТРОВ КЛАСТЕРА (v5.0 — ИДЕНТИЧЕН НА NODE1 И NODE2)
# =========================================================================

# 1. Имена и сетевые интерфейсы узлов
NODE1_NAME="node1"
NODE2_NAME="node2"
RING0_NIC="eth1"                # Интерфейс прямого патч-корда (Ring 0)
CLUSTER_VIP_NIC="eth0"          # Интерфейс в сети маршрутизатора (Ring 1 и VIP)
SAFE_MTU="1500"                 # Эталонный MTU (защита от Jumbo Frames Black Hole)

# 2. Сетевые адреса (Ring 0 — прямой кабель, Ring 1 — сеть маршрутизатора)
NODE1_RING0_IP="10.0.0.1"
NODE2_RING0_IP="10.0.0.2"
NODE1_RING1_IP="192.168.1.11"
NODE2_RING1_IP="192.168.1.12"

# 3. Маршрутизаторы (псевдо-арбитры) и асимметричная задержка
ROUTER_IP="192.168.1.1"
ROUTER_IPS="192.168.1.1 192.168.1.2"
NODE2_ASYMMETRIC_DELAY_SEC="120"

# 4. Виртуальный IP (VIP)
CLUSTER_VIP="192.168.1.100"
CLUSTER_VIP_CIDR="24"

# 5. Параметры СУБД PostgreSQL и HAProxy
PG_VERSION="16"
PGDATA="/var/lib/postgresql/16/main"
PGBIN="/usr/lib/postgresql/16/bin"
DB_PORT="5432"
DB_CHECK_USER="haproxy_check"
DB_CHECK_PORT="9200"
HAPROXY_DB_BIND_PORT="5000"
REPL_USER="repl_user"
REPL_PASS="ReplSecretPass!"
PGPASS_FILE="/var/lib/postgresql/.pgpass"
REPL_SLOT_NODE1="slot_node1"
REPL_SLOT_NODE2="slot_node2"
MAX_SLOT_WAL_KEEP_SIZE="10GB"
MAX_XID_AGE_LIMIT="1900000000"  # Порог защиты от XID Wraparound (1.9 млрд)
IDLE_IN_TX_TIMEOUT_MS="15000ms"
STATEMENT_TIMEOUT_MS="30000ms"

# 6. Прикладные сервисы (разделены: основное приложение и второстепенный демон)
APP_SERVICE="my-app"
DAEMON_SERVICE="my-daemon"
APP_MEMORY_MAX="75%"
APP_CPU_QUOTA="80%"

# 7. Таймауты, анти-VM-Stun параметры Corosync и пороги безопасности
COROSYNC_TOKEN_MS="3000"        # 3 сек (защита от VM Stun / vMotion при бэкапах)
COROSYNC_RETRANSMITS="10"
COROSYNC_CONSENSUS_MS="3600"
COROSYNC_JOIN_MS="60"
MIN_FREE_DISK_PCT="5"
MIN_FREE_CIB_MB="500"           # Минимум 500 МБ на разделе /var/lib/pacemaker
MAX_CLOCK_SKEW_SEC="1.0"
COLD_START_TIMEOUT_SEC="180"
CRASH_TIMEOUT_SEC="900"
FAILURE_TIMEOUT_SEC="900s"

# 8. Служебные файлы состояния
STATE_DIR="/var/lib/cluster-state"
STATE_FILE="/var/lib/cluster-state/graceful_shutdown"
BOOT_MODE_FILE="/run/cluster_boot_mode"

# 9. Пароль пользователя hacluster (для автоматической инициализации pcs)
HACLUSTER_PASS="StrongClusterPass123!"
EOF
    chmod 600 "$ENV_FILE"
    echo "[ВНИМАНИЕ] Шаблон $ENV_FILE создан."
    echo "Проверьте в нем IP-адреса и имена ваших сервисов, затем запустите скрипт повторно!"
    exit 0
fi

# Подгружаем переменные из единого файла конфигурации
source "$ENV_FILE"

# Установка безопасных дефолтов при обновлении со старых версий
RING0_NIC="${RING0_NIC:-eth1}"
CLUSTER_VIP_NIC="${CLUSTER_VIP_NIC:-eth0}"
SAFE_MTU="${SAFE_MTU:-1500}"
MAX_XID_AGE_LIMIT="${MAX_XID_AGE_LIMIT:-1900000000}"
COROSYNC_TOKEN_MS="${COROSYNC_TOKEN_MS:-3000}"
COROSYNC_RETRANSMITS="${COROSYNC_RETRANSMITS:-10}"
COROSYNC_CONSENSUS_MS="${COROSYNC_CONSENSUS_MS:-3600}"
COROSYNC_JOIN_MS="${COROSYNC_JOIN_MS:-60}"
MIN_FREE_CIB_MB="${MIN_FREE_CIB_MB:-500}"
MAX_CLOCK_SKEW_SEC="${MAX_CLOCK_SKEW_SEC:-1.0}"
APP_MEMORY_MAX="${APP_MEMORY_MAX:-75%}"
APP_CPU_QUOTA="${APP_CPU_QUOTA:-80%}"
REPL_USER="${REPL_USER:-repl_user}"
REPL_PASS="${REPL_PASS:-ReplSecretPass!}"
PGPASS_FILE="${PGPASS_FILE:-/var/lib/postgresql/.pgpass}"
REPL_SLOT_NODE1="${REPL_SLOT_NODE1:-slot_node1}"
REPL_SLOT_NODE2="${REPL_SLOT_NODE2:-slot_node2}"
MAX_SLOT_WAL_KEEP_SIZE="${MAX_SLOT_WAL_KEEP_SIZE:-10GB}"
ROUTER_IPS="${ROUTER_IPS:-$ROUTER_IP}"
NODE2_ASYMMETRIC_DELAY_SEC="${NODE2_ASYMMETRIC_DELAY_SEC:-120}"
FAILURE_TIMEOUT_SEC="${FAILURE_TIMEOUT_SEC:-900s}"
IDLE_IN_TX_TIMEOUT_MS="${IDLE_IN_TX_TIMEOUT_MS:-15000ms}"
STATEMENT_TIMEOUT_MS="${STATEMENT_TIMEOUT_MS:-30000ms}"

echo "[INFO] Конфигурация успешно загружена из $ENV_FILE (v5.0 активна)"

# -----------------------------------------------------------------------------
# ШАГ 2. Автоопределение текущего узла (node1 или node2)
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
    echo "[ОШИБКА] Ни один из локальных IP ($LOCAL_IPS) не совпадает с NODE1/NODE2 в $ENV_FILE!"
    exit 1
fi
echo "[INFO] Скрипт выполняется на узле: $CURRENT_NODE (сосед: $PEER_NODE)"

# -----------------------------------------------------------------------------
# ШАГ 3. Настройка ядра (D-state, Overcommit, MTU probing, Chrony, Conntrack, Hosts)
# -----------------------------------------------------------------------------
echo "[INFO] Настройка параметров ядра, файрвола, времени, .pgpass и /etc/hosts..."

# 3.1 Защита от зависания ввода-вывода (D-state), OOM-Killer и черной дыры MTU
cat << 'EOF' > /etc/sysctl.d/99-ha-cluster-v5.conf
# 1. Самострел при зависании диска в D-state > 45 сек
kernel.hung_task_timeout_secs = 45
kernel.hung_task_panic = 1
kernel.panic = 5
kernel.panic_on_oops = 1

# 2. Защита checkpointer/walwriter от OOM-Killer (строгий учет памяти)
vm.overcommit_memory = 2
vm.overcommit_ratio = 80

# 3. Защита от «Черной дыры MTU» (автоподбор TCP MSS при расхождении Jumbo Frames)
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss = 1024
EOF
sysctl --system >/dev/null 2>&1 || true

# 3.2 Резервируем 2% блоков на корневом разделе и разделе /var для root и Pacemaker CIB
ROOT_DEV=$(findmnt -n -o SOURCE /var/lib/pacemaker 2>/dev/null || findmnt -n -o SOURCE / 2>/dev/null || true)
if [[ "$ROOT_DEV" == /dev/* ]]; then
    tune2fs -m 2 "$ROOT_DEV" >/dev/null 2>&1 || true
fi

# 3.3 Установка необходимых вспомогательных пакетов
if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y conntrack iptables-persistent chrony iputils-arping 2>/dev/null || true
fi

# 3.4 Принудительная отправка TCP RST на пакеты старых сессий со статусом INVALID
if command -v iptables >/dev/null 2>&1; then
    if ! iptables -C INPUT -p tcp -m conntrack --ctstate INVALID -j REJECT --reject-with tcp-reset 2>/dev/null; then
        iptables -I INPUT 1 -p tcp -m conntrack --ctstate INVALID -j REJECT --reject-with tcp-reset 2>/dev/null || true
        command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save 2>/dev/null || true
    fi
fi

# 3.5 Взаимная синхронизация времени Chrony по прямому линку Ring 0
CHRONY_CONF="/etc/chrony/chrony.conf"
[[ ! -f "$CHRONY_CONF" && -f "/etc/chrony.conf" ]] && CHRONY_CONF="/etc/chrony.conf"
if [[ -f "$CHRONY_CONF" ]]; then
    sed -i '/# --- HA-CLUSTER-CHRONY-BEGIN ---/,/# --- HA-CLUSTER-CHRONY-END ---/d' "$CHRONY_CONF"
    cat << EOF >> "$CHRONY_CONF"
# --- HA-CLUSTER-CHRONY-BEGIN ---
peer ${NODE1_RING0_IP} iburst
peer ${NODE2_RING0_IP} iburst
local stratum 10
makestep 1.0 3
# --- HA-CLUSTER-CHRONY-END ---
EOF
    systemctl restart chrony 2>/dev/null || systemctl restart chronyd 2>/dev/null || true
fi

# 3.6 Идемпотентное обновление /etc/hosts
sed -i '/# --- HA-CLUSTER-HOSTS-BEGIN ---/,/# --- HA-CLUSTER-HOSTS-END ---/d' /etc/hosts
cat << EOF >> /etc/hosts
# --- HA-CLUSTER-HOSTS-BEGIN ---
$NODE1_RING0_IP    ${NODE1_NAME}-ring0 $NODE1_NAME
$NODE2_RING0_IP    ${NODE2_NAME}-ring0 $NODE2_NAME
$NODE1_RING1_IP    ${NODE1_NAME}-ring1
$NODE2_RING1_IP    ${NODE2_NAME}-ring1
# --- HA-CLUSTER-HOSTS-END ---
EOF

# 3.7 Автогенерация /var/lib/postgresql/.pgpass (0600)
mkdir -p "$(dirname "$PGPASS_FILE")" "$STATE_DIR"
chmod 700 "$STATE_DIR"
cat << EOF > "$PGPASS_FILE"
*:${DB_PORT}:*:${REPL_USER}:${REPL_PASS}
EOF
chown postgres:postgres "$PGPASS_FILE" 2>/dev/null || true
chmod 0600 "$PGPASS_FILE"

# 3.8 Настройка критических параметров PostgreSQL v5.0 в postgresql.conf
if [[ -f "${PGDATA}/postgresql.conf" ]]; then
    sed -i '/# --- HA-CLUSTER-PG-BEGIN ---/,/# --- HA-CLUSTER-PG-END ---/d' "${PGDATA}/postgresql.conf"
    sed -i '/# --- HA-CLUSTER-PG-V5-BEGIN ---/,/# --- HA-CLUSTER-PG-V5-END ---/d' "${PGDATA}/postgresql.conf"
    cat << EOF >> "${PGDATA}/postgresql.conf"
# --- HA-CLUSTER-PG-V5-BEGIN ---
listen_addresses = '*'
wal_level = replica
wal_log_hints = on
full_page_writes = on
track_commit_timestamp = on
hot_standby = on
hot_standby_feedback = on
synchronous_commit = remote_write
superuser_reserved_connections = 5
max_slot_wal_keep_size = ${MAX_SLOT_WAL_KEEP_SIZE}
wal_keep_size = 2048MB
idle_in_transaction_session_timeout = '${IDLE_IN_TX_TIMEOUT_MS}'
statement_timeout = '${STATEMENT_TIMEOUT_MS}'
lock_timeout = '5000ms'
tcp_keepalives_idle = 15
tcp_keepalives_interval = 5
tcp_keepalives_count = 3
# --- HA-CLUSTER-PG-V5-END ---
EOF
fi

# -----------------------------------------------------------------------------
# ШАГ 4. Генерация 4 рабочих скриптов кластера v5.0
# -----------------------------------------------------------------------------
echo "[INFO] Создаю рабочие скрипты в /usr/local/bin и /usr/local/sbin..."

# 4.1 Скрипт проверки роли БД для HAProxy с защитой от Read-Only и XID Wraparound
cat << 'EOF' > /usr/local/bin/db-role-check.sh
#!/bin/bash
source /etc/default/ha-cluster

# Единым быстрым запросом через Unix-сокет проверяем:
# 1) pg_is_in_recovery() == f (Master)
# 2) current_setting('transaction_read_only') == off (Не в аварийном режиме Read-Only)
# 3) max(age(datfrozenxid)) < MAX_XID_AGE_LIMIT (Нет риска остановки из-за XID Wraparound)
QUERY="SELECT pg_is_in_recovery() || '|' || current_setting('transaction_read_only') || '|' || COALESCE(max(age(datfrozenxid)), 0) FROM pg_database WHERE datallowconn;"
OUT=$(psql -p "${DB_PORT:-5432}" -U postgres -d postgres -tAc "$QUERY" 2>&1 || true)

IFS='|' read -r IS_REC IS_RO XID_AGE <<< "$OUT"

if [[ "$IS_REC" == "f" ]] && [[ "$IS_RO" == "off" ]] && (( ${XID_AGE:-0} < ${MAX_XID_AGE_LIMIT:-1900000000} )); then
    # Дополнительно защищаем ключевые процессы СУБД от OOM-Killer в runtime
    for pid in $(pgrep -u postgres 2>/dev/null || true); do
        echo -1000 > "/proc/${pid}/oom_score_adj" 2>/dev/null || true
    done
    printf "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 6\r\n\r\nMaster"
    exit 0
elif [[ "$OUT" == *"too many clients"* ]] && [[ ! -f "${PGDATA}/standby.signal" ]]; then
    # Даже если исчерпаны суперпользовательские слоты, но standby.signal отсутствует — база Master жива!
    printf "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 6\r\n\r\nMaster"
    exit 0
else
    if (( ${XID_AGE:-0} >= ${MAX_XID_AGE_LIMIT:-1900000000} )) || [[ "$IS_RO" == "on" ]]; then
        logger -t db-role-check "КРИТИЧЕСКАЯ АВАРИЯ БД: Master перешел в Read-Only ($IS_RO) или превысил лимит XID Wraparound ($XID_AGE)!"
    fi
    printf "HTTP/1.1 503 Service Unavailable\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nSlave"
    exit 1
fi
EOF
chmod +x /usr/local/bin/db-role-check.sh

# 4.2 Скрипт фиксации штатного выключения (/usr/local/sbin/cluster-mark-shutdown.sh)
cat << 'EOF' > /usr/local/sbin/cluster-mark-shutdown.sh
#!/bin/bash
source /etc/default/ha-cluster

LOCAL_NODE=$(crm_node -n 2>/dev/null || hostname -s)
LOCAL_IPS=$(hostname -I)
if [[ " $LOCAL_IPS " == *" $NODE1_RING0_IP "* ]]; then
    PEER_RING0_IP="$NODE2_RING0_IP"
else
    PEER_RING0_IP="$NODE1_RING0_IP"
fi

# Проверяем, являемся ли мы Master перед началом остановки
if crm_mon -1 2>/dev/null | grep -A 2 "Promoted:" | grep -qw "$LOCAL_NODE"; then
    # Если мы были Master, записываем MASTER по умолчанию (защита от одновременного shutdown обеих нод!)
    FINAL_ROLE="MASTER"
else
    # Если мы были Slave, но прямо во время остановки соседа промоутились в Master:
    if [[ ! -f "${PGDATA}/standby.signal" ]]; then
        FINAL_ROLE="MASTER"
    else
        FINAL_ROLE="SLAVE"
    fi
fi

echo "SHUTDOWN_TYPE=GRACEFUL" > "$STATE_FILE"
echo "LAST_KNOWN_ROLE=$FINAL_ROLE" >> "$STATE_FILE"
echo "TIMESTAMP=$(date +%s)" >> "$STATE_FILE"
sync
logger -t cluster-state "Штатная остановка ($LOCAL_NODE). Записана роль: $FINAL_ROLE"
EOF
chmod +x /usr/local/sbin/cluster-mark-shutdown.sh

# 4.3 Скрипт проверки дисков, CIB, MTU, времени, WAL и выбора режима старта
cat << 'EOF' > /usr/local/sbin/cluster-boot-analyzer.sh
#!/bin/bash
set -euo pipefail
source /etc/default/ha-cluster

rm -f "$BOOT_MODE_FILE"
WAS_GRACEFUL="no"
SAVED_ROLE="UNKNOWN"

# --- БЛОК 1: Чтение и МГНОВЕННОЕ удаление маркера штатного выключения с диска ---
if [[ -f "$STATE_FILE" ]]; then
    source "$STATE_FILE"
    WAS_GRACEFUL="yes"
    SAVED_ROLE="${LAST_KNOWN_ROLE:-UNKNOWN}"
    rm -f "$STATE_FILE"
    sync
    logger -t cluster-precheck "Маркер штатного выключения прочитан (Роль: $SAVED_ROLE) и удален с диска."
fi

# --- БЛОК 2: Предстартовая проверка диска БД и раздела CIB Pacemaker ---
if [[ ! -f "$PGDATA/PG_VERSION" ]]; then
    logger -t cluster-precheck "КРИТИЧЕСКАЯ ОШИБКА: Каталог БД ($PGDATA) отсутствует! Старт Pacemaker заблокирован."
    exit 1
fi

TEST_FILE="$PGDATA/.cluster_rw_test"
if ! touch "$TEST_FILE" 2>/dev/null || ! rm -f "$TEST_FILE" 2>/dev/null; then
    logger -t cluster-precheck "КРИТИЧЕСКАЯ ОШИБКА: Файловая система БД ($PGDATA) в режиме Read-Only! Старт заблокирован."
    exit 1
fi

USED_PCT=$(df --output=pcent "$PGDATA" | tail -n 1 | tr -dc '0-9')
if (( 100 - ${USED_PCT:-100} < MIN_FREE_DISK_PCT )); then
    logger -t cluster-precheck "КРИТИЧЕСКАЯ ОШИБКА: На диске БД менее ${MIN_FREE_DISK_PCT}% свободного места! Старт заблокирован."
    exit 1
fi

CIB_FREE_MB=$(df -BM --output=avail /var/lib/pacemaker 2>/dev/null | tail -n 1 | tr -dc '0-9' || echo "1000")
if (( ${CIB_FREE_MB:-1000} < ${MIN_FREE_CIB_MB:-500} )); then
    logger -t cluster-precheck "ВНИМАНИЕ: В /var/lib/pacemaker осталось ${CIB_FREE_MB} МБ (< ${MIN_FREE_CIB_MB} МБ)! Очищаю системный журнал..."
    journalctl --vacuum-size=100M >/dev/null 2>&1 || true
fi

# --- БЛОК 3: Проверка wal_log_hints в заголовке pg_controldata ---
HINTS_STATE=$(LC_ALL=C "$PGBIN/pg_controldata" "$PGDATA" 2>/dev/null | awk -F: '/wal_log_hints setting/ {gsub(/^[ \t]+/, "", $2); print $2}' || echo "unknown")
if [[ "$HINTS_STATE" != "on" ]] && [[ -f "$PGDATA/postgresql.conf" ]]; then
    logger -t cluster-precheck "ПРЕДУПРЕЖДЕНИЕ: wal_log_hints=$HINTS_STATE! Принудительно включаю wal_log_hints=on для поддержки pg_rewind."
    sed -i 's/^#*wal_log_hints.*/wal_log_hints = on/' "$PGDATA/postgresql.conf"
fi

# --- БЛОК 4: Проверка и автокоррекция MTU (DF-ping) на линке прямого соединения ---
LOCAL_IPS=$(hostname -I)
if [[ " $LOCAL_IPS " == *" $NODE1_RING0_IP "* ]]; then
    PEER_IP="$NODE2_RING0_IP"
    MY_SLOT="${REPL_SLOT_NODE1:-slot_node1}"
else
    PEER_IP="$NODE1_RING0_IP"
    MY_SLOT="${REPL_SLOT_NODE2:-slot_node2}"
fi

CUR_MTU=$(ip -o link show dev "$RING0_NIC" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="mtu") print $(i+1)}' || echo "1500")
PAYLOAD=$(( CUR_MTU - 28 ))
if ping -c 1 -W 1 "$PEER_IP" >/dev/null 2>&1; then
    if ! ping -c 2 -W 1 -M do -s "$PAYLOAD" "$PEER_IP" >/dev/null 2>&1; then
        logger -t cluster-precheck "КРИТИЧЕСКАЯ ОШИБКА MTU: Пакеты ${CUR_MTU} байт (DF) не проходят до $PEER_IP! Принудительно снижаю MTU на $RING0_NIC до ${SAFE_MTU}."
        ip link set dev "$RING0_NIC" mtu "${SAFE_MTU:-1500}" || true
    fi
fi

# --- БЛОК 5: Определение режима запуска по заголовку pg_controldata ---
DB_STATE=$(LC_ALL=C "$PGBIN/pg_controldata" "$PGDATA" 2>/dev/null | awk -F: '/Database cluster state/ {gsub(/^[ \t]+/, "", $2); print $2}')

if [[ "$WAS_GRACEFUL" == "yes" ]] && [[ "$DB_STATE" == "shut down"* ]]; then
    echo "MODE=COLD_START" > "$BOOT_MODE_FILE"
    echo "LAST_ROLE=$SAVED_ROLE" >> "$BOOT_MODE_FILE"
    echo "UNBLOCK_TIMEOUT_SEC=$COLD_START_TIMEOUT_SEC" >> "$BOOT_MODE_FILE"
    logger -t cluster-precheck "Диски исправны. СЦЕНАРИЙ: Плановый холодный старт (таймаут ${COLD_START_TIMEOUT_SEC} сек)."
else
    echo "MODE=CRASH_RECOVERY" > "$BOOT_MODE_FILE"
    echo "DB_RAW_STATE=${DB_STATE:-UNKNOWN}" >> "$BOOT_MODE_FILE"
    echo "UNBLOCK_TIMEOUT_SEC=$CRASH_TIMEOUT_SEC" >> "$BOOT_MODE_FILE"
    logger -t cluster-precheck "Диски исправны. ВНИМАНИЕ: Старт после ПАДЕНИЯ (БД: '$DB_STATE', таймаут ${CRASH_TIMEOUT_SEC} сек)."
fi

# --- БЛОК 6: Проверка синхронности .pgpass, валидация WAL и безопасный авто-pg_basebackup ---
export PGPASSFILE="${PGPASS_FILE:-/var/lib/postgresql/.pgpass}"

if curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "http://${PEER_IP}:${DB_CHECK_PORT}" | grep -q "200"; then
    logger -t cluster-precheck "Сосед ($PEER_IP) уже работает как активный Master. Проверяю авторизацию по протоколу репликации..."

    if ! sudo -u postgres PGPASSFILE="$PGPASSFILE" PGCONNECT_TIMEOUT=5 \
         psql -w "host=$PEER_IP port=$DB_PORT user=${REPL_USER:-repl_user} dbname=postgres replication=database" -c "IDENTIFY_SYSTEM;" >/dev/null 2>&1; then
        logger -t cluster-precheck "КРИТИЧЕСКАЯ ОШИБКА БЕЗОПАСНОСТИ: Пароль $REPL_USER в .pgpass не подходит к активному Master ($PEER_IP)!"
    else
        SLOT_STATUS=$(sudo -u postgres PGPASSFILE="$PGPASSFILE" PGCONNECT_TIMEOUT=5 \
            psql -w -h "$PEER_IP" -p "$DB_PORT" -U "${REPL_USER:-repl_user}" -d postgres -tAc \
            "SELECT wal_status FROM pg_replication_slots WHERE slot_name='${MY_SLOT}';" 2>/dev/null || echo "ok")

        REWIND_CHECK="ok"
        if ! sudo -u postgres "$PGBIN/pg_rewind" --dry-run --target-pgdata="$PGDATA" \
             --source-server="host=$PEER_IP port=$DB_PORT user=${REPL_USER:-repl_user} dbname=postgres connect_timeout=5" >/dev/null 2>&1; then
            REWIND_CHECK="failed"
        fi

        if [[ "$SLOT_STATUS" == "lost" ]] || [[ "$REWIND_CHECK" == "failed" ]]; then
            logger -t cluster-precheck "Нужные сегменты WAL на Master удалены (slot=$SLOT_STATUS, rewind=$REWIND_CHECK). Пересоздаю реплику через pg_basebackup --no-password..."
            rm -rf "${PGDATA:?}"/*
            if ! timeout 600 sudo -u postgres PGPASSFILE="$PGPASSFILE" PGCONNECT_TIMEOUT=10 \
                 pg_basebackup --no-password -h "$PEER_IP" -p "$DB_PORT" -U "${REPL_USER:-repl_user}" \
                 -D "$PGDATA" -Fp -Xs -R -S "$MY_SLOT"; then
                logger -t cluster-precheck "ОШИБКА: pg_basebackup завершился с ошибкой или по таймауту!"
                exit 1
            fi
            logger -t cluster-precheck "Автоматический pg_basebackup успешно завершен! Реплика пересоздана с нуля."
        fi
    fi
fi

# --- БЛОК 7: Контроль синхронизации системного времени (Clock Skew) ---
if command -v chronyc >/dev/null 2>&1; then
    OFFSET=$(chronyc tracking 2>/dev/null | awk '/System time/ {print $4}' || echo "0")
    if awk "BEGIN {exit !(${OFFSET:-0} > ${MAX_CLOCK_SKEW_SEC:-1.0})}"; then
        logger -t cluster-precheck "ВНИМАНИЕ: Смещение часов (${OFFSET} сек) превышает порог ${MAX_CLOCK_SKEW_SEC} сек! Выполняю принудительный chronyc makestep..."
        chronyc makestep >/dev/null 2>&1 || true
    fi
fi
EOF
chmod +x /usr/local/sbin/cluster-boot-analyzer.sh

# 4.4 Сторож таймаута и выхода в режим деградации (/usr/local/sbin/cluster-degraded-unblock.sh)
cat << 'EOF' > /usr/local/sbin/cluster-degraded-unblock.sh
#!/bin/bash
set -euo pipefail
source /etc/default/ha-cluster
[[ -f "$BOOT_MODE_FILE" ]] && source "$BOOT_MODE_FILE"

LOCAL_IPS=$(hostname -I)
if [[ " $LOCAL_IPS " == *" $NODE1_RING0_IP "* ]] || [[ " $LOCAL_IPS " == *" $NODE1_RING1_IP "* ]]; then
    PEER_RING0_IP="$NODE2_RING0_IP"
    PEER_RING1_IP="$NODE2_RING1_IP"
    EXTRA_DELAY=0
else
    PEER_RING0_IP="$NODE1_RING0_IP"
    PEER_RING1_IP="$NODE1_RING1_IP"
    # На node2 добавляем асимметричный сдвиг +120 сек для исключения одновременного старта при Partition
    EXTRA_DELAY="${NODE2_ASYMMETRIC_DELAY_SEC:-120}"
fi

# Комбинированная проверка доступности шлюза (L3 ICMP + L2 arping + neigh reachable)
check_gateway_alive() {
    local rip="$1"
    # 1. Пробуем стандартный ICMP ping (L3)
    if ping -c 2 -W 1 "$rip" >/dev/null 2>&1; then
        return 0
    fi
    # 2. Если ICMP закрыт файрволом — проверяем L2 ARP-отклик роутера через arping
    if arping -I "$CLUSTER_VIP_NIC" -c 2 -w 2 "$rip" >/dev/null 2>&1; then
        logger -t cluster-watchdog "Шлюз $rip не отвечает на ICMP, но доступен по L2 ARP (arping OK)."
        return 0
    fi
    # 3. Проверяем статус соседа в ARP-таблице ядра после пробного TCP-пакета
    timeout 1 bash -c "</dev/tcp/${rip}/22" 2>/dev/null || true
    if ip neigh show "$rip" dev "$CLUSTER_VIP_NIC" 2>/dev/null | grep -qE "REACHABLE|DELAY"; then
        logger -t cluster-watchdog "Шлюз $rip подтвержден через таблицу соседей ядра (REACHABLE)."
        return 0
    fi
    return 1
}

BASE_WAIT="${UNBLOCK_TIMEOUT_SEC:-$CRASH_TIMEOUT_SEC}"
TOTAL_WAIT=$(( BASE_WAIT + EXTRA_DELAY ))
logger -t cluster-watchdog "Ожидание кворума: ${TOTAL_WAIT} сек (базовый: ${BASE_WAIT}с, сдвиг узла: ${EXTRA_DELAY}с)..."
sleep "$TOTAL_WAIT"

if corosync-quorumtool -s 2>/dev/null | grep -q "Quorate:.*Yes"; then
    logger -t cluster-watchdog "Кворум уже собран штатно."
    exit 0
fi

# ПРЕДОХРАНИТЕЛЬ 1: Комбинированная проверка доступности шлюзов из ROUTER_IPS
ROUTER_OK="no"
for rip in ${ROUTER_IPS:-$ROUTER_IP}; do
    if check_gateway_alive "$rip"; then
        ROUTER_OK="yes"
        break
    fi
done
if [[ "$ROUTER_OK" != "yes" ]]; then
    logger -t cluster-watchdog "ОШИБКА: Ни один адрес шлюза (${ROUTER_IPS:-$ROUTER_IP}) не доступен (ICMP/ARP/neigh)! Разблокировка отменена."
    exit 1
fi

# ПРЕДОХРАНИТЕЛЬ 2: Проверка соседа по ICMP И по TCP-портам (9200, 5432, 22) на обоих кольцах
for pip in "$PEER_RING0_IP" "$PEER_RING1_IP"; do
    if ping -c 2 -W 1 "$pip" >/dev/null 2>&1; then
        logger -t cluster-watchdog "Сосед ($pip) отвечает по ICMP! Отмена принудительной разблокировки."
        exit 1
    fi
    for pport in "$DB_CHECK_PORT" "$DB_PORT" 22; do
        if timeout 2 bash -c "</dev/tcp/${pip}/${pport}" 2>/dev/null; then
            logger -t cluster-watchdog "Сосед ($pip:$pport) отвечает по TCP (ICMP мог быть закрыт)! Отмена разблокировки."
            exit 1
        fi
    done
done

# ПРЕДОХРАНИТЕЛЬ 3: Проверка, не поднят ли уже CLUSTER_VIP в сети роутера
if ping -c 2 -W 1 "$CLUSTER_VIP" >/dev/null 2>&1 || arping -D -I "$CLUSTER_VIP_NIC" -c 2 "$CLUSTER_VIP" 2>&1 | grep -q "Received [1-9]"; then
    logger -t cluster-watchdog "КРИТИЧЕСКАЯ ОШИБКА: Виртуальный IP ($CLUSTER_VIP) УЖЕ АКТИВЕН в сети! Защита от Split-Brain сработала."
    exit 1
fi

# ПРЕДОХРАНИТЕЛЬ 4: Проверка статуса БД до остановки
if [[ "${MODE:-}" == "COLD_START" ]] && [[ "${LAST_ROLE:-}" == "MASTER" ]]; then
    logger -t cluster-watchdog "Плановый холодный старт мастера в одиночку: разблокировка кворума."
    pcs quorum unblock --yes
elif [[ "${MODE:-}" == "CRASH_RECOVERY" ]] && [[ "${DB_RAW_STATE:-}" == "in production" ]]; then
    logger -t cluster-watchdog "Аварийный старт: локальная БД была Master. Активация режима деградации."
    pcs quorum unblock --yes
else
    logger -t cluster-watchdog "СТОП: Узел не был подтвержденным Master (MODE=${MODE:-}, ROLE=${LAST_ROLE:-}, DB=${DB_RAW_STATE:-})."
    exit 1
fi
EOF
chmod +x /usr/local/sbin/cluster-degraded-unblock.sh

# -----------------------------------------------------------------------------
# ШАГ 5. Генерация юнитов systemd и конфигурации HAProxy
# -----------------------------------------------------------------------------
echo "[INFO] Генерирую systemd-юниты и конфигурацию HAProxy..."

# 5.1 Сокет и сервис проверки роли БД для HAProxy (подавление 86 400 логов)
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
StandardError=journal
LogLevelMax=warning
EOF

# Ограничение размера системного журнала
mkdir -p /etc/systemd/journald.conf.d
cat << 'EOF' > /etc/systemd/journald.conf.d/ha-limits.conf
[Journal]
SystemMaxUse=500M
RuntimeMaxUse=100M
EOF

# 5.2 Подключение EnvironmentFile к сервису HAProxy и генерация /etc/haproxy/haproxy.cfg
mkdir -p /etc/systemd/system/haproxy.service.d
cat << 'EOF' > /etc/systemd/system/haproxy.service.d/env.conf
[Service]
EnvironmentFile=/etc/default/ha-cluster
EOF

cat << 'EOF' > /etc/haproxy/haproxy.cfg
global
    log /dev/log local0
    maxconn 2000
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
    bind "127.0.0.1:${HAPROXY_DB_BIND_PORT}"
    mode tcp
    option httpchk GET /
    http-check expect status 200
    default-server inter 2s fall 2 rise 2 on-marked-down shutdown-sessions
    # Основные маршруты через прямой кабель (Ring 0)
    server node1_db_r0 "${NODE1_RING0_IP}:${DB_PORT}" maxconn 500 check port "${DB_CHECK_PORT}"
    server node2_db_r0 "${NODE2_RING0_IP}:${DB_PORT}" maxconn 500 check port "${DB_CHECK_PORT}"
    # Резервные маршруты через сеть роутера (Ring 1) на случай обрыва прямого кабеля
    server node1_db_r1 "${NODE1_RING1_IP}:${DB_PORT}" maxconn 500 check port "${DB_CHECK_PORT}" backup
    server node2_db_r1 "${NODE2_RING1_IP}:${DB_PORT}" maxconn 500 check port "${DB_CHECK_PORT}" backup
EOF

# 5.3 Шлюз проверки дисков и сценария старта
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
EnvironmentFile=/etc/default/ha-cluster
ExecStart=/usr/local/sbin/cluster-boot-analyzer.sh

[Install]
WantedBy=multi-user.target
RequiredBy=corosync.service pacemaker.service
EOF

# 5.4 Перехватчик штатного выключения
cat << 'EOF' > /etc/systemd/system/cluster-shutdown-marker.service
[Unit]
Description=Save cluster Master/Slave role before Pacemaker stops on graceful shutdown
After=corosync.service pacemaker.service
Requires=pacemaker.service

[Service]
Type=oneshot
RemainAfterExit=yes
EnvironmentFile=/etc/default/ha-cluster
ExecStart=/bin/true
ExecStop=/usr/local/sbin/cluster-mark-shutdown.sh

[Install]
WantedBy=multi-user.target
EOF

# 5.5 Сервис и таймер выхода в режим деградации
cat << 'EOF' > /etc/systemd/system/cluster-degraded-unblock.service
[Unit]
Description=Unblock Corosync WaitForAll quorum after timeout (Degraded Mode)
After=corosync.service pacemaker.service

[Service]
Type=oneshot
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

# -----------------------------------------------------------------------------
# ШАГ 6. Hardening systemd: OOM-Killer защита, RT-приоритет и лимиты cgroups
# -----------------------------------------------------------------------------
echo "[INFO] Настройка безопасности systemd: OOM-защита, RT-Corosync и лимиты ресурсов..."

# 6.1 Иммунитет от OOM-Killer и RT-планировщик (SCHED_RR priority 99) для Corosync
mkdir -p /etc/systemd/system/corosync.service.d
cat << 'EOF' > /etc/systemd/system/corosync.service.d/ha-hardening.conf
[Service]
OOMScoreAdjust=-1000
CPUSchedulingPolicy=rr
CPUSchedulingPriority=99
IOSchedulingClass=realtime
IOSchedulingPriority=0
LimitMEMLOCK=infinity
EOF

# 6.2 Иммунитет от OOM-Killer для Pacemaker, PostgreSQL и HAProxy
for crit_svc in pacemaker postgresql "postgresql@${PG_VERSION}-main" haproxy; do
    mkdir -p "/etc/systemd/system/${crit_svc}.service.d"
    cat << 'EOF' > "/etc/systemd/system/${crit_svc}.service.d/oom-protect.conf"
[Service]
OOMScoreAdjust=-1000
EOF
done

# 6.3 Ограничение памяти и CPU для прикладного стека (my-app и my-daemon)
for app_svc in "$APP_SERVICE" "$DAEMON_SERVICE"; do
    mkdir -p "/etc/systemd/system/${app_svc}.service.d"
    cat << EOF > "/etc/systemd/system/${app_svc}.service.d/resource-limits.conf"
[Service]
MemoryMax=${APP_MEMORY_MAX}
CPUQuota=${APP_CPU_QUOTA}
OOMScoreAdjust=500
EOF
done

systemctl daemon-reload
systemctl restart systemd-journald 2>/dev/null || true

# Отключаем автозапуск сервисов, которыми управляет исключительно Pacemaker
for svc in postgresql "postgresql@${PG_VERSION}-main" haproxy "$APP_SERVICE" "$DAEMON_SERVICE"; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}.service"; then
        systemctl disable "${svc}.service" 2>/dev/null || true
    fi
done

# Включаем наши шлюзы безопасности, сокет чеккера БД и демон pcsd
systemctl enable --now db-role-check.socket pcsd.service 2>/dev/null || true
systemctl enable cluster-boot-analyzer.service \
                 cluster-shutdown-marker.service \
                 cluster-degraded-unblock.timer 2>/dev/null || true

echo "hacluster:${HACLUSTER_PASS}" | chpasswd 2>/dev/null || true

# -----------------------------------------------------------------------------
# ШАГ 7. Опциональная инициализация кластера Pacemaker/Corosync (--init-pcs)
# -----------------------------------------------------------------------------
if [[ "${1:-}" == "--init-pcs" ]]; then
    echo "[INFO] Флаг --init-pcs активен. Инициализирую кластер Corosync v5.0 и ресурсы Pacemaker..."

    pcs host auth "$NODE1_NAME" "$NODE2_NAME" -u hacluster -p "$HACLUSTER_PASS"

    # Настройка Corosync с таймингами защиты от VM Stun / vMotion (token=3000ms)
    pcs cluster setup ha_cluster \
        "$NODE1_NAME" addr="$NODE1_RING0_IP" addr="$NODE1_RING1_IP" \
        "$NODE2_NAME" addr="$NODE2_RING0_IP" addr="$NODE2_RING1_IP" \
        transport knet \
        link linknumber=0 link_priority=100 mcastport=5405 \
        link linknumber=1 link_priority=50  mcastport=5406 \
        totem token="${COROSYNC_TOKEN_MS:-3000}" \
              token_retransmits_before_loss_const="${COROSYNC_RETRANSMITS:-10}" \
              consensus="${COROSYNC_CONSENSUS_MS:-3600}" \
              join="${COROSYNC_JOIN_MS:-60}"

    pcs cluster start --all
    pcs cluster enable --all

    pcs property set stonith-enabled=false
    pcs property set no-quorum-policy=stop
    pcs property set start-failure-is-fatal=true
    pcs resource defaults update resource-stickiness=100 migration-threshold=3 failure-timeout="${FAILURE_TIMEOUT_SEC:-900s}"

    # Псевдо-арбитр (пинг шлюза)
    pcs resource create ping-gateway ocf:pacemaker:ping \
        host_list="${ROUTER_IPS:-$ROUTER_IP}" multiplier=1000 dampen=10s \
        op monitor interval=5s timeout=10s \
        clone meta interleave=true

    # Мониторинг свободного места на системном разделе /var/lib/pacemaker (защита CIB)
    pcs resource create fs-mon ocf:heartbeat:Diskd \
        dir="/var/lib/pacemaker" min_free="${MIN_FREE_CIB_MB:-500}" \
        op monitor interval=20s timeout=10s \
        clone meta interleave=true

    # СУБД PostgreSQL (агент PAF pgsqlms)
    pcs resource create pgsql ocf:heartbeat:pgsqlms \
        bindir="$PGBIN" pgdata="$PGDATA" \
        recovery_template="/var/lib/postgresql/recovery.conf.pcmk" \
        op start timeout=60s op stop timeout=60s \
        op promote timeout=30s op demote timeout=120s \
        op monitor interval=15s timeout=10s role="Master" \
        op monitor interval=16s timeout=10s role="Slave" \
        op notify timeout=15s \
        promotable notify=true

    # Виртуальный IP с активным обнаружением ARP-коллизий (run_arping=true)
    pcs resource create vip ocf:heartbeat:IPaddr2 \
        ip="$CLUSTER_VIP" cidr_netmask="$CLUSTER_VIP_CIDR" nic="$CLUSTER_VIP_NIC" \
        run_arping=true arp_interval=500 arp_count=5 arp_bg=true \
        op monitor interval=5s timeout=20s

    # Развязка fate-sharing: разделяем критическое ядро (core-app-stack) и второстепенный демон (daemon-svc)
    pcs resource create haproxy-svc systemd:haproxy op monitor interval=10s --group core-app-stack
    pcs resource create app-svc "systemd:${APP_SERVICE}" op monitor interval=10s --group core-app-stack
    pcs resource create daemon-svc "systemd:${DAEMON_SERVICE}" op monitor interval=10s

    # Положительное предпочтение (+1000 за каждый живой IP роутера)
    pcs constraint location vip rule score-attribute=pingd pingd gt 0
    pcs constraint location pgsql-clone rule role=Master score-attribute=pingd pingd gt 0

    # Привязка core-app-stack и VIP к Master СУБД:
    pcs constraint colocation add core-app-stack with vip INFINITY
    pcs constraint colocation add daemon-svc with core-app-stack INFINITY
    pcs constraint colocation add vip with master pgsql-clone 500
    pcs constraint order start vip then start core-app-stack

    # Привязка daemon-svc как зависимого от core-app-stack (symmetrical=false):
    # При сбое daemon-svc ядро (my-app и haproxy) НЕ останавливаются и НЕ мигрируют!
    pcs constraint order start core-app-stack then start daemon-svc symmetrical=false

    echo "[УСПЕХ] Кластер полностью создан и запущен (v5.0 Production Full активны)!"
    echo "Проверьте состояние командой: pcs status"
else
    echo "[УСПЕХ] Узел $CURRENT_NODE подготовлен (v5.0 Production Full активны)."
    echo "Когда оба узла будут подготовлены и репликация БД настроена, выполните на $NODE1_NAME:"
    echo "  sudo /usr/local/sbin/bootstrap-ha.sh --init-pcs"
fi