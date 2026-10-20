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
  echo "[ОШИБКА] Файл $ENV_FILE не найден! Сначала запустите configure-ha.sh."
  exit 1
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
# ШАГ 1. Создание вспомогательных кластерных скриптов
# -----------------------------------------------------------------------------
echo "[INFO] Создаю рабочие скрипты анализатора и сторожа деградации..."

# 1.1 Предстартовый анализатор
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

USED_SPACE_PCT=$(df -P "$PGDATA" 2>/dev/null | tail -n 1 | awk '{print $5}' | tr -dc '0-9' || true)
USED_SPACE_PCT=${USED_SPACE_PCT:-0}
USED_INODE_PCT=$(df -i -P "$PGDATA" 2>/dev/null | tail -n 1 | awk '{print $5}' | tr -dc '0-9' || true)
USED_INODE_PCT=${USED_INODE_PCT:-0}
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

    BACKUP_DIR="/var/backups/postgresql_splitbrain"
    LOG_FILE="/var/log/postgresql_splitbrain.log"
    MIN_ROWS_FOR_COPY=10000
    FORCE_BASEBACKUP=0

    mkdir -p "$BACKUP_DIR" "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    chown -R postgres:postgres "$BACKUP_DIR" "$LOG_FILE"

    log_sb() {
        local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
        log_msg "$1"
        echo "$msg" >> "$LOG_FILE"
    }

    validate_lsn() {
        [[ "$1" =~ ^[0-9A-Fa-f]+/[0-9A-Fa-f]+$ ]]
    }

    # 1. Защита от осиротевшего postmaster.pid
    if [[ -f "$PGDATA/postmaster.pid" ]]; then
        OLD_PID=$(head -1 "$PGDATA/postmaster.pid" 2>/dev/null || echo "")
        if [[ -n "$OLD_PID" ]] && ! kill -0 "$OLD_PID" 2>/dev/null; then
            log_sb "Удаление осиротевшего postmaster.pid (PID $OLD_PID не существует)"
            rm -f "$PGDATA/postmaster.pid"
        fi
    fi

    # 2. Crash Recovery перед pg_rewind
    log_sb "Выполнение изолированного Crash Recovery перед сверкой WAL..."
    if ! sudo -u postgres "$PGBIN/pg_ctl" -D "$PGDATA" -o "-c listen_addresses=''" start -w -t 60 >>"$LOG_FILE" 2>&1; then
        log_sb "КРИТИЧЕСКАЯ ОШИБКА: pg_ctl start не удался при Crash Recovery! Локальная БД повреждена."
        log_sb "Пропускаю создание дельты и pg_rewind — принудительно переключаюсь на pg_basebackup."
        FORCE_BASEBACKUP=1
    else
        if ! sudo -u postgres "$PGBIN/pg_ctl" -D "$PGDATA" stop -m fast -w -t 60 >>"$LOG_FILE" 2>&1; then
            log_sb "ОШИБКА: Штатная остановка pg_ctl stop не удалась, применяю режим immediate..."
            sudo -u postgres "$PGBIN/pg_ctl" -D "$PGDATA" stop -m immediate -w -t 30 >>"$LOG_FILE" 2>&1 || FORCE_BASEBACKUP=1
        fi
    fi

    # 3. Определение и валидация точки расхождения
    DIVERGE_LSN=""
    if [[ "$FORCE_BASEBACKUP" -eq 0 ]]; then
        log_sb "Поиск точки расхождения WAL с Мастером ($ACTIVE_PEER_IP)..."
        REWIND_RC=0
        REWIND_OUT=$(timeout 60 sudo -u postgres PGPASSFILE="$PGPASS_FILE" \
            "$PGBIN/pg_rewind" --dry-run \
            --target-pgdata="$PGDATA" \
            --source-server="host=$ACTIVE_PEER_IP port=$DB_PORT user=$REPL_USER dbname=postgres" 2>&1) || REWIND_RC=$?
        echo "$REWIND_OUT" >> "$LOG_FILE"

        if [[ "$REWIND_RC" -ne 0 ]]; then
            log_sb "ПРЕДУПРЕЖДЕНИЕ: pg_rewind --dry-run завершился с кодом $REWIND_RC"
        fi

        CANDIDATE_LSN=$(echo "$REWIND_OUT" | awk '/diverged at WAL location/ {print $6}')
        if validate_lsn "$CANDIDATE_LSN"; then
            DIVERGE_LSN="$CANDIDATE_LSN"
        else
            log_sb "Из вывода pg_rewind не получен валидный LSN. Проверяю .history файлы..."
            CUR_TLI=$(LC_ALL=C "$PGBIN/pg_controldata" "$PGDATA" 2>/dev/null | awk -F: '/Latest checkpoint.s TimeLineID/ {gsub(/^[ \t]+/, "", $2); print $2}')
            if [[ "$CUR_TLI" =~ ^[0-9]+$ ]]; then
                HIST_FILE="$PGDATA/pg_wal/$(printf '%08X' "$CUR_TLI").history"
                if [[ -f "$HIST_FILE" ]]; then
                    CANDIDATE_LSN=$(tail -n 1 "$HIST_FILE" | awk '{print $2}')
                    if validate_lsn "$CANDIDATE_LSN"; then
                        DIVERGE_LSN="$CANDIDATE_LSN"
                        log_sb "Валидный LSN точки расхождения извлечен из $HIST_FILE: $DIVERGE_LSN"
                    fi
                fi
            fi
        fi
    fi

    # 4. Выгрузка дельты и полного дампа при наличии валидного DIVERGE_LSN
    if [[ -n "$DIVERGE_LSN" ]]; then
        log_sb "Подтверждено расхождение историй WAL! Валидный LSN ветвления: $DIVERGE_LSN"

        TS=$(date +%Y%m%d_%H%M%S)
        SAFE_LSN="${DIVERGE_LSN//\//_}"
        DELTA_DIR="$BACKUP_DIR/delta_${SAFE_LSN}_${TS}"
        DELTA_SQL="$DELTA_DIR/delta_apply.sql"
        DELTA_REPORT="$DELTA_DIR/report.txt"
        FULL_DUMP="$BACKUP_DIR/full_dump_${SAFE_LSN}_${TS}.sql.gz"
        mkdir -p "$DELTA_DIR"
        chown postgres:postgres "$DELTA_DIR"

        FORK_TIME=""
        if WALDUMP_OUT=$("$PGBIN/pg_waldump" -p "$PGDATA/pg_wal" -s "$DIVERGE_LSN" -n 200 2>>"$LOG_FILE"); then
            FORK_TIME=$(echo "$WALDUMP_OUT" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+ [A-Z0-9+-]+' | head -n 1 || echo "")
        fi

        if [[ -z "$FORK_TIME" ]]; then
            LAST_HIST=$(ls -1t "$PGDATA"/pg_wal/*.history 2>/dev/null | head -n 1 || echo "")
            if [[ -n "$LAST_HIST" ]]; then
                FORK_TIME=$(date -d "@$(stat -c %Y "$LAST_HIST")" +"%Y-%m-%d %H:%M:%S%z")
            fi
        fi

        log_sb "Запуск PostgreSQL в изолированном режиме для выгрузки дельты..."
        if ! sudo -u postgres "$PGBIN/pg_ctl" -D "$PGDATA" -o "-c listen_addresses='' -c port=$DB_PORT" start -w -t 60 >>"$LOG_FILE" 2>&1; then
            log_sb "КРИТИЧЕСКАЯ ОШИБКА: Не удалось запустить PostgreSQL для выгрузки дельты! Переключаюсь на pg_basebackup."
            FORCE_BASEBACKUP=1
        else
            TRACK_TS=$(sudo -u postgres "$PGBIN/psql" -p "$DB_PORT" -U postgres -d postgres -tAc "SHOW track_commit_timestamp;" 2>>"$LOG_FILE" || echo "off")
            if [[ "$TRACK_TS" != "on" ]] || [[ -z "$FORK_TIME" ]]; then
                log_sb "ОШИБКА: track_commit_timestamp выключен или не найден FORK_TIME. Создаю только полный дамп."
            else
                {
                    echo "-- АВТОМАТИЧЕСКИЙ ДАМП РАСХОЖДЕНИЯ (SPLIT-BRAIN DELTA)"
                    echo "-- Узел: $(hostname) | LSN: $DIVERGE_LSN | Время: $FORK_TIME"
                    echo "SET session_replication_role = replica;"
                } > "$DELTA_SQL"

                {
                    echo "ОТЧЁТ ПО ДЕЛЬТЕ SPLIT-BRAIN"
                    echo "Узел: $(hostname) | LSN: $DIVERGE_LSN | Время: $FORK_TIME"
                } > "$DELTA_REPORT"

                DB_LIST=$(sudo -u postgres "$PGBIN/psql" -p "$DB_PORT" -U postgres -d postgres -tAc \
                    "SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres';" 2>>"$LOG_FILE")

                for dbname in $DB_LIST; do
                    echo "\\connect $dbname" >> "$DELTA_SQL"
                    echo "База данных: $dbname" >> "$DELTA_REPORT"

                    TABLE_LIST=$(sudo -u postgres "$PGBIN/psql" -p "$DB_PORT" -U postgres -d "$dbname" -tAc "
                        SELECT quote_ident(n.nspname) || '.' || quote_ident(c.relname)
                        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                        WHERE c.relkind = 'r' AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
                        ORDER BY n.nspname, c.relname;
                    " 2>>"$LOG_FILE")

                    for full_table in $TABLE_LIST; do
                        ROW_COUNT=$(sudo -u postgres "$PGBIN/psql" -p "$DB_PORT" -U postgres -d "$dbname" -tAc "
                            SELECT COUNT(*) FROM $full_table t
                            WHERE pg_xact_commit_timestamp(t.xmin) IS NOT NULL
                              AND pg_xact_commit_timestamp(t.xmin) >= '$FORK_TIME';
                        " 2>>"$LOG_FILE" || echo "0")

                        [[ "${ROW_COUNT:-0}" -eq 0 ]] && continue

                        echo "  - $full_table: $ROW_COUNT строк" >> "$DELTA_REPORT"
                        SAFE_TBL="${full_table//[^a-zA-Z0-9_]/_}"
                        CSV_FILE="$DELTA_DIR/${dbname}_${SAFE_TBL}.csv"

                        sudo -u postgres "$PGBIN/psql" -p "$DB_PORT" -U postgres -d "$dbname" -c "
                            COPY (
                                SELECT * FROM $full_table t
                                WHERE pg_xact_commit_timestamp(t.xmin) IS NOT NULL
                                  AND pg_xact_commit_timestamp(t.xmin) >= '$FORK_TIME'
                            ) TO STDOUT WITH CSV HEADER
                        " > "$CSV_FILE" 2>>"$LOG_FILE" || true

                        if [[ "$ROW_COUNT" -le "$MIN_ROWS_FOR_COPY" ]]; then
                            COLUMNS=$(sudo -u postgres "$PGBIN/psql" -p "$DB_PORT" -U postgres -d "$dbname" -tAc "
                                SELECT string_agg(quote_ident(attname), ', ' ORDER BY attnum)
                                FROM pg_attribute
                                WHERE attrelid = '$full_table'::regclass AND attnum > 0 AND NOT attisdropped AND attgenerated = '';
                            " 2>>"$LOG_FILE")

                            if [[ -n "$COLUMNS" ]]; then
                                sudo -u postgres "$PGBIN/psql" -p "$DB_PORT" -U postgres -d "$dbname" -tAc "
                                    SELECT format(
                                        'INSERT INTO $full_table ($COLUMNS) SELECT $COLUMNS FROM json_populate_recordset(NULL::$full_table, %L::json) ON CONFLICT DO NOTHING;',
                                        json_agg(row_to_json(t))::text
                                    )
                                    FROM (
                                        SELECT * FROM $full_table t
                                        WHERE pg_xact_commit_timestamp(t.xmin) IS NOT NULL
                                          AND pg_xact_commit_timestamp(t.xmin) >= '$FORK_TIME'
                                    ) t
                                    HAVING json_agg(row_to_json(t)) IS NOT NULL;
                                " >> "$DELTA_SQL" 2>>"$LOG_FILE" || true
                            fi
                        fi
                    done
                done
            fi

            sudo -u postgres "$PGBIN/pg_dumpall" -p "$DB_PORT" 2>>"$LOG_FILE" | gzip > "$FULL_DUMP" || true
            sudo -u postgres "$PGBIN/pg_ctl" -D "$PGDATA" stop -m fast -w -t 60 >>"$LOG_FILE" 2>&1 || {
                sudo -u postgres "$PGBIN/pg_ctl" -D "$PGDATA" stop -m immediate -w -t 30 >>"$LOG_FILE" 2>&1 || true
                FORCE_BASEBACKUP=1
            }
        fi
    fi

    # 5. Синхронизация с Мастером
    if [[ "$FORCE_BASEBACKUP" -eq 1 ]] || [[ "$SLOT_STATUS" == "lost" ]] || ! timeout 300 sudo -u postgres PGPASSFILE="$PGPASS_FILE" \
        "$PGBIN/pg_rewind" \
        --target-pgdata="$PGDATA" \
        --source-server="host=$ACTIVE_PEER_IP port=$DB_PORT user=$REPL_USER dbname=postgres" >>"$LOG_FILE" 2>&1; then

        log_sb "Выполняю пересборку реплики через pg_basebackup от $ACTIVE_PEER_IP..."
        rm -rf "${PGDATA:?}"/*
        if ! timeout 600 sudo -u postgres PGPASSFILE="$PGPASS_FILE" \
            "$PGBIN/pg_basebackup" --no-password \
            -h "$ACTIVE_PEER_IP" -p "$DB_PORT" -U "$REPL_USER" \
            -D "$PGDATA" -Fp -Xs -R -S "$MY_SLOT" >>"$LOG_FILE" 2>&1; then
            log_sb "КРИТИЧЕСКАЯ ОШИБКА: pg_basebackup завершился неудачей! Блокирую старт."
            exit 1
        fi
    fi

    touch "$PGDATA/standby.signal"
    chown postgres:postgres "$PGDATA/standby.signal"

  elif [[ "$SLOT_STATUS" == "lost" ]]; then
    log_msg "Слот $MY_SLOT потерян. Пересоздаю реплику через pg_basebackup..."
    rm -rf "${PGDATA:?}"/*
    timeout 600 sudo -u postgres PGPASSFILE="$PGPASS_FILE" pg_basebackup --no-password \
      -h "$ACTIVE_PEER_IP" -p "$DB_PORT" -U "$REPL_USER" -D "$PGDATA" -Fp -Xs -R -S "$MY_SLOT"
    touch "$PGDATA/standby.signal"
    chown postgres:postgres "$PGDATA/standby.signal"
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

# 1.2 Сторож деградированного режима
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
log_msg "Ожидание сбора кворума: ${TOTAL_WAIT} сек (Режим: ${MODE:-UNKNOWN}, Роль: ${LAST_ROLE:-UNKNOWN})..."
sleep "$TOTAL_WAIT"

if corosync-quorumtool -s 2>/dev/null | grep -q "Quorate:.*Yes"; then
  log_msg "Обе ноды в строю, кворум собран штатно."
  exit 0
fi

# Проверка №1: Маршрутизатор
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

# Проверка №2: Сосед молчит
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

# Проверка №3: VIP не занят
if ping -c 2 -W 1 "$CLUSTER_VIP" >/dev/null 2>&1; then
  log_msg "КРИТИЧЕСКАЯ ОШИБКА: VIP ($CLUSTER_VIP) отвечает на ping! Защита от Split-Brain."
  exit 1
fi
if arping -D -I "$CLUSTER_VIP_NIC" -c 2 -w 2 "$CLUSTER_VIP" >/dev/null 2>&1; then
  log_msg "КРИТИЧЕСКАЯ ОШИБКА: VIP ($CLUSTER_VIP) занят (ARP-ответ)! Защита от Split-Brain."
  exit 1
fi

# Проверка №4: Решение по роли
if [[ "${LAST_ROLE:-}" == "MASTER" ]]; then
  log_msg "Узел был MASTER. Разблокировка кворума."
  pcs quorum unblock --yes
elif [[ "${LAST_ROLE:-}" == "SLAVE" ]]; then
  log_msg "Узел был SLAVE. Дополнительное ожидание ${NODE2_ASYMMETRIC_DELAY_SEC}с..."
  sleep "${NODE2_ASYMMETRIC_DELAY_SEC:-120}"

  if corosync-quorumtool -s 2>/dev/null | grep -q "Quorate:.*Yes"; then
    exit 0
  fi
  if ping -c 2 -W 1 "$CLUSTER_VIP" >/dev/null 2>&1; then
    exit 1
  fi

  log_msg "Мастер не появился. Разблокировка кворума для промоута реплики."
  pcs quorum unblock --yes
else
  exit 1
fi
EOF
chmod +x /usr/local/sbin/cluster-degraded-unblock.sh

# -----------------------------------------------------------------------------
# ШАГ 2. Регистрация кластерных systemd-юнитов и OOM-тюнинг
# -----------------------------------------------------------------------------
echo "[INFO] Регистрация кластерных юнитов в systemd..."

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

# Защита от OOM-Killer и RT-приоритет для Corosync
mkdir -p /etc/systemd/system/corosync.service.d
cat << 'EOF' > /etc/systemd/system/corosync.service.d/ha-hardening.conf
[Service]
OOMScoreAdjust=-1000
CPUSchedulingPolicy=rr
CPUSchedulingPriority=99
LimitNOFILE=65536
LimitMEMLOCK=infinity
EOF

# Тюнинг для критических кластерных демонов
for crit_svc in pacemaker postgresql "postgresql@${PG_VERSION}-main" haproxy; do
  mkdir -p "/etc/systemd/system/${crit_svc}.service.d"
  cat << 'EOF' > "/etc/systemd/system/${crit_svc}.service.d/ha-hardening.conf"
[Service]
EnvironmentFile=-/etc/default/ha-cluster
OOMScoreAdjust=-1000
LimitNOFILE=65536
EOF
done

# Применение cgroups-лимитов к сервисам приложения (если они зарегистрированы в системе)
for app_svc in $APP_SERVICE $DAEMON_SERVICE; do
  if systemctl list-unit-files 2>/dev/null | grep -q "^${app_svc}.service"; then
    mkdir -p "/etc/systemd/system/${app_svc}.service.d"
    cat << EOF > "/etc/systemd/system/${app_svc}.service.d/ha-limits.conf"
[Service]
MemoryMax=${APP_MEMORY_MAX}
CPUQuota=${APP_CPU_QUOTA}
OOMScoreAdjust=500
LimitNOFILE=65536
EOF
  fi
done

# Ограничение размера системного журнала
mkdir -p /etc/systemd/journald.conf.d
cat << 'EOF' > /etc/systemd/journald.conf.d/ha-limits.conf
[Journal]
SystemMaxUse=500M
RuntimeMaxUse=100M
EOF

systemctl daemon-reload
systemctl restart systemd-journald 2>/dev/null || true

systemctl enable pcsd.service 2>/dev/null || true
systemctl enable cluster-boot-analyzer.service cluster-degraded-unblock.timer 2>/dev/null || true

# -----------------------------------------------------------------------------
# ШАГ 3. Инициализация кластера Corosync и Pacemaker (только с --init-pcs)
# -----------------------------------------------------------------------------
CURRENT_NODE_NAME=$(hostname -s)

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

  # Свойства кластера
  pcs property set stonith-enabled=false
  pcs property set no-quorum-policy=stop
  pcs property set start-failure-is-fatal=true
  pcs resource defaults update migration-threshold=3 \
    failure-timeout="$FAILURE_TIMEOUT_SEC" resource-stickiness=100

  # 1. Псевдо-арбитр (ping к шлюзу)
  pcs resource create ping-gateway ocf:pacemaker:ping \
    host_list="$ROUTER_IPS" multiplier=1000 dampen=10s \
    op monitor interval=5s timeout=10s \
    clone meta interleave=true

  # 2. PostgreSQL (promotable)
  pcs resource create pgsql ocf:heartbeat:pgsqlms \
    system_user=postgres \
    bindir="$PGBIN" \
    pgdata="$PGDATA" \
    pghost="/var/run/postgresql" \
    pgport="$DB_PORT" \
    maxlag=1048576 \
    op start timeout=60s \
    op stop timeout=60s \
    op reload timeout=20s \
    op promote timeout=30s \
    op demote timeout=120s \
    op monitor interval=15s timeout=10s \
    op monitor interval=15s role=Master timeout=10s \
    op monitor interval=16s role=Slave timeout=10s \
    op notify timeout=60s \
    meta promotable=true notify=true

  # 3. Балансировщик HAProxy (клон на обеих нодах)
  pcs resource create haproxy-svc systemd:haproxy \
    op monitor interval=10s \
    clone meta interleave=true

  # 4. Группа app-stack: VIP + Веб-приложение
  pcs resource create vip ocf:heartbeat:IPaddr2 \
    ip="$CLUSTER_VIP" cidr_netmask="$CLUSTER_VIP_CIDR" nic="$CLUSTER_VIP_NIC" \
    run_arping=true arp_interval=500 arp_count=5 arp_bg=true \
    op monitor interval=5s timeout=20s \
    --group app-stack

  for svc in $APP_SERVICE; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}.service"; then
      pcs resource create "app-${svc}" "systemd:${svc}" \
        op monitor interval=10s \
        --group app-stack
    fi
  done

  # 5. Группа daemon-stack: Фоновый демон
  for dsvc in $DAEMON_SERVICE; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${dsvc}.service"; then
      pcs resource create "daemon-${dsvc}" "systemd:${dsvc}" \
        op monitor interval=10s \
        --group daemon-stack
    fi
  done

  # Ограничения размещения по доступности шлюза
  pcs constraint location app-stack rule score-attribute=pingd pingd gt 0
  pcs constraint location pgsql-clone rule role=Master score-attribute=pingd pingd gt 0
  if pcs resource config daemon-stack >/dev/null 2>&1; then
    pcs constraint location daemon-stack rule score-attribute=pingd pingd gt 0
    pcs constraint colocation add daemon-stack with Master pgsql-clone 500
    pcs constraint order start haproxy-svc-clone then start daemon-stack
  fi

  # Связывание групп с Мастером БД
  pcs constraint colocation add app-stack with Master pgsql-clone 500

  # Порядок запуска: HAProxy должен стартовать до приложения
  pcs constraint order start haproxy-svc-clone then start app-stack

  echo "[УСПЕХ] Кластер успешно инициализирован и запущен! Проверьте: pcs status"
else
  echo "[УСПЕХ] Узел ${CURRENT_NODE_NAME} успешно подготовлен на уровне кластерных сервисов."
  echo "Для финальной инициализации кластера выполните на ${NODE1_NAME}:"
  echo "  sudo $0 --init-pcs"
fi