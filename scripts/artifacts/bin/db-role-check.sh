#!/usr/bin/env bash
# Socket-activated HTTP health handler. One SQL snapshot, bounded input/runtime.
set -o pipefail
for ((n=0; n<64; n++)); do
    IFS= read -r -t 2 line || exit 1
    line=${line%$'\r'}
    [[ -z $line ]] && break
done
DB_PORT=${DB_PORT:-5432}
PGBIN=${PGBIN:-/usr/lib/postgresql/16/bin}
result=$(timeout --kill-after=1s 2s env PGCONNECT_TIMEOUT=1 \
    PGOPTIONS='-c statement_timeout=1500' "$PGBIN/psql" -X -w -qAt \
    -h /var/run/postgresql -p "$DB_PORT" -U postgres -d postgres \
    -c "SELECT NOT pg_is_in_recovery() AND current_setting('transaction_read_only') = 'off';" 2>/dev/null) || result=f
if [[ $result == t ]]; then
    printf 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 8\r\nConnection: close\r\n\r\nMaster\r\n'
else
    printf 'HTTP/1.1 503 Service Unavailable\r\nContent-Type: text/plain\r\nContent-Length: 7\r\nConnection: close\r\n\r\nSlave\r\n'
fi
