#!/usr/bin/env bash
#
# lib/harden.sh — Despliegue: usuario, nftables, systemd, nginx y verificación.

set -euo pipefail

APT_ACTUALIZADO=""

# Ejecuta el despliegue completo, en orden y abortando al primer fallo.
mcsrv_deploy() {
    mkdir -p "$SERVER_DIR" "$STATE_DIR"

    log_info "--- Validaciones previas ---"
    validar_java
    validar_memoria
    validar_integridad_jar
    validar_puerto_servidor

    log_info "--- Endurecimiento ---"
    instalar_paquete nft nftables
    instalar_paquete nginx nginx
    crear_usuario_servidor
    configurar_nftables
    instalar_unit_minecraft
    instalar_unit_monitor
    configurar_nginx
    activar_servicio_minecraft
    activar_servicio_monitor

    log_info "--- Verificación ---"
    if ! verificar_puertos_expuestos; then
        log_error "el despliegue terminó, pero la verificación de puertos encontró problemas"
        return 1
    fi

    log_ok "despliegue completado"
}

# Instala un paquete de Debian si su comando principal no está disponible.
instalar_paquete() {
    local comando="$1" paquete="$2"

    if command -v "$comando" >/dev/null 2>&1; then
        log_info "${paquete} ya está instalado"
        return 0
    fi

    if [[ -z "$APT_ACTUALIZADO" ]]; then
        log_info "actualizando el índice de paquetes..."
        apt-get update -qq || log_warn "'apt-get update' falló; se intenta instalar de todos modos"
        APT_ACTUALIZADO="si"
    fi

    log_info "instalando ${paquete}..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$paquete" >/dev/null ||
        die "no se pudo instalar ${paquete}"
    log_ok "${paquete} instalado"
}

# ---------------------------------------------------------------------------
# Usuario sin privilegios
# ---------------------------------------------------------------------------

# Crea la cuenta de sistema que ejecuta el servidor y le asigna SERVER_DIR.
crear_usuario_servidor() {
    if id "$SERVER_USER" >/dev/null 2>&1; then
        log_info "el usuario ${SERVER_USER} ya existe"
    else
        useradd --system --home-dir "$SERVER_DIR" --shell /usr/sbin/nologin "$SERVER_USER" ||
            die "no se pudo crear el usuario ${SERVER_USER}"
        log_ok "usuario de sistema ${SERVER_USER} creado (shell: nologin)"
    fi

    mkdir -p "$SERVER_DIR"
    chown -R "${SERVER_USER}:${SERVER_USER}" "$SERVER_DIR"
    chmod 750 "$SERVER_DIR"
    log_ok "${SERVER_DIR} pertenece a ${SERVER_USER}"
}

# ---------------------------------------------------------------------------
# Cortafuegos
# ---------------------------------------------------------------------------

# Devuelve el puerto de sshd; no se leen los archivos de sshd_config.d.
detectar_puerto_ssh() {
    local puerto

    puerto="$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2; exit}' \
        /etc/ssh/sshd_config 2>/dev/null)"
    printf '%s\n' "${puerto:-22}"
}

# Añade a /etc/nftables.conf el include que carga las reglas al arrancar.
incluir_en_nftables_conf() {
    local conf="/etc/nftables.conf"
    local linea='include "/etc/nftables.d/*.nft"'

    if [[ ! -f "$conf" ]]; then
        printf '#!/usr/sbin/nft -f\n' > "$conf"
        chmod 755 "$conf"
    fi

    if grep -qF "$linea" "$conf"; then
        log_info "${conf} ya incluye /etc/nftables.d"
        return 0
    fi

    printf '\n%s\n' "$linea" >> "$conf"
    log_ok "añadido el include de /etc/nftables.d a ${conf}"
}

# Escribe el ruleset de mcsrv por la salida estándar.
generar_ruleset_nftables() {
    local puerto_ssh regla_reporte

    puerto_ssh="$(detectar_puerto_ssh)"

    if [[ -n "$ADMIN_IP" ]]; then
        regla_reporte="ip saddr ${ADMIN_IP} tcp dport ${REPORT_PORT} accept"
    else
        regla_reporte="tcp dport ${REPORT_PORT} accept"
    fi

    cat <<EOF
#!/usr/sbin/nft -f
# Generado por mcsrv. Cada deploy reescribe este archivo.

table inet mcsrv
delete table inet mcsrv

table inet mcsrv {
    set blocked_ips {
        type ipv4_addr
    }

    chain input {
        type filter hook input priority filter; policy drop;

        ip saddr @blocked_ips meta l4proto tcp reject with tcp reset
        ip saddr @blocked_ips drop

        ct state established,related accept
        ct state invalid drop

        iif lo accept

        tcp dport ${puerto_ssh} accept
        tcp dport ${SERVER_PORT} accept
        ${regla_reporte}
    }
}
EOF
}

