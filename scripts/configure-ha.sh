#!/bin/bash
# =============================================================================
# СКРИПТ РАЗВЕРТЫВАНИЯ И ОРКЕСТРАЦИИ HA-КЛАСТЕРА (COROSYNC / PACEMAKER)
# =============================================================================
set -euo pipefail

ENV_FILE="/etc/default/ha-cluster"
case ${1:-} in
  ''|--init-pcs) ;;
  *) echo "Использование: $0 [--init-pcs]" >&2; exit 2 ;;
esac

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
for key in NODE1_NAME NODE2_NAME NODE1_RING0_IP NODE1_RING1_IP NODE2_RING0_IP NODE2_RING1_IP CLUSTER_VIP CLUSTER_VIP_CIDR CLUSTER_VIP_NIC; do
  [[ -n ${!key:-} ]] || { echo "Не задан параметр конфигурации: $key" >&2; exit 1; }
done
case $(hostname -s) in
  "$NODE1_NAME"|"$NODE2_NAME") ;;
  *) echo 'Неизвестный узел кластера' >&2; exit 1 ;;
esac
APP_SERVICE=${APP_SERVICE:-}
DAEMON_SERVICE=${DAEMON_SERVICE:-}
if [[ ${1:-} == --init-pcs && -f /etc/corosync/corosync.conf ]]; then
  echo 'Кластер уже настроен; повторная инициализация запрещена, изменения не внесены' >&2
  exit 1
fi
for service in $APP_SERVICE $DAEMON_SERVICE; do
  [[ $service =~ ^[a-zA-Z0-9_@.-]+$ ]] || { echo "Недопустимое имя службы: $service" >&2; exit 1; }
done

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

# Runtime artifacts have a single source of truth, independent of the installer.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/artifacts.sh"

for script in cluster-boot-analyzer.sh cluster-degraded-unblock.sh; do
  install_artifact "bin/$script" "/usr/local/sbin/$script" 0755
done
render_artifact systemd/cluster-boot-analyzer.service.tpl /etc/systemd/system/cluster-boot-analyzer.service
for unit in cluster-degraded-unblock.service cluster-degraded-unblock.timer; do
  install_artifact "systemd/$unit" "/etc/systemd/system/$unit"
done
for service in corosync pacemaker; do
  install_artifact systemd/cluster-preflight.conf "/etc/systemd/system/$service.service.d/ha-preflight.conf"
  # Replace obsolete RT=99/OOM=-1000 policy installed by previous versions.
  install_artifact systemd/ha-limits.conf "/etc/systemd/system/$service.service.d/ha-hardening.conf"
done
systemctl daemon-reload
systemctl enable pcsd.service
# Preflight is pulled in by explicit Requires= drop-ins, not enable-time links.
# Preserve the existing degraded quorum policy; fencing/quorum redesign is separate.
systemctl enable cluster-degraded-unblock.timer

# -----------------------------------------------------------------------------
# ШАГ 3. Инициализация кластера Corosync и Pacemaker (только с --init-pcs)
# -----------------------------------------------------------------------------
CURRENT_NODE_NAME=$(hostname -s)
case "$CURRENT_NODE_NAME" in
  "$NODE1_NAME"|"$NODE2_NAME") ;;
  *) echo "[ОШИБКА] Неизвестный узел: $CURRENT_NODE_NAME" >&2; exit 1 ;;
esac

