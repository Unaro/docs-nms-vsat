primary_conninfo = 'host=${NODE2_RING0_IP},${NODE2_RING1_IP} port=${DB_PORT} user=${REPL_USER} passfile=${PGPASS_FILE} application_name=${NODE1_NAME} connect_timeout=2 target_session_attrs=read-write'
primary_slot_name = '${REPL_SLOT_NODE1}'
recovery_target_timeline = 'latest'
