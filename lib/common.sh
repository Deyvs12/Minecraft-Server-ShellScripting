#!/usr/bin/env bash
#
# lib/common.sh — Registro de eventos, verificación de privilegios y carga de
# la configuración. Se carga con `source` desde mcsrv.sh.

set -euo pipefail

: "${MCSRV_LOG_FILE:=/var/log/mcsrv.log}"

if [[ -t 1 ]]; then
    readonly C_RESET=$'\033[0m'
    readonly C_ROJO=$'\033[1;31m'
    readonly C_VERDE=$'\033[1;32m'
    readonly C_AMARILLO=$'\033[1;33m'
    readonly C_AZUL=$'\033[1;34m'
else
    readonly C_RESET='' C_ROJO='' C_VERDE='' C_AMARILLO='' C_AZUL=''
fi

# ---------------------------------------------------------------------------
# Registro de eventos
# ---------------------------------------------------------------------------

# Emite un evento al archivo de log, a syslog y a la consola.
_mcsrv_log() {
    local nivel="$1"
    shift
    local mensaje="$*" color prioridad salida=1

    case "$nivel" in
        INFO)  color="$C_AZUL";     prioridad="user.info"    ;;
        OK)    color="$C_VERDE";    prioridad="user.info"    ;;
        WARN)  color="$C_AMARILLO"; prioridad="user.warning"; salida=2 ;;
        ERROR) color="$C_ROJO";     prioridad="user.err";     salida=2 ;;
    esac

    { printf '%s [%s] %s\n' "$(date -Iseconds)" "$nivel" "$mensaje" \
        >>"$MCSRV_LOG_FILE"; } 2>/dev/null || true

    logger -t mcsrv -p "$prioridad" -- "[${nivel}] ${mensaje}" 2>/dev/null || true

    printf '%s%-5s%s %s\n' "$color" "$nivel" "$C_RESET" "$mensaje" >&"$salida"
}

# Registra un evento del flujo normal.
log_info() { _mcsrv_log INFO "$@"; }

# Registra una operación completada con éxito.
log_ok() { _mcsrv_log OK "$@"; }

# Registra una anomalía que no impide continuar.
log_warn() { _mcsrv_log WARN "$@"; }

# Registra un error sin terminar el programa.
log_error() { _mcsrv_log ERROR "$@"; }

# Registra un error y aborta la ejecución.
die() { log_error "$@"; exit 1; }

# Aborta si el programa no se está ejecutando como root.
require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        die "este comando requiere root (usa: sudo $0 ${MCSRV_COMANDO:-<comando>})"
    fi
}

# ---------------------------------------------------------------------------
# Configuración
# ---------------------------------------------------------------------------

readonly VARS_OBLIGATORIAS=(
    SERVER_JAR
    SERVER_PORT
    EXPECTED_SHA1
    JAVA_BIN
    JAVA_MIN_VERSION
    MIN_RAM_MB
    JVM_XMX
    JVM_XMS
    REPORT_PORT
    MONITOR_INTERVAL
    CPU_ALERT
    MEM_ALERT
    IP_BLOCK_THRESHOLD
    IP_BLOCK_WINDOW
)

