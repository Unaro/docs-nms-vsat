#!/bin/bash
# =============================================================================
# УНИВЕРСАЛЬНЫЙ СКРИПТ РАЗВЕРТЫВАНИЯ HA-КЛАСТЕРА (NODE1 / NODE2)
# Настраивает: /etc/default/ha-cluster, скрипты контроля БД и кворума,
# юниты systemd, сокет проверки роли БД, HAProxy и (опционально) Pacemaker/PCS.
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

# 3. Маршрутизатор (псевдо-арбитр) и Виртуальный IP (VIP)
ROUTER_IP="192.168.1.1"
CLUSTER_VIP="192.168.1.100"
CLUSTER_VIP_CIDR="24"
CLUSTER_VIP_NIC="eth0"

# 4. Параметры СУБД и HAProxy
PG_VERSION="16"
PGDATA="/var/lib/postgresql/16/main"
PGBIN="/usr/lib/postgresql/16/bin"
DB_PORT="5432"
DB_CHECK_USER="haproxy_check"
DB_CHECK_PORT="9200"
HAPROXY_DB_BIND_PORT="5000"

# 5. Управляемые systemd-сервисы приложения и демонов
APP_SERVICE="my-app"
DAEMON_SERVICE="my-daemon"

# 6. Таймауты и пороги безопасности
MIN_FREE_DISK_PCT="5"
COLD_START_TIMEOUT_SEC="180"    # 3 минуты при плановом холодном старте
CRASH_TIMEOUT_SEC="900"         # 15 минут при старте после аварийного падения

# 7. Служебные файлы состояния
STATE_DIR="/var/lib/cluster-state"
STATE_FILE="/var/lib/cluster-state/graceful_shutdown"
BOOT_MODE_FILE="/run/cluster_boot_mode"

# 8. Пароль пользователя hacluster (для автоматической инициализации pcs)
HACLUSTER_PASS="StrongClusterPass123!"
EOF
    chmod 600 "$ENV_FILE"
    echo "[ВНИМАНИЕ] Шаблон $ENV_FILE создан."
    echo "Проверьте в нем IP-адреса и имена ваших сервисов, затем запустите скрипт повторно!"
    exit 0
fi

# Подгружаем переменные из единого файла конфигурации
source "$ENV_FILE"
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
# ШАГ 3. Идемпотентное обновление /etc/hosts и создание директорий
# -----------------------------------------------------------------------------
sed -i '/# --- HA-CLUSTER-HOSTS-BEGIN ---/,/# --- HA-CLUSTER-HOSTS-END ---/d' /etc/hosts
cat << EOF >> /etc/hosts
# --- HA-CLUSTER-HOSTS-BEGIN ---
$NODE1_RING0_IP    ${NODE1_NAME}-ring0 $NODE1_NAME
$NODE2_RING0_IP    ${NODE2_NAME}-ring0 $NODE2_NAME
$NODE1_RING1_IP    ${NODE1_NAME}-ring1
$NODE2_RING1_IP    ${NODE2_NAME}-ring1
# --- HA-CLUSTER-HOSTS-END ---
EOF

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

IS_RECOVERY=$(psql -h 127.0.0.1 -p "${DB_PORT:-5432}" -U "${DB_CHECK_USER:-haproxy_check}" -d postgres -tAc "SELECT pg_is_in_recovery();" 2>/dev/null || echo "err")

if [[ "$IS_RECOVERY" == "f" ]]; then
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

if crm_mon -1 2>/dev/null | grep -A 2 "Promoted:" | grep -qw "$LOCAL_NODE"; then
    AM_I_MASTER="yes"
else
    AM_I_MASTER="no"
fi

ONLINE_NODES_COUNT=$(crm_node -l 2>/dev/null | grep -c "member" || echo "1")

if [[ "$AM_I_MASTER" == "yes" ]] && (( ONLINE_NODES_COUNT == 1 )); then
    FINAL_ROLE="MASTER"
else
    FINAL_ROLE="SLAVE"
fi

