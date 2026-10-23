#!/bin/bash
# =============================================================================
# СКРИПТ РАЗВЕРТЫВАНИЯ И ОРКЕСТРАЦИИ HA-КЛАСТЕРА (COROSYNC / PACEMAKER)
# =============================================================================
set -euo pipefail

ENV_FILE="/etc/default/ha-cluster"

if [[ $EUID -ne 0 ]]; then
  echo "[ОШИБКА] Запустите скрипт с правами root: sudo $0"
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "[ОШИБКА] Файл $ENV_FILE не найден! Сначала запустите generate-ha-config.sh."
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

# Безопасные дефолты параметров
RING0_NIC="${RING0_NIC:-eth1}"
CLUSTER_VIP_NIC="${CLUSTER_VIP_NIC:-eth0}"
ROUTER_IPS="${ROUTER_IPS:-192.168.1.1}"
PG_VERSION="${PG_VERSION:-16}"
PGDATA="${PGDATA:-/var/lib/postgresql/ha-cluster}"
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
# ШАГ 1. Создание вспомогательных кластерных скриптов
# -----------------------------------------------------------------------------
echo "[INFO] Создаю рабочие скрипты анализатора и сторожа деградации..."

# 1.1 Скрипт предстартового анализа и подготовки СУБД
cat << 'EOF' > /usr/local/sbin/cluster-boot-analyzer.sh
#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# ИНИЦИАЛИЗАЦИЯ И ЛОГИРОВАНИЕ
# =============================================================================
CONF_FILE="/etc/default/ha-cluster"
if [[ ! -r "$CONF_FILE" ]]; then
  echo "CRITICAL: Не найден конфигурационный файл $CONF_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$CONF_FILE"

LOG_TAG="cluster-precheck"
SPLITBRAIN_LOG="/var/log/postgresql_splitbrain.log"
BACKUP_ROOT="/var/backups/pg_divergent_tails"

log_msg() {
  local msg="$1"
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$ts] [$LOG_TAG] $msg" >&2
  timeout 2 logger -t "$LOG_TAG" "$msg" 2>/dev/null || true
}

# Дефолтные параметры
DB_PORT="${DB_PORT:-5432}"
DB_CHECK_PORT="${DB_CHECK_PORT:-9200}"
REPL_USER="${REPL_USER:-repl_user}"
PGPASS_FILE="${PGPASS_FILE:-/var/lib/postgresql/.pgpass}"
REPL_SLOT_NODE1="${REPL_SLOT_NODE1:-slot_node1}"
REPL_SLOT_NODE2="${REPL_SLOT_NODE2:-slot_node2}"
MIN_FREE_DISK_PCT="${MIN_FREE_DISK_PCT:-10}"
COLD_START_TIMEOUT_SEC="${COLD_START_TIMEOUT_SEC:-180}"
CRASH_TIMEOUT_SEC="${CRASH_TIMEOUT_SEC:-900}"
BOOT_MODE_FILE="${BOOT_MODE_FILE:-/run/cluster_boot_mode}"
PGBIN="${PGBIN:-/usr/lib/postgresql/16/bin}"
PGDATA="${PGDATA:-/var/lib/postgresql/ha-cluster}"

# Валидация обязательных переменных
for req_var in \
  NODE1_NAME NODE2_NAME \
  NODE1_RING0_IP NODE1_RING1_IP \
  NODE2_RING0_IP NODE2_RING1_IP \
  REPL_SLOT_NODE1 REPL_SLOT_NODE2 \
  PGBIN PGDATA DB_PORT REPL_USER PGPASS_FILE
do
  if [[ -z "${!req_var:-}" ]]; then
    log_msg "CRITICAL: Обязательная переменная $req_var не определена в $CONF_FILE"
    exit 1
  fi
done

# Инициализация путей и ловушки очистки временных ресурсов
TEMP_PGDATA=""
TEST_FILE=""

