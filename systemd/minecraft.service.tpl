# Plantilla de la unit del servidor. deploy sustituye los marcadores __XXX__
# y la instala en /etc/systemd/system/minecraft.service.

[Unit]
Description=Servidor de Minecraft Java Edition (gestionado por mcsrv)
Documentation=https://www.minecraft.net/download/server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=__SERVER_USER__
Group=__SERVER_USER__
WorkingDirectory=__SERVER_DIR__
ExecStart=__JAVA_BIN__ -Xms__JVM_XMS__ -Xmx__JVM_XMX__ -jar __SERVER_JAR__ nogui
Restart=on-failure
RestartSec=10

NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=__SERVER_DIR__

[Install]
WantedBy=multi-user.target
