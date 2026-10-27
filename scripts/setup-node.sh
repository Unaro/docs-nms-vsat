#!/usr/bin/env bash
# =============================================================================
# ПОДГОТОВКА ИНФРАСТРУКТУРЫ УЗЛА КЛАСТЕРА (ТОЛЬКО СИСТЕМА, PGSQL, HAPROXY)
# Управление ролью: явный флаг --master или --standby
# =============================================================================
set -euo pipefail

ENV_FILE="/etc/default/ha-cluster"
LOG_FILE="/var/log/setup-node.log"


# 1. Валидация аргументов запуска
NODE_ROLE=""
case "${1:-}" in
  --master)
    NODE_ROLE="MASTER"
    ;;
  --standby)
    NODE_ROLE="STANDBY"
    ;;
  --stop-master)
    NODE_ROLE="STOP_MASTER"
    ;;
  *)
    echo "[ОШИБКА] Укажите роль узла явно:"
    echo "  sudo $0 --master       (node1, инициализация и временный запуск master)"
    echo "  sudo $0 --standby      (node2, pg_basebackup с node1)"
    echo "  sudo $0 --stop-master  (node1, остановить временный master после standby)"
    exit 1
    ;;
esac

if [[ $EUID -ne 0 ]]; then
  echo "[ОШИБКА] Скрипт должен запускаться с правами root!"
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "[ОШИБКА] Файл $ENV_FILE не найден! Сначала выполните configure-ha.sh."
  exit 1
fi
exec > >(tee -a "$LOG_FILE") 2>&1
source "$ENV_FILE"
for value in "$REPL_USER" "$REPL_PASS" "$HACLUSTER_PASS"; do
  [[ $value != *$'\n'* && $value != *$'\r'* ]] || { echo 'Переводы строк в учётных данных не поддерживаются' >&2; exit 1; }
