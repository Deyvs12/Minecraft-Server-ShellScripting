# Plantilla del server block del reporte. deploy sustituye __REPORT_PORT__ y
# __REPORT_DIR__ y la instala en /etc/nginx/sites-available/mcsrv-report.

server {
    listen __REPORT_PORT__;
    listen [::]:__REPORT_PORT__;

    server_name _;
    root __REPORT_DIR__;

    autoindex off;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }

    access_log /var/log/nginx/mcsrv-report.access.log;
    error_log  /var/log/nginx/mcsrv-report.error.log;
}
