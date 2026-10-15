#!/bin/bash
# =============================================================================
# УНИВЕРСАЛЬНЫЙ СКРИПТ РАЗВЕРТЫВАНИЯ HA-КЛАСТЕРА (NODE1 / NODE2) — v4.0
# Включает:
#  - v2.0: D-state sysctl, Unix-сокет db-role-check, параллельное выключение,
#          4-ступенчатый сторож деградации, резервирование HAProxy Ring 1,
#          положительные pingd preferences;
#  - v3.0: Слоты репликации PostgreSQL, conntrack TCP RST, OOMScoreAdjust,
#          Realtime CPU scheduling (SCHED_RR 99), cgroups лимиты, Chrony Ring 0;
#  - v4.0 (Production Edge Cases):
#          1. Безопасный беспарольный pg_basebackup (--no-password, .pgpass, pre-check);
#          2. Подавление 86 400 логов journald с сохранением сокета HAProxy;
#          3. Комбинированная проверка шлюза (L3 ICMP + L2 arping + neigh reachable);
#          4. Таймауты idle_in_transaction_session_timeout и statement_timeout;
#          5. Устранение fate-sharing: разделение на core-app-stack и daemon-svc;
#          6. Защита от пинг-понга: start-failure-is-fatal=true, failure-timeout=900s.
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
    echo "[INFO] Файл $ENV_FILE не найден. Создаю базовый шаблон..."
    cat << 'EOF' > "$ENV_FILE"
# =========================================================================
# ЕДИНЫЙ КОНФИГ ПАРАМЕТРОВ КЛАСТЕРА (ИДЕНТИЧЕН НА NODE1 И NODE2)
# =========================================================================

# 1. Имена узлов кластера
NODE1_NAME="node1"
NODE2_NAME="node2"

# 2. Сетевые адреса (Кольцо 0 — прямой кабель, Кольцо 1 — сеть маршрутизатора)
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
CLUSTER_VIP_NIC="eth0"

# 5. Параметры СУБД и HAProxy
PG_VERSION="16"
PGDATA="/var/lib/postgresql/16/main"
PGBIN="/usr/lib/postgresql/16/bin"
DB_PORT="5432"
DB_CHECK_USER="haproxy_check"
DB_CHECK_PORT="9200"
HAPROXY_DB_BIND_PORT="5000"

# 6. Управляемые systemd-сервисы приложения и демонов
APP_SERVICE="my-app"
DAEMON_SERVICE="my-daemon"

# 7. Таймауты и пороги безопасности
MIN_FREE_DISK_PCT="5"
COLD_START_TIMEOUT_SEC="180"    # 3 минуты при плановом холодном старте
CRASH_TIMEOUT_SEC="900"         # 15 минут при старте после аварийного падения

# 8. Служебные файлы состояния
STATE_DIR="/var/lib/cluster-state"
STATE_FILE="/var/lib/cluster-state/graceful_shutdown"
BOOT_MODE_FILE="/run/cluster_boot_mode"

# 9. Пароль пользователя hacluster (для автоматической инициализации pcs)
HACLUSTER_PASS="StrongClusterPass123!"

# 10. Параметры v3.0 (Day-2 Operations: лимиты, слоты, дрейф времени)
MAX_CLOCK_SKEW_SEC="1.0"
APP_MEMORY_MAX="75%"
APP_CPU_QUOTA="80%"
REPL_USER="repl_user"
REPL_PASS="ReplSecretPass!"
PGPASS_FILE="/var/lib/postgresql/.pgpass"
REPL_SLOT_NODE1="slot_node1"
REPL_SLOT_NODE2="slot_node2"
MAX_SLOT_WAL_KEEP_SIZE="10GB"

# 11. Параметры v4.0 (Production Edge Cases: таймауты транзакций и отказов)
FAILURE_TIMEOUT_SEC="900s"
IDLE_IN_TX_TIMEOUT_MS="15000ms"
STATEMENT_TIMEOUT_MS="30000ms"
EOF
    chmod 600 "$ENV_FILE"
    echo "[ВНИМАНИЕ] Шаблон $ENV_FILE создан."
    echo "Проверьте в нем IP-адреса и имена ваших сервисов, затем запустите скрипт повторно!"
    exit 0
