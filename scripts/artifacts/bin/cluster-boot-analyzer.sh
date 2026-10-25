#!/usr/bin/env bash
# Read-only database preflight. Recovery belongs exclusively to PAF/pgsqlms-ha.
set -euo pipefail
export LC_ALL=C
source /etc/default/ha-cluster
BOOT_MODE_FILE=${BOOT_MODE_FILE:-/run/cluster_boot_mode}
case $(hostname -s) in
    "$NODE1_NAME"|"$NODE2_NAME") ;;
    *) echo 'Неизвестный узел кластера' >&2; exit 1 ;;
esac
# A restarted Corosync/Pacemaker must not stop or rewrite a live database.
# PAF handles an existing instance. Never remove PID or socket files here.
state=unknown
if [[ -f $PGDATA/global/pg_control ]]; then
    state=$("$PGBIN/pg_controldata" "$PGDATA" | awk -F: '/Database cluster state/ {sub(/^[ \t]+/, "", $2); print $2}')
fi
role=UNKNOWN
case "$state" in
    'shut down'|'in production') role=MASTER ;;
    *recovery*) role=SLAVE ;;
esac
if [[ -f $PGDATA/standby.signal ]]; then role=SLAVE; fi
# Missing PGDATA is allowed: wrapper may bootstrap it from an available primary.
check_path=$PGDATA
while [[ ! -d $check_path && $check_path != / ]]; do check_path=$(dirname "$check_path"); done
used=$(df -P "$check_path" | awk 'END {gsub(/%/, "", $5); print $5}')
inodes=$(df -Pi "$check_path" | awk 'END {gsub(/%/, "", $5); print $5}')
for pct in "$used" "$inodes"; do
    [[ $pct =~ ^[0-9]+$ ]] || { echo 'Не удалось определить доступное место файловой системы' >&2; exit 1; }
    (( 100 - pct >= ${MIN_FREE_DISK_PCT:-5} )) || { echo 'Недостаточно свободного места или inode' >&2; exit 1; }
done
case "$state" in
    'shut down'|'shut down in recovery') mode=COLD_START; delay=${COLD_START_TIMEOUT_SEC:-180} ;;
    *) mode=CRASH_RECOVERY; delay=${CRASH_TIMEOUT_SEC:-900} ;;
esac
[[ $delay =~ ^[1-9][0-9]*$ && $BOOT_MODE_FILE == /* ]] || exit 1
umask 077
mkdir -p "$(dirname "$BOOT_MODE_FILE")"
temp=$(mktemp "${BOOT_MODE_FILE}.XXXXXX")
trap 'rm -f "$temp"' EXIT
printf 'MODE=%s\nLAST_ROLE=%s\nUNBLOCK_TIMEOUT_SEC=%s\n' "$mode" "$role" "$delay" > "$temp"
mv -f "$temp" "$BOOT_MODE_FILE"
logger -t cluster-precheck -- "Предстартовая проверка: состояние=$state режим=$mode роль=$role; PGDATA не изменялся"
