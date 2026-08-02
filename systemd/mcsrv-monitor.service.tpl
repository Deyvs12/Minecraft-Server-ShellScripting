# Plantilla de la unit del monitor. deploy sustituye los marcadores __XXX__
# y la instala en /etc/systemd/system/mcsrv-monitor.service.
#
# Corre como root porque ejecuta `nft` para añadir elementos al conjunto
# blocked_ips del cortafuegos y lee /proc del proceso del servidor.

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
