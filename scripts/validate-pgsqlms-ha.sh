#!/usr/bin/env bash
# =============================================================================
# СКРИПТ ПРОВЕРКИ И ВАЛИДАЦИИ УСТАНОВКИ pgsqlms-ha
# =============================================================================
set -euo pipefail

ENV_FILE="/etc/default/ha-cluster"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

check_passed=0
check_failed=0
check_warnings=0

echo "======================================================================="
echo " ПРОВЕРКА УСТАНОВКИ И КОНФИГУРАЦИИ pgsqlms-ha"
echo "======================================================================="
echo ""

# Функции для вывода результатов
print_ok() {
    echo -e "${GREEN}[✓]${NC} $1"
    check_passed=$((check_passed + 1))
}

print_fail() {
    echo -e "${RED}[✗]${NC} $1"
    check_failed=$((check_failed + 1))
}

print_warn() {
    echo -e "${YELLOW}[!]${NC} $1"
    check_warnings=$((check_warnings + 1))
}

print_info() {
    echo -e "    ${NC}$1"
}

# ==============================================================================
# 1. Проверка базовых зависимостей
# ==============================================================================
echo "--- 1. ПРОВЕРКА БАЗОВЫХ ЗАВИСИМОСТЕЙ ---"
echo ""

# Проверка root прав
if [[ $EUID -ne 0 ]]; then
   print_fail "Скрипт должен запускаться с правами root"
   echo ""
   echo "Использование: sudo $0"
   exit 1
fi
print_ok "Права root подтверждены"

# Проверка файла конфигурации
if [[ -f "$ENV_FILE" ]]; then
    print_ok "Файл конфигурации найден: $ENV_FILE"
    # shellcheck disable=SC1090
    source "$ENV_FILE"
else
    print_fail "Файл конфигурации не найден: $ENV_FILE"
    print_info "Запустите сначала: ./generate-ha-config.sh"
    exit 1
fi

# Проверка базового PAF агента
if [[ -x "/usr/lib/ocf/resource.d/heartbeat/pgsqlms" ]]; then
    print_ok "Базовый PAF агент (pgsqlms) установлен"
else
    print_fail "Базовый PAF агент не найден: /usr/lib/ocf/resource.d/heartbeat/pgsqlms"
    print_info "Установите: apt install resource-agents-paf (Debian/Ubuntu)"
    print_info "        или: yum install resource-agents-paf (RHEL/CentOS)"
fi

# Проверка обертки pgsqlms-ha
if [[ -x "/usr/lib/ocf/resource.d/heartbeat/pgsqlms-ha" ]]; then
    print_ok "OCF-обертка pgsqlms-ha установлена"
else
    print_fail "OCF-обертка pgsqlms-ha не найдена"
    print_info "Запустите: cp pgsqlms-ha /usr/lib/ocf/resource.d/heartbeat/pgsqlms-ha"
    print_info "           chmod +x /usr/lib/ocf/resource.d/heartbeat/pgsqlms-ha"
fi

# Проверка PostgreSQL бинарников
if [[ -x "${PGBIN}/pg_ctl" && -x "${PGBIN}/psql" && -x "${PGBIN}/pg_basebackup" ]]; then
    print_ok "PostgreSQL бинарники найдены: ${PGBIN}"
else
    print_fail "PostgreSQL бинарники не найдены в ${PGBIN}"
    print_info "Проверьте переменную PGBIN в $ENV_FILE"
fi

# Проверка pg_waldump
if [[ -x "${PGBIN}/pg_waldump" ]]; then
    print_ok "Утилита pg_waldump найдена"
else
    print_fail "Утилита pg_waldump не найдена в ${PGBIN}"
    print_info "Требуется для извлечения хвоста транзакций"
fi

# Проверка pg_rewind
if [[ -x "${PGBIN}/pg_rewind" ]]; then
    print_ok "Утилита pg_rewind найдена"
else
    print_fail "Утилита pg_rewind не найдена в ${PGBIN}"
    print_info "Требуется для быстрой синхронизации"
fi

echo ""

# ==============================================================================
# 2. Проверка конфигурации PostgreSQL
# ==============================================================================
echo "--- 2. ПРОВЕРКА КОНФИГУРАЦИИ POSTGRESQL ---"
echo ""

