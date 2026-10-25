-- psql variables are quoted as identifiers/literals, never interpolated by shell.
SELECT format('CREATE ROLE %I WITH REPLICATION LOGIN PASSWORD %L', :'repl_user', :'repl_pass')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'repl_user')
\gexec
SELECT format('ALTER ROLE %I WITH REPLICATION LOGIN PASSWORD %L', :'repl_user', :'repl_pass')
\gexec
GRANT pg_read_all_data TO :"repl_user";
GRANT pg_read_server_files TO :"repl_user";
GRANT EXECUTE ON FUNCTION pg_catalog.pg_control_system() TO :"repl_user";
GRANT EXECUTE ON FUNCTION pg_catalog.pg_control_checkpoint() TO :"repl_user";
GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text) TO :"repl_user";
GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean) TO :"repl_user";
GRANT EXECUTE ON FUNCTION pg_catalog.pg_stat_file(text, boolean) TO :"repl_user";
GRANT EXECUTE ON FUNCTION pg_catalog.pg_ls_dir(text, boolean, boolean) TO :"repl_user";
SELECT pg_create_physical_replication_slot(:'slot1', true)
WHERE NOT EXISTS (SELECT FROM pg_replication_slots WHERE slot_name = :'slot1');
SELECT pg_create_physical_replication_slot(:'slot2', true)
WHERE NOT EXISTS (SELECT FROM pg_replication_slots WHERE slot_name = :'slot2');
