#!/usr/bin/env bash
#
# Generación del reporte HTML estático que sirve nginx.

set -euo pipefail

# Convierte segundos a un formato del tipo "2d 03h 14m".
formato_uptime() {
    local s="$1"
    printf '%dd %02dh %02dm\n' $(( s / 86400 )) $(( s % 86400 / 3600 )) $(( s % 3600 / 60 ))
}

# Convierte décimas de porcentaje a texto con un decimal.
formato_porcentaje() {
    printf '%d.%d\n' $(( $1 / 10 )) $(( $1 % 10 ))
}

# Convierte kilobytes a gigabytes con dos decimales.
formato_gb() {
    printf '%d.%02d GB\n' $(( $1 / 1048576 )) $(( ($1 % 1048576) * 100 / 1048576 ))
}

# Devuelve la clase CSS del semáforo según el valor y su umbral.
clase_semaforo() {
    local valor_x10="$1" umbral="$2"

    if (( valor_x10 >= umbral * 10 )); then
        printf 'rojo\n'
    elif (( valor_x10 >= umbral * 8 )); then
        printf 'amarillo\n'
    else
        printf 'verde\n'
    fi
}

# Escapa los caracteres que romperían el HTML del reporte.
escapar_html() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# Genera las filas de la tabla de IPs bloqueadas.
filas_bloqueadas() {
    if [[ ! -s "$BLOCKED_LIST_FILE" ]]; then
        printf '<tr><td colspan="3">Ninguna</td></tr>\n'
        return 0
    fi

    tac "$BLOCKED_LIST_FILE" | head -20 | escapar_html |
        awk -F'|' '{printf "<tr><td>%s</td><td>%s</td><td>%s</td></tr>\n", $2, $1, $3}'
}

# Genera las filas con los últimos eventos relevantes del log.
filas_eventos() {
    if [[ ! -s "$EVENTOS_FILE" ]]; then
        printf '<tr><td colspan="3">Sin eventos</td></tr>\n'
        return 0
    fi

    tail -20 "$EVENTOS_FILE" | tac | escapar_html |
        awk -F'|' '{
            texto = $4
            for (i = 5; i <= NF; i++) texto = texto "|" $i
            printf "<tr><td>%s</td><td>%s</td><td>%s</td></tr>\n", $2, ($3 == "" ? "-" : $3), texto
        }'
}

# Escribe el reporte HTML de forma atómica: primero temporal, luego mv.
generar_reporte() {
    local cpu_x10="$1" mem_x10="$2" rss_kb="$3" jugadores="$4" uptime_s="$5" pid="$6"
    local temporal="${REPORT_FILE}.tmp"
    local estado_servicio="detenido" clase_servicio="rojo"

    if (( pid > 0 )); then
        estado_servicio="activo"
        clase_servicio="verde"
    fi

    cat > "$temporal" <<HTML
<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="${MONITOR_INTERVAL}">
<title>mcsrv - estado del servidor</title>
<style>
body { font-family: system-ui, sans-serif; margin: 0; padding: 1.5rem;
       background: #14161a; color: #e6e8eb; }
h1 { font-size: 1.4rem; margin: 0 0 .3rem; }
p.sub { color: #8b929c; margin: 0 0 1.5rem; font-size: .85rem; }
.tarjetas { display: grid; gap: 1rem; margin-bottom: 2rem;
            grid-template-columns: repeat(auto-fit, minmax(190px, 1fr)); }
.tarjeta { background: #1c1f26; border-radius: 8px; padding: 1rem;
           border-left: 5px solid #3a3f4b; }
.tarjeta.verde    { border-left-color: #3fb950; }
.tarjeta.amarillo { border-left-color: #d29922; }
.tarjeta.rojo     { border-left-color: #f85149; }
.etiqueta { font-size: .75rem; text-transform: uppercase;
            letter-spacing: .05em; color: #8b929c; }
.valor { font-size: 1.9rem; font-weight: 600; margin-top: .2rem; }
h2 { font-size: 1rem; margin: 1.5rem 0 .6rem; }
table { width: 100%; border-collapse: collapse; font-size: .85rem; }
th, td { text-align: left; padding: .45rem .6rem;
         border-bottom: 1px solid #2a2e37; }
th { color: #8b929c; font-weight: 600; }
td { font-family: ui-monospace, monospace; word-break: break-word; }
footer { margin-top: 2rem; color: #8b929c; font-size: .75rem; }
</style>
</head>
<body>

<h1>mcsrv - estado del servidor</h1>
<p class="sub">Generado el $(date -Iseconds) · se actualiza cada ${MONITOR_INTERVAL} s</p>

<div class="tarjetas">
  <div class="tarjeta ${clase_servicio}">
    <div class="etiqueta">Servicio</div>
    <div class="valor">${estado_servicio}</div>
  </div>
  <div class="tarjeta $(clase_semaforo "$cpu_x10" "$CPU_ALERT")">
    <div class="etiqueta">CPU del sistema (umbral ${CPU_ALERT}%)</div>
    <div class="valor">$(formato_porcentaje "$cpu_x10")%</div>
  </div>
  <div class="tarjeta $(clase_semaforo "$mem_x10" "$MEM_ALERT")">
    <div class="etiqueta">Memoria · $(formato_porcentaje "$mem_x10")% de ${JVM_XMX} (umbral ${MEM_ALERT}%)</div>
    <div class="valor">$(formato_gb "$rss_kb")</div>
  </div>
  <div class="tarjeta verde">
    <div class="etiqueta">Jugadores</div>
    <div class="valor">${jugadores}</div>
  </div>
  <div class="tarjeta verde">
    <div class="etiqueta">Tiempo activo</div>
    <div class="valor">$(formato_uptime "$uptime_s")</div>
  </div>
</div>

<h2>IPs bloqueadas</h2>
<table>
  <tr><th>Dirección</th><th>Fecha</th><th>Motivo</th></tr>
$(filas_bloqueadas)
</table>

<h2>Últimos eventos del servidor</h2>
<table>
  <tr><th>Tipo</th><th>Origen</th><th>Línea</th></tr>
$(filas_eventos)
</table>

<footer>
mcsrv · PID ${pid} · umbral de bloqueo: ${IP_BLOCK_THRESHOLD} eventos en ${IP_BLOCK_WINDOW} s
</footer>

</body>
</html>
HTML

    chmod 644 "$temporal"
    mv "$temporal" "$REPORT_FILE"
}

# Borra el reporte al detener el monitor
retirar_reporte() {
    rm -f "$REPORT_FILE"
}

