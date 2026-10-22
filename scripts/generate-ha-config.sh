#!/usr/bin/env bash
# =============================================================================
# ИНТЕРАКТИВНАЯ ГЕНЕРАЦИЯ /etc/default/ha-cluster
# =============================================================================
set -euo pipefail

ENV_FILE="/etc/default/ha-cluster"

if [[ $EUID -ne 0 ]]; then
  echo "[ОШИБКА] Запустите скрипт с правами root: sudo $0"
  exit 1
fi

echo "====================================================================="
echo " НАСТРОЙКА КЛАСТЕРНОГО ОКРУЖЕНИЯ"
echo "====================================================================="

# Получаем список сетевых интерфейсов кроме loopback и виртуальных мостов
mapfile -t NICS < <(ip -o link show | awk -F': ' '{print $2}' | grep -Ev '^(lo|virbr.*|docker.*|veth.*)$' || true)

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

    ip_addr=$(
      ip -4 -o addr show dev "$nic_name" scope global primary 2>/dev/null |
      awk '{print $4}' |
      tr '\n' ' '
    )

    ip_addr="${ip_addr% }"
    [[ -z "$ip_addr" ]] && ip_addr="нет IPv4"

    printf '  [%d] %-10s (IP: %s)\n' "$((i+1))" "$nic_name" "$ip_addr"
  done

  while true; do
    read -rp "Выберите номер интерфейса [1-${#NICS[@]}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#NICS[@]} )); then
      eval "$selected_var='${NICS[$((choice-1))]}'; break"
    fi
    echo "Некорректный выбор. Повторите ввод."
  done
}

# 1. Выбор сетевых интерфейсов
select_interface "Интерфейс для ПРЯМОГО ЛИНКА между серверами (Ring 0 / Latency-critical)" RING0_NIC
select_interface "Интерфейс для СЕТИ МАРШРУТИЗАТОРА (Ring 1 и плавающий VIP)" CLUSTER_VIP_NIC

if [[ "$RING0_NIC" == "$CLUSTER_VIP_NIC" ]]; then
  echo "[ВНИМАНИЕ] Для Ring 0 и Ring 1 выбран один и тот же интерфейс ($RING0_NIC)!"
  read -rp "Продолжить без дублирующего сетевого кольца? [y/N]: " confirm
  if [[ ! "$confirm" =~ ^[yY]$ ]]; then
    exit 1
  fi
fi

# 2. Определение параметров локального узла (строго primary адрес, без вторичных/VIP)
MY_HOSTNAME=$(hostname -s)
MY_RING0_IP=$(ip -4 -o addr show dev "$RING0_NIC" scope global primary 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)

MY_RING1_ENTRY=$(ip -4 -o addr show dev "$CLUSTER_VIP_NIC" scope global primary 2>/dev/null | awk '{print $4}' | head -n1 || true)
MY_RING1_IP="${MY_RING1_ENTRY%/*}"
DETECTED_CIDR="${MY_RING1_ENTRY#*/}"
DETECTED_CIDR="${DETECTED_CIDR:-24}"

if [[ -z "$MY_RING0_IP" || -z "$MY_RING1_IP" ]]; then
  echo "[ОШИБКА] На одном из выбранных интерфейсов отсутствует первичный IPv4 адрес!"
  exit 1
fi

echo ""
echo "Текущий хост: $MY_HOSTNAME"
echo "  Локальный IP на Ring 0 ($RING0_NIC): $MY_RING0_IP"
echo "  Локальный IP на Ring 1 ($CLUSTER_VIP_NIC): $MY_RING1_IP (CIDR: /$DETECTED_CIDR)"

# Функция валидации и проверки доступности IP
validate_ip_ping() {
  local prompt_text="$1"
  local default_ip="$2"
  local result_var="$3"
  local input_ip=""

  while true; do
    read -rp "$prompt_text [$default_ip]: " input_ip
    input_ip="${input_ip:-$default_ip}"

    if [[ "$input_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      eval "$result_var='$input_ip'"
      if ! ping -c 1 -W 1 "$input_ip" >/dev/null 2>&1; then
        echo "  [ПРЕДУПРЕЖДЕНИЕ] Хост $input_ip не отвечает на ping прямо сейчас."
      else
        echo "  [OK] Хост $input_ip доступен по сети."
      fi
      break
    else
      echo "  [ОШИБКА] Некорректный формат IPv4. Повторите ввод."
    fi
  done
}

# 3. Распределение ролей узлов
echo ""
echo "Определите роль ТЕКУЩЕГО хоста ($MY_HOSTNAME) в кластере:"
echo "  [1] Это первичный Мастер (node1)"
echo "  [2] Это резервный узел (node2)"

while true; do
  read -rp "Выберите роль [1/2]: " role_choice
  case "$role_choice" in
    1)
      NODE1_NAME="$MY_HOSTNAME"
      NODE1_RING0_IP="$MY_RING0_IP"
      NODE1_RING1_IP="$MY_RING1_IP"

      read -rp "Имя второго узла (резерв) [node2]: " NODE2_NAME
      NODE2_NAME="${NODE2_NAME:-node2}"

      GUESS_NODE2_R0="${MY_RING0_IP%.*}.2"
      GUESS_NODE2_R1="${MY_RING1_IP%.*}.12"

      validate_ip_ping "IP узла $NODE2_NAME для прямого линка ($RING0_NIC)" "$GUESS_NODE2_R0" NODE2_RING0_IP
      validate_ip_ping "IP узла $NODE2_NAME для внешней сети ($CLUSTER_VIP_NIC)" "$GUESS_NODE2_R1" NODE2_RING1_IP
      break
      ;;
    2)
      NODE2_NAME="$MY_HOSTNAME"
      NODE2_RING0_IP="$MY_RING0_IP"
      NODE2_RING1_IP="$MY_RING1_IP"

      read -rp "Имя первого узла (мастер) [node1]: " NODE1_NAME
      NODE1_NAME="${NODE1_NAME:-node1}"

      GUESS_NODE1_R0="${MY_RING0_IP%.*}.1"
      GUESS_NODE1_R1="${MY_RING1_IP%.*}.11"

      validate_ip_ping "IP узла $NODE1_NAME (Мастера) для прямого линка ($RING0_NIC)" "$GUESS_NODE1_R0" NODE1_RING0_IP
      validate_ip_ping "IP узла $NODE1_NAME (Мастера) для внешней сети ($CLUSTER_VIP_NIC)" "$GUESS_NODE1_R1" NODE1_RING1_IP
      break
      ;;
    *)
      echo "Неверный выбор. Введите 1 или 2."
      ;;
  esac
