#!/bin/bash
# ============================================================================
# Core Script: core_ntp.sh
# SeederLinux Lite - Sincronizacao de horario (NTP adaptativo)
# ============================================================================
# Descobre, em runtime, qual cliente NTP funciona com o servidor da OM,
# sincroniza o relogio, e persiste o cliente vencedor para o
# seederlinux-sync-ntp reaproveitar em logons e reboots seguintes.
#
# CASCATA (mais simples para o mais robusto):
#   1. systemd-timesyncd   (default Ubuntu)
#   2. chrony              (classico)
#   3. ntpsec              (aceita w32time sem reclamar)
#   4. ntp (ISC)           (Debian classico)
#   5. ntpdate + cron      (step one-shot, paliativo)
#
# Lista de servidores (prioridade):
#   1. DC_IP (primario)
#   2. Cada DC em DC_IP_LIST
#   3. NTP_SERVER (fallback externo do painel)
#
# FAST PATH: se ntp-state.env tem NTP_CLIENT funcional, reaproveita
# sem reinstalar/desinstalar pacotes.
#
# PERSISTE ESTADO v2 em /etc/seederlinux/ntp-state.env
# ============================================================================

(
set -e

source /usr/local/lib/seederlinux/diag.sh 2>/dev/null || true
SCRIPT_ID="02-ntp"

echo "============================================================"
echo "Sincronizar horario (NTP adaptativo)"
echo "============================================================"

# ============================================================
# Variáveis
# ============================================================
NTP_SERVER="{{NTP_SERVER}}"
DNS_INTERNET="{{DNS_INTERNET}}"
DOMINIO="{{DOMINIO}}"
# Preferir valores do header do bundle; placeholders substituídos na geração
DC_IP="${DC_IP:-}"
DC_IP_LIST="${DC_IP_LIST:-}"
# Se o header não exportou, usar placeholders (substituídos pelo gerador)
[ -z "$DC_IP" ] && DC_IP="{{DC_IP}}"
[ -z "$DC_IP_LIST" ] && DC_IP_LIST="{{DC_IP_LIST}}"

# Remover protocolo indevido do NTP_SERVER
NTP_SERVER="${NTP_SERVER#http://}"
NTP_SERVER="${NTP_SERVER#https://}"

# Fallback: se DC_IP_LIST vazio, usar DC_IP
[ -z "$DC_IP_LIST" ] && DC_IP_LIST="$DC_IP"

NTP_STATE_DIR="/etc/seederlinux"
NTP_STATE_FILE="${NTP_STATE_DIR}/ntp-state.env"
mkdir -p "$NTP_STATE_DIR"

# ============================================================
# Funções auxiliares
# ============================================================

_construir_lista_ntp_servers() {
    local lista=""
    if [ -n "${DC_IP:-}" ] && [ "$DC_IP" != "" ]; then
        lista="$DC_IP"
    fi
    if [ -n "${DC_IP_LIST:-}" ] && [ "$DC_IP_LIST" != "" ]; then
        local dc
        for dc in $(echo "$DC_IP_LIST" | tr ',' ' '); do
            dc="$(echo "$dc" | xargs)"
            [ -z "$dc" ] && continue
            case ",$lista," in
                *",$dc,"*) ;;
                *) [ -z "$lista" ] && lista="$dc" || lista="$lista,$dc" ;;
            esac
        done
    fi
    if [ -n "${NTP_SERVER:-}" ] && [ "$NTP_SERVER" != "" ]; then
        case ",$lista," in
            *",$NTP_SERVER,"*) ;;
            *) [ -z "$lista" ] && lista="$NTP_SERVER" || lista="$lista,$NTP_SERVER" ;;
        esac
    fi
    echo "$lista"
}

