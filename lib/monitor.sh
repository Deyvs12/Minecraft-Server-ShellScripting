#!/usr/bin/env bash
#
# Métricas de /proc, análisis del log y bloqueo de IPs.
# Corre como root porque ejecuta nft.


set -euo pipefail

PID_TAIL=""
PID_PARSER=""

HZ="$(getconf CLK_TCK)"

CPU_TOTAL_PREVIO=""
CPU_INACTIVO_PREVIO=""
CPU_X10=0

# ---------------------------------------------------------------------------
# Estado en disco
# ---------------------------------------------------------------------------

# Crea los archivos de estado que comparten el parser y el bucle de métricas.
preparar_estado() {
    mkdir -p "$STATE_DIR" "$REPORT_DIR"
    : > "$EVENTOS_FILE"
    printf '0\n' > "$PLAYERS_FILE"
    [[ -f "$BLOCKED_LIST_FILE" ]] || : > "$BLOCKED_LIST_FILE"
    chmod 640 "$EVENTOS_FILE" "$PLAYERS_FILE" "$BLOCKED_LIST_FILE"
}

# Impide que se ejecuten dos monitores a la vez sobre el mismo estado.
tomar_cerrojo() {
    exec 9>"$LOCK_FILE"
    flock -n 9 ||
        die "ya hay un monitor en marcha; revisa con 'systemctl status mcsrv-monitor'"
}

# Devuelve el número de jugadores conectados según el parser.
leer_jugadores() {
    local n
    read -r n < "$PLAYERS_FILE" 2>/dev/null || n=0
    printf '%s\n' "${n:-0}"
}

# Suma el valor indicado al contador de jugadores, sin bajar de cero.
ajustar_jugadores() {
    local delta="$1" actual
    actual="$(leer_jugadores)"
    actual=$(( actual + delta ))
    (( actual < 0 )) && actual=0
    printf '%s\n' "$actual" > "$PLAYERS_FILE"
}

# ---------------------------------------------------------------------------
# Análisis del log del servidor
# ---------------------------------------------------------------------------

# Extrae la IPv4 del token /IP:PUERTO de una línea, si lo tiene.
extraer_ip() {
    if [[ "$1" =~ /([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}): ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    fi
}

# Clasifica una línea del log y devuelve su tipo de evento.
clasificar_linea() {
    case "$1" in
        *"joined the game"*)          printf 'JOIN\n' ;;
        *"left the game"*)            printf 'LEAVE\n' ;;
        *"logged in with entity id"*) printf 'LOGIN\n' ;;
        *"lost connection"*)          printf 'DESCONEXION\n' ;;
        *"Disconnecting"*)            printf 'RECHAZO\n' ;;
        *"/ERROR]"*)                  printf 'ERROR\n' ;;
        *"/WARN]"*)                   printf 'AVISO\n' ;;
    esac
}

# Registra un evento del log y actualiza el contador de jugadores.
procesar_linea_log() {
    local linea="$1"
    local tipo ip

    if [[ "$linea" == *"Starting minecraft server version"* ]]; then
        printf '0\n' > "$PLAYERS_FILE"
        return 0
    fi

    tipo="$(clasificar_linea "$linea")"
    [[ -n "$tipo" ]] || return 0

    ip="$(extraer_ip "$linea")"

    case "$tipo" in
        JOIN)  ajustar_jugadores 1 ;;
        LEAVE) ajustar_jugadores -1 ;;
    esac

    printf '%s|%s|%s|%s\n' "$(date +%s)" "$tipo" "$ip" "$linea" >> "$EVENTOS_FILE"
}

# Lanza tail y el lector del log como procesos en segundo plano.
iniciar_parser() {
    rm -f "$FIFO_EVENTOS"
    mkfifo "$FIFO_EVENTOS"

    # -n 0 lee solo lo nuevo: releer el histórico lo contaría como actual
    # 9>&- libera el cerrojo en los hijos por si quedan huérfanos
    tail -F -n 0 "$SERVER_LOG_FILE" > "$FIFO_EVENTOS" 2>/dev/null 9>&- &
    PID_TAIL=$!

    while IFS= read -r linea; do
        procesar_linea_log "$linea"
    done < "$FIFO_EVENTOS" 9>&- &
    PID_PARSER=$!

    log_info "analizando ${SERVER_LOG_FILE} (tail pid ${PID_TAIL})"
}