# Guarda el ruleset en /etc/nftables.d y lo aplica.
configurar_nftables() {
    local archivo="/etc/nftables.d/mcsrv.nft"

    mkdir -p /etc/nftables.d
    generar_ruleset_nftables > "$archivo"
    chmod 640 "$archivo"

    incluir_en_nftables_conf

    nft -c -f "$archivo" || die "nft rechazó el ruleset de ${archivo}"
    nft -f "$archivo" || die "no se pudo aplicar el ruleset de ${archivo}"

    systemctl enable --now nftables.service >/dev/null 2>&1 ||
        log_warn "no se pudo habilitar nftables.service: las reglas no sobrevivirán al reinicio"

    log_ok "nftables activo: solo $(detectar_puerto_ssh)/tcp, ${SERVER_PORT}/tcp y ${REPORT_PORT}/tcp aceptados"
}

# ---------------------------------------------------------------------------
# Servicio del servidor
# ---------------------------------------------------------------------------

# Genera minecraft.service desde la plantilla y lo instala si cambió.
instalar_unit_minecraft() {
    local plantilla="${MCSRV_ROOT}/systemd/minecraft.service.tpl"
    local destino="/etc/systemd/system/minecraft.service"
    local temporal

    [[ -f "$plantilla" ]] || die "no se encontró la plantilla ${plantilla}"

    temporal="$(mktemp)"
    sed -e "s|__JAVA_BIN__|${JAVA_RESUELTO}|g" \
        -e "s|__JVM_XMS__|${JVM_XMS}|g" \
        -e "s|__JVM_XMX__|${JVM_XMX}|g" \
        -e "s|__SERVER_JAR__|${SERVER_JAR}|g" \
        -e "s|__SERVER_DIR__|${SERVER_DIR}|g" \
        -e "s|__SERVER_USER__|${SERVER_USER}|g" \
        "$plantilla" > "$temporal"

    if [[ -f "$destino" ]] && cmp -s "$temporal" "$destino"; then
        rm -f "$temporal"
        log_info "minecraft.service ya está al día"
        return 0
    fi

    install -m 644 "$temporal" "$destino"
    rm -f "$temporal"
    systemctl daemon-reload
    log_ok "minecraft.service instalado en ${destino}"
}

# Genera mcsrv-monitor.service desde la plantilla y lo instala si cambió.
instalar_unit_monitor() {
    local plantilla="${MCSRV_ROOT}/systemd/mcsrv-monitor.service.tpl"
    local destino="/etc/systemd/system/mcsrv-monitor.service"
    local temporal

    [[ -f "$plantilla" ]] || die "no se encontró la plantilla ${plantilla}"

    temporal="$(mktemp)"
    sed -e "s|__MCSRV_ROOT__|${MCSRV_ROOT}|g" \
        -e "s|__CONFIG__|${MCSRV_CONF_ACTIVO}|g" \
        "$plantilla" > "$temporal"

    if [[ -f "$destino" ]] && cmp -s "$temporal" "$destino"; then
        rm -f "$temporal"
        log_info "mcsrv-monitor.service ya está al día"
        return 0
    fi

    install -m 644 "$temporal" "$destino"
    rm -f "$temporal"
    systemctl daemon-reload
    log_ok "mcsrv-monitor.service instalado en ${destino}"
}

# Punto de entrada del comando stop: detiene el monitor y el servidor.
mcsrv_stop() {
    if systemctl is-active --quiet mcsrv-monitor.service; then
        systemctl stop mcsrv-monitor.service
        log_ok "monitor detenido"
    else
        log_info "el monitor ya estaba detenido"
    fi

    if systemctl is-active --quiet minecraft.service; then
        log_info "guardando el mundo y deteniendo el servidor..."
        systemctl stop minecraft.service
        log_ok "servidor detenido"
    else
        log_info "el servidor ya estaba detenido"
    fi
}

# Habilita y arranca el servicio del monitor.
activar_servicio_monitor() {
    systemctl enable mcsrv-monitor.service >/dev/null 2>&1 ||
        die "no se pudo habilitar mcsrv-monitor.service"

    systemctl restart mcsrv-monitor.service

    if systemctl is-active --quiet mcsrv-monitor.service; then
        log_ok "mcsrv-monitor.service en marcha"
    else
        log_warn "mcsrv-monitor.service no quedó activo; revisa: journalctl -u mcsrv-monitor -n 30"
    fi
}

# Deja eula.txt en true; el servidor no arranca sin eso.
aceptar_eula() {
    local eula="${SERVER_DIR}/eula.txt"

    if [[ -f "$eula" ]] && grep -qi '^eula[[:space:]]*=[[:space:]]*true' "$eula"; then
        log_info "el EULA de Mojang ya está aceptado"
        return 0
    fi

    printf '#By changing the setting below to TRUE you are indicating your agreement to our EULA (https://aka.ms/MinecraftEULA).\neula=true\n' > "$eula"
    chown "${SERVER_USER}:${SERVER_USER}" "$eula"
    chmod 644 "$eula"
    log_ok "EULA de Mojang aceptado en ${eula}"
}