cleanup() {
  local exit_code=$?
  if [[ -n "${TEST_FILE:-}" && -f "$TEST_FILE" ]]; then
    rm -f "$TEST_FILE" 2>/dev/null || true
  fi
  if [[ -n "${TEMP_PGDATA:-}" && -d "$TEMP_PGDATA" ]]; then
    log_msg "Очистка временного каталога $TEMP_PGDATA по завершению..."
    rm -rf "$TEMP_PGDATA" 2>/dev/null || true
  fi
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

rm -f "$BOOT_MODE_FILE"
mkdir -p "$(dirname "$SPLITBRAIN_LOG")" "$BACKUP_ROOT"

# Хелпер для парсинга значений pg_controldata
get_control_value() {
  local pattern="$1"
  LC_ALL=C "$PGBIN/pg_controldata" "$PGDATA" 2>/dev/null |
    awk -F: -v pat="$pattern" '$1 ~ pat {gsub(/^[ \t]+/, "", $2); print $2}' || true
}

# =============================================================================
# 0. ПРЕДВАРИТЕЛЬНЫЕ ПРОВЕРКИ И ЗАЩИТА ОТ ДВОЙНОГО ЗАПУСКА
# =============================================================================
if pgrep -u postgres -f "postgres -D ${PGDATA}" >/dev/null 2>&1; then
  log_msg "КРИТИЧЕСКАЯ ОШИБКА: PostgreSQL для $PGDATA уже запущен. Analyzer остановлен."
  exit 1
fi

if sudo -u postgres "$PGBIN/pg_isready" -h /var/run/postgresql -p "$DB_PORT" >/dev/null 2>&1 || \
   sudo -u postgres "$PGBIN/pg_isready" -h /tmp -p "$DB_PORT" >/dev/null 2>&1; then
  log_msg "КРИТИЧЕСКАЯ ОШИБКА: сокет порт $DB_PORT уже прослушивается PostgreSQL. Analyzer остановлен."
  exit 1
fi

# Права на системные ключи
if [[ -f /etc/corosync/authkey ]]; then
  chown root:root /etc/corosync/authkey
  chmod 0400 /etc/corosync/authkey
fi

if [[ -f "$PGPASS_FILE" ]]; then
  chown postgres:postgres "$PGPASS_FILE" 2>/dev/null || true
  chmod 0600 "$PGPASS_FILE"
fi

# =============================================================================
# 1. ПРОВЕРКА ФАЙЛОВОЙ СИСТЕМЫ И ДИСКОВОГО ПРОСТРАНСТВА
# =============================================================================
if [[ ! -f "$PGDATA/PG_VERSION" ]]; then
  log_msg "КРИТИЧЕСКАЯ ОШИБКА: Каталог БД ($PGDATA) отсутствует или не инициализирован!"
  exit 1
fi

TEST_FILE="$PGDATA/.cluster_rw_test"
if ! touch "$TEST_FILE" 2>/dev/null || ! rm -f "$TEST_FILE" 2>/dev/null; then
  log_msg "КРИТИЧЕСКАЯ ОШИБКА: Каталог БД ($PGDATA) смонтирован в Read-Only!"
  exit 1
fi

USED_SPACE_PCT=$(df -P "$PGDATA" 2>/dev/null | tail -n 1 | awk '{print $5}' | tr -dc '0-9' || true)
USED_SPACE_PCT=${USED_SPACE_PCT:-0}

USED_INODE_PCT=$(df -i -P "$PGDATA" 2>/dev/null | tail -n 1 | awk '{print $5}' | tr -dc '0-9' || true)
USED_INODE_PCT=${USED_INODE_PCT:-0}

if (( 100 - USED_SPACE_PCT < MIN_FREE_DISK_PCT )) || (( 100 - USED_INODE_PCT < MIN_FREE_DISK_PCT )); then
  log_msg "КРИТИЧЕСКАЯ ОШИБКА: Нехватка места (${USED_SPACE_PCT}%) или inodes (${USED_INODE_PCT}%) на диске БД!"
  exit 1
fi

# Безопасная проверка postmaster.pid
if [[ -f "$PGDATA/postmaster.pid" ]]; then
  OLD_PID=$(head -n 1 "$PGDATA/postmaster.pid" 2>/dev/null | tr -d ' ' || true)
  if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
    CMDLINE=$(tr '\0' ' ' < "/proc/$OLD_PID/cmdline" 2>/dev/null || true)
    if [[ "$CMDLINE" == *"postgres"* ]]; then
      log_msg "КРИТИЧЕСКАЯ ОШИБКА: postmaster.pid принадлежит живому процессу PostgreSQL (PID $OLD_PID)."
      exit 1
    fi
  fi
  log_msg "Обнаружен и удален осиротевший postmaster.pid (бывший PID ${OLD_PID:-unknown})."
  rm -f "$PGDATA/postmaster.pid"
fi

# Очистка только сокетов назначенного порта
rm -f \
  "/var/run/postgresql/.s.PGSQL.${DB_PORT}" \
  "/var/run/postgresql/.s.PGSQL.${DB_PORT}.lock" \
  "/tmp/.s.PGSQL.${DB_PORT}" \
  "/tmp/.s.PGSQL.${DB_PORT}.lock"

# =============================================================================
# 2. ОПРЕДЕЛЕНИЕ РОЛИ УЗЛА И ПОИСК АКТИВНОГО МАСТЕРА
# =============================================================================
LOCAL_IPS=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)