_ntp_sincronizado() {
    if command -v timedatectl >/dev/null 2>&1; then
        if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ]; then
            return 0
        fi
    fi
    if command -v chronyc >/dev/null 2>&1; then
        if chronyc tracking 2>/dev/null | grep -q "Leap status.*Normal"; then
            return 0
        fi
    fi
    if command -v ntpq >/dev/null 2>&1; then
        if ntpq -p 2>/dev/null | grep -qE "^\*"; then
            return 0
        fi
    fi
    if [ -f /var/lib/seederlinux/ntpdate-last-ok ]; then
        local age
        age=$(( $(date +%s) - $(stat -c %Y /var/lib/seederlinux/ntpdate-last-ok 2>/dev/null || echo 0) ))
        [ "$age" -lt 900 ] && return 0
    fi
    return 1
}

_parar_todos_ntp() {
    for _svc in systemd-timesyncd chrony ntpsec ntp; do
        systemctl stop "$_svc" 2>/dev/null || true
    done
}

_iniciar_cliente() {
    case "$1" in
        systemd-timesyncd) systemctl restart systemd-timesyncd 2>/dev/null || true ;;
        chrony)            systemctl restart chrony 2>/dev/null || true ;;
        ntpsec)            systemctl restart ntpsec 2>/dev/null || true ;;
        ntp-isc)           systemctl restart ntp 2>/dev/null || true ;;
        ntpdate+cron)      : ;;
    esac
}

_reconfigurar_cliente() {
    local cliente="$1"
    local servers="$2"
    local s
    case "$cliente" in
        systemd-timesyncd)
            {
                echo "[Time]"
                echo "NTP=$(echo "$servers" | tr ',' ' ')"
                echo "FallbackNTP=$DNS_INTERNET"
            } > /etc/systemd/timesyncd.conf
            ;;
        chrony)
            {
                echo "# SeederLinux - chrony"
                for s in $(echo "$servers" | tr ',' ' '); do
                    echo "server $s iburst"
                done
                echo "driftfile /var/lib/chrony/chrony.drift"
                echo "makestep 1.0 3"
                echo "rtcsync"
            } > /etc/chrony/chrony.conf
            ;;
        ntpsec|ntp-isc)
            local conf="/etc/ntpsec/ntp.conf"
            [ "$cliente" = "ntp-isc" ] && conf="/etc/ntp.conf"
            {
                echo "# SeederLinux - $cliente"
                for s in $(echo "$servers" | tr ',' ' '); do
                    echo "server $s iburst"
                done
                echo "restrict -4 default kod notrap nomodify nopeer noquery limited"
                echo "restrict 127.0.0.1"
            } > "$conf"
            ;;
        ntpdate+cron)
            local primeiro
            primeiro="$(echo "$servers" | cut -d, -f1)"
            {
                echo "# SeederLinux - ntpdate (fallback)"
                echo "SHELL=/bin/bash"
                echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
                echo "*/5 * * * * root /usr/sbin/ntpdate -u $primeiro >/dev/null 2>&1 && touch /var/lib/seederlinux/ntpdate-last-ok"
            } > /etc/cron.d/seederlinux-ntpdate
            chmod 644 /etc/cron.d/seederlinux-ntpdate
            ;;
    esac
}

_persistir_estado_ok() {
    local servers_list
    servers_list="${NTP_SERVERS_CACHE:-$(_construir_lista_ntp_servers)}"
    local primary
    primary="$(echo "$servers_list" | cut -d, -f1)"
    local dc_list
    dc_list="$(echo "$servers_list" | tr ',' '\n' | grep -vxF "$NTP_SERVER" | paste -sd, -)"
    cat > "$NTP_STATE_FILE" <<EOF
# SeederLinux - Estado do NTP
# Gerado por core_ntp.sh em $(date -Is)
NTP_VERSION="2"
NTP_CLIENT="$NTP_CLIENT"
NTP_SERVERS="$servers_list"
NTP_SERVER_PRIMARY="$primary"
NTP_DC_LIST="$dc_list"
NTP_EXTERNAL_SERVER="$NTP_SERVER"
NTP_LAST_OK="$(date +%s)"
NTP_LAST_CHECK="$(date +%s)"
EOF
    chmod 644 "$NTP_STATE_FILE"
}