if [[ -f "${PGDATA}/postgresql.conf" ]]; then
    print_ok "Файл postgresql.conf найден"
    
    # Проверка track_commit_timestamp
    if grep -q "^[[:space:]]*track_commit_timestamp[[:space:]]*=[[:space:]]*on" "${PGDATA}/postgresql.conf"; then
        print_ok "Параметр track_commit_timestamp = on"
    else
        print_fail "Параметр track_commit_timestamp не установлен в 'on'"
        print_info "Добавьте в postgresql.conf: track_commit_timestamp = on"
    fi
    
    # Проверка wal_log_hints
    if grep -q "^[[:space:]]*wal_log_hints[[:space:]]*=[[:space:]]*on" "${PGDATA}/postgresql.conf"; then
        print_ok "Параметр wal_log_hints = on"
    else
        print_fail "Параметр wal_log_hints не установлен в 'on'"
        print_info "Добавьте в postgresql.conf: wal_log_hints = on"
    fi
    
    # Проверка wal_level
    if grep -q "^[[:space:]]*wal_level[[:space:]]*=[[:space:]]*replica" "${PGDATA}/postgresql.conf"; then
        print_ok "Параметр wal_level = replica"
    else
        print_warn "Параметр wal_level может быть не установлен в 'replica'"
    fi
else
    print_fail "Файл postgresql.conf не найден в ${PGDATA}"
fi

# Проверка pg_hba.conf
if [[ -f "${PGDATA}/pg_hba.conf" ]]; then
    print_ok "Файл pg_hba.conf найден"
    
    if grep -q "^host.*replication.*${REPL_USER}" "${PGDATA}/pg_hba.conf"; then
        print_ok "Правило репликации для ${REPL_USER} найдено в pg_hba.conf"
    else
        print_fail "Правило репликации не найдено в pg_hba.conf"
        print_info "Добавьте адресные правила scram-sha-256 для replication и SQL-доступа к postgres."
    fi
else
    print_fail "Файл pg_hba.conf не найден в ${PGDATA}"
fi

echo ""

# ==============================================================================
# 3. Проверка каталогов и прав доступа
# ==============================================================================
echo "--- 3. ПРОВЕРКА КАТАЛОГОВ И ПРАВ ДОСТУПА ---"
echo ""

# Проверка PGDATA
if [[ -d "$PGDATA" ]]; then
    print_ok "Каталог PGDATA существует: $PGDATA"
    
    owner=$(stat -c '%U:%G' "$PGDATA" 2>/dev/null || stat -f '%Su:%Sg' "$PGDATA" 2>/dev/null)
    if [[ "$owner" == "postgres:postgres" ]]; then
        print_ok "Владелец PGDATA: postgres:postgres"
    else
        print_fail "Неверный владелец PGDATA: $owner (должен быть postgres:postgres)"
    fi
    
    perms=$(stat -c '%a' "$PGDATA" 2>/dev/null || stat -f '%A' "$PGDATA" 2>/dev/null)
    if [[ "$perms" == "700" ]]; then
        print_ok "Права доступа PGDATA: 700"
    else
        print_warn "Права доступа PGDATA: $perms (рекомендуется 700)"
    fi
else
    print_fail "Каталог PGDATA не существует: $PGDATA"
fi

# Проверка каталога состояния
STATE_DIR="/var/lib/postgresql/pcmk_state"
if [[ -d "$STATE_DIR" ]]; then
    print_ok "Каталог состояния существует: $STATE_DIR"
else
    print_warn "Каталог состояния не существует: $STATE_DIR"
    print_info "Будет создан автоматически при запуске pgsqlms-ha"
fi

# Проверка каталога резервных копий хвостов
RESCUE_DIR="/var/lib/postgresql/tail_backups"
if [[ -d "$RESCUE_DIR" ]]; then
    print_ok "Каталог резервных копий существует: $RESCUE_DIR"
else
    print_warn "Каталог резервных копий не существует: $RESCUE_DIR"
    print_info "Будет создан автоматически при запуске pgsqlms-ha"
fi

# Проверка файла .pgpass
if [[ -f "$PGPASS_FILE" ]]; then
    print_ok "Файл .pgpass найден: $PGPASS_FILE"
    
    owner=$(stat -c '%U:%G' "$PGPASS_FILE" 2>/dev/null || stat -f '%Su:%Sg' "$PGPASS_FILE" 2>/dev/null)
    if [[ "$owner" == "postgres:postgres" ]]; then
        print_ok "Владелец .pgpass: postgres:postgres"
    else
        print_fail "Неверный владелец .pgpass: $owner"
    fi
    
    perms=$(stat -c '%a' "$PGPASS_FILE" 2>/dev/null || stat -f '%A' "$PGPASS_FILE" 2>/dev/null)
    if [[ "$perms" == "600" ]]; then
        print_ok "Права доступа .pgpass: 600"
    else
        print_fail "Неверные права доступа .pgpass: $perms (должны быть 600)"
    fi
else
    print_fail "Файл .pgpass не найден: $PGPASS_FILE"
fi

echo ""

# ==============================================================================
# 4. Проверка сетевых подключений
# ==============================================================================
echo "--- 4. ПРОВЕРКА СЕТЕВЫХ ПОДКЛЮЧЕНИЙ ---"
echo ""