MY_NODE_NAME=""
PEER_IP=""
PEER_ALT_IP=""
MY_SLOT=""

if echo "$LOCAL_IPS" | grep -qw "$NODE1_RING0_IP" || echo "$LOCAL_IPS" | grep -qw "$NODE1_RING1_IP"; then
  MY_NODE_NAME="$NODE1_NAME"
  PEER_IP="$NODE2_RING0_IP"
  PEER_ALT_IP="$NODE2_RING1_IP"
  MY_SLOT="$REPL_SLOT_NODE1"
elif echo "$LOCAL_IPS" | grep -qw "$NODE2_RING0_IP" || echo "$LOCAL_IPS" | grep -qw "$NODE2_RING1_IP"; then
  MY_NODE_NAME="$NODE2_NAME"
  PEER_IP="$NODE1_RING0_IP"
  PEER_ALT_IP="$NODE1_RING1_IP"
  MY_SLOT="$REPL_SLOT_NODE2"
else
  HOST_S=$(hostname -s)
  if [[ "$HOST_S" == "$NODE1_NAME" ]]; then
    MY_NODE_NAME="$NODE1_NAME"
    PEER_IP="$NODE2_RING0_IP"
    PEER_ALT_IP="$NODE2_RING1_IP"
    MY_SLOT="$REPL_SLOT_NODE1"
  elif [[ "$HOST_S" == "$NODE2_NAME" ]]; then
    MY_NODE_NAME="$NODE2_NAME"
    PEER_IP="$NODE1_RING0_IP"
    PEER_ALT_IP="$NODE1_RING1_IP"
    MY_SLOT="$REPL_SLOT_NODE2"
  fi
fi

if [[ -z "$MY_NODE_NAME" || -z "$PEER_IP" || -z "$MY_SLOT" ]]; then
  log_msg "КРИТИЧЕСКАЯ ОШИБКА: не удалось сопоставить текущий узел с конфигурацией кластера."
  exit 1
fi

if echo "$LOCAL_IPS" | grep -qw "$PEER_IP" || echo "$LOCAL_IPS" | grep -qw "$PEER_ALT_IP"; then
  log_msg "КРИТИЧЕСКАЯ ОШИБКА: PEER_IP совпадает с локальным адресом хоста. Проверьте конфигурацию."
  exit 1
fi

ACTIVE_PEER_IP=""
log_msg "Поиск активного мастера на соседнем узле..."

# Симметричный опрос соседа (HTTP хелпер и прямая проверка psql)
for attempt in {1..6}; do
  for cip in "$PEER_IP" "$PEER_ALT_IP"; do
    [[ -z "$cip" ]] && continue

    # Проверка через HTTP health-check
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "http://${cip}:${DB_CHECK_PORT}" 2>/dev/null || true)
    if [[ "$HTTP_CODE" == "200" ]]; then
      ACTIVE_PEER_IP="$cip"
      log_msg "HTTP-проверка: сосед $cip подтвердил статус MASTER (200 OK)."
      break 2
    fi

    # Fallback: прямая проверка в PostgreSQL
    PEER_RECOVERY=$(
      sudo -u postgres PGPASSFILE="$PGPASS_FILE" PGCONNECT_TIMEOUT=2 \
        "$PGBIN/psql" -w -h "$cip" -p "$DB_PORT" -U "$REPL_USER" -d postgres -tAc \
        "SELECT pg_is_in_recovery();" 2>/dev/null | tail -n 1 | tr -d '[:space:]' || true
    )
    if [[ "$PEER_RECOVERY" == "f" ]]; then
      ACTIVE_PEER_IP="$cip"
      log_msg "Прямая проверка PostgreSQL: сосед $cip подтвердил статус MASTER."
      break 2
    fi
  done
  sleep 2
