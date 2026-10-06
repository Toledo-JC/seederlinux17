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
# Cada tentativa tem timeout de 20s. Só avanca se nao sincronizar.
#
# DEPENDE DE ESTAR NA FASE 1 (DNS de internet ativo): se o cliente
# default falhar, esta script instala outro cliente via apt, o que
# exige internet. Por isso roda ANTES do core_domain.sh.
#
# PERSISTE ESTADO em /etc/seederlinux/ntp-state.env:
#   NTP_CLIENT=<cliente vencedor>
#   NTP_SERVER=<servidor>
#   NTP_LAST_OK=<epoch>
#
# Os placeholders VARIAVEL sao substituidos automaticamente
# pelo sistema na geracao do bundle.
# ============================================================================

set -e

echo "============================================================"
echo "02 - Sincronizacao de horario (NTP adaptativo)"
echo "============================================================"

# ============================================================
# Variáveis
# ============================================================
NTP_SERVER="{{NTP_SERVER}}"
DNS_INTERNET="{{DNS_INTERNET}}"
DOMINIO="{{DOMINIO}}"

# Remover protocolo indevido do NTP_SERVER (a OM pode ter cadastrado
# "http://host" em vez de "host"; normalizamos aqui para nao quebrar
# o chrony/ntp, que esperam apenas hostname/IP).
NTP_SERVER="${NTP_SERVER#http://}"
NTP_SERVER="${NTP_SERVER#https://}"

NTP_STATE_DIR="/etc/seederlinux"
NTP_STATE_FILE="${NTP_STATE_DIR}/ntp-state.env"
mkdir -p "$NTP_STATE_DIR"

# ============================================================
# Helpers de log estruturado (prefixo literal - o lib/diag.sh
# será usado a partir do Commit 3, quando todos os scripts forem
# instrumentados juntos).
# ============================================================
_dns_tag="02-ntp"
log_dns() { local _nivel="$1"; shift; printf '[%-5s] [%s] %s\n' "$_nivel" "$_dns_tag" "$*"; }

# ============================================================
# Exibir informacoes
# ============================================================
echo ">>> Servidor NTP: $NTP_SERVER"
echo ">>> Fallback:     $DNS_INTERNET"

if [ -z "$NTP_SERVER" ] || [ "$NTP_SERVER" = "" ]; then
    log_dns AVISO "NTP_SERVER vazio. Pulando configuracao NTP."
    log_dns ACAO  "Defina NTP_SERVER no painel (IP ou FQDN do servidor NTP/DC)."
    exit 0
fi

# ============================================================
# Pre-flight: L3 (informativo apenas - ICMP bloqueado nao impede NTP)
# ============================================================
log_dns TESTE "Pre-flight: testando alcance do servidor NTP $NTP_SERVER"

if command -v ping >/dev/null 2>&1; then
    if ping -c 2 -W 2 "$NTP_SERVER" >/dev/null 2>&1; then
        log_dns OK    "L3 (ICMP): $NTP_SERVER responde"
    else
        log_dns AVISO "L3 (ICMP): $NTP_SERVER NAO responde a ping"
        log_dns DIAG  "Isso NAO impede NTP - muitos servidores bloqueiam ICMP"
        log_dns DIAG  "Prosseguindo para o teste NTP real"
    fi
fi

# ============================================================
# Funções auxiliares
# ============================================================

# Verifica se o relogio esta sincronizado (por QUALQUER cliente)
_ntp_sincronizado() {
    # systemd-timesyncd
    if [ "$(timedatectl show --property=NTPSynchronized --value 2>/dev/null)" = "yes" ]; then
        return 0
    fi
    # chrony
    if command -v chronyc >/dev/null 2>&1; then
        if chronyc tracking 2>/dev/null | grep -q "Leap status.*Normal"; then
            return 0
        fi
    fi
    # ntpsec / isc ntp
    if command -v ntpq >/dev/null 2>&1; then
        if ntpq -p 2>/dev/null | grep -qE "^\*"; then
            return 0
        fi
    fi
    return 1
}

# Para todos os daemons NTP conhecidos (garante exclusividade mutua)
_parar_todos_ntp() {
    for _svc in systemd-timesyncd chrony ntpsec ntp; do
        systemctl stop "$_svc" 2>/dev/null || true
        systemctl disable "$_svc" 2>/dev/null || true
    done
}