MY_HOSTNAME=$(hostname -s)
if [[ "$MY_HOSTNAME" == "$NODE1_NAME" ]]; then
    PEER_R0_IP="$NODE2_RING0_IP"
    PEER_R1_IP="$NODE2_RING1_IP"
    PEER_NAME="$NODE2_NAME"
else
    PEER_R0_IP="$NODE1_RING0_IP"
    PEER_R1_IP="$NODE1_RING1_IP"
    PEER_NAME="$NODE1_NAME"
fi

# Проверка доступности соседнего узла по Ring 0
if timeout 2 bash -c "echo > /dev/tcp/${PEER_R0_IP}/${DB_PORT}" 2>/dev/null; then
    print_ok "Соседний узел $PEER_NAME доступен по Ring 0 (${PEER_R0_IP}:${DB_PORT})"
else
    print_warn "Соседний узел $PEER_NAME недоступен по Ring 0 (${PEER_R0_IP}:${DB_PORT})"
    print_info "Это нормально, если узел еще не запущен"
fi

# Проверка доступности соседнего узла по Ring 1
if timeout 2 bash -c "echo > /dev/tcp/${PEER_R1_IP}/${DB_PORT}" 2>/dev/null; then
    print_ok "Соседний узел $PEER_NAME доступен по Ring 1 (${PEER_R1_IP}:${DB_PORT})"
else
    print_warn "Соседний узел $PEER_NAME недоступен по Ring 1 (${PEER_R1_IP}:${DB_PORT})"
    print_info "Это нормально, если узел еще не запущен"
fi

echo ""

# ==============================================================================
# 5. Проверка конфигурации Pacemaker
# ==============================================================================
echo "--- 5. ПРОВЕРКА КОНФИГУРАЦИИ PACEMAKER ---"
echo ""

# Проверка, запущен ли Pacemaker
if systemctl is-active --quiet pacemaker; then
    print_ok "Служба Pacemaker запущена"
    
    # Проверка наличия ресурса PostgreSQL
    if pcs resource show pgsql &>/dev/null; then
        print_ok "Ресурс PostgreSQL (pgsql) найден в кластере"
        
        # Проверка типа агента
        agent_type=$(pcs resource show pgsql | grep -oP 'ocf:heartbeat:\K[^ ]+' | head -1 || true)
        if [[ "$agent_type" == "pgsqlms-ha" ]]; then
            print_ok "Ресурс использует агент pgsqlms-ha"
        elif [[ "$agent_type" == "pgsqlms" ]]; then
            print_warn "Ресурс использует стандартный агент pgsqlms (не pgsqlms-ha)"
            print_info "Для использования автовосстановления обновите ресурс:"
            print_info "  Измените тип primitive в проверенной offline CIB с сохранением constraints."
        else
            print_warn "Ресурс использует неизвестный агент: $agent_type"
        fi
    else
        print_warn "Ресурс PostgreSQL не найден в кластере"
        print_info "Это нормально, если кластер еще не сконфигурирован"
    fi
else
    print_warn "Служба Pacemaker не запущена"
    print_info "Это нормально на этапе первоначальной настройки"
fi

# Проверка pcsd
if systemctl is-active --quiet pcsd; then
    print_ok "Служба pcsd запущена"
else
    print_warn "Служба pcsd не запущена"
    print_info "Запустите: systemctl start pcsd"
fi

echo ""

# ==============================================================================
# 6. Проверка пользователя репликации (если PostgreSQL запущен)
# ==============================================================================
echo "--- 6. ПРОВЕРКА ПОЛЬЗОВАТЕЛЯ РЕПЛИКАЦИИ ---"
echo ""

if sudo -u postgres "${PGBIN}/pg_ctl" -D "$PGDATA" status &>/dev/null; then
    print_ok "PostgreSQL запущен, проверяем пользователя репликации..."
    
    # Проверка существования пользователя
    if sudo -u postgres "${PGBIN}/psql" -h /var/run/postgresql -p "$DB_PORT" -tAc "SELECT 1 FROM pg_roles WHERE rolname='${REPL_USER}';" 2>/dev/null | grep -q 1; then
        print_ok "Пользователь репликации ${REPL_USER} существует"
        
        # Проверка прав репликации
        if sudo -u postgres "${PGBIN}/psql" -h /var/run/postgresql -p "$DB_PORT" -tAc "SELECT 1 FROM pg_roles WHERE rolname='${REPL_USER}' AND rolreplication;" 2>/dev/null | grep -q 1; then
            print_ok "Пользователь ${REPL_USER} имеет права REPLICATION"
        else
            print_fail "Пользователь ${REPL_USER} НЕ имеет права REPLICATION"
            print_info "Выполните: ALTER ROLE ${REPL_USER} WITH REPLICATION;"
        fi
        
        # Проверка прав на чтение файлов (для pg_rewind)
        if sudo -u postgres "${PGBIN}/psql" -h /var/run/postgresql -p "$DB_PORT" -tAc "SELECT 1 FROM pg_roles WHERE rolname='${REPL_USER}' AND pg_has_role('${REPL_USER}', 'pg_read_all_data', 'member');" 2>/dev/null | grep -q 1; then
            print_ok "Пользователь ${REPL_USER} имеет права pg_read_all_data"
        else
            print_fail "Пользователь ${REPL_USER} НЕ имеет права pg_read_all_data"
            print_info "Выполните: GRANT pg_read_all_data TO ${REPL_USER};"
        fi
    else
        print_fail "Пользователь репликации ${REPL_USER} не существует"
        print_info "Запустите setup-node.sh для создания пользователя"
    fi