done

# =============================================================================
# 3. ИЗОЛИРОВАННЫЙ CRASH RECOVERY
# =============================================================================
INITIAL_DB_STATE=$(get_control_value "Database cluster state")
INITIAL_DB_STATE=${INITIAL_DB_STATE:-unknown}

log_msg "Исходное состояние БД на диске: '$INITIAL_DB_STATE'"

if [[ "$INITIAL_DB_STATE" == "unknown" ]]; then
  log_msg "КРИТИЧЕСКАЯ ОШИБКА: невозможно получить статус базы через pg_controldata."
  exit 1
fi

if [[ -f "$PGDATA/standby.signal" ]] || [[ "$INITIAL_DB_STATE" == *"recovery"* ]]; then
  DETECTED_ROLE="SLAVE"
else
  DETECTED_ROLE="MASTER"
fi

# Если база не выключена чисто, выполняем recovery в строгой изоляции
if [[ "$INITIAL_DB_STATE" != "shut down" && "$INITIAL_DB_STATE" != "shut down in recovery" ]]; then
  log_msg "База в аварийном состоянии ($INITIAL_DB_STATE). Запуск строго изолированного Crash Recovery..."

  set +e
  sudo -u postgres "$PGBIN/pg_ctl" -D "$PGDATA" \
    -o "-c listen_addresses='' -c primary_conninfo='' -c archive_mode=off -c autovacuum=off -c unix_socket_directories='/var/run/postgresql, /tmp'" \
    start -w -t 90 >>"$SPLITBRAIN_LOG" 2>&1
  START_RC=$?

  sudo -u postgres "$PGBIN/pg_ctl" -D "$PGDATA" stop -m fast -w -t 60 >>"$SPLITBRAIN_LOG" 2>&1
  STOP_RC=$?

  if [[ "$STOP_RC" -ne 0 ]]; then
    sudo -u postgres "$PGBIN/pg_ctl" -D "$PGDATA" stop -m immediate -w -t 30 >>"$SPLITBRAIN_LOG" 2>&1
  fi
  set -e

  CLEANED_STATE=$(get_control_value "Database cluster state")
  log_msg "Состояние БД после recovery: '$CLEANED_STATE' (start_rc=$START_RC, stop_rc=$STOP_RC)"

  if [[ "$CLEANED_STATE" != "shut down" && "$CLEANED_STATE" != "shut down in recovery" ]]; then
    log_msg "КРИТИЧЕСКАЯ ОШИБКА: crash recovery не привел БД в согласованное состояние: '$CLEANED_STATE'."
    exit 1
  fi
fi

touch "$PGDATA/standby.signal"
chown postgres:postgres "$PGDATA/standby.signal"

touch "$PGDATA/postgresql.auto.conf"
sed -i -E '/^(primary_conninfo|primary_slot_name|recovery_target_timeline)/d' "$PGDATA/postgresql.auto.conf" 2>/dev/null || true
cat <<BOOT_CONF_EOF >> "$PGDATA/postgresql.auto.conf"
primary_conninfo = 'host=${PEER_IP},${PEER_ALT_IP} port=${DB_PORT} user=${REPL_USER} passfile=${PGPASS_FILE} application_name=${MY_NODE_NAME} connect_timeout=2 target_session_attrs=read-write'
primary_slot_name = '${MY_SLOT}'
recovery_target_timeline = 'latest'
BOOT_CONF_EOF
chown postgres:postgres "$PGDATA/postgresql.auto.conf"
chmod 0600 "$PGDATA/postgresql.auto.conf"

# =============================================================================
# 6. ФИКСАЦИЯ РЕЖИМА ЗАПУСКА ДЛЯ СТОРОЖА ДЕГРАДИРОВАННОГО РЕЖИМА
# =============================================================================
FINAL_STATE=$(get_control_value "Database cluster state")
FINAL_STATE=${FINAL_STATE:-unknown}

if [[ "$FINAL_STATE" == "unknown" ]]; then
  log_msg "КРИТИЧЕСКАЯ ОШИБКА: не удалось получить финальный статус БД."
  exit 1
fi

# Внутренний heredoc использует маркер BOOT_CONF_EOF во избежание коллизий
if [[ "$INITIAL_DB_STATE" == "shut down" || "$INITIAL_DB_STATE" == "shut down in recovery" ]]; then
  cat <<BOOT_CONF_EOF > "$BOOT_MODE_FILE"
