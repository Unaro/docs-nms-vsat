global
  log /dev/log local0 warning
  maxconn 500
  user haproxy
  group haproxy
  daemon

defaults
  log     global
  mode    tcp
  option  tcplog
  retries 3
  timeout queue   1m
  timeout connect 5s
  timeout client  30m
  timeout server  30m
  timeout check   2s

listen postgres_master
  bind 127.0.0.1:${HAPROXY_DB_BIND_PORT}
  mode tcp
  option httpchk GET /
  http-check expect status 200
  default-server inter 2s fall 2 rise 2 on-marked-down shutdown-sessions

  server node1_db_r0 ${NODE1_RING0_IP}:${DB_PORT} maxconn 100 check port ${DB_CHECK_PORT}
  server node2_db_r0 ${NODE2_RING0_IP}:${DB_PORT} maxconn 100 check port ${DB_CHECK_PORT}
  server node1_db_r1 ${NODE1_RING1_IP}:${DB_PORT} maxconn 100 check port ${DB_CHECK_PORT} backup
  server node2_db_r1 ${NODE2_RING1_IP}:${DB_PORT} maxconn 100 check port ${DB_CHECK_PORT} backup