else
    print_warn "PostgreSQL не запущен, пропускаем проверку пользователя"
fi

echo ""

# ==============================================================================
# 7. Тест базовых функций агента
# ==============================================================================
echo "--- 7. ТЕСТ БАЗОВЫХ ФУНКЦИЙ АГЕНТА ---"
echo ""

# Проверка meta-data
if /usr/lib/ocf/resource.d/heartbeat/pgsqlms-ha meta-data &>/dev/null; then
    print_ok "Агент pgsqlms-ha: команда meta-data работает"
else
    print_fail "Агент pgsqlms-ha: команда meta-data завершилась с ошибкой"
fi

# Проверка validate-all (если агент поддерживает)
export OCF_ROOT=/usr/lib/ocf
export OCF_RESKEY_bindir="${PGBIN}"
export OCF_RESKEY_pgdata="${PGDATA}"
export OCF_RESKEY_pgport="${DB_PORT}"

if /usr/lib/ocf/resource.d/heartbeat/pgsqlms-ha validate-all &>/dev/null; then
    print_ok "Агент pgsqlms-ha: валидация конфигурации успешна"
else
    print_warn "Агент pgsqlms-ha: валидация конфигурации выдала предупреждения"
fi

echo ""

# ==============================================================================
# 8. Проверка SELinux / AppArmor
# ==============================================================================
echo "--- 8. ПРОВЕРКА БЕЗОПАСНОСТИ (SELINUX / APPARMOR) ---"
echo ""

# Проверка SELinux
if command -v getenforce &>/dev/null; then
    selinux_status=$(getenforce 2>/dev/null || echo "Disabled")
    if [[ "$selinux_status" == "Disabled" || "$selinux_status" == "Permissive" ]]; then
        print_ok "SELinux: $selinux_status (не блокирует PostgreSQL)"
    else
        print_warn "SELinux: $selinux_status"
        print_info "Может блокировать pg_waldump и pg_rewind"
        print_info "Проверьте AVC-отказы и создайте минимальную адресную политику."
    fi
else
    print_info "SELinux не установлен"
fi

# Проверка AppArmor
if command -v aa-status &>/dev/null; then
    if aa-status --enabled 2>/dev/null; then
        print_warn "AppArmor включен"
        print_info "Проверьте audit-журнал и разрешения профилей PostgreSQL; не отключайте защиту массово."
    else
        print_ok "AppArmor отключен (не блокирует PostgreSQL)"
    fi
else
    print_info "AppArmor не установлен"
fi

echo ""

# ==============================================================================
# ИТОГОВАЯ СТАТИСТИКА
# ==============================================================================
echo "======================================================================="
echo " ИТОГОВАЯ СТАТИСТИКА"
echo "======================================================================="
echo ""
echo -e "Успешно:         ${GREEN}${check_passed}${NC}"
echo -e "Предупреждения:  ${YELLOW}${check_warnings}${NC}"
echo -e "Ошибки:          ${RED}${check_failed}${NC}"
echo ""

if [[ $check_failed -eq 0 ]]; then
    echo -e "${GREEN}✓ Статические проверки пройдены; необходимы интеграционные испытания восстановления${NC}"
    echo ""
    echo "Следующие шаги:"
    echo "  1. Если Pacemaker еще не настроен: ./bootstrap-ha.sh"
    echo "  2. Проверка кластера: pcs status"
    echo "  3. Мониторинг логов: tail -f /var/lib/postgresql/tail_backups/tail_recovery.log"
    exit 0
elif [[ $check_failed -le 2 ]]; then
    echo -e "${YELLOW}! Обнаружены ошибки конфигурации${NC}"
    echo ""
    echo "Устраните ошибки перед включением автоматического восстановления."
    exit 1
else
    echo -e "${RED}✗ Обнаружены критические проблемы${NC}"
    echo ""
    echo "Устраните ошибки, указанные выше, перед запуском кластера."
    exit 2
fi