# Termina los procesos hijos y limpia la tubería.
detener_monitor() {
    if [[ -n "$PID_TAIL" ]]; then
        kill "$PID_TAIL" 2>/dev/null || true
    fi
    if [[ -n "$PID_PARSER" ]]; then
        kill "$PID_PARSER" 2>/dev/null || true
    fi
    rm -f "$FIFO_EVENTOS"
    retirar_reporte
    log_info "monitor detenido"
}

# Recorta el archivo de eventos para que no crezca sin límite.
podar_eventos() {
    local temporal="${EVENTOS_FILE}.tmp"

    if (( $(wc -l < "$EVENTOS_FILE") > 2000 )); then
        tail -n 1000 "$EVENTOS_FILE" > "$temporal"
        mv "$temporal" "$EVENTOS_FILE"
    fi
}

# ---------------------------------------------------------------------------
# Bloqueo de direcciones
# ---------------------------------------------------------------------------

# Lista las IPs que superan el umbral de eventos dentro de la ventana.
ips_sobre_umbral() {
    local limite=$(( $(date +%s) - IP_BLOCK_WINDOW ))

    awk -F'|' -v limite="$limite" -v umbral="$IP_BLOCK_THRESHOLD" '
        $1 >= limite && $3 != "" { cuenta[$3]++ }
        END { for (ip in cuenta) if (cuenta[ip] >= umbral) print ip }
    ' "$EVENTOS_FILE"
}

# Devuelve 0 si la IP ya está en el conjunto del cortafuegos.
ip_ya_bloqueada() {
    nft list set inet mcsrv blocked_ips 2>/dev/null | grep -qF "$1"
}

# Añade una IP al conjunto blocked_ips y la registra en blocked.list.
bloquear_ip() {
    local ip="$1" motivo="${2:-manual}"

    # El resto de 127.0.0.0/8 lo usan los túneles y sí debe poder bloquearse.
    if [[ "$ip" == "127.0.0.1" ]]; then
        log_warn "se omite el bloqueo de ${ip}: es el loopback del propio host"
        return 0
    fi

    if [[ -n "$ADMIN_IP" && "$ip" == "${ADMIN_IP%%/*}" ]]; then
        log_warn "se omite el bloqueo de ${ip}: es la dirección del administrador"
        return 0
    fi

    if ip_ya_bloqueada "$ip"; then
        return 0
    fi

    nft add element inet mcsrv blocked_ips "{ ${ip} }" ||
        { log_error "no se pudo bloquear ${ip} en nftables"; return 1; }

    printf '%s|%s|%s\n' "$(date -Iseconds)" "$ip" "$motivo" >> "$BLOCKED_LIST_FILE"
    log_warn "IP bloqueada: ${ip} (${motivo})"
}

# Quita una IP del conjunto blocked_ips y de blocked.list.
desbloquear_ip() {
    local ip="$1" temporal="${BLOCKED_LIST_FILE}.tmp"

    nft delete element inet mcsrv blocked_ips "{ ${ip} }" 2>/dev/null ||
        log_warn "${ip} no estaba en el conjunto de nftables"

    if [[ -f "$BLOCKED_LIST_FILE" ]]; then
        grep -v "|${ip}|" "$BLOCKED_LIST_FILE" > "$temporal" || true
        mv "$temporal" "$BLOCKED_LIST_FILE"
    fi

    log_ok "IP desbloqueada: ${ip}"
}

# Bloquea todas las IPs que superaron el umbral en la ventana actual.
aplicar_autobloqueo() {
    local ip

    while read -r ip; do
        [[ -n "$ip" ]] || continue
        bloquear_ip "$ip" "autobloqueo: ${IP_BLOCK_THRESHOLD}+ eventos en ${IP_BLOCK_WINDOW}s" || true
    done < <(ips_sobre_umbral)
}

# ---------------------------------------------------------------------------
# Métricas desde /proc
# ---------------------------------------------------------------------------

# Devuelve el PID principal del servicio del servidor, o 0 si no corre.
pid_servidor() {
    local pid
    pid="$(systemctl show -p MainPID --value minecraft.service 2>/dev/null)"
    printf '%s\n' "${pid:-0}"
}

