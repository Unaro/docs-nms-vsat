# Разделение настройки HA и аудит configure-ha.sh

## Структура и ответственность

- `generate-ha-config.sh`: формирование /etc/default/ha-cluster.
- `setup-node.sh`: первоначальная подготовка ОС, PostgreSQL, HAProxy, role-check.
  Требует пустой PGDATA для master/standby; не используется для обновления живой БД.
- `configure-ha.sh`: установка кластерных runtime-артефактов и, только с --init-pcs,
  создание Corosync/Pacemaker и ресурсов. Без аргументов CIB не меняется.
- `bootstrap-ha.sh`: совместимая точка входа, вызывает configure-ha.sh.
- `pgsqlms-ha`: единственный компонент автоматического восстановления PGDATA.
- `artifacts/bin/`: исполняемые role-check, preflight и degraded-policy.
- `artifacts/systemd/`: unit-файлы, drop-in и шаблоны unit-файлов.
- `artifacts/postgresql/`: шаблоны настроек, HBA и SQL первоначальной настройки.
- `artifacts/haproxy/`, `artifacts/sysctl/`: отдельные системные конфигурации.
- `lib/artifacts.sh`: установка и подстановка только ${NAME}, без eval/envsubst.

В установщиках больше нет heredoc с программами, unit-файлами, конфигурациями или SQL.
Статические файлы копируются, `.tpl` обрабатываются без выполнения содержимого.
Каталоги artifacts и lib необходимо распространять вместе со скриптами.

## Что обнаружено и исправлено

1. bootstrap/configure содержали разные версии одних программ и CIB. Теперь
   реализация одна, старое имя оставлено как совместимая обёртка.
2. Analyzer запускал crash recovery на исходном PGDATA, удалял PID/socket файлы,
   менял standby.signal и auto.conf до сохранения ветки. Теперь он читает только
   pg_controldata/ёмкость диска и атомарно пишет собственный /run-файл.
3. enable-time RequiredBy и RemainAfterExit не обеспечивали повторную проверку
   при всех запусках. Установлены явные Requires/After drop-in для cluster services;
   preflight не остаётся active после oneshot.
4. Удалены RT scheduling priority 99 и blanket OOMScoreAdjust=-1000 для cluster
   daemons: такая политика могла ухудшать поведение системы при дефиците ресурсов.
5. Заданный consensus=3600 мог быть меньше настраиваемого token; теперь 2*token.
6. Инициализация CIB выполняется под maintenance-mode. При ошибке создания
   ресурса/constraint режим остаётся включённым для разбора оператором.
7. Positive score-attribute=pingd не запрещал узлы без шлюза. Добавлены явные
   -INFINITY для missing/нулевого pingd. Это сетевой критерий, не арбитраж.
8. daemon-stack constraints создаются только при непустом списке демонов.
9. Приложение и демон ожидают только запуск HAProxy, не promote PostgreSQL.
   app-stack и daemon-stack обращаются к текущему primary через локальный HAProxy;
   зависимости order/colocation между этими стеками и PostgreSQL отсутствуют.
   Смена роли или перезапуск БД не должны перемещать или останавливать стеки.
10. Скорректированы ARP interval и таймаут stop PostgreSQL.
11. Неизвестный узел и повторная --init-pcs отклоняются; --force при создании
    приложений удалён. Пустые списки приложений допустимы (VIP остаётся в группе).
12. Role-check делает один SQL-запрос вместо двух, имеет таймаут чтения и systemd
    RuntimeMaxSec. Критерий — доступный writable PostgreSQL, не полномочия кластера.
13. Широкие сетевые trust заменены SCRAM и /32 адресами колец. Правила приложений
    нужно добавить явно; это несовместимое усиление безопасности для новых установок.
14. SQL роли использует psql identifier/literal quoting. .pgpass экранирует : и backslash.
15. Первоначальная подготовка отказывается стирать непустой PGDATA и работать при
    активном Pacemaker. Это не инструмент восстановления существующего узла.

## Что намеренно не решено

Fencing/quorum не переработаны: stonith-enabled=false и degraded-unblock — старый
режим. Таймаут и ICMP не доказывают отсутствие второго primary. Незнакомый hostname
и неизвестная прежняя роль теперь не разрешают автоматическую разблокировку.
Quorate=Yes не обязательно означает наличие двух узлов; сообщения старого watchdog
не следует трактовать как достоверную проверку membership.

Инициализация не является распределённой транзакцией: если pcs cluster setup/start
оборвался, нужен осмотр обоих узлов. Проверка версии pcs и реальная проверка его
CLI/constraints нужны на целевом стенде. Повторную настройку существующего CIB
не следует делать через --init-pcs.

Предыдущие установки могли оставить systemd symlink, drop-in для postgresql/haproxy,
app cgroup limits и journald limits из старого bootstrap. Скрипт их массово не удаляет:
перед обновлением сравните systemctl cat и удалите только устаревшие настройки.
Новые artefacts не обновляются на втором узле автоматически.

Системный sysctl по-прежнему включает hung_task_panic; это отдельная агрессивная
политика ОС, которую нужно согласовать и проверить на нагрузке.

## Проверки

`python3 tests/test-artifacts.py` — 5 тестов (синтаксис, рендеринг всех шаблонов,
отсутствующие переменные, отсутствие embedded heredoc, read-only preflight).
`python3 tests/test-pgsqlms-ha.py` — ещё 5 локальных тестов восстановления.

systemd-analyze verify в рабочем окружении агента не прошёл полностью: отсутствуют
установленные /usr/local программы и db-role-check.socket. Полную проверку rendered
unit-файлов следует выполнить после установки на стенде. systemctl/pcs/HAProxy
на хосте разработки не запускались; CIB и системная конфигурация не изменялись.