MODE=COLD_START
LAST_ROLE=$DETECTED_ROLE
UNBLOCK_TIMEOUT_SEC=$COLD_START_TIMEOUT_SEC
BOOT_CONF_EOF
else
  cat <<BOOT_CONF_EOF > "$BOOT_MODE_FILE"
MODE=CRASH_RECOVERY
LAST_ROLE=$DETECTED_ROLE
UNBLOCK_TIMEOUT_SEC=$CRASH_TIMEOUT_SEC
BOOT_CONF_EOF
fi

# Точечная проверка прав без рекурсивного chown -R
chmod 0700 "$PGDATA" 2>/dev/null || true
chown postgres:postgres "$PGDATA" 2>/dev/null || true

log_msg "Предстартовый анализ завершен успешно. Режим: $(tr '\n' ' ' < "$BOOT_MODE_FILE")"
exit 0
EOF

chmod 0755 /usr/local/sbin/cluster-boot-analyzer.sh

# 1.2 Сторож деградированного режима (Unblock Quorum)
cat << 'EOF' > /usr/local/sbin/cluster-degraded-unblock.sh
#!/bin/bash
set -euo pipefail

source /etc/default/ha-cluster
[[ -f "${BOOT_MODE_FILE:-}" ]] && source "$BOOT_MODE_FILE"

log_msg() { timeout 2 logger -t cluster-watchdog "$1" || true; }

# Корректное завершение при остановке службы через systemctl
trap 'log_msg "Служба остановлена извне. Прерывание ожидания."; exit 0' SIGTERM SIGINT

is_cluster_quorate() {
  # Проверка наличия кворума (оба узла в сети)
  corosync-quorumtool -s 2>/dev/null | grep -q "Quorate:.*Yes"
}

unblock_quorum_safely() {
  log_msg "Выполняю отмену wait_for_all для кворума..."

  # 1. Штатный метод через corosync-quorumtool (-u / --unblock)
  if corosync-quorumtool -u >/dev/null 2>&1; then
    log_msg "Флаг wait_for_all успешно сброшен через corosync-quorumtool."
  # 2. Резервный метод через прямую запись в cmap Corosync
  elif corosync-cmapctl -s quorum.cancel_wait_for_all u8 1 >/dev/null 2>&1; then
    log_msg "Флаг wait_for_all успешно сброшен через corosync-cmapctl."
  else
    log_msg "ОШИБКА: Не удалось отменить wait_for_all ни через quorumtool, ни через cmapctl!"
    return 1
  fi

  # Контрольная пауза и проверка результата
  sleep 1
  if is_cluster_quorate; then
    log_msg "Кворум успешно активирован на единственном узле."
  else
    log_msg "ПРЕДУПРЕЖДЕНИЕ: wait_for_all отменен, но кворум не появился. Проверьте параметр two_node в corosync.conf."
  fi
}

# Функция динамического ожидания кворума
wait_for_quorum_or_timeout() {
  local max_wait="$1"
  local interval=2
  local waited=0

  while (( waited < max_wait )); do
    if is_cluster_quorate; then
      return 0
    fi
    sleep "$interval"
    waited=$(( waited + interval ))
  done

  is_cluster_quorate
}

# 1. Если второй узел уже на связи — выходим немедленно
if is_cluster_quorate; then
  log_msg "Оба узла в строю (кворум уже собран). Скрипт не требуется, завершение."
  exit 0
fi

LOCAL_IPS=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)
if echo "$LOCAL_IPS" | grep -qw "$NODE1_RING0_IP" || echo "$LOCAL_IPS" | grep -qw "$NODE1_RING1_IP"; then
  MY_NODE_NAME="$NODE1_NAME"
  PEER_RING0_IP="$NODE2_RING0_IP"
  PEER_RING1_IP="$NODE2_RING1_IP"
  EXTRA_DELAY=0
else
  MY_NODE_NAME="$NODE2_NAME"
  PEER_RING0_IP="$NODE1_RING0_IP"
  PEER_RING1_IP="$NODE1_RING1_IP"
  EXTRA_DELAY="${NODE2_ASYMMETRIC_DELAY_SEC:-120}"
fi