done

# 4. Шлюз и плавающий VIP
DEFAULT_GW=$(ip route show dev "$CLUSTER_VIP_NIC" 2>/dev/null | awk '/default/ {print $3}' | head -n1 || true)
if [[ -z "$DEFAULT_GW" ]]; then
  DEFAULT_GW=$(ip route show default 2>/dev/null | awk '/default/ {print $3}' | head -n1 || echo "${NODE1_RING1_IP%.*}.1")
fi

validate_ip_ping "IP маршрутизатора / шлюза сети" "$DEFAULT_GW" ROUTER_IPS

DEFAULT_VIP="${NODE1_RING1_IP%.*}.100"
read -rp "Виртуальный плавающий IP (CLUSTER_VIP) [$DEFAULT_VIP]: " CLUSTER_VIP
CLUSTER_VIP="${CLUSTER_VIP:-$DEFAULT_VIP}"

read -rp "Маска подсети VIP (CIDR) [$DETECTED_CIDR]: " CLUSTER_VIP_CIDR
CLUSTER_VIP_CIDR="${CLUSTER_VIP_CIDR:-$DETECTED_CIDR}"

# 5. Определение версии PostgreSQL
DETECTED_PG_VER=$(pg_config --version 2>/dev/null | awk '{print $2}' | cut -d. -f1 || true)
if [[ -z "$DETECTED_PG_VER" ]]; then
  DETECTED_PG_VER=$(ls -1d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -n1 | awk -F/ '{print $(NF-1)}' || echo "16")
fi
read -rp "Мажорная версия PostgreSQL [$DETECTED_PG_VER]: " PG_VERSION
PG_VERSION="${PG_VERSION:-$DETECTED_PG_VER}"

PGDATA="/var/lib/postgresql/ha-cluster"
PGBIN="/usr/lib/postgresql/${PG_VERSION}/bin"

if [[ ! -x "$PGBIN/initdb" || ! -x "$PGBIN/pg_ctl" || ! -x "$PGBIN/psql" ]]; then
  echo "[ОШИБКА] Не найдены исполняемые файлы PostgreSQL в $PGBIN"
  echo "Убедитесь, что установлен пакет postgresql-${PG_VERSION}!"
  exit 1
fi

# 6. Резервное копирование и запись конфигурации
if [[ -f "$ENV_FILE" ]]; then
  cp "$ENV_FILE" "${ENV_FILE}.bak.$(date +%s)"
fi

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
REPL_PASS="ReplSecretPass"
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
HACLUSTER_PASS="StrongClusterPass123"
EOF

chmod 600 "$ENV_FILE"

echo ""
echo "====================================================================="
echo "[УСПЕХ] Файл $ENV_FILE успешно сгенерирован!"
echo "Параметры:"
echo "  - Мастер ($NODE1_NAME): Ring 0 = $NODE1_RING0_IP | Ring 1 = $NODE1_RING1_IP"
echo "  - Резерв ($NODE2_NAME): Ring 0 = $NODE2_RING0_IP | Ring 1 = $NODE2_RING1_IP"
echo "  - Шлюз: $ROUTER_IPS | VIP: $CLUSTER_VIP/$CLUSTER_VIP_CIDR"
echo ""
echo "[ВАЖНО] Чтобы избежать расхождения параметров кластера, скопируйте"
echo "        этот файл на соседний узел прямо сейчас:"
if [[ "$MY_HOSTNAME" == "$NODE1_NAME" ]]; then
  echo "  scp $ENV_FILE ${NODE2_RING0_IP}:$ENV_FILE"
else
  echo "  scp $ENV_FILE ${NODE1_RING0_IP}:$ENV_FILE"
fi
echo "====================================================================="