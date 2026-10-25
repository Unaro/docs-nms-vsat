# --- HA-CLUSTER-PG-BEGIN ---
listen_addresses = '*'
unix_socket_directories = '/var/run/postgresql, /tmp'
max_connections = ${MAX_CONNECTIONS}
shared_buffers = 256MB
wal_level = replica
wal_log_hints = on
full_page_writes = on
track_commit_timestamp = on
hot_standby = on
hot_standby_feedback = on
recovery_target_timeline = 'latest'
superuser_reserved_connections = 3
max_slot_wal_keep_size = ${MAX_SLOT_WAL_KEEP_SIZE}
wal_keep_size = ${WAL_KEEP_SIZE}
password_encryption = scram-sha-256
idle_in_transaction_session_timeout = '15000ms'
statement_timeout = '30000ms'
lock_timeout = '5000ms'
tcp_keepalives_idle = 15
tcp_keepalives_interval = 5
tcp_keepalives_count = 3
# --- HA-CLUSTER-PG-END ---
