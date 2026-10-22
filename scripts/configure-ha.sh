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

# Если база не выключена чисто, выполняем recovery в строгой изоляции
if [[ "$INITIAL_DB_STATE" != "shut down" && "$INITIAL_DB_STATE" != "shut down in recovery" ]]; then
  log_msg "База в аварийном состоянии ($INITIAL_DB_STATE). Запуск строго изолированного Crash Recovery..."

  set +e
  # Изоляция: отключены архивация (archive_mode=off) и автовакуум во избежание порчи общего архива
  sudo -u postgres "$PGBIN/pg_ctl" -D "$PGDATA" \
    -o "-c listen_addresses='' -c archive_mode=off -c autovacuum=off -c unix_socket_directories='/var/run/postgresql, /tmp'" \
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

# =============================================================================
# 4. СИНХРОНИЗАЦИЯ С АКТИВНЫМ МАСТЕРОМ
# =============================================================================
if [[ -n "$ACTIVE_PEER_IP" ]]; then
  log_msg "Обнаружен активный MASTER ($ACTIVE_PEER_IP). Проверяю слот репликации..."

  CONNSTR="host=$ACTIVE_PEER_IP port=$DB_PORT user=$REPL_USER application_name=$MY_NODE_NAME dbname=postgres passfile=$PGPASS_FILE"

  SLOT_ROW=$(
    sudo -u postgres PGPASSFILE="$PGPASS_FILE" PGCONNECT_TIMEOUT=3 \
      "$PGBIN/psql" -w -d "$CONNSTR" -tAc \
      "SELECT COALESCE(max(wal_status), 'missing'), COALESCE(bool_or(active), false) FROM pg_replication_slots WHERE slot_name = '$MY_SLOT';" \
      2>>"$SPLITBRAIN_LOG" | tail -n 1 || true
  )

  SLOT_STATUS=$(printf '%s' "$SLOT_ROW" | awk -F'|' '{print $1}' | tr -d '[:space:]')
  SLOT_ACTIVE=$(printf '%s' "$SLOT_ROW" | awk -F'|' '{print $2}' | tr -d '[:space:]')

  if [[ -z "$SLOT_STATUS" || -z "$SLOT_ACTIVE" ]]; then
    log_msg "КРИТИЧЕСКАЯ ОШИБКА: не удалось опросить слот $MY_SLOT на мастере $ACTIVE_PEER_IP."
    exit 1
  fi

  log_msg "Состояние слота $MY_SLOT на мастере: wal_status=$SLOT_STATUS, active=$SLOT_ACTIVE"

  BASEBACKUP_CREATE_SLOT=false
  FORCE_BASEBACKUP=false

  case "$SLOT_STATUS" in
    missing)
      BASEBACKUP_CREATE_SLOT=true
      FORCE_BASEBACKUP=true
      log_msg "Слот отсутствует на мастере. Потребуется pg_basebackup с созданием слота (-C)."
      ;;
    lost)
      if [[ "$SLOT_ACTIVE" == "f" || "$SLOT_ACTIVE" == "false" ]]; then
        log_msg "Слот в статусе lost. Удаляю старый слот..."
        if ! sudo -u postgres PGPASSFILE="$PGPASS_FILE" PGCONNECT_TIMEOUT=5 \
          "$PGBIN/psql" -w -d "$CONNSTR" -c \
          "SELECT pg_drop_replication_slot('$MY_SLOT');" >>"$SPLITBRAIN_LOG" 2>&1; then
          log_msg "КРИТИЧЕСКАЯ ОШИБКА: сбой удаления lost-слота $MY_SLOT."
          exit 1
        fi
        BASEBACKUP_CREATE_SLOT=true
        FORCE_BASEBACKUP=true
      else
        log_msg "КРИТИЧЕСКАЯ ОШИБКА: слот $MY_SLOT в статусе lost, но числится активным."
        exit 1
      fi
      ;;
    reserved|extended|unreserved)
      log_msg "Слот $MY_SLOT валиден. Полноценный пересоздание не обязательно."
      ;;
    *)
      log_msg "КРИТИЧЕСКАЯ ОШИБКА: неизвестный статус слота: $SLOT_STATUS."
      exit 1
      ;;
  esac

  # Проверка готовности узла к pg_rewind
  CHECKSUMS=$(get_control_value "Data page checksum version")
  CHECKSUMS=${CHECKSUMS:-0}
  WAL_LOG_HINTS=$(get_control_value "wal_log_hints setting")
  WAL_LOG_HINTS=${WAL_LOG_HINTS:-off}

  if [[ "$CHECKSUMS" == "0" && "$WAL_LOG_HINTS" != "on" ]]; then
    log_msg "ВНИМАНИЕ: wal_log_hints=off и data_checksums=off. pg_rewind не поддерживается кластером!"
    FORCE_BASEBACKUP=true
  fi

  NEED_REWIND=false

  if [[ "$FORCE_BASEBACKUP" != "true" ]]; then
    set +e
    REWIND_CHECK=$(
      sudo -u postgres PGPASSFILE="$PGPASS_FILE" "$PGBIN/pg_rewind" \
        --target-pgdata="$PGDATA" \
        --source-server="$CONNSTR" \
        --dry-run 2>&1
    )
    REWIND_RC=$?
    set -e

    log_msg "pg_rewind dry-run (код $REWIND_RC): $(printf '%s' "$REWIND_CHECK" | tr '\n' ' ' | head -c 250)"

    if printf '%s' "$REWIND_CHECK" | grep -qi "no rewind required"; then
      if [[ -f "$PGDATA/standby.signal" ]]; then
        NEED_REWIND=false
        log_msg "Откат не требуется: реплика уже синхронизирована с мастером."
      else
        NEED_REWIND=true
        log_msg "Данные совпадают, но standby.signal отсутствует. Требуется инициализация standby."
      fi
    elif [[ "$REWIND_RC" -eq 0 ]] || printf '%s' "$REWIND_CHECK" | grep -qiE "diverged|history"; then
      NEED_REWIND=true
      log_msg "Требуется выполнение pg_rewind."
    else
      FORCE_BASEBACKUP=true
      log_msg "pg_rewind dry-run завершился ошибкой. Требуется pg_basebackup."
    fi
  fi

  SYNC_OK=false

  if [[ ! -f "$PGDATA/standby.signal" || "$NEED_REWIND" == "true" || "$FORCE_BASEBACKUP" == "true" ]]; then
    log_msg "Выполняю резервное копирование расходящегося хвоста перед синхронизацией..."

    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    CURRENT_TLI=$(get_control_value "Latest checkpoint.s TimeLineID")
    CURRENT_TLI=${CURRENT_TLI:-unknown}

    TAIL_DIR="${BACKUP_ROOT}/tail_${TIMESTAMP}_tli${CURRENT_TLI}"
    mkdir -p "$TAIL_DIR/wal" "$TAIL_DIR/meta"

    cp -p "$PGDATA/global/pg_control" "$TAIL_DIR/meta/pg_control.bak" 2>/dev/null || true
    cp -p "$PGDATA"/*.history "$TAIL_DIR/meta/" 2>/dev/null || true
    cp -p "$PGDATA/pg_wal"/*.history "$TAIL_DIR/meta/" 2>/dev/null || true

    TLI_HEX=""
    if [[ "$CURRENT_TLI" =~ ^[0-9]+$ ]]; then
      TLI_HEX=$(printf "%08X" "$CURRENT_TLI")
    fi

    # Архивируем ВСЕ WAL текущего разошедшегося таймлайна
    if [[ -n "$TLI_HEX" ]]; then
      find "$PGDATA/pg_wal" -maxdepth 1 -name "${TLI_HEX}*" -type f -exec cp -p {} "$TAIL_DIR/wal/" \; 2>/dev/null || true
    fi

    # Ротация старых бэкапов хвостов (оставляем последние 5 каталогов)
    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name "tail_*" | sort -r | tail -n +6 | xargs -r rm -rf 2>/dev/null || true

    REWIND_SUCCESS=false

    # Попытка pg_rewind
    if [[ "$FORCE_BASEBACKUP" != "true" ]]; then
      set +e
      timeout 180 sudo -u postgres PGPASSFILE="$PGPASS_FILE" \
        "$PGBIN/pg_rewind" \
        --target-pgdata="$PGDATA" \
        --source-server="$CONNSTR" \
        --write-recovery-conf >>"$SPLITBRAIN_LOG" 2>&1
      REWIND_RC=$?
      set -e

      if [[ "$REWIND_RC" -eq 0 && -f "$PGDATA/standby.signal" ]]; then
        REWIND_SUCCESS=true
        SYNC_OK=true
        log_msg "pg_rewind успешно выполнен, создан standby.signal."
      else
        log_msg "pg_rewind завершился неудачно (rc=$REWIND_RC). Переход к pg_basebackup."
      fi
    fi

    # Выполнение pg_basebackup при невозможности rewind
    if [[ "$REWIND_SUCCESS" != "true" ]]; then
      log_msg "Подготовка к pg_basebackup..."

      # Проверка, не является ли PGDATA точкой монтирования
      if mountpoint -q "$PGDATA"; then
        log_msg "КРИТИЧЕСКАЯ ОШИБКА: $PGDATA является точкой монтирования. Атомарная ротация каталогов (mv) невозможна!"
        log_msg "Рекомендация: перенесите файлы БД в подкаталог, например: $PGDATA/data"
        exit 1
      fi

      PG_PARENT=$(dirname "$PGDATA")
      TEMP_PGDATA="${PG_PARENT}/.incoming_pgdata.$$"

      # Проверка свободного места: нужно минимум 120% от текущего размера PGDATA
      CURRENT_SIZE_KB=$(du -s -k "$PGDATA" 2>/dev/null | awk '{print $1}' || echo "0")
      AVAIL_SPACE_KB=$(df -P -k "$PG_PARENT" 2>/dev/null | tail -n 1 | awk '{print $4}' || echo "0")
      REQUIRED_SPACE_KB=$(( CURRENT_SIZE_KB * 12 / 10 ))

      if (( AVAIL_SPACE_KB < REQUIRED_SPACE_KB )); then
        log_msg "КРИТИЧЕСКАЯ ОШИБКА: недостаточно места на диске для basebackup! Требуется: ~${REQUIRED_SPACE_KB}KB, доступно: ${AVAIL_SPACE_KB}KB."
        exit 1
      fi

      rm -rf "$TEMP_PGDATA"
      mkdir -p "$TEMP_PGDATA"
      chown postgres:postgres "$TEMP_PGDATA"
      chmod 0700 "$TEMP_PGDATA"

      BASEBACKUP_ARGS=(
        -d "$CONNSTR"
        -D "$TEMP_PGDATA"
        -Fp -Xs -R
        -S "$MY_SLOT"
      )

      if [[ "$BASEBACKUP_CREATE_SLOT" == "true" ]]; then
        BASEBACKUP_ARGS+=( -C )
        log_msg "Добавлен флаг -C для создания слота $MY_SLOT на мастере."
      fi

      set +e
      sudo -u postgres PGPASSFILE="$PGPASS_FILE" \
        "$PGBIN/pg_basebackup" "${BASEBACKUP_ARGS[@]}" >>"$SPLITBRAIN_LOG" 2>&1
      BB_RC=$?
      set -e

      if [[ "$BB_RC" -eq 0 && -f "$TEMP_PGDATA/standby.signal" && -f "$TEMP_PGDATA/PG_VERSION" ]]; then
        log_msg "pg_basebackup успешно загружен. Выполняю атомарную ротацию каталогов..."

        BACKUP_OLD="${PG_PARENT}/.old_pgdata.$$"

        if mv "$PGDATA" "$BACKUP_OLD" 2>>"$SPLITBRAIN_LOG" && \
           mv "$TEMP_PGDATA" "$PGDATA" 2>>"$SPLITBRAIN_LOG"; then
          rm -rf "$BACKUP_OLD" 2>/dev/null || true
          SYNC_OK=true
          TEMP_PGDATA="" # Снимаем с trap
          log_msg "Каталог PGDATA успешно обновлен из basebackup."
        else
          log_msg "КРИТИЧЕСКАЯ ОШИБКА: сбой ротации каталогов PGDATA!"
          if [[ -d "$BACKUP_OLD" && ! -d "$PGDATA" ]]; then
            mv "$BACKUP_OLD" "$PGDATA" 2>/dev/null || true
          fi
          exit 1
        fi
      else
        log_msg "КРИТИЧЕСКАЯ ОШИБКА: pg_basebackup упал (rc=$BB_RC) или не создал standby.signal. Исходный PGDATA не затронут."
        exit 1
      fi
    fi

    if [[ "$SYNC_OK" != "true" ]]; then
      log_msg "КРИТИЧЕСКАЯ ОШИБКА: узел не приведен в состояние валидного standby."
      exit 1
    fi
  fi

  # Сброс transient-атрибута Pacemaker
  if command -v crm_attribute >/dev/null 2>&1; then
    crm_attribute -N "$MY_NODE_NAME" -l reboot -n master-pgsql -D 2>/dev/null || true
  fi
fi

# =============================================================================
# 5. ПРОВЕРКА И ОБНОВЛЕНИЕ ПАРАМЕТРОВ РЕПЛИКАЦИИ
# =============================================================================
if [[ -f "$PGDATA/standby.signal" ]]; then
  AUTO_CONF="$PGDATA/postgresql.auto.conf"
  touch "$AUTO_CONF"

  # Удаляем старую директиву primary_slot_name (если была) и записываем актуальную
  sed -i '/^[[:space:]]*primary_slot_name[[:space:]]*=/d' "$AUTO_CONF"
  echo "primary_slot_name = '${MY_SLOT}'" >> "$AUTO_CONF"
  chown postgres:postgres "$AUTO_CONF" "$PGDATA/standby.signal" 2>/dev/null || true
  chmod 0600 "$AUTO_CONF" 2>/dev/null || true
  log_msg "Параметр primary_slot_name = '${MY_SLOT}' успешно зафиксирован в postgresql.auto.conf"
fi

# =============================================================================
# 6. ФИКСАЦИЯ РЕЖИМА ЗАПУСКА ДЛЯ СТОРОЖА ДЕГРАДИРОВАННОГО РЕЖИМА
# =============================================================================
FINAL_STATE=$(get_control_value "Database cluster state")
FINAL_STATE=${FINAL_STATE:-unknown}

if [[ "$FINAL_STATE" == "unknown" ]]; then
  log_msg "КРИТИЧЕСКАЯ ОШИБКА: не удалось получить финальный статус БД."
  exit 1
fi

if [[ -f "$PGDATA/standby.signal" ]] || [[ "$FINAL_STATE" == *"recovery"* ]]; then
  DETECTED_ROLE="SLAVE"
else
  DETECTED_ROLE="MASTER"
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
[[ -f "$BOOT_MODE_FILE" ]] && source "$BOOT_MODE_FILE"

log_msg() { timeout 2 logger -t cluster-watchdog "$1" || true; }

unblock_quorum_safely() {
  log_msg "Выполняю отмену wait_for_all для кворума..."
  pcs quorum unblock --yes 2>/dev/null || \
  corosync-cmapctl -s quorum.cancel_wait_for_all u8 1 2>/dev/null || true
}

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

TOTAL_WAIT=$(( ${UNBLOCK_TIMEOUT_SEC:-$CRASH_TIMEOUT_SEC} + EXTRA_DELAY ))
log_msg "Ожидание сбора кворума: ${TOTAL_WAIT} сек (Режим: ${MODE:-UNKNOWN}, Роль: ${LAST_ROLE:-UNKNOWN})..."
sleep "$TOTAL_WAIT"

if corosync-quorumtool -s 2>/dev/null | grep -q "Quorate:.*Yes"; then
  log_msg "Обе ноды в строю, кворум собран штатно."
  exit 0
fi

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
  sleep "${NODE2_ASYMMETRIC_DELAY_SEC:-120}"
  if corosync-quorumtool -s 2>/dev/null | grep -q "Quorate:.*Yes"; then
    exit 0
  fi
  log_msg "Мастер не появился. Разблокировка кворума для промоута реплики."
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