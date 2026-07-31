#!/usr/bin/env bash
#
# mcsrv.sh — Punto de entrada. Procesa las opciones, carga las librerías de
# lib/ y despacha al módulo correspondiente.
#
# Uso: mcsrv.sh [-c ARCHIVO] <comando> [argumentos]

set -euo pipefail

MCSRV_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
readonly MCSRV_ROOT
readonly MCSRV_VERSION="0.1.0"

# shellcheck source=lib/common.sh
source "${MCSRV_ROOT}/lib/common.sh"
# shellcheck source=lib/validate.sh
source "${MCSRV_ROOT}/lib/validate.sh"
# shellcheck source=lib/harden.sh
source "${MCSRV_ROOT}/lib/harden.sh"

# Imprime la ayuda de uso de la herramienta.
mostrar_uso() {
    cat <<'AYUDA'
mcsrv — despliegue seguro y monitoreo de servidores Minecraft Java Edition

Uso: mcsrv.sh [-c ARCHIVO] <comando> [argumentos]

Comandos:
  deploy                 Valida el entorno, endurece el host y arranca el
                         servidor. Requiere root.
  monitor                Métricas y análisis del log en bucle. Requiere root.
  status                 Resumen en consola del estado del servidor.
  report                 Regenera el reporte HTML.
  block <IP>             Bloquea una IP en nftables. Requiere root.
  unblock <IP>           Desbloquea una IP. Requiere root.
  help                   Muestra esta ayuda.
  version                Muestra la versión.

Opciones:
  -c, --config ARCHIVO   Ruta a mcsrv.conf. Por defecto usa $MCSRV_CONF o
                         /etc/mcsrv/mcsrv.conf.
AYUDA
}


RUTA_CONFIG=""

while [[ "${1:-}" == -* ]]; do
    case "$1" in
        -c|--config)
            [[ -n "${2:-}" ]] || die "la opción $1 requiere una ruta de archivo"
            RUTA_CONFIG="$2"
            shift 2
            ;;
        -h|--help)
            mostrar_uso
            exit 0
            ;;
        *)
            log_error "opción desconocida: $1"
            mostrar_uso >&2
            exit 1
            ;;
    esac
done

if (( $# == 0 )); then
    log_error "falta el comando"
    mostrar_uso >&2
    exit 1
fi

MCSRV_COMANDO="$1"
readonly MCSRV_COMANDO
shift

case "$MCSRV_COMANDO" in
    deploy)
        require_root
        crear_config_si_falta "$RUTA_CONFIG"
        load_config "$RUTA_CONFIG"
        mcsrv_deploy "$@"
        ;;

    monitor)
        require_root
        load_config "$RUTA_CONFIG"
        die "'monitor' se implementa en la Fase 2"      # Fase 2: mcsrv_monitor "$@"
        ;;

    block)
        require_root
        load_config "$RUTA_CONFIG"
        die "'block' se implementa en la Fase 2"        # Fase 2: mcsrv_block "$@"
        ;;

    unblock)
        require_root
        load_config "$RUTA_CONFIG"
        die "'unblock' se implementa en la Fase 2"      # Fase 2: mcsrv_unblock "$@"
        ;;

    status)
        load_config "$RUTA_CONFIG"
        die "'status' se implementa en la Fase 3"       # Fase 3: mcsrv_status "$@"
        ;;

    report)
        load_config "$RUTA_CONFIG"
        die "'report' se implementa en la Fase 3"       # Fase 3: mcsrv_report "$@"
        ;;

    help)
        mostrar_uso
        ;;

    version)
        printf 'mcsrv %s\n' "$MCSRV_VERSION"
        ;;

    *)
        log_error "comando desconocido: ${MCSRV_COMANDO}"
        mostrar_uso >&2
        exit 1
        ;;
esac
