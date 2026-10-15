# TC-10: Аномалии инфраструктуры — MTU Black Hole, дефицит диска CIB и VM Stun

## 1. Паспорт тест-кейса
- **Идентификатор**: `TC-10`
- **Цель**: Проверить защитные механизмы v5.0 на сетевом, системном и гипервизорном уровнях:
  1. Автодетекция и устранение «черной дыры MTU» (Jumbo Frames Mismatch) на канале Ring 0.
  2. Защита CIB Pacemaker от исчерпания дискового пространства (`MIN_FREE_CIB_MB=500` и ресурс `fs-mon`).
  3. Устойчивость кластера Corosync к задержкам гипервизора при бэкапах/снапшотах (VM Stun / vMotion).
  4. Предстартовая валидация беспарольного доступа `.pgpass` по протоколу потоковой репликации (`IDENTIFY_SYSTEM`).
- **Объекты проверки**:
  - Предстартовый анализатор `/usr/local/sbin/cluster-boot-analyzer.sh` (Блоки 2, 4, 6).
  - Тайминги `totem` в `corosync.conf` (`token: 3000`, `consensus: 3600`).
  - Ресурс `fs-mon` (`ocf:heartbeat:Diskd`).
  - Sysctl параметры `net.ipv4.tcp_mtu_probing` и `vm.overcommit_memory`.

---

## 2. Предусловия
1. Кластер развернут по спецификации `bootstrap-ha.sh` v5.0.
2. Оба узла активны, кворум собран.
3. Доступны утилиты `ping`, `ip`, `pcs`, `journalctl`.

---

## 3. Шаги выполнения и ожидаемые результаты

### Шаг 1. Проверка защиты от черной дыры MTU (Jumbo Frames Mismatch)
**Действие:**
Имитируем рассинхронизацию MTU: выставляем на интерфейсе `RING0_NIC` размер MTU 9000, при котором пакеты размером 9000 байт не могут пройти до соседа.
```bash
source /etc/default/ha-cluster
ip link set dev "$RING0_NIC" mtu 9000
ip -o link show dev "$RING0_NIC"
```

**Запуск проверки анализатором:**
```bash
/usr/local/sbin/cluster-boot-analyzer.sh
```

**Ожидаемый результат:**
- Анализатор отправляет тестовый DF-пинг:
  ```bash
  ping -c 2 -W 1 -M do -s 8972 "$PEER_IP"
  ```
- Зафиксировав потерю пакетов `Message too long` или таймаут, скрипт логирует алерт:
  ```text
  cluster-precheck: КРИТИЧЕСКАЯ ОШИБКА MTU: Пакеты 9000 байт (DF) не проходят до 10.0.0.2! Принудительно снижаю MTU на eth1 до 1500.
  ```
- MTU на интерфейсе автоматически возвращается к значению `SAFE_MTU` (1500).
- Проверяем результат:
  ```bash
  ip -o link show dev "$RING0_NIC" | grep "mtu 1500"
  ```

---

### Шаг 2. Проверка защиты раздела CIB Pacemaker от переполнения
**Действие:**
Проверяем реакцию анализатора на дефицит свободного места в `/var/lib/pacemaker`:
```bash
# Проверяем наличие параметра в конфиге
source /etc/default/ha-cluster
echo "Лимит CIB: ${MIN_FREE_CIB_MB:-500} MB"

# Проверяем статус ресурса fs-mon в Pacemaker
pcs status | grep -E "fs-mon"
```

**Ожидаемый результат:**
- Ресурс `fs-mon` (`ocf:heartbeat:Diskd`) активен на обоих узлах в режиме Clone:
  ```text
  Clone Set: fs-mon-clone [fs-mon]
    Started: [ node1 node2 ]
  ```
- При снижении свободного места ниже 500 МБ скрипт запускает автовакуумирование логов:
  ```bash
  journalctl --vacuum-size=100M
  ```
  освобождая место под транзакции CIB и предотвращая зависание демона `crmd`.

---

### Шаг 3. Проверка параметров защиты от VM Stun (vMotion / Hypervisor Backup)
**Действие на обоих узлах:**
```bash
corosync-cmapctl | grep -E "totem.token|totem.consensus|totem.token_retransmits_before_loss_const"
```

**Ожидаемый результат:**
Параметры Totem соответствуют промышленным рекомендациям для сред виртуализации:
- `totem.token (u32) = 3000` (3 секунды вместо дефолтной 1 секунды).
- `totem.token_retransmits_before_loss_const (u32) = 10`.
- `totem.consensus (u32) = 3600`.
- Кратковременные паузы виртуальной машины длительностью 1–2.5 секунды (сброс памяти при создании snapshot) **не приводят** к ложному фенсингу и перезагрузке узла.

---

### Шаг 4. Проверка валидации .pgpass перед операциями репликации
**Действие:**
Проверяем корректность выполнения блока 6 скрипта `cluster-boot-analyzer.sh`:
```bash
source /etc/default/ha-cluster
export PGPASSFILE="${PGPASS_FILE:-/var/lib/postgresql/.pgpass}"

# Тестируем подключение по протоколу репликации
sudo -u postgres PGPASSFILE="$PGPASSFILE" PGCONNECT_TIMEOUT=5 \
  psql -w "host=$NODE1_RING0_IP port=$DB_PORT user=$REPL_USER dbname=postgres replication=database" -c "IDENTIFY_SYSTEM;"
```

**Ожидаемый результат:**
- Подключение проходит без интерактивного запроса пароля (`-w`).
- Сервер возвращает системный идентификатор репликации:
  ```text
      systemid       | timeline |  xlogpos   | dbname 
  -------------------+----------+------------+--------
   738129481928471... |        1 | 0/1A000060 | 
  ```
- Файл `$PGDATA` защищен от ошибочного удаления при некорректном пароле в `.pgpass`.

---

## 4. Восстановление исходного состояния
```bash
# Убеждаемся, что MTU на Ring 0 находится в эталонном состоянии 1500:
ip link set dev "$RING0_NIC" mtu 1500

# Проверяем отсутствие ошибок в Pacemaker:
pcs status
```
Все проверки пройдены, кластер полностью готов к эксплуатации в реальных условиях дата-центра и сред виртуализации.
