# Local administration/health checks via OS identity.
local   all             all                                     peer
local   replication     postgres                                peer
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256

# Replication and pg_rewind SQL access on the two configured rings only.
host    postgres        ${REPL_USER}    ${NODE1_RING0_IP}/32      scram-sha-256
host    postgres        ${REPL_USER}    ${NODE2_RING0_IP}/32      scram-sha-256
host    postgres        ${REPL_USER}    ${NODE1_RING1_IP}/32      scram-sha-256
host    postgres        ${REPL_USER}    ${NODE2_RING1_IP}/32      scram-sha-256
host    replication     ${REPL_USER}    ${NODE1_RING0_IP}/32      scram-sha-256
host    replication     ${REPL_USER}    ${NODE2_RING0_IP}/32      scram-sha-256
host    replication     ${REPL_USER}    ${NODE1_RING1_IP}/32      scram-sha-256
host    replication     ${REPL_USER}    ${NODE2_RING1_IP}/32      scram-sha-256
# Application DB/user/address rules must be added explicitly before deployment.
