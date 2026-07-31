#!/usr/bin/env bash
#
# lib/validate.sh — Validaciones previas al despliegue: versión de Java,
# memoria disponible, integridad del jar y puerto libre.

set -euo pipefail

# Ruta absoluta de Java, resuelta por validar_java() y usada al generar la unit.
JAVA_RESUELTO=""

# Comprueba que Java existe y que su versión alcanza JAVA_MIN_VERSION.
validar_java() {
    local salida version major

    JAVA_RESUELTO="$(command -v "$JAVA_BIN" 2>/dev/null)" ||
        die "no se encontró el binario de Java: '${JAVA_BIN}' (ajusta JAVA_BIN en la configuración)"
    [[ -x "$JAVA_RESUELTO" ]] || die "${JAVA_RESUELTO} no es ejecutable"

    salida="$("$JAVA_RESUELTO" -version 2>&1)" ||
        die "'${JAVA_RESUELTO} -version' terminó con error"

    version="$(printf '%s\n' "$salida" | sed -n 's/.*version "\([^"]*\)".*/\1/p' | head -1)"
    [[ -n "$version" ]] ||
        die "no se pudo interpretar la versión de Java a partir de: ${salida}"

    # Hasta Java 8 la versión empezaba por 1. (1.8.0_381 = Java 8).
    if [[ "$version" == 1.* ]]; then
        major="$(printf '%s\n' "$version" | cut -d. -f2)"
    else
        major="$(printf '%s\n' "$version" | cut -d. -f1)"
    fi
    major="${major%%[!0-9]*}"
    [[ -n "$major" ]] || die "no se pudo determinar la versión major de Java (${version})"

    if (( major < JAVA_MIN_VERSION )); then
        die "Java ${version} es insuficiente: se requiere major ${JAVA_MIN_VERSION} o superior"
    fi
    log_ok "Java ${version} en ${JAVA_RESUELTO}"
}

# Comprueba que hay al menos MIN_RAM_MB de memoria disponible.
validar_memoria() {
    local libre_kb libre_mb

    libre_kb="$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo)"
    [[ -n "$libre_kb" ]] || die "no se pudo leer MemAvailable de /proc/meminfo"

    libre_mb=$(( libre_kb / 1024 ))
    if (( libre_mb < MIN_RAM_MB )); then
        die "memoria disponible insuficiente: ${libre_mb} MB, se requieren ${MIN_RAM_MB} MB"
    fi
    log_ok "memoria disponible: ${libre_mb} MB"
}

# Compara el sha1 del jar con el que publica Mojang en EXPECTED_SHA1.
validar_integridad_jar() {
    local hash_actual

    if [[ ! -f "$SERVER_JAR" ]]; then
        log_error "falta el jar del servidor: ${SERVER_JAR}"
        log_error "descárgalo de https://www.minecraft.net/download/server y cópialo ahí:"
        log_error "    sudo cp <archivo descargado> ${SERVER_JAR}"
        die "el directorio ${SERVER_DIR} ya está creado; vuelve a ejecutar deploy tras copiar el jar"
    fi

    hash_actual="$(sha1sum "$SERVER_JAR" | cut -d' ' -f1)"

    if [[ "$hash_actual" != "${EXPECTED_SHA1,,}" ]]; then
        log_error "sha1 del jar : ${hash_actual}"
        log_error "sha1 esperado: ${EXPECTED_SHA1,,}"
        die "el jar no coincide con el hash oficial de Mojang; podría estar alterado o ser otra versión"
    fi

    log_ok "integridad del jar verificada (sha1 ${hash_actual})"
}

# Devuelve 0 si algún proceso escucha en el puerto indicado.
puerto_en_escucha() {
    ss -tln | awk -v patron=":${1}$" '$4 ~ patron {abierto=1} END {exit !abierto}'
}

# Comprueba que SERVER_PORT está libre, salvo que lo ocupe el propio servidor.
validar_puerto_servidor() {
    if ! puerto_en_escucha "$SERVER_PORT"; then
        log_ok "puerto ${SERVER_PORT} libre"
        return 0
    fi

    if systemctl is-active --quiet minecraft.service; then
        log_warn "el puerto ${SERVER_PORT} lo ocupa minecraft.service (redespliegue en curso)"
        return 0
    fi

    die "el puerto ${SERVER_PORT} ya está ocupado por otro proceso; libéralo o cambia SERVER_PORT"
}