if [[ "${1:-}" == "--init-pcs" ]]; then
  echo "[INFO] Инициализирую кластер Corosync и ресурсы Pacemaker..."

  [[ "$CURRENT_NODE_NAME" == "$NODE1_NAME" ]] || { echo "Выполните инициализацию с узла $NODE1_NAME" >&2; exit 1; }
  [[ ! -f /etc/corosync/corosync.conf ]] || { echo 'Кластер уже настроен; разрушительная повторная инициализация запрещена' >&2; exit 1; }
  for key in COROSYNC_TOKEN_MS TAIL_BACKUP_TIMEOUT_SEC REWIND_TIMEOUT_SEC BASEBACKUP_TIMEOUT_SEC PG_STOP_TIMEOUT_SEC; do
    value=${!key:-}
    [[ -z $value || $value =~ ^[1-9][0-9]*$ ]] || { echo "Недопустимое значение таймаута: $key" >&2; exit 1; }
  done
  [[ -x /usr/lib/ocf/resource.d/heartbeat/pgsqlms-ha ]] || { echo 'Сначала установите pgsqlms-ha на ОБОИХ узлах' >&2; exit 1; }
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
          consensus="$((COROSYNC_TOKEN_MS * 2))" \
          join=60

  pcs quorum update wait_for_all=1

  pcs cluster start --all
  pcs cluster enable --all

  # No resources exist yet. Keep scheduling disabled until all constraints exist.
  pcs property set maintenance-mode=true

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

  # 4. PostgreSQL: архивирование + rewind + basebackup + запуск PAF.
  recovery_start_timeout=$(( ${TAIL_BACKUP_TIMEOUT_SEC:-900} + ${REWIND_TIMEOUT_SEC:-180} + ${BASEBACKUP_TIMEOUT_SEC:-540} + ${PG_STOP_TIMEOUT_SEC:-60} + 180 ))
  pcs resource create pgsql ocf:heartbeat:pgsqlms-ha \
    bindir="$PGBIN" \
    pgdata="$PGDATA" \
    pghost="/var/run/postgresql" \
    pgport="$DB_PORT" \
    op start timeout="${recovery_start_timeout}s" \
    op stop timeout="$(( ${PG_STOP_TIMEOUT_SEC:-60} + 30 ))s" \
    op reload timeout=20s \
    op promote timeout=60s \
    op demote timeout=120s \
    op notify timeout=60s \
    op monitor interval=5s role="Promoted" timeout=30s \
    op monitor interval=10s role="Unpromoted" timeout=30s \
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
    arp_interval=200 arp_count=5 \
    op monitor interval=5s timeout=20s \
    --group app-stack

  for svc in $APP_SERVICE; do
    svc_clean="${svc%.service}"
    pcs resource create "app-${svc_clean}" "systemd:${svc_clean}" \
      op start timeout=30s \
      op stop timeout=30s \
      op monitor interval=10s timeout=20s \
      --group app-stack
  done

  # Варинат 1: Один гуляющий демон
  # 7. Группа daemon-stack (фоновый демон записи)
  # for dsvc in $DAEMON_SERVICE; do
  #   dsvc_clean="${dsvc%.service}"
  #   pcs resource create "daemon-${dsvc_clean}" "systemd:${dsvc_clean}" \
  #     op start timeout=30s \
  #     op stop timeout=30s \
  #     op monitor interval=10s timeout=20s \
  #     --group daemon-stack
  # done

  # Варинат 2: Клон на каждой ноде
  for dsvc in $DAEMON_SERVICE; do
    dsvc_clean="${dsvc%.service}"
    pcs resource create "daemon-${dsvc_clean}" "systemd:${dsvc_clean}" \
      op start timeout=30s \
      op stop timeout=30s \
      op monitor interval=10s timeout=20s \
      clone meta interleave=true
  done

  # ---------------------------------------------------------------------------
  # ОГРАНИЧЕНИЯ РАЗМЕЩЕНИЯ И ПОРЯДКА
  # ---------------------------------------------------------------------------
  pcs constraint location pgsql-clone rule role=Promoted score=-INFINITY not_defined pingd
  pcs constraint location pgsql-clone rule role=Promoted score=-INFINITY pingd lte 0
  pcs constraint location app-stack rule score=-INFINITY not_defined pingd
  pcs constraint location app-stack rule score=-INFINITY pingd lte 0
  
  # Варинат 1: Один гуляющий демон
  # pcs constraint order start haproxy-svc-clone then start app-stack
  # if [[ -n ${DAEMON_SERVICE:-} ]]; then
  #   pcs constraint order start haproxy-svc-clone then start daemon-stack
  # fi

  # Варинат 2: Клон на каждой ноде
  pcs constraint order start haproxy-svc-clone then start app-stack
  if [[ -n ${DAEMON_SERVICE:-} ]]; then
    for dsvc in $DAEMON_SERVICE; do
      dsvc_clean="${dsvc%.service}"
      pcs constraint order start haproxy-svc-clone then start "daemon-${dsvc_clean}-clone"
    done
  fi

  # If any command above fails, maintenance remains enabled for operator inspection.
  pcs property set maintenance-mode=false
  echo "[УСПЕХ] Кластер успешно инициализирован и запущен! Проверьте: pcs status"
else
  echo "[УСПЕХ] Узел ${CURRENT_NODE_NAME} успешно подготовлен на уровне кластерных сервисов."
  echo "Для финальной инициализации кластера выполните на ${NODE1_NAME}:"
  echo "  sudo $0 --init-pcs"
fi