echo "SHUTDOWN_TYPE=GRACEFUL" > "$STATE_FILE"
echo "LAST_KNOWN_ROLE=$FINAL_ROLE" >> "$STATE_FILE"
echo "TIMESTAMP=$(date +%s)" >> "$STATE_FILE"
sync
logger -t cluster-state "Штатная остановка ($LOCAL_NODE). Живых узлов: $ONLINE_NODES_COUNT. Записана роль: $FINAL_ROLE"
EOF
chmod +x /usr/local/sbin/cluster-mark-shutdown.sh

# 4.3 Скрипт проверки дисков и выбора режима старта (/usr/local/sbin/cluster-boot-analyzer.sh)
cat << 'EOF' > /usr/local/sbin/cluster-boot-analyzer.sh
#!/bin/bash
set -euo pipefail
source /etc/default/ha-cluster

rm -f "$BOOT_MODE_FILE"
WAS_GRACEFUL="no"
SAVED_ROLE="UNKNOWN"

# 1. Читаем и МГНОВЕННО удаляем маркер штатного выключения с диска
if [[ -f "$STATE_FILE" ]]; then
    source "$STATE_FILE"
    WAS_GRACEFUL="yes"
    SAVED_ROLE="${LAST_KNOWN_ROLE:-UNKNOWN}"
    rm -f "$STATE_FILE"
    sync
    logger -t cluster-precheck "Маркер штатного выключения прочитан (Роль: $SAVED_ROLE) и удален с диска."
fi

# 2. Предстартовая проверка диска БД
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

# 3. Определение режима запуска по заголовку pg_controldata
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
else
    PEER_RING0_IP="$NODE1_RING0_IP"
    PEER_RING1_IP="$NODE1_RING1_IP"
fi

if [[ -z "${ROUTER_IP:-}" ]]; then
    ROUTER_IP=$(ip route show default | awk '/default/ {print $3; exit}')
fi

sleep "${UNBLOCK_TIMEOUT_SEC:-$CRASH_TIMEOUT_SEC}"

if corosync-quorumtool -s | grep -q "Quorate:.*Yes"; then
    logger -t cluster-watchdog "Обе ноды в строю, кворум собран штатно (${MODE:-UNKNOWN})."
    exit 0
fi

# Предохранитель №1: Проверка пинга роутера и молчания соседа
if ! ping -c 3 -W 2 "$ROUTER_IP" >/dev/null 2>&1; then
    logger -t cluster-watchdog "ОШИБКА: Маршрутизатор ($ROUTER_IP) недоступен! Отмена разблокировки во избежание Split-Brain."
    exit 1
fi

if ping -c 2 -W 1 "$PEER_RING0_IP" >/dev/null 2>&1 || ping -c 2 -W 1 "$PEER_RING1_IP" >/dev/null 2>&1; then
    logger -t cluster-watchdog "Сосед ($PEER_RING0_IP / $PEER_RING1_IP) отвечает по ICMP, ждем запуска его Corosync."
    exit 1
fi

# Предохранитель №2: Проверка роли БД перед выключением/падением
if [[ "${MODE:-}" == "COLD_START" ]] && [[ "${LAST_ROLE:-}" == "MASTER" ]]; then
    logger -t cluster-watchdog "Холодный старт в одиночку: разблокировка кворума (pcs quorum unblock)."
    pcs quorum unblock --yes
elif [[ "${MODE:-}" == "CRASH_RECOVERY" ]]; then
    if [[ "${DB_RAW_STATE:-}" == "in production" ]]; then
        logger -t cluster-watchdog "АВАРИЙНЫЙ СТАРТ: Сосед не встал. Локальная БД была Master. Активация режима деградации!"
        pcs quorum unblock --yes
    else
        logger -t cluster-watchdog "СТОП! Этот узел до аварии был РЕПЛИКОЙ (${DB_RAW_STATE:-}). Автопромоут запрещен!"
        exit 1
    fi
fi
EOF
chmod +x /usr/local/sbin/cluster-degraded-unblock.sh

