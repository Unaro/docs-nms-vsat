#!/usr/bin/env bash
# =============================================================================
# ИНТЕРАКТИВНАЯ ГЕНЕРАЦИЯ /etc/default/ha-cluster С ВЫБОРОМ ИНТЕРФЕЙСОВ
# =============================================================================
set -euo pipefail

ENV_FILE="/etc/default/ha-cluster"

if [[ $EUID -ne 0 ]]; then
  echo "[ОШИБКА] Запустите скрипт с правами root: sudo $0"
  exit 1
fi

echo "====================================================================="
echo " НАСТРОЙКА КЛАСТЕРНОГО ОКРУЖЕНИЯ
echo "====================================================================="

# Получаем список сетевых интерфейсов кроме loopback
mapfile -t NICS < <(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$' || true)

if [[ ${#NICS[@]} -lt 2 ]]; then
  echo "[ОШИБКА] В системе найдено менее двух сетевых интерфейсов. Кластер требует минимум 2 NIC!"
  exit 1
fi

select_interface() {
  local prompt_title="$1"
  local selected_var="$2"
  
  echo ""
  echo "--- $prompt_title ---"
  for i in "${!NICS[@]}"; do
    local nic_name="${NICS[$i]}"
    local ip_addr
    ip_addr=$(ip -4 -o addr show dev "$nic_name" 2>/dev/null | awk '{print $4}' | tr '\n' ' ' || echo "нет IPv4")
    printf "  [%d] %-10s (IP: %s)\n" "$((i+1))" "$nic_name" "${ip_addr:-нет IPv4}"
  done

  while true; do
    read -rp "Выберите номер интерфейса [1-${#NICS[@]}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#NICS[@]} )); then
      eval "$selected_var='${NICS[$((choice-1))]}'"
      break
    fi
    echo "Некорректный выбор. Повторите ввод."
  done
}

# 1. Интерактивный выбор интерфейсов
select_interface "Интерфейс для ПРЯМОГО ЛИНКА между серверами (Ring 0 / Latency-critical)" RING0_NIC
select_interface "Интерфейс для СЕТИ МАРШРУТИЗАТОРА (Ring 1 и плавающий VIP)" CLUSTER_VIP_NIC

if [[ "$RING0_NIC" == "$CLUSTER_VIP_NIC" ]]; then
  echo "[ВНИМАНИЕ] Для Ring 0 и Ring 1 выбран один и тот же интерфейс ($RING0_NIC)!"
  read -rp "Продолжить без дублирующего сетевого кольца? [y/N]: " confirm
  if [[ ! "$confirm" =~ ^[yY]$ ]]; then
    exit 1
  fi
fi

# 2. Определение параметров текущего узла
MY_HOSTNAME=$(hostname -s)
MY_RING0_IP=$(ip -4 -o addr show dev "$RING0_NIC" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)
MY_RING1_IP=$(ip -4 -o addr show dev "$CLUSTER_VIP_NIC" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)

if [[ -z "$MY_RING0_IP" || -z "$MY_RING1_IP" ]]; then
  echo "[ОШИБКА] На одном из выбранных интерфейсов отсутствует настроенный IPv4 адрес!"
  exit 1
fi

echo ""
echo "Текущий хост: $MY_HOSTNAME"
echo "  Локальный IP на $RING0_NIC: $MY_RING0_IP"
echo "  Локальный IP на $CLUSTER_VIP_NIC: $MY_RING1_IP"

# 3. Запрос сведений о нодах и соседе
read -rp "Имя первой ноды (node1) [$MY_HOSTNAME]: " NODE1_NAME
NODE1_NAME="${NODE1_NAME:-$MY_HOSTNAME}"

DEFAULT_NODE2_NAME="node2"
[[ "$NODE1_NAME" == "node2" ]] && DEFAULT_NODE2_NAME="node1"
read -rp "Имя второй ноды (node2) [$DEFAULT_NODE2_NAME]: " NODE2_NAME
NODE2_NAME="${NODE2_NAME:-$DEFAULT_NODE2_NAME}"

if [[ "$MY_HOSTNAME" == "$NODE1_NAME" ]]; then
  NODE1_RING0_IP="$MY_RING0_IP"
  NODE1_RING1_IP="$MY_RING1_IP"
  
  # Пытаемся предположить IP соседа
  GUESS_PEER_R0="${MY_RING0_IP%.*}.2"
  GUESS_PEER_R1="${MY_RING1_IP%.*}.12"

  read -rp "IP узла $NODE2_NAME для прямого линка ($RING0_NIC) [$GUESS_PEER_R0]: " NODE2_RING0_IP
  NODE2_RING0_IP="${NODE2_RING0_IP:-$GUESS_PEER_R0}"

  read -rp "IP узла $NODE2_NAME для внешней сети ($CLUSTER_VIP_NIC) [$GUESS_PEER_R1]: " NODE2_RING1_IP
  NODE2_RING1_IP="${NODE2_RING1_IP:-$GUESS_PEER_R1}"
else
  NODE2_RING0_IP="$MY_RING0_IP"
  NODE2_RING1_IP="$MY_RING1_IP"

  GUESS_PEER_R0="${MY_RING0_IP%.*}.1"
  GUESS_PEER_R1="${MY_RING1_IP%.*}.11"

  read -rp "IP узла $NODE1_NAME для прямого линка ($RING0_NIC) [$GUESS_PEER_R0]: " NODE1_RING0_IP
  NODE1_RING0_IP="${NODE1_RING0_IP:-$GUESS_PEER_R0}"

  read -rp "IP узла $NODE1_NAME для внешней сети ($CLUSTER_VIP_NIC) [$GUESS_PEER_R1]: " NODE1_RING1_IP
  NODE1_RING1_IP="${NODE1_RING1_IP:-$GUESS_PEER_R1}"
fi

# 4. Шлюз и VIP
DEFAULT_GW=$(ip route show default 2>/dev/null | awk '/default/ {print $3}' | head -n1 || echo "${MY_RING1_IP%.*}.1")
read -rp "IP маршрутизатора (арбитра сети) [$DEFAULT_GW]: " ROUTER_IPS
ROUTER_IPS="${ROUTER_IPS:-$DEFAULT_GW}"

DEFAULT_VIP="${MY_RING1_IP%.*}.100"
read -rp "Виртуальный плавающий IP (CLUSTER_VIP) [$DEFAULT_VIP]: " CLUSTER_VIP
CLUSTER_VIP="${CLUSTER_VIP:-$DEFAULT_VIP}"

read -rp "Маска подсети VIP (CIDR) [24]: " CLUSTER_VIP_CIDR
CLUSTER_VIP_CIDR="${CLUSTER_VIP_CIDR:-24}"

# 5. Определение установленной версии PostgreSQL
DETECTED_PG_VER=$(pg_config --version 2>/dev/null | awk '{print $2}' | cut -d. -f1 || true)
if [[ -z "$DETECTED_PG_VER" ]]; then
  DETECTED_PG_VER=$(ls -1d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -n1 | awk -F/ '{print $(NF-1)}' || echo "16")
fi
read -rp "Мажорная версия PostgreSQL [$DETECTED_PG_VER]: " PG_VERSION
PG_VERSION="${PG_VERSION:-$DETECTED_PG_VER}"

PGDATA="/var/lib/postgresql/${PG_VERSION}/main"
PGBIN="/usr/lib/postgresql/${PG_VERSION}/bin"

# 6. Запись в целевой конфигурационный файл
cat << EOF > "$ENV_FILE"
# Конфигурация кластера сформирована через интерактивный мастер $(date '+%Y-%m-%d %H:%M:%S')
NODE1_NAME="${NODE1_NAME}"
NODE2_NAME="${NODE2_NAME}"
RING0_NIC="${RING0_NIC}"
CLUSTER_VIP_NIC="${CLUSTER_VIP_NIC}"

NODE1_RING0_IP="${NODE1_RING0_IP}"
NODE2_RING0_IP="${NODE2_RING0_IP}"
NODE1_RING1_IP="${NODE1_RING1_IP}"
NODE2_RING1_IP="${NODE2_RING1_IP}"

ROUTER_IPS="${ROUTER_IPS}"
CLUSTER_VIP="${CLUSTER_VIP}"
CLUSTER_VIP_CIDR="${CLUSTER_VIP_CIDR}"

PG_VERSION="${PG_VERSION}"
PGDATA="${PGDATA}"
PGBIN="${PGBIN}"
DB_PORT="5432"
DB_CHECK_PORT="9200"
HAPROXY_DB_BIND_PORT="5000"
REPL_USER="repl_user"
REPL_PASS="ReplSecretPass!"
PGPASS_FILE="/var/lib/postgresql/.pgpass"
REPL_SLOT_NODE1="slot_node1"
REPL_SLOT_NODE2="slot_node2"
MAX_SLOT_WAL_KEEP_SIZE="5GB"
WAL_KEEP_SIZE="512MB"
MAX_CONNECTIONS="100"

APP_SERVICE="my-app"
DAEMON_SERVICE="my-daemon"
APP_MEMORY_MAX="75%"
APP_CPU_QUOTA="80%"

COROSYNC_TOKEN_MS="3000"
MIN_FREE_DISK_PCT="5"
MIN_FREE_CIB_MB="500"
COLD_START_TIMEOUT_SEC="180"
CRASH_TIMEOUT_SEC="900"
NODE2_ASYMMETRIC_DELAY_SEC="120"
FAILURE_TIMEOUT_SEC="900s"

BOOT_MODE_FILE="/run/cluster_boot_mode"
HACLUSTER_PASS="StrongClusterPass123!"
EOF

chmod 600 "$ENV_FILE"

echo ""
echo "[УСПЕХ] Файл $ENV_FILE успешно сгенерирован!"
echo "Выбранные интерфейсы и роли:"
echo "  - Ring 0 (Прямой линк): $RING0_NIC ($NODE1_NAME: $NODE1_RING0_IP <-> $NODE2_NAME: $NODE2_RING0_IP)"
echo "  - Ring 1 / VIP:         $CLUSTER_VIP_NIC (Шлюз: $ROUTER_IPS, VIP: $CLUSTER_VIP/$CLUSTER_VIP_CIDR)"