done
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/artifacts.sh"
[[ $PGDATA == /* && $PGDATA != / && ! -L $PGDATA ]] || { echo 'Небезопасный путь PGDATA' >&2; exit 1; }
expected_node=$NODE1_NAME
[[ $NODE_ROLE == STANDBY ]] && expected_node=$NODE2_NAME
[[ $(hostname -s) == "$expected_node" ]] || { echo "Эту роль необходимо настраивать на узле $expected_node" >&2; exit 1; }
if [[ $NODE_ROLE != STOP_MASTER && -d $PGDATA && -n $(find "$PGDATA" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
  echo 'Первоначальная настройка требует пустого PGDATA; для существующих данных используйте восстановление кластера.' >&2
  exit 1
fi
if systemctl is-active --quiet pacemaker; then
  echo '[ОШИБКА] Подготовка узла запрещена при работающем Pacemaker.' >&2
  exit 1
fi

if [[ "$NODE_ROLE" == "STOP_MASTER" ]]; then
  echo "====================================================================="
  echo " Остановка временного master на $(hostname) и подготовка для Pacemaker"
  echo "====================================================================="

  sudo -u postgres "$PGBIN/pg_ctl" \
    -D "$PGDATA" \
    stop -m fast -w -t 60 2>/dev/null || true

  if sudo -u postgres "$PGBIN/pg_ctl" -D "$PGDATA" status >/dev/null 2>&1; then
    echo "[WARN] PostgreSQL всё ещё запущен, применяю immediate stop..."
    sudo -u postgres "$PGBIN/pg_ctl" \
      -D "$PGDATA" \
      stop -m immediate -w -t 30 2>/dev/null || true
  fi

  if pgrep -u postgres -f "postgres -D $PGDATA" >/dev/null 2>&1; then
    echo "[ОШИБКА] Не удалось остановить временный master."
    exit 1
  fi

  touch "$PGDATA/standby.signal"
  chown postgres:postgres "$PGDATA/standby.signal"

  echo "[УСПЕХ] Временный master остановлен и переведен в готовность для Pacemaker."
  exit 0
fi

echo "====================================================================="
echo " Запуск настройки узла $(hostname) в роли: $NODE_ROLE"
echo "====================================================================="

# 2. Очистка и фиксация /etc/hosts
sed -i '/127.0.1.1/d' /etc/hosts
sed -i '/# --- HA-CLUSTER-HOSTS-BEGIN ---/,/# --- HA-CLUSTER-HOSTS-END ---/d' /etc/hosts
render_artifact hosts.block.tpl /run/ha-hosts.block
cat /run/ha-hosts.block >> /etc/hosts
rm -f /run/ha-hosts.block

# 3. Тюнинг ядра для отказоустойчивости
install_artifact sysctl/99-ha-cluster.conf /etc/sysctl.d/99-ha-cluster.conf
sysctl --system >/dev/null 2>&1 || true

# 4. Файл паролей .pgpass и пароль для pcsd
mkdir -p "$(dirname "$PGPASS_FILE")"
pgpass_user=${REPL_USER//\\/\\\\}; pgpass_user=${pgpass_user//:/\\:}
pgpass_password=${REPL_PASS//\\/\\\\}; pgpass_password=${pgpass_password//:/\\:}
printf '*:%s:*:%s:%s\n' "$DB_PORT" "$pgpass_user" "$pgpass_password" > "$PGPASS_FILE"
chown postgres:postgres "$PGPASS_FILE" 2>/dev/null || true
chmod 0600 "$PGPASS_FILE"

echo "hacluster:${HACLUSTER_PASS}" | chpasswd 2>/dev/null || true

# 5. Скрипт проверки роли для балансировщика
install_artifact bin/db-role-check.sh /usr/local/bin/db-role-check.sh 0755
chmod +x /usr/local/bin/db-role-check.sh

# 6. Сокет db-role-check (порт DB_CHECK_PORT)
render_artifact systemd/db-role-check.socket.tpl /etc/systemd/system/db-role-check.socket

install_artifact systemd/db-role-check@.service /etc/systemd/system/db-role-check@.service

# 7. Конфигурация HAProxy
render_artifact haproxy/haproxy.cfg.tpl /etc/haproxy/haproxy.cfg
haproxy -c -f /etc/haproxy/haproxy.cfg

# Функция записи директив PostgreSQL
configure_postgres_files() {
  if [[ ! -f "${PGDATA}/postgresql.conf" || ! -f "${PGDATA}/pg_hba.conf" ]]; then
    echo "[ОШИБКА] В PGDATA=${PGDATA} отсутствуют postgresql.conf или pg_hba.conf."
    exit 1
  fi

  # Удаляем старые блоки параметров
  sed -i '/# --- HA-CLUSTER-PG-BEGIN ---/,/# --- HA-CLUSTER-PG-END ---/d' "${PGDATA}/postgresql.conf"
  sed -i '/unix_socket_directories/d' "${PGDATA}/postgresql.conf"

  render_artifact postgresql/ha.conf.tpl "$PGDATA/.ha.conf.block"
  cat "$PGDATA/.ha.conf.block" >> "$PGDATA/postgresql.conf"
  rm -f "$PGDATA/.ha.conf.block"

  # Полная чистая перезапись pg_hba.conf
  render_artifact postgresql/pg_hba.conf.tpl "$PGDATA/pg_hba.conf"
}

# Гарантируем права на каталог сокетов Unix
mkdir -p /var/run/postgresql
chown -R postgres:postgres /var/run/postgresql
chmod 2775 /var/run/postgresql

# Останавливаем системные демоны перед началом работ
systemctl stop postgresql "postgresql@${PG_VERSION}-main" 2>/dev/null || true

# 8. Ветвление подготовки базы по переданному флагу
if [[ "$NODE_ROLE" == "MASTER" ]]; then
  echo "--- [MASTER] Инициализация каталога PGDATA и создание репликационной роли ---"

  if [[ ! -f "$PGDATA/PG_VERSION" || ! -f "$PGDATA/postgresql.conf" || ! -f "$PGDATA/pg_hba.conf" ]]; then
    echo "[INFO] Инициализирую PostgreSQL в каталоге: $PGDATA"
    mkdir -p "$(dirname "$PGDATA")"
    mkdir -p "$PGDATA"
    chown postgres:postgres "$PGDATA"
    chmod 0700 "$PGDATA"

    sudo -u postgres "$PGBIN/initdb" \
      -D "$PGDATA" \
      -k \
      -E UTF8 \
      --locale=C
  else
    echo "[INFO] Каталог $PGDATA уже инициализирован, обновляю параметры HA..."
  fi

  configure_postgres_files

  touch "$PGDATA/postgresql.auto.conf"
  sed -i -E '/^(primary_conninfo|primary_slot_name|recovery_target_timeline)/d' "$PGDATA/postgresql.auto.conf" 2>/dev/null || true
  render_artifact postgresql/node1.auto.conf.tpl "$PGDATA/.auto.conf.block"
  cat "$PGDATA/.auto.conf.block" >> "$PGDATA/postgresql.auto.conf"
  rm -f "$PGDATA/.auto.conf.block"
  chown postgres:postgres "$PGDATA/postgresql.auto.conf"
  chmod 0600 "$PGDATA/postgresql.auto.conf"

  echo "[INFO] Запускаю временный master для создания репликации и slots..."
  if ! sudo -u postgres "$PGBIN/pg_ctl" \
    -D "$PGDATA" \
    -l "$PGDATA/setup-master.log" \
    -o "-p $DB_PORT -c listen_addresses='*'" \
    start -w -t 60; then
    echo "=== ОШИБКА ЗАПУСКА POSTGRESQL ==="
    cat "$PGDATA/setup-master.log" 2>/dev/null || true
    exit 1
  fi

  sudo -u postgres "$PGBIN/psql" -X -h /var/run/postgresql -p "$DB_PORT" -d postgres \
    -v ON_ERROR_STOP=1 -v repl_user="$REPL_USER" -v repl_pass="$REPL_PASS" \
    -v slot1="$REPL_SLOT_NODE1" -v slot2="$REPL_SLOT_NODE2" \
    < "$HA_ARTIFACTS_DIR/postgresql/provision.sql"

  echo "[INFO] Временный master запущен и слушает порт $DB_PORT."
  echo "[INFO] Теперь на node2 выполните:"
  echo "       sudo $0 --standby"
  echo "[INFO] После успешного standby вернитесь на node1 и выполните:"
  echo "       sudo $0 --stop-master"

elif [[ "$NODE_ROLE" == "STANDBY" ]]; then
  echo "--- [STANDBY] Клонирование базы данных с мастера ($NODE1_RING0_IP) ---"

  TARGET_MASTER_IP="$NODE1_RING0_IP"

  echo "Проверка доступности порта $DB_PORT на мастере $TARGET_MASTER_IP..."
  MASTER_READY=0
  for i in {1..30}; do
    if timeout 2 bash -c "</dev/tcp/${TARGET_MASTER_IP}/${DB_PORT}" 2>/dev/null; then
      MASTER_READY=1
      break
    fi
    echo "Попытка $i/30: порт $DB_PORT на $TARGET_MASTER_IP ещё недоступен, ждем..."
    sleep 2
  done

  if [[ "$MASTER_READY" -ne 1 ]]; then
    echo "[ОШИБКА] Master $TARGET_MASTER_IP:$DB_PORT недоступен."
    echo "Сначала запустите на node1: sudo $0 --master"
    exit 1
  fi

  mkdir -p "$(dirname "$PGDATA")"
  mkdir -p "$PGDATA"
  chown postgres:postgres "$PGDATA"
  chmod 0700 "$PGDATA"

  timeout --kill-after=5s "${BASEBACKUP_TIMEOUT_SEC:-540}s" sudo -u postgres env PGPASSFILE="$PGPASS_FILE" "$PGBIN/pg_basebackup" \
    -h "$TARGET_MASTER_IP" \
    -p "$DB_PORT" \
    -U "$REPL_USER" \
    -D "$PGDATA" \
    -Fp -Xs -P -R \
    -S "$REPL_SLOT_NODE2"

  if [[ ! -f "$PGDATA/PG_VERSION" ]]; then
    echo "[ОШИБКА] После pg_basebackup отсутствует $PGDATA/PG_VERSION"
    exit 1
  fi

  if [[ ! -f "$PGDATA/standby.signal" ]]; then
    touch "$PGDATA/standby.signal"
  fi

  # Фиксируем подключение по двум кольцам, слот и application_name для Pacemaker/pgsqlms
  touch "$PGDATA/postgresql.auto.conf"
  sed -i -E '/^(primary_conninfo|primary_slot_name|recovery_target_timeline)/d' "$PGDATA/postgresql.auto.conf" 2>/dev/null || true
  render_artifact postgresql/node2.auto.conf.tpl "$PGDATA/.auto.conf.block"
  cat "$PGDATA/.auto.conf.block" >> "$PGDATA/postgresql.auto.conf"
  rm -f "$PGDATA/.auto.conf.block"

  configure_postgres_files

  chown -R postgres:postgres "$PGDATA"
  chmod 0700 "$PGDATA"

  echo "[УСПЕХ] Standby-каталог подготовлен на $(hostname)."
  echo "[INFO] Выполните на node1: sudo $0 --stop-master"
fi

# 9. Установка OCF-обертки pgsqlms-ha для автоматического восстановления
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OCF_WRAPPER_SRC="${SCRIPT_DIR}/pgsqlms-ha"
OCF_WRAPPER_DST="/usr/lib/ocf/resource.d/heartbeat/pgsqlms-ha"

if [[ -f "$OCF_WRAPPER_SRC" ]]; then
  echo "[INFO] Устанавливаем OCF-агент pgsqlms-ha для автоматического восстановления БД..."
  install -D -m 0755 -o root -g root "$OCF_WRAPPER_SRC" "$OCF_WRAPPER_DST"
  
  # Проверка базового PAF-агента
  if [[ ! -x "/usr/lib/ocf/resource.d/heartbeat/pgsqlms" ]]; then
    echo "[ОШИБКА] Базовый агент PAF (pgsqlms) не найден!"
    echo "                 Установите пакет: apt install resource-agents-paf (Debian/Ubuntu)"
    echo "                                   или: yum install resource-agents-paf (RHEL/CentOS)"
    exit 1
  else
    echo "[УСПЕХ] Агент pgsqlms-ha установлен: $OCF_WRAPPER_DST"
  fi
else
  echo "[ПРЕДУПРЕЖДЕНИЕ] Файл $OCF_WRAPPER_SRC не найден. OCF-агент не установлен."
  echo "                 Разместите скрипт pgsqlms-ha в директории скриптов."
  exit 1
fi

# SELinux/AppArmor не отключаем: при отказах настраиваются адресные политики.

# 10. Фиксация служб в systemd
systemctl daemon-reload

# Отключаем автозапуск системных сервисов (управление передается Pacemaker)
for svc in postgresql "postgresql@${PG_VERSION}-main" haproxy; do
  systemctl disable "$svc" 2>/dev/null || true
  if [[ "$NODE_ROLE" != "MASTER" ]]; then
    systemctl stop "$svc" 2>/dev/null || true
  fi
done

systemctl enable db-role-check.socket pcsd.service 2>/dev/null || true
systemctl restart db-role-check.socket pcsd.service 2>/dev/null || true

echo "====================================================================="
echo "[УСПЕХ] Узел $(hostname) успешно настроен в роли $NODE_ROLE!"
echo "====================================================================="