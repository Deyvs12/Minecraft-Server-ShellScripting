#!/usr/bin/env bash
#
# Resumen del estado en consola.

set -euo pipefail

# Imprime una línea del resumen con la etiqueta alineada.
linea_estado() {
    printf '  %-14s %s\n' "$1" "$2"
}

# Devuelve "activo" o "detenido" según el estado de la unit indicada.
estado_unit() {
    if systemctl is-active --quiet "$1"; then
        printf 'activo\n'
    else
        printf 'detenido\n'
    fi
}

# Devuelve el número de IPs bloqueadas, o un aviso si no se puede leer.
conteo_bloqueadas() {
    if [[ -s "$BLOCKED_LIST_FILE" ]]; then
        wc -l < "$BLOCKED_LIST_FILE"
    else
        printf '0\n'
    fi
}

# Devuelve los jugadores conectados, o un aviso si no se puede leer.
conteo_jugadores() {
    local n

    if read -r n < "$PLAYERS_FILE" 2>/dev/null; then
        printf '%s\n' "$n"
    else
        printf '0\n'
    fi
}

# Devuelve la dirección principal del host.
ip_del_host() {
    hostname -I | awk '{print $1}'
}

# Punto de entrada del comando status.
mcsrv_status() {
    local pid mem_x10 rss_kb uptime_s ip

    pid="$(pid_servidor)"
    ip="$(ip_del_host)"

    printf '\nmcsrv - estado\n\n'

    if (( pid > 0 )); then
        rss_kb="$(memoria_rss_kb "$pid")"
        mem_x10="$(memoria_del_proceso "$pid")"
        uptime_s="$(uptime_del_proceso "$pid")"
        linea_estado "Servidor" "activo · PID ${pid} · $(formato_uptime "$uptime_s")"
        linea_estado "Memoria" "$(formato_gb "$rss_kb") de ${JVM_XMX} ($(formato_porcentaje "$mem_x10")%)"
    else
        linea_estado "Servidor" "detenido"
    fi

    linea_estado "Monitor" "$(estado_unit mcsrv-monitor.service)"
    linea_estado "Cortafuegos" "$(estado_unit nftables.service)"
    linea_estado "Reporte web" "$(estado_unit nginx.service) · http://${ip}:${REPORT_PORT}/"
    linea_estado "Jugadores" "$(conteo_jugadores)"
    linea_estado "IPs bloqueadas" "$(conteo_bloqueadas)"

    printf '\n'
    linea_estado "Puertos" "abiertos en nftables: $(detectar_puerto_ssh), ${SERVER_PORT}, ${REPORT_PORT}"

    if puerto_en_escucha "$SERVER_PORT"; then
        linea_estado "" "${SERVER_PORT} escuchando"
    else
        linea_estado "" "${SERVER_PORT} SIN escuchar"
    fi
    if puerto_en_escucha "$REPORT_PORT"; then
        linea_estado "" "${REPORT_PORT} escuchando"
    else
        linea_estado "" "${REPORT_PORT} SIN escuchar"
    fi

    printf '\n'
    linea_estado "Configuración" "$(ruta_config "${RUTA_CONFIG:-}")"
    linea_estado "Jar" "${SERVER_JAR}"
    linea_estado "Log del server" "${SERVER_LOG_FILE}"
    linea_estado "Log de mcsrv" "${MCSRV_LOG_FILE}"
    printf '\n'
}
