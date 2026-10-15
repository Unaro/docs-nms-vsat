# TC-APP-01: Авария PostgreSQL — режим Read-Only и порог XID Wraparound

> **Примечание**: Данный тест-кейс относится к **Приложению: Специальные испытания на надежность (Day-2 Reliability Tests)** и проверяет реакцию на редкие, глубинные отказы движка СУБД.

## 1. Паспорт тест-кейса
- **Идентификатор**: `TC-APP-01`
- **MMD-диаграмма**: [`mmd/ОтказPostgresReadOnly.mmd`](../mmd/ОтказPostgresReadOnly.mmd)
- **Цель**: Проверить реакцию кластера и балансировщика HAProxy на критический переход Master СУБД в состояние Read-Only (вследствие исчерпания транзакций XID Wraparound или ручной блокировки), валидацию через `db-role-check.sh` и перевод трафика на Standby.
- **Объекты проверки**:
  - Скрипт `/usr/local/bin/db-role-check.sh` (`current_setting('transaction_read_only') == 'off'`).
  - Возврат HTTP 503 при работающем процессе `postgres`.
  - Реакция HAProxy на статус 503 (`inter 2s fall 2 on-marked-down shutdown-sessions`).

---

## 2. Шаги выполнения и ожидаемые результаты

### Шаг 1. Имитация блокировки записи (Read-Only)
**Команда на `node1`:**
```bash
sudo -u postgres psql -c "ALTER SYSTEM SET default_transaction_read_only = 'on';"
sudo -u postgres psql -c "SELECT pg_reload_conf();"
```

### Шаг 2. Проверка отклика db-role-check.sh
**Команда на `node1`:**
```bash
/usr/local/bin/db-role-check.sh
curl -i http://127.0.0.1:9200/
```
**Ожидаемый результат:**
- Скрипт отдает HTTP 503 Service Unavailable (Slave).
- В течение 4 секунд HAProxy помечает бэкенд `node1_db_r0` как `DOWN` и сбрасывает клиентские сессии.

---

## 3. Восстановление
```bash
sudo -u postgres psql -c "ALTER SYSTEM RESET default_transaction_read_only;"
sudo -u postgres psql -c "SELECT pg_reload_conf();"
```
