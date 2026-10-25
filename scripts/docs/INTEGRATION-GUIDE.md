# Интеграция

1. Изучите [гарантии и ограничения](HA-AUTO-RECOVERY.md).
2. Установите PAF и одинаковую версию pgsqlms-ha на обоих узлах через install -m 0755.
3. Обновите /etc/default/ha-cluster: отдельные бюджеты архивирования, rewind,
   basebackup. Конфигурация должна принадлежать root и не разрешать чужую запись.
4. На primary предоставьте роли репликации EXECUTE на pg_control_system() и
   pg_control_checkpoint(), а также необходимые pg_rewind права чтения файлов.
   Для существующих установок эти GRANT нужно выполнить отдельно; setup-node.sh
   добавляет их только при выполнении настройки.
5. Подготовьте хранилище архивов, место и мониторинг. Внешние tablespaces/WAL
   пока блокируют автоматическое восстановление.
6. Пройдите локальные и интеграционные тесты на одноразовом стенде.
7. Сохраните полный CIB. Подготовьте offline-изменение типа primitive на pgsqlms-ha
   с сохранением параметров, clone, constraints и notifications. Проверьте diff
   и scheduler simulation до применения в согласованное окно обслуживания.
   Не удаляйте ресурс ради смены типа и не задавайте type/provider как instance attributes.
8. Обновите start timeout по полному бюджету и monitor timeout с учётом SQL-запросов.
9. Проверьте PAF start, streaming, архивы, доступность обоих колец и alerting.

track_commit_timestamp и wal_log_hints требуют рестарта, не только reload.
Не перезапускайте управляемый PostgreSQL напрямую в обход Pacemaker.