# Habilita y arranca el servicio del servidor.
activar_servicio_minecraft() {
    aceptar_eula

    systemctl enable minecraft.service >/dev/null 2>&1 ||
        die "no se pudo habilitar minecraft.service"

    if systemctl is-active --quiet minecraft.service; then
        systemctl restart minecraft.service
        log_ok "minecraft.service reiniciado con la configuración nueva"
    else
        systemctl start minecraft.service
        log_ok "minecraft.service arrancado"
    fi

    if ! systemctl is-active --quiet minecraft.service; then
        log_warn "minecraft.service no quedó activo; revisa: journalctl -u minecraft -n 30"
        return 0
    fi

    esperar_puerto_servidor
}

# Espera a que el servidor abra su puerto tras cargar el mundo.
esperar_puerto_servidor() {
    local intentos=45

    log_info "esperando a que el servidor abra el puerto ${SERVER_PORT}..."
    while (( intentos > 0 )); do
        if puerto_en_escucha "$SERVER_PORT"; then
            log_ok "el servidor escucha en el puerto ${SERVER_PORT}"
            return 0
        fi
        sleep 2
        intentos=$(( intentos - 1 ))
    done

    log_warn "el servidor no abrió el puerto ${SERVER_PORT} en 90 s; revisa: journalctl -u minecraft -n 30"
}

# ---------------------------------------------------------------------------
# Reporte web
# ---------------------------------------------------------------------------

# Quita el sitio por defecto de nginx, que escucha en el puerto 80.
desactivar_sitio_por_defecto_nginx() {
    local enlace="/etc/nginx/sites-enabled/default"

    [[ -e "$enlace" ]] || return 0

    rm -f "$enlace"
    log_ok "desactivado el sitio por defecto de nginx (liberado el puerto 80)"
}

# Instala y habilita el sitio de nginx que publica el reporte.
configurar_nginx() {
    local plantilla="${MCSRV_ROOT}/nginx/mcsrv-report.conf.tpl"
    local disponible="/etc/nginx/sites-available/mcsrv-report"
    local habilitado="/etc/nginx/sites-enabled/mcsrv-report"

    [[ -f "$plantilla" ]] || die "no se encontró la plantilla ${plantilla}"

    mkdir -p "$REPORT_DIR"
    chmod 755 "$STATE_DIR" "$REPORT_DIR"

    if [[ ! -f "${REPORT_DIR}/index.html" ]]; then
        printf '%s\n' \
            '<!doctype html><meta charset="utf-8"><title>mcsrv</title>' \
            '<p>El reporte se genera cuando arranca el monitor.</p>' \
            > "${REPORT_DIR}/index.html"
        chmod 644 "${REPORT_DIR}/index.html"
    fi

    sed -e "s|__REPORT_PORT__|${REPORT_PORT}|g" \
        -e "s|__REPORT_DIR__|${REPORT_DIR}|g" \
        "$plantilla" > "$disponible"

    ln -sfn "$disponible" "$habilitado"

    desactivar_sitio_por_defecto_nginx

    nginx -t >/dev/null 2>&1 || die "nginx rechazó la configuración; revisa con: nginx -t"
    systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx ||
        die "no se pudo recargar nginx"

    log_ok "nginx sirve ${REPORT_DIR} en el puerto ${REPORT_PORT}"
}

# ---------------------------------------------------------------------------
# Verificación posterior
# ---------------------------------------------------------------------------

# Escanea el host con nmap y avisa de todo puerto abierto no previsto.
verificar_puertos_expuestos() {
    local ip esperados abiertos puerto fallo="no"

    ip="$(hostname -I | awk '{print $1}')"
    if [[ -z "$ip" ]]; then
        log_warn "no se pudo determinar la IP del host; se omite la verificación"
        return 0
    fi

    esperados=" $(detectar_puerto_ssh) ${SERVER_PORT} ${REPORT_PORT} "

    log_info "escaneando ${ip} con nmap (puede tardar un minuto)..."
    abiertos="$(nmap -Pn -p- --open "$ip" 2>/dev/null |
        awk '/^[0-9]+\/tcp/ {sub("/.*", "", $1); print $1}')"

    while read -r puerto; do
        [[ -n "$puerto" ]] || continue
        if [[ "$esperados" == *" ${puerto} "* ]]; then
            log_ok "puerto ${puerto}/tcp abierto (previsto)"
        else
            log_error "puerto ${puerto}/tcp abierto y NO previsto"
            fallo="si"
        fi
    done <<<"$abiertos"

    # El escaneo sale del propio host: comprueba qué escucha, no qué filtra.
    log_warn "escaneo local: para validar el filtrado, escanea desde otra máquina con 'nmap -Pn -p- ${ip}'"

    [[ "$fallo" == "no" ]]
}
