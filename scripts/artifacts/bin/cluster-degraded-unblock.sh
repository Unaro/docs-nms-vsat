#!/bin/bash
set -euo pipefail

export LC_ALL=C
source /etc/default/ha-cluster
BOOT_MODE_FILE=${BOOT_MODE_FILE:-/run/cluster_boot_mode}
if [[ -f $BOOT_MODE_FILE ]]; then source "$BOOT_MODE_FILE"; fi

log_msg() { timeout 2 logger -t cluster-watchdog "$1" || true; }

# Корректное завершение при остановке службы через systemctl
trap 'log_msg "Служба остановлена извне. Прерывание ожидания."; exit 0' SIGTERM SIGINT

is_cluster_quorate() {
  # Проверка наличия кворума 
  corosync-quorumtool -s 2>/dev/null | grep -q "Quorate:.*Yes"
}

unblock_quorum_safely() {
  log_msg "Выполняю отмену wait_for_all для кворума..."

  # 1. Штатный метод через corosync-quorumtool
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

MY_HOSTNAME=$(hostname -s)
if [[ $MY_HOSTNAME == "$NODE1_NAME" ]]; then
  MY_NODE_NAME="$NODE1_NAME"
  PEER_RING0_IP="$NODE2_RING0_IP"
  PEER_RING1_IP="$NODE2_RING1_IP"
  EXTRA_DELAY=0
elif [[ $MY_HOSTNAME == "$NODE2_NAME" ]]; then
  MY_NODE_NAME="$NODE2_NAME"
  PEER_RING0_IP="$NODE1_RING0_IP"
  PEER_RING1_IP="$NODE1_RING1_IP"
  EXTRA_DELAY="${NODE2_ASYMMETRIC_DELAY_SEC:-120}"
else
  log_msg 'Неизвестный узел кластера; изменение кворума запрещено'; exit 1
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
  log_msg "Роль не MASTER/SLAVE (${LAST_ROLE:-UNKNOWN}); автоматическая разблокировка запрещена."
  exit 1
fi