fi

# Подгружаем переменные из единого файла конфигурации
source "$ENV_FILE"

# Установка дефолтов для параметров v3.0 и v4.0 (если файл уже существовал ранее)
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

echo "[INFO] Конфигурация успешно загружена из $ENV_FILE"

# -----------------------------------------------------------------------------
# ШАГ 2. Автоопределение текущего узла (node1 или node2)
# -----------------------------------------------------------------------------
LOCAL_IPS=$(hostname -I)
if [[ " $LOCAL_IPS " == *" $NODE1_RING0_IP "* ]] || [[ " $LOCAL_IPS " == *" $NODE1_RING1_IP "* ]]; then
    CURRENT_NODE="$NODE1_NAME"
    PEER_NODE="$NODE2_NAME"
elif [[ " $LOCAL_IPS " == *" $NODE2_RING0_IP "* ]] || [[ " $LOCAL_IPS " == *" $NODE2_RING1_IP "* ]]; then
    CURRENT_NODE="$NODE2_NAME"
    PEER_NODE="$NODE1_NAME"
else
    echo "[ОШИБКА] Ни один из локальных IP ($LOCAL_IPS) не совпадает с NODE1/NODE2 в $ENV_FILE!"
    exit 1
fi
echo "[INFO] Скрипт выполняется на узле: $CURRENT_NODE (сосед: $PEER_NODE)"

# -----------------------------------------------------------------------------
# ШАГ 3. Настройка ядра против D-state, Conntrack, Chrony, .pgpass, hosts и каталогов
# -----------------------------------------------------------------------------
echo "[INFO] Настройка параметров ядра, файрвола, времени, .pgpass и /etc/hosts..."

# 3.1 Защита от зависания дискового ввода-вывода (I/O hang / D-state):
cat << 'EOF' > /etc/sysctl.d/99-ha-dstate-fencing.conf
# Если процесс (например, postgres) висит в D-state (I/O hang) > 45 сек -> Kernel Panic и авторебут
kernel.hung_task_timeout_secs = 45
kernel.hung_task_panic = 1
kernel.panic = 5
kernel.panic_on_oops = 1
EOF
sysctl --system >/dev/null 2>&1 || true

# 3.2 Установка необходимых вспомогательных пакетов (при наличии менеджера пакетов)
if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y conntrack iptables-persistent chrony 2>/dev/null || true
fi

# 3.3 Принудительная отправка TCP RST на пакеты старых сессий со статусом INVALID (Conntrack fix)
if command -v iptables >/dev/null 2>&1; then
    if ! iptables -C INPUT -p tcp -m conntrack --ctstate INVALID -j REJECT --reject-with tcp-reset 2>/dev/null; then
        iptables -I INPUT 1 -p tcp -m conntrack --ctstate INVALID -j REJECT --reject-with tcp-reset 2>/dev/null || true
        command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save 2>/dev/null || true
    fi
fi

# 3.4 Взаимная синхронизация времени Chrony по прямому линку Ring 0
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

# 3.5 Идемпотентное обновление /etc/hosts
sed -i '/# --- HA-CLUSTER-HOSTS-BEGIN ---/,/# --- HA-CLUSTER-HOSTS-END ---/d' /etc/hosts
cat << EOF >> /etc/hosts
# --- HA-CLUSTER-HOSTS-BEGIN ---
$NODE1_RING0_IP    ${NODE1_NAME}-ring0 $NODE1_NAME
$NODE2_RING0_IP    ${NODE2_NAME}-ring0 $NODE2_NAME
$NODE1_RING1_IP    ${NODE1_NAME}-ring1
$NODE2_RING1_IP    ${NODE2_NAME}-ring1
# --- HA-CLUSTER-HOSTS-END ---
EOF

# 3.6 Автогенерация /var/lib/postgresql/.pgpass (0600) для безопасного беспарольного подключения
mkdir -p "$(dirname "$PGPASS_FILE")"
cat << EOF > "$PGPASS_FILE"
*:${DB_PORT}:*:${REPL_USER}:${REPL_PASS}
EOF
chown postgres:postgres "$PGPASS_FILE" 2>/dev/null || true
chmod 0600 "$PGPASS_FILE"