# -----------------------------------------------------------------------------
# ШАГ 5. Генерация юнитов systemd и конфигурации HAProxy
# -----------------------------------------------------------------------------
echo "[INFO] Генерирую systemd-юниты и конфигурацию HAProxy..."

# 5.1 Сокет и сервис проверки роли БД для HAProxy
cat << EOF > /etc/systemd/system/db-role-check.socket
[Unit]
Description=PostgreSQL Role Check Socket for HAProxy

[Socket]
ListenStream=${DB_CHECK_PORT}
Accept=yes

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
    server node1_db "${NODE1_RING0_IP}:${DB_PORT}" maxconn 500 check port "${DB_CHECK_PORT}"
    server node2_db "${NODE2_RING0_IP}:${DB_PORT}" maxconn 500 check port "${DB_CHECK_PORT}"
EOF

# 5.3 Шлюз проверки дисков и сценария старта (RequiresMountsFor подставляется из $PGDATA)
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
# ШАГ 6. Настройка прав автозагрузки сервисов в systemd
# -----------------------------------------------------------------------------
echo "[INFO] Настраиваю правила автозагрузки systemd..."
systemctl daemon-reload

# Отключаем автозапуск сервисов, которыми управляет исключительно Pacemaker
for svc in postgresql haproxy "$APP_SERVICE" "$DAEMON_SERVICE"; do
    if systemctl list-unit-files | grep -q "^${svc}.service"; then
        systemctl disable "${svc}.service" 2>/dev/null || true
    fi
done

# Включаем наши шлюзы безопасности, сокет чеккера БД и демон pcsd
systemctl enable --now db-role-check.socket pcsd.service
systemctl enable cluster-boot-analyzer.service \
                 cluster-shutdown-marker.service \
                 cluster-degraded-unblock.timer

echo "hacluster:${HACLUSTER_PASS}" | chpasswd

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
    pcs resource defaults update resource-stickiness=100

    pcs resource create ping-gateway ocf:pacemaker:ping \
        host_list="$ROUTER_IP" multiplier=100 dampen=5s \
        op monitor interval=5s timeout=10s \
        clone meta interleave=true

    pcs resource create pgsql ocf:heartbeat:pgsqlms \
        bindir="$PGBIN" pgdata="$PGDATA" \
        recovery_template="/var/lib/postgresql/recovery.conf.pcmk" \
        op start timeout=60s op stop timeout=60s \
        op promote timeout=30s op demote timeout=120s \
        op monitor interval=15s timeout=10s role="Master" \
        op monitor interval=16s timeout=10s role="Slave" \
        op notify timeout=60s \
        promotable notify=true

    pcs resource create vip ocf:heartbeat:IPaddr2 \
        ip="$CLUSTER_VIP" cidr_netmask="$CLUSTER_VIP_CIDR" nic="$CLUSTER_VIP_NIC" \
        op monitor interval=5s timeout=20s

    pcs resource create haproxy-svc systemd:haproxy op monitor interval=10s --group app-stack
    pcs resource create app-svc "systemd:${APP_SERVICE}" op monitor interval=10s --group app-stack
    pcs resource create daemon-svc "systemd:${DAEMON_SERVICE}" op monitor interval=10s --group app-stack

    pcs constraint location vip rule score=-INFINITY pingd lt 1 or not_defined pingd
    pcs constraint location pgsql-clone rule role=Master score=-INFINITY pingd lt 1 or not_defined pingd
    pcs constraint colocation add app-stack with vip INFINITY
    pcs constraint colocation add vip with master pgsql-clone 500
    pcs constraint order start vip then start app-stack

    echo "[УСПЕХ] Кластер полностью создан и запущен! Проверьте состояние командой: pcs status"
else
    echo "[УСПЕХ] Узел $CURRENT_NODE подготовлен."
    echo "Когда оба узла будут подготовлены и репликация БД настроена, выполните на $NODE1_NAME:"
    echo "  sudo /usr/local/sbin/bootstrap-ha.sh --init-pcs"
fi