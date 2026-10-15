# TC-09: Авария PostgreSQL — переход в режим Read-Only и порог XID Wraparound

## 1. Паспорт тест-кейса
- **Идентификатор**: `TC-09`
- **MMD-диаграмма**: [`mmd/ОтказPostgresReadOnly.mmd`](../mmd/ОтказPostgresReadOnly.mmd)
- **Цель**: Проверить реакцию кластера и балансировщика HAProxy на критический переход Master СУБД в состояние Read-Only (вследствие исчерпания идентификаторов транзакций XID Wraparound или ручной блокировки), валидацию через скрипт `db-role-check.sh` и переключение трафика на Standby.
- **Объекты проверки**:
  - Комплексный скрипт `/usr/local/bin/db-role-check.sh` (проверка `pg_is_in_recovery()`, `current_setting('transaction_read_only')` и `max(age(datfrozenxid))`).
  - Возврат HTTP 503 Service Unavailable при сохранении процесса `postgres` в живых.
  - Реакция HAProxy на статус 503 (`inter 2s fall 2 on-marked-down shutdown-sessions`).
  - Отработка переключения Pacemaker при невозможности записи на текущем мастере.

---

## 2. Предусловия
1. Кластер развернут по спецификации `bootstrap-ha.sh` v5.0.
2. `node1` находится в роли Master, `node2` — Standby.
3. VIP `192.168.1.100` и группа `core-app-stack` активны на `node1`.
4. Клиентские запросы успешно проходят через порт `127.0.0.1:5000` (HAProxy).

---

## 3. Шаги выполнения и ожидаемые результаты

### Шаг 1. Проверка исходного состояния проверки роли БД
**Команда на `node1`:**
```bash
/usr/local/bin/db-role-check.sh
curl -i http://127.0.0.1:9200/
```
**Ожидаемый результат:**
- Возвращается HTTP 200 OK:
  ```text
  HTTP/1.1 200 OK
  Content-Type: text/plain
  Content-Length: 6

  Master
  ```
- В `haproxy.cfg` сервер `node1_db_r0` находится в состоянии UP.

---

### Шаг 2. Имитация блокировки записи (Read-Only авария)
**Команда на `node1`:**
```bash
sudo -u postgres psql -c "ALTER SYSTEM SET default_transaction_read_only = 'on';"
sudo -u postgres psql -c "SELECT pg_reload_conf();"
```
*Примечание*: В продакшене аналогичный эффект возникает автоматически, если `max(age(datfrozenxid))` превышает порог безопасности `autovacuum_freeze_max_age` / `txid_stop_limit`.

---

### Шаг 3. Проверка срабатывания фильтра v5.0 в db-role-check.sh
**Команда на `node1`:**
```bash
/usr/local/bin/db-role-check.sh
```
**Ожидаемый результат:**
- Скрипт детектирует, что хотя `pg_is_in_recovery()` равно `f`, параметр `transaction_read_only` равен `on`.
- В системный журнал отправляется алерт:
  ```text
  db-role-check: КРИТИЧЕСКАЯ АВАРИЯ БД: Master перешел в Read-Only (on) или превысил лимит XID Wraparound!
  ```
- Код возврата равен `1`.
- Вывод скрипта возвращает HTTP 503:
  ```text
  HTTP/1.1 503 Service Unavailable
  Content-Type: text/plain
  Content-Length: 5

  Slave
  ```

---

### Шаг 4. Реакция HAProxy на отказ мастера в обслуживании записи
**Команда на `node1`:**
```bash
echo "show stat" | socat stdio /var/run/haproxy/admin.sock 2>/dev/null | grep -E "node1_db_r0|node2_db_r0" || true
journalctl -u haproxy -n 20 --no-pager
```
**Ожидаемый результат:**
- Через 4 секунды (2 интервала по 2 сек, `fall 2`) HAProxy переводит бэкенд `node1_db_r0` в статус DOWN.
- Срабатывает флаг `shutdown-sessions`: все зависшие сессии клиентов, ожидавшие записи, немедленно принудительно обрываются.

---

### Шаг 5. Инициирование переключения ролей и проверка промоута на Standby
**Команда на `node1` / `node2`:**
```bash
pcs resource fail pgsql
pcs status
```
**Ожидаемый результат:**
- Pacemaker выполняет demote СУБД на `node1` и переводит ресурс в статус Stopped.
- `node2` промоутируется в Master:
  - `Promoted: node2`
  - Ресурсы `vip`, `core-app-stack` и `daemon-svc` мигрируют на `node2`.
- На `node2` скрипт `/usr/local/bin/db-role-check.sh` возвращает HTTP 200 OK.
- Балансировщик HAProxy на `node2` начинает маршрутизировать клиентские запросы на локальный PostgreSQL.

---

### Шаг 6. Проверка защиты от XID Wraparound по порогу MAX_XID_AGE_LIMIT
**Команда на `node2` (тестирование граничного условия в скрипте):**
```bash
bash -c '
source /etc/default/ha-cluster
MAX_XID_AGE_LIMIT=1000 /usr/local/bin/db-role-check.sh
'
```
**Ожидаемый результат:**
- Если текущий возраст XID больше искусственно заниженного лимита (1000), скрипт возвращает 503 Service Unavailable и логирует алерт в syslog, подтверждая готовность к предотвращению аварии XID Wraparound.

---

## 4. Восстановление исходного состояния
```bash
# На node1 снимаем флаг Read-Only:
sudo -u postgres psql -c "ALTER SYSTEM RESET default_transaction_read_only;"
sudo -u postgres psql -c "SELECT pg_reload_conf();"

# Сбрасываем счетчик ошибок Pacemaker:
pcs resource cleanup pgsql
pcs status
```
Узел `node1` возвращается в кластер в качестве синхронного Standby.
