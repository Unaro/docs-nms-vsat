[Unit]
Description=PostgreSQL Role Check Socket for HAProxy
[Socket]
ListenStream=${DB_CHECK_PORT}
Accept=yes
LogLevelMax=warning
[Install]
WantedBy=sockets.target