_persistir_estado_falha() {
    cat > "$NTP_STATE_FILE" <<EOF
# SeederLinux - Estado do NTP (NAO SINCRONIZADO)
# Gerado por core_ntp.sh em $(date -Is)
NTP_VERSION="2"
NTP_CLIENT=""
NTP_SERVERS="$(_construir_lista_ntp_servers)"
NTP_DC_LIST="$DC_IP_LIST"
NTP_EXTERNAL_SERVER="$NTP_SERVER"
NTP_LAST_OK="0"
NTP_LAST_CHECK="$(date +%s)"
NTP_LAST_FAIL="$(date +%s)"
EOF
    chmod 644 "$NTP_STATE_FILE"
}

# ============================================================
# Lista de servidores e validação
# ============================================================
SERVERS_LIST="$(_construir_lista_ntp_servers)"
log_nivel INFO "Lista NTP: $SERVERS_LIST"
log_nivel INFO "Fallback DNS: $DNS_INTERNET"

if [ -z "$SERVERS_LIST" ]; then
    log_nivel AVISO "Nenhum servidor NTP disponivel (DC_IP, DC_IP_LIST e NTP_SERVER vazios)."
    log_nivel ACAO  "Defina DC_IP ou NTP_SERVER no painel."
    exit 0
fi

# ============================================================
# FAST PATH: reaproveitar cliente vencedor do bundle anterior
# ============================================================
NTP_FAST_PATH=false
NTP_RESULT=""
NTP_CLIENT=""
NTP_SERVERS_CACHE=""

if [ -f "$NTP_STATE_FILE" ] && [ "${SEEDER_NTP_FORCE_CASCADE:-false}" != "true" ]; then
    # shellcheck disable=SC1090
    . "$NTP_STATE_FILE"
    if [ -n "${NTP_CLIENT:-}" ]; then
        log_nivel INFO "Cliente NTP em cache: $NTP_CLIENT"
        servers_atual="$(_construir_lista_ntp_servers)"
        if [ "$servers_atual" != "${NTP_SERVERS:-}" ]; then
            log_nivel INFO "Lista NTP mudou: '${NTP_SERVERS:-}' -> '$servers_atual'"
            _parar_todos_ntp
            _reconfigurar_cliente "$NTP_CLIENT" "$servers_atual"
        else
            _parar_todos_ntp
            _iniciar_cliente "$NTP_CLIENT"
        fi
        log_nivel TESTE "Verificando se $NTP_CLIENT ainda funciona (10s)..."
        for i in 1 2 3 4 5; do
            sleep 2
            if _ntp_sincronizado; then
                log_nivel OK "$NTP_CLIENT ainda funcional - pulando cascata"
                log_nivel INFO "Lista: $servers_atual"
                NTP_FAST_PATH=true
                NTP_RESULT=OK
                NTP_SERVERS_CACHE="$servers_atual"
                break
            fi
        done
        if [ "$NTP_FAST_PATH" != "true" ]; then
            log_nivel AVISO "$NTP_CLIENT parou de funcionar - rodando cascata completa"
            NTP_CLIENT=""
            NTP_RESULT=""
        fi
    fi
fi

if [ "$NTP_FAST_PATH" = "true" ]; then
    _persistir_estado_ok
    log_nivel OK "NTP configurado (fast path)!"
    echo "============================================================"
    exit 0
fi

PRIMARY="$(echo "$SERVERS_LIST" | cut -d, -f1)"
log_nivel TESTE "Pre-flight: testando alcance de $PRIMARY"

if command -v ping >/dev/null 2>&1; then
    if ping -c 2 -W 2 "$PRIMARY" >/dev/null 2>&1; then
        log_nivel OK    "L3 (ICMP): $PRIMARY responde"
    else
        log_nivel AVISO "L3 (ICMP): $PRIMARY NAO responde a ping"
        log_nivel DIAG  "Isso NAO impede NTP - muitos servidores bloqueiam ICMP"
    fi
