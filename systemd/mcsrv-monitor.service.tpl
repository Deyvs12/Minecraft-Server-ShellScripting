# Plantilla de la unit del monitor. deploy sustituye los marcadores __XXX__.
# Corre como root porque ejecuta nft.

[Unit]
Description=Monitor de mcsrv para el servidor de Minecraft
After=minecraft.service
Wants=minecraft.service

[Service]
Type=simple
ExecStart=__MCSRV_ROOT__/mcsrv.sh -c __CONFIG__ monitor
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