TOTAL_WAIT=$(( ${UNBLOCK_TIMEOUT_SEC:-${CRASH_TIMEOUT_SEC:-120}} + EXTRA_DELAY ))
log_msg "Второй узел не обнаружен. Ожидание сбора кворума до ${TOTAL_WAIT} сек (Режим: ${MODE:-UNKNOWN}, Роль: ${LAST_ROLE:-UNKNOWN})..."

# 2. Динамический цикл ожидания: завершается сразу, как только появляется второй узел
if wait_for_quorum_or_timeout "$TOTAL_WAIT"; then
  log_msg "Второй узел подключился, кворум собран штатно. Отмена degraded-режима."
  exit 0
fi

log_msg "Таймаут истек, второй узел не появился. Проверяю сетевой периметр..."

ROUTER_OK="no"
for rip in ${ROUTER_IPS:-}; do
  if ping -c 2 -W 1 "$rip" >/dev/null 2>&1 || arping -I "$CLUSTER_VIP_NIC" -c 2 -w 2 "$rip" >/dev/null 2>&1; then
    ROUTER_OK="yes"
    break
  fi
done
if [[ "$ROUTER_OK" != "yes" ]]; then
  log_msg "ОШИБКА: Маршрутизатор ($ROUTER_IPS) недоступен! Разблокировка отменена."
  exit 1
fi

for pip in "$PEER_RING0_IP" "$PEER_RING1_IP"; do
  if ping -c 2 -W 1 "$pip" >/dev/null 2>&1; then
    log_msg "Сосед ($pip) отвечает по ICMP! Отмена разблокировки во избежание Split-Brain."
    exit 1
  fi
done

if ping -c 2 -W 1 "$CLUSTER_VIP" >/dev/null 2>&1; then
  log_msg "КРИТИЧЕСКАЯ ОШИБКА: VIP ($CLUSTER_VIP) отвечает на ping! Защита от Split-Brain."
  exit 1
fi

if [[ "${LAST_ROLE:-}" == "MASTER" ]]; then
  log_msg "Узел был MASTER. Разблокировка кворума."
  unblock_quorum_safely
elif [[ "${LAST_ROLE:-}" == "SLAVE" ]]; then
  log_msg "Узел был SLAVE. Ожидание мастера еще ${NODE2_ASYMMETRIC_DELAY_SEC:-120} сек..."
  if wait_for_quorum_or_timeout "${NODE2_ASYMMETRIC_DELAY_SEC:-120}"; then
    log_msg "Мастер появился в сети, кворум собран штатно."
    exit 0
  fi
  log_msg "Мастер не появился. Разблокировка кворума для промоута реплики."
  unblock_quorum_safely
else
  log_msg "Роль не MASTER/SLAVE (${LAST_ROLE:-UNKNOWN}). Разблокировка кворума."
  unblock_quorum_safely
fi
EOF
chmod +x /usr/local/sbin/cluster-degraded-unblock.sh

# -----------------------------------------------------------------------------
# ШАГ 2. Регистрация кластерных systemd-юнитов и тюнинг
# -----------------------------------------------------------------------------
echo "[INFO] Регистрация кластерных юнитов в systemd..."

cat << EOF > /etc/systemd/system/cluster-boot-analyzer.service
[Unit]
Description=Pre-flight Disk Health Check and Boot Mode Analyzer for Pacemaker
DefaultDependencies=no
After=local-fs.target network-online.target
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
PartOf=pacemaker.service

[Service]
Type=oneshot
TimeoutStartSec=infinity
EnvironmentFile=/etc/default/ha-cluster

ExecCondition=/bin/bash -c '! corosync-quorumtool -s 2>/dev/null | grep -q "Quorate:.*Yes"'

ExecStart=/usr/local/sbin/cluster-degraded-unblock.sh

[Install]
WantedBy=pacemaker.service
EOF

cat << 'EOF' > /etc/systemd/system/cluster-degraded-unblock.timer
[Unit]
Description=Start Degraded Mode Watchdog Timer after Pacemaker boot
PartOf=pacemaker.service
After=pacemaker.service

[Timer]
OnActiveSec=5sec
AccuracySec=1s
Unit=cluster-degraded-unblock.service

[Install]
WantedBy=pacemaker.service multi-user.target
EOF

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

systemctl daemon-reload
systemctl enable pcsd.service 2>/dev/null || true
systemctl enable cluster-boot-analyzer.service cluster-degraded-unblock.timer 2>/dev/null || true

