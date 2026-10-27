#!/usr/bin/env bash
# Database preflight with crash-recovery reconciliation.
# Brings dirty stopped instances to a clean shut-down state before Pacemaker/PAF starts.
set -euo pipefail
export LC_ALL=C

ENV_FILE="/etc/default/ha-cluster"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "[ОШИБКА] Файл конфигурации $ENV_FILE не найден!" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

BOOT_MODE_FILE=${BOOT_MODE_FILE:-/run/cluster_boot_mode}

case $(hostname -s) in
    "$NODE1_NAME"|"$NODE2_NAME") ;;
    *) echo 'Неизвестный узел кластера' >&2; exit 1 ;;
esac

# 1. Проверка доступного места и inode
check_path=$PGDATA
while [[ ! -d $check_path && $check_path != / ]]; do check_path=$(dirname "$check_path"); done
used=$(df -P "$check_path" | awk 'END {gsub(/%/, "", $5); print $5}')
inodes=$(df -Pi "$check_path" | awk 'END {gsub(/%/, "", $5); print $5}')
for pct in "$used" "$inodes"; do
    [[ $pct =~ ^[0-9]+$ ]] || { echo 'Не удалось определить доступное место файловой системы' >&2; exit 1; }
    (( 100 - pct >= ${MIN_FREE_DISK_PCT:-5} )) || { echo 'Недостаточно свободного места или inode' >&2; exit 1; }
done

# 2. Определение текущего состояния базы данных
state="unknown"
if [[ -f "$PGDATA/global/pg_control" && -x "$PGBIN/pg_controldata" ]]; then
    state=$(sudo -u postgres "$PGBIN/pg_controldata" "$PGDATA" 2>/dev/null | \
        awk -F: '/Database cluster state/ {sub(/^[ \t]+/, "", $2); print $2}')
fi

was_crashed=0

# 3. Приведение к консистентному состоянию (Crash Recovery)
# Вмешательство допустимо только если локальный процесс PostgreSQL гарантированно не запущен
if ! sudo -u postgres "$PGBIN/pg_ctl" -D "$PGDATA" status >/dev/null 2>&1; then
    if [[ "$state" == "in production" || "$state" == "in archive recovery" ]]; then
        was_crashed=1
        logger -t cluster-precheck -- "Обнаружен 'грязный' статус ($state) при остановленном процессе. Запуск Crash Recovery..."

        if sudo -u postgres "$PGBIN/pg_ctl" -D "$PGDATA" \
            -o "-c listen_addresses='' -p $DB_PORT" \
            -w -t "${CRASH_TIMEOUT_SEC:-900}" start; then

            sudo -u postgres "$PGBIN/pg_ctl" -D "$PGDATA" -m fast -w -t 60 stop || {
                logger -t cluster-precheck -- "[ОШИБКА] Не удалось корректно остановить базу после Crash Recovery" >&2
                exit 1
            }

            state=$(sudo -u postgres "$PGBIN/pg_controldata" "$PGDATA" 2>/dev/null | \
                awk -F: '/Database cluster state/ {sub(/^[ \t]+/, "", $2); print $2}')
            logger -t cluster-precheck -- "Восстановление завершено. Новый статус: $state"
        else
            logger -t cluster-precheck -- "[ОШИБКА] Сбой при попытке наката WAL через pg_ctl start" >&2
            exit 1
        fi
    fi
else
    logger -t cluster-precheck -- "PostgreSQL уже запущен в системе, пропуск локального Crash Recovery"
fi

# 4. Классификация роли на основе полученного состояния
role="UNKNOWN"
case "$state" in
    'shut down'|'in production') role="MASTER" ;;
    *recovery*) role="SLAVE" ;;
esac
if [[ -f "$PGDATA/standby.signal" ]]; then 
    role="SLAVE"
fi

# 5. Определение режима запуска для окружения веб-хоста
if [[ $was_crashed -eq 1 ]]; then
    mode="CRASH_RECOVERY_APPLIED"
    delay=${CRASH_TIMEOUT_SEC:-900}
else
    case "$state" in
        'shut down'|'shut down in recovery') 
            mode="COLD_START"
            delay=${COLD_START_TIMEOUT_SEC:-180} 
            ;;
        *) 
            mode="CRASH_RECOVERY"
            delay=${CRASH_TIMEOUT_SEC:-900} 
            ;;
    esac
fi

[[ $delay =~ ^[1-9][0-9]*$ && $BOOT_MODE_FILE == /* ]] || exit 1

# 6. Фиксация режима в файл
umask 077
mkdir -p "$(dirname "$BOOT_MODE_FILE")"
temp=$(mktemp "${BOOT_MODE_FILE}.XXXXXX")
trap 'rm -f "$temp"' EXIT
printf 'MODE=%s\nLAST_ROLE=%s\nUNBLOCK_TIMEOUT_SEC=%s\n' "$mode" "$role" "$delay" > "$temp"
mv -f "$temp" "$BOOT_MODE_FILE"

logger -t cluster-precheck -- "Предстартовая проверка завершена: состояние=$state режим=$mode роль=$role"