fi

if ! command -v ntpdate >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y ntpdate 2>/dev/null || true
fi

log_nivel TESTE "Probe: testando comunicacao com $PRIMARY"

NTP_PROBE_OK=false
NTP_PROBE_METHOD=""

if command -v ntpdate >/dev/null 2>&1; then
    if ntpdate -q "$PRIMARY" 2>&1 | grep -qE 'server|offset|stratum'; then
        NTP_PROBE_OK=true
        NTP_PROBE_METHOD="ntpdate -q"
    fi
fi

if [ "$NTP_PROBE_OK" != "true" ] && command -v ntpdig >/dev/null 2>&1; then
    if ntpdig -t 5 "$PRIMARY" 2>&1 | grep -qE 'reply|offset|stratum'; then
        NTP_PROBE_OK=true
        NTP_PROBE_METHOD="ntpdig"
    fi
fi

if [ "$NTP_PROBE_OK" = "true" ]; then
    log_nivel OK "Probe OK via $NTP_PROBE_METHOD"
else
    log_nivel AVISO "Probe nao conseguiu confirmar conversacao SNTP"
fi

_try_systemd_timesyncd() {
    log_nivel TENT  "Tentativa 1/5: systemd-timesyncd"
    if ! systemctl list-unit-files systemd-timesyncd.service >/dev/null 2>&1; then
        return 1
    fi
    _parar_todos_ntp
    if [ -f /etc/systemd/timesyncd.conf ] || [ -d /etc/systemd ]; then
        cp /etc/systemd/timesyncd.conf /etc/systemd/timesyncd.conf.bak.$(date +%s) 2>/dev/null || true
        {
            echo "[Time]"
            echo "NTP=$(echo "$SERVERS_LIST" | tr ',' ' ')"
            echo "FallbackNTP=$DNS_INTERNET"
        } > /etc/systemd/timesyncd.conf
    fi
    systemctl enable systemd-timesyncd 2>/dev/null || true
    systemctl restart systemd-timesyncd 2>/dev/null || true
    for i in $(seq 1 10); do
        sleep 2
        if _ntp_sincronizado; then
            log_nivel OK "Sincronizado em $((i*2))s via systemd-timesyncd"
            return 0
        fi
    done
    return 1
}

_try_chrony() {
    log_nivel TENT  "Tentativa 2/5: chrony"
    if ! command -v chronyd >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y chrony 2>/dev/null || return 1
    fi
    _parar_todos_ntp
    {
        echo "# SeederLinux - chrony"
        for s in $(echo "$SERVERS_LIST" | tr ',' ' '); do
            echo "server $s iburst trust"
        done
        echo "driftfile /var/lib/chrony/chrony.drift"
        echo "makestep 1.0 3"
        echo "rtcsync"
    } > /etc/chrony/chrony.conf
    systemctl enable chrony 2>/dev/null || true
    systemctl restart chrony 2>/dev/null || true
    for i in $(seq 1 10); do
        sleep 2
        chronyc makestep 2>/dev/null || true
        if _ntp_sincronizado; then
            log_nivel OK "Sincronizado em $((i*2))s via chrony"
            return 0
        fi
    done
    return 1
}

_try_ntpsec() {
    log_nivel TENT  "Tentativa 3/5: ntpsec"
    if ! dpkg -l ntpsec 2>/dev/null | grep -q "^ii"; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y ntpsec 2>/dev/null || return 1
    fi
    _parar_todos_ntp
    {
        echo "# SeederLinux - NTPsec"
        for s in $(echo "$SERVERS_LIST" | tr ',' ' '); do
            echo "server $s iburst"
        done
        echo "driftfile /var/lib/ntpsec/ntp.drift"
        echo "restrict -4 default kod notrap nomodify nopeer noquery limited"
        echo "restrict 127.0.0.1"
    } > /etc/ntpsec/ntp.conf
    systemctl enable ntpsec 2>/dev/null || true
    systemctl restart ntpsec 2>/dev/null || true
    for i in $(seq 1 10); do
        sleep 2
        if _ntp_sincronizado; then
            log_nivel OK "Sincronizado em $((i*2))s via ntpsec"
            return 0
        fi
    done
    return 1
}