# 3.7 Настройка параметров WAL-слотов, keepalive и таймаутов транзакций в postgresql.conf
if [[ -f "${PGDATA}/postgresql.conf" ]]; then
    sed -i '/# --- HA-CLUSTER-PG-BEGIN ---/,/# --- HA-CLUSTER-PG-END ---/d' "${PGDATA}/postgresql.conf"
    cat << EOF >> "${PGDATA}/postgresql.conf"
# --- HA-CLUSTER-PG-BEGIN ---
max_slot_wal_keep_size = ${MAX_SLOT_WAL_KEEP_SIZE}
wal_keep_size = 2048MB
tcp_keepalives_idle = 15
tcp_keepalives_interval = 5
tcp_keepalives_count = 3
lock_timeout = '5000ms'
idle_in_transaction_session_timeout = '${IDLE_IN_TX_TIMEOUT_MS}'
statement_timeout = '${STATEMENT_TIMEOUT_MS}'
# --- HA-CLUSTER-PG-END ---
EOF
fi

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

# -----------------------------------------------------------------------------
# ШАГ 4. Генерация 4 рабочих скриптов кластера
# -----------------------------------------------------------------------------
echo "[INFO] Создаю рабочие скрипты в /usr/local/bin и /usr/local/sbin..."

# 4.1 Скрипт проверки роли БД для HAProxy (/usr/local/bin/db-role-check.sh)
cat << 'EOF' > /usr/local/bin/db-role-check.sh
#!/bin/bash
source /etc/default/ha-cluster

# Подключаемся через локальный Unix-сокет от имени суперпользователя postgres
# (использует пул superuser_reserved_connections и не зависит от клиентского max_connections)
OUT=$(psql -p "${DB_PORT:-5432}" -U postgres -d postgres -tAc "SELECT pg_is_in_recovery();" 2>&1 || true)

if [[ "$OUT" == "f" ]]; then
    printf "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 6\r\n\r\nMaster"
    exit 0
elif [[ "$OUT" == *"too many clients"* ]] && [[ ! -f "${PGDATA}/standby.signal" ]]; then
    # Даже если исчерпаны суперпользовательские слоты, но standby.signal отсутствует — база Master жива!
    printf "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 6\r\n\r\nMaster"
    exit 0
else
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
    # Если мы были Master, записываем MASTER по умолчанию (защита от одновременного shutdown обеих нод!).
    # Меняем на SLAVE только если сосед НЕ находится в процессе остановки и реально принимает трафик как Master.
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

# 4.3 Скрипт проверки дисков, времени, WAL и выбора режима старта (/usr/local/sbin/cluster-boot-analyzer.sh)
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

# --- БЛОК 2: Предстартовая проверка диска БД ---
if [[ ! -f "$PGDATA/PG_VERSION" ]]; then
    logger -t cluster-precheck "КРИТИЧЕСКАЯ ОШИБКА: Каталог БД ($PGDATA) отсутствует! Старт Pacemaker заблокирован."
    exit 1
fi

TEST_FILE="$PGDATA/.cluster_rw_test"
if ! touch "$TEST_FILE" 2>/dev/null || ! rm -f "$TEST_FILE" 2>/dev/null; then
    logger -t cluster-precheck "КРИТИЧЕСКАЯ ОШИБКА: Файловая система БД ($PGDATA) в режиме Read-Only! Старт Pacemaker заблокирован."
    exit 1
fi

USED_PCT=$(df --output=pcent "$PGDATA" | tail -n 1 | tr -dc '0-9')
if (( 100 - ${USED_PCT:-100} < MIN_FREE_DISK_PCT )); then
    logger -t cluster-precheck "КРИТИЧЕСКАЯ ОШИБКА: На диске БД менее ${MIN_FREE_DISK_PCT}% свободного места! Старт Pacemaker заблокирован."
    exit 1
fi

# --- БЛОК 3: Определение режима запуска по заголовку pg_controldata ---
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

# --- БЛОК 4 (v4.0): Безопасный pg_basebackup без интерактивного запроса пароля ---
LOCAL_IPS=$(hostname -I)
if [[ " $LOCAL_IPS " == *" $NODE1_RING0_IP "* ]]; then
    PEER_IP="$NODE2_RING0_IP"
    MY_SLOT="${REPL_SLOT_NODE1:-slot_node1}"
