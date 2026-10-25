[Unit]
Description=Read-only PostgreSQL cluster preflight
After=local-fs.target
RequiresMountsFor=${PGDATA}
Before=corosync.service pacemaker.service

[Service]
Type=oneshot
TimeoutStartSec=60
ExecStart=/usr/local/sbin/cluster-boot-analyzer.sh