_try_ntp_isc() {
    log_nivel TENT  "Tentativa 4/5: ntp ISC"
    if dpkg -l ntpsec 2>/dev/null | grep -q "^ii"; then
        DEBIAN_FRONTEND=noninteractive apt-get remove -y ntpsec 2>/dev/null || true
    fi
    if ! dpkg -l ntp 2>/dev/null | grep -q "^ii"; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y ntp 2>/dev/null || return 1
    fi
    _parar_todos_ntp
    {
        echo "# SeederLinux - ntp ISC"
        for s in $(echo "$SERVERS_LIST" | tr ',' ' '); do
            echo "server $s iburst"
        done
        echo "driftfile /var/lib/ntp/ntp.drift"
        echo "restrict default kod nomodify notrap nopeer noquery"
        echo "restrict 127.0.0.1"
    } > /etc/ntp.conf
    systemctl enable ntp 2>/dev/null || true
    systemctl restart ntp 2>/dev/null || true
    for i in $(seq 1 10); do
        sleep 2
        if _ntp_sincronizado; then
            log_nivel OK "Sincronizado em $((i*2))s via ntp ISC"
            return 0
        fi
    done
    return 1
}

_try_ntpdate_cron() {
    log_nivel TENT  "Tentativa 5/5: ntpdate + cron"
    if ! command -v ntpdate >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y ntpdate 2>/dev/null || return 1
    fi
    _parar_todos_ntp
    local primeiro
    primeiro="$(echo "$SERVERS_LIST" | cut -d, -f1)"
    local _out
    _out="$(ntpdate -u "$primeiro" 2>&1 || true)"
    if echo "$_out" | grep -qiE "step|adjust"; then
        mkdir -p /var/lib/seederlinux
        touch /var/lib/seederlinux/ntpdate-last-ok
        cat > /etc/cron.d/seederlinux-ntpdate <<EOF
# SeederLinux - paliativo ntpdate
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * root /usr/sbin/ntpdate -u $primeiro >/dev/null 2>&1 && touch /var/lib/seederlinux/ntpdate-last-ok
EOF
        chmod 644 /etc/cron.d/seederlinux-ntpdate
        return 0
    fi
    return 1
}

if _try_systemd_timesyncd; then
    NTP_RESULT=OK; NTP_CLIENT="systemd-timesyncd"
elif _try_chrony; then
    NTP_RESULT=OK; NTP_CLIENT="chrony"
elif _try_ntpsec; then
    NTP_RESULT=OK; NTP_CLIENT="ntpsec"
elif _try_ntp_isc; then
    NTP_RESULT=OK; NTP_CLIENT="ntp-isc"
elif _try_ntpdate_cron; then
    NTP_RESULT=OK; NTP_CLIENT="ntpdate+cron"
fi

echo ""
log_nivel TESTE "Validacao final: 3 leituras..."
_confirmacoes=0
for _i in 1 2 3; do
    sleep 1
    if _ntp_sincronizado; then
        _confirmacoes=$((_confirmacoes + 1))
    fi
done
log_nivel INFO "Confirmacoes: $_confirmacoes/3"

if [ "$NTP_RESULT" = "OK" ] && [ "$_confirmacoes" -ge 2 ]; then
    log_nivel OK "NTP validado: $NTP_CLIENT"
    NTP_SERVERS_CACHE="$SERVERS_LIST"
    _persistir_estado_ok
elif [ "$NTP_RESULT" = "OK" ]; then
    log_nivel AVISO "validacao falhou"
    _persistir_estado_falha
else
    log_nivel ERRO "NTP NAO sincronizou"
    _persistir_estado_falha
fi

log_nivel OK "NTP configurado!"
echo "============================================================"
)