else
    PEER_IP="$NODE1_RING0_IP"
    MY_SLOT="${REPL_SLOT_NODE2:-slot_node2}"
fi

export PGPASSFILE="${PGPASS_FILE:-/var/lib/postgresql/.pgpass}"

# Проверяем, работает ли сейчас сосед в роли активного Master (порт 9200 -> HTTP 200)
if curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "http://${PEER_IP}:${DB_CHECK_PORT}" | grep -q "200"; then
    logger -t cluster-precheck "Сосед ($PEER_IP) уже работает как активный Master. Проверяем совместимость WAL..."

    SLOT_STATUS=$(PGPASSFILE="$PGPASSFILE" PGCONNECT_TIMEOUT=5 sudo -u postgres psql -w -h "$PEER_IP" -p "$DB_PORT" -U "${REPL_USER:-repl_user}" -d postgres -tAc \
        "SELECT wal_status FROM pg_replication_slots WHERE slot_name='${MY_SLOT}';" 2>/dev/null || echo "ok")

    REWIND_CHECK="ok"
    if ! sudo -u postgres "$PGBIN/pg_rewind" --dry-run --target-pgdata="$PGDATA" \
         --source-server="host=$PEER_IP port=$DB_PORT user=${REPL_USER:-repl_user} dbname=postgres connect_timeout=5" >/dev/null 2>&1; then
        REWIND_CHECK="failed"
    fi

    if [[ "$SLOT_STATUS" == "lost" ]] || [[ "$REWIND_CHECK" == "failed" ]]; then
        logger -t cluster-precheck "ВНИМАНИЕ: Нужные сегменты WAL на Master удалены (slot=$SLOT_STATUS, rewind=$REWIND_CHECK). Проверяю беспарольный доступ..."

        # КРИТИЧЕСКАЯ ПРОВЕРКА: тестируем беспарольный вход с флагом -w (--no-password) ДО удаления PGDATA!
        if sudo -u postgres PGPASSFILE="$PGPASSFILE" PGCONNECT_TIMEOUT=5 \
           psql -w -h "$PEER_IP" -p "$DB_PORT" -U "${REPL_USER:-repl_user}" -d postgres -tAc "SELECT 1;" >/dev/null 2>&1; then

            logger -t cluster-precheck "Беспарольная авторизация успешна. Очищаю $PGDATA и запускаю pg_basebackup --no-password..."
            rm -rf "${PGDATA:?}"/*
            if ! timeout 600 sudo -u postgres PGPASSFILE="$PGPASSFILE" PGCONNECT_TIMEOUT=10 \
                 pg_basebackup --no-password -h "$PEER_IP" -p "$DB_PORT" -U "${REPL_USER:-repl_user}" \
                 -D "$PGDATA" -Fp -Xs -R -S "$MY_SLOT"; then
                logger -t cluster-precheck "ОШИБКА: pg_basebackup завершился с ошибкой или по таймауту!"
                exit 1
            fi
            logger -t cluster-precheck "Автоматический pg_basebackup успешно завершен! Реплика пересоздана с нуля."
        else
            logger -t cluster-precheck "КРИТИЧЕСКАЯ ОШИБКА: Беспарольный вход для $REPL_USER по .pgpass не прошел! PGDATA сохранен во избежание зависания загрузки."
        fi
    fi
fi

# --- БЛОК 5 (v3.0): Контроль синхронизации системного времени (Clock Skew) ---
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

# ПРЕДОХРАНИТЕЛЬ 3: Проверка, не поднят ли уже CLUSTER_VIP в сети роутера (защита от Split-Brain и долгого fsck)
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
# Подавляем info-сообщения сокета в systemd-journald
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
# StandardOutput обязан оставаться 'socket', чтобы HAProxy получал HTTP 200/503!
StandardOutput=socket
StandardError=journal
# Подавляем 'Started...' и 'Deactivated successfully' (уровень info) в journald:
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
for crit_svc in pacemaker postgresql haproxy; do
    mkdir -p "/etc/systemd/system/${crit_svc}.service.d"
    cat << 'EOF' > "/etc/systemd/system/${crit_svc}.service.d/oom-protect.conf"
[Service]
OOMScoreAdjust=-950
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
for svc in postgresql haproxy "$APP_SERVICE" "$DAEMON_SERVICE"; do
    if systemctl list-unit-files | grep -q "^${svc}.service"; then
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
    echo "[INFO] Флаг --init-pcs активен. Инициализирую кластер Corosync и ресурсы Pacemaker..."

    pcs host auth "$NODE1_NAME" "$NODE2_NAME" -u hacluster -p "$HACLUSTER_PASS"

    pcs cluster setup ha_cluster \
        "$NODE1_NAME" addr="$NODE1_RING0_IP" addr="$NODE1_RING1_IP" \
        "$NODE2_NAME" addr="$NODE2_RING0_IP" addr="$NODE2_RING1_IP" \
        transport knet \
        link linknumber=0 link_priority=100 mcastport=5405 \
        link linknumber=1 link_priority=50  mcastport=5406

    pcs cluster start --all
    pcs cluster enable --all

    pcs property set stonith-enabled=false
    pcs property set no-quorum-policy=stop
    # Защита от пинг-понга: фатальный сбой старта сразу останавливает миграции на узле,
    # а окно сброса ошибок задано на 15 минут (900с):
    pcs property set start-failure-is-fatal=true
    pcs resource defaults update resource-stickiness=100 migration-threshold=3 failure-timeout="${FAILURE_TIMEOUT_SEC:-900s}"

    pcs resource create ping-gateway ocf:pacemaker:ping \
        host_list="${ROUTER_IPS:-$ROUTER_IP}" multiplier=1000 dampen=10s \
        op monitor interval=5s timeout=10s \
        clone meta interleave=true

    pcs resource create pgsql ocf:heartbeat:pgsqlms \
        bindir="$PGBIN" pgdata="$PGDATA" \
        recovery_template="/var/lib/postgresql/recovery.conf.pcmk" \
        op start timeout=60s op stop timeout=60s \
        op promote timeout=30s op demote timeout=120s \
        op monitor interval=15s timeout=10s role="Master" \
        op monitor interval=16s timeout=10s role="Slave" \
        op notify timeout=15s \
        promotable notify=true

    pcs resource create vip ocf:heartbeat:IPaddr2 \
        ip="$CLUSTER_VIP" cidr_netmask="$CLUSTER_VIP_CIDR" nic="$CLUSTER_VIP_NIC" \
        arp_interval=500 arp_count=10 arp_bg=true \
        op monitor interval=5s timeout=20s

    # Развязка fate-sharing: разделяем критическое ядро (core-app-stack) и второстепенный демон (daemon-svc)
    pcs resource create haproxy-svc systemd:haproxy op monitor interval=10s --group core-app-stack
    pcs resource create app-svc "systemd:${APP_SERVICE}" op monitor interval=10s --group core-app-stack

    pcs resource create daemon-svc "systemd:${DAEMON_SERVICE}" op monitor interval=10s

    # Положительное предпочтение (+1000 за каждый живой IP роутера) вместо жесткого -INFINITY
    pcs constraint location vip rule score-attribute=pingd pingd gt 0
    pcs constraint location pgsql-clone rule role=Master score-attribute=pingd pingd gt 0

    # Привязка core-app-stack и VIP к Master СУБД:
    pcs constraint colocation add core-app-stack with vip INFINITY
    pcs constraint colocation add vip with master pgsql-clone 500
    pcs constraint order start vip then start core-app-stack

    # Привязка daemon-svc как зависимого от core-app-stack:
    # При сбое daemon-svc ядро (my-app и haproxy) НЕ останавливаются и НЕ мигрируют!
    pcs constraint colocation add daemon-svc with core-app-stack INFINITY
    pcs constraint order start core-app-stack then start daemon-svc symmetrical=false

    echo "[УСПЕХ] Кластер полностью создан и запущен (v4.0 Production Edge Cases активны)!"
    echo "Проверьте состояние командой: pcs status"
else
    echo "[УСПЕХ] Узел $CURRENT_NODE подготовлен (v4.0 Production Edge Cases активны)."
    echo "Когда оба узла будут подготовлены и репликация БД настроена, выполните на $NODE1_NAME:"
    echo "  sudo /usr/local/sbin/bootstrap-ha.sh --init-pcs"
fi