# -----------------------------------------------------------------------------
# ШАГ 3. Инициализация кластера Corosync и Pacemaker (только с --init-pcs)
# -----------------------------------------------------------------------------
CURRENT_NODE_NAME=$(hostname -s)

if [[ "${1:-}" == "--init-pcs" ]]; then
  echo "[INFO] Инициализирую кластер Corosync и ресурсы Pacemaker..."

  pcs host auth "$NODE1_NAME" "$NODE2_NAME" -u hacluster -p "$HACLUSTER_PASS"

  # 1. Создание кластера Corosync
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

  pcs quorum update wait_for_all=1

  pcs cluster start --all
  pcs cluster enable --all

  # 2. Базовые свойства кластера
  pcs property set stonith-enabled=false
  pcs property set no-quorum-policy=stop
  pcs property set start-failure-is-fatal=false

  pcs resource defaults update migration-threshold=3 \
    failure-timeout="$FAILURE_TIMEOUT_SEC" resource-stickiness=100

  # 3. Псевдо-арбитр (ping к шлюзу)
  pcs resource create ping-gateway ocf:pacemaker:ping \
    host_list="$ROUTER_IPS" multiplier=1000 dampen=10s \
    op monitor interval=5s timeout=10s \
    clone meta interleave=true

  # 4. PostgreSQL (promotable pgsqlms)
  pcs resource create pgsql ocf:heartbeat:pgsqlms \
    bindir="$PGBIN" \
    pgdata="$PGDATA" \
    pghost="/var/run/postgresql" \
    pgport="$DB_PORT" \
    op start timeout=60s \
    op stop timeout=60s \
    op reload timeout=20s \
    op promote timeout=60s \
    op demote timeout=120s \
    op notify timeout=60s \
    op monitor interval=5s role="Promoted" timeout=10s \
    op monitor interval=10s role="Unpromoted" timeout=10s \
    promotable promoted-max=1 promoted-node-max=1 clone-max=2 clone-node-max=1 notify=true

  # 5. Клонированный балансировщик HAProxy
  pcs resource create haproxy-svc systemd:haproxy \
    op start timeout=30s \
    op stop timeout=30s \
    op monitor interval=10s timeout=20s \
    clone meta interleave=true

  # 6. Группа app-stack (VIP + Web App)
  pcs resource create vip ocf:heartbeat:IPaddr2 \
    ip="$CLUSTER_VIP" cidr_netmask="$CLUSTER_VIP_CIDR" nic="$CLUSTER_VIP_NIC" \
    arp_interval=1 arp_count=5 \
    op monitor interval=5s timeout=20s \
    --group app-stack

  for svc in $APP_SERVICE; do
    svc_clean="${svc%.service}"
    pcs resource create "app-${svc_clean}" "systemd:${svc_clean}" \
      op start timeout=30s \
      op stop timeout=30s \
      op monitor interval=10s timeout=20s \
      --group app-stack --force
  done

  # 7. Группа daemon-stack (фоновый демон записи)
  for dsvc in $DAEMON_SERVICE; do
    dsvc_clean="${dsvc%.service}"
    pcs resource create "daemon-${dsvc_clean}" "systemd:${dsvc_clean}" \
      op start timeout=30s \
      op stop timeout=30s \
      op monitor interval=10s timeout=20s \
      --group daemon-stack --force
  done

  # ---------------------------------------------------------------------------
  # ОГРАНИЧЕНИЯ РАЗМЕЩЕНИЯ И ПОРЯДКА
  # ---------------------------------------------------------------------------
  # 1. Размещение от сети: Мастер СУБД и VIP размещаются только там, где доступен шлюз
  pcs constraint location pgsql-clone rule role=Promoted score-attribute=pingd pingd gt 0
  pcs constraint location app-stack rule score-attribute=pingd pingd gt 0

  # 2. Порядок запуска: Сервисам нужен только HAProxy
  pcs constraint order start haproxy-svc-clone then start app-stack
  pcs constraint order start haproxy-svc-clone then start daemon-stack

  echo "[УСПЕХ] Кластер успешно инициализирован и запущен! Проверьте: pcs status"
else
  echo "[УСПЕХ] Узел ${CURRENT_NODE_NAME} успешно подготовлен на уровне кластерных сервисов."
  echo "Для финальной инициализации кластера выполните на ${NODE1_NAME}:"
  echo "  sudo $0 --init-pcs"
fi