# ============================================================
# Tentativa 1: systemd-timesyncd
# ============================================================
_try_systemd_timesyncd() {
    log_dns TENT  "Tentativa 1/5: systemd-timesyncd (default Ubuntu)"

    if ! systemctl list-unit-files systemd-timesyncd.service >/dev/null 2>&1; then
        log_dns DIAG  "systemd-timesyncd nao disponivel nesta distro"
        return 1
    fi

    _parar_todos_ntp

    if [ -f /etc/systemd/timesyncd.conf ]; then
        cp /etc/systemd/timesyncd.conf /etc/systemd/timesyncd.conf.bak.$(date +%s) 2>/dev/null || true
        cat > /etc/systemd/timesyncd.conf <<EOF
[Time]
NTP=$NTP_SERVER
FallbackNTP=$DNS_INTERNET
EOF
        log_dns DIAG  "Config: /etc/systemd/timesyncd.conf -> NTP=$NTP_SERVER"
    fi

    systemctl enable systemd-timesyncd 2>/dev/null || true
    systemctl restart systemd-timesyncd 2>/dev/null || true

    log_dns TESTE "Aguardando 20s por sincronizacao..."
    for i in $(seq 1 10); do
        sleep 2
        if _ntp_sincronizado; then
            log_dns OK    "Sincronizado em $((i*2))s via systemd-timesyncd"
            return 0
        fi
    done
    log_dns AVISO "systemd-timesyncd nao sincronizou em 20s"
    log_dns DIAG  "Provavel causa: DC Windows (w32time) incompativel com systemd-timesyncd"
    return 1
}

# ============================================================
# Tentativa 2: chrony
# ============================================================
_try_chrony() {
    log_dns TENT  "Tentativa 2/5: chrony"

    if ! command -v chronyd >/dev/null 2>&1; then
        log_dns DIAG  "chrony nao instalado - instalando..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y chrony 2>/dev/null || {
            log_dns AVISO "Falha ao instalar chrony. Pulando."
            return 1
        }
    fi

    _parar_todos_ntp

    cat > /etc/chrony/chrony.conf <<EOF
server $NTP_SERVER iburst trust
driftfile /var/lib/chrony/chrony.drift
makestep 1.0 3
rtcsync
EOF
    log_dns DIAG  "Config: /etc/chrony/chrony.conf -> server $NTP_SERVER iburst trust"

    systemctl enable chrony 2>/dev/null || true
    systemctl restart chrony 2>/dev/null || true

    log_dns TESTE "Aguardando 20s por sincronizacao..."
    for i in $(seq 1 10); do
        sleep 2
        chronyc makestep 2>/dev/null || true
        if _ntp_sincronizado; then
            log_dns OK    "Sincronizado em $((i*2))s via chrony"
            return 0
        fi
    done
    log_dns AVISO "chrony nao sincronizou em 20s"
    log_dns DIAG  "chronyc sources abaixo (para o tecnico ver o motivo):"
    chronyc sources -v 2>/dev/null | sed 's/^/    /' || true
    log_dns DIAG  "Causa tipica: DC Windows se declara stratum 1 sem refid valido"
    log_dns DIAG  "chrony rejeita por padrao. NTPsec aceita. Avancando."
    return 1
}

# ============================================================
# Tentativa 3: ntpsec
# ============================================================
_try_ntpsec() {
    log_dns TENT  "Tentativa 3/5: ntpsec"

    if ! dpkg -l ntpsec 2>/dev/null | grep -q "^ii"; then
        log_dns DIAG  "ntpsec nao instalado - instalando..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y ntpsec 2>/dev/null || {
            log_dns AVISO "Falha ao instalar ntpsec. Pulando."
            return 1
        }
    fi

    _parar_todos_ntp

    cat > /etc/ntpsec/ntp.conf <<EOF
# SeederLinux - NTPsec
server $NTP_SERVER iburst
driftfile /var/lib/ntpsec/ntp.drift
restrict -4 default kod notrap nomodify nopeer noquery limited
restrict -6 default kod notrap nomodify nopeer noquery limited
restrict 127.0.0.1
EOF
    log_dns DIAG  "Config: /etc/ntpsec/ntp.conf -> server $NTP_SERVER iburst"

    systemctl enable ntpsec 2>/dev/null || true
    systemctl restart ntpsec 2>/dev/null || true

    log_dns TESTE "Aguardando 20s por sincronizacao..."
    for i in $(seq 1 10); do
        sleep 2
        if _ntp_sincronizado; then
            log_dns OK    "Sincronizado em $((i*2))s via ntpsec"
            return 0
        fi
    done
    log_dns AVISO "ntpsec nao sincronizou em 20s"
    log_dns DIAG  "ntpq -p abaixo:"
    ntpq -p 2>/dev/null | sed 's/^/    /' || true
    return 1
}

# ============================================================
# Tentativa 4: ntp (ISC classico)
# ============================================================
_try_ntp_isc() {
    log_dns TENT  "Tentativa 4/5: ntp (ISC classico)"

    # Se ntpsec esta instalado, ele ja fornece /usr/sbin/ntpd.
    # Removemos ntpsec antes de instalar o ntp ISC para evitar conflito.
    if dpkg -l ntpsec 2>/dev/null | grep -q "^ii"; then
        log_dns DIAG  "Removendo ntpsec para instalar ntp ISC..."
        DEBIAN_FRONTEND=noninteractive apt-get remove -y ntpsec 2>/dev/null || true
    fi

    if ! dpkg -l ntp 2>/dev/null | grep -q "^ii"; then
        log_dns DIAG  "ntp ISC nao instalado - instalando..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y ntp 2>/dev/null || {
            log_dns AVISO "Falha ao instalar ntp ISC. Pulando."
            return 1
        }
    fi

    _parar_todos_ntp

    cat > /etc/ntp.conf <<EOF
server $NTP_SERVER iburst
driftfile /var/lib/ntp/ntp.drift
restrict default kod nomodify notrap nopeer noquery
restrict 127.0.0.1
EOF
    log_dns DIAG  "Config: /etc/ntp.conf -> server $NTP_SERVER iburst"

    systemctl enable ntp 2>/dev/null || true
    systemctl restart ntp 2>/dev/null || true

    log_dns TESTE "Aguardando 20s por sincronizacao..."
    for i in $(seq 1 10); do
        sleep 2
        if _ntp_sincronizado; then
            log_dns OK    "Sincronizado em $((i*2))s via ntp ISC"
            return 0
        fi
    done
    log_dns AVISO "ntp ISC nao sincronizou em 20s"
    return 1
}

# ============================================================
# Tentativa 5: ntpdate + cron (ultimo recurso)
# ============================================================
_try_ntpdate_cron() {
    log_dns TENT  "Tentativa 5/5: ntpdate + cron (step one-shot)"

    if ! command -v ntpdate >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y ntpdate 2>/dev/null || {
            log_dns AVISO "Falha ao instalar ntpdate. Desistindo."
            return 1
        }
    fi

    _parar_todos_ntp

    log_dns TESTE "Executando ntpdate -u $NTP_SERVER (step unico)..."
    local _out
    _out="$(ntpdate -u "$NTP_SERVER" 2>&1 || true)"
    echo "$_out" | sed 's/^/    /'

    if echo "$_out" | grep -qiE "step|adjust"; then
        log_dns OK    "Relogio ajustado via ntpdate"
        log_dns DIAG  "ntpdate e' one-shot; sera reagendado via cron a cada 5min"
        log_dns DIAG  "Isso NAO substitui um daemon NTP - e' paliativo"
        log_dns ACAO  "Corrigir o NTP do servidor ($NTP_SERVER) para o daemon funcionar"

        mkdir -p /var/lib/seederlinux
        touch /var/lib/seederlinux/ntpdate-last-ok

        cat > /etc/cron.d/seederlinux-ntpdate <<EOF
# SeederLinux - paliativo ntpdate
# Reagenda step a cada 5min porque nenhum daemon NTP funcionou.
# Remova quando o servidor NTP estiver respondendo corretamente.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * root /usr/sbin/ntpdate -u $NTP_SERVER >/dev/null 2>&1 && touch /var/lib/seederlinux/ntpdate-last-ok
EOF
        chmod 644 /etc/cron.d/seederlinux-ntpdate
        return 0
    fi
    log_dns AVISO "ntpdate falhou"
    return 1
}

# ============================================================
# Executa a cascata
# ============================================================
NTP_RESULT=""
NTP_CLIENT=""

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

# ============================================================
# Resultado
# ============================================================
echo ""
if [ "$NTP_RESULT" = "OK" ]; then
    log_dns OK    "NTP sincronizado via: $NTP_CLIENT"
    log_dns DIAG  "Horario local: $(date -Is)"

    cat > "$NTP_STATE_FILE" <<EOF
# SeederLinux - Estado do NTP
# Gerado por core_ntp.sh em $(date -Is)
NTP_CLIENT="$NTP_CLIENT"
NTP_SERVER="$NTP_SERVER"
NTP_LAST_OK="$(date +%s)"
EOF
    chmod 644 "$NTP_STATE_FILE"
else
    log_dns ERRO  "NTP NAO sincronizou com nenhum dos 5 clientes"
    log_dns DIAG  "Causas mais provaveis:"
    log_dns DIAG  "  1. Firewall do servidor bloqueando UDP/123 inbound"
    log_dns DIAG  "  2. w32time (Windows) desconfigurado no servidor"
    log_dns DIAG  "  3. Servidor NTP incorreto no painel"
    log_dns DIAG  "  4. Rede L3 indisponivel entre estacao e servidor"
    log_dns ACAO  "No servidor (Windows, como admin): w32tm /query /status"
    log_dns ACAO  "Abrir firewall UDP 123 inbound no servidor"
    log_dns ACAO  "Na estacao: ntpdate -q $NTP_SERVER"
    log_dns DIAG  "O bundle continua, mas Kerberos pode falhar com 'Clock skew too great'"

    cat > "$NTP_STATE_FILE" <<EOF
# SeederLinux - Estado do NTP (NAO SINCRONIZADO)
# Gerado por core_ntp.sh em $(date -Is)
NTP_CLIENT=""
NTP_SERVER="$NTP_SERVER"
NTP_LAST_OK="0"
NTP_LAST_FAIL="$(date +%s)"
EOF
    chmod 644 "$NTP_STATE_FILE"
fi

echo ">>> [02] NTP configurado!"
echo "============================================================"