# Calcula el uso de CPU de toda la máquina y lo deja en CPU_X10.
cpu_del_sistema() {
    local -a campos
    local valor total inactivo delta_total delta_inactivo

    read -r -a campos < /proc/stat

    total=0
    for valor in "${campos[@]:1}"; do
        total=$(( total + valor ))
    done
    inactivo="${campos[4]}"

    CPU_X10=0
    if [[ -n "$CPU_TOTAL_PREVIO" ]]; then
        delta_total=$(( total - CPU_TOTAL_PREVIO ))
        delta_inactivo=$(( inactivo - CPU_INACTIVO_PREVIO ))
        if (( delta_total > 0 )); then
            CPU_X10=$(( (delta_total - delta_inactivo) * 1000 / delta_total ))
        fi
    fi

    CPU_TOTAL_PREVIO="$total"
    CPU_INACTIVO_PREVIO="$inactivo"
}

# Convierte el límite de heap JVM_XMX a kilobytes.
jvm_xmx_kb() {
    local numero="${JVM_XMX%[kKmMgG]}"

    case "${JVM_XMX: -1}" in
        k|K) printf '%s\n' "$numero" ;;
        m|M) printf '%s\n' "$(( numero * 1024 ))" ;;
        g|G) printf '%s\n' "$(( numero * 1024 * 1024 ))" ;;
        *)   printf '%s\n' "$(( JVM_XMX / 1024 ))" ;;
    esac
}

# Devuelve la memoria residente del proceso en kilobytes.
memoria_rss_kb() {
    local rss

    [[ -r "/proc/${1}/status" ]] || { printf '0\n'; return 0; }
    rss="$(awk '/^VmRSS:/ {print $2; exit}' "/proc/${1}/status")"
    printf '%s\n' "${rss:-0}"
}

# Devuelve la memoria usada en décimas de porcentaje del límite de la JVM.
memoria_del_proceso() {
    local rss limite

    rss="$(memoria_rss_kb "$1")"
    limite="$(jvm_xmx_kb)"

    (( limite > 0 )) || { printf '0\n'; return 0; }
    printf '%s\n' "$(( rss * 1000 / limite ))"
}

# Devuelve los segundos que lleva corriendo el proceso.
uptime_del_proceso() {
    local pid="$1"
    local -a campos
    local arranque uptime_sistema

    [[ -r "/proc/${pid}/stat" ]] || { printf '0\n'; return 0; }

    read -r -a campos < "/proc/${pid}/stat"
    arranque=$(( campos[21] / HZ ))
    uptime_sistema="$(awk '{print int($1); exit}' /proc/uptime)"
    printf '%s\n' "$(( uptime_sistema - arranque ))"
}

# ---------------------------------------------------------------------------
# Bucle principal
# ---------------------------------------------------------------------------

# Ejecuta un ciclo de métricas, autobloqueo y generación del reporte.
ciclo_de_monitoreo() {
    local pid cpu_x10 mem_x10 rss_kb jugadores uptime_s

    pid="$(pid_servidor)"
    cpu_del_sistema
    cpu_x10="$CPU_X10"
    mem_x10=0
    rss_kb=0
    uptime_s=0

    if (( pid > 0 )); then
        rss_kb="$(memoria_rss_kb "$pid")"
        mem_x10="$(memoria_del_proceso "$pid")"
        uptime_s="$(uptime_del_proceso "$pid")"
    else
        log_warn "minecraft.service no está corriendo"
    fi

    jugadores="$(leer_jugadores)"

    if (( cpu_x10 >= CPU_ALERT * 10 )); then
        log_warn "CPU del sistema al $(formato_porcentaje "$cpu_x10")% (umbral ${CPU_ALERT}%)"
    fi
    if (( mem_x10 >= MEM_ALERT * 10 )); then
        log_warn "memoria al $(formato_porcentaje "$mem_x10")% de ${JVM_XMX} (umbral ${MEM_ALERT}%)"
    fi

    aplicar_autobloqueo
    podar_eventos
    generar_reporte "$cpu_x10" "$mem_x10" "$rss_kb" "$jugadores" "$uptime_s" "$pid"
}

# Punto de entrada del comando monitor.
mcsrv_monitor() {
    [[ -f "$SERVER_LOG_FILE" ]] ||
        die "no existe el log del servidor: ${SERVER_LOG_FILE}"

    mkdir -p "$STATE_DIR"
    tomar_cerrojo
    preparar_estado
    trap detener_monitor EXIT INT TERM

    log_ok "monitor iniciado (intervalo ${MONITOR_INTERVAL}s)"
    iniciar_parser

    while true; do
        ciclo_de_monitoreo
        sleep "$MONITOR_INTERVAL"
    done
}

# Punto de entrada del comando block.
mcsrv_block() {
    bloquear_ip "$1" "bloqueo manual"
}

# Punto de entrada del comando unblock.
mcsrv_unblock() {
    desbloquear_ip "$1"
}