# Devuelve 0 si el argumento es una IPv4 con máscara CIDR opcional.
es_ipv4() {
    local -a octetos
    local octeto

    [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]] || return 1
    [[ "$1" != */* ]] || (( ${1##*/} <= 32 )) || return 1

    IFS='.' read -r -a octetos <<<"${1%%/*}"
    for octeto in "${octetos[@]}"; do
        (( 10#$octeto <= 255 )) || return 1
    done
}

# Aborta si la variable no contiene un entero dentro del rango indicado.
validar_rango() {
    local nombre="$1" valor="$2" min="$3" max="$4"

    if [[ ! "$valor" =~ ^[0-9]+$ ]] || (( 10#$valor < min || 10#$valor > max )); then
        die "configuración inválida: ${nombre}='${valor}' debe ser un entero entre ${min} y ${max}"
    fi
}

# Aborta si falta alguna variable obligatoria, listándolas todas.
validar_obligatorias() {
    local nombre
    local faltantes=()

    for nombre in "${VARS_OBLIGATORIAS[@]}"; do
        [[ -n "${!nombre:-}" ]] || faltantes+=("$nombre")
    done

    if (( ${#faltantes[@]} > 0 )); then
        die "faltan variables obligatorias en ${1}: ${faltantes[*]}"
    fi
}

# Comprueba el tipo y el rango de cada valor de la configuración.
validar_valores() {
    local nombre

    validar_rango SERVER_PORT        "$SERVER_PORT"        1000 65535
    validar_rango REPORT_PORT        "$REPORT_PORT"        1000 65535
    validar_rango JAVA_MIN_VERSION   "$JAVA_MIN_VERSION"   1 999
    validar_rango MIN_RAM_MB         "$MIN_RAM_MB"         1 1048576
    validar_rango MONITOR_INTERVAL   "$MONITOR_INTERVAL"   1 3600
    validar_rango CPU_ALERT          "$CPU_ALERT"          1 100
    validar_rango MEM_ALERT          "$MEM_ALERT"          1 100
    validar_rango IP_BLOCK_THRESHOLD "$IP_BLOCK_THRESHOLD" 1 100000
    validar_rango IP_BLOCK_WINDOW    "$IP_BLOCK_WINDOW"    1 86400

    for nombre in JVM_XMS JVM_XMX; do
        [[ "${!nombre}" =~ ^[0-9]+[kKmMgG]?$ ]] ||
            die "configuración inválida: ${nombre}='${!nombre}' no es un tamaño JVM (ej. 512M, 2G)"
    done

    (( SERVER_PORT != REPORT_PORT )) ||
        die "configuración inválida: SERVER_PORT y REPORT_PORT no pueden ser el mismo (${SERVER_PORT})"

    # shellcheck disable=SC2153
    [[ "$SERVER_JAR" == /* ]] ||
        die "configuración inválida: SERVER_JAR='${SERVER_JAR}' debe ser una ruta absoluta"

    [[ "$EXPECTED_SHA1" =~ ^[0-9a-fA-F]{40}$ ]] ||
        die "configuración inválida: EXPECTED_SHA1 debe ser un hash de 40 caracteres hexadecimales"

    [[ -z "$ADMIN_IP" ]] || es_ipv4 "$ADMIN_IP" ||
        die "configuración inválida: ADMIN_IP='${ADMIN_IP}' no es una dirección IPv4 válida"
}

# Devuelve la ruta del archivo de configuración que corresponde usar.
ruta_config() {
    printf '%s\n' "${1:-${MCSRV_CONF:-/etc/mcsrv/mcsrv.conf}}"
}

# Crea la configuración desde mcsrv.conf.example si todavía no existe.
crear_config_si_falta() {
    local destino ejemplo="${MCSRV_ROOT}/mcsrv.conf.example"

    destino="$(ruta_config "${1:-}")"

    if [[ -f "$destino" ]]; then
        log_info "se usa la configuración existente: ${destino}"
        return 0
    fi

    [[ -f "$ejemplo" ]] || die "no se encontró la plantilla ${ejemplo}"

    install -D -m 640 -o root -g root "$ejemplo" "$destino" ||
        die "no se pudo crear ${destino}"

    log_warn "se creó ${destino} con los valores por defecto"
    log_warn "rellena EXPECTED_SHA1 y revisa jar, Java, puertos y ADMIN_IP"
}

# Localiza, carga y valida el archivo de configuración.
load_config() {
    local ruta
    ruta="$(ruta_config "${1:-}")"

    [[ -f "$ruta" ]] ||
        die "no se encontró la configuración: ${ruta} (ejecuta 'deploy' para crearla)"
    [[ -r "$ruta" ]] || die "sin permisos de lectura sobre ${ruta}"

    if [[ -n "$(find "$ruta" -maxdepth 0 -perm /go+w)" ]]; then
        log_warn "permisos laxos en ${ruta}: usa 'chmod 640'"
    fi

    ADMIN_IP=""

    # shellcheck source=/dev/null
    source "$ruta"

    validar_obligatorias "$ruta"
    validar_valores

    # Ruta efectiva del config, que harden.sh escribe en la unit del monitor.
    # shellcheck disable=SC2034
    MCSRV_CONF_ACTIVO="$ruta"

    : "${SERVER_DIR:=/opt/minecraft}"
    : "${SERVER_USER:=mcserver}"
    : "${STATE_DIR:=/var/lib/mcsrv}"
    : "${REPORT_DIR:=${STATE_DIR}/report}"
    : "${SERVER_LOG_FILE:=${SERVER_DIR}/logs/latest.log}"
    : "${REPORT_FILE:=${REPORT_DIR}/index.html}"
    : "${EVENTOS_FILE:=${STATE_DIR}/eventos.log}"
    : "${PLAYERS_FILE:=${STATE_DIR}/players}"
    : "${BLOCKED_LIST_FILE:=${STATE_DIR}/blocked.list}"
    : "${FIFO_EVENTOS:=${STATE_DIR}/eventos.fifo}"
    : "${LOCK_FILE:=${STATE_DIR}/monitor.lock}"

    log_info "configuración cargada desde ${ruta}"
}
