#!/usr/bin/env bash
# =============================================================================
# ОЧИСТКА ОКРУЖЕНИЯ УЗЛА ДЛЯ ПОВТОРНОГО ЗАПУСКА setup-node.sh
# =============================================================================
set -euo pipefail

ENV_FILE="/etc/default/ha-cluster"

if [[ $EUID -ne 0 ]]; then
  echo "[ОШИБКА] Запустите скрипт с правами root: sudo $0"
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "[ОШИБКА] Файл конфигурации $ENV_FILE не найден!"
  exit 1
fi

source "$ENV_FILE"

PGDATA="${PGDATA:-/var/lib/postgresql/ha-cluster}"
PGBIN="${PGBIN:-/usr/lib/postgresql/${PG_VERSION:-16}/bin}"
BOOT_MODE_FILE="${BOOT_MODE_FILE:-/run/cluster_boot_mode}"
APP_SVC="${APP_SERVICE:-my-app}"
APP_SVC="${APP_SVC%.service}"
DAEMON_SVC="${DAEMON_SERVICE:-my-daemon}"
DAEMON_SVC="${DAEMON_SVC%.service}"

echo "====================================================================="
echo " Очистка узла $(hostname) перед повторным запуском setup-node"
echo " Каталог данных: $PGDATA"
echo "====================================================================="

# -----------------------------------------------------------------------------
# 1. ОСТАНОВКА КЛАСТЕРНОГО СТЕКА И СЕРВИСОВ
# -----------------------------------------------------------------------------
echo "[1/6] Остановка Pacemaker, Corosync, таймеров и балансировщика..."

# Останавливаем кластерную оркестрацию, чтобы она не пыталась перезапустить базу
systemctl stop pacemaker.service corosync.service 2>/dev/null || true
systemctl stop cluster-degraded-unblock.timer cluster-degraded-unblock.service 2>/dev/null || true
systemctl stop cluster-boot-analyzer.service 2>/dev/null || true

# Останавливаем вспомогательные службы и сокет проверки роли
systemctl stop haproxy.service 2>/dev/null || true
systemctl stop db-role-check.socket db-role-check@*.service 2>/dev/null || true

# Останавливаем пользовательские тестовые приложения
systemctl stop "${APP_SVC}.service" "${DAEMON_SVC}.service" 2>/dev/null || true
systemctl stop "app-${APP_SVC}.service" "daemon-${DAEMON_SVC}.service" 2>/dev/null || true

# -----------------------------------------------------------------------------
# 2. ОСТАНОВКА И ПРИНУДИТЕЛЬНОЕ ЗАВЕРШЕНИЕ СУБД
# -----------------------------------------------------------------------------
echo "[2/6] Остановка PostgreSQL..."

# Попытка штатной остановки через systemd
systemctl stop postgresql "postgresql@${PG_VERSION:-16}-main" 2>/dev/null || true

# Попытка быстрой остановки через pg_ctl
if [[ -x "$PGBIN/pg_ctl" && -d "$PGDATA" ]]; then
  sudo -u postgres "$PGBIN/pg_ctl" -D "$PGDATA" stop -m fast -w -t 15 2>/dev/null || \
  sudo -u postgres "$PGBIN/pg_ctl" -D "$PGDATA" stop -m immediate -w -t 10 2>/dev/null || true
fi

# Принудительное завершение любых оставшихся процессов PostgreSQL и тестов
echo "[INFO] Принудительная зачистка зависших процессов..."
pkill -9 -u postgres -f "postgres.*${PGDATA}" 2>/dev/null || true
pkill -9 -f "my-daemon.py" 2>/dev/null || true
pkill -9 -f "my-app.py" 2>/dev/null || true
sleep 1

# -----------------------------------------------------------------------------
# 3. УДАЛЕНИЕ СОКЕТОВ, БЛОКИРОВОК И RUNTIME-ФАЙЛОВ
# -----------------------------------------------------------------------------
echo "[3/6] Удаление временных файлов, IPC-сокетов и логов Split-Brain..."

rm -f /var/run/postgresql/.s.PGSQL.* /tmp/.s.PGSQL.*
rm -f "$BOOT_MODE_FILE"
rm -f /var/log/postgresql_splitbrain.log
rm -f /var/log/setup-node.log

# -----------------------------------------------------------------------------
# 4. ПОЛНАЯ ЗАЧИСТКА ДИРЕКТОРИИ ДАННЫХ (PGDATA)
# -----------------------------------------------------------------------------
echo "[4/6] Очистка каталога $PGDATA и временных инстансов basebackup..."

# Удаляем временные каталоги восстановления, если они остались от analyzer
rm -rf "${PGDATA}.incoming."* "${PGDATA}.old."* 2>/dev/null || true

# Удаляем каталог данных
if [[ -d "$PGDATA" ]]; then
  rm -rf "${PGDATA:?}"/*
  rm -rf "$PGDATA"
fi

# -----------------------------------------------------------------------------
# 5. ОЧИСТКА СОСТОЯНИЯ PACEMAKER / COROSYNC (CIB И КЭШ)
# -----------------------------------------------------------------------------
echo "[5/6] Сброс локального состояния CIB Pacemaker..."

rm -rf /var/lib/pacemaker/cib/*
rm -rf /var/lib/pacemaker/pengine/*
rm -rf /var/lib/corosync/*

# -----------------------------------------------------------------------------
# 6. ВОССТАНОВЛЕНИЕ БАЗОВЫХ ПРАВ И ДИРЕКТОРИЙ
# -----------------------------------------------------------------------------
echo "[6/6] Подготовка чистых системных директорий..."

mkdir -p /var/run/postgresql
chown -R postgres:postgres /var/run/postgresql
chmod 2775 /var/run/postgresql

mkdir -p "$(dirname "$PGDATA")"
chown postgres:postgres "$(dirname "$PGDATA")"

echo "====================================================================="
echo "[УСПЕХ] Узел полностью очищен и готов к запуску setup-node.sh."
echo "Следующие шаги:"
echo "  - На Node 1:  sudo ./setup-node.sh --master"
echo "  - На Node 2:  sudo ./setup-node.sh --standby"
echo "  - На Node 1:  sudo ./setup-node.sh --stop-master"
echo "====================================================================="