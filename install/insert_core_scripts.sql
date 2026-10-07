-- ============================================================================
-- SeederLinux Lite - Insercao dos Scripts Core
-- ============================================================================
-- Este arquivo popula a tabela 'scripts' com todos os scripts Core.
-- Gerado automaticamente a partir dos arquivos em scripts/core/.
--
-- ESCAPING: Usa dollar-quoting do PostgreSQL ($SeederScript$) para o conteudo
-- dos scripts, eliminando problemas com aspas simples, aspas duplas,
-- backslashes e qualquer outro caractere especial no bash.
-- ============================================================================

-- Limpar scripts core existentes (opcional - descomente se necessario)
-- DELETE FROM scripts WHERE is_core = TRUE;


-- ============================================================================
-- DNS e resolucao de nomes (ordem 1) - core_dns.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, depends_on, version, organization_id)
VALUES (
    'DNS e resolucao de nomes',
    'core_dns.sh',
    'Configura DNS temporario e /etc/hosts. Roda ANTES de repositorios para permitir apt-get update.',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_dns.sh
# SeederLinux Lite - DNS e resolucao de nomes
# ============================================================================
# Configura DNS temporario para permitir resolucao durante o
# provisionamento e ajusta /etc/resolv.conf, /etc/hosts e hostname.
# NTP foi movido para core_ntp.sh (script 02).
#
# CONTRATO DE FASES DO BUNDLE:
#   Fase 1 (este script, etapa 01): DNS de internet na frente. Permite
#     apt-get/wget nos scripts 03..06 (repositorios, pacotes, legados,
#     apps).
#   Fase 2 (core_domain.sh, etapa 07): reescreve /etc/resolv.conf
#     apontando SOMENTE para DNS_PRIMARIO + DNS_SECUNDARIO do AD.
#   Fase 3 (scripts 08..24): DNS do AD mantido, sem apt-get.
#
# Este script NAO trava o resolv.conf com chattr +i - quem faz isso e'
# o core_domain.sh, na Fase 2. Este script apenas REMOVE a trava antes
# de escrever, para nao abortar sob `set -e` quando o bundle roda de
# novo numa estacao ja ingressada.
#
# Os placeholders VARIAVEL são substituídos automaticamente
# pelo sistema na geração do bundle.
# ============================================================================

set -e

source /usr/local/lib/seederlinux/diag.sh 2>/dev/null || true
SCRIPT_ID="01-dns"

echo "============================================================"
echo "Configurar DNS e resolucao de nomes"
echo "============================================================"

# ============================================================
# Variáveis
# ============================================================
DOMINIO="{{DOMINIO}}"
DC_IP="{{DC_IP}}"
DC_IP_LIST="{{DC_IP_LIST}}"
DNS_PRIMARIO="{{DNS_PRIMARIO}}"
DNS_SECUNDARIO="{{DNS_SECUNDARIO}}"
DNS_INTERNET="{{DNS_INTERNET}}"
OM_ACRONYM="{{OM_ACRONYM}}"
NON_INTERACTIVE="${NON_INTERACTIVE:-false}"

# ============================================================
# Exibir informacoes
# ============================================================
log_nivel INFO "Dominio: $DOMINIO"
log_nivel INFO "DNS primario: $DNS_PRIMARIO"
log_nivel INFO "DNS secundario: ${DNS_SECUNDARIO}"

# ============================================================
# Hostname interativo
# ============================================================
CURRENT_HOSTNAME=$(hostname)
log_nivel INFO "Hostname atual: $CURRENT_HOSTNAME"

if [ "$NON_INTERACTIVE" = "true" ]; then
    CHANGE_HOST="n"
else
    read -p ">>> Deseja alterar o hostname? (s/N): " CHANGE_HOST
fi

if [[ "$CHANGE_HOST" =~ ^[Ss]$ ]]; then
    if [ "$NON_INTERACTIVE" = "true" ]; then
        log_nivel INFO "Modo não interativo: mantendo hostname atual."
    else
        read -p ">>> Novo hostname: " NEW_HOSTNAME
        hostnamectl set-hostname "$NEW_HOSTNAME"
        log_nivel INFO "Hostname alterado para: $NEW_HOSTNAME"
    fi
fi

HOSTNAME_SHORT=$(hostname | cut -d. -f1)
HOSTNAME_FQDN="${HOSTNAME_SHORT}.${DOMINIO}"

# ============================================================
# FASE 1 — DNS TEMPORARIO (internet primeiro)
# ============================================================
# Escreve DNS_INTERNET na frente, seguido de DNS_PRIMARIO/SECUNDARIO
# do AD como fallback. Isso permite que apt-get/wget dos scripts
# 02..05 funcionem mesmo se o DNS de internet estiver momentaneamente
# indisponivel (o glibc so passa para o proximo nameserver em timeout,
# nao em NXDOMAIN - por isso a ordem importa).
#
# Idempotente: roda N vezes sem problema. Sempre destrava o arquivo
# antes (chattr -i), trata o caso de symlink do systemd-resolved e
# reescreve do zero.
# ============================================================
log_nivel INFO "Configurando DNS temporario (Fase 1: internet primeiro para baixar pacotes)..."

# 1) Remover imutabilidade eventualmente deixada pelo core_domain.sh
#    (Fase 2 usa chattr +i para proteger o resolv.conf do AD).
chattr -i /etc/resolv.conf 2>/dev/null || true

# 2) Se /etc/resolv.conf for symlink (systemd-resolved), remover o
#    symlink. Sem isso, o `>` abaixo seguiria o link e escreveria
#    no alvo do symlink (geralmente /run/systemd/resolve/...), nao
#    no arquivo real.
if [ -L /etc/resolv.conf ]; then
    rm -f /etc/resolv.conf
fi

# 3) Escrever o resolv.conf da Fase 1. Cada nameserver e' incluido
#    apenas se a variavel estiver preenchida - evita linhas
#    "nameserver " (vazias) que confundem o glibc.
{
    echo "# SeederLinux - Fase 1 (DNS de internet temporario)"
    echo "# Sera reescrito pelo core_domain.sh (script 07) na Fase 2."
    echo "# Gerado em: $(date -Is)"
    if [ -n "$DNS_INTERNET" ] && [ "$DNS_INTERNET" != "" ]; then
        echo "nameserver $DNS_INTERNET"
    fi
    if [ -n "$DNS_PRIMARIO" ] && [ "$DNS_PRIMARIO" != "" ]; then
        echo "nameserver $DNS_PRIMARIO"
    fi
    if [ -n "$DNS_SECUNDARIO" ] && [ "$DNS_SECUNDARIO" != "" ]; then
        echo "nameserver $DNS_SECUNDARIO"
    fi
    if [ -n "$DOMINIO" ] && [ "$DOMINIO" != "" ]; then
        echo "search $DOMINIO"
    fi
    echo "options timeout:2 attempts:2"
} > /etc/resolv.conf

# 4) Modo canonico: world-readable. O arquivo e' lido por qualquer
#    processo (glibc, apt, wget, sssd), precisa ser 644.
chmod 644 /etc/resolv.conf

# 5) Log do conteudo real (util para debug em bundle)
log_nivel INFO "DNS temporario configurado:"
sed 's/^/    /' /etc/resolv.conf

# ============================================================
# /etc/hosts - garantir resolucao do proprio host e do dominio
# ============================================================
log_nivel INFO "Configurando /etc/hosts..."

cp /etc/hosts /etc/hosts.bak.$(date +%Y%m%d%H%M%S) 2>/dev/null || true

cat > /etc/hosts <<EOF
127.0.0.1   localhost
127.0.1.1   ${HOSTNAME_FQDN} ${HOSTNAME_SHORT}

# Controladores de dominio
EOF

# Adiciona todos os DCs no /etc/hosts
DC_HOSTNAME="dc-${OM_ACRONYM,,}"
for DC in $DC_IP_LIST; do
    [ -z "$DC" ] && continue
    echo "$DC    ${DC_HOSTNAME}.${DOMINIO} ${DC_HOSTNAME}" >> /etc/hosts
done

log_nivel INFO "/etc/hosts configurado"

# ============================================================
# Aviso de contexto: sem mirror local
# ============================================================
# Este script prepara a Fase 1 (DNS de internet ativo). O NTP
# agora roda no core_ntp.sh (script 02), logo apos este.
#
# Se REPOSITORY_MODE=PUBLIC, a estacao depende de internet real
# para baixar pacotes nos scripts 03..06. Se a OM tem mirror
# interno (MIRROR_LOCAL_SEEDER ou MIRROR_LOCAL_OM), a Fase 1 pode
# ser mais curta.
#
# IMPORTANTE: o core_ntp.sh (02) PRECISA vir antes do
# core_domain.sh (07), porque:
#   - NTP depende de apt (na Fase 1) para instalar chrony/ntpsec
#     se o cliente default falhar.
#   - Kerberos (no core_domain.sh) depende de clock sincronizado.
# Se um tecnico reordenar os scripts na UI, manter essa restricao.
# ============================================================
if [ "${REPOSITORY_MODE:-PUBLIC}" = "PUBLIC" ]; then
    log_nivel INFO "REPOSITORY_MODE=PUBLIC (sem mirror local)"
    log_nivel INFO "Fase 1 exige internet real (DNS de internet na frente)"
    log_nivel DIAG "Se a OM tiver mirror interno, mudar REPOSITORY_MODE no painel"
    log_nivel DIAG "Ordem obrigatoria: core_dns (01) antes de core_ntp (02) antes de core_domain (07)"
fi

log_nivel OK "DNS e resolucao de nomes configurados!"
echo "============================================================"
$SeederScript$,
    TRUE,
    TRUE,
    1,
    ARRAY[]::TEXT[],
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    depends_on = EXCLUDED.depends_on,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Sincronizacao de Horario (NTP adaptativo) (ordem 2) - core_ntp.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, depends_on, version, organization_id)
VALUES (
    'Sincronizacao de Horario (NTP adaptativo)',
    'core_ntp.sh',
    'Descobre o cliente NTP que funciona com o servidor da OM, sincroniza o relogio e persiste o cliente vencedor em /etc/seederlinux/ntp-state.env.',
    $SeederScript$#!/bin/bash
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

# Remover protocolo indevido do NTP_SERVER (a OM pode ter cadastrado
# "http://host" em vez de "host"; normalizamos aqui para nao quebrar
# o chrony/ntp, que esperam apenas hostname/IP).
NTP_SERVER="${NTP_SERVER#http://}"
NTP_SERVER="${NTP_SERVER#https://}"

NTP_STATE_DIR="/etc/seederlinux"
NTP_STATE_FILE="${NTP_STATE_DIR}/ntp-state.env"
mkdir -p "$NTP_STATE_DIR"
# ============================================================
# Exibir informacoes
# ============================================================
log_nivel INFO "Servidor NTP: $NTP_SERVER"
log_nivel INFO "Fallback:     $DNS_INTERNET"

if [ -z "$NTP_SERVER" ] || [ "$NTP_SERVER" = "" ]; then
    log_nivel AVISO "NTP_SERVER vazio. Pulando configuracao NTP."
    log_nivel ACAO  "Defina NTP_SERVER no painel (IP ou FQDN do servidor NTP/DC)."
    exit 0
fi

# ============================================================
# Pre-flight: L3 (informativo apenas - ICMP bloqueado nao impede NTP)
# ============================================================
log_nivel TESTE "Pre-flight: testando alcance do servidor NTP $NTP_SERVER"

if command -v ping >/dev/null 2>&1; then
    if ping -c 2 -W 2 "$NTP_SERVER" >/dev/null 2>&1; then
        log_nivel OK    "L3 (ICMP): $NTP_SERVER responde"
    else
        log_nivel AVISO "L3 (ICMP): $NTP_SERVER NAO responde a ping"
        log_nivel DIAG  "Isso NAO impede NTP - muitos servidores bloqueiam ICMP"
        log_nivel DIAG  "Prosseguindo para o teste NTP real"
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
# Garantir ntpdate para o probe abaixo
# ============================================================
# O probe usa `ntpdate -q` (consulta, não ajusta). Se o comando
# não existir, tenta instalar via apt (Fase 1 — DNS de internet
# ainda ativo neste ponto). Se falhar, o probe roda sem essa
# ferramenta e cai no fallback "probe cego" (informa no log).
if ! command -v ntpdate >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y ntpdate 2>/dev/null || true
fi

# ============================================================
# PROBE DO SERVIDOR NTP
#
# Antes de tentar a cascata de clientes, faz um probe rapido
# para descobrir qual cliente consegue conversar com o servidor.
# Motivo: DCs Windows (w32time) respondem de forma estranha ao
# systemd-timesyncd ("Server has too large root distance"), que
# pode "sincronizar por 1s" e cair. Probar antes evita perder
# 20s por cliente tentando o errado.
#
# Metodos, do mais simples ao mais robusto:
#   1. ntpdate -q (consulta, nao ajusta) — prova conversacao SNTP
#   2. ntpdig / ntpq — variantes
#   3. Se nenhum comando estiver disponivel, aceita "probe cego"
#      (tenta todos os clientes na ordem)
# ============================================================
log_nivel TESTE "Probe: testando comunicacao com $NTP_SERVER"

NTP_PROBE_OK=false
NTP_PROBE_METHOD=""

if command -v ntpdate >/dev/null 2>&1; then
    if ntpdate -q "$NTP_SERVER" 2>&1 | grep -qE 'server|offset|stratum'; then
        NTP_PROBE_OK=true
        NTP_PROBE_METHOD="ntpdate -q"
    fi
fi

if [ "$NTP_PROBE_OK" != "true" ] && command -v ntpdig >/dev/null 2>&1; then
    if ntpdig -t 5 "$NTP_SERVER" 2>&1 | grep -qE 'reply|offset|stratum'; then
        NTP_PROBE_OK=true
        NTP_PROBE_METHOD="ntpdig"
    fi
fi

if [ "$NTP_PROBE_OK" = "true" ]; then
    log_nivel OK "Probe OK via $NTP_PROBE_METHOD — servidor responde SNTP"
    log_nivel DIAG "Para DC Windows (w32time), NTPsec costuma ser o cliente vencedor"
else
    log_nivel AVISO "Probe nao conseguiu confirmar conversacao SNTP"
    log_nivel DIAG  "Vou testar todos os clientes na ordem — pode ser firewall UDP/123"
fi

# ============================================================
# Tentativa 1: systemd-timesyncd
# ============================================================
_try_systemd_timesyncd() {
    log_nivel TENT  "Tentativa 1/5: systemd-timesyncd (default Ubuntu)"

    if ! systemctl list-unit-files systemd-timesyncd.service >/dev/null 2>&1; then
        log_nivel DIAG  "systemd-timesyncd nao disponivel nesta distro"
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
        log_nivel DIAG  "Config: /etc/systemd/timesyncd.conf -> NTP=$NTP_SERVER"
    fi

    systemctl enable systemd-timesyncd 2>/dev/null || true
    systemctl restart systemd-timesyncd 2>/dev/null || true

    log_nivel TESTE "Aguardando 20s por sincronizacao..."
    for i in $(seq 1 10); do
        sleep 2
        if _ntp_sincronizado; then
            log_nivel OK    "Sincronizado em $((i*2))s via systemd-timesyncd"
            return 0
        fi
    done
    log_nivel AVISO "systemd-timesyncd nao sincronizou em 20s"
    log_nivel DIAG  "Provavel causa: DC Windows (w32time) incompativel com systemd-timesyncd"
    return 1
}

# ============================================================
# Tentativa 2: chrony
# ============================================================
_try_chrony() {
    log_nivel TENT  "Tentativa 2/5: chrony"

    if ! command -v chronyd >/dev/null 2>&1; then
        log_nivel DIAG  "chrony nao instalado - instalando..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y chrony 2>/dev/null || {
            log_nivel AVISO "Falha ao instalar chrony. Pulando."
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
    log_nivel DIAG  "Config: /etc/chrony/chrony.conf -> server $NTP_SERVER iburst trust"

    systemctl enable chrony 2>/dev/null || true
    systemctl restart chrony 2>/dev/null || true

    log_nivel TESTE "Aguardando 20s por sincronizacao..."
    for i in $(seq 1 10); do
        sleep 2
        chronyc makestep 2>/dev/null || true
        if _ntp_sincronizado; then
            log_nivel OK    "Sincronizado em $((i*2))s via chrony"
            return 0
        fi
    done
    log_nivel AVISO "chrony nao sincronizou em 20s"
    log_nivel DIAG  "chronyc sources abaixo (para o tecnico ver o motivo):"
    chronyc sources -v 2>/dev/null | sed 's/^/    /' || true
    log_nivel DIAG  "Causa tipica: DC Windows se declara stratum 1 sem refid valido"
    log_nivel DIAG  "chrony rejeita por padrao. NTPsec aceita. Avancando."
    return 1
}

# ============================================================
# Tentativa 3: ntpsec
# ============================================================
_try_ntpsec() {
    log_nivel TENT  "Tentativa 3/5: ntpsec"

    if ! dpkg -l ntpsec 2>/dev/null | grep -q "^ii"; then
        log_nivel DIAG  "ntpsec nao instalado - instalando..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y ntpsec 2>/dev/null || {
            log_nivel AVISO "Falha ao instalar ntpsec. Pulando."
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
    log_nivel DIAG  "Config: /etc/ntpsec/ntp.conf -> server $NTP_SERVER iburst"

    systemctl enable ntpsec 2>/dev/null || true
    systemctl restart ntpsec 2>/dev/null || true

    log_nivel TESTE "Aguardando 20s por sincronizacao..."
    for i in $(seq 1 10); do
        sleep 2
        if _ntp_sincronizado; then
            log_nivel OK    "Sincronizado em $((i*2))s via ntpsec"
            return 0
        fi
    done
    log_nivel AVISO "ntpsec nao sincronizou em 20s"
    log_nivel DIAG  "ntpq -p abaixo:"
    ntpq -p 2>/dev/null | sed 's/^/    /' || true
    return 1
}

# ============================================================
# Tentativa 4: ntp (ISC classico)
# ============================================================
_try_ntp_isc() {
    log_nivel TENT  "Tentativa 4/5: ntp (ISC classico)"

    # Se ntpsec esta instalado, ele ja fornece /usr/sbin/ntpd.
    # Removemos ntpsec antes de instalar o ntp ISC para evitar conflito.
    if dpkg -l ntpsec 2>/dev/null | grep -q "^ii"; then
        log_nivel DIAG  "Removendo ntpsec para instalar ntp ISC..."
        DEBIAN_FRONTEND=noninteractive apt-get remove -y ntpsec 2>/dev/null || true
    fi

    if ! dpkg -l ntp 2>/dev/null | grep -q "^ii"; then
        log_nivel DIAG  "ntp ISC nao instalado - instalando..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y ntp 2>/dev/null || {
            log_nivel AVISO "Falha ao instalar ntp ISC. Pulando."
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
    log_nivel DIAG  "Config: /etc/ntp.conf -> server $NTP_SERVER iburst"

    systemctl enable ntp 2>/dev/null || true
    systemctl restart ntp 2>/dev/null || true

    log_nivel TESTE "Aguardando 20s por sincronizacao..."
    for i in $(seq 1 10); do
        sleep 2
        if _ntp_sincronizado; then
            log_nivel OK    "Sincronizado em $((i*2))s via ntp ISC"
            return 0
        fi
    done
    log_nivel AVISO "ntp ISC nao sincronizou em 20s"
    return 1
}

# ============================================================
# Tentativa 5: ntpdate + cron (ultimo recurso)
# ============================================================
_try_ntpdate_cron() {
    log_nivel TENT  "Tentativa 5/5: ntpdate + cron (step one-shot)"

    if ! command -v ntpdate >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y ntpdate 2>/dev/null || {
            log_nivel AVISO "Falha ao instalar ntpdate. Desistindo."
            return 1
        }
    fi

    _parar_todos_ntp

    log_nivel TESTE "Executando ntpdate -u $NTP_SERVER (step unico)..."
    local _out
    _out="$(ntpdate -u "$NTP_SERVER" 2>&1 || true)"
    echo "$_out" | sed 's/^/    /'

    if echo "$_out" | grep -qiE "step|adjust"; then
        log_nivel OK    "Relogio ajustado via ntpdate"
        log_nivel DIAG  "ntpdate e' one-shot; sera reagendado via cron a cada 5min"
        log_nivel DIAG  "Isso NAO substitui um daemon NTP - e' paliativo"
        log_nivel ACAO  "Corrigir o NTP do servidor ($NTP_SERVER) para o daemon funcionar"

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
    log_nivel AVISO "ntpdate falhou"
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
# Validacao final
#
# A cascata pode ter "aceito" um cliente que sincronizou por 1s
# e caiu depois (bug observado: systemd-timesyncd com w32time).
# Aqui confirmamos o estado atual com 3 leituras em 3s.
# Se as 3 confirmarem, aceita. Senao, marca como falha.
# ============================================================
echo ""
log_nivel TESTE "Validacao final: confirmando sincronizacao em 3 leituras..."

_confirmacoes=0
for _i in 1 2 3; do
    sleep 1
    if [ "$(timedatectl show --property=NTPSynchronized --value 2>/dev/null)" = "yes" ]; then
        _confirmacoes=$((_confirmacoes + 1))
    elif command -v chronyc >/dev/null 2>&1 && chronyc tracking 2>/dev/null | grep -q "Leap status.*Normal"; then
        _confirmacoes=$((_confirmacoes + 1))
    elif command -v ntpq >/dev/null 2>&1 && ntpq -p 2>/dev/null | grep -qE "^\*"; then
        _confirmacoes=$((_confirmacoes + 1))
    fi
done

log_nivel INFO "Confirmacoes: $_confirmacoes/3"

if [ "$NTP_RESULT" = "OK" ] && [ "$_confirmacoes" -ge 2 ]; then
    log_nivel OK    "NTP validado: $NTP_CLIENT"
    log_nivel DIAG  "Horario local: $(date -Is)"

    cat > "$NTP_STATE_FILE" <<EOF
# SeederLinux - Estado do NTP
# Gerado por core_ntp.sh em $(date -Is)
NTP_CLIENT="$NTP_CLIENT"
NTP_SERVER="$NTP_SERVER"
NTP_LAST_OK="$(date +%s)"
EOF
    chmod 644 "$NTP_STATE_FILE"
elif [ "$NTP_RESULT" = "OK" ]; then
    log_nivel AVISO "cliente '$NTP_CLIENT' reportou OK mas validacao falhou"
    log_nivel DIAG  "Isso e' o sintoma de w32time respondendo de forma intermitente"
    log_nivel DIAG  "Persistindo como NAO-SINCRONIZADO para forcar nova tentativa no proximo logon"
    NTP_RESULT="FALHOU_VALIDACAO"

    cat > "$NTP_STATE_FILE" <<EOF
# SeederLinux - Estado do NTP (VALIDACAO FALHOU)
# Gerado por core_ntp.sh em $(date -Is)
NTP_CLIENT=""
NTP_SERVER="$NTP_SERVER"
NTP_LAST_OK="0"
NTP_LAST_FAIL="$(date +%s)"
NTP_LAST_CLIENT_ATTEMPTED="$NTP_CLIENT"
EOF
    chmod 644 "$NTP_STATE_FILE"
else
    log_nivel ERRO  "NTP NAO sincronizou com nenhum dos 5 clientes"
    log_nivel DIAG  "Causas mais provaveis:"
    log_nivel DIAG  "  1. Firewall do servidor bloqueando UDP/123 inbound"
    log_nivel DIAG  "  2. w32time (Windows) desconfigurado no servidor"
    log_nivel DIAG  "  3. Servidor NTP incorreto no painel"
    log_nivel DIAG  "  4. Rede L3 indisponivel entre estacao e servidor"
    log_nivel ACAO  "No servidor (Windows, como admin): w32tm /query /status"
    log_nivel ACAO  "Abrir firewall UDP 123 inbound no servidor"
    log_nivel ACAO  "Na estacao: ntpdate -q $NTP_SERVER"
    log_nivel DIAG  "O bundle continua, mas Kerberos pode falhar com 'Clock skew too great'"

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

log_nivel OK "NTP configurado!"
echo "============================================================"
$SeederScript$,
    TRUE,
    TRUE,
    2,
    ARRAY['core_dns.sh']::TEXT[],
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    depends_on = EXCLUDED.depends_on,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Configuracao de Repositorios APT (ordem 3) - core_repositories.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, depends_on, version, organization_id)
VALUES (
    'Configuracao de Repositorios APT',
    'core_repositories.sh',
    'Configura repositorios APT (oficial, espelho ou customizado) apos o DNS estar resolvendo.',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_repositories.sh
# SeederLinux Lite - Configurar sources.list (APT)
# ============================================================================
# Detecta a distribuição (Debian, Ubuntu, Mint, Zorin) e configura os
# repositórios APT conforme APT_POLICY da OM.
#
# POLÍTICAS SUPORTADAS (APT_POLICY):
#   DIRECT              -> mirrors oficiais, direto (Fase 1 clássica)
#   PROXY_NO_AUTH       -> mirrors oficiais via proxy (sem auth)
#   PROXY_WITH_AUTH     -> mirrors oficiais via proxy (com user/senha)
#   MIRROR_LOCAL_SEEDER -> mirror hospedado no próprio SeederLinux,
#                          acessado direto (rede local, sem proxy)
#   MIRROR_LOCAL_OM     -> mirror customizado da OM; se APT_PROXY_NAME
#                          definido, acessa via proxy, senão direto
#   MIRROR_OFFICIAL     -> mirrors oficiais, direto (alias explícito
#                          de DIRECT, mantido por clareza semântica)
#
# MÚLTIPLOS PROXIES:
#   A OM pode ter 0..N proxies nomeados. APT_PROXY_NAME aponta para um
#   deles; se vazio, usa PROXY_DEFAULT_NAME. O proxy é resolvido aqui
#   e escrito em /etc/apt/apt.conf.d/95seederlinux-proxy.
#
# Os placeholders VARIAVEL são substituídos automaticamente
# pelo sistema na geração do bundle.
# ============================================================================

set -e

source /usr/local/lib/seederlinux/diag.sh 2>/dev/null || true
SCRIPT_ID="03-repositories"

echo "============================================================"
echo "Configurar repositorios APT"
echo "============================================================"

# ============================================================
# Variáveis (substituídas no bundle)
# ============================================================
APT_POLICY="{{APT_POLICY}}"
APT_PROXY_NAME="{{APT_PROXY_NAME}}"
MIRROR_LOCAL_SEEDER_PATH="{{MIRROR_LOCAL_SEEDER_PATH}}"
MIRROR_LOCAL_OM_URL="{{MIRROR_LOCAL_OM_URL}}"
SEEDER_SERVER="{{SEEDER_SERVER}}"

# Múltiplos proxies (dinâmicos, vem do header do bundle)
PROXY_COUNT="${PROXY_COUNT:-0}"
PROXY_DEFAULT_NAME="${PROXY_DEFAULT_NAME:-}"

# Defaults defensivos
[ -z "$APT_POLICY" ] && APT_POLICY="DIRECT"
[ -z "$MIRROR_LOCAL_SEEDER_PATH" ] && MIRROR_LOCAL_SEEDER_PATH="/mirror/"
SEEDER_SERVER="${SEEDER_SERVER%/}"

log_nivel INFO "APT_POLICY: $APT_POLICY"
log_nivel INFO "APT_PROXY_NAME: ${APT_PROXY_NAME:-<default>}"
log_nivel INFO "Proxies cadastrados: $PROXY_COUNT"

# ============================================================
# Fase 1 — limpar estado de proxy herdado
# ============================================================
# O apt nao respeita wildcards no no_proxy. Se um snapshot herdou
# um 95seederlinux-proxy de execucao anterior com proxy nao
# resolvivel, o apt-get update quebra antes mesmo deste script
# decidir qual politica aplicar.
#
# Comecamos SEMPRE limpo. Se a policy escolhida for PROXY_*, o
# arquivo sera reescrito no fim deste script, ANTES do apt-get
# update.
log_nivel INFO "Limpando config de proxy do apt de execucoes anteriores..."
rm -f /etc/apt/apt.conf.d/95seederlinux-proxy 2>/dev/null || true

# ============================================================
# Detectar distribuição
# ============================================================
detect_distro() {
    if [ -f /etc/linuxmint/info ]; then
        echo "mint"
    elif [ -f /etc/zorin-release ]; then
        echo "zorin"
    elif grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
        echo "ubuntu"
    elif grep -qi "debian" /etc/os-release 2>/dev/null; then
        echo "debian"
    else
        echo "unknown"
    fi
}

DISTRO="$(detect_distro)"
log_nivel INFO "Distribuicao detectada: $DISTRO"

# ============================================================
# Obter codename da distro
# ============================================================
get_codename() {
    local fallback="$1"
    local codename=""

    if [ -f /etc/os-release ]; then
        codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
    fi
    if [ -z "$codename" ] && command -v lsb_release &>/dev/null; then
        codename="$(lsb_release -cs 2>/dev/null)"
    fi
    if [ -z "$codename" ]; then
        log_nivel AVISO "nao foi possivel detectar o codename. Usando fallback: $fallback"
        codename="$fallback"
    fi
    echo "$codename"
}

# ============================================================
# Helper: resolver proxy por nome
# ============================================================
# Procura PROXY_N_NAME == $1 e retorna a URL montada (com user:pass
# embutido se houver). Vazio se nao encontrar.
#
# Formato aceito pelo apt: http://user:pass@host:port/
_resolver_proxy_url() {
    local name="$1"
    [ -z "$name" ] && return 1
    [ "$PROXY_COUNT" -lt 1 ] 2>/dev/null && return 1

    local i=1
    while [ "$i" -le "$PROXY_COUNT" ]; do
        local v_name="PROXY_${i}_NAME"
        if [ "${!v_name}" = "$name" ]; then
            local v_url="PROXY_${i}_URL"
            local v_user="PROXY_${i}_USER"
            local v_pass_b64="PROXY_${i}_PASS_B64"
            local url="${!v_url}"
            local user="${!v_user}"
            local pass_b64="${!v_pass_b64}"

            if [ -z "$url" ]; then
                log_nivel AVISO "proxy '$name' encontrado mas URL vazia."
                return 1
            fi

            # Sem user: retorna URL como esta
            if [ -z "$user" ]; then
                echo "$url"
                return 0
            fi

            # Com user: decodifica senha e embute na URL
            local pass=""
            if [ -n "$pass_b64" ]; then
                pass="$(printf '%s' "$pass_b64" | base64 -d 2>/dev/null)" || pass=""
            fi

            # URL-encode muito basico de @ e : no user/pass
            # (se contiverem, quebram a sintaxe user:pass@host)
            local user_esc="${user//@/%40}"
            user_esc="${user_esc//:/%3A}"
            local pass_esc="${pass//@/%40}"
            pass_esc="${pass_esc//:/%3A}"

            # http://user:pass@host:port
            if echo "$url" | grep -qE '^https?://'; then
                echo "$url" | sed -E "s|^(https?://)|\1${user_esc}:${pass_esc}@|"
            else
                # URL sem scheme (raro, mas defensivo)
                echo "http://${user_esc}:${pass_esc}@${url}"
            fi
            return 0
        fi
        i=$((i+1))
    done
    return 1
}

# Resolve o nome efetivo do proxy (policy name ou default)
_resolver_proxy_nome_efetivo() {
    if [ -n "$APT_PROXY_NAME" ]; then
        echo "$APT_PROXY_NAME"
    else
        echo "$PROXY_DEFAULT_NAME"
    fi
}

# ============================================================
# Helper: escrever 95seederlinux-proxy
# ============================================================
_escrever_proxy_apt() {
    local url="$1"
    log_nivel INFO "Configurando apt via proxy: $url"
    cat > /etc/apt/apt.conf.d/95seederlinux-proxy <<EOF
Acquire::http::Proxy "${url}";
Acquire::https::Proxy "${url}";
Acquire::ftp::Proxy "${url}";
EOF
}

# ============================================================
# Resolver config de proxy (se aplicável)
# ============================================================
APT_PROXY_URL=""

case "$APT_POLICY" in
    PROXY|PROXY_NO_AUTH|PROXY_WITH_AUTH)
        NOME_EFETIVO="$(_resolver_proxy_nome_efetivo)"
        if [ -z "$NOME_EFETIVO" ]; then
            log_nivel ERRO "APT_POLICY=$APT_POLICY mas nenhum proxy configurado (APT_PROXY_NAME vazio e PROXY_DEFAULT_NAME vazio)."
            log_nivel INFO "Configurando apt como DIRECT para nao travar o bundle."
            APT_POLICY="DIRECT"
        else
            APT_PROXY_URL="$(_resolver_proxy_url "$NOME_EFETIVO")" || APT_PROXY_URL=""
            if [ -z "$APT_PROXY_URL" ]; then
                log_nivel ERRO "proxy '$NOME_EFETIVO' nao encontrado na lista de proxies da OM."
                log_nivel INFO "Configurando apt como DIRECT para nao travar o bundle."
                APT_POLICY="DIRECT"
            else
                _escrever_proxy_apt "$APT_PROXY_URL"
            fi
        fi
        ;;
    MIRROR_LOCAL_OM)
        # Mirror da OM pode estar em outra rede; se a OM definiu proxy
        # para ele, usamos; senao, direto.
        NOME_EFETIVO="$(_resolver_proxy_nome_efetivo)"
        if [ -n "$NOME_EFETIVO" ]; then
            APT_PROXY_URL="$(_resolver_proxy_url "$NOME_EFETIVO")" || APT_PROXY_URL=""
            if [ -n "$APT_PROXY_URL" ]; then
                _escrever_proxy_apt "$APT_PROXY_URL"
            fi
        fi
        ;;
    DIRECT|MIRROR_LOCAL_SEEDER|MIRROR_OFFICIAL|*)
        # Sem proxy. O 95seederlinux-proxy ja foi removido no topo.
        ;;
esac

# ============================================================
# Backup do sources.list antes de mexer
# ============================================================
backup_sources() {
    if [ -f /etc/apt/sources.list ]; then
        cp /etc/apt/sources.list /etc/apt/sources.list.bak.$(date +%Y%m%d%H%M%S)
    fi
}

# ============================================================
# Escrever sources.list conforme a policy
# ============================================================
case "$APT_POLICY" in

    DIRECT|PROXY|PROXY_NO_AUTH|PROXY_WITH_AUTH)
        log_nivel INFO "Policy: mirrors oficiais da distro ($DISTRO)."
        log_nivel INFO "Nenhuma alteracao em sources.list (mantendo o que ja esta)."
        # Nao mexe: a estacao ja veio com sources.list da distro
        ;;

    MIRROR_OFFICIAL)
        log_nivel INFO "Policy: mirrors oficiais explicitos."
        log_nivel INFO "Nenhuma alteracao em sources.list."
        ;;

    MIRROR_LOCAL_SEEDER)
        log_nivel INFO "Policy: mirror local hospedado no SeederLinux."
        log_nivel INFO "Base: ${SEEDER_SERVER}${MIRROR_LOCAL_SEEDER_PATH}"

        backup_sources

        case "$DISTRO" in
            ubuntu)
                UBUNTU_CODENAME="$(get_codename noble)"
                cat > /etc/apt/sources.list <<EOF
deb ${SEEDER_SERVER}${MIRROR_LOCAL_SEEDER_PATH}ubuntu $UBUNTU_CODENAME main restricted universe multiverse
deb ${SEEDER_SERVER}${MIRROR_LOCAL_SEEDER_PATH}ubuntu $UBUNTU_CODENAME-updates main restricted universe multiverse
deb ${SEEDER_SERVER}${MIRROR_LOCAL_SEEDER_PATH}ubuntu $UBUNTU_CODENAME-security main restricted universe multiverse
EOF
                ;;
            mint)
                MINT_CODENAME="$(get_codename wilma)"
                UBUNTU_CODENAME="$(grep UBUNTU_CODENAME /etc/linuxmint/info 2>/dev/null | cut -d= -f2 || echo noble)"
                cat > /etc/apt/sources.list <<EOF
deb ${SEEDER_SERVER}${MIRROR_LOCAL_SEEDER_PATH}mint $MINT_CODENAME main upstream import backport
deb ${SEEDER_SERVER}${MIRROR_LOCAL_SEEDER_PATH}ubuntu $UBUNTU_CODENAME main restricted universe multiverse
deb ${SEEDER_SERVER}${MIRROR_LOCAL_SEEDER_PATH}ubuntu $UBUNTU_CODENAME-updates main restricted universe multiverse
deb ${SEEDER_SERVER}${MIRROR_LOCAL_SEEDER_PATH}ubuntu $UBUNTU_CODENAME-security main restricted universe multiverse
EOF
                ;;
            debian)
                DEBIAN_CODENAME="$(get_codename trixie)"
                cat > /etc/apt/sources.list <<EOF
deb ${SEEDER_SERVER}${MIRROR_LOCAL_SEEDER_PATH}debian $DEBIAN_CODENAME main contrib non-free non-free-firmware
deb ${SEEDER_SERVER}${MIRROR_LOCAL_SEEDER_PATH}debian-security $DEBIAN_CODENAME-security main contrib non-free non-free-firmware
deb ${SEEDER_SERVER}${MIRROR_LOCAL_SEEDER_PATH}debian $DEBIAN_CODENAME-updates main contrib non-free non-free-firmware
EOF
                ;;
            zorin)
                UBUNTU_CODENAME="$(get_codename jammy)"
                cat > /etc/apt/sources.list <<EOF
deb ${SEEDER_SERVER}${MIRROR_LOCAL_SEEDER_PATH}ubuntu $UBUNTU_CODENAME main restricted universe multiverse
deb ${SEEDER_SERVER}${MIRROR_LOCAL_SEEDER_PATH}ubuntu $UBUNTU_CODENAME-updates main restricted universe multiverse
deb ${SEEDER_SERVER}${MIRROR_LOCAL_SEEDER_PATH}ubuntu $UBUNTU_CODENAME-security main restricted universe multiverse
EOF
                ;;
            *)
                log_nivel AVISO "distro '$DISTRO' nao reconhecida. Mantendo sources.list atual."
                ;;
        esac
        ;;

    MIRROR_LOCAL_OM)
        if [ -z "$MIRROR_LOCAL_OM_URL" ]; then
            log_nivel ERRO "APT_POLICY=MIRROR_LOCAL_OM mas MIRROR_LOCAL_OM_URL esta vazio."
            log_nivel INFO "Mantendo sources.list atual."
        else
            log_nivel INFO "Policy: mirror local da OM ($MIRROR_LOCAL_OM_URL)"
            backup_sources

            MIRROR_BASE="${MIRROR_LOCAL_OM_URL%/}"
            case "$DISTRO" in
                ubuntu|zorin)
                    UBUNTU_CODENAME="$(get_codename noble)"
                    cat > /etc/apt/sources.list <<EOF
deb ${MIRROR_BASE}/ubuntu $UBUNTU_CODENAME main restricted universe multiverse
deb ${MIRROR_BASE}/ubuntu $UBUNTU_CODENAME-updates main restricted universe multiverse
deb ${MIRROR_BASE}/ubuntu $UBUNTU_CODENAME-security main restricted universe multiverse
EOF
                    ;;
                mint)
                    MINT_CODENAME="$(get_codename wilma)"
                    UBUNTU_CODENAME="$(grep UBUNTU_CODENAME /etc/linuxmint/info 2>/dev/null | cut -d= -f2 || echo noble)"
                    cat > /etc/apt/sources.list <<EOF
deb ${MIRROR_BASE}/mint $MINT_CODENAME main upstream import backport
deb ${MIRROR_BASE}/ubuntu $UBUNTU_CODENAME main restricted universe multiverse
deb ${MIRROR_BASE}/ubuntu $UBUNTU_CODENAME-updates main restricted universe multiverse
deb ${MIRROR_BASE}/ubuntu $UBUNTU_CODENAME-security main restricted universe multiverse
EOF
                    ;;
                debian)
                    DEBIAN_CODENAME="$(get_codename trixie)"
                    cat > /etc/apt/sources.list <<EOF
deb ${MIRROR_BASE}/debian $DEBIAN_CODENAME main contrib non-free non-free-firmware
deb ${MIRROR_BASE}/debian-security $DEBIAN_CODENAME-security main contrib non-free non-free-firmware
deb ${MIRROR_BASE}/debian $DEBIAN_CODENAME-updates main contrib non-free non-free-firmware
EOF
                    ;;
                *)
                    log_nivel AVISO "distro '$DISTRO' nao reconhecida. Mantendo sources.list atual."
                    ;;
            esac
        fi
        ;;

    *)
        log_nivel AVISO "APT_POLICY desconhecida '$APT_POLICY'. Tratando como DIRECT."
        ;;
esac

# ============================================================
# apt-get update
# ============================================================
# Em DIRECT/PROXY_* a fonte eh mirror oficial - se falhar, e' falha
# real (internet caiu, proxy caiu), e o bundle deve abortar.
#
# Em MIRROR_* a fonte eh local ou curada - se falhar, tambem e' falha
# real (mirror fora do ar, path errado), e o bundle deve abortar.
#
# Nao toleramos falha aqui: queremos saber se o APT nao esta funcional
# ANTES de tentar instalar pacotes no script 04.
log_nivel INFO "Atualizando apt-get update..."
apt-get update

log_nivel OK "Repositorios configurados com sucesso (policy: $APT_POLICY)!"
echo "============================================================"
$SeederScript$,
    TRUE,
    TRUE,
    3,
    ARRAY['core_dns.sh']::TEXT[],
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    depends_on = EXCLUDED.depends_on,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Instalacao de Pacotes Essenciais (ordem 4) - core_packages.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, depends_on, version, organization_id)
VALUES (
    'Instalacao de Pacotes Essenciais',
    'core_packages.sh',
    'Instala TODOS os pacotes necessarios (sistema, OCS, CUPS, VNC, Conky, Java, etc).',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_packages.sh
# SeederLinux Lite - Instalar pacotes essenciais
# ============================================================================
# Instala todos os pacotes necessarios para o funcionamento da estacao:
# ferramentas de rede, autenticacao, sistema grafico, utilitarios.
#
# COMPATIBILIDADE 24.04 x 26.04+:
#   - policykit-1 foi renomeado para polkitd+pkexec no Ubuntu 22.04+.
#     Listamos os tres nomes - instalar_pacotes tolera os que nao existem.
#   - bzip2, xz-utils sairam do conjunto base do Ubuntu 26+.
#     Precisam ser instalados explicitamente (core_legados.sh depende de bzip2).
#
# ESTRUTURA DE INSTALACAO:
#   Todos os grupos (base, auth, extras, DE, DM) usam `instalar_pacotes`,
#   que instala pacote-a-pacote e tolera falhas individuais.
#
# Os placeholders VARIAVEL sao substituidos automaticamente
# pelo sistema na geracao do bundle.
# ============================================================================

set -e

source /usr/local/lib/seederlinux/diag.sh 2>/dev/null || true
SCRIPT_ID="04-packages"

echo "============================================================"
echo "Instalar pacotes essenciais"
echo "============================================================"

# ============================================================
# Variáveis
# ============================================================
DESKTOP_ENV=""
INSTALL_DESKTOP="false"

log_nivel INFO "Ambiente grafico solicitado (opcional): $DESKTOP_ENV"
log_nivel INFO "Instalar ambiente grafico: $INSTALL_DESKTOP"

# ============================================================
# Detectar ambiente grafico ja instalado
# ============================================================
detectar_de() {
    if command -v cinnamon-session &>/dev/null; then echo "cinnamon"
    elif command -v mate-session &>/dev/null; then echo "mate"
    elif command -v gnome-session &>/dev/null; then echo "gnome"
    elif command -v startxfce4 &>/dev/null; then echo "xfce"
    elif command -v startplasma-x11 &>/dev/null; then echo "kde"
    elif command -v lxqt-session &>/dev/null; then echo "lxqt"
    elif command -v startlxde &>/dev/null; then echo "lxde"
    else echo "unknown"
    fi
}

detectar_dm() {
    if systemctl is-active --quiet lightdm 2>/dev/null; then echo "lightdm"
    elif systemctl is-active --quiet gdm3 2>/dev/null; then echo "gdm3"
    elif systemctl is-active --quiet sddm 2>/dev/null; then echo "sddm"
    elif [ -f /etc/X11/default-display-manager ]; then
        basename "$(cat /etc/X11/default-display-manager)"
    else echo "unknown"
    fi
}

DETECTED_DE="$(detectar_de)"
DETECTED_DM="$(detectar_dm)"
export DETECTED_DE DETECTED_DM

log_nivel INFO "DE detectado na estacao: $DETECTED_DE"
log_nivel INFO "DM detectado na estacao: $DETECTED_DM"

# ============================================================
# Instalar pacotes com fallback por item
# ============================================================
instalar_pacotes() {
    local grupo="$1"; shift
    local falhou=0
    for pkg in "$@"; do
        if ! apt-get install -y "$pkg" 2>/dev/null; then
            log_nivel INFO "AVISO [$grupo]: falha ao instalar pacote '$pkg'"
            falhou=$((falhou + 1))
        fi
    done
    if [ "$falhou" -gt 0 ]; then
        log_nivel INFO "[$grupo] concluido com $falhou pacote(s) nao instalado(s)."
    fi
}

# ============================================================
# Atualizar sistema
# ============================================================
log_nivel INFO "Atualizando pacotes do sistema..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y upgrade

# ============================================================
# Pacotes base do sistema
# ============================================================
log_nivel INFO "Instalando pacotes base..."
BASE_PACKAGES=(
    wget
    curl
    gnupg
    ca-certificates
    lsb-release
    apt-transport-https
    software-properties-common
    unzip
    rsync
    htop
    vim
    nano
    less
    bash-completion
    net-tools
    # dnsutils (24.04) ou bind9-dnsutils (26.04) - listamos os dois
    dnsutils
    bind9-dnsutils
    iproute2
    iputils-ping
    traceroute
    nmap
    tcpdump
    openssh-server
    openssh-client
    cifs-utils
    nfs-common
    smbclient
    # policykit-1 (ate 21.10) ou polkitd+pkexec (22.04+)
    policykit-1
    polkitd
    pkexec
    udisks2
    gvfs-backends
    gvfs-fuse
    fuse3
    libnotify-bin
    dbus-x11
    xdg-utils
    fonts-liberation
    fonts-noto
    fonts-noto-cjk
    fontconfig
    # Ferramentas de descompressao - NAO estao no base do 26+
    bzip2
    xz-utils
)

instalar_pacotes "base" "${BASE_PACKAGES[@]}"

# ============================================================
# Garantir repositorio universe
# ============================================================
log_nivel INFO "Garantindo repositorio universe..."
if command -v add-apt-repository &>/dev/null; then
    add-apt-repository -y universe 2>/dev/null || true
fi
apt-get update -qq

# ============================================================
# Pacotes de autenticacao (AD/Kerberos/SSSD)
# ============================================================
log_nivel INFO "Instalando pacotes de autenticacao..."
AUTH_PACKAGES=(
    krb5-user
    samba
    samba-common
    samba-common-bin
    sssd
    sssd-tools
    sssd-krb5
    sssd-krb5-common
    libsss-sudo
    libnss-sss
    libpam-sss
    adcli
    realmd
    oddjob
    oddjob-mkhomedir
    packagekit
    network-manager
    network-manager-gnome
)

instalar_pacotes "auth" "${AUTH_PACKAGES[@]}"

# ============================================================
# Pacotes do ambiente grafico (OPCIONAL)
# ============================================================
if [ "$INSTALL_DESKTOP" = "true" ] && [ -n "$DESKTOP_ENV" ] && [ "$DESKTOP_ENV" != "" ]; then
    log_nivel INFO "Instalando ambiente grafico solicitado: $DESKTOP_ENV"
    case "$DESKTOP_ENV" in
        cinnamon)
            instalar_pacotes "DE-cinnamon" cinnamon cinnamon-common lightdm lightdm-gtk-greeter
            ;;
        mate)
            instalar_pacotes "DE-mate" mate-desktop-environment mate-desktop-environment-extras lightdm lightdm-gtk-greeter
            ;;
        gnome)
            instalar_pacotes "DE-gnome" gnome-shell gnome-session gnome-terminal gdm3
            ;;
        xfce)
            instalar_pacotes "DE-xfce" xfce4 xfce4-goodies lightdm lightdm-gtk-greeter
            ;;
        kde)
            instalar_pacotes "DE-kde" kde-plasma-desktop sddm
            ;;
        lxqt)
            instalar_pacotes "DE-lxqt" lxqt sddm
            ;;
        lxde)
            instalar_pacotes "DE-lxde" lxde lightdm lightdm-gtk-greeter
            ;;
        *)
            log_nivel AVISO "Ambiente grafico nao reconhecido: $DESKTOP_ENV"
            log_nivel INFO "Nenhum DE sera instalado. Usando o ja presente: $DETECTED_DE"
            ;;
    esac
else
    log_nivel INFO "INSTALL_DESKTOP != true. Nao instalando DE."
    log_nivel INFO "Utilizando ambiente grafico ja presente: $DETECTED_DE"
fi

# ============================================================
# Pacotes complementares
# ============================================================
log_nivel INFO "Instalando pacotes complementares..."
EXTRA_PACKAGES=(
    cups
    cups-client
    system-config-printer
    x11vnc
    conky-all
    jq
    dmidecode
    gimp
    vlc
    evince
    file-roller
    gparted
    gnome-screenshot
    xbacklight
    pavucontrol
    pulseaudio
    pulseaudio-utils
    alsa-utils
    intel-microcode
    amd64-microcode
    acpi
    acpid
    powermgmt-base
    upower
    colord
    geoclue-2.0
)

instalar_pacotes "extras" "${EXTRA_PACKAGES[@]}"

if [ "{{INSTALL_JAVA8}}" = "true" ]; then
    instalar_pacotes "java8" openjdk-8-jre
fi

# ============================================================
# Display Manager + greeter
# ============================================================
detectar_de_dm() {
    if command -v cinnamon-session &>/dev/null; then echo "cinnamon"
    elif command -v mate-session &>/dev/null; then echo "mate"
    elif command -v gnome-session &>/dev/null; then echo "gnome"
    elif command -v startxfce4 &>/dev/null; then echo "xfce"
    elif command -v startplasma-x11 &>/dev/null; then echo "kde"
    elif command -v lxqt-session &>/dev/null; then echo "lxqt"
    elif command -v startlxde &>/dev/null; then echo "lxde"
    else echo "unknown"
    fi
}

dm_padrao_de() {
    case "$1" in
        gnome) echo "gdm3" ;;
        kde)   echo "sddm" ;;
        *)     echo "lightdm" ;;
    esac
}

DE_EFFECTIVE="${DESKTOP_ENV:-}"
[ -z "$DE_EFFECTIVE" ] && DE_EFFECTIVE="$(detectar_de_dm)"
[ -z "$DE_EFFECTIVE" ] && DE_EFFECTIVE="unknown"

DM_EFFECTIVE="${DISPLAY_MANAGER:-}"
[ -z "$DM_EFFECTIVE" ] && DM_EFFECTIVE="$(dm_padrao_de "$DE_EFFECTIVE")"

log_nivel INFO "DE efetivo: $DE_EFFECTIVE"
log_nivel INFO "DM efetivo: $DM_EFFECTIVE"

case "$DM_EFFECTIVE" in
    lightdm)
        instalar_pacotes "dm-lightdm" lightdm lightdm-slick-greeter
        if ! dpkg -l lightdm-slick-greeter 2>/dev/null | grep -q "^ii"; then
            log_nivel INFO "slick-greeter indisponivel - tentando lightdm-gtk-greeter..."
            instalar_pacotes "dm-lightdm-gtk" lightdm-gtk-greeter
        fi
        ;;
    gdm3)
        instalar_pacotes "dm-gdm3" gdm3
        ;;
    sddm)
        instalar_pacotes "dm-sddm" sddm sddm-theme-breeze
        ;;
    *)
        log_nivel AVISO "DM '$DM_EFFECTIVE' desconhecido - instalando lightdm."
        instalar_pacotes "dm-lightdm" lightdm lightdm-slick-greeter
        if ! dpkg -l lightdm-slick-greeter 2>/dev/null | grep -q "^ii"; then
            instalar_pacotes "dm-lightdm-gtk" lightdm-gtk-greeter
        fi
        ;;
esac

DM_OK=false
command -v lightdm &>/dev/null && DM_OK=true
command -v gdm3    &>/dev/null && DM_OK=true
command -v sddm    &>/dev/null && DM_OK=true
if [ "$DM_OK" != "true" ]; then
    log_nivel ERRO "nenhum display manager foi instalado com sucesso."
else
    log_nivel INFO "Display manager instalado com sucesso."
fi

# ============================================================
# OCS Inventory Agent
# ============================================================
log_nivel INFO "Instalando OCS Inventory Agent..."
if ! apt-get install -y ocsinventory-agent 2>/dev/null; then
    log_nivel AVISO "Falha ao instalar ocsinventory-agent."
else
    log_nivel INFO "OCS Inventory Agent instalado com sucesso"
fi

# ============================================================
# Firefox: instalar tarball oficial da Mozilla (sem PPA, sem snap)
# ============================================================
# Ubuntu 24.04+ entrega Firefox como snap. O snap NAO le policies.json
# (a interface firefox:etc-firefox nao vem conectada por padrao),
# o que quebra proxy e homepage corporativos.
#
# NAO remover o snap automaticamente: o snap remove --purge seguido de
# add-apt-repository ppa:mozillateam falha quando o DNS ja foi trocado
# para o AD (Fase 2 do core_domain.sh) e o PPA nao resolve. Resultado:
# usuario perde o Firefox moderno sem ganhar o .deb.
#
# Em vez disso, baixar o tarball direto da Mozilla (nao depende de PPA
# nem de apt) e instalar em /opt/firefox. O snap (se presente) e
# mantido — o usuario pode remove-lo manualmente depois se quiser.
# O tarball le policies.json normalmente.
log_nivel INFO "Verificando instalacao existente do Firefox..."
FIREFOX_TARBALL="/tmp/firefox-latest.tar.xz"
FIREFOX_URL="https://download.mozilla.org/?product=firefox-latest-ssl&os=linux64&lang=pt-BR"

# Deteccao: deb nativo vs snap vs nenhum
TEM_DEB=false
TEM_SNAP=false
if dpkg -l firefox 2>/dev/null | grep -q "^ii" || \
   dpkg -l firefox-esr 2>/dev/null | grep -q "^ii"; then
    TEM_DEB=true
fi
if snap list firefox 2>/dev/null | grep -q "^firefox"; then
    TEM_SNAP=true
fi

if [ "$TEM_DEB" = "true" ] && [ "$TEM_SNAP" != "true" ]; then
    # Ja existe Firefox .deb nativo e nenhum snap — nada a fazer
    log_nivel INFO "Firefox .deb nativo ja instalado. Nenhuma acao necessaria."
elif [ "$TEM_SNAP" = "true" ]; then
    # Snap presente — baixar tarball da Mozilla em /opt/firefox-moderno
    # (NAO remover o snap)
    log_nivel INFO "Firefox snap detectado. Instalando tarball da Mozilla em /opt/firefox-moderno..."
    if wget -q --no-proxy -O "$FIREFOX_TARBALL" "$FIREFOX_URL" 2>/dev/null; then
        tar xJf "$FIREFOX_TARBALL" -C /opt/ 2>/dev/null
        rm -f "$FIREFOX_TARBALL"

        [ -d /opt/firefox-moderno ] && rm -rf /opt/firefox-moderno
        mv /opt/firefox /opt/firefox-moderno 2>/dev/null || true

        ln -sf /opt/firefox-moderno/firefox /usr/local/bin/firefox

        cat > /usr/share/applications/firefox-moderno.desktop <<DESKTOP
[Desktop Entry]
Version=1.0
Name=Firefox
Comment=Navegador Web
Exec=/opt/firefox-moderno/firefox %u
Icon=/opt/firefox-moderno/browser/chrome/icons/default/default128.png
Terminal=false
Type=Application
Categories=Network;WebBrowser;
MimeType=text/html;text/xml;application/xhtml+xml;application/vnd.mozilla.xul+xml;text/mml;x-scheme-handler/http;x-scheme-handler/https;
DESKTOP

        log_nivel INFO "Firefox tarball instalado em /opt/firefox-moderno (snap mantido)."
    else
        log_nivel AVISO "Falha ao baixar tarball do Firefox. Snap mantido."
    fi
else
    # Nenhum Firefox instalado — baixar tarball da Mozilla
    log_nivel INFO "Nenhum Firefox detectado. Instalando tarball da Mozilla..."
    if wget -q --no-proxy -O "$FIREFOX_TARBALL" "$FIREFOX_URL" 2>/dev/null; then
        tar xJf "$FIREFOX_TARBALL" -C /opt/ 2>/dev/null
        rm -f "$FIREFOX_TARBALL"

        [ -d /opt/firefox-moderno ] && rm -rf /opt/firefox-moderno
        mv /opt/firefox /opt/firefox-moderno 2>/dev/null || true

        ln -sf /opt/firefox-moderno/firefox /usr/local/bin/firefox

        cat > /usr/share/applications/firefox-moderno.desktop <<DESKTOP
[Desktop Entry]
Version=1.0
Name=Firefox
Comment=Navegador Web
Exec=/opt/firefox-moderno/firefox %u
Icon=/opt/firefox-moderno/browser/chrome/icons/default/default128.png
Terminal=false
Type=Application
Categories=Network;WebBrowser;
MimeType=text/html;text/xml;application/xhtml+xml;application/vnd.mozilla.xul+xml;text/mml;x-scheme-handler/http;x-scheme-handler/https;
DESKTOP

        log_nivel INFO "Firefox tarball instalado em /opt/firefox-moderno."
    else
        log_nivel AVISO "Falha ao baixar tarball do Firefox."
        log_nivel INFO "Tentando firefox-esr via apt..."
        apt-get install -y firefox-esr firefox-esr-l10n-pt-br 2>/dev/null || \
            apt-get install -y firefox firefox-l10n-pt-br 2>/dev/null || true
    fi
fi

# Firmware opcional
apt-get install -y firmware-linux 2>/dev/null || true
apt-get install -y firmware-linux-nonfree 2>/dev/null || true

# ============================================================
# Detectar GPU e instalar drivers
# ============================================================
log_nivel INFO "Detectando placa de video..."
if lspci | grep -qi nvidia; then
    log_nivel INFO "Placa NVIDIA detectada. Instalando drivers..."
    apt-get install -y nvidia-driver-550 2>/dev/null || {
        log_nivel AVISO "Falha ao instalar driver NVIDIA. Tentando ubuntu-drivers..."
        ubuntu-drivers autoinstall 2>/dev/null || true
    }
elif lspci | grep -qi amd; then
    log_nivel INFO "Placa AMD detectada. Instalando drivers..."
    apt-get install -y mesa-utils xserver-xorg-video-amdgpu 2>/dev/null || true
else
    log_nivel INFO "GPU NVIDIA/AMD nao detectada. Usando driver generico."
fi

# ============================================================
# Remover LibreOffice (opcional)
# ============================================================
if [ "{{REMOVER_LIBREOFFICE}}" = "true" ]; then
    log_nivel INFO "Removendo LibreOffice..."
    apt-get remove --purge -y libreoffice* libreoffice-core libreoffice-common
fi

# ============================================================
# Limpar cache do APT
# ============================================================
log_nivel INFO "Limpando cache do APT..."
apt-get clean
apt-get autoremove -y

log_nivel OK "Pacotes essenciais instalados!"
echo "============================================================"
$SeederScript$,
    TRUE,
    TRUE,
    4,
    ARRAY['core_dns.sh', 'core_repositories.sh']::TEXT[],
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    depends_on = EXCLUDED.depends_on,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Suporte a Sistemas Legados (ordem 5) - core_legados.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, depends_on, version, organization_id)
VALUES (
    'Suporte a Sistemas Legados',
    'core_legados.sh',
    'Instala Java 8 e Firefox 52 ESR para compatibilidade com sistemas legados.',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_legados.sh
# SeederLinux Lite - Java 8, Firefox 52.7 ESR (sistemas legados)
# ============================================================================
# Instala Java 8 (OpenJDK) e/ou Firefox 52.7 ESR para compatibilidade
# com sistemas legados (applets Java, sistemas antigos da intranet).
#
# Toggles por OM:
#   INSTALL_JAVA8     - Instalar Java 8?
#   INSTALL_FIREFOX52 - Instalar Firefox 52.7 ESR?
#
# DOWNLOADS INTERNOS vs EXTERNOS:
#   - Tarball do Firefox 52.7 vem do proprio Seeder (BASE_URL/downloads).
#     Usa --no-proxy (Seeder esta sempre no NO_PROXY, e wget nao
#     respeita wildcards).
#   - Fallback da Mozilla (ftp.mozilla.org) e' download publico.
#     Pode passar por proxy normalmente se o /etc/environment estiver
#     configurado - deixamos o wget usar o ambiente.
#   - Chave GPG do Adoptium (packages.adoptium.net) e' publica.
#     Idem: respeita proxy do ambiente se houver.
#
# DEPENDENCIAS:
#   Firefox 52.7 usa .tar.bz2 - precisa de bzip2 para extrair.
#   bzip2 e' instalado em core_packages.sh, mas se por algum motivo
#   nao estiver, o script avisa e pula o Firefox em vez de derrubar
#   o bundle.
#
# Executado ANTES de core_domain.sh para evitar erro 407 de proxy
# (Firefox precisa de internet direta antes do ingresso).
#
# Os placeholders VARIAVEL sao substituidos automaticamente
# pelo sistema na geracao do bundle.
# ============================================================================

(
set -e

source /usr/local/lib/seederlinux/diag.sh 2>/dev/null || true
SCRIPT_ID="05-legados"

echo "============================================================"
echo "Configurar sistemas legados (Java 8, Firefox 52.7)"
echo "============================================================"

# ============================================================
# Variaveis (substituidas no bundle)
# ============================================================
INSTALL_JAVA8="{{INSTALL_JAVA8}}"
INSTALL_FIREFOX52="{{INSTALL_FIREFOX52}}"
BASE_URL="{{BASE_URL}}"
JAVA_EXCEPTIONS="{{JAVA_EXCEPTIONS}}"

BASE_URL="${BASE_URL%/}"

log_nivel INFO "Instalar Java 8: $INSTALL_JAVA8"
log_nivel INFO "Instalar Firefox 52.7: $INSTALL_FIREFOX52"
log_nivel INFO "Excecoes Java: ${JAVA_EXCEPTIONS:-nenhuma}"

# ============================================================
# Verificar se pelo menos um toggle esta ativo
# ============================================================
if [ "$INSTALL_JAVA8" != "true" ] && [ "$INSTALL_FIREFOX52" != "true" ]; then
    log_nivel INFO "Sistemas legados desativados. Pulando."
    log_nivel INFO "[05] Sistemas legados nao instalados (desativado)."
    echo "============================================================"
    exit 0
fi

export DEBIAN_FRONTEND=noninteractive

# ============================================================
# Java 8 (OpenJDK) - apenas se INSTALL_JAVA8=true
# ============================================================
if [ "$INSTALL_JAVA8" = "true" ]; then
    log_nivel INFO "Instalando Java 8 (OpenJDK 8)..."

    if command -v java &>/dev/null; then
        JAVA_VERSION=$(java -version 2>&1 | head -1)
        log_nivel INFO "Java ja instalado: $JAVA_VERSION"
    else
        log_nivel INFO "Java 8 nao encontrado. Tentando repositorio Adoptium/Temurin..."

        # ------------------------------------------------------------------
        # Determinar codename da distro para o repositorio Adoptium.
        # Adoptium usa nomes de suite baseados no codename Debian/Ubuntu.
        # ------------------------------------------------------------------
        ADOPTIUM_CODENAME=""
        if [ -f /etc/os-release ]; then
            ADOPTIUM_CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
        fi
        if [ -z "$ADOPTIUM_CODENAME" ] && command -v lsb_release &>/dev/null; then
            ADOPTIUM_CODENAME="$(lsb_release -cs 2>/dev/null)"
        fi
        if [ -z "$ADOPTIUM_CODENAME" ]; then
            log_nivel AVISO "nao foi possivel detectar codename. Usando bookworm."
            ADOPTIUM_CODENAME="bookworm"
        fi
        log_nivel INFO "Codename Adoptium: $ADOPTIUM_CODENAME"

        # ------------------------------------------------------------------
        # Adicionar chave GPG do Adoptium.
        # Download publico: respeita proxy do ambiente se houver.
        # ------------------------------------------------------------------
        if wget -q --timeout=20 -O /tmp/adoptium-key.asc \
                "https://packages.adoptium.net/artifactory/api/gpg/key/public"; then
            gpg --dearmor < /tmp/adoptium-key.asc \
                > /usr/share/keyrings/adoptium-keyring.gpg 2>/dev/null || true
            rm -f /tmp/adoptium-key.asc

            echo "deb [signed-by=/usr/share/keyrings/adoptium-keyring.gpg] https://packages.adoptium.net/artifactory/deb ${ADOPTIUM_CODENAME} main" \
                > /etc/apt/sources.list.d/adoptium.list

            apt-get update -qq
            if apt-get install -y temurin-8-jre; then
                log_nivel INFO "Temurin 8 instalado via Adoptium"
            else
                log_nivel AVISO "Falha ao instalar temurin-8-jre."
                log_nivel INFO "Verifique se Adoptium tem suite '$ADOPTIUM_CODENAME'."
                # Limpa o repo para nao atrapalhar proximos apt-get update
                rm -f /etc/apt/sources.list.d/adoptium.list
                apt-get update -qq 2>/dev/null || true
            fi
        else
            log_nivel AVISO "Nao foi possivel baixar a chave GPG do Adoptium."
            log_nivel INFO "Java 8 legado nao sera instalado por aqui."
        fi
    fi

    # ------------------------------------------------------------------
    # Excecoes Java (deployment.properties) - se fornecidas
    # ------------------------------------------------------------------
    if [ -n "$JAVA_EXCEPTIONS" ]; then
        log_nivel INFO "Configurando excecoes Java..."
        DEPLOY_DIR="/usr/lib/jvm/.deployment"
        mkdir -p "$DEPLOY_DIR"
        DEPLOY_FILE="$DEPLOY_DIR/deployment.properties"
        {
            echo "# Excecoes Java - SeederLinux"
            echo "deployment.security.level=MEDIUM"
        } > "$DEPLOY_FILE"

        IDX=0
        IFS=$'\n,' read -ra EXC_URLS <<< "$JAVA_EXCEPTIONS"
        for EXC_URL in "${EXC_URLS[@]}"; do
            EXC_URL="$(echo "$EXC_URL" | xargs)"
            if [ -n "$EXC_URL" ]; then
                echo "javaws.allow.${IDX}=$EXC_URL" >> "$DEPLOY_FILE"
                IDX=$((IDX+1))
            fi
        done
        log_nivel INFO "Excecoes Java configuradas ($IDX URLs)"
    fi

    if command -v java &>/dev/null; then
        log_nivel INFO "Java instalado: $(java -version 2>&1 | head -1)"
    else
        log_nivel AVISO "Java nao instalado."
    fi
else
    log_nivel INFO "Java 8 desativado (INSTALL_JAVA8=false). Pulando."
fi

# ============================================================
# Firefox 52.7 ESR - apenas se INSTALL_FIREFOX52=true
# ============================================================
if [ "$INSTALL_FIREFOX52" = "true" ]; then
    log_nivel INFO "Instalando Firefox 52.7 ESR..."

    # ------------------------------------------------------------------
    # Pre-requisito: bzip2 para extrair .tar.bz2
    # ------------------------------------------------------------------
    if ! command -v bzip2 &>/dev/null; then
        log_nivel INFO "bzip2 nao instalado. Tentando instalar..."
        apt-get install -y bzip2 2>/dev/null || true
    fi
    if ! command -v bzip2 &>/dev/null; then
        log_nivel AVISO "bzip2 indisponivel - impossivel extrair o tarball do Firefox 52.7."
        log_nivel INFO "Pulando instalacao do Firefox legado (nao e' critico para o ingresso AD)."
        INSTALL_FIREFOX52="false"
    fi
fi

if [ "$INSTALL_FIREFOX52" = "true" ]; then
    FF_LEGADO_DIR="/opt/firefox-legado"
    FF_LEGADO_TARBALL="/tmp/firefox-52.7-esr.tar.bz2"
    FF_LEGADO_URL="${BASE_URL}/downloads/firefox-52.7.3esr.tar.bz2"

    mkdir -p /opt
    rm -f "$FF_LEGADO_TARBALL"

    # ------------------------------------------------------------------
    # Tentativa 1: repositório interno do Seeder
    # Usa --no-proxy (Seeder esta sempre no NO_PROXY).
    # ------------------------------------------------------------------
    if wget -q --no-proxy --timeout=30 -O "$FF_LEGADO_TARBALL" "$FF_LEGADO_URL" 2>/dev/null; then
        if [ -s "$FF_LEGADO_TARBALL" ]; then
            log_nivel INFO "Firefox 52.7 baixado do repositorio interno do Seeder"
            if tar xjf "$FF_LEGADO_TARBALL" -C /opt/ 2>/dev/null; then
                mv /opt/firefox "$FF_LEGADO_DIR" 2>/dev/null || true
            else
                log_nivel AVISO "falha ao extrair tarball do Seeder."
            fi
        else
            log_nivel AVISO "tarball do Seeder baixou vazio."
        fi
        rm -f "$FF_LEGADO_TARBALL"
    else
        # ------------------------------------------------------------------
        # Fallback: Mozilla (download publico)
        # Respeita proxy do ambiente se houver.
        # ------------------------------------------------------------------
        log_nivel AVISO "Nao foi possivel baixar do repositorio interno."
        log_nivel INFO "Tentando Mozilla (ftp.mozilla.org)..."

        FF_MOZILLA_URL="https://ftp.mozilla.org/pub/firefox/releases/52.7.3esr/linux-x86_64/en-US/firefox-52.7.3esr.tar.bz2"
        if wget -q --timeout=60 -O "$FF_LEGADO_TARBALL" "$FF_MOZILLA_URL" 2>/dev/null; then
            if [ -s "$FF_LEGADO_TARBALL" ]; then
                log_nivel INFO "Firefox 52.7 baixado da Mozilla"
                if tar xjf "$FF_LEGADO_TARBALL" -C /opt/ 2>/dev/null; then
                    mv /opt/firefox "$FF_LEGADO_DIR" 2>/dev/null || true
                else
                    log_nivel AVISO "falha ao extrair tarball da Mozilla."
                fi
            else
                log_nivel AVISO "tarball da Mozilla baixou vazio."
            fi
            rm -f "$FF_LEGADO_TARBALL"
        else
            log_nivel AVISO "Nao foi possivel baixar Firefox 52.7 de nenhuma fonte."
        fi
    fi

    # ------------------------------------------------------------------
    # Se extraiu, configura symlink + .desktop
    # ------------------------------------------------------------------
    if [ -d "$FF_LEGADO_DIR" ]; then
        ln -sf "${FF_LEGADO_DIR}/firefox" /usr/local/bin/firefox-legado
        log_nivel INFO "Firefox 52.7 ESR instalado em: $FF_LEGADO_DIR"

        mkdir -p /usr/share/applications
        cat > /usr/share/applications/firefox-legado.desktop <<EOF
[Desktop Entry]
Version=1.0
Name=Firefox 52.7 ESR (Legado)
Comment=Navegador Firefox 52.7 ESR para sistemas legados
Exec=${FF_LEGADO_DIR}/firefox
Icon=${FF_LEGADO_DIR}/browser/icons/mozicon128.png
Terminal=false
Type=Application
Categories=Network;WebBrowser;
EOF
        chmod 644 /usr/share/applications/firefox-legado.desktop
        log_nivel INFO "Entrada de desktop criada"

        # Plugin Java (para applets)
        if command -v java &>/dev/null; then
            log_nivel INFO "Configurando plugin Java para Firefox legado..."
            JAVA_HOME_DIR="$(dirname "$(dirname "$(readlink -f "$(which java)")")")"
            PLUGIN_DIR="${FF_LEGADO_DIR}/browser/plugins"
            mkdir -p "$PLUGIN_DIR"
            if find "$JAVA_HOME_DIR" -name "libnpjp2.so" -exec ln -sf {} "$PLUGIN_DIR/libnpjp2.so" \; 2>/dev/null; then
                log_nivel INFO "Plugin Java configurado"
            else
                log_nivel AVISO "Plugin Java (libnpjp2.so) nao encontrado."
            fi
        fi
    else
        log_nivel AVISO "Firefox 52.7 ESR nao instalado (nenhuma fonte funcionou)."
    fi
else
    log_nivel INFO "Firefox 52.7 desativado (INSTALL_FIREFOX52=false). Pulando."
fi

log_nivel OK "Sistemas legados configurados!"
echo "============================================================"
)
$SeederScript$,
    TRUE,
    TRUE,
    5,
    ARRAY['core_dns.sh', 'core_repositories.sh', 'core_packages.sh']::TEXT[],
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    depends_on = EXCLUDED.depends_on,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Instalacao de Aplicativos Extras (ordem 6) - core_apps.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, depends_on, version, organization_id)
VALUES (
    'Instalacao de Aplicativos Extras',
    'core_apps.sh',
    'Instala aplicacoes extras (OnlyOffice, Chrome, etc).',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_apps.sh
# SeederLinux Lite - OnlyOffice, Chrome, Chromium, Firefox
# ============================================================================
# Instala aplicativos adicionais: OnlyOffice Desktop Editors, Google Chrome
# estavel, Chromium e Firefox ESR.
#
# CORRECOES NESTA VERSAO:
#   1. Checagem final de instalacao do Firefox nao dava mais falso
#      negativo. Antes so testava `firefox-esr` (nome do pacote no
#      Debian). Em Ubuntu/Mint/Zorin o pacote e' `firefox` e o binario
#      e' `firefox` (ou `firefox-esr` em instalacoes mistas). O
#      resultado era o log imprimir "Firefox ESR: NAO INSTALADO"
#      mesmo com o navegador presente - ruido puro de diagnostico.
#      Agora testa os dois nomes (firefox-esr E firefox).
#   2. Checagem final do Chrome idem: o binario pode ser
#      `google-chrome` ou `google-chrome-stable` dependendo do pacote
#      instalado (o .deb oficial instala `google-chrome-stable` como
#      binario principal e cria symlink `google-chrome` em alguns
#      casos, mas nao em todos). Agora testa os dois.
#   3. Adicionada checagem final do Chromium (que antes nao existia -
#      o log nunca confirmava se instalou de fato ou nao, mesmo com
#      INSTALL_CHROMIUM=true).
#   4. Adicionada verificacao final do Firefox legado (instalado pelo
#      core_legados.sh) como item separado, para diferenciar
#      "Firefox ESR do sistema" de "Firefox 52.7 ESR legado em
#      /opt/firefox-legado".
#
# Os placeholders VARIAVEL sao substituidos automaticamente
# pelo sistema na geracao do bundle.
# ============================================================================

(
set -e

source /usr/local/lib/seederlinux/diag.sh 2>/dev/null || true
SCRIPT_ID="06-apps"

echo "============================================================"
echo "Instalar aplicativos (Chrome, OnlyOffice via .deb/wget)"
echo "============================================================"

# ============================================================
# Variáveis
# ============================================================
INSTALL_ONLYOFFICE="{{INSTALL_ONLYOFFICE}}"
INSTALL_CHROME="{{INSTALL_CHROME}}"
INSTALL_CHROMIUM="{{INSTALL_CHROMIUM}}"
BASE_URL="{{BASE_URL}}"
PROXY_MODE="{{PROXY_MODE}}"
PROXY_HTTP="{{PROXY_HTTP}}"
PROXY_PORTA="{{PROXY_PORTA}}"

log_nivel INFO "Instalar OnlyOffice: $INSTALL_ONLYOFFICE"
log_nivel INFO "Instalar Chrome: $INSTALL_CHROME"
log_nivel INFO "Instalar Chromium: $INSTALL_CHROMIUM"

# ============================================================
# Verificar se pelo menos um toggle esta ativo
# ============================================================
if [ "$INSTALL_ONLYOFFICE" != "true" ] && [ "$INSTALL_CHROME" != "true" ] && [ "$INSTALL_CHROMIUM" != "true" ]; then
    log_nivel INFO "Instalacao de apps desativada. Pulando."
    log_nivel INFO "[10] Aplicativos nao instalados (desativado)."
    echo "============================================================"
    exit 0
fi

export DEBIAN_FRONTEND=noninteractive

# ============================================================
# Google Chrome (instalado via .deb/wget, nao via apt-get)
# ============================================================
if [ "$INSTALL_CHROME" = "true" ]; then
    if command -v google-chrome &>/dev/null || command -v google-chrome-stable &>/dev/null; then
        log_nivel INFO "Google Chrome ja instalado - pulando download."
    else
        log_nivel INFO "Instalando Google Chrome..."
        CHROME_DEB="/tmp/google-chrome-stable.deb"

        if wget -q -O "$CHROME_DEB" "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"; then
            dpkg -i "$CHROME_DEB" || apt-get install -y -f
            rm -f "$CHROME_DEB"
        else
            log_nivel AVISO "Nao foi possivel baixar Google Chrome."
            log_nivel INFO "Verifique conectividade e configuracao de proxy."
        fi
    fi
else
    log_nivel INFO "Google Chrome desativado (INSTALL_CHROME=false). Pulando."
fi

# ============================================================
# Chromium (via apt-get)
# ============================================================
if [ "$INSTALL_CHROMIUM" = "true" ]; then
    log_nivel INFO "Instalando Chromium..."
    apt-get install -y chromium 2>/dev/null || \
        apt-get install -y chromium-browser 2>/dev/null || {
        log_nivel AVISO "Nao foi possivel instalar Chromium."
    }
else
    log_nivel INFO "Chromium desativado (INSTALL_CHROMIUM=false). Pulando."
fi

# ============================================================
# OnlyOffice Desktop Editors
# ============================================================
if [ "$INSTALL_ONLYOFFICE" = "true" ]; then
    if command -v onlyoffice-desktopeditors &>/dev/null; then
        log_nivel INFO "OnlyOffice ja instalado - pulando download."
    else
        log_nivel INFO "Instalando OnlyOffice Desktop Editors..."

        # Metodo 1: Via repositorio APT oficial
        ONLYOFFICE_KEY="/tmp/onlyoffice-key.asc"
        ONLYOFFICE_REPO_LIST="/etc/apt/sources.list.d/onlyoffice.list"

        # Baixar e adicionar chave GPG
        if wget -q -O "$ONLYOFFICE_KEY" "https://download.onlyoffice.com/GPG-KEY-ONLYOFFICE"; then
            gpg --dearmor < "$ONLYOFFICE_KEY" > /usr/share/keyrings/onlyoffice-keyring.gpg 2>/dev/null || \
                apt-key add "$ONLYOFFICE_KEY" 2>/dev/null || true

            cat > "$ONLYOFFICE_REPO_LIST" <<EOF
deb [signed-by=/usr/share/keyrings/onlyoffice-keyring.gpg] https://download.onlyoffice.com/repo/debian squeeze main
EOF

        apt-get update
        apt-get install -y onlyoffice-desktopeditors || {
            log_nivel AVISO "Falha ao instalar OnlyOffice via repositorio."
            log_nivel INFO "Tentando download direto..."

            # Metodo 2: Download direto do .deb
            ONLYOFFICE_DEB="/tmp/onlyoffice-desktopeditors.deb"
            if wget -q -O "$ONLYOFFICE_DEB" "https://download.onlyoffice.com/install/desktop/editors/linux/onlyoffice-desktopeditors_amd64.deb"; then
                dpkg -i "$ONLYOFFICE_DEB" || apt-get install -y -f
                rm -f "$ONLYOFFICE_DEB"
            else
                log_nivel AVISO "Nao foi possivel baixar OnlyOffice."
            fi
        }
        rm -f "$ONLYOFFICE_KEY"
    else
        log_nivel AVISO "Nao foi possivel obter chave do OnlyOffice."
        log_nivel INFO "Tentando instalar via repositorio Debian..."

        apt-get install -y onlyoffice-desktopeditors 2>/dev/null || {
            log_nivel AVISO "OnlyOffice nao disponivel. Instalacao ignorada."
        }
    fi
    fi
else
    log_nivel INFO "OnlyOffice desativado (INSTALL_ONLYOFFICE=false). Pulando."
fi

# ============================================================
# Verificacao final de instalacoes
#
# CORRECAO: as checagens abaixo agora testam TODOS os nomes
# possiveis de cada binario, em vez de assumir um unico nome. Isso
# elimina os falsos negativos que apareciam no log:
#   - "Firefox ESR: NAO INSTALADO" quando o pacote e' `firefox`
#     (Ubuntu/Mint/Zorin) em vez de `firefox-esr` (Debian).
#   - Chrome pode vir como `google-chrome` ou `google-chrome-stable`
#     dependendo de como o .deb foi instalado.
# ============================================================
log_nivel INFO "Verificando instalacoes..."

# Firefox: aceita firefox-esr OU firefox (varia por distro)
if command -v firefox-esr &>/dev/null; then
    log_nivel INFO "Firefox ESR: OK (firefox-esr)"
elif command -v firefox &>/dev/null; then
    log_nivel INFO "Firefox ESR: OK (firefox)"
else
    log_nivel INFO "Firefox ESR: NAO INSTALADO"
fi

# Chrome: aceita google-chrome OU google-chrome-stable
if command -v google-chrome &>/dev/null; then
    log_nivel INFO "Google Chrome: OK (google-chrome)"
elif command -v google-chrome-stable &>/dev/null; then
    log_nivel INFO "Google Chrome: OK (google-chrome-stable)"
else
    log_nivel INFO "Google Chrome: NAO INSTALADO"
fi

# Chromium: aceita chromium OU chromium-browser
if command -v chromium &>/dev/null; then
    log_nivel INFO "Chromium: OK (chromium)"
elif command -v chromium-browser &>/dev/null; then
    log_nivel INFO "Chromium: OK (chromium-browser)"
else
    # So reporta "nao instalado" se INSTALL_CHROMIUM=true. Caso
    # contrario, e' o comportamento esperado (toggle desligado).
    if [ "$INSTALL_CHROMIUM" = "true" ]; then
        log_nivel INFO "Chromium: NAO INSTALADO (toggle estava ativo)"
    else
        log_nivel INFO "Chromium: desativado (toggle=false)"
    fi
fi

# OnlyOffice
if command -v onlyoffice-desktopeditors &>/dev/null; then
    log_nivel INFO "OnlyOffice: OK"
else
    if [ "$INSTALL_ONLYOFFICE" = "true" ]; then
        log_nivel INFO "OnlyOffice: NAO INSTALADO (toggle estava ativo)"
    else
        log_nivel INFO "OnlyOffice: desativado (toggle=false)"
    fi
fi

# Firefox 52.7 ESR legado (instalado pelo core_legados.sh, roda antes)
if [ -x /opt/firefox-legado/firefox ]; then
    log_nivel INFO "Firefox 52.7 ESR (legado): OK (/opt/firefox-legado)"
elif [ -x /usr/local/bin/firefox-legado ]; then
    log_nivel INFO "Firefox 52.7 ESR (legado): OK (symlink em /usr/local/bin)"
else
    log_nivel INFO "Firefox 52.7 ESR (legado): nao instalado"
fi

log_nivel OK "Aplicativos instalados!"
echo "============================================================"
)
$SeederScript$,
    TRUE,
    TRUE,
    6,
    ARRAY['core_dns.sh', 'core_repositories.sh', 'core_packages.sh']::TEXT[],
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    depends_on = EXCLUDED.depends_on,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Ingresso em Dominio AD (ordem 7) - core_domain.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, depends_on, version, organization_id)
VALUES (
    'Ingresso em Dominio AD',
    'core_domain.sh',
    'Ingressa a estacao no Active Directory (SSSD/Winbind com fallback).',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_domain.sh (v5 - DNS swap incondicional + resolv.conf imutavel)
# SeederLinux Lite - Gerenciador de Estado do Active Directory
# ============================================================================
# Implementa uma máquina de estados para diagnosticar, classificar e
# corrigir o ingresso no AD, suportando SSSD (realm join) e Winbind
# (net ads join) como fallback.
#
# Estagios: 1) Diagnostico  2) Classificacao  3) Decisao
#           4) Execucao (somente se necessario)  5) Pos-ingresso + Validacao
#
# CONTRATO DE FASES DO BUNDLE (INVARIANTE):
#   Fase 1 (scripts 01..05): DNS de internet ativo. apt/wget funcionam.
#   Fase 2 (ESTE script, PRIMEIRA coisa): troca /etc/resolv.conf para
#     apontar SOMENTE para DNS_PRIMARIO + DNS_SECUNDARIO do AD, e TRAVA
#     o arquivo com chattr +i para o NetworkManager/dhclient nao
#     sobrescreverem em lease renewal.
#   Fase 3 (scripts 07..23): DNS do AD mantido, sem apt-get.
#
# Este script aplica a Fase 2 DE FORMA INCONDICIONAL - independente do
# estado da estacao (nova, ingressada, corrompida). Motivo: o
# core_dns.sh (script 01) SEMPRE reescreve /etc/resolv.conf colocando
# DNS_INTERNET na frente; se a estacao ja esta ingressada, a maquina
# de estados pula o bloco de join e ninguem remove o 8.8.8.8 de novo.
# Consequencia em producao: glibc nao tenta o proximo nameserver em
# NXDOMAIN (so em timeout), entao consultas SRV/LDAP do SSSD falham
# silenciosamente e nomes internos (ex: seederlinux.comara.intraer)
# deixam de resolver apos o ingresso.
#
# O core_dns.sh (script 01) foi ajustado para comecar com
# `chattr -i /etc/resolv.conf 2>/dev/null || true` - isso permite que
# a Fase 1 da proxima execucao escreva no arquivo mesmo se ele estiver
# travado por esta Fase 2. Por isso o `chattr +i` no fim da Fase 2
# (abaixo) agora e' seguro: a trava e' levantada na proxima passagem
# pelo script 01, antes de qualquer escrita.
#
# Os placeholders {{VARIAVEL}} sao substituidos automaticamente
# pelo sistema na geracao do bundle. Variaveis sensiveis usam o
# formato  (substituicao separada, nunca em texto plano
# no restante do bundle).
# ============================================================================

set -e

source /usr/local/lib/seederlinux/diag.sh 2>/dev/null || true
SCRIPT_ID="07-domain"

echo "============================================================"
echo "Gerenciador de Estado do Active Directory"
echo "============================================================"

# ============================================================
# Variáveis (substituídas no bundle)
# ============================================================
DOMINIO="{{DOMINIO}}"
DOMINIO_NETBIOS="{{DOMINIO_NETBIOS}}"
DC_IP="{{DC_IP}}"
DC_IP_LIST="{{DC_IP_LIST}}"
DNS_PRIMARIO="{{DNS_PRIMARIO}}"
DNS_SECUNDARIO="{{DNS_SECUNDARIO}}"
OU_PADRAO="{{OU_PADRAO}}"
GRUPO_ADMIN="{{GRUPO_ADMIN}}"
GRUPO_ADMIN_AD="{{GRUPO_ADMIN_AD}}"
GRUPO_ADMIN_LINUX="{{GRUPO_ADMIN_LINUX}}"
GRUPO_DASTI="{{GRUPO_DASTI}}"
OFFLINE_AUTH_ENABLED="{{OFFLINE_AUTH_ENABLED}}"
OFFLINE_AUTH_DAYS="{{OFFLINE_AUTH_DAYS}}"
ADMIN_USERNAME="{{ADMIN_USERNAME}}"
ADMIN_PASSWORD_B64="__ADMIN_PASSWORD_B64__"
AUTH_METHOD="{{AUTH_METHOD}}"

# ============================================================
# Checagem de sanidade: o backend PHP deve ter substituido os
# placeholders criticos antes de gerar o bundle. Se algum deles
# aparecer literal aqui, e bug do backend (nao deste script) -
# abortar cedo com mensagem clara em vez de deixar o kinit falhar
# silenciosamente mais adiante.
# ============================================================
if [[ "$ADMIN_USERNAME" == *"{{"* ]]; then
    log_nivel ERRO "placeholder ADMIN_USERNAME nao foi substituido pelo backend."
    exit 1
fi
if [[ "$ADMIN_PASSWORD_B64" == "__"* && "$ADMIN_PASSWORD_B64" == *"__" ]]; then
    log_nivel ERRO "placeholder ADMIN_PASSWORD_B64 nao foi substituido pelo backend."
    exit 1
fi

ADMIN_PASSWORD=""
if [ -n "$ADMIN_PASSWORD_B64" ]; then
    ADMIN_PASSWORD=$(printf '%s' "$ADMIN_PASSWORD_B64" | base64 -d 2>/dev/null) || ADMIN_PASSWORD=""
fi
unset ADMIN_PASSWORD_B64

NON_INTERACTIVE="${NON_INTERACTIVE:-false}"
if [ "$NON_INTERACTIVE" = "true" ]; then
    log_nivel INFO "Modo não interativo ativado."
fi

log_nivel INFO "Dominio: $DOMINIO"
log_nivel INFO "NetBIOS: $DOMINIO_NETBIOS"
log_nivel INFO "DC principal: $DC_IP"
[ -n "$DC_IP_LIST" ] && echo ">>> DCs adicionais: $DC_IP_LIST"

# ============================================================
# ============================================================
# FASE 2 — TROCA DE DNS (INCONDICIONAL)
# ============================================================
# Esta secao PRECISA rodar sempre, ANTES de qualquer comando que
# dependa do AD (host, realm, kinit, net ads, sssd, adcli, ldapsearch).
#
# Era o bug principal da versao anterior: a troca de DNS estava
# dentro do `if [ "$ESTADO" = "NAO_INGRESSADO" ]` do ESTAGIO 4. Numa
# estacao ja ingressada, o ESTAGIO 4 nunca executava e o
# /etc/resolv.conf ficava com o DNS_INTERNET (8.8.8.8) que o
# core_dns.sh (script 01) tinha escrito - resultando em NXDOMAIN
# para todo nome interno e SRV do AD.
#
# Idempotente: pode rodar N vezes sem efeito colateral.
# ============================================================
echo "============================================================"
log_nivel INFO "FASE 2: Aplicando DNS do AD (incondicional)"
echo "============================================================"

# Guarda o resolv.conf da Fase 1 para auditoria/debug
if [ -s /etc/resolv.conf ]; then
    cp -f /etc/resolv.conf /etc/resolv.conf.fase1.bak 2>/dev/null || true
fi

# -- Validar que temos pelo menos um DNS do AD definido.
#    Se nao tiver, e erro de configuracao da OM - abortar, porque
#    sem DNS do AD nao ha como ingressar nem manter o ingresso.
if [ -z "$DNS_PRIMARIO" ] || [ "$DNS_PRIMARIO" = "" ]; then
    if [ -n "$DC_IP" ] && [ "$DC_IP" != "" ]; then
        log_nivel AVISO "DNS_PRIMARIO vazio - usando DC_IP ($DC_IP) como fallback."
        DNS_PRIMARIO="$DC_IP"
    else
        log_nivel ERRO "DNS_PRIMARIO e DC_IP vazios. Ingresso impossivel."
        log_nivel INFO "Configure DNS_PRIMARIO na OM antes de gerar o bundle."
        exit 1
    fi
fi

# -- Neutralizar systemd-resolved: o stub 127.0.0.53 nao encaminha
#    consultas SRV (_ldap._tcp.dc._msdcs.$DOMINIO) para o AD, o que
#    quebra a descoberta automatica do SSSD.
systemctl disable --now systemd-resolved 2>/dev/null || true
systemctl stop systemd-resolved 2>/dev/null || true
systemctl disable --now systemd-resolved-monitor.socket 2>/dev/null || true
systemctl disable --now systemd-resolved-varlink.socket 2>/dev/null || true

# -- Remover imutabilidade eventualmente deixada por uma execucao
#    anterior deste script (idempotencia defensiva).
chattr -i /etc/resolv.conf 2>/dev/null || true

# -- Reescrever /etc/resolv.conf com SOMENTE os DNS do AD.
#    Nao usamos DC_IP_LIST aqui - DC_IP_LIST e a lista de
#    controladores de dominio redundantes; DNS_PRIMARIO/DNS_SECUNDARIO
#    sao os servidores DNS propriamente ditos, que podem ter IPs
#    distintos dos DCs.
rm -f /etc/resolv.conf
{
    echo "# SeederLinux - Fase 2 (DNS do AD). NAO EDITAR."
    echo "# Gerado por core_domain.sh em $(date -Is)"
    echo "search ${DOMINIO}"
    echo "nameserver ${DNS_PRIMARIO}"
    if [ -n "$DNS_SECUNDARIO" ] && [ "$DNS_SECUNDARIO" != "" ]; then
        echo "nameserver ${DNS_SECUNDARIO}"
    fi
    echo "options timeout:2 attempts:2 rotate"
} > /etc/resolv.conf

log_nivel INFO "/etc/resolv.conf agora:"
sed 's/^/    /' /etc/resolv.conf

# -- Travar /etc/resolv.conf com chattr +i.
#
#    Motivo: em estacoes com DHCP (NetworkManager), o arquivo e'
#    reescrito a cada renovacao de lease. Sem a trava, o DNS do AD
#    configurado aqui volta a ter o DNS do DHCP (que pode ser
#    8.8.8.8 ou qualquer outro) sem bundle nenhum rodar - e a
#    estacao ingressada comeca a falhar consultas internas
#    silenciosamente.
#
#    Seguranca da trava: o core_dns.sh (script 01) foi ajustado para
#    comecar com `chattr -i /etc/resolv.conf 2>/dev/null || true`
#    antes de escrever. Ou seja, na proxima execucao do bundle, a
#    Fase 1 consegue levantar a trava, escrever o DNS temporario, e
#    a Fase 2 reaplica a trava no fim. Sem essa contrapartida, o
#    `chattr +i` faria o bundle abortar sob `set -e` na proxima
#    execucao.
#
#    Idempotente: chattr +i em arquivo ja imutavel e' no-op.
chattr +i /etc/resolv.conf 2>/dev/null || true

if lsattr /etc/resolv.conf 2>/dev/null | grep -q 'i'; then
    log_nivel INFO "/etc/resolv.conf travado (chattr +i) - NetworkManager nao pode sobrescrever"
else
    log_nivel AVISO "chattr +i nao aplicou (filesystem sem suporte? ex: overlayfs em container)"
fi

# -- Gate: confirmar que o DNS do AD responde ao SRV do dominio
#    antes de seguir. Melhor abortar aqui (erro claro) do que deixar
#    a estacao meio-ingressada.
if command -v host >/dev/null 2>&1; then
    log_nivel INFO "[DNS] Validando SRV _ldap._tcp.dc._msdcs.${DOMINIO} ..."
    if ! host -t SRV "_ldap._tcp.dc._msdcs.${DOMINIO}" >/dev/null 2>&1; then
        # Heuristica: se ja ha artefatos de ingresso, apenas avisar
        # (a estacao pode estar ingressada e o DNS e' "menos bom"
        # que o ideal, mas nao vamos abortar re-provisionamento de
        # uma estacao em producao por isso).
        ALREADY_JOINED_HEURISTIC=false
        if [ -f /etc/krb5.keytab ] && [ -s /etc/krb5.keytab ]; then
            ALREADY_JOINED_HEURISTIC=true
        fi
        if [ -f /etc/sssd/sssd.conf ] && \
           grep -qE '^[[:space:]]*domains[[:space:]]*=' /etc/sssd/sssd.conf 2>/dev/null; then
            ALREADY_JOINED_HEURISTIC=true
        fi

        if [ "$ALREADY_JOINED_HEURISTIC" = "true" ]; then
            log_nivel AVISO "SRV nao resolve, mas a estacao parece ja ingressada"
            log_nivel DIAG "Verificar DNS_PRIMARIO/DNS_SECUNDARIO no painel"
            log_nivel DIAG "Seguindo para validacao do estado atual"
        else
            log_nivel ERRO "SRV _ldap._tcp.dc._msdcs.${DOMINIO} nao resolve"
            log_nivel DIAG "DNS configurado: ${DNS_PRIMARIO} / ${DNS_SECUNDARIO:-<vazio>}"
            log_nivel DIAG "O core_ntp.sh deveria ter rodado antes e sincronizado o relogio"
            log_nivel DIAG "mas o DNS do AD tambem depende de conectividade L3"
            log_nivel ACAO "Verificar conectividade L3 com o DC: ping $DC_IP"
            log_nivel ACAO "Verificar DNS: host $DOMINIO  (deve responder o IP do DC)"
            log_nivel ACAO "Se DNS nao responde: revisar DNS_PRIMARIO no painel"
            exit 1
        fi
    else
        log_nivel OK "[DNS] SRV OK - dominio visivel via DNS do AD"
    fi
else
    log_nivel AVISO "comando 'host' nao encontrado - pulando gate de SRV."
    log_nivel INFO "(isso nao deveria acontecer: 'dnsutils' e' pacote base do bundle)"
fi

log_nivel INFO "[FASE 2] DNS do AD aplicado."
echo "============================================================"

# ============================================================
# ESTÁGIO 1: DIAGNÓSTICO
# ============================================================
echo "============================================================"
log_nivel INFO "ESTÁGIO 1: Diagnóstico do ambiente AD"
echo "============================================================"

# Funções de diagnóstico
check_dns() {
    if host "$DOMINIO" > /dev/null 2>&1; then
        echo "DNS............. OK ($DOMINIO resolve)"
        return 0
    else
        echo "DNS............. FALHA ($DOMINIO não resolve)"
        return 1
    fi
}

check_kerberos_config() {
    if [ -f /etc/krb5.conf ]; then
        echo "Kerberos........ OK (configurado)"
        return 0
    else
        echo "Kerberos........ FALHA (não configurado)"
        return 1
    fi
}

check_ticket() {
    if klist -s 2>/dev/null; then
        echo "Ticket.......... OK ($(klist | grep 'Default principal' | awk '{print $3}'))"
        return 0
    else
        echo "Ticket.......... NÃO (sem ticket ativo)"
        return 1
    fi
}

check_realm() {
    if realm list 2>/dev/null | grep -q "$DOMINIO"; then
        echo "Realm........... OK (associado)"
        return 0
    else
        echo "Realm........... NÃO (não associado)"
        return 1
    fi
}

check_sssd() {
    if systemctl is-active --quiet sssd 2>/dev/null; then
        echo "SSSD............ OK (ativo)"
        return 0
    else
        echo "SSSD............ NÃO (parado)"
        return 1
    fi
}

check_winbind() {
    if systemctl is-active --quiet winbind 2>/dev/null; then
        echo "Winbind......... OK (ativo)"
        return 0
    else
        echo "Winbind......... NÃO (parado)"
        return 1
    fi
}

check_keytab() {
    if [ -f /etc/krb5.keytab ] && [ -s /etc/krb5.keytab ]; then
        echo "Keytab.......... OK (presente)"
        return 0
    else
        echo "Keytab.......... NÃO (ausente ou vazio)"
        return 1
    fi
}

check_machine_account() {
    if net ads testjoin > /dev/null 2>&1; then
        echo "Conta AD........ OK (verificada)"
        return 0
    else
        if adcli testjoin --domain="$DOMINIO" > /dev/null 2>&1; then
            echo "Conta AD........ OK (adcli)"
            return 0
        else
            echo "Conta AD........ NÃO (não verificada)"
            return 1
        fi
    fi
}

check_time_sync() {
    if timedatectl status 2>/dev/null | grep -q "synchronized: yes"; then
        echo "Sinc. Tempo..... OK"
        return 0
    else
        echo "Sinc. Tempo..... NÃO (pode afetar Kerberos)"
        return 1
    fi
}

# Executar diagnóstico
echo ""
echo "--- Coletando informações ---"
DNS_OK=true && check_dns || DNS_OK=false
KRB5_OK=true && check_kerberos_config || KRB5_OK=false
TICKET_OK=true && check_ticket || TICKET_OK=false
REALM_OK=true && check_realm || REALM_OK=false
SSSD_OK=true && check_sssd || SSSD_OK=false
WINBIND_OK=true && check_winbind || WINBIND_OK=false
KEYTAB_OK=true && check_keytab || KEYTAB_OK=false
MACHINE_OK=true && check_machine_account || MACHINE_OK=false
TIME_OK=true && check_time_sync || TIME_OK=false
echo "================================"

# ============================================================
# Helpers de saida do dominio - sempre com senha via stdin (ou
# /dev/null se nao houver) para nunca ficar esperando prompt
# interativo em execucao via cron/push remoto.
# ============================================================
realm_leave_safe() {
    if [ -n "$ADMIN_PASSWORD" ]; then
        echo "$ADMIN_PASSWORD" | realm leave "$DOMINIO" -U "$ADMIN_USERNAME" 2>/dev/null || true
    else
        realm leave "$DOMINIO" -U "$ADMIN_USERNAME" < /dev/null 2>/dev/null || true
    fi
}

net_ads_leave_safe() {
    if [ -n "$ADMIN_PASSWORD" ]; then
        echo "$ADMIN_PASSWORD" | net ads leave -U "$ADMIN_USERNAME" 2>/dev/null || true
    else
        net ads leave -U "$ADMIN_USERNAME" < /dev/null 2>/dev/null || true
    fi
}

# ============================================================
# ESTÁGIO 2: CLASSIFICAR ESTADO
# ============================================================
echo ""
log_nivel INFO "ESTÁGIO 2: Classificando estado atual"

if [ "$REALM_OK" = "true" ] && [ "$SSSD_OK" = "true" ] && [ "$KEYTAB_OK" = "true" ]; then
    if [ "$WINBIND_OK" = "true" ]; then
        ESTADO="INGRESSADO_HIBRIDO"
    else
        ESTADO="INGRESSADO_SSSD"
    fi
elif [ "$WINBIND_OK" = "true" ] && [ "$MACHINE_OK" = "true" ]; then
    ESTADO="INGRESSADO_WINBIND"
elif [ "$REALM_OK" = "false" ] && [ "$WINBIND_OK" = "false" ] && [ "$MACHINE_OK" = "false" ] && [ "$KEYTAB_OK" = "false" ]; then
    ESTADO="NAO_INGRESSADO"
elif [ "$REALM_OK" = "true" ] && [ "$KEYTAB_OK" = "false" ]; then
    ESTADO="CORROMPIDO"
elif [ "$REALM_OK" = "true" ] && [ "$SSSD_OK" = "false" ]; then
    ESTADO="PARCIAL"
elif [ "$MACHINE_OK" = "true" ] || [ "$KEYTAB_OK" = "true" ]; then
    # Ha vestigios de um ingresso anterior (conta AD e/ou keytab) que nao
    # bate com nenhum padrao "limpo" acima - tratar como CORROMPIDO em vez
    # de INDETERMINADO, para passar pela limpeza (leave + remove keytab)
    # antes de tentar um join novo. Evita duplicar a conta no AD.
    ESTADO="CORROMPIDO"
else
    ESTADO="INDETERMINADO"
fi

log_nivel INFO "Estado detectado: $ESTADO"

# ============================================================
# Bloqueio preventivo: tempo quebrado antes de tentar ingresso.
# (DNS nao entra mais aqui - ja foi corrigido na FASE 2 acima.
#  Se ainda estiver quebrado, o gate de SRV ja abortou.)
# ============================================================
if [ "$ESTADO" = "NAO_INGRESSADO" ] || [ "$ESTADO" = "INDETERMINADO" ]; then
    if [ "$TIME_OK" = "false" ]; then
        echo ""
        log_nivel AVISO "relogio fora de sincronia (Kerberos rejeita diferenca > 5min)."
        log_nivel INFO "O kinit provavelmente vai falhar com 'Clock skew too great'."
        if [ "$NON_INTERACTIVE" = "true" ]; then
            log_nivel INFO "Modo nao interativo: prosseguindo mesmo assim (provavel falha adiante)."
        else
            read -p ">>> Deseja continuar mesmo assim? (s/N): " CONTINUE_APESAR_DE
            if [[ ! "$CONTINUE_APESAR_DE" =~ ^[Ss]$ ]]; then
                log_nivel INFO "Instalação abortada pelo usuário."
                exit 1
            fi
        fi
    fi
fi

# ============================================================
# ESTÁGIO 3: DECISÃO
# ============================================================
echo ""
log_nivel INFO "ESTÁGIO 3: Decisão sobre ação necessária"

case "$ESTADO" in
    INGRESSADO_SSSD|INGRESSADO_HIBRIDO)
        log_nivel INFO "A máquina já está ingressada via SSSD."
        if [ "$NON_INTERACTIVE" = "true" ]; then
            REINGRESSAR="n"
        else
            read -p ">>> Deseja reingressar (remover e ingressar novamente)? (s/N): " REINGRESSAR
        fi
        if [[ "$REINGRESSAR" =~ ^[Ss]$ ]]; then
            log_nivel INFO "Removendo ingresso existente..."
            realm_leave_safe
            net_ads_leave_safe
            ESTADO="NAO_INGRESSADO"
        else
            log_nivel INFO "Mantendo ingresso existente. Pulando ingresso."
        fi
        ;;

    INGRESSADO_WINBIND)
        log_nivel INFO "A máquina está ingressada via Winbind (método legado)."
        log_nivel INFO "Recomenda-se migrar para SSSD."
        if [ "$NON_INTERACTIVE" = "true" ]; then
            MIGRAR="s"
        else
            read -p ">>> Deseja migrar para SSSD (remover Winbind e ingressar via realm)? (S/n): " MIGRAR
        fi
        if [[ ! "$MIGRAR" =~ ^[Nn]$ ]]; then
            log_nivel INFO "Removendo ingresso Winbind..."
            net_ads_leave_safe
            systemctl stop winbind 2>/dev/null || true
            ESTADO="NAO_INGRESSADO"
        else
            log_nivel INFO "Mantendo Winbind. Pulando ingresso."
        fi
        ;;

    CORROMPIDO|PARCIAL)
        log_nivel AVISO "Estado inconsistente detectado ($ESTADO)."
        log_nivel INFO "Possíveis causas: keytab ausente, SSSD parado, ou ingresso parcial."
        if [ "$NON_INTERACTIVE" = "true" ]; then
            REPARAR="s"
        else
            read -p ">>> Deseja reparar automaticamente? (S/n): " REPARAR
        fi
        if [[ ! "$REPARAR" =~ ^[Nn]$ ]]; then
            log_nivel INFO "Executando limpeza completa..."
            realm_leave_safe
            net_ads_leave_safe
            rm -f /etc/krb5.keytab
            systemctl stop sssd 2>/dev/null || true
            systemctl stop winbind 2>/dev/null || true
            # Limpar caches
            rm -rf /var/lib/sss/db/* 2>/dev/null || true
            rm -rf /var/lib/sss/mc/* 2>/dev/null || true
            ESTADO="NAO_INGRESSADO"
            log_nivel INFO "Limpeza concluída."
        else
            log_nivel INFO "Prosseguindo sem reparar (pode falhar)."
        fi
        ;;

    INDETERMINADO)
        log_nivel INFO "Estado indeterminado. Tentando ingresso como máquina nova."
        ESTADO="NAO_INGRESSADO"
        ;;
esac

# ============================================================
# ESTÁGIO 4: EXECUÇÃO (apenas se necessário)
# ============================================================
# NOTA: a troca de DNS NAO fica mais aqui - foi movida para a FASE 2
# incondicional, no topo do script. Isso garante que mesmo uma
# estacao ja ingressada (que pula este bloco inteiro) fique com o
# /etc/resolv.conf correto apos o bundle rodar.
# ============================================================
if [ "$ESTADO" = "NAO_INGRESSADO" ]; then
    echo ""
    log_nivel INFO "ESTÁGIO 4: Executando ingresso no domínio"

    # Configurar Kerberos
    log_nivel INFO "Configurando Kerberos..."
    REALM="${DOMINIO^^}"
    # CORRECAO: dns_lookup_kdc=false (era true) - nao depender de SRV
    # ja que acabamos de desativar o encaminhamento via
    # systemd-resolved; kdc listado por FQDN E IP como redundancia;
    # default_ccache_name para integracao com keyring do systemd;
    # kpasswd_server para permitir troca de senha pelo usuario.
    cat > /etc/krb5.conf <<EOF
[libdefaults]
    default_realm = ${REALM}
    dns_lookup_realm = false
    dns_lookup_kdc = false
    rdns = false
    ticket_lifetime = 24h
    forwardable = yes
    renew_lifetime = 7d
    udp_preference_limit = 0
    default_ccache_name = KEYRING:persistent:%{uid}

[realms]
    ${REALM} = {
        kdc = dc-${OM_ACRONYM,,}.${DOMINIO}
        kdc = ${DC_IP}
        admin_server = dc-${OM_ACRONYM,,}.${DOMINIO}
        kpasswd_server = dc-${OM_ACRONYM,,}.${DOMINIO}
    }

[domain_realm]
    .${DOMINIO} = ${REALM}
    ${DOMINIO} = ${REALM}
EOF

    # Configurar Samba
    log_nivel INFO "Configurando Samba..."
    cat > /etc/samba/smb.conf <<EOF
[global]
    workgroup = ${DOMINIO_NETBIOS}
    realm = ${DOMINIO}
    security = ads
    dns forwarder = ${DC_IP}
    kerberos method = secrets and keytab
    idmap config * : backend = tdb
    idmap config * : range = 3000-7999
    idmap config ${DOMINIO_NETBIOS} : backend = rid
    idmap config ${DOMINIO_NETBIOS} : range = 10000-999999
    template shell = /bin/bash
    template homedir = /home/%D/%U
    winbind use default domain = true
    winbind offline logon = false
    winbind nss info = rfc2307
    winbind enum users = no
    winbind enum groups = no
    load printers = no
    printing = bsd
    printcap name = /dev/null
    disable spoolss = yes
EOF

    # Obter ticket Kerberos
    log_nivel INFO "Obtendo ticket Kerberos..."
    KINIT_OK=false

    # Tentar com pipe se ADMIN_PASSWORD estiver disponível
    if [ -n "$ADMIN_PASSWORD" ]; then
        log_nivel INFO "Tentando obter ticket com senha pre-definida..."
        KINIT_HAS_PWFILE=false
        if kinit --help 2>&1 | grep -q -- '--password-file'; then
            KINIT_HAS_PWFILE=true
        fi
        log_nivel INFO "suporte a --password-file: $KINIT_HAS_PWFILE"

        for TRY_USER in \
            "${ADMIN_USERNAME}@${REALM}" \
            "${ADMIN_USERNAME}@${DOMINIO_NETBIOS}" \
            "${ADMIN_USERNAME,,}@${REALM}" \
            "${ADMIN_USERNAME,,}@${DOMINIO,,}"; do
            log_nivel INFO "tentando kinit para ${TRY_USER}..."
            if [ "$KINIT_HAS_PWFILE" = "true" ]; then
                if printf '%s\n' "$ADMIN_PASSWORD" | kinit --password-file=- "$TRY_USER" >/tmp/kinit-out.txt 2>&1; then
                    KINIT_OK=true
                    log_nivel INFO "OK"
                    break
                else
                    log_nivel INFO "falhou: $(head -3 /tmp/kinit-out.txt 2>/dev/null | tr '\n' ' ')"
                fi
            else
                if printf '%s\n' "$ADMIN_PASSWORD" | kinit "$TRY_USER" >/tmp/kinit-out.txt 2>&1; then
                    KINIT_OK=true
                    log_nivel INFO "OK"
                    break
                else
                    log_nivel INFO "falhou: $(head -3 /tmp/kinit-out.txt 2>/dev/null | tr '\n' ' ')"
                fi
            fi
        done
        rm -f /tmp/kinit-out.txt
    elif [ "$NON_INTERACTIVE" = "true" ]; then
        log_nivel ERRO "ADMIN_PASSWORD nao definido em modo nao interativo."
    fi

    # Modo interativo se pipe falhou
    if [ "$KINIT_OK" != "true" ] && [ "$NON_INTERACTIVE" != "true" ]; then
        log_nivel INFO "Não foi possível obter ticket automaticamente."
        log_nivel INFO "Solicitando credenciais interativamente..."
        while [ "$KINIT_OK" != "true" ]; do
            if [ -z "$ADMIN_USERNAME" ] || [ "$ADMIN_USERNAME" = "Administrator" ]; then
                read -p ">>> Usuário do domínio: " input_user
                [ -n "$input_user" ] && ADMIN_USERNAME="$input_user"
            else
                log_nivel INFO "Usuário: ${ADMIN_USERNAME}"
            fi

            log_nivel INFO "Tentando kinit para ${ADMIN_USERNAME}@${REALM} ..."
            if kinit "${ADMIN_USERNAME}@${REALM}"; then
                KINIT_OK=true
            else
                log_nivel INFO "Falhou. Verifique a senha e conectividade com o DC."
                read -p ">>> Tentar novamente? (S/n): " try_again
                [[ "$try_again" =~ ^[Nn]$ ]] && break
                ADMIN_USERNAME=""
            fi
        done
    fi

    # Abortar em non-interactive quando kinit falha - sem isso o
    # script segue com JOIN_METHOD=nenhum e deixa a estacao em estado
    # "meio-ingressada" (pior cenario para depurar).
    if [ "$KINIT_OK" != "true" ]; then
        log_nivel ERRO "Falha ao obter ticket Kerberos."
        log_nivel INFO "Verifique as credenciais e conectividade com o DC."
        exit 1
    fi
    log_nivel OK "Ticket Kerberos obtido com sucesso!"

    # Tentar ingresso via realm join (SSSD)
    JOIN_OK=false
    JOIN_METHOD=""

    # --computer-ou so e passado quando definido; vazio faz o AD
    # usar a OU padrao de computadores em vez de rejeitar o join
    REALM_JOIN_ARGS=(--user="$ADMIN_USERNAME" --verbose)
    if [ -n "$OU_PADRAO" ]; then
        REALM_JOIN_ARGS+=(--computer-ou="$OU_PADRAO")
    fi

    log_nivel INFO "Ingressando no dominio via realm join (SSSD)..."
    if echo "$ADMIN_PASSWORD" | realm join "$DOMINIO" "${REALM_JOIN_ARGS[@]}" 2>&1; then
        JOIN_OK=true
        JOIN_METHOD="sssd"
        log_nivel OK "Ingresso via SSSD (realm join) bem-sucedido!"
    else
        log_nivel ERRO "realm join falhou"
        log_nivel DIAG "Kerberos rejeitou o ticket antes de validar a senha"
        log_nivel DIAG "3 causas provaveis, em ordem de probabilidade:"
        log_nivel DIAG "  1. Clock skew > 5min (servidor e estacao fora de sincronia)"
        log_nivel DIAG "  2. Senha do admin de ingresso incorreta no painel"
        log_nivel DIAG "  3. Conta bloqueada ou sem permissao para ingresso"
        log_nivel ACAO "Confirmar horario: seederlinux-sync-ntp  (ou 'date' vs horario do AD)"
        log_nivel ACAO "Se senha: refazer bundle no painel com a senha correta"
        log_nivel ACAO "Se conta: desbloquear no AD (ADUC / Set-ADAccount -Enabled)"
    fi

    # Fallback: net ads join (Winbind)
    if [ "$JOIN_OK" != "true" ]; then
        log_nivel INFO "Tentando fallback com net ads join (Winbind)..."

        if ! grep -q "kerberos method" /etc/samba/smb.conf; then
            sed -i '/\[global\]/a\    kerberos method = secrets and keytab' /etc/samba/smb.conf
        fi

        # -S aceita IP diretamente; usar DC_IP em vez de tentar
        # adivinhar o hostname do DC por convencao de nome
        NET_JOIN_ARGS=(-U "$ADMIN_USERNAME" -S "$DC_IP")
        if [ -n "$OU_PADRAO" ]; then
            NET_JOIN_ARGS+=(createcomputer="$OU_PADRAO")
        fi

        if echo "$ADMIN_PASSWORD" | net ads join "$DOMINIO" "${NET_JOIN_ARGS[@]}" 2>&1; then
            JOIN_OK=true
            JOIN_METHOD="winbind"
            log_nivel OK "Ingresso via Winbind (net ads join) bem-sucedido!"

            # net ads join NAO gera o keytab de maquina sozinho.
            # Como ja temos um ticket Kerberos valido em cache (kinit
            # acima), "net ads keytab create" usa esse cache
            # automaticamente - nao aceita/precisa de senha via -P.
            log_nivel INFO "Gerando keytab..."
            if ! net ads keytab create 2>/dev/null; then
                log_nivel INFO "net ads keytab create falhou. Tentando via adcli..."
                echo "$ADMIN_PASSWORD" | adcli join "$DOMINIO" \
                    --login-user="$ADMIN_USERNAME" \
                    ${OU_PADRAO:+--domain-ou="$OU_PADRAO"} \
                    --stdin-password 2>&1 || {
                    log_nivel AVISO "Falha ao gerar keytab. Login offline pode nao funcionar."
                }
            fi
        else
            log_nivel ERRO "net ads join falhou"
            log_nivel DIAG "SSSD falhou E Winbind tambem falhou - problema e' mais fundo"
            log_nivel DIAG "Provavel: DNS do AD nao resolve, ou firewall L3 bloqueando,"
            log_nivel DIAG "         ou conta de maquina ja existe no AD (duplicata)"
            log_nivel ACAO "Verificar: host -t SRV _ldap._tcp.dc._msdcs.$DOMINIO"
            log_nivel ACAO "Verificar: ping ao DC e portas 389/445/88 abertas"
            log_nivel ACAO "Se conta duplicada: remover do AD e reexecutar bundle"
        fi
    fi

    if [ "$JOIN_OK" != "true" ]; then
        log_nivel ERRO "Falha ao ingressar no domínio com todos os métodos."
        if [ "$NON_INTERACTIVE" = "true" ]; then
            CONTINUE="s"
        else
            read -p ">>> Deseja continuar mesmo assim? (S/n): " CONTINUE
        fi
        if [[ "$CONTINUE" =~ ^[Nn]$ ]]; then
            log_nivel INFO "Instalação abortada pelo usuário."
            exit 1
        fi
        JOIN_METHOD="nenhum"
    fi
fi  # Fim do bloco de ingresso

# ============================================================
# ESTÁGIO 5: CONFIGURAÇÃO PÓS-INGRESSO E VALIDAÇÃO
# ============================================================
echo ""
log_nivel INFO "ESTÁGIO 5: Configuração e validação"

# Configurar SSSD (se método for sssd)
if [ "$JOIN_METHOD" = "sssd" ] || [ "$ESTADO" = "INGRESSADO_SSSD" ] || [ "$ESTADO" = "INGRESSADO_HIBRIDO" ]; then
    log_nivel INFO "Configurando SSSD..."
    OFFLINE_CACHE=""
    if [ "$OFFLINE_AUTH_ENABLED" = "true" ]; then
        OFFLINE_CACHE="$(printf '    cache_credentials = true\n    krb5_store_password_if_offline = true\n    offline_credentials_expiration = %s' "${OFFLINE_AUTH_DAYS:-3}")"
    fi

    # ad_hostname: evitar duplicar o dominio se o hostname atual ja
    # vier como FQDN (ex: se um core_dns.sh anterior setou
    # hostnamectl com FQDN completo). Sem isso, sssd.conf fica com
    # "host.dominio.dominio" e o SSSD nao sobe.
    _HN_NOW="$(hostname)"

    # Se o hostname ja termina com .$DOMINIO, e FQDN real — usa como esta.
    # Senao, pega so a primeira parte (antes do primeiro ponto) e
    # adiciona o dominio. Isso evita que hostnames como
    # "seeder-client11.2" virem "seeder-client11.2" no ad_hostname,
    # quando o SPN no AD e "seeder-client11".
    if echo "$_HN_NOW" | grep -q "\.${DOMINIO}$"; then
        SSSD_AD_HOSTNAME="$_HN_NOW"
    else
        _HN_SHORT="${_HN_NOW%%.*}"
        SSSD_AD_HOSTNAME="${_HN_SHORT}.${DOMINIO}"
    fi

    # /home/%u (nao /home/%d/%u): o snap do Firefox no Ubuntu 24.04+
    # usa AppArmor que restringe /home/*/snap — /home/dominio/usuario/snap
    # nao bate com o pattern e o snap falha com Permission denied.
    cat > /etc/sssd/sssd.conf <<EOF
[sssd]
services = nss, pam, sudo
config_file_version = 2
domains = ${DOMINIO}

[domain/${DOMINIO}]
    id_provider = ad
    ad_domain = ${DOMINIO}
    ad_server = dc-${OM_ACRONYM,,}.${DOMINIO}
    ad_backup_server = ${DC_IP}
    krb5_server = ${DC_IP}
    krb5_backup_server = ${DC_IP}
    ad_hostname = ${SSSD_AD_HOSTNAME}
    ldap_id_mapping = true
    ldap_schema = ad
    ldap_user_principal = userPrincipalName
    ldap_user_name = sAMAccountName
    ldap_user_gecos = displayName
    ldap_user_home_directory = unixHomeDirectory
    ldap_user_shell = loginShell
    enumerate = false
    use_fully_qualified_names = false
    fallback_homedir = /home/%u
    default_shell = /bin/bash
    krb5_use_fast = never
${OFFLINE_CACHE}
    dyndns_update = false
EOF

    chmod 600 /etc/sssd/sssd.conf
    log_nivel INFO "SSSD configurado (ad_hostname=${SSSD_AD_HOSTNAME})"

    # SSSD 2.9+ (Ubuntu 24.04+): o aviso "Misconfiguration found for
    # the 'nss' responder" entre services= e socket activation e'
    # COSMETICO — nao impede o sssd.service de subir. NAO desabilitar
    # os sockets: no Ubuntu 24.04 o sssd.service depende deles para
    # alguns responders e disable --now quebra o start.
    # Mantemos services = nss, pam, sudo E os sockets convivendo.
    log_nivel INFO "SSSD: mantendo socket activation (nao desabilitar sockets)."
fi

# Configurar NSS
log_nivel INFO "Configurando NSS..."
if [ "$JOIN_METHOD" = "winbind" ]; then
    cat > /etc/nsswitch.conf <<EOF
passwd:     files systemd winbind
shadow:     files winbind
group:      files systemd winbind
gshadow:    files

hosts:      files dns

services:   files
netgroup:   files
sudoers:    files

automount:  files
EOF
else
    cat > /etc/nsswitch.conf <<EOF
passwd:     files systemd sss
shadow:     files sss
group:      files systemd sss
gshadow:    files

hosts:      files dns

services:   files sss
netgroup:   files sss
sudoers:    files sss

automount:  files sss
EOF
fi

log_nivel INFO "NSS configurado"

# Configurar PAM (mkhomedir)
log_nivel INFO "Configurando PAM e mkhomedir..."
pam-auth-update --enable mkhomedir --force 2>/dev/null || true

if [ -f /etc/pam.d/common-session ]; then
    grep -q "pam_mkhomedir" /etc/pam.d/common-session || \
        echo "session required pam_mkhomedir.so skel=/etc/skel umask=0022" >> /etc/pam.d/common-session
fi

log_nivel INFO "PAM configurado"

# Configurar sudo para grupos do domínio
log_nivel INFO "Configurando sudo..."
SUDO_FILE="/etc/sudoers.d/seederlinux-domain"
_sudo_candidatos=()

if [ -n "${GRUPO_ADMIN_LINUX:-}" ]; then
    IFS=',' read -ra _tmp <<< "$GRUPO_ADMIN_LINUX"
    for _g in "${_tmp[@]}"; do
        _g="$(echo "$_g" | xargs)"
        [ -n "$_g" ] && _sudo_candidatos+=("$_g")
    done
fi

_sudo_candidatos+=("_dasti" "admins. do domínio")

_sudo_deduplicados=()
while IFS= read -r _g; do
    _sudo_deduplicados+=("$_g")
done < <(printf '%s\n' "${_sudo_candidatos[@]}" | awk '!seen[$0]++')
_sudo_candidatos=("${_sudo_deduplicados[@]}")

# ============================================================
# Aquecer o cache do SSSD antes de consultar getent group.
# Motivo: logo apos restart do sssd, o cache pode estar vazio -
# o getent retorna vazio para grupos que existem no AD, e o
# sudoers fica sem regra (bug observado em campo).
#
# Sentinela: o USUÁRIO de ingresso (ADMIN_USERNAME), que sempre
# existe no AD depois de um kinit bem-sucedido. NÃO usar o
# primeiro grupo da lista de candidatos — alguns podem não
# existir no AD (ex: linux-admins) e o retry giraria 30s à toa.
#
# Estratégia: reinicia sssd, aguarda até 30s com retry no
# sentinela. Se o sentinela resolver, prossegue; se não, avisa
# mas continua (alguns grupos podem não existir mesmo).
# ============================================================
log_nivel INFO "Aguardando cache do SSSD popular..."
systemctl restart sssd 2>/dev/null || true
sleep 3

if [ -n "${ADMIN_USERNAME:-}" ]; then
    _tent=0
    while [ "$_tent" -lt 15 ]; do
        if getent passwd "$ADMIN_USERNAME" >/dev/null 2>&1; then
            log_nivel INFO "Cache populado (usuario '$ADMIN_USERNAME' resolvido)"
            break
        fi
        _tent=$((_tent + 1))
        sleep 2
    done
    if [ "$_tent" -ge 15 ]; then
        log_nivel AVISO "cache do SSSD nao populou '$ADMIN_USERNAME' em 30s"
        log_nivel DIAG  "Pode ser que o SSSD esteja com problema, ou o AD inacessivel"
    fi
else
    log_nivel AVISO "ADMIN_USERNAME vazio - pulando aquecimento do cache"
fi

{
    echo "# SeederLinux - Acesso sudo para grupos do dominio"
    echo "# Regras por GID numerico para evitar problemas com case,"
    echo "# espacos e acentos nos nomes de grupo do AD."
    echo ""

    _sudo_gids_adicionados=0
    for _grupo_nome in "${_sudo_candidatos[@]}"; do
        _gid="$(getent group "$_grupo_nome" 2>/dev/null | cut -d: -f3)"
        if [ -n "$_gid" ]; then
            echo "%#${_gid}    ALL=(ALL:ALL) ALL  # $_grupo_nome"
            _sudo_gids_adicionados=$((_sudo_gids_adicionados + 1))
            echo ">>> Sudoers: grupo '$_grupo_nome' (gid=$_gid) adicionado" >&2
        else
            echo ">>> Sudoers: grupo '$_grupo_nome' nao existe - pulado" >&2
        fi
    done
} > "$SUDO_FILE"

chmod 440 "$SUDO_FILE"
if [ "$_sudo_gids_adicionados" -gt 0 ]; then
    visudo -cf "$SUDO_FILE" || {
        log_nivel ERRO "sintaxe do sudoers inválida"
        exit 1
    }
else
    log_nivel AVISO "nenhum grupo de sudo encontrado no AD."
    log_nivel AVISO "Nenhum usuario de dominio tera sudo nesta estacao."
fi

log_nivel INFO "Sudo configurado"

# Reiniciar serviços
log_nivel INFO "Reiniciando serviços..."
if [ "$JOIN_METHOD" = "sssd" ] || [ "$ESTADO" = "INGRESSADO_SSSD" ] || [ "$ESTADO" = "INGRESSADO_HIBRIDO" ]; then
    systemctl restart sssd 2>/dev/null || true
    systemctl enable sssd
fi

if [ "$JOIN_METHOD" = "winbind" ] || [ "$ESTADO" = "INGRESSADO_WINBIND" ]; then
    systemctl restart winbind 2>/dev/null || true
    systemctl enable winbind
fi

systemctl restart samba 2>/dev/null || true

# ============================================================
# VALIDAÇÃO FINAL
# ============================================================
echo ""
log_nivel INFO "Validação final..."

VALIDATION_OK=true

if [ "$JOIN_METHOD" = "sssd" ] || [ "$ESTADO" = "INGRESSADO_SSSD" ] || [ "$ESTADO" = "INGRESSADO_HIBRIDO" ]; then
    echo "--- Testes SSSD ---"
    if systemctl is-active --quiet sssd; then
        echo "✔ SSSD ativo"
    else
        echo "✘ SSSD NÃO está ativo"
        VALIDATION_OK=false
    fi

    if [ -f /etc/krb5.keytab ] && [ -s /etc/krb5.keytab ]; then
        echo "✔ Keytab presente"
    else
        echo "✘ Keytab ausente ou vazio"
        VALIDATION_OK=false
    fi

    if realm list 2>/dev/null | grep -q "$DOMINIO"; then
        echo "✔ Realm associado"
    else
        echo "✘ Realm NÃO associado"
        VALIDATION_OK=false
    fi
fi

if [ "$JOIN_METHOD" = "winbind" ] || [ "$ESTADO" = "INGRESSADO_WINBIND" ]; then
    echo "--- Testes Winbind ---"
    if systemctl is-active --quiet winbind; then
        echo "✔ Winbind ativo"
    else
        echo "✘ Winbind NÃO está ativo"
        VALIDATION_OK=false
    fi

    if net ads testjoin > /dev/null 2>&1; then
        echo "✔ Testjoin OK"
    else
        echo "✘ Testjoin FALHOU"
        VALIDATION_OK=false
    fi

    if [ -f /etc/krb5.keytab ] && [ -s /etc/krb5.keytab ]; then
        echo "✔ Keytab presente"
    else
        echo "✘ Keytab ausente ou vazio (login offline pode nao funcionar)"
        VALIDATION_OK=false
    fi
fi

if [ "$VALIDATION_OK" = "false" ]; then
    echo ""
    log_nivel AVISO "Alguns testes de validação falharam."
    log_nivel INFO "O ingresso pode não estar completamente funcional."
    if [ "$NON_INTERACTIVE" = "true" ]; then
        CONTINUE="s"
    else
        read -p ">>> Deseja continuar mesmo assim? (S/n): " CONTINUE
    fi
fi

echo ""
log_nivel INFO "Gerenciamento de AD concluído! Método: ${JOIN_METHOD:-$ESTADO}"
echo "============================================================="
$SeederScript$,
    TRUE,
    TRUE,
    7,
    ARRAY['core_dns.sh', 'core_ntp.sh', 'core_packages.sh']::TEXT[],
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    depends_on = EXCLUDED.depends_on,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Configuracao SSH (ordem 8) - core_ssh.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, depends_on, version, organization_id)
VALUES (
    'Configuracao SSH',
    'core_ssh.sh',
    'Configura acesso SSH e politicas de seguranca.',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_ssh.sh
# SeederLinux Lite - Configuracao SSH (porta, AllowGroups)
# Executado APOS o ingresso no AD para que os grupos do dominio existam.
# ============================================================================

set -e

source /usr/local/lib/seederlinux/diag.sh 2>/dev/null || true
SCRIPT_ID="08-ssh"

echo "============================================================"
echo "Configurar SSH"
echo "============================================================"

SSH_PORT="{{SSH_PORT}}"
SSH_GROUPS="{{SSH_GROUPS}}"

log_nivel INFO "Porta SSH: ${SSH_PORT:-22}"
log_nivel INFO "Grupos SSH: ${SSH_GROUPS:-nenhum}"

# Configurar porta
if [ -n "$SSH_PORT" ] && [ "$SSH_PORT" != "" ] && [ "$SSH_PORT" != "22" ]; then
    log_nivel INFO "Configurando porta SSH: $SSH_PORT"
    if [ -f /etc/ssh/sshd_config ]; then
        cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S) 2>/dev/null || true
        sed -i "s/^#*Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
        log_nivel INFO "Porta SSH alterada para $SSH_PORT"
    fi
fi

# ============================================================
# Configurar AllowGroups do sshd
#
# Parse CSV (respeitando aspas duplas) via Python. O resultado
# é um array Bash — NUNCA concatenar em string com espaço,
# senão nomes com espaço (ex: "Domain Admins") são quebrados
# em dois tokens no loop seguinte.
#
# sshd AllowGroups NÃO tem sintaxe para grupos com espaço. Grupos
# com espaço são IGNORADOS no AllowGroups com aviso claro. Para
# permitir via SSH, é preciso `Match Group` (V2).
# ============================================================
if [ -n "$SSH_GROUPS" ] && [ "$SSH_GROUPS" != "" ]; then
    log_nivel INFO "Configurando AllowGroups: $SSH_GROUPS"
    if [ -f /etc/ssh/sshd_config ]; then

        # Parse CSV (respeitando aspas) → array Bash
        GRP_ARRAY=()
        while IFS= read -r _item; do
            [ -z "$_item" ] && continue
            GRP_ARRAY+=("$_item")
        done < <(python3 - "$SSH_GROUPS" <<'PY'
import csv, sys
raw = sys.argv[1] if len(sys.argv) > 1 else ""
for row in csv.reader([raw], skipinitialspace=True):
    for item in row:
        item = item.strip()
        if item:
            print(item)
PY
        )

        # Filtrar: só entra no AllowGroups se existir via getent E não tiver espaço
        GRP_LIST_FILTRADO=""
        _sem_espaco_count=0
        _com_espaco_count=0
        _inexistente_count=0

        for GRP in "${GRP_ARRAY[@]}"; do
            [ -z "$GRP" ] && continue

            # sshd AllowGroups não tem sintaxe para grupo com espaço
            if echo "$GRP" | grep -q ' '; then
                log_nivel AVISO "grupo '$GRP' tem espaco - sshd AllowGroups nao suporta; ignorado"
                log_nivel DIAG  "Para permitir via SSH, use 'Match Group' no sshd_config (V2)"
                _com_espaco_count=$((_com_espaco_count + 1))
                continue
            fi

            if getent group "$GRP" >/dev/null 2>&1; then
                if [ -z "$GRP_LIST_FILTRADO" ]; then
                    GRP_LIST_FILTRADO="$GRP"
                else
                    GRP_LIST_FILTRADO="$GRP_LIST_FILTRADO $GRP"
                fi
                _sem_espaco_count=$((_sem_espaco_count + 1))
            else
                log_nivel AVISO "grupo '$GRP' nao existe - removido do AllowGroups."
                _inexistente_count=$((_inexistente_count + 1))
            fi
        done

        # Escrever o AllowGroups final (só com grupos válidos e sem espaço)
        if [ -n "$GRP_LIST_FILTRADO" ]; then
            sed -i "s/^#*AllowGroups .*/AllowGroups $GRP_LIST_FILTRADO/" /etc/ssh/sshd_config
            if ! grep -q "^AllowGroups " /etc/ssh/sshd_config; then
                echo "AllowGroups $GRP_LIST_FILTRADO" >> /etc/ssh/sshd_config
            fi
            log_nivel INFO "AllowGroups final: $GRP_LIST_FILTRADO"
            log_nivel INFO "  (grupos validos: $_sem_espaco_count | com espaco ignorados: $_com_espaco_count | inexistentes: $_inexistente_count)"
        else
            log_nivel ERRO "nenhum grupo do AllowGroups e' valido - NAO aplicando AllowGroups."
            log_nivel INFO "Verifique o SSH_GROUPS no painel da OM."
            sed -i '/^AllowGroups /d' /etc/ssh/sshd_config 2>/dev/null || true
        fi
    fi
fi

# Ubuntu 24.04+ usa ssh.socket (socket activation) com ListenStream=22
# hardcoded que ignora "Port" do sshd_config. Desabilitar o socket
# para a porta customizada valer e usar o ssh.service tradicional.
if [ -n "$SSH_PORT" ] && [ "$SSH_PORT" != "" ] && [ "$SSH_PORT" != "22" ]; then
    if systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
        systemctl disable --now ssh.socket 2>/dev/null || true
        systemctl mask ssh.socket 2>/dev/null || true
    fi
fi
systemctl enable ssh 2>/dev/null || true

# Reiniciar SSH
if [ -f /etc/ssh/sshd_config ]; then
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
fi

log_nivel OK "SSH configurado!"
echo "============================================================"
$SeederScript$,
    TRUE,
    TRUE,
    8,
    ARRAY['core_domain.sh']::TEXT[],
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    depends_on = EXCLUDED.depends_on,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Politicas de Navegadores (ordem 9) - core_browser.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, depends_on, version, organization_id)
VALUES (
    'Politicas de Navegadores',
    'core_browser.sh',
    'Configura Firefox ESR e Chrome (homepage, proxy, bookmarks) via politicas corporativas.',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_browser.sh
# SeederLinux Lite - Políticas de navegadores (Firefox, Chrome, Chromium)
# ============================================================================
# LIMITAÇÃO DO CHROMIUM (não é bug do bundle):
# Chrome e Chromium NÃO exibem popup de autenticação quando a
# política de proxy é 'fixed_servers' e o proxy exige Basic auth.
# Eles ignoram silenciosamente a credencial e caem em DIRECT.
#
# O bundle nao injeta credenciais nem instala extensoes de
# autenticacao. Para Chrome, use proxy transparente ou consulte o
# administrador da OM. Firefox .deb suporta o popup nativo.
#
# Recomendação para as OMs: preferir Firefox .deb + Squid
# transparente; no Chrome, seguir a orientacao do administrador.
#
# Configura políticas corporativas para Firefox ESR, Google Chrome e
# Chromium, incluindo homepage, proxy, certificados e telemetria.
#
# POLÍTICAS SUPORTADAS (BROWSER_POLICY):
#   DIRECT          -> sem proxy (default)
#   PROXY           -> via proxy (host:port, sem credencial embutida)
#   PROXY_NO_AUTH   -> alias legado de PROXY (retrocompatibilidade)
#   PROXY_WITH_AUTH -> alias legado de PROXY (retrocompatibilidade)
#   PAC             -> via PAC
#   SYSTEM          -> herda proxy do sistema (libproxy)
#
# IMPORTANTE — BROWSER NUNCA RECEBE CREDENCIAL DE PROXY
# ====================================================
# A autenticação de proxy para navegadores é SEMPRE do usuário, não da
# estação. Isso vale para os 3 mecanismos possíveis:
#
#   1. Popup interativo: o browser exibe um diálogo pedindo user/senha
#      na primeira navegação. O usuário digita, o browser guarda no
#      keyring do usuário. Nada disso passa pelo bundle.
#
#   2. SSO/Kerberos: o proxy aceita Negociate/NTLM usando o ticket
#      Kerberos da sessão do usuário (que existe porque a estação
#      está ingressada no AD). Nada a configurar.
#
#   3. Proxy transparente: o proxy não pede auth, o browser só usa.
#
# Por isso NUNCA embutimos user:pass na URL do proxy configurada no
# navegador. Duas razões técnicas, além da conceitual:
#
#   - Chrome/Chromium: o campo "ProxyServer" da policy aceita apenas
#     o formato "scheme=host:port". Se vier com user:pass@, o Chrome
#     IGNORA a policy de proxy (bug silencioso — o browser fica sem
#     proxy sem avisar).
#
#   - Firefox: o enterprise policy "Proxy.HTTPProxy" aceita
#     user:pass@host:port na sintaxe, mas expõe a credencial no
#     arquivo /usr/lib/firefox-esr/distribution/policies.json (modo
#     644, legível por qualquer usuário). Além de inseguro, se o
#     operador trocar a senha dele, o arquivo fica desatualizado
#     silenciosamente. O Firefox também pede a senha no primeiro
#     acesso se o proxy exigir Basic auth — comportamento melhor
#     que credencial estática.
#
# CONCLUSÃO: browser recebe apenas host:port + lista de exceções.
# Credenciais para APT/CLI continuam no cadastro do proxy, mas o
# core_browser.sh as ignora completamente.
#
# MÚLTIPLOS PROXIES:
#   BROWSER_PROXY_NAME aponta para um dos proxies nomeados da OM; se
#   vazio, usa PROXY_DEFAULT_NAME.
#
# PROXY DO FIREFOX — NÃO É CONFIGURADO AQUI (Modelo B)
# ==================================================
# O Firefox recebe proxy POR GRUPO DO AD via
# ~/.mozilla/firefox/seederlinux.default/user.js, escrito pelo
# core_logon.sh (no logon) e reaplicado pelo seeder-sync (a cada
# 10min via seeder-sync.timer). Para isso funcionar, o policies.json
# do Firefox NÃO PODE ter a seção "Proxy" com "Locked": true — se
# tiver, o Firefox ignora o user.js por precedência de policy.
#
# O Chrome/Chromium usa SEMPRE PROXY_DEFAULT_NAME (catch-all) via
# policies.json. Ele não suporta proxy por usuário em máquina
# multi-usuário sem PAC dinâmico (V2).
#
# Os placeholders VARIAVEL são substituídos automaticamente
# pelo sistema na geração do bundle.
# ============================================================================

set -e

source /usr/local/lib/seederlinux/diag.sh 2>/dev/null || true
SCRIPT_ID="09-browser"

echo "============================================================"
echo "Configurar politicas de navegadores"
echo "============================================================"

# ============================================================
# Variáveis (substituídas no bundle)
# ============================================================
HOMEPAGE="{{HOMEPAGE}}"
BROWSER_POLICY="{{BROWSER_POLICY}}"
BROWSER_PROXY_NAME="{{BROWSER_PROXY_NAME}}"
DOMINIO="{{DOMINIO}}"
OM_ACRONYM="{{OM_ACRONYM}}"
SEEDER_SERVER="{{SEEDER_SERVER}}"
DC_IP="{{DC_IP}}"
DC_IP_LIST="{{DC_IP_LIST}}"

# Múltiplos proxies
PROXY_COUNT="${PROXY_COUNT:-0}"
PROXY_DEFAULT_NAME="${PROXY_DEFAULT_NAME:-}"

# Defaults defensivos
[ -z "$BROWSER_POLICY" ] && BROWSER_POLICY="DIRECT"

log_nivel INFO "Homepage: $HOMEPAGE"
log_nivel INFO "BROWSER_POLICY: $BROWSER_POLICY"
log_nivel INFO "BROWSER_PROXY_NAME: ${BROWSER_PROXY_NAME:-<default>}"
log_nivel INFO "Proxies cadastrados: $PROXY_COUNT"

# ============================================================
# Helper: resolver proxy por nome -> host:port (SEMPRE sem credencial)
# ============================================================
# Uso neste script: SOMENTE formato "plain" (host:port).
# A variante "auth" existe em outros scripts (core_proxy.sh,
# core_repositories.sh) para APT/CLI, que precisam de user:pass
# quando o proxy exige auth estática. Aqui NÃO.
#
# Retorna vazio se o proxy não existir, ou se a URL for inválida.
_resolver_proxy_hostport() {
    local name="$1"
    [ -z "$name" ] && return 1
    [ "$PROXY_COUNT" -lt 1 ] 2>/dev/null && return 1

    local i=1
    while [ "$i" -le "$PROXY_COUNT" ]; do
        local v_name="PROXY_${i}_NAME"
        if [ "${!v_name}" = "$name" ]; then
            local v_url="PROXY_${i}_URL"
            local url="${!v_url}"
            [ -z "$url" ] && return 1

            # Extrai só host:port — remove http:// ou https:// e barra
            # final. Ignora PROXY_${i}_USER e PROXY_${i}_PASS_B64 de
            # propósito (ver cabeçalho para o motivo).
            echo "$url" | sed -E 's|^https?://||' | sed 's|/$||'
            return 0
        fi
        i=$((i+1))
    done
    return 1
}

# ============================================================
# Helper: retorna o PAC_URL do proxy nomeado (usado se policy=PAC)
# ============================================================
_resolver_proxy_pac() {
    local name="$1"
    [ -z "$name" ] && return 1
    [ "$PROXY_COUNT" -lt 1 ] 2>/dev/null && return 1

    local i=1
    while [ "$i" -le "$PROXY_COUNT" ]; do
        local v_name="PROXY_${i}_NAME"
        if [ "${!v_name}" = "$name" ]; then
            local v="PROXY_${i}_PAC_URL"
            echo "${!v}"
            return 0
        fi
        i=$((i+1))
    done
    return 1
}

# ============================================================
# Helper: NO_PROXY específico de um proxy
# ============================================================
_resolver_proxy_no_proxy() {
    local name="$1"
    [ -z "$name" ] && return 1
    [ "$PROXY_COUNT" -lt 1 ] 2>/dev/null && return 1

    local i=1
    while [ "$i" -le "$PROXY_COUNT" ]; do
        local v_name="PROXY_${i}_NAME"
        if [ "${!v_name}" = "$name" ]; then
            local v="PROXY_${i}_NO_PROXY"
            echo "${!v}"
            return 0
        fi
        i=$((i+1))
    done
    return 1
}

# ============================================================
# Helper: montar lista de exceções (Passthrough / ProxyBypassList)
# ============================================================
# A lista inclui automaticamente:
#   - localhost e 127.0.0.1 (sempre)
#   - hostname e IP do SEEDER_SERVER (DNS resolvido em runtime)
#   - o domínio AD (sufixo .dominio — Firefox e Chrome aceitam)
#   - DC principal e todos os DCs adicionais
#   - o no_proxy específico do proxy escolhido (se houver)
#
# Formato: lista separada por vírgula. Firefox e Chrome aceitam
# hostname, IP, CIDR e sufixo .dominio.
_build_no_proxy_browser() {
    local extra="$1"
    local base="localhost,127.0.0.1"

    if [ -n "$SEEDER_SERVER" ]; then
        local host
        host="$(echo "$SEEDER_SERVER" | sed -E 's|https?://([^/]+).*|\1|')"
        if [ -n "$host" ]; then
            base="${base},${host}"
            local ip
            ip="$(getent hosts "$host" 2>/dev/null | awk '{print $1}' | head -1)"
            [ -n "$ip" ] && base="${base},${ip}"
        fi
    fi

    [ -n "$DOMINIO" ] && base="${base},.${DOMINIO}"

    if [ -n "$DC_IP" ]; then
        case ",$base," in
            *",$DC_IP,"*) ;;
            *) base="${base},${DC_IP}" ;;
        esac
    fi

    if [ -n "$DC_IP_LIST" ]; then
        local dc
        for dc in $(echo "$DC_IP_LIST" | tr ',' ' '); do
            [ -z "$dc" ] && continue
            case ",$base," in
                *",$dc,"*) ;;
                *) base="${base},${dc}" ;;
            esac
        done
    fi

    [ -n "$extra" ] && base="${base},${extra}"

    # Normalizar: painel guarda "a;b; *.dom" — Firefox/Chrome
    # esperam virgula e sem "*".
    base="$(echo "$base" | tr ';' ',' | tr -d ' ')"
    base="$(echo "$base" | sed 's/^\*\././; s/,\*\./,./g')"

    echo "$base"
}

# ============================================================
# Helper: nome efetivo do proxy conforme a policy
# ============================================================
_resolver_proxy_nome_efetivo() {
    if [ -n "$BROWSER_PROXY_NAME" ]; then
        echo "$BROWSER_PROXY_NAME"
    else
        echo "$PROXY_DEFAULT_NAME"
    fi
}

# ============================================================
# Resolver URL de proxy e NO_PROXY conforme a policy
# ============================================================
# Modelo B: Firefox NÃO recebe proxy em policies.json; o proxy do
# Firefox é resolvido por AD_GROUP via user.js em core_logon.sh.
# O Chrome/Chromium continua recebendo fixed_servers/system/direct.
CHROME_PROXY_MODE="direct"
CHROME_PROXY_SERVER=""
CHROME_PROXY_PAC=""
CHROME_NO_PROXY=""

case "$BROWSER_POLICY" in

    DIRECT|"")
        CHROME_PROXY_MODE="direct"
        ;;

    # PROXY, PROXY_NO_AUTH e PROXY_WITH_AUTH fazem a mesma coisa para
    # browser: aplicam o proxy sem credencial. Os nomes "NO_AUTH" e
    # "WITH_AUTH" são legados do modelo single-proxy e não têm mais
    # significado distinto para navegadores.
    PROXY|PROXY_NO_AUTH|PROXY_WITH_AUTH)
        # Chrome SEMPRE usa PROXY_DEFAULT_NAME (catch-all). Modelo B:
        # Firefox tem proxy por grupo via user.js; Chrome não tem esse
        # mecanismo em multi-usuário. Ignoramos BROWSER_PROXY_NAME aqui.
        NOME="${PROXY_DEFAULT_NAME:-}"
        HOSTPORT="$(_resolver_proxy_hostport "$NOME")" || HOSTPORT=""
        if [ -z "$HOSTPORT" ]; then
            log_nivel AVISO "BROWSER_POLICY=$BROWSER_POLICY mas proxy '${NOME:-<nenhum>}' nao encontrado."
            log_nivel INFO "Aplicando DIRECT para os navegadores."
            CHROME_PROXY_MODE="direct"
        else
            CHROME_NO_PROXY="$(_build_no_proxy_browser "$(_resolver_proxy_no_proxy "$NOME" || echo "")")"

            # --- Chrome: fixed_servers com host:port e bypass list ---
            # Formato OBRIGATÓRIO: "scheme=host:port;scheme=host:port".
            # Se vier user:pass@, o Chrome ignora a policy.
            CHROME_PROXY_MODE="fixed_servers"
            CHROME_PROXY_SERVER="http=${HOSTPORT};https=${HOSTPORT}"

            log_nivel INFO "Proxy aplicado ao Chrome: $HOSTPORT"
            log_nivel INFO "Firefox continua por grupo do AD via user.js; autenticacao por usuario (popup ou SSO)."
        fi
        ;;

    PAC)
        NOME="${PROXY_DEFAULT_NAME:-}"
        PAC_URL="$(_resolver_proxy_pac "$NOME")" || PAC_URL=""
        if [ -z "$PAC_URL" ]; then
            log_nivel AVISO "BROWSER_POLICY=PAC mas PAC_URL vazio para o proxy '${NOME:-<nenhum>}'."
            log_nivel INFO "Aplicando DIRECT para os navegadores."
            CHROME_PROXY_MODE="direct"
        else
            CHROME_PROXY_MODE="pac_script"
            CHROME_PROXY_PAC="$PAC_URL"
        fi
        ;;

    SYSTEM)
        CHROME_PROXY_MODE="system"
        ;;

    *)
        log_nivel AVISO "BROWSER_POLICY desconhecida '$BROWSER_POLICY'. Aplicando DIRECT."
        CHROME_PROXY_MODE="direct"
        ;;
esac

# ============================================================
# Firefox ESR - policies.json
# ============================================================
log_nivel INFO "Configurando policies.json do Firefox..."
mkdir -p /usr/lib/firefox-esr/distribution
cat > /usr/lib/firefox-esr/distribution/policies.json <<EOF
{
    "policies": {
        "DisableTelemetry": true,
        "DisableFirefoxStudies": true,
        "DisablePocket": true,
        "DisableDeveloperTools": false,
        "BlockAboutConfig": false,
        "Homepage": {
            "URL": "${HOMEPAGE}",
            "Locked": true,
            "StartPage": "homepage"
        },
        "SearchBar": "unified",
        "SearchEngines": {
            "Add": [
                { "Name": "${OM_ACRONYM}", "URL": "${HOMEPAGE}", "Method": "GET" }
            ]
        },
        "Certificates": { "ImportEnterpriseRoots": true },
        "ExtensionSettings": { "*": { "installation_mode": "allowed" } },
        "DisableSetDesktopBackground": false,
        "DontCheckDefaultBrowser": true,
        "PrimaryPassword": false,
        "OfferToSaveLogins": false,
        "PasswordManagerEnabled": false,
        "SanitizeOnShutdown": {
            "Cache": true,
            "Cookies": false,
            "Downloads": false,
            "FormData": true,
            "History": false,
            "Sessions": false,
            "SiteSettings": false,
            "OfflineApps": false
        }
    }
}
EOF

# Caminho canônico Debian (firefox-esr) e fallback Ubuntu (firefox).
# Copia para os dois se ambos existirem — em instalações mistas.
for DIR in /usr/lib/firefox-esr /usr/lib/firefox; do
    [ -d "$DIR" ] || continue
    mkdir -p "$DIR/distribution"
    cp /usr/lib/firefox-esr/distribution/policies.json "$DIR/distribution/policies.json" 2>/dev/null || true
done

# Cobertura extra (builds que honram este local alternativo)
for DIR in /etc/firefox/policies /etc/firefox-esr/policies; do
    PARENT="$(dirname "$DIR")"
    [ -d "$PARENT" ] || continue
    mkdir -p "$DIR"
    cp /usr/lib/firefox-esr/distribution/policies.json "$DIR/policies.json" 2>/dev/null || true
done

if [ -d /opt/firefox-moderno ]; then
    mkdir -p /opt/firefox-moderno/distribution
    cp /usr/lib/firefox-esr/distribution/policies.json \
       /opt/firefox-moderno/distribution/policies.json 2>/dev/null || true
fi

log_nivel INFO "Firefox configurado (sem Proxy em policies.json; proxy por user.js via AD)"

# ============================================================
# Chrome / Chromium
# ============================================================
log_nivel INFO "Configurando politicas do Chrome/Chromium..."

case "$CHROME_PROXY_MODE" in
    fixed_servers)
        # Formato: "scheme=host:port;scheme=host:port"
        # SEM user:pass@ — o Chrome não aceita e ignora a policy.
        CHROME_PROXY_JSON=", \"ProxyMode\": \"fixed_servers\", \"ProxyServer\": \"${CHROME_PROXY_SERVER}\""
        if [ -n "$CHROME_NO_PROXY" ]; then
            CHROME_PROXY_JSON="${CHROME_PROXY_JSON}, \"ProxyBypassList\": \"${CHROME_NO_PROXY}\""
        fi
        ;;
    pac_script)
        CHROME_PROXY_JSON=", \"ProxyMode\": \"pac_script\", \"ProxyPacUrl\": \"${CHROME_PROXY_PAC}\""
        ;;
    direct)
        CHROME_PROXY_JSON=", \"ProxyMode\": \"direct\""
        ;;
    system)
        CHROME_PROXY_JSON=", \"ProxyMode\": \"system\""
        ;;
esac

CHROME_POLICY_JSON=$(cat <<EOF
{
    "HomepageLocation": "${HOMEPAGE}",
    "HomepageIsNewTabPage": false,
    "RestoreOnStartup": 4,
    "RestoreOnStartupURLs": ["${HOMEPAGE}"],
    "BrowserSignin": 0,
    "SyncDisabled": true,
    "BlockThirdPartyCookies": true,
    "BackgroundModeEnabled": false,
    "TelemetryReportingEnabled": false,
    "UrlKeyboardsEnabled": false${CHROME_PROXY_JSON},
    "DefaultCookiesSetting": 1,
    "AutoSelectCertificateForUrls": ["{\"pattern\":\"https://*\",\"filter\":{}}"],
    "ChromeCertProtectorEnabled": false
}
EOF
)

for DIR in /etc/opt/chrome/policies/managed \
           /etc/chromium/policies/managed \
           /etc/chromium-browser/policies/managed \
           /var/snap/chromium/current/policies/managed \
           /var/snap/chromium/common/policies/managed; do
    mkdir -p "$DIR" 2>/dev/null || continue
    echo "$CHROME_POLICY_JSON" > "$DIR/seederlinux.json"
    chmod 644 "$DIR/seederlinux.json"
    chown root:root "$DIR/seederlinux.json" 2>/dev/null || true
done

log_nivel INFO "Chrome/Chromium configurado (policy de proxy: $CHROME_PROXY_MODE)"

# Diagnostico: verificar onde a policy realmente ficou gravada
echo ">>> Diagnostico de politicas Chrome/Chromium:"
for DIR in /etc/opt/chrome/policies/managed \
           /etc/chromium/policies/managed \
           /etc/chromium-browser/policies/managed \
           /var/snap/chromium/current/policies/managed \
           /var/snap/chromium/common/policies/managed; do
    if [ -f "$DIR/seederlinux.json" ]; then
        PERMS="$(stat -c '%a %U:%G' "$DIR/seederlinux.json" 2>/dev/null)"
        echo "    [OK] $DIR/seederlinux.json ($PERMS)"
    fi
done

# Aviso: Chrome/Chromium so releem policies no startup.
# Se estiverem rodando agora, o usuario precisa fechar e reabrir
# (ou reiniciar a sessao) para as policies valerem.
CHROME_RODANDO=false
pgrep -x chrome >/dev/null 2>&1 && CHROME_RODANDO=true
pgrep -x chromium >/dev/null 2>&1 && CHROME_RODANDO=true

if [ "$CHROME_RODANDO" = "true" ]; then
    echo ">>> AVISO: Chrome/Chromium estao rodando."
    echo ">>>        Eles NAO releem policies.json ate reiniciar."
    echo ">>>        Feche todos os processos e reabra."
fi

# Detectar snap-chromium (AppArmor pode bloquear leitura de /etc)
if command -v snap >/dev/null 2>&1 && snap list chromium 2>/dev/null | grep -q "^chromium"; then
    echo ">>> AVISO: Chromium via SNAP detectado."
    echo ">>>        AppArmor da snap pode impedir leitura de /etc/chromium/."
    echo ">>>        Se a policy nao aplicar, use: snap set chromium proxy..."
    echo ">>>        ou instale o Chromium via apt (nao snap)."
fi

# ============================================================
# AUTENTICACAO DE PROXY NOS NAVEGADORES — NAO E CONFIGURADA AQUI
# ============================================================
# Firefox e Chrome recebem apenas host:port do proxy. Quando o
# proxy exige autenticacao (ex: GAPE-BE), o usuario digita suas
# credenciais no popup nativo do navegador na primeira navegacao.
# Cada usuario tem a sua — o bundle nao injeta credencial.
#
# Isso vale para os dois navegadores. A extensao de autenticacao
# automatica do Chrome foi removida por decisao de projeto:
# credencial de usuario nao fica em arquivo global lido por todos.
#
# Nota: Chrome/Chromium NAO exibem popup de auth em
# `fixed_servers` — comportamento conhecido. Usuarios precisam
# de extensao manual ou proxy transparente. Isso e' documentado
# no AVISO-PROXY.txt para o usuario final.
# ============================================================

# ============================================================
# Aviso ao usuario sobre proxy por grupo do AD
# ============================================================
log_nivel INFO "Criando aviso de proxy para o usuario..."
mkdir -p /usr/share/doc/seederlinux
cat > /usr/share/doc/seederlinux/AVISO-PROXY.txt <<'AVISOEOF'
AVISO — PROXY CORPORATIVO

Este computador usa proxies corporativos com autenticacao.

- O FIREFOX pede a sua senha do proxy na primeira navegacao
  (popup nativo do browser). Cada usuario tem a sua.
- O CHROME/CHROMIUM nao exibe popup com proxy fixo (limitacao
  conhecida do navegador). Se voce precisar autenticar no
  Chrome, procure o administrador da OM.

O proxy padrao da OM e' o mesmo para todos os usuarios.
Se voce pertence a um grupo especifico (ex: _SPTF), o FIREFOX
usa o proxy do seu grupo apos o login. O CHROME sempre usa o
proxy padrao.

Se voce foi movido de grupo, faca LOGOFF e LOGON novamente
para que o Firefox receba o novo proxy.

Em caso de duvida, procure o administrador da sua OM.
AVISOEOF

cat > /usr/share/applications/seederlinux-aviso-proxy.desktop <<DESKTOPEOF
[Desktop Entry]
Type=Application
Name=Aviso do Proxy
Comment=Leia sobre o proxy corporativo
Exec=xdg-open /usr/share/doc/seederlinux/AVISO-PROXY.txt
Icon=dialog-information
Terminal=false
Categories=System;
DESKTOPEOF

log_nivel INFO "Aviso de proxy criado."

log_nivel OK "Politicas de navegadores configuradas!"
echo "============================================================"
$SeederScript$,
    TRUE,
    TRUE,
    9,
    ARRAY['core_domain.sh']::TEXT[],
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    depends_on = EXCLUDED.depends_on,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Inventario OCS (ordem 10) - core_inventory.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, depends_on, version, organization_id)
VALUES (
    'Inventario OCS',
    'core_inventory.sh',
    'Configura OCS Inventory Agent (sem apt-get; pacote instalado em core_packages.sh).',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_inventory.sh
# SeederLinux Lite - OCS Inventory Agent (configuracao apenas)
# ============================================================================
# Configura o agente do OCS Inventory para coleta de inventario
# automatica da estacao. A instalacao de pacotes e feita no core_packages.sh.
# Os placeholders VARIAVEL sao substituidos automaticamente
# pelo sistema na geracao do bundle.
# ============================================================================

(
set -e

source /usr/local/lib/seederlinux/diag.sh 2>/dev/null || true
SCRIPT_ID="10-inventory"

echo "============================================================"
echo "Configurar OCS Inventory Agent"
echo "============================================================"

# ============================================================
# Variaveis
# ============================================================
INVENTORY_ENABLED="{{INVENTORY_ENABLED}}"
OCS_SERVER="{{OCS_SERVER}}"
OCS_TAG="{{OCS_TAG}}"
GLPI_SERVER="{{GLPI_SERVER}}"

log_nivel INFO "Inventario habilitado: $INVENTORY_ENABLED"

# ============================================================
# Verificar se o inventario esta habilitado
# ============================================================
if [ "$INVENTORY_ENABLED" != "true" ]; then
    log_nivel INFO "Inventario desativado. Pulando configuracao."
    log_nivel INFO "[06] OCS Inventory desativado."
    echo "============================================================"
    exit 0
fi

if [ -z "$OCS_SERVER" ] || [ "$OCS_SERVER" = "" ]; then
    log_nivel AVISO "OCS_SERVER nao definido. Pulando configuracao."
    log_nivel INFO "[06] OCS Inventory nao configurado (servidor ausente)."
    echo "============================================================"
    exit 0
fi

log_nivel INFO "Servidor OCS: $OCS_SERVER"
log_nivel INFO "Tag OCS: $OCS_TAG"

# Normalizar OCS_SERVER: remover http:// ou https:// do prefixo e
# sufixo /ocsinventory se presentes (operador pode cadastrar URL
# completa no painel, mas o agente espera apenas host:port).
OCS_SERVER="$(echo "$OCS_SERVER" | sed -E 's|^https?://||' | sed -E 's|/ocsinventory/?$||' | sed 's|/$||')"
log_nivel INFO "Servidor OCS (normalizado): $OCS_SERVER"

# ============================================================
# Verificar se o pacote foi instalado (no core_packages.sh)
# ============================================================
if ! command -v ocsinventory-agent &>/dev/null; then
    log_nivel AVISO "ocsinventory-agent nao instalado. Pulando configuracao."
    log_nivel INFO "[06] OCS Inventory nao configurado (pacote ausente)."
    echo "============================================================"
    exit 0
fi

# ============================================================
# Configurar agente OCS
# ============================================================
log_nivel INFO "Configurando agente OCS..."
mkdir -p /etc/ocsinventory-agent

cat > /etc/ocsinventory-agent/ocsinventory-agent.cfg <<EOF
# Configuracao do OCS Inventory Agent - SeederLinux
server = ${OCS_SERVER}
tag = ${OCS_TAG}
basepath = /var/lib/ocsinventory-agent
debug = 0
local = no
nosoftware = 0
verbose = 0
EOF

# Arquivo de configuracao para o modulo Perl
OCS_URL="http://${OCS_SERVER}/ocsinventory"
cat > /etc/ocsinventory-agent/modules.conf 2>/dev/null <<EOF
# Modulos do OCS Inventory Agent
OCS_MODE = HTTP
OCS_SERVER = ${OCS_SERVER}
OCS_TAG = ${OCS_TAG}
EOF

# Configurar cron para execucao periodica
log_nivel INFO "Configurando cron do OCS..."
cat > /etc/cron.d/ocsinventory-agent <<EOF
# OCS Inventory Agent - SeederLinux
# Executa a cada 4 horas
0 */4 * * * root /usr/bin/ocsinventory-agent --server=${OCS_SERVER} --tag="${OCS_TAG}" --lazy 2>/dev/null
EOF
chmod 644 /etc/cron.d/ocsinventory-agent

# ============================================================
# Configurar GLPI (se disponivel)
# ============================================================
if [ -n "$GLPI_SERVER" ] && [ "$GLPI_SERVER" != "" ]; then
    log_nivel INFO "Configurando integracao GLPI..."
    mkdir -p /etc/glpi-agent

    cat > /etc/glpi-agent/agent.cfg <<EOF
# Configuracao do GLPI Agent - SeederLinux
server = ${GLPI_SERVER}
tag = ${OCS_TAG}
EOF
fi

# ============================================================
# Execucao inicial do inventario
# ============================================================
log_nivel INFO "Executando coleta inicial de inventario..."
ocsinventory-agent --server="$OCS_SERVER" --tag="$OCS_TAG" --lazy 2>/dev/null || {
    log_nivel AVISO "Falha na coleta inicial. Sera refeito via cron."
}

log_nivel OK "OCS Inventory configurado!"
echo "============================================================"
)
$SeederScript$,
    TRUE,
    TRUE,
    10,
    ARRAY['core_domain.sh']::TEXT[],
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    depends_on = EXCLUDED.depends_on,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Configuracao de Impressoras (ordem 11) - core_printers.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, depends_on, version, organization_id)
VALUES (
    'Configuracao de Impressoras',
    'core_printers.sh',
    'Configura CUPS e impressoras via servidor remoto.',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_printers.sh
# SeederLinux Lite - CUPS e impressoras (configuracao apenas)
# ============================================================================
# Configura o CUPS e instala as impressoras compartilhadas via servidor
# de impressao. A instalacao de pacotes e feita no core_packages.sh.
# Os placeholders VARIAVEL sao substituidos automaticamente
# pelo sistema na geracao do bundle.
# ============================================================================

(
set -e

source /usr/local/lib/seederlinux/diag.sh 2>/dev/null || true
SCRIPT_ID="11-printers"

echo "============================================================"
echo "Configurar CUPS e impressoras"
echo "============================================================"

# ============================================================
# Variaveis
# ============================================================
PRINT_SERVER="{{PRINT_SERVER}}"
DEFAULT_PRINTER="{{DEFAULT_PRINTER}}"
PRINTERS="{{PRINTERS}}"
DOMINIO="{{DOMINIO}}"

log_nivel INFO "Servidor de impressao: $PRINT_SERVER"
log_nivel INFO "Impressora padrao: $DEFAULT_PRINTER"

# Normalizar PRINT_SERVER: remover http:// ou https:// do prefixo e
# barra final (operador pode cadastrar URL completa no painel, mas
# o CUPS/IPP espera apenas host:port).
PRINT_SERVER="$(echo "$PRINT_SERVER" | sed -E 's|^https?://||' | sed 's|/$||')"
log_nivel INFO "Servidor de impressao (normalizado): $PRINT_SERVER"

# ============================================================
# Verificar se ha servidor de impressao
# ============================================================
if [ -z "$PRINT_SERVER" ] || [ "$PRINT_SERVER" = "" ]; then
    log_nivel AVISO "PRINT_SERVER nao definido. Pulando configuracao."
    log_nivel INFO "[07] Impressoras nao configuradas (servidor ausente)."
    echo "============================================================"
    exit 0
fi

# ============================================================
# Verificar se o CUPS foi instalado (no core_packages.sh)
# ============================================================
if ! command -v cupsctl &>/dev/null; then
    log_nivel AVISO "CUPS nao instalado. Pulando configuracao."
    log_nivel INFO "[07] Impressoras nao configuradas (CUPS ausente)."
    echo "============================================================"
    exit 0
fi

# ============================================================
# Configurar CUPS
# ============================================================
log_nivel INFO "Configurando CUPS..."

# Habilitar e iniciar CUPS
systemctl enable cups
systemctl start cups

# Permitir administracao remota e compartilhamento
cupsctl --remote-admin --remote-any --share-printers 2>/dev/null || true

# Configurar cupsd.conf
cat > /etc/cups/cupsd.conf <<EOF
# Configuracao CUPS - SeederLinux
Browsing On
BrowseLocalProtocols dnssd
DefaultAuthType Basic
WebInterface Yes

Listen localhost:631
Listen /run/cups/cups.sock

<Location />
    Order allow,deny
    Allow all
</Location>

<Location /admin>
    Order allow,deny
    Allow all
</Location>

<Location /admin/conf>
    AuthType Default
    Require user @SYSTEM
    Order allow,deny
    Allow all
</Location>
EOF

systemctl restart cups

# ============================================================
# Configurar impressoras via servidor CUPS remoto
# ============================================================
log_nivel INFO "Configurando impressoras via servidor remoto..."

# Criar arquivo de configuracao client.conf do CUPS
cat > /etc/cups/client.conf <<EOF
# Cliente CUPS - SeederLinux
ServerName ${PRINT_SERVER}
EOF

# ============================================================
# Instalar cada impressora listada
# ============================================================
if [ -n "$PRINTERS" ] && [ "$PRINTERS" != "" ]; then
    log_nivel INFO "Instalando impressoras listadas..."
    for PRINTER in $PRINTERS; do
        log_nivel INFO "Configurando impressora: $PRINTER"
        # Adicionar impressora via lpadmin (IPP via servidor)
        lpadmin -p "$PRINTER" -E -v "ipp://${PRINT_SERVER}/printers/${PRINTER}" \
            -m everywhere 2>/dev/null || {
            log_nivel AVISO "Falha ao adicionar impressora $PRINTER"
        }
    done
else
    log_nivel INFO "Nenhuma impressora listada. Usando descoberta automatica."
    # Descoberta automatica via servidor remoto
    lpinfo -h "$PRINT_SERVER" -v 2>/dev/null | grep ipp | while read -r line; do
        PRINTER_URI=$(echo "$line" | awk '{print $2}')
        PRINTER_NAME=$(basename "$PRINTER_URI")
        log_nivel INFO "Impressora encontrada: $PRINTER_NAME"
        lpadmin -p "$PRINTER_NAME" -E -v "$PRINTER_URI" -m everywhere 2>/dev/null || true
    done
fi

# ============================================================
# Definir impressora padrao
# ============================================================
if [ -n "$DEFAULT_PRINTER" ] && [ "$DEFAULT_PRINTER" != "" ]; then
    log_nivel INFO "Definindo impressora padrao: $DEFAULT_PRINTER"
    lpadmin -d "$DEFAULT_PRINTER" 2>/dev/null || {
        log_nivel AVISO "Falha ao definir impressora padrao"
    }
fi

# ============================================================
# Reiniciar CUPS para aplicar
# ============================================================
systemctl restart cups

log_nivel OK "CUPS e impressoras configurados!"
echo "============================================================"
)
$SeederScript$,
    TRUE,
    TRUE,
    11,
    ARRAY['core_domain.sh']::TEXT[],
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    depends_on = EXCLUDED.depends_on,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Configuracao VNC (ordem 12) - core_vnc.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, depends_on, version, organization_id)
VALUES (
    'Configuracao VNC',
    'core_vnc.sh',
    'Configura x11vnc para acesso remoto assistido.',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_vnc.sh
# SeederLinux Lite - x11vnc (configuracao apenas)
# ============================================================================
# Configura o x11vnc para suporte remoto, incluindo servico systemd e
# senha de acesso. A instalacao de pacotes e feita no core_packages.sh.
#
# SEGURANCA: A senha VNC e recebida como VNC_PASSWORD_B64 (base64),
# decodificada em memoria e usada com x11vnc -storepasswd. Nunca
# armazenada em texto plano no bundle ou no disco.
#
# Os placeholders VARIAVEL sao substituidos automaticamente
# pelo sistema na geracao do bundle.
# ============================================================================

(
set -e

source /usr/local/lib/seederlinux/diag.sh 2>/dev/null || true
SCRIPT_ID="12-vnc"

echo "============================================================"
echo "Configurar x11vnc"
echo "============================================================"

# ============================================================
# Variaveis
# ============================================================
VNC_ENABLED="{{VNC_ENABLED}}"
VNC_PASSWORD_B64="__VNC_PASSWORD_B64__"
DISPLAY_MANAGER="{{DISPLAY_MANAGER}}"

# Decodificar senha VNC (armazenada em base64)
if [ -n "$VNC_PASSWORD_B64" ] && [ "$VNC_PASSWORD_B64" != "" ]; then
    VNC_PASSWORD=$(echo "$VNC_PASSWORD_B64" | base64 -d 2>/dev/null)
    if [ -z "$VNC_PASSWORD" ]; then
        log_nivel AVISO "Falha ao decodificar VNC_PASSWORD_B64. Sera gerada senha aleatoria."
    fi
fi
unset VNC_PASSWORD_B64

log_nivel INFO "VNC habilitado: $VNC_ENABLED"

# ============================================================
# Verificar se VNC esta habilitado
# ============================================================
if [ "$VNC_ENABLED" != "true" ]; then
    log_nivel INFO "VNC desativado. Pulando configuracao."
    log_nivel INFO "[08] x11vnc desativado."
    echo "============================================================"
    exit 0
fi

# ============================================================
# Verificar se o x11vnc foi instalado (no core_packages.sh)
# ============================================================
if ! command -v x11vnc &>/dev/null; then
    log_nivel AVISO "x11vnc nao instalado. Pulando configuracao."
    log_nivel INFO "[08] x11vnc nao configurado (pacote ausente)."
    echo "============================================================"
    exit 0
fi

# ============================================================
# Detectar Display Manager se nao definido
# ============================================================
if [ -z "$DISPLAY_MANAGER" ] || [ "$DISPLAY_MANAGER" = "" ]; then
    if systemctl is-active --quiet lightdm 2>/dev/null; then DISPLAY_MANAGER="lightdm"
    elif systemctl is-active --quiet gdm3 2>/dev/null; then DISPLAY_MANAGER="gdm3"
    elif systemctl is-active --quiet sddm 2>/dev/null; then DISPLAY_MANAGER="sddm"
    else DISPLAY_MANAGER="lightdm"
    fi
    log_nivel INFO "Display Manager detectado: $DISPLAY_MANAGER"
fi

# ============================================================
# Configurar senha do VNC (SEM expor em texto plano)
# ============================================================
log_nivel INFO "Configurando senha do VNC..."
mkdir -p /etc/x11vnc
mkdir -p /etc/seederlinux

SECRETS_FILE="/etc/seederlinux/secrets.env"

if [ -n "$VNC_PASSWORD" ] && [ "$VNC_PASSWORD" != "" ]; then
    x11vnc -storepasswd "$VNC_PASSWORD" /etc/x11vnc/vncpasswd
    chmod 600 /etc/x11vnc/vncpasswd
    log_nivel INFO "Senha VNC configurada (fornecida pela OM)"
    echo "VNC_PASSWORD_SET=true" >> "$SECRETS_FILE"
else
    log_nivel INFO "VNC_PASSWORD nao definido. Gerando senha aleatoria."
    RANDOM_PASS=$(openssl rand -base64 12)
    x11vnc -storepasswd "$RANDOM_PASS" /etc/x11vnc/vncpasswd
    chmod 600 /etc/x11vnc/vncpasswd
    log_nivel INFO "Senha VNC gerada com sucesso"
    echo "VNC_PASSWORD_SET=true" >> "$SECRETS_FILE"
fi

chmod 600 "$SECRETS_FILE" 2>/dev/null || true
unset VNC_PASSWORD
unset VNC_PASSWORD_B64
unset RANDOM_PASS

# ============================================================
# Criar servico systemd para x11vnc
# ============================================================
log_nivel INFO "Criando servico systemd x11vnc..."

# ============================================================
# Display e autenticação do x11vnc
#
# Uso fixo de `:0` + `-auth guess`. Motivo (achado em campo):
#   1. O Xorg no Debian/Ubuntu/Mint/Zorin usa `:0` por padrão. A
#      tentativa de "extrair o display do ps" pegou `:41` de um
#      processo alheio e quebrou o x11vnc (loop infinito).
#   2. O `-auth guess` do x11vnc descobre o Xauthority correto
#      sozinho em GDM3, LightDM e SDDM - inclusive quando o GDM
#      roda em /run/user/<uid-gdm>/gdm/Xauthority. Extrair o
#      caminho via ps pegou o Xauthority do USUÁRIO (toledojcct)
#      e não do GDM, apontando para um diretório inexistente.
#
# Se algum dia `:0` não for o display (ex: multi-seat com :1), o
# operador edita o unit manualmente. Não tentar ser esperto.
# ============================================================

VNC_DISPLAY=":0"
VNC_AUTH_ARG="-auth guess"

log_nivel INFO "Display: $VNC_DISPLAY"
log_nivel INFO "Argumento de auth: $VNC_AUTH_ARG"

cat > /etc/systemd/system/x11vnc.service <<EOF
[Unit]
Description=x11vnc Server - SeederLinux
After=display-manager.service

[Service]
Type=simple
ExecStart=/usr/bin/x11vnc -display ${VNC_DISPLAY} ${VNC_AUTH_ARG} -forever -loop -noxdamage -repeat -rfbauth /etc/x11vnc/vncpasswd -rfbport 5900 -shared -o /var/log/x11vnc.log
ExecStop=/usr/bin/killall x11vnc
Restart=on-failure
RestartSec=10

[Install]
WantedBy=graphical.target
EOF

systemctl daemon-reload
systemctl enable x11vnc.service
systemctl start x11vnc.service 2>/dev/null || {
    log_nivel AVISO "Nao foi possivel iniciar x11vnc agora."
    log_nivel INFO "O servico sera iniciado apos o display manager."
}

log_nivel OK "x11vnc configurado!"
echo "============================================================"
)
$SeederScript$,
    TRUE,
    TRUE,
    12,
    ARRAY['core_packages.sh']::TEXT[],
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    depends_on = EXCLUDED.depends_on,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Configuracao do Conky (ordem 13) - core_conky.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, depends_on, version, organization_id)
VALUES (
    'Configuracao do Conky',
    'core_conky.sh',
    'Configura o Conky (monitor de sistema no desktop) com perfil dinamico via JSON.',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_conky.sh
# SeederLinux Lite - Conky (configuracao apenas)
# ============================================================================
# Configura o Conky para exibicao de informacoes do sistema no desktop,
# com perfil personalizavel. A instalacao de pacotes e feita no core_packages.sh.
# Os placeholders VARIAVEL sao substituidos automaticamente
# pelo sistema na geracao do bundle.
# ============================================================================

(
set -e

source /usr/local/lib/seederlinux/diag.sh 2>/dev/null || true
SCRIPT_ID="13-conky"

echo "============================================================"
echo "Configurar Conky"
echo "============================================================"

# ============================================================
# Variaveis
# ============================================================
CONKY_PROFILE="{{CONKY_PROFILE}}"
CONKY_CONFIG='{{CONKY_CONFIG}}'
DESKTOP_ENV="{{DESKTOP_ENV}}"
OM_ACRONYM="{{OM_ACRONYM}}"
OM_NAME="{{OM_NAME}}"

log_nivel INFO "Perfil Conky: $CONKY_PROFILE"
log_nivel INFO "Ambiente: $DESKTOP_ENV"

# ============================================================
# Detectar ambiente grafico se nao definido
# ============================================================
if [ -z "$DESKTOP_ENV" ] || [ "$DESKTOP_ENV" = "" ]; then
    if command -v cinnamon-session &>/dev/null; then DESKTOP_ENV="cinnamon"
    elif command -v mate-session &>/dev/null; then DESKTOP_ENV="mate"
    elif command -v gnome-session &>/dev/null; then DESKTOP_ENV="gnome"
    elif command -v startxfce4 &>/dev/null; then DESKTOP_ENV="xfce"
    elif command -v startplasma-x11 &>/dev/null; then DESKTOP_ENV="kde"
    elif command -v lxqt-session &>/dev/null; then DESKTOP_ENV="lxqt"
    elif command -v startlxde &>/dev/null; then DESKTOP_ENV="lxde"
    else DESKTOP_ENV="unknown"
    fi
fi

# ============================================================
# Verificar se o Conky foi instalado (no core_packages.sh)
# ============================================================
if ! command -v conky &>/dev/null; then
    log_nivel AVISO "Conky nao instalado. Pulando configuracao."
    log_nivel INFO "[09] Conky nao configurado (pacote ausente)."
    echo "============================================================"
    exit 0
fi

# ============================================================
# Parse do CONKY_CONFIG (JSON) com fallbacks
# ============================================================
parse_json() {
    local key="$1"
    local default="$2"
    local val
    val=$(echo "$CONKY_CONFIG" | jq -r "if has(\"${key}\") then .${key} else \"__UNSET__\" end" 2>/dev/null)
    if [ -z "$val" ] || [ "$val" = "null" ] || [ "$val" = "__UNSET__" ]; then
        echo "$default"
    else
        echo "$val"
    fi
}

CFG_POSITION=$(parse_json position "top_right")
CFG_TRANSPARENT=$(parse_json transparent "true")
CFG_COLOR_TEXT=$(parse_json color_text "#FFFFFF")
CFG_COLOR_BG=$(parse_json color_bg "#000000")
CFG_FONT_SIZE=$(parse_json font_size "10")
CFG_GAP_X=$(parse_json gap_x "10")
CFG_GAP_Y=$(parse_json gap_y "40")
CFG_UPDATE_INTERVAL=$(parse_json update_interval "1.0")
CFG_SHOW_CPU=$(parse_json show_cpu "true")
CFG_SHOW_RAM=$(parse_json show_ram "true")
CFG_SHOW_DISK=$(parse_json show_disk "true")
CFG_DISK_PARTITION=$(parse_json disk_partition "/")
CFG_SHOW_NETWORK=$(parse_json show_network "true")
CFG_NETWORK_IFACE=$(parse_json network_interface "eth0")

# Validar interface de rede: se a configurada nao existir, detectar
# a interface default do sistema. Evita ${addr eth0} falhar em
# estacoes com interface enp0s3, wlp2s0, etc.
if ! ip link show "$CFG_NETWORK_IFACE" &>/dev/null 2>&1; then
    DETECTED_IFACE="$(ip route 2>/dev/null | awk '/default/ {print $5; exit}')"
    if [ -n "$DETECTED_IFACE" ]; then
        log_nivel INFO "interface '$CFG_NETWORK_IFACE' nao existe, usando '$DETECTED_IFACE'"
        CFG_NETWORK_IFACE="$DETECTED_IFACE"
    fi
fi
CFG_SHOW_TOP=$(parse_json show_top_processes "true")
CFG_SHOW_DATETIME=$(parse_json show_datetime "true")
CFG_SHOW_HOSTNAME=$(parse_json show_hostname "true")
CFG_HOSTNAME_FONT_SIZE=$(parse_json font_size_hostname "14")

COLOR_TEXT_LUA="${CFG_COLOR_TEXT#\#}"
COLOR_BG_LUA="${CFG_COLOR_BG#\#}"

if [ "$CFG_TRANSPARENT" = "true" ]; then
    OWN_TRANSPARENT="true"
    OWN_ARGB_VALUE="0"
else
    OWN_TRANSPARENT="false"
    OWN_ARGB_VALUE="200"
fi

# ============================================================
# Criar diretorio de configuracao global
# ============================================================
mkdir -p /etc/seederlinux/conky

# ============================================================
# Gerar configuracao do Conky (usando CONKY_CONFIG JSON)
# ============================================================
log_nivel INFO "Gerando configuracao do Conky (CONKY_CONFIG=${CONKY_CONFIG:-vazio})..."

if [ "$CFG_SHOW_HOSTNAME" = "true" ]; then
    CONKY_TEXT="\${font DejaVu Sans Mono:size=${CFG_HOSTNAME_FONT_SIZE}}\${color ${COLOR_TEXT_LUA}}Host: \${nodename}
\${font DejaVu Sans Mono:size=${CFG_FONT_SIZE}}
\${color ${COLOR_TEXT_LUA}}${OM_ACRONYM} - ${OM_NAME}
\${color ${COLOR_TEXT_LUA}}\${hr}"
else
    CONKY_TEXT="\${color ${COLOR_TEXT_LUA}}${OM_ACRONYM} - ${OM_NAME}
\${color ${COLOR_TEXT_LUA}}\${hr}"
fi

CONKY_TEXT="${CONKY_TEXT}
\${color ${COLOR_TEXT_LUA}}Uptime: \${color grey}\${uptime}
\${color ${COLOR_TEXT_LUA}}\${hr}"

if [ "$CFG_SHOW_CPU" = "true" ]; then
    CONKY_TEXT="${CONKY_TEXT}
\${color ${COLOR_TEXT_LUA}}CPU:  \${color grey}\${cpu}% \${cpubar 4}"
fi
if [ "$CFG_SHOW_RAM" = "true" ]; then
    CONKY_TEXT="${CONKY_TEXT}
\${color ${COLOR_TEXT_LUA}}RAM:  \${color grey}\${mem}/\${memmax} \${membar 4}
\${color ${COLOR_TEXT_LUA}}SWAP: \${color grey}\${swap}/\${swapmax} \${swapbar 4}"
fi
if [ "$CFG_SHOW_DISK" = "true" ]; then
    CONKY_TEXT="${CONKY_TEXT}
\${color ${COLOR_TEXT_LUA}}Disco (${CFG_DISK_PARTITION}): \${color grey}\${fs_used ${CFG_DISK_PARTITION}}/\${fs_size ${CFG_DISK_PARTITION}} \${fs_bar 6 ${CFG_DISK_PARTITION}}"
fi
if [ "$CFG_SHOW_NETWORK" = "true" ]; then
    CONKY_TEXT="${CONKY_TEXT}
\${color ${COLOR_TEXT_LUA}}Rede (${CFG_NETWORK_IFACE}):
\${color ${COLOR_TEXT_LUA}}IP:   \${color grey}\${addr ${CFG_NETWORK_IFACE}}
\${color ${COLOR_TEXT_LUA}}Down: \${color grey}\${downspeed ${CFG_NETWORK_IFACE}}
\${color ${COLOR_TEXT_LUA}}Up:   \${color grey}\${upspeed ${CFG_NETWORK_IFACE}}"
fi
if [ "$CFG_SHOW_TOP" = "true" ]; then
    CONKY_TEXT="${CONKY_TEXT}
\${color ${COLOR_TEXT_LUA}}\${hr}
\${color ${COLOR_TEXT_LUA}}Top CPU:
\${color grey}\${top name 1} \${top cpu 1}%
\${color grey}\${top name 2} \${top cpu 2}%
\${color grey}\${top name 3} \${top cpu 3}%"
fi
if [ "$CFG_SHOW_DATETIME" = "true" ]; then
    CONKY_TEXT="${CONKY_TEXT}
\${color ${COLOR_TEXT_LUA}}\${hr}
\${color ${COLOR_TEXT_LUA}}\${time %A, %d/%m/%Y %H:%M:%S}"
fi

cat > /etc/seederlinux/conky/conky.conf <<EOF
-- Configuracao Conky - SeederLinux (gerada dinamicamente)
-- Perfil: ${CONKY_PROFILE:-default}

conky.config = {
    alignment = '${CFG_POSITION}',
    background = false,
    border_width = 1,
    cpu_avg_samples = 2,
    default_color = '${COLOR_TEXT_LUA}',
    double_buffer = true,
    draw_borders = false,
    draw_graph_borders = true,
    font = 'DejaVu Sans Mono:size=${CFG_FONT_SIZE}',
    gap_x = ${CFG_GAP_X},
    gap_y = ${CFG_GAP_Y},
    minimum_width = 200,
    net_avg_samples = 2,
    no_buffers = true,
    own_window = true,
    own_window_class = 'Conky',
    own_window_type = 'desktop',
    own_window_argb_visual = true,
    own_window_argb_value = ${OWN_ARGB_VALUE},
    own_window_transparent = ${OWN_TRANSPARENT},
    own_window_colour = '${COLOR_BG_LUA}',
    own_window_hints = 'undecorated,below,sticky,skip_taskbar,skip_pager',
    update_interval = ${CFG_UPDATE_INTERVAL},
    use_xft = true,
}

conky.text = [[
${CONKY_TEXT}
]]
EOF

# ============================================================
# Criar script de inicializacao do Conky
# ============================================================
log_nivel INFO "Criando script de inicializacao..."
cat > /usr/local/bin/seederlinux-conky <<'SCRIPT'
#!/bin/bash
CONKY_CONF="/etc/seederlinux/conky/conky.conf"
sleep 5
if [ -f "$CONKY_CONF" ]; then
    killall conky 2>/dev/null || true
    conky -c "$CONKY_CONF" &
else
    echo "Configuracao do Conky nao encontrada: $CONKY_CONF"
fi
SCRIPT

chmod +x /usr/local/bin/seederlinux-conky

# ============================================================
# Adicionar Conky ao autostart conforme o DE
# ============================================================
log_nivel INFO "Configurando autostart do Conky para: $DESKTOP_ENV"

case "$DESKTOP_ENV" in
    cinnamon|mate|xfce|lxde|lxqt|gnome)
        mkdir -p /etc/xdg/autostart
        cat > /etc/xdg/autostart/seederlinux-conky.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Conky (SeederLinux)
Exec=/usr/local/bin/seederlinux-conky
Terminal=false
X-GNOME-Autostart-enabled=true
NoDisplay=false
EOF
        ;;
    kde)
        mkdir -p /usr/share/autostart
        cat > /usr/share/autostart/seederlinux-conky.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Conky (SeederLinux)
Exec=/usr/local/bin/seederlinux-conky
Terminal=false
X-KDE-autostart-enabled=true
EOF
        ;;
esac

log_nivel OK "Conky configurado!"
echo "============================================================"
)
$SeederScript$,
    TRUE,
    TRUE,
    13,
    ARRAY['core_packages.sh']::TEXT[],
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    depends_on = EXCLUDED.depends_on,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Configuracao Persistente (ordem 14) - core_config.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, depends_on, version, organization_id)
VALUES (
    'Configuracao Persistente',
    'core_config.sh',
    'Configuracoes diversas do sistema (sysctl, limits, etc).',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_config.sh
# SeederLinux Lite - Arquivo de Configuracao Persistente
# ============================================================================
# Cria /etc/seederlinux/config.env com todas as variaveis nao-sensiveis
# da OM. Este arquivo e lido pelos scripts permanentes (seederlinux-logon,
# seederlinux-logoff, seeder-sync) apos reboot, quando as variaveis
# exportadas no bundle ja nao existem mais na memoria.
#
# MODELO MULTI-PROXY:
#   A OM pode ter 0..N proxies nomeados. As 3 politicas (APT/CLI/BROWSER)
#   referenciam um proxy pelo nome. config.env guarda o array de proxies
#   SEM as senhas; as senhas vao para /etc/seederlinux/secrets.env (600).
#
# Variaveis sensiveis (senha VNC, senha de proxy) NAO sao escritas em
# config.env. Vao em secrets.env, com permissao 600.
#
# Os placeholders VARIAVEL sao substituidos automaticamente
# pelo sistema na geracao do bundle.
# ============================================================================

set -e

source /usr/local/lib/seederlinux/diag.sh 2>/dev/null || true
SCRIPT_ID="14-config"

echo "============================================================"
echo "Criar arquivo de configuracao persistente"
echo "============================================================"

# ============================================================
# Diretorio base
# ============================================================
mkdir -p /etc/seederlinux

CONFIG_FILE="/etc/seederlinux/config.env"
SECRETS_FILE="/etc/seederlinux/secrets.env"

# ============================================================
# Normalizacao de URLs de assets
# ============================================================
SEEDER_SERVER="{{SEEDER_SERVER}}"
SEEDER_SERVER="${SEEDER_SERVER%/}"

WALLPAPER_URL="{{WALLPAPER_URL}}"
WALLPAPER_LOGIN_URL="{{WALLPAPER_LOGIN_URL}}"
LOGO_URL="{{LOGO_URL}}"
GREETER_URL="{{GREETER_URL}}"

log_nivel INFO "Normalizando URLs de assets para forma absoluta..."
for url_var in WALLPAPER_URL WALLPAPER_LOGIN_URL LOGO_URL GREETER_URL; do
    url_val="${!url_var}"
    [ -z "$url_val" ] && continue
    echo "$url_val" | grep -qE '^https?://[^/]+/' && continue
    if [ -n "$SEEDER_SERVER" ]; then
        if echo "$url_val" | grep -q '^/'; then
            eval "${url_var}=\"${SEEDER_SERVER}${url_val}\""
        else
            eval "${url_var}=\"${SEEDER_SERVER}/${url_val}\""
        fi
    fi
done

# ============================================================
# NTP_SERVER: remover protocolo
# ============================================================
NTP_SERVER="{{NTP_SERVER}}"
NTP_SERVER="${NTP_SERVER#http://}"
NTP_SERVER="${NTP_SERVER#https://}"

# ============================================================
# Politicas de proxy (multi-proxy)
# ============================================================
APT_POLICY="{{APT_POLICY}}"
APT_PROXY_NAME="{{APT_PROXY_NAME}}"
CLI_POLICY="{{CLI_POLICY}}"
CLI_PROXY_NAME="{{CLI_PROXY_NAME}}"
BROWSER_POLICY="{{BROWSER_POLICY}}"
BROWSER_PROXY_NAME="{{BROWSER_PROXY_NAME}}"
MIRROR_LOCAL_SEEDER_PATH="{{MIRROR_LOCAL_SEEDER_PATH}}"
MIRROR_LOCAL_OM_URL="{{MIRROR_LOCAL_OM_URL}}"

[ -z "$APT_POLICY" ] && APT_POLICY="DIRECT"
[ -z "$CLI_POLICY" ] && CLI_POLICY="DIRECT"
[ -z "$BROWSER_POLICY" ] && BROWSER_POLICY="DIRECT"
[ -z "$MIRROR_LOCAL_SEEDER_PATH" ] && MIRROR_LOCAL_SEEDER_PATH="/mirror/"

# Array de proxies (vem do header do bundle)
PROXY_COUNT="${PROXY_COUNT:-0}"
PROXY_DEFAULT_NAME="${PROXY_DEFAULT_NAME:-}"

log_nivel INFO "APT_POLICY: $APT_POLICY"
log_nivel INFO "CLI_POLICY: $CLI_POLICY"
log_nivel INFO "BROWSER_POLICY: $BROWSER_POLICY"
log_nivel INFO "Proxies: $PROXY_COUNT (default: ${PROXY_DEFAULT_NAME:-<nenhum>})"

# ============================================================
# Preservar SERIAL_APLICADO
# ============================================================
SERIAL_APLICADO_ATUAL="0"
if [ -f "$CONFIG_FILE" ]; then
    VALOR_EXISTENTE="$(grep -m1 '^SERIAL_APLICADO=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"')"
    [ -n "$VALOR_EXISTENTE" ] && SERIAL_APLICADO_ATUAL="$VALOR_EXISTENTE"
fi
log_nivel INFO "SERIAL_APLICADO preservado: $SERIAL_APLICADO_ATUAL"

# ============================================================
# Escrever config.env (cabecalho + variaveis + array de proxies)
# ============================================================
cat > "$CONFIG_FILE" <<EOF
# SeederLinux Lite - Configuracao Persistente
# NAO EDITAR MANUALMENTE - gerado pelo core_config.sh
# Gerado em: $(date '+%Y-%m-%d %H:%M:%S')

# Dominio e Autenticacao
DOMINIO="{{DOMINIO}}"
DOMINIO_NETBIOS="{{DOMINIO_NETBIOS}}"
DC_IP="{{DC_IP}}"
DC_IP_LIST="{{DC_IP_LIST}}"
DC_SECUNDARIO_IP="{{DC_SECUNDARIO_IP}}"
DNS_PRIMARIO="{{DNS_PRIMARIO}}"
DNS_SECUNDARIO="{{DNS_SECUNDARIO}}"
DNS_INTERNET="{{DNS_INTERNET}}"
NTP_SERVER="${NTP_SERVER}"
OU_PADRAO="{{OU_PADRAO}}"
GRUPO_ADMIN="{{GRUPO_ADMIN}}"
GRUPO_ADMIN_AD="{{GRUPO_ADMIN_AD}}"
GRUPO_ADMIN_LINUX="{{GRUPO_ADMIN_LINUX}}"
GRUPO_DASTI="{{GRUPO_DASTI}}"
AUTH_METHOD="{{AUTH_METHOD}}"
OFFLINE_AUTH_ENABLED="{{OFFLINE_AUTH_ENABLED}}"
OFFLINE_AUTH_DAYS="{{OFFLINE_AUTH_DAYS}}"

# Politicas de proxy (modelo multi-proxy)
APT_POLICY="${APT_POLICY}"
APT_PROXY_NAME="${APT_PROXY_NAME}"
CLI_POLICY="${CLI_POLICY}"
CLI_PROXY_NAME="${CLI_PROXY_NAME}"
BROWSER_POLICY="${BROWSER_POLICY}"
BROWSER_PROXY_NAME="${BROWSER_PROXY_NAME}"
MIRROR_LOCAL_SEEDER_PATH="${MIRROR_LOCAL_SEEDER_PATH}"
MIRROR_LOCAL_OM_URL="${MIRROR_LOCAL_OM_URL}"

# URLs e Servidores
BASE_URL="{{BASE_URL}}"
HOMEPAGE="{{HOMEPAGE}}"
OCS_SERVER="{{OCS_SERVER}}"
OCS_TAG="{{OCS_TAG}}"
GLPI_SERVER="{{GLPI_SERVER}}"
PRINT_SERVER="{{PRINT_SERVER}}"
SERVIDOR_ARQUIVOS="{{SERVIDOR_ARQUIVOS}}"

# Identidade Visual
OM_ACRONYM="{{OM_ACRONYM}}"
OM_NAME="{{OM_NAME}}"
DISPLAY_NAME="{{DISPLAY_NAME}}"
WALLPAPER_URL="${WALLPAPER_URL}"
WALLPAPER_LOGIN_URL="${WALLPAPER_LOGIN_URL}"
LOGO_URL="${LOGO_URL}"
GREETER_URL="${GREETER_URL}"
THEME="{{THEME}}"

# Ambiente Grafico
DESKTOP_ENV="{{DESKTOP_ENV}}"
DISPLAY_MANAGER="{{DISPLAY_MANAGER}}"

# Aplicacoes e Funcionalidades
INSTALL_ONLYOFFICE="{{INSTALL_ONLYOFFICE}}"
INSTALL_CHROME="{{INSTALL_CHROME}}"
INSTALL_CHROMIUM="{{INSTALL_CHROMIUM}}"
INSTALL_JAVA8="{{INSTALL_JAVA8}}"
INSTALL_FIREFOX52="{{INSTALL_FIREFOX52}}"
VNC_ENABLED="{{VNC_ENABLED}}"
INVENTORY_ENABLED="{{INVENTORY_ENABLED}}"

# Repositorios
REPOSITORY_MODE="{{REPOSITORY_MODE}}"
REPOSITORY_URL="{{REPOSITORY_URL}}"
REPOSITORY_FALLBACK="{{REPOSITORY_FALLBACK}}"

# Compartilhamentos e Impressoras
COMPARTILHAMENTOS="{{COMPARTILHAMENTOS}}"
MOUNT_BASE="{{MOUNT_BASE}}"
DEFAULT_PRINTER="{{DEFAULT_PRINTER}}"
PRINTERS="{{PRINTERS}}"

# Acesso Remoto
REMOTE_METHOD="{{REMOTE_METHOD}}"
SSH_PORT="{{SSH_PORT}}"
SSH_GROUPS="{{SSH_GROUPS}}"

# Certificados
CERTIFICATE_BUNDLE="{{CERTIFICATE_BUNDLE}}"
CERTIFICATE_AUTO_INSTALL="{{CERTIFICATE_AUTO_INSTALL}}"

# Conky
CONKY_PROFILE="{{CONKY_PROFILE}}"
CONKY_CONFIG='{{CONKY_CONFIG}}'

# Servidor SeederLinux
SEEDER_SERVER="${SEEDER_SERVER}"
EOF

# ============================================================
# Anexar array de proxies (sem senhas - vao em secrets.env)
# ============================================================
{
    echo ""
    echo "# Array de proxies da OM (senhas em secrets.env)"
    echo "PROXY_COUNT=\"${PROXY_COUNT}\""
    echo "PROXY_DEFAULT_NAME=\"${PROXY_DEFAULT_NAME}\""
    echo ""

    i=1
    while [ "$i" -le "$PROXY_COUNT" ] 2>/dev/null; do
        v_name="PROXY_${i}_NAME"
        v_url="PROXY_${i}_URL"
        v_user="PROXY_${i}_USER"
        v_pac="PROXY_${i}_PAC_URL"
        v_no_proxy="PROXY_${i}_NO_PROXY"
        v_ad_group="PROXY_${i}_AD_GROUP"

        # Escapar valores entre aspas duplas (\ e ")
        name_v="$(printf '%s' "${!v_name}" | sed 's/\\/\\\\/g; s/"/\\"/g')"
        url_v="$(printf '%s' "${!v_url}"  | sed 's/\\/\\\\/g; s/"/\\"/g')"
        user_v="$(printf '%s' "${!v_user}" | sed 's/\\/\\\\/g; s/"/\\"/g')"
        pac_v="$(printf '%s' "${!v_pac}" | sed 's/\\/\\\\/g; s/"/\\"/g')"
        no_proxy_v="$(printf '%s' "${!v_no_proxy}" | sed 's/\\/\\\\/g; s/"/\\"/g')"
        ad_group_v="$(printf '%s' "${!v_ad_group}" | sed 's/\\/\\\\/g; s/"/\\"/g')"

        echo "PROXY_${i}_NAME=\"${name_v}\""
        echo "PROXY_${i}_URL=\"${url_v}\""
        echo "PROXY_${i}_USER=\"${user_v}\""
        echo "PROXY_${i}_PAC_URL=\"${pac_v}\""
        echo "PROXY_${i}_NO_PROXY=\"${no_proxy_v}\""
        echo "PROXY_${i}_AD_GROUP=\"${ad_group_v}\""
        i=$((i+1))
    done

    echo ""
    echo "# Estado local (GPO) - progresso desta estacao"
    echo "SERIAL_APLICADO=\"${SERIAL_APLICADO_ATUAL}\""
} >> "$CONFIG_FILE"

chmod 644 "$CONFIG_FILE"
log_nivel INFO "config.env gravado em $CONFIG_FILE"

# ============================================================
# Atualizar secrets.env com as senhas dos proxies
# ============================================================
# Preserva o que ja existe (VNC_PASSWORD_SET etc), so substitui as
# linhas PROXY_K_PASS. Arquivo criado com perm 600.
TMP_SECRETS="$(mktemp /tmp/seeder-secrets.XXXXXX)"

if [ -f "$SECRETS_FILE" ]; then
    grep -v '^PROXY_[0-9]\+_PASS=' "$SECRETS_FILE" > "$TMP_SECRETS" 2>/dev/null || : > "$TMP_SECRETS"
else
    : > "$TMP_SECRETS"
fi

i=1
while [ "$i" -le "$PROXY_COUNT" ] 2>/dev/null; do
    v_pass_b64="PROXY_${i}_PASS_B64"
    pass_b64="${!v_pass_b64}"
    pass=""
    if [ -n "$pass_b64" ]; then
        pass="$(printf '%s' "$pass_b64" | base64 -d 2>/dev/null)" || pass=""
    fi
    # Usa printf %q do bash para escape shell-safe
    pass_escaped="$(printf '%q' "$pass")"
    printf 'PROXY_%d_PASS=%s\n' "$i" "$pass_escaped" >> "$TMP_SECRETS"
    i=$((i+1))
done

install -m 0600 "$TMP_SECRETS" "$SECRETS_FILE"
rm -f "$TMP_SECRETS"

log_nivel INFO "secrets.env atualizado (${PROXY_COUNT} senha(s) de proxy)"
log_nivel OK "Arquivo de configuracao criado!"
echo "============================================================"
$SeederScript$,
    TRUE,
    TRUE,
    14,
    ARRAY['core_packages.sh']::TEXT[],
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    depends_on = EXCLUDED.depends_on,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Identidade Visual (ordem 15) - core_branding.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, depends_on, version, organization_id)
VALUES (
    'Identidade Visual',
    'core_branding.sh',
    'Aplica wallpaper, logo, tema GTK e branding da OM.',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_branding.sh
# SeederLinux Lite - Wallpaper, logo, tema (varia por DE)
# ============================================================================
# Aplica identidade visual da OM: wallpaper, logo, tema GTK e configuracoes
# de aparencia. Varia conforme o ambiente grafico (DE).
#
# CORRECOES NESTA VERSAO:
#   1. _baixar_ativo() usa `install -m 0644` em vez de `mv`. O `mv` de
#      um arquivo criado por `mktemp` (0600) preserva o modo restritivo,
#      o que fazia o greeter do LightDM (roda como usuario `lightdm`)
#      nao conseguir ler os wallpapers -> tela preta no login.
#   2. Validacao de MIME type alem do tamanho: se o servidor devolver
#      uma pagina HTML de erro (404 estilizado, portal cativo), o
#      arquivo tem bytes mas nao e imagem. `file --mime-type` detecta.
#   3. Fallback wallpaper-login -> wallpaper.jpg quando o primeiro nao
#      existe (seja por URL vazia, download falho, ou OM que so
#      cadastrou WALLPAPER_URL).
#   4. Diretorio /usr/share/backgrounds/seederlinux forcado a 0755 -
#      sem isso, um bundle rodado com umask restritivo o cria como
#      0700, e o greeter tambem nao consegue *entrar* no diretorio.
#   5. `install -m 0644` tambem no caso GREETER_URL=imagem, que copiava
#      via `cp` sem controle de modo.
#   6. chmod 0644 explicito no lightdm-gtk-greeter.conf (lightdm le
#      esse arquivo como usuario `lightdm`, nao como root).
#
# Os placeholders VARIAVEL são substituídos automaticamente
# pelo sistema na geração do bundle.
# ============================================================================

set -e

source /usr/local/lib/seederlinux/diag.sh 2>/dev/null || true
SCRIPT_ID="15-branding"

# CORRECAO: script envolvido em subshell - uma falha aqui (ex: asset
# externo que nao baixa/extrai direito) nao pode mais derrubar o
# bundle inteiro, so este modulo.
(
set -e

echo "============================================================"
echo "Aplicar identidade visual (branding)"
echo "============================================================"

# ============================================================
# Variáveis
# ============================================================
OM_ACRONYM="{{OM_ACRONYM}}"
OM_NAME="{{OM_NAME}}"
DISPLAY_NAME="{{DISPLAY_NAME}}"
WALLPAPER_URL="{{WALLPAPER_URL}}"
WALLPAPER_LOGIN_URL="{{WALLPAPER_LOGIN_URL}}"
LOGO_URL="{{LOGO_URL}}"
GREETER_URL="{{GREETER_URL}}"
THEME="{{THEME}}"
DESKTOP_ENV="{{DESKTOP_ENV}}"
DISPLAY_MANAGER="{{DISPLAY_MANAGER}}"
SEEDER_SERVER="{{SEEDER_SERVER}}"

# ============================================================
# Prefixar URLs de assets com SEEDER_SERVER quando relativas
# ============================================================
for url_var in WALLPAPER_URL WALLPAPER_LOGIN_URL LOGO_URL GREETER_URL; do
    url_val="${!url_var}"
    if [ -n "$url_val" ] && [ "$url_val" != "" ]; then
        if echo "$url_val" | grep -qE '^https?://[^/]+/'; then
            continue
        fi
        server_clean="${SEEDER_SERVER%/}"
        if echo "$url_val" | grep -q '^/'; then
            eval "${url_var}=\"${server_clean}${url_val}\""
        else
            eval "${url_var}=\"${server_clean}/${url_val}\""
        fi
    fi
done

# ============================================================
# Detectar ambiente grafico se nao definido
# ============================================================
if [ -z "$DESKTOP_ENV" ] || [ "$DESKTOP_ENV" = "" ]; then
    if command -v cinnamon-session &>/dev/null; then DESKTOP_ENV="cinnamon"
    elif command -v mate-session &>/dev/null; then DESKTOP_ENV="mate"
    elif command -v gnome-session &>/dev/null; then DESKTOP_ENV="gnome"
    elif command -v startxfce4 &>/dev/null; then DESKTOP_ENV="xfce"
    elif command -v startplasma-x11 &>/dev/null; then DESKTOP_ENV="kde"
    elif command -v lxqt-session &>/dev/null; then DESKTOP_ENV="lxqt"
    elif command -v startlxde &>/dev/null; then DESKTOP_ENV="lxde"
    else DESKTOP_ENV="unknown"
    fi
fi
log_nivel INFO "Ambiente detectado: $DESKTOP_ENV"

# ============================================================
# Detectar display manager se nao definido
# ============================================================
if [ -z "$DISPLAY_MANAGER" ] || [ "$DISPLAY_MANAGER" = "" ]; then
    if systemctl is-active --quiet lightdm 2>/dev/null; then DISPLAY_MANAGER="lightdm"
    elif systemctl is-active --quiet gdm3 2>/dev/null; then DISPLAY_MANAGER="gdm3"
    elif systemctl is-active --quiet sddm 2>/dev/null; then DISPLAY_MANAGER="sddm"
    elif [ -f /etc/X11/default-display-manager ]; then
        DISPLAY_MANAGER="$(basename "$(cat /etc/X11/default-display-manager)")"
    else DISPLAY_MANAGER="unknown"
    fi
fi
log_nivel INFO "Display Manager detectado: $DISPLAY_MANAGER"

log_nivel INFO "OM: $OM_ACRONYM - $OM_NAME"
log_nivel INFO "Ambiente: $DESKTOP_ENV / $DISPLAY_MANAGER"
log_nivel INFO "Tema: $THEME"

# ============================================================
# Criar diretorios de branding
# ============================================================
mkdir -p /usr/share/seederlinux/branding
mkdir -p /usr/share/backgrounds/seederlinux
mkdir -p /usr/share/pixmaps

# CORRECAO: o diretorio precisa ser 0755 (world-readable + world-
# executable). Um bundle rodado com umask 077 o criaria como 0700 -
# o greeter do LightDM (usuario `lightdm`) nao conseguiria nem entrar
# no diretorio, mesmo que o arquivo dentro fosse 0644. Este chmod e'
# idempotente e cobre tanto criacao nova quanto bundle re-rodado.
chmod 0755 /usr/share/backgrounds/seederlinux
chmod 0755 /usr/share/pixmaps

# ============================================================
# Garantir perfil dconf "user" com o banco system-db:local incluido.
# Sem isso, TUDO que escrevemos em /etc/dconf/db/local.d/ (GNOME,
# Cinnamon, MATE) e ignorado pelos usuarios - dconf so aplica um
# banco de sistema se o perfil do usuario listar explicitamente
# "system-db:<nome>". Alguns pacotes de DE ja criam isso no
# postinst, mas nao e garantido em toda combinacao de distro/DE -
# entao garantimos aqui de forma idempotente.
# ============================================================
mkdir -p /etc/dconf/profile
if [ ! -f /etc/dconf/profile/user ]; then
    cat > /etc/dconf/profile/user <<EOF
user-db:user
system-db:local
EOF
elif ! grep -q "^system-db:local$" /etc/dconf/profile/user; then
    echo "system-db:local" >> /etc/dconf/profile/user
fi

# ============================================================
# Helper: baixar asset validando TAMANHO e TIPO.
#
# CORRECAO (causa raiz da tela preta em teste real):
#   - Antes: `mktemp` cria arquivo 0600; `wget -O` escreve nele; `mv`
#     preserva o modo. O wallpaper resultante ficava 0600. O greeter
#     do LightDM roda como usuario `lightdm`, tentava abrir, tomava
#     EACCES e caia no fundo preto padrao. Solucao: `install -m 0644`
#     (copia + define modo explicitamente, sem depender de umask).
#   - Antes: so validava `-s` (tamanho > 0). Se o servidor devolvesse
#     uma pagina HTML de erro (proxy 407, portal cativo, 404 estilizado),
#     o arquivo tinha bytes e era aceito como wallpaper. Solucao: usar
#     `file --mime-type` para exigir `image/*`.
#
# Em caso de falha, NUNCA apaga o destino - mantem o que ja estava
# la (pode ser de bundle anterior). Apenas o tmp e' removido.
# ============================================================
_baixar_ativo() {
    local url="$1"
    local dest="$2"
    local tmp
    tmp="$(mktemp /tmp/seeder-asset.XXXXXX)"

    if ! wget -q --no-check-certificate --no-proxy --timeout=20 -O "$tmp" "$url"; then
        rm -f "$tmp"
        log_nivel AVISO "falha de download de $(basename "$dest") ($url) - mantendo o existente"
        return 1
    fi

    if [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        log_nivel AVISO "$(basename "$dest") baixou 0 bytes (404/proxy/DNS?) - mantendo o existente"
        return 1
    fi

    # Validacao de tipo: aceita apenas image/*. Cobre jpg/png/gif/webp/
    # bmp/svg - o que o usuario cadastrar como wallpaper, desde que
    # seja imagem de verdade.
    local mime
    mime="$(file -b --mime-type "$tmp" 2>/dev/null || echo "application/octet-stream")"
    if ! echo "$mime" | grep -q '^image/'; then
        rm -f "$tmp"
        log_nivel AVISO "$(basename "$dest") baixou $mime (nao e imagem - HTML de erro?) - mantendo o existente"
        return 1
    fi

    # `install -m 0644` - copia E define modo. Nao depende de umask
    # herdado do bundle. Garante que greeter (usuario `lightdm`) e
    # sessoes de usuario conseguem ler.
    install -m 0644 "$tmp" "$dest"
    rm -f "$tmp"
    log_nivel INFO "$(basename "$dest") instalado ($mime)"
    return 0
}

# ============================================================
# Baixar e instalar wallpaper (da sessao)
# ============================================================
log_nivel INFO "Baixando wallpaper..."
if [ -n "$WALLPAPER_URL" ] && [ "$WALLPAPER_URL" != "" ]; then
    _baixar_ativo "$WALLPAPER_URL" /usr/share/backgrounds/seederlinux/wallpaper.jpg
else
    log_nivel INFO "WALLPAPER_URL nao definido. Pulando wallpaper."
fi

# ============================================================
# Baixar e instalar wallpaper de login
# ============================================================
log_nivel INFO "Baixando wallpaper de login..."
if [ -n "$WALLPAPER_LOGIN_URL" ] && [ "$WALLPAPER_LOGIN_URL" != "" ]; then
    _baixar_ativo "$WALLPAPER_LOGIN_URL" /usr/share/backgrounds/seederlinux/wallpaper-login.jpg
else
    log_nivel INFO "WALLPAPER_LOGIN_URL nao definido. Pulando wallpaper de login."
fi

# ============================================================
# Baixar e instalar logo
# ============================================================
log_nivel INFO "Baixando logo..."
if [ -n "$LOGO_URL" ] && [ "$LOGO_URL" != "" ]; then
    _baixar_ativo "$LOGO_URL" /usr/share/pixmaps/seederlinux-logo.png
else
    log_nivel INFO "LOGO_URL nao definido. Pulando logo."
fi

# ============================================================
# Baixar e instalar greeter personalizado
# ============================================================
# GREETER_URL pode ser:
#   - um pacote compactado (tar/gzip/bzip2/xz) com tema de greeter
#     personalizado, OU
#   - uma imagem (.jpg, .jpeg, .png, .bmp, .gif, .webp, .tif, ...)
#     que sera usada como wallpaper de login.
#
# Deteccao por conteudo (MIME type via magic bytes), NAO por
# extensao do arquivo - funciona com qualquer formato, mesmo que o
# nome/extensao esteja errado.
# ============================================================
log_nivel INFO "Baixando greeter..."
if [ -n "$GREETER_URL" ] && [ "$GREETER_URL" != "" ]; then
    GREETER_TARBALL="/tmp/seederlinux-greeter.bin"
    if wget -q --no-check-certificate --no-proxy --timeout=20 -O "$GREETER_TARBALL" "$GREETER_URL" && [ -s "$GREETER_TARBALL" ]; then
        GREETER_MIME="$(file -b --mime-type "$GREETER_TARBALL" 2>/dev/null)"
        log_nivel INFO "Greeter detectado como: ${GREETER_MIME:-desconhecido}"

        case "$GREETER_MIME" in
            # --- Caso 1: arquivo compactado (tar/gzip/bzip2/xz) ---
            application/gzip|application/x-gzip|application/x-tar|\
            application/x-bzip2|application/x-xz|application/octet-stream)
                # octet-stream e ambiguo - confirmar via file -b (magic)
                GREETER_FILETYPE="$(file -b "$GREETER_TARBALL" 2>/dev/null)"
                if echo "$GREETER_FILETYPE" | grep -qiE 'gzip|tar|bzip2|xz'; then
                    mkdir -p /tmp/seederlinux-greeter
                    if tar xf "$GREETER_TARBALL" -C /tmp/seederlinux-greeter 2>/dev/null; then
                        case "$DISPLAY_MANAGER" in
                            lightdm)
                                cp -r /tmp/seederlinux-greeter/* /usr/share/lightdm/ 2>/dev/null || true
                                ;;
                            gdm3)
                                cp -r /tmp/seederlinux-greeter/* /usr/share/gdm/ 2>/dev/null || true
                                ;;
                            sddm)
                                cp -r /tmp/seederlinux-greeter/* /usr/share/sddm/themes/ 2>/dev/null || true
                                ;;
                        esac
                        log_nivel INFO "Greeter (pacote) instalado"
                    else
                        log_nivel AVISO "falha ao extrair o pacote do greeter."
                    fi
                    rm -rf /tmp/seederlinux-greeter
                else
                    log_nivel AVISO "conteudo nao reconhecido como tar/gzip/bzip2/xz."
                fi
                ;;

            # --- Caso 2: qualquer imagem ---
            image/*)
                GREETER_EXT="${GREETER_MIME#image/}"
                case "$GREETER_EXT" in
                    jpeg) GREETER_EXT="jpg" ;;
                    x-ms-bmp) GREETER_EXT="bmp" ;;
                    x-icon) GREETER_EXT="ico" ;;
                    svg+xml) GREETER_EXT="svg" ;;
                    x-portable-pixmap) GREETER_EXT="ppm" ;;
                    tiff) GREETER_EXT="tif" ;;
                esac
                GREETER_IMG="/usr/share/backgrounds/seederlinux/greeter.${GREETER_EXT}"

                # CORRECAO: `install -m 0644` em vez de `cp`. O `cp`
                # sem -p herda o modo do arquivo de origem mascarado
                # pelo umask corrente do bundle - que pode ser 077.
                # O greeter precisa ler, entao modo tem que ser 0644
                # explicito, sem depender de umask.
                install -m 0644 "$GREETER_TARBALL" "$GREETER_IMG"
                log_nivel INFO "Greeter (imagem ${GREETER_EXT}) instalado: $GREETER_IMG"

                # Se WALLPAPER_LOGIN_URL nao foi definido OU o arquivo
                # de wallpaper de login ainda nao existe, usar o
                # greeter como wallpaper de login. Copiado com nome
                # fixo wallpaper-login.jpg independente do formato
                # real - GTK/LightDM/GDM3/SDDM detectam o formato pelo
                # conteudo (magic bytes), nao pela extensao, entao
                # isso nao quebra a leitura. Ressalva: formatos menos
                # comuns (webp, svg) dependem do loader gdk-pixbuf
                # correspondente estar instalado na imagem do SO.
                if [ -z "$WALLPAPER_LOGIN_URL" ] || [ ! -s /usr/share/backgrounds/seederlinux/wallpaper-login.jpg ]; then
                    install -m 0644 "$GREETER_TARBALL" /usr/share/backgrounds/seederlinux/wallpaper-login.jpg
                    log_nivel INFO "Greeter usado como wallpaper de login"
                else
                    log_nivel INFO "Wallpaper de login proprio ja instalado - greeter mantido apenas em $GREETER_IMG"
                fi
                ;;

            # --- Caso 3: qualquer outra coisa ---
            *)
                log_nivel AVISO "GREETER_URL nao e imagem nem pacote compactado valido"
                log_nivel INFO "(detectado como: ${GREETER_MIME:-desconhecido}). Pulando greeter customizado."
                ;;
        esac

        rm -f "$GREETER_TARBALL"
    else
        log_nivel AVISO "greeter baixado vazio ou com falha - pulando"
        rm -f "$GREETER_TARBALL"
    fi
fi

# ============================================================
# FALLBACK: wallpaper de login
#
# Se por qualquer motivo (URL vazia, download falho, HTML de erro) o
# wallpaper-login.jpg nao existe no disco mas o wallpaper.jpg existe,
# copiamos o da sessao por cima. Isso evita que o greeter caia no
# fundo preto padrao - que era exatamente o sintoma reportado.
#
# Tambem serve para OM que so cadastrou WALLPAPER_URL (caso comum:
# a OM nao quer se preocupar em subir dois arquivos).
# ============================================================
LOGIN_WP="/usr/share/backgrounds/seederlinux/wallpaper-login.jpg"
SESSION_WP="/usr/share/backgrounds/seederlinux/wallpaper.jpg"

if [ ! -s "$LOGIN_WP" ] && [ -s "$SESSION_WP" ]; then
    log_nivel INFO "Wallpaper de login ausente - usando o da sessao como fallback"
    install -m 0644 "$SESSION_WP" "$LOGIN_WP"
fi

# ============================================================
# Aplicar tema GTK (SOMENTE se THEME foi definido explicitamente)
# ============================================================
# CORRECAO (achado em teste real): THEME="DEFAULT" (valor de fato
# configurado nas OMs) NAO e um tema GTK valido - "DEFAULT" nao
# existe em /usr/share/themes, entao gtk-theme-name=DEFAULT e
# simplesmente ignorado pelo GTK. Pior: theme-name=DEFAULT no
# greeter e ColorScheme=DEFAULT no KDE tambem nao fazem nada. Agora
# so aplicamos tema se THEME vier definido E existir de verdade em
# /usr/share/themes - caso contrario mantemos o tema atual do
# sistema/DE, sem sobrescrever nada.
log_nivel INFO "Aplicando tema GTK: $THEME"
THEME_APLICAR=false

if [ -z "$THEME" ] || [ "$THEME" = "DEFAULT" ]; then
    log_nivel INFO "THEME=DEFAULT (ou vazio) - mantendo tema atual do sistema."
elif [ -d "/usr/share/themes/$THEME" ]; then
    THEME_APLICAR=true
    log_nivel INFO "THEME=$THEME - tema encontrado em /usr/share/themes."
else
    log_nivel AVISO "THEME=$THEME nao existe em /usr/share/themes - mantendo tema atual."
fi

if [ "$THEME_APLICAR" = "true" ]; then
    mkdir -p /etc/skel/.config/gtk-3.0
    cat > /etc/skel/.config/gtk-3.0/settings.ini <<EOF
[Settings]
gtk-theme-name=${THEME}
gtk-icon-theme-name=Adwaita
gtk-font-name=DejaVu Sans 10
gtk-cursor-theme-name=Adwaita
gtk-cursor-theme-size=16
gtk-toolbar-style=GTK_TOOLBAR_BOTH
gtk-toolbar-icon-size=GTK_ICON_SIZE_LARGE_TOOLBAR
gtk-button-images=1
gtk-menu-images=1
gtk-application-prefer-dark-theme=0
EOF
    log_nivel INFO "Tema GTK configurado: $THEME"
else
    log_nivel INFO "Tema GTK NAO foi alterado (DEFAULT ou inexistente)."
fi

# ============================================================
# Aplicar wallpaper e configuracoes conforme o DE
# ============================================================
log_nivel INFO "Aplicando configuracoes para: $DESKTOP_ENV"

case "$DESKTOP_ENV" in
    cinnamon)
        # CORRECAO: Cinnamon usa dconf (e um fork do GNOME), nao um
        # arquivo de configuracao solto. A versao anterior escrevia em
        # /etc/skel/.config/cinnamon-settings.conf, que o Cinnamon
        # nunca le - nao tinha efeito nenhum. Usar dconf keyfile igual
        # ao branch do GNOME, com sintaxe de caminho (barras), nao a
        # notacao com pontos do schema id.
        mkdir -p /etc/dconf/db/local.d
        cat > /etc/dconf/db/local.d/seederlinux-branding-cinnamon <<EOF
[org/cinnamon/desktop/background]
picture-uri='file:///usr/share/backgrounds/seederlinux/wallpaper.jpg'
picture-options='zoom'
EOF
        if [ "$THEME_APLICAR" = "true" ]; then
            cat >> /etc/dconf/db/local.d/seederlinux-branding-cinnamon <<EOF

[org/cinnamon/desktop/interface]
gtk-theme='${THEME}'
icon-theme-name='Adwaita'

[org/cinnamon/theme]
name='${THEME}'
EOF
        fi
        dconf update 2>/dev/null || true
        ;;

    mate)
        # CORRECAO: mesmo problema do Cinnamon - MATE tambem usa dconf,
        # nao /etc/skel/.config/mate-background.conf (nunca lido).
        mkdir -p /etc/dconf/db/local.d
        cat > /etc/dconf/db/local.d/seederlinux-branding-mate <<EOF
[org/mate/desktop/background]
picture-filename='/usr/share/backgrounds/seederlinux/wallpaper.jpg'
picture-options='zoom'
EOF
        if [ "$THEME_APLICAR" = "true" ]; then
            cat >> /etc/dconf/db/local.d/seederlinux-branding-mate <<EOF

[org/mate/desktop/interface]
gtk-theme='${THEME}'
icon-theme='Adwaita'
EOF
        fi
        dconf update 2>/dev/null || true
        ;;

    gnome)
        # GNOME - via gsettings (dconf)
        mkdir -p /etc/dconf/db/local.d
        cat > /etc/dconf/db/local.d/seederlinux-branding <<EOF
[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/seederlinux/wallpaper.jpg'
picture-uri-dark='file:///usr/share/backgrounds/seederlinux/wallpaper.jpg'
picture-options='zoom'

[org/gnome/login-screen]
logo='/usr/share/pixmaps/seederlinux-logo.png'
EOF
        if [ "$THEME_APLICAR" = "true" ]; then
            cat >> /etc/dconf/db/local.d/seederlinux-branding <<EOF

[org/gnome/desktop/interface]
gtk-theme='${THEME}'
icon-theme='Adwaita'
EOF
        fi
        dconf update 2>/dev/null || true
        ;;

    xfce)
        # XFCE - via xfconf
        mkdir -p /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml
        cat > /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitor0" type="empty">
        <property name="image-path" type="string" value="/usr/share/backgrounds/seederlinux/wallpaper.jpg"/>
        <property name="image-style" type="int" value="5"/>
      </property>
    </property>
  </property>
</channel>
EOF
        ;;

    kde)
        # KDE Plasma - via kdeglobals (SOMENTE se THEME_APLICAR)
        if [ "$THEME_APLICAR" = "true" ]; then
            mkdir -p /etc/skel/.config
            cat > /etc/skel/.config/kdeglobals <<EOF
[General]
ColorScheme=${THEME}
Name=${THEME}

[KDE]
widgetStyle=${THEME}
EOF
        fi
        # Wallpaper via plasma config (independe de tema)
        mkdir -p /etc/skel/.config
        cat > /etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc <<EOF
[Containments][1][Wallpaper][org.kde.image][General]
Image=file:///usr/share/backgrounds/seederlinux/wallpaper.jpg
EOF
        ;;

    lxde)
        # LXDE - via pcmanfm
        mkdir -p /etc/skel/.config/pcmanfm/LXDE
        cat > /etc/skel/.config/pcmanfm/LXDE/pcmanfm.conf <<EOF
[desktop]
wallpaper_mode=crop
wallpaper=/usr/share/backgrounds/seederlinux/wallpaper.jpg
EOF
        ;;

    lxqt)
        # LXQt - via lxqt.conf + pcmanfm-qt
        mkdir -p /etc/skel/.config/lxqt
        cat > /etc/skel/.config/lxqt/lxqt.conf <<EOF
[General]
theme=Ambiance
icon_theme=Adwaita
EOF
        mkdir -p /etc/skel/.config/pcmanfm-qt/lxqt
        cat > /etc/skel/.config/pcmanfm-qt/lxqt/settings.conf <<EOF
[Wallpaper]
Wallpaper=/usr/share/backgrounds/seederlinux/wallpaper.jpg
WallpaperMode=zoom
EOF
        ;;
esac

# ============================================================
# Configurar wallpaper de login (greeter)
# CORRECAO: theme-name=${THEME} incondicional removido do LightDM -
# mesmo problema do THEME=DEFAULT explicado acima.
#
# CORRECAO de permissoes: o LightDM le lightdm-gtk-greeter.conf como
# usuario `lightdm` (uid 113), nao como root. chmod 0644 garante
# leitura. E o `background` aponta para wallpaper-login.jpg - que a
# esta altura ja existe (download OK, fallback do greeter, ou
# fallback do wallpaper da sessao).
# ============================================================
log_nivel INFO "Configurando wallpaper de login..."
case "$DISPLAY_MANAGER" in
    lightdm)
        mkdir -p /etc/lightdm
        if [ -s /usr/share/backgrounds/seederlinux/wallpaper-login.jpg ]; then
            cat > /etc/lightdm/lightdm-gtk-greeter.conf <<EOF
[greeter]
background=/usr/share/backgrounds/seederlinux/wallpaper-login.jpg
logo=/usr/share/pixmaps/seederlinux-logo.png
icon-theme-name=Adwaita
font-name=DejaVu Sans 10
EOF
            if [ "$THEME_APLICAR" = "true" ]; then
                echo "theme-name=${THEME}" >> /etc/lightdm/lightdm-gtk-greeter.conf
            fi
            # lightdm le este arquivo como usuario `lightdm`.
            chmod 0644 /etc/lightdm/lightdm-gtk-greeter.conf
            log_nivel INFO "lightdm-gtk-greeter.conf configurado (background=$LOGIN_WP)"
        else
            log_nivel AVISO "wallpaper-login.jpg ausente - greeter mantem padrao do sistema"
        fi
        ;;
    gdm3)
        if [ -s /usr/share/backgrounds/seederlinux/wallpaper-login.jpg ]; then
            # GDM3 usa dconf para configuracao
            mkdir -p /etc/dconf/db/gdm.d
            cat > /etc/dconf/db/gdm.d/01-seederlinux-background <<EOF
[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/seederlinux/wallpaper-login.jpg'
picture-options='zoom'
EOF
            dconf update 2>/dev/null || true
            log_nivel INFO "GDM3 background configurado"
        else
            log_nivel AVISO "wallpaper-login.jpg ausente - GDM3 mantem padrao do sistema"
        fi
        ;;
    sddm)
        if [ -s /usr/share/backgrounds/seederlinux/wallpaper-login.jpg ]; then
            mkdir -p /etc/sddm.conf.d
            cat > /etc/sddm.conf.d/seederlinux.conf <<EOF
[Theme]
ThemeDir=/usr/share/sddm/themes
Current=seederlinux
Background=/usr/share/backgrounds/seederlinux/wallpaper-login.jpg
EOF
            log_nivel INFO "SDDM background configurado"
        else
            log_nivel AVISO "wallpaper-login.jpg ausente - SDDM mantem padrao do sistema"
        fi
        ;;
esac

# ============================================================
# Sumario final dos assets (observabilidade - facilita debug)
# ============================================================
log_nivel INFO "Sumario dos assets instalados:"
ls -la /usr/share/backgrounds/seederlinux/ 2>/dev/null | sed 's/^/    /'
ls -la /usr/share/pixmaps/seederlinux-logo.png 2>/dev/null | sed 's/^/    /'

log_nivel OK "Identidade visual aplicada!"
echo "============================================================"
)
$SeederScript$,
    TRUE,
    TRUE,
    15,
    ARRAY['core_config.sh']::TEXT[],
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    depends_on = EXCLUDED.depends_on,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Sessao LightDM (ordem 16) - core_session_lightdm.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, depends_on, version, organization_id)
VALUES (
    'Sessao LightDM',
    'core_session_lightdm.sh',
    'Configura LightDM como display manager (autoselecao via DISPLAY_MANAGER=lightdm).',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_session_lightdm.sh
# SeederLinux Lite - LightDM: logon/logoff (MATE, Cinnamon, XFCE, LXDE)
# ============================================================================
# Configura o LightDM como display manager e define os scripts de logon
# e logoff que serao executados nas transicoes de sessao.
#
# Resolucao de DESKTOP_ENV/DISPLAY_MANAGER (nessa ordem):
#   1) Valor injetado pela OM ( / )
#   2) Valor ja persistido em /etc/seederlinux/config.env (escrito por
#      este mesmo script em uma execucao anterior, ou por outro dos
#      scripts de sessao no mesmo bundle)
#   3) Deteccao em runtime: DM ja ativo -> DM ja instalado -> padrao
#      por DE (gnome->gdm3, kde->sddm, qualquer outro->lightdm)
#
# O resultado final e sempre regravado em config.env, para que os
# demais scripts de sessao (gdm3/sddm) e as fases seguintes (branding,
# logon, logoff) reaproveitem a mesma resposta sem redetectar.
#
# CORRECAO CRITICA (v1): a versao anterior usava `return 0` dentro deste
# subshell "( ... )", o que nao e uma funcao. Isso gera erro em
# runtime ("return: can only `return' from a function or sourced
# script"), o subshell termina com exit code != 0 e, como o bundle
# roda com `set -e`, o erro ABORTA O BUNDLE INTEIRO ali mesmo -
# em qualquer distro/DE. Este script usa `exit` (valido dentro do
# subshell) em todos os pontos de saida antecipada.
#
# CORRECAO CRITICA (v2, esta versao): o bloco final de "reiniciar
# LightDM" foi REMOVIDO. Motivo:
#   - A tentativa de guarda era: reiniciar so se estiver via TTY/cron
#     (sem $DISPLAY) ou se vier por SSH ($SSH_CONNECTION), para nao
#     matar sessao local.
#   - O caso NAO pensado: o agente Python roda via cron, sem $DISPLAY
#     e sem $SSH_CONNECTION. Cai exatamente na condicao que reinicia
#     o LightDM -> mata a sessao do usuario logado, sem aviso.
#   - Nao ha necessidade de reiniciar o DM para aplicar a config: ele
#     le os arquivos quando sobe, no proximo boot. Reiniciar em
#     runtime so serve para "aplicar agora", e isso nunca justifica
#     matar sessao de usuario.
#   - Regra do projeto: o bundle NAO reinicia display manager.
#
# Os placeholders VARIAVEL sao substituidos automaticamente
# pelo sistema na geracao do bundle.
# ============================================================================

(
set -e

source /usr/local/lib/seederlinux/diag.sh 2>/dev/null || true
SCRIPT_ID="16-session-lightdm"

echo "============================================================"
echo "Configurar LightDM (MATE, Cinnamon, XFCE, LXDE)"
echo "============================================================"

# ============================================================
# Variáveis
# ============================================================
DISPLAY_MANAGER=""
DESKTOP_ENV=""
BASE_URL="{{BASE_URL}}"
DOMINIO="{{DOMINIO}}"
DOMINIO_NETBIOS="{{DOMINIO_NETBIOS}}"
GRUPO_ADMIN_AD="{{GRUPO_ADMIN_AD}}"
THEME="{{THEME}}"

CONFIG_FILE="/etc/seederlinux/config.env"

# ============================================================
# Funcoes de deteccao (usadas somente se nao vier persistido)
# ============================================================
detectar_de() {
    if command -v cinnamon-session &>/dev/null; then echo "cinnamon"
    elif command -v mate-session &>/dev/null; then echo "mate"
    elif command -v gnome-session &>/dev/null; then echo "gnome"
    elif command -v startxfce4 &>/dev/null; then echo "xfce"
    elif command -v startplasma-x11 &>/dev/null; then echo "kde"
    elif command -v lxqt-session &>/dev/null; then echo "lxqt"
    elif command -v startlxde &>/dev/null; then echo "lxde"
    else echo "unknown"
    fi
}

detectar_dm_ativo() {
    if systemctl is-active --quiet lightdm 2>/dev/null; then echo "lightdm"
    elif systemctl is-active --quiet gdm3 2>/dev/null; then echo "gdm3"
    elif systemctl is-active --quiet sddm 2>/dev/null; then echo "sddm"
    else echo ""
    fi
}

detectar_dm_instalado() {
    if dpkg -l lightdm 2>/dev/null | grep -q "^ii"; then echo "lightdm"
    elif dpkg -l gdm3 2>/dev/null | grep -q "^ii"; then echo "gdm3"
    elif dpkg -l sddm 2>/dev/null | grep -q "^ii"; then echo "sddm"
    else echo ""
    fi
}

dm_padrao_para_de() {
    case "$1" in
        gnome) echo "gdm3" ;;
        kde)   echo "sddm" ;;
        *)     echo "lightdm" ;;  # cinnamon, mate, xfce, lxde, lxqt, unknown
    esac
}

# ============================================================
# 1. Resolver DESKTOP_ENV (OM -> config.env -> deteccao)
# ============================================================
if [ -z "$DESKTOP_ENV" ] && [ -f "$CONFIG_FILE" ]; then
    DESKTOP_ENV="$(grep -m1 '^DESKTOP_ENV=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"')"
fi
if [ -z "$DESKTOP_ENV" ]; then
    DESKTOP_ENV="$(detectar_de)"
    log_nivel INFO "DESKTOP_ENV nao informado. Detectado em runtime: $DESKTOP_ENV"
else
    log_nivel INFO "DESKTOP_ENV: $DESKTOP_ENV"
fi

# ============================================================
# 2. Resolver DISPLAY_MANAGER (OM -> config.env -> deteccao)
# ============================================================
if [ -z "$DISPLAY_MANAGER" ] && [ -f "$CONFIG_FILE" ]; then
    DISPLAY_MANAGER="$(grep -m1 '^DISPLAY_MANAGER=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"')"
fi
if [ -z "$DISPLAY_MANAGER" ]; then
    DISPLAY_MANAGER="$(detectar_dm_ativo)"
    [ -z "$DISPLAY_MANAGER" ] && DISPLAY_MANAGER="$(detectar_dm_instalado)"
    [ -z "$DISPLAY_MANAGER" ] && DISPLAY_MANAGER="$(dm_padrao_para_de "$DESKTOP_ENV")"
    log_nivel INFO "DISPLAY_MANAGER nao informado. Resolvido automaticamente: $DISPLAY_MANAGER"
else
    log_nivel INFO "DISPLAY_MANAGER: $DISPLAY_MANAGER"
fi

# ============================================================
# 3. Persistir o resultado para os proximos scripts (gdm3/sddm,
#    branding, logon, logoff) reaproveitarem sem redetectar
# ============================================================
mkdir -p /etc/seederlinux
touch "$CONFIG_FILE"
sed -i '/^DESKTOP_ENV=/d;/^DISPLAY_MANAGER=/d' "$CONFIG_FILE"
{
    echo "DESKTOP_ENV=${DESKTOP_ENV}"
    echo "DISPLAY_MANAGER=${DISPLAY_MANAGER}"
} >> "$CONFIG_FILE"

# ============================================================
# 4. Este script so configura LightDM. Se o DM resolvido for
#    outro, encerra este bloco (nao o bundle) e segue para 14b/14c.
# ============================================================
if [ "$DISPLAY_MANAGER" != "lightdm" ]; then
    log_nivel INFO "DISPLAY_MANAGER resolvido e '$DISPLAY_MANAGER' (nao e lightdm). Pulando."
    echo "============================================================"
    exit 0
fi

log_nivel INFO "Display Manager: $DISPLAY_MANAGER"
log_nivel INFO "Ambiente: $DESKTOP_ENV"

# ============================================================
# Verificar se LightDM + greeter estao presentes.
# CORRECAO: NAO instalar aqui - este script roda DEPOIS do ingresso
# no AD, quando o DNS ja foi trocado pro controlador de dominio e
# nao resolve mais repositorios publicos. A instalacao real acontece
# no core_packages.sh (etapa 04), enquanto o DNS de internet ainda
# esta ativo. Aqui so verificamos e configuramos.
# ============================================================
if ! dpkg -l lightdm 2>/dev/null | grep -q "^ii"; then
    log_nivel ERRO "lightdm nao instalado (deveria ter sido no core_packages.sh)."
    log_nivel INFO "Pulando configuracao de LightDM."
    echo "============================================================"
    exit 0
fi

if dpkg -l lightdm-slick-greeter 2>/dev/null | grep -q "^ii"; then
    GREETER_SESSION="lightdm-slick-greeter"
elif dpkg -l lightdm-gtk-greeter 2>/dev/null | grep -q "^ii"; then
    GREETER_SESSION="lightdm-gtk-greeter"
else
    log_nivel ERRO "nenhum greeter instalado."
    log_nivel INFO "Pulando configuracao de LightDM."
    echo "============================================================"
    exit 0
fi
log_nivel INFO "Greeter a usar: $GREETER_SESSION"

# Registrar LightDM como DM padrao (arquivo canonico do Debian/Ubuntu)
echo "lightdm shared/default-x-display-manager select lightdm" | debconf-set-selections 2>/dev/null || true
echo "lightdm lightdm/daemon_name string lightdm" | debconf-set-selections 2>/dev/null || true
echo "/usr/sbin/lightdm" > /etc/X11/default-display-manager

# ============================================================
# Configurar LightDM
# ============================================================
log_nivel INFO "Configurando LightDM..."
mkdir -p /etc/lightdm

cat > /etc/lightdm/lightdm.conf <<EOF
# Configuracao LightDM - SeederLinux
[Seat:*]
greeter-session=${GREETER_SESSION}
user-session=${DESKTOP_ENV}
allow-guest=false
greeter-hide-users=true
greeter-show-manual-login=true
session-wrapper=/etc/lightdm/Xsession
pam-service=lightdm
pam-autologin-service=lightdm-autologin

# Logoff via hook do DM (root, tolerante - so desmonta/mata processo).
# Logon NAO fica mais aqui: passou a rodar via autostart XDG dentro da
# sessao do usuario (ver core_logon.sh), porque session-setup-script
# roda como root ANTES da sessao existir - sem D-Bus/HOME do usuario
# corretos, os gsettings/mounts/atalhos nao aplicavam de verdade.
session-cleanup-script=/usr/local/bin/seederlinux-logoff
EOF

log_nivel INFO "LightDM configurado"

# ============================================================
# Configurar greeter do LightDM
# CORRECAO: theme-name = ${THEME} removido daqui incondicionalmente -
# quando THEME="DEFAULT" (ou vazio), "DEFAULT" nao e um tema GTK
# valido; o core_branding.sh ja decide se THEME deve ser aplicado
# (grava em outro arquivo quando aplicavel). Este greeter.conf fica
# sem theme-name explicito, usando o tema padrao do sistema.
# ============================================================
log_nivel INFO "Configurando greeter..."
mkdir -p /etc/lightdm

cat > /etc/lightdm/lightdm-gtk-greeter.conf <<EOF
[greeter]
icon-theme-name = Adwaita
font-name = DejaVu Sans 10
background = /usr/share/backgrounds/seederlinux/wallpaper-login.jpg
logo = /usr/share/pixmaps/seederlinux-logo.png
show-indicators = ~host;~spacer;~clock;~spacer;~session;~spacer;~power
EOF

log_nivel INFO "Greeter configurado"

# ============================================================
# Configurar Xsession
# ============================================================
log_nivel INFO "Configurando Xsession..."
if [ ! -f /etc/lightdm/Xsession ]; then
    cat > /etc/lightdm/Xsession <<'XSESSION'
#!/bin/bash
# Xsession do SeederLinux para LightDM
exec /etc/X11/Xsession "$@"
XSESSION
    chmod +x /etc/lightdm/Xsession
fi

# ============================================================
# Garantir que os scripts de logon/logoff existam
# ============================================================
log_nivel INFO "Verificando scripts de logon/logoff..."
for SCRIPT in seederlinux-logon seederlinux-logoff; do
    if [ ! -f "/usr/local/bin/${SCRIPT}" ]; then
        log_nivel AVISO "/usr/local/bin/${SCRIPT} nao encontrado."
        log_nivel INFO "Os scripts core_logon.sh e core_logoff.sh devem ser executados antes."
    fi
done

# ============================================================
# Desabilitar outros display managers
# ============================================================
log_nivel INFO "Desabilitando outros display managers..."
systemctl disable gdm3 2>/dev/null || true
systemctl disable sddm 2>/dev/null || true

systemctl enable lightdm 2>/dev/null || true
ln -sf /lib/systemd/system/lightdm.service /etc/systemd/system/display-manager.service

# ============================================================
# Aplicacao da config: NAO reiniciar o DM.
#
# Versao anterior tentava reiniciar "so quando seguro" usando
# `[ -z "$DISPLAY" ] || [ -n "$SSH_CONNECTION" ]`. Isso FALHAVA
# quando o bundle era invocado pelo agente Python (via cron):
# cron nao tem $DISPLAY nem $SSH_CONNECTION, entao a condicao dava
# verdadeiro, o restart acontecia e MATAVA A SESSAO DO USUARIO.
#
# Solucao: nao reiniciar nunca. A config do LightDM e' lida pelo
# daemon quando ele sobe - no proximo boot a config ja vale. Nao
# ha caso legitimo de "precisa aplicar agora" que justifique matar
# sessao de usuario logado.
# ============================================================
log_nivel INFO "Configuracao de LightDM sera aplicada no proximo boot."
log_nivel INFO "(NAO reiniciamos o DM aqui: se o bundle rodar via cron/agente,"
log_nivel INFO "ele nao tem \$DISPLAY nem \$SSH_CONNECTION - qualquer restart"
log_nivel INFO "mataria a sessao do usuario logado.)"

log_nivel OK "LightDM configurado!"
echo "============================================================"
)
$SeederScript$,
    TRUE,
    TRUE,
    16,
    ARRAY[]::TEXT[],
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    depends_on = EXCLUDED.depends_on,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Sessao GDM3 (ordem 17) - core_session_gdm3.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, depends_on, version, organization_id)
VALUES (
    'Sessao GDM3',
    'core_session_gdm3.sh',
    'Configura GDM3 como display manager (autoselecao via DISPLAY_MANAGER=gdm3).',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_session_gdm3.sh
# SeederLinux Lite - GDM3: logon/logoff (GNOME)
# ============================================================================
# Configura o GDM3 como display manager e define os scripts de logon
# e logoff que serao executados nas transicoes de sessao.
#
# Resolucao de DESKTOP_ENV/DISPLAY_MANAGER (nessa ordem):
#   1) Valor injetado pela OM ( / )
#   2) Valor ja persistido em /etc/seederlinux/config.env (escrito pelo
#      core_session_lightdm.sh ou por este mesmo script)
#   3) Deteccao em runtime: DM ja ativo -> DM ja instalado -> padrao
#      por DE (gnome->gdm3, kde->sddm, qualquer outro->lightdm)
#
# CORRECAO CRITICA (v1): a versao anterior usava `return 0` dentro deste
# subshell "( ... )", o que nao e uma funcao e gera erro em runtime,
# abortando o BUNDLE INTEIRO sob `set -e`. Este script usa `exit`
# em todos os pontos de saida antecipada.
#
# CORRECAO CRITICA (v2, esta versao): o bloco final de "reiniciar
# GDM3" foi REMOVIDO pelo mesmo motivo do LightDM: quando o bundle
# roda via cron/agente, $DISPLAY e $SSH_CONNECTION nao existem, entao
# o guard "so reinicia se nao estiver em sessao grafica" nao protegia
# nada - reiniciava e matava a sessao do usuario. Regra do projeto:
# o bundle NAO reinicia display manager.
#
# Os placeholders VARIAVEL sao substituidos automaticamente
# pelo sistema na geracao do bundle.
# ============================================================================

(
set -e

source /usr/local/lib/seederlinux/diag.sh 2>/dev/null || true
SCRIPT_ID="17-session-gdm3"

echo "============================================================"
echo "Configurar GDM3 (GNOME)"
echo "============================================================"

# ============================================================
# Variáveis
# ============================================================
DISPLAY_MANAGER=""
DESKTOP_ENV=""
BASE_URL="{{BASE_URL}}"
DOMINIO="{{DOMINIO}}"
DOMINIO_NETBIOS="{{DOMINIO_NETBIOS}}"
GRUPO_ADMIN_AD="{{GRUPO_ADMIN_AD}}"

CONFIG_FILE="/etc/seederlinux/config.env"

# ============================================================
# Funcoes de deteccao (usadas somente se nao vier persistido)
# ============================================================
detectar_de() {
    if command -v cinnamon-session &>/dev/null; then echo "cinnamon"
    elif command -v mate-session &>/dev/null; then echo "mate"
    elif command -v gnome-session &>/dev/null; then echo "gnome"
    elif command -v startxfce4 &>/dev/null; then echo "xfce"
    elif command -v startplasma-x11 &>/dev/null; then echo "kde"
    elif command -v lxqt-session &>/dev/null; then echo "lxqt"
    elif command -v startlxde &>/dev/null; then echo "lxde"
    else echo "unknown"
    fi
}

detectar_dm_ativo() {
    if systemctl is-active --quiet lightdm 2>/dev/null; then echo "lightdm"
    elif systemctl is-active --quiet gdm3 2>/dev/null; then echo "gdm3"
    elif systemctl is-active --quiet sddm 2>/dev/null; then echo "sddm"
    else echo ""
    fi
}

detectar_dm_instalado() {
    if dpkg -l lightdm 2>/dev/null | grep -q "^ii"; then echo "lightdm"
    elif dpkg -l gdm3 2>/dev/null | grep -q "^ii"; then echo "gdm3"
    elif dpkg -l sddm 2>/dev/null | grep -q "^ii"; then echo "sddm"
    else echo ""
    fi
}

dm_padrao_para_de() {
    case "$1" in
        gnome) echo "gdm3" ;;
        kde)   echo "sddm" ;;
        *)     echo "lightdm" ;;
    esac
}

# ============================================================
# 1. Resolver DESKTOP_ENV (OM -> config.env -> deteccao)
# ============================================================
if [ -z "$DESKTOP_ENV" ] && [ -f "$CONFIG_FILE" ]; then
    DESKTOP_ENV="$(grep -m1 '^DESKTOP_ENV=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"')"
fi
if [ -z "$DESKTOP_ENV" ]; then
    DESKTOP_ENV="$(detectar_de)"
    log_nivel INFO "DESKTOP_ENV nao informado. Detectado em runtime: $DESKTOP_ENV"
else
    log_nivel INFO "DESKTOP_ENV: $DESKTOP_ENV"
fi

# ============================================================
# 2. Resolver DISPLAY_MANAGER (OM -> config.env -> deteccao)
# ============================================================
if [ -z "$DISPLAY_MANAGER" ] && [ -f "$CONFIG_FILE" ]; then
    DISPLAY_MANAGER="$(grep -m1 '^DISPLAY_MANAGER=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"')"
fi
if [ -z "$DISPLAY_MANAGER" ]; then
    DISPLAY_MANAGER="$(detectar_dm_ativo)"
    [ -z "$DISPLAY_MANAGER" ] && DISPLAY_MANAGER="$(detectar_dm_instalado)"
    [ -z "$DISPLAY_MANAGER" ] && DISPLAY_MANAGER="$(dm_padrao_para_de "$DESKTOP_ENV")"
    log_nivel INFO "DISPLAY_MANAGER nao informado. Resolvido automaticamente: $DISPLAY_MANAGER"
else
    log_nivel INFO "DISPLAY_MANAGER: $DISPLAY_MANAGER"
fi

# ============================================================
# 3. Persistir o resultado (idempotente - reafirma o mesmo valor
#    se o core_session_lightdm.sh ja tiver gravado)
# ============================================================
mkdir -p /etc/seederlinux
touch "$CONFIG_FILE"
sed -i '/^DESKTOP_ENV=/d;/^DISPLAY_MANAGER=/d' "$CONFIG_FILE"
{
    echo "DESKTOP_ENV=${DESKTOP_ENV}"
    echo "DISPLAY_MANAGER=${DISPLAY_MANAGER}"
} >> "$CONFIG_FILE"

# ============================================================
# 4. Este script so configura GDM3. Se o DM resolvido for outro,
#    encerra este bloco (nao o bundle) e segue para 14c.
# ============================================================
if [ "$DISPLAY_MANAGER" != "gdm3" ]; then
    log_nivel INFO "DISPLAY_MANAGER resolvido e '$DISPLAY_MANAGER' (nao e gdm3). Pulando."
    echo "============================================================"
    exit 0
fi

log_nivel INFO "Display Manager: $DISPLAY_MANAGER"
log_nivel INFO "Ambiente: $DESKTOP_ENV"

# ============================================================
# Verificar se GDM3 esta presente.
# CORRECAO: NAO instalar aqui - este script roda DEPOIS do ingresso
# no AD, quando o DNS ja foi trocado pro controlador de dominio e
# nao resolve mais repositorios publicos. A instalacao real acontece
# no core_packages.sh (etapa 04), enquanto o DNS de internet ainda
# esta ativo.
# ============================================================
if ! dpkg -l gdm3 2>/dev/null | grep -q "^ii"; then
    log_nivel ERRO "gdm3 nao instalado (deveria ter sido no core_packages.sh)."
    log_nivel INFO "Pulando configuracao do GDM3."
    echo "============================================================"
    exit 0
fi

echo "gdm3 shared/default-x-display-manager select gdm3" | debconf-set-selections 2>/dev/null || true
echo "gdm3 gdm3/daemon_name string gdm3" | debconf-set-selections 2>/dev/null || true
echo "/usr/sbin/gdm3" > /etc/X11/default-display-manager

# ============================================================
# Configurar GDM3
# ============================================================
log_nivel INFO "Configurando GDM3..."
mkdir -p /etc/gdm3

cat > /etc/gdm3/daemon.conf <<EOF
# Configuracao GDM3 - SeederLinux
[daemon]
WaylandEnable=false
AutomaticLoginEnable=false
TimedLoginEnable=false

[security]
DisallowRoot=true

[greeter]
Session=${DESKTOP_ENV}
EOF

log_nivel INFO "GDM3 configurado (daemon.conf)"

# Ubuntu 24.04+: o GDM3 le WaylandEnable de /etc/gdm3/custom.conf,
# NAO de daemon.conf. Sem isso, o GDM sobe em Wayland e quebra
# x11vnc (nao acessa display :0). Escrever ambos.
cat > /etc/gdm3/custom.conf <<EOF
# Configuracao GDM3 custom - SeederLinux (Ubuntu 24.04+)
[daemon]
WaylandEnable=false
AutomaticLoginEnable=false
TimedLoginEnable=false

[security]
DisallowRoot=true
EOF

log_nivel INFO "GDM3 configurado (custom.conf)"

# ============================================================
# Configurar script de logoff via PostSession
# ============================================================
# Logon NAO fica mais aqui (PreSession removido): PreSession roda como
# root ANTES da sessao existir - sem D-Bus/HOME do usuario corretos,
# os gsettings/mounts/atalhos nao aplicavam de verdade. O logon passou
# a rodar via autostart XDG dentro da sessao (ver core_logon.sh).
# Logoff continua aqui pois so desmonta/mata processo (tolerante a
# rodar como root).
log_nivel INFO "Configurando script de logoff no GDM3..."

POSTSESSION_FILE="/etc/gdm3/PostSession/Default"
mkdir -p /etc/gdm3/PostSession

cat > "$POSTSESSION_FILE" <<'POSTSESSION'
#!/bin/bash
# PostSession do GDM3 - SeederLinux
if [ -x /usr/local/bin/seederlinux-logoff ]; then
    /usr/local/bin/seederlinux-logoff "$@"
fi

exit "${EXIT_STATUS:-0}"
POSTSESSION
chmod +x "$POSTSESSION_FILE"

log_nivel INFO "Script de logoff configurado no GDM3"

# ============================================================
# Garantir que os scripts de logon/logoff existam
# ============================================================
log_nivel INFO "Verificando scripts de logon/logoff..."
for SCRIPT in seederlinux-logon seederlinux-logoff; do
    if [ ! -f "/usr/local/bin/${SCRIPT}" ]; then
        log_nivel AVISO "/usr/local/bin/${SCRIPT} nao encontrado."
        log_nivel INFO "Os scripts core_logon.sh e core_logoff.sh devem ser executados antes."
    fi
done

# ============================================================
# Desabilitar outros display managers
# ============================================================
log_nivel INFO "Desabilitando outros display managers..."
systemctl disable lightdm 2>/dev/null || true
systemctl disable sddm 2>/dev/null || true

systemctl enable gdm3 2>/dev/null || true
ln -sf /lib/systemd/system/gdm.service /etc/systemd/system/display-manager.service

# ============================================================
# Aplicacao da config: NAO reiniciar o DM.
# Mesmo motivo do core_session_lightdm.sh - o guard baseado em
# $DISPLAY/$SSH_CONNECTION falha quando o bundle roda via cron
# (agente Python), matando a sessao do usuario logado.
# ============================================================
log_nivel INFO "Configuracao de GDM3 sera aplicada no proximo boot."
log_nivel INFO "(NAO reiniciamos o DM aqui - ver comentario no topo deste script.)"

log_nivel OK "GDM3 configurado!"
echo "============================================================"
)
$SeederScript$,
    TRUE,
    TRUE,
    17,
    ARRAY[]::TEXT[],
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    depends_on = EXCLUDED.depends_on,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Sessao SDDM (ordem 18) - core_session_sddm.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, depends_on, version, organization_id)
VALUES (
    'Sessao SDDM',
    'core_session_sddm.sh',
    'Configura SDDM como display manager (autoselecao via DISPLAY_MANAGER=sddm).',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_session_sddm.sh
# SeederLinux Lite - SDDM: logon/logoff (KDE)
# ============================================================================
# Configura o SDDM como display manager e define os scripts de logon
# e logoff que serao executados nas transicoes de sessao.
#
# Resolucao de DESKTOP_ENV/DISPLAY_MANAGER (nessa ordem):
#   1) Valor injetado pela OM ( / )
#   2) Valor ja persistido em /etc/seederlinux/config.env (escrito pelo
#      core_session_lightdm.sh/core_session_gdm3.sh ou por este mesmo
#      script)
#   3) Deteccao em runtime: DM ja ativo -> DM ja instalado -> padrao
#      por DE (gnome->gdm3, kde->sddm, qualquer outro->lightdm)
#
# CORRECAO CRITICA (v1): a versao anterior usava `return 0` dentro deste
# subshell "( ... )", o que nao e uma funcao e gera erro em runtime,
# abortando o BUNDLE INTEIRO sob `set -e`. Este script usa `exit`
# em todos os pontos de saida antecipada.
#
# CORRECAO CRITICA (v2, esta versao): o bloco final de "reiniciar
# SDDM" foi REMOVIDO. Mesmo motivo do LightDM/GDM3: quando o bundle
# roda via cron/agente, $DISPLAY e $SSH_CONNECTION nao existem, entao
# o guard nao protegia nada - reiniciava e matava a sessao do usuario.
# Regra do projeto: o bundle NAO reinicia display manager.
#
# Os placeholders VARIAVEL sao substituidos automaticamente
# pelo sistema na geracao do bundle.
# ============================================================================

(
set -e

source /usr/local/lib/seederlinux/diag.sh 2>/dev/null || true
SCRIPT_ID="18-session-sddm"

echo "============================================================"
echo "Configurar SDDM (KDE)"
echo "============================================================"

# ============================================================
# Variáveis
# ============================================================
DISPLAY_MANAGER=""
DESKTOP_ENV=""
BASE_URL="{{BASE_URL}}"
DOMINIO="{{DOMINIO}}"
DOMINIO_NETBIOS="{{DOMINIO_NETBIOS}}"
GRUPO_ADMIN_AD="{{GRUPO_ADMIN_AD}}"

CONFIG_FILE="/etc/seederlinux/config.env"

# ============================================================
# Funcoes de deteccao (usadas somente se nao vier persistido)
# ============================================================
detectar_de() {
    if command -v cinnamon-session &>/dev/null; then echo "cinnamon"
    elif command -v mate-session &>/dev/null; then echo "mate"
    elif command -v gnome-session &>/dev/null; then echo "gnome"
    elif command -v startxfce4 &>/dev/null; then echo "xfce"
    elif command -v startplasma-x11 &>/dev/null; then echo "kde"
    elif command -v lxqt-session &>/dev/null; then echo "lxqt"
    elif command -v startlxde &>/dev/null; then echo "lxde"
    else echo "unknown"
    fi
}

detectar_dm_ativo() {
    if systemctl is-active --quiet lightdm 2>/dev/null; then echo "lightdm"
    elif systemctl is-active --quiet gdm3 2>/dev/null; then echo "gdm3"
    elif systemctl is-active --quiet sddm 2>/dev/null; then echo "sddm"
    else echo ""
    fi
}

detectar_dm_instalado() {
    if dpkg -l lightdm 2>/dev/null | grep -q "^ii"; then echo "lightdm"
    elif dpkg -l gdm3 2>/dev/null | grep -q "^ii"; then echo "gdm3"
    elif dpkg -l sddm 2>/dev/null | grep -q "^ii"; then echo "sddm"
    else echo ""
    fi
}

dm_padrao_para_de() {
    case "$1" in
        gnome) echo "gdm3" ;;
        kde)   echo "sddm" ;;
        *)     echo "lightdm" ;;
    esac
}

# ============================================================
# 1. Resolver DESKTOP_ENV (OM -> config.env -> deteccao)
# ============================================================
if [ -z "$DESKTOP_ENV" ] && [ -f "$CONFIG_FILE" ]; then
    DESKTOP_ENV="$(grep -m1 '^DESKTOP_ENV=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"')"
fi
if [ -z "$DESKTOP_ENV" ]; then
    DESKTOP_ENV="$(detectar_de)"
    log_nivel INFO "DESKTOP_ENV nao informado. Detectado em runtime: $DESKTOP_ENV"
else
    log_nivel INFO "DESKTOP_ENV: $DESKTOP_ENV"
fi

# ============================================================
# 2. Resolver DISPLAY_MANAGER (OM -> config.env -> deteccao)
# ============================================================
if [ -z "$DISPLAY_MANAGER" ] && [ -f "$CONFIG_FILE" ]; then
    DISPLAY_MANAGER="$(grep -m1 '^DISPLAY_MANAGER=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"')"
fi
if [ -z "$DISPLAY_MANAGER" ]; then
    DISPLAY_MANAGER="$(detectar_dm_ativo)"
    [ -z "$DISPLAY_MANAGER" ] && DISPLAY_MANAGER="$(detectar_dm_instalado)"
    [ -z "$DISPLAY_MANAGER" ] && DISPLAY_MANAGER="$(dm_padrao_para_de "$DESKTOP_ENV")"
    log_nivel INFO "DISPLAY_MANAGER nao informado. Resolvido automaticamente: $DISPLAY_MANAGER"
else
    log_nivel INFO "DISPLAY_MANAGER: $DISPLAY_MANAGER"
fi

# ============================================================
# 3. Persistir o resultado (idempotente - reafirma o mesmo valor
#    se um dos scripts anteriores ja tiver gravado)
# ============================================================
mkdir -p /etc/seederlinux
touch "$CONFIG_FILE"
sed -i '/^DESKTOP_ENV=/d;/^DISPLAY_MANAGER=/d' "$CONFIG_FILE"
{
    echo "DESKTOP_ENV=${DESKTOP_ENV}"
    echo "DISPLAY_MANAGER=${DISPLAY_MANAGER}"
} >> "$CONFIG_FILE"

# ============================================================
# 4. Este script so configura SDDM. Se o DM resolvido for outro,
#    encerra este bloco (nao o bundle).
# ============================================================
if [ "$DISPLAY_MANAGER" != "sddm" ]; then
    log_nivel INFO "DISPLAY_MANAGER resolvido e '$DISPLAY_MANAGER' (nao e sddm). Pulando."
    echo "============================================================"
    exit 0
fi

log_nivel INFO "Display Manager: $DISPLAY_MANAGER"
log_nivel INFO "Ambiente: $DESKTOP_ENV"

# ============================================================
# Verificar se SDDM esta presente.
# CORRECAO: NAO instalar aqui - este script roda DEPOIS do ingresso
# no AD, quando o DNS ja foi trocado pro controlador de dominio e
# nao resolve mais repositorios publicos. A instalacao real acontece
# no core_packages.sh (etapa 04), enquanto o DNS de internet ainda
# esta ativo.
# ============================================================
if ! dpkg -l sddm 2>/dev/null | grep -q "^ii"; then
    log_nivel ERRO "sddm nao instalado (deveria ter sido no core_packages.sh)."
    log_nivel INFO "Pulando configuracao do SDDM."
    echo "============================================================"
    exit 0
fi

echo "sddm shared/default-x-display-manager select sddm" | debconf-set-selections 2>/dev/null || true
echo "sddm sddm/daemon_name string sddm" | debconf-set-selections 2>/dev/null || true
echo "/usr/sbin/sddm" > /etc/X11/default-display-manager

# ============================================================
# Configurar SDDM
# ============================================================
log_nivel INFO "Configurando SDDM..."
mkdir -p /etc/sddm.conf.d

cat > /etc/sddm.conf.d/seederlinux.conf <<EOF
# Configuracao SDDM - SeederLinux
[Theme]
Current=breeze
ThemeDir=/usr/share/sddm/themes

[Users]
MaximumUid=60000
MinimumUid=1000

[Autologin]
User=
Session=
EOF

log_nivel INFO "SDDM configurado"

# ============================================================
# Configurar script de logoff via Xstop
# ============================================================
# Logon NAO fica mais aqui (Xsetup removido): Xsetup roda como root
# na fase de setup do X, ANTES/fora do contexto de sessao do usuario
# (nem sempre ha usuario resolvido ainda nesse ponto) - sem D-Bus/HOME
# corretos, os gsettings/mounts/atalhos nao aplicavam de verdade. O
# logon passou a rodar via autostart XDG dentro da sessao (ver
# core_logon.sh). Logoff continua aqui pois so desmonta/mata processo
# (tolerante a rodar como root).
log_nivel INFO "Configurando script de logoff no SDDM..."

mkdir -p /usr/share/sddm/scripts

XSTOP_FILE="/usr/share/sddm/scripts/Xstop"

cat > "$XSTOP_FILE" <<'XSTOP'
#!/bin/bash
# Xstop do SDDM - SeederLinux
if [ -x /usr/local/bin/seederlinux-logoff ]; then
    /usr/local/bin/seederlinux-logoff "$@"
fi

exit "${EXIT_STATUS:-0}"
XSTOP
chmod +x "$XSTOP_FILE"

log_nivel INFO "Scripts de logon/logoff configurados no SDDM"

# ============================================================
# Garantir que os scripts de logon/logoff existam
# ============================================================
log_nivel INFO "Verificando scripts de logon/logoff..."
for SCRIPT in seederlinux-logon seederlinux-logoff; do
    if [ ! -f "/usr/local/bin/${SCRIPT}" ]; then
        log_nivel AVISO "/usr/local/bin/${SCRIPT} nao encontrado."
        log_nivel INFO "Os scripts core_logon.sh e core_logoff.sh devem ser executados antes."
    fi
done

# ============================================================
# Desabilitar outros display managers
# ============================================================
log_nivel INFO "Desabilitando outros display managers..."
systemctl disable lightdm 2>/dev/null || true
systemctl disable gdm3 2>/dev/null || true

systemctl enable sddm 2>/dev/null || true
ln -sf /lib/systemd/system/sddm.service /etc/systemd/system/display-manager.service

# ============================================================
# Aplicacao da config: NAO reiniciar o DM.
# Mesmo motivo do core_session_lightdm.sh/gdm3.sh - o guard baseado
# em $DISPLAY/$SSH_CONNECTION falha quando o bundle roda via cron
# (agente Python), matando a sessao do usuario logado.
# ============================================================
log_nivel INFO "Configuracao de SDDM sera aplicada no proximo boot."
log_nivel INFO "(NAO reiniciamos o DM aqui - ver comentario no topo deste script.)"

log_nivel OK "SDDM configurado!"
echo "============================================================"
)
$SeederScript$,
    TRUE,
    TRUE,
    18,
    ARRAY[]::TEXT[],
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    depends_on = EXCLUDED.depends_on,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Logon Persistente (ordem 19) - core_logon.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, depends_on, version, organization_id)
VALUES (
    'Logon Persistente',
    'core_logon.sh',
    'Script executado a cada logon de usuario (multi-DE).',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_logon.sh
# SeederLinux Lite - Logon MINIMALISTA (via autostart XDG)
# ============================================================================
# MUDANCA DE ARQUITETURA:
# A versao anterior era chamada pelo display manager via
# session-setup-script (LightDM) / PreSession (GDM3) / Xsetup (SDDM) -
# hooks que rodam como ROOT, ANTES da sessao grafica existir. Isso e
# documentado assim nos tres DMs: sem $HOME/$USER do usuario real e
# sem D-Bus de sessao, o que tornava suspeita a eficacia de tudo que
# dependia desses dois (montagem em $HOME, gsettings, etc).
#
# Agora o /usr/local/bin/seederlinux-logon roda via ENTRADA DE
# AUTOSTART XDG (/etc/xdg/autostart/), que e honrada por GNOME,
# Cinnamon, MATE, XFCE, KDE e LXDE de forma padronizada - executando
# DENTRO da sessao ja iniciada, como o proprio usuario, com $HOME,
# $USER e D-Bus corretos. Um mecanismo so para qualquer DE/DM.
#
# ESCOPO REDUZIDO (minimalista, conforme especificacao original):
# so o que precisa rodar em TODO login e e rapido (< 3s): montar
# compartilhamentos, impressora padrao, atalhos. Branding, tema,
# politicas de navegador, proxy, certificados etc. NAO rodam mais
# aqui - isso agora e responsabilidade do core_sync.sh (aplicador
# tipo GPO, rodando via timer systemd, independente de login).
#
# PRIVILEGIO:
# Como o script agora roda como usuario comum (nao root), mount/umount
# de CIFS precisam de sudo. Mas sudo 1.9.x+ (Ubuntu 24.04/26.04)
# REJEITA wildcards em argumentos de comando dentro do sudoers:
#
#   /etc/sudoers.d/xxx: syntax error:
#   wildcards are not allowed in command arguments
#
# (sudo antigo do Mint aceitava; por isso o bundle passava la e
# abortava no Ubuntu 26.04 sob `set -e`.)
#
# SOLUCAO: expor dois wrappers em /usr/local/bin/ que fazem a
# validacao do share internamente (whitelist via config.env) e
# chamam /bin/mount e /bin/umount com caminhos absolutos. O sudoers
# autoriza apenas os wrappers - sem wildcards, sem argumentos com
# padroes. Funciona identico em qualquer versao de sudo.
#
# Os placeholders VARIAVEL sao substituidos automaticamente
# pelo sistema na geracao do bundle.
# ============================================================================

set -e

source /usr/local/lib/seederlinux/diag.sh 2>/dev/null || true
SCRIPT_ID="19-logon"

echo "============================================================"
echo "Logon minimalista (via autostart)"
echo "============================================================"

# ============================================================
# Variáveis
# ============================================================
SERVIDOR_ARQUIVOS="{{SERVIDOR_ARQUIVOS}}"
COMPARTILHAMENTOS="{{COMPARTILHAMENTOS}}"
MOUNT_BASE="{{MOUNT_BASE}}"
DEFAULT_PRINTER="{{DEFAULT_PRINTER}}"
HOMEPAGE="{{HOMEPAGE}}"
OM_ACRONYM="{{OM_ACRONYM}}"
DOMINIO_NETBIOS="{{DOMINIO_NETBIOS}}"

MOUNT_DIR="${MOUNT_BASE:-/mnt/servidor}"

# ============================================================
# 1. Wrappers de mount/umount
#
# Motivo: sudo 1.9.x+ rejeita wildcards em argumentos. Em vez de
# autorizar /bin/mount -t cifs * e /bin/umount <dir>/* no sudoers,
# autorizamos dois wrappers que:
#   - leem /etc/seederlinux/config.env (fonte de verdade da OM)
#   - validam que o share pedido esta em COMPARTILHAMENTOS
#   - validam que o caminho resolvido fica dentro de MOUNT_BASE
#   - chamam /bin/mount | /bin/umount com caminhos absolutos
#
# Isso da uma superficie de ataque MENOR que a versao anterior com
# wildcards - e funciona em qualquer versao de sudo.
# ============================================================
log_nivel INFO "Criando wrappers de mount/umount (compat sudo 1.9.x+)..."
mkdir -p /usr/local/bin

cat > /usr/local/bin/seederlinux-mount-share <<'MOUNT_WRAPPER'
#!/bin/bash
# seederlinux-mount-share - mount CIFS com whitelist interna.
# Uso: seederlinux-mount-share <share> <servidor> <usuario> <uid> <gid>
#
# Seguranca: valida que <share> esta em COMPARTILHAMENTOS do
# /etc/seederlinux/config.env, que <servidor> nao tem path traversal,
# e que o alvo resolvido fica dentro de MOUNT_BASE. So entao chama
# /bin/mount com caminhos absolutos. NAO aceita flags do usuario.
set -euo pipefail

SHARE="${1:?share obrigatorio}"
SERVER="${2:?servidor obrigatorio}"
RUN_USER="${3:?usuario obrigatorio}"
RUN_UID="${4:?uid obrigatorio}"
RUN_GID="${5:?gid obrigatorio}"

if [ -f /etc/seederlinux/config.env ]; then
    # shellcheck disable=SC1090
    . /etc/seederlinux/config.env
fi

# Whitelist: share precisa estar na lista COMPARTILHAMENTOS.
AUTORIZADO=false
IFS=',' read -ra _shares_arr <<< "${COMPARTILHAMENTOS:-}"
for s in "${_shares_arr[@]}"; do
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    [ -z "$s" ] && continue
    if [ "$s" = "$SHARE" ]; then AUTORIZADO=true; break; fi
done
if [ "$AUTORIZADO" != "true" ]; then
    echo "seederlinux-mount-share: share nao autorizado: $SHARE" >&2
    exit 1
fi

# Server nao pode conter / nem ..
case "$SERVER" in
    */*|*..*)
        echo "seederlinux-mount-share: servidor invalido: $SERVER" >&2
        exit 1
        ;;
esac

MOUNT_BASE_DIR="${MOUNT_BASE:-/mnt/servidor}"
TARGET="${MOUNT_BASE_DIR%/}/${SHARE}"

# Alvo tem que estar dentro de MOUNT_BASE_DIR.
case "$TARGET" in
    "${MOUNT_BASE_DIR%/}"/*) ;;
    *)
        echo "seederlinux-mount-share: target fora de MOUNT_BASE: $TARGET" >&2
        exit 1
        ;;
esac

mkdir -p "$TARGET"

exec /bin/mount -t cifs "//${SERVER}/${SHARE}" "$TARGET" \
    -o "username=${RUN_USER},domain=${DOMINIO_NETBIOS:-},uid=${RUN_UID},gid=${RUN_GID},iocharset=utf8,vers=3.0"
MOUNT_WRAPPER
chmod 0755 /usr/local/bin/seederlinux-mount-share

cat > /usr/local/bin/seederlinux-umount-share <<'UMOUNT_WRAPPER'
#!/bin/bash
# seederlinux-umount-share - umount CIFS com whitelist interna.
# Uso: seederlinux-umount-share <share>
set -euo pipefail

SHARE="${1:?share obrigatorio}"

if [ -f /etc/seederlinux/config.env ]; then
    # shellcheck disable=SC1090
    . /etc/seederlinux/config.env
fi

AUTORIZADO=false
IFS=',' read -ra _shares_arr <<< "${COMPARTILHAMENTOS:-}"
for s in "${_shares_arr[@]}"; do
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    [ -z "$s" ] && continue
    if [ "$s" = "$SHARE" ]; then AUTORIZADO=true; break; fi
done
if [ "$AUTORIZADO" != "true" ]; then
    echo "seederlinux-umount-share: share nao autorizado: $SHARE" >&2
    exit 1
fi

MOUNT_BASE_DIR="${MOUNT_BASE:-/mnt/servidor}"
TARGET="${MOUNT_BASE_DIR%/}/${SHARE}"

case "$TARGET" in
    "${MOUNT_BASE_DIR%/}"/*) ;;
    *)
        echo "seederlinux-umount-share: target fora de MOUNT_BASE: $TARGET" >&2
        exit 1
        ;;
esac

exec /bin/umount "$TARGET"
UMOUNT_WRAPPER
chmod 0755 /usr/local/bin/seederlinux-umount-share

# ============================================================
# 2. sudoers restrito (sem wildcards - compat sudo 1.9.x+)
# ============================================================
log_nivel INFO "Configurando sudoers restrito para logon..."
SUDOERS_FILE="/etc/sudoers.d/seederlinux-logon"
cat > "$SUDOERS_FILE" <<EOF
# SeederLinux - permissoes minimas para o logon do usuario.
# Restrito aos wrappers (que validam share internamente via
# /etc/seederlinux/config.env) e ao disparo do seeder-sync.
#
# NAO usar wildcards aqui: sudo 1.9.x+ (Ubuntu 24.04+) rejeita
# wildcards em argumentos de comando com "syntax error: wildcards
# are not allowed in command arguments". Os wrappers resolvem isso.
Cmnd_Alias SEEDERLINUX_MOUNT  = /usr/local/bin/seederlinux-mount-share
Cmnd_Alias SEEDERLINUX_UMOUNT = /usr/local/bin/seederlinux-umount-share
Cmnd_Alias SEEDERLINUX_SYNC   = /usr/local/bin/seeder-sync
ALL ALL=(root) NOPASSWD: SEEDERLINUX_MOUNT, SEEDERLINUX_UMOUNT, SEEDERLINUX_SYNC
EOF
chmod 440 "$SUDOERS_FILE"
if ! visudo -cf "$SUDOERS_FILE"; then
    log_nivel ERRO "sintaxe invalida no sudoers gerado. Removendo."
    rm -f "$SUDOERS_FILE"
    exit 1
fi
log_nivel INFO "sudoers configurado: $SUDOERS_FILE"

# ============================================================
# 3. Preparar diretorio de log (mundo-gravavel com sticky bit)
# ============================================================
mkdir -p /var/log/logon-logoff
chmod 1777 /var/log/logon-logoff

# ============================================================
# 4. Pre-criar os pontos de montagem (como root, agora, uma vez)
# ============================================================
mkdir -p "$MOUNT_DIR"
if [ -n "$COMPARTILHAMENTOS" ]; then
    IFS=',' read -ra _shares_arr <<< "$COMPARTILHAMENTOS"
    for SHARE in "${_shares_arr[@]}"; do
        SHARE="${SHARE#"${SHARE%%[![:space:]]*}"}"
        SHARE="${SHARE%"${SHARE##*[![:space:]]}"}"
        [ -z "$SHARE" ] && continue
        mkdir -p "${MOUNT_DIR}/${SHARE}"
    done
fi
chmod 755 "$MOUNT_DIR"

# ============================================================
# 5. Criar o script PERMANENTE em /usr/local/bin/seederlinux-logon
#    Sera chamado via autostart XDG a cada login, DENTRO da sessao
#    do usuario (nao mais como hook do display manager).
# ============================================================
log_nivel INFO "Criando script permanente: /usr/local/bin/seederlinux-logon"

cat > /usr/local/bin/seederlinux-logon <<'PERMSCRIPT'
#!/bin/bash
# seederlinux-logon - script MINIMALISTA de logon do SeederLinux.
# Executado via autostart XDG (dentro da sessao do usuario).
# Alvo: menos de 3 segundos. So o que precisa rodar em TODO login.

CONFIG_FILE="/etc/seederlinux/config.env"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
else
    exit 0
fi

USERNAME="${USER:-$(whoami)}"
USER_HOME="${HOME:-/home/$USERNAME}"
LOG_FILE="/var/log/logon-logoff/logon_${USERNAME}.log"

exec >> "$LOG_FILE" 2>&1
echo "=== Logon (minimo): $(date) - Usuario: $USERNAME ==="

# ============================================================
# Diretorios basicos do usuario (idempotente, rapido)
# ============================================================
mkdir -p "$USER_HOME/Desktop" "$USER_HOME/Downloads" "$USER_HOME/Documents" 2>/dev/null || true

# ============================================================
# Montar compartilhamentos CIFS via wrapper com sudo restrito.
# O wrapper (seederlinux-mount-share) valida share/servidor/target
# internamente e chama /bin/mount. Sudoers autoriza apenas o wrapper.
# ============================================================
if [ -n "$SERVIDOR_ARQUIVOS" ] && [ -n "$COMPARTILHAMENTOS" ]; then
    MOUNT_DIR="${MOUNT_BASE:-/mnt/servidor}"
    IFS=',' read -ra _shares_arr <<< "$COMPARTILHAMENTOS"
    for SHARE in "${_shares_arr[@]}"; do
        SHARE="${SHARE#"${SHARE%%[![:space:]]*}"}"
        SHARE="${SHARE%"${SHARE##*[![:space:]]}"}"
        [ -z "$SHARE" ] && continue

        SHARE_MOUNT="${MOUNT_DIR}/${SHARE}"
        if ! mountpoint -q "$SHARE_MOUNT" 2>/dev/null; then
            if sudo -n /usr/local/bin/seederlinux-mount-share \
                    "$SHARE" "$SERVIDOR_ARQUIVOS" "$USERNAME" "$(id -u)" "$(id -g)" \
                    >/dev/null 2>&1; then
                echo "Compartilhamento montado: ${SHARE}"
            else
                echo "AVISO: falha ao montar ${SHARE} (verifique credenciais/sudoers)"
            fi
        fi

        cat > "$USER_HOME/Desktop/${SHARE}.desktop" <<EOF
[Desktop Entry]
Type=Link
Name=${SHARE}
URL=file://${SHARE_MOUNT}
Icon=folder
EOF
        chmod +x "$USER_HOME/Desktop/${SHARE}.desktop" 2>/dev/null || true
    done
fi

# ============================================================
# Impressora padrao (config per-user do CUPS, nao precisa root)
# ============================================================
if [ -n "$DEFAULT_PRINTER" ]; then
    lpoptions -d "$DEFAULT_PRINTER" 2>/dev/null || true
fi

# ============================================================
# Atalho do portal
# ============================================================
if [ -n "$HOMEPAGE" ]; then
    cat > "$USER_HOME/Desktop/Portal-${OM_ACRONYM}.desktop" <<EOF
[Desktop Entry]
Type=Link
Name=Portal ${OM_ACRONYM}
URL=${HOMEPAGE}
Icon=web-browser
EOF
    chmod +x "$USER_HOME/Desktop/Portal-${OM_ACRONYM}.desktop" 2>/dev/null || true
fi

# ============================================================
# Disparar seeder-sync em background, so se o timer ainda nao
# estiver ativo (ex: bundle rodado antes do core_sync.sh, ou timer
# desabilitado manualmente) - nao bloqueia o login esperando.
# ============================================================
if ! systemctl is-active --quiet seeder-sync.timer 2>/dev/null; then
    ( sudo -n /usr/local/bin/seeder-sync >/dev/null 2>&1 & ) 2>/dev/null || true
fi

# ============================================================
# Sincronizar NTP (rapido: timeout 3s, nao bloqueia login).
#
# Motivo: se a estacao ficou desligada por dias, o relogio pode
# estar fora da janela de tolerancia do Kerberos (> 5 min) ate o
# daemon NTP conseguir sincronizar. Forcar uma tentativa rapida
# aqui evita que o usuario tome erro de autenticacao no primeiro
# login apos boot.
#
# O cliente vencedor foi descoberto pelo core_ntp.sh (script 02)
# e persistido em /etc/seederlinux/ntp-state.env.
# ============================================================
if [ -x /usr/local/bin/seederlinux-sync-ntp ]; then
    timeout 3 /usr/local/bin/seederlinux-sync-ntp >/dev/null 2>&1 || true
fi

# ============================================================
# Perfil do Firefox — criar se não existir (Modelo B)
# ============================================================
FIREFOX_DIR="$USER_HOME/.mozilla/firefox"
FIREFOX_PROFILE_DIR="$FIREFOX_DIR/seederlinux.default"
FIREFOX_PROFILES_INI="$FIREFOX_DIR/profiles.ini"

if [ ! -f "$FIREFOX_PROFILES_INI" ]; then
    mkdir -p "$FIREFOX_PROFILE_DIR"
    chmod 700 "$USER_HOME/.mozilla" 2>/dev/null || true
    chmod 700 "$FIREFOX_DIR" 2>/dev/null || true
    chmod 700 "$FIREFOX_PROFILE_DIR" 2>/dev/null || true

    cat > "$FIREFOX_PROFILES_INI" <<EOFINI
[Profile0]
Name=default
IsRelative=1
Path=seederlinux.default
Default=1

[General]
StartWithLastProfile=1
Version=2
EOFINI
    chmod 644 "$FIREFOX_PROFILES_INI"
    echo "Firefox: perfil criado ($FIREFOX_PROFILE_DIR)"
fi

# ============================================================
# Resolver e aplicar proxy do Firefox conforme grupo do AD.
#
# CHROME: sempre usa o proxy padrao (system-wide, aplicado pelo
# core_browser.sh no provisionamento). Nao e tocado aqui.
#
# FIREFOX: aplica o proxy especifico do grupo do usuario em
# ~/.mozilla/firefox/seederlinux.default/user.js. Se o usuario nao
# pertence a nenhum grupo com proxy, limpa o user.js.
# ============================================================
if [ -f /usr/local/lib/seederlinux/resolve-proxy.sh ]; then
    # shellcheck disable=SC1091
    source /usr/local/lib/seederlinux/resolve-proxy.sh

    _proxy_idx="$(_resolver_proxy_index_para_usuario "$USERNAME")" || _proxy_idx=""
    if [ -n "$_proxy_idx" ]; then
        _hostport="$(_proxy_hostport_por_index "$_proxy_idx")"
        _no_proxy="$(_proxy_no_proxy_por_index "$_proxy_idx")"
        _vname="PROXY_${_proxy_idx}_NAME"
        _proxy_name="${!_vname}"

        # Normalizar no_proxy: virgulas, sem espacos, sem *.
        _no_proxy="$(echo "$_no_proxy" | tr ';' ',' | tr -d ' ')"
        _no_proxy="$(echo "$_no_proxy" | sed 's/^\*\././; s/,\*\./,./g')"

        if [ -n "$_hostport" ]; then
            _proxy_host="${_hostport%:*}"
            _proxy_port="${_hostport##*:}"

            _userjs="$FIREFOX_PROFILE_DIR/user.js"
            if [ -d "$FIREFOX_PROFILE_DIR" ]; then
                cat > "$_userjs" <<EOFPREF
// SeederLinux — proxy por grupo do AD
// Proxy: ${_proxy_name}
// Gerado em: $(date -Is)
user_pref("network.proxy.type", 1);
user_pref("network.proxy.http", "${_proxy_host}");
user_pref("network.proxy.http_port", ${_proxy_port});
user_pref("network.proxy.ssl", "${_proxy_host}");
user_pref("network.proxy.ssl_port", ${_proxy_port});
user_pref("network.proxy.no_proxies_on", "${_no_proxy}");
EOFPREF
                chmod 644 "$_userjs"
                echo "Firefox: proxy aplicado (${_proxy_name}) em $_userjs"
            fi
        fi
    else
        # Nenhum proxy aplicável: limpar user.js para não deixar proxy velho
        _userjs="$FIREFOX_PROFILE_DIR/user.js"
        if [ -f "$_userjs" ]; then
            rm -f "$_userjs"
            echo "Firefox: user.js removido (DIRECT)"
        fi
    fi
fi

echo "=== Logon concluido: $(date) ==="
exit 0
PERMSCRIPT

chmod 755 /usr/local/bin/seederlinux-logon
log_nivel INFO "Script permanente criado: /usr/local/bin/seederlinux-logon"

# ============================================================
# 6. Registrar via autostart XDG (funciona em GNOME, Cinnamon, MATE,
#    XFCE, KDE, LXDE/LXQt de forma padronizada - um mecanismo so)
# ============================================================
log_nivel INFO "Registrando autostart..."
mkdir -p /etc/xdg/autostart
cat > /etc/xdg/autostart/seederlinux-logon.desktop <<EOF
[Desktop Entry]
Type=Application
Name=SeederLinux Logon
Comment=Monta compartilhamentos e aplica configuracoes essenciais de logon
Exec=/usr/local/bin/seederlinux-logon
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
X-KDE-autostart-after=panel
EOF

log_nivel OK "Logon minimalista instalado (via autostart)!"
echo "============================================================"
$SeederScript$,
    TRUE,
    TRUE,
    19,
    ARRAY['core_domain.sh']::TEXT[],
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    depends_on = EXCLUDED.depends_on,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Troca de Senha AD (ordem 20) - core_password_change.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, depends_on, version, organization_id)
VALUES (
    'Troca de Senha AD',
    'core_password_change.sh',
    'Configura a alteracao de senha do usuario no dominio.',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_password_change.sh
# SeederLinux Lite - Troca de Senha do Active Directory
# ============================================================================
# Instala um aplicativo gráfico (Zenity) para troca de senha no AD.
# É executado pelo bundle para instalar o script; a troca de senha
# em si é feita pelo usuário quando desejar.
# ============================================================================

(
set -e

source /usr/local/lib/seederlinux/diag.sh 2>/dev/null || true
SCRIPT_ID="20-password-change"

echo "============================================================"
echo "Instalar aplicativo de troca de senha AD"
echo "============================================================"

INSTALL_PASSWORD_CHANGER="{{INSTALL_PASSWORD_CHANGER}}"

if [ "$INSTALL_PASSWORD_CHANGER" != "true" ]; then
    log_nivel INFO "Instalacao do trocador de senha desativada. Pulando."
    log_nivel INFO "[16] Trocador de senha ignorado."
    echo "============================================================"
    exit 0
fi

DOMINIO="{{DOMINIO}}"
OM_ACRONYM="{{OM_ACRONYM}}"

log_nivel INFO "Instalando aplicativo de troca de senha..."

# Criar o script de troca de senha
cat > /usr/local/bin/trocar-senha << 'EOFSCRIPT'
#!/bin/bash
# ============================================================================
# Troca de Senha - Active Directory
# Interface gráfica com Zenity para alteração de senha no domínio
# ============================================================================

DOMINIO="{{DOMINIO}}"
OM_ACRONYM="{{OM_ACRONYM}}"

trocar_senha() {
    IFS='|' read -r OldPasswd NewPasswd1 NewPasswd2 <<< \
    $(zenity --forms --title="Trocar Senha do Usuário" \
        --text="Usuário: $USER\nDomínio: $DOMINIO" \
        --add-password="Senha atual" \
        --add-password="Nova Senha" \
        --add-password="Confirme a nova senha" \
        --width=450 \
        --height=250)

    if [ -z "$OldPasswd" ] || [ -z "$NewPasswd1" ]; then
        zenity --error --title="Erro" --text="Todos os campos devem ser preenchidos."
        return 1
    fi

    while [ "$NewPasswd1" != "$NewPasswd2" ]; do
        NewPasswd1=$(zenity --entry \
            --title="Trocar Senha" \
            --text="As senhas não coincidem!\n\nDigite a nova senha:" \
            --hide-text \
            --width=400)

        if [ -z "$NewPasswd1" ]; then
            zenity --error --title="Erro" --text="Operação cancelada."
            return 1
        fi

        NewPasswd2=$(zenity --entry \
            --title="Trocar Senha" \
            --text="Confirme a nova senha:" \
            --hide-text \
            --width=400)
    done

    if [ ${#NewPasswd1} -lt 7 ]; then
        zenity --error \
            --title="Senha muito curta" \
            --text="A nova senha deve ter no mínimo 7 caracteres.\n\nRequisitos do Active Directory:\n• Mínimo 7 caracteres\n• Pelo menos 3 dos 4 tipos:\n  - Maiúsculas (A-Z)\n  - Minúsculas (a-z)\n  - Números (0-9)\n  - Símbolos (@#\$% etc)"
        return 1
    fi

    DC_ONLINE=""
    for DC in $(host -t SRV _ldap._tcp.$DOMINIO 2>/dev/null | awk '{print $NF}' | sed 's/\.$//'); do
        if ping -c 1 -W 2 "$DC" > /dev/null 2>&1; then
            DC_ONLINE="$DC"
            break
        fi
    done

    if [ -z "$DC_ONLINE" ]; then
        DC_ONLINE="dc-${OM_ACRONYM,,}.$DOMINIO"
    fi

    echo -e "$OldPasswd\n$NewPasswd1\n$NewPasswd1" | smbpasswd -r "$DC_ONLINE" -U "$USER" > /tmp/password-change.log 2>&1

    if grep -q "Password changed" /tmp/password-change.log; then
        zenity --info \
            --title="Sucesso" \
            --text="Senha alterada com sucesso!\n\nA nova senha entrará em vigor imediatamente.\nRecomenda-se fazer logoff e login novamente." \
            --width=400
        rm -f /tmp/password-change.log
        return 0
    else
        ERRO=$(cat /tmp/password-change.log 2>/dev/null | tail -5)
        zenity --error \
            --title="Erro ao trocar senha" \
            --text="Não foi possível alterar a senha.\n\nMotivos possíveis:\n• Senha atual incorreta\n• Senha nova não atende aos requisitos\n• Controlador de domínio indisponível\n\nDetalhes técnicos:\n$ERRO" \
            --width=500
        rm -f /tmp/password-change.log
        return 1
    fi
}

if ! command -v zenity &>/dev/null; then
    echo "Erro: zenity não está instalado."
    echo "Execute: sudo apt-get install -y zenity"
    exit 1
fi

if ! command -v smbpasswd &>/dev/null; then
    echo "Erro: smbpasswd não está instalado."
    echo "Execute: sudo apt-get install -y samba-common-bin"
    exit 1
fi

trocar_senha

exit $?
EOFSCRIPT

chmod 755 /usr/local/bin/trocar-senha
log_nivel INFO "Script de troca de senha instalado em /usr/local/bin/trocar-senha"

# Criar entrada no menu de aplicativos
cat > /usr/share/applications/trocar-senha.desktop << EOF
[Desktop Entry]
Version=1.0
Name=Trocar Senha
Name[pt_BR]=Trocar Senha
Comment=Alterar senha do Active Directory
Comment[pt_BR]=Alterar senha do Active Directory
Exec=/usr/local/bin/trocar-senha
Icon=dialog-password
Terminal=false
Type=Application
Categories=System;Settings;
StartupNotify=true
EOF

log_nivel INFO "Atalho no menu criado"

# Criar atalho na área de trabalho (todos os usuários futuros via /etc/skel)
if [ -d /etc/skel ]; then
    mkdir -p /etc/skel/Desktop
    cp /usr/share/applications/trocar-senha.desktop /etc/skel/Desktop/
    chmod +x /etc/skel/Desktop/trocar-senha.desktop 2>/dev/null || true
fi

# Criar atalho para usuários existentes com diretório home em /home
for USER_HOME in /home/*/; do
    if [ -d "${USER_HOME}Desktop" ]; then
        cp /usr/share/applications/trocar-senha.desktop "${USER_HOME}Desktop/"
        chmod +x "${USER_HOME}Desktop/trocar-senha.desktop" 2>/dev/null || true
    fi
done

log_nivel INFO "Atalhos na area de trabalho criados"
log_nivel OK "Aplicativo de troca de senha instalado!"
echo "============================================================"
)
$SeederScript$,
    TRUE,
    TRUE,
    20,
    ARRAY['core_domain.sh']::TEXT[],
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    depends_on = EXCLUDED.depends_on,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Logoff Persistente (ordem 21) - core_logoff.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, depends_on, version, organization_id)
VALUES (
    'Logoff Persistente',
    'core_logoff.sh',
    'Script executado a cada logoff de usuario.',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_logoff.sh
# SeederLinux Lite - Logoff MINIMALISTA
# ============================================================================
# Ao contrario do logon, o logoff CONTINUA sendo chamado pelo display
# manager (session-cleanup-script no LightDM / PostSession no GDM3 /
# Xstop no SDDM) - roda como root. Isso e adequado aqui: desmontar
# compartilhamentos e matar processos por usuario nao depende de D-Bus
# de sessao, e precisa de privilegio de root de qualquer forma.
#
# CORRECAO: a versao anterior confiava em `$USER`/`whoami` para saber
# de quem e a sessao que esta terminando. Nesses hooks de DM (rodando
# como root, ANTES/DURANTE o encerramento da sessao), $USER nao e
# garantidamente o usuario que esta saindo - pode nao estar setado,
# ou apontar pra root. Agora a resolucao do usuario segue uma cascata:
#   1) $1 (primeiro argumento - e como LightDM/GDM3 normalmente
#      informam o usuario da sessao para esses hooks)
#   2) $PAM_USER (presente se invocado via pam_exec em algum fluxo)
#   3) loginctl - sessao grafica mais recente
#   4) $USER como ultimo recurso
#
# ESCOPO REDUZIDO (minimalista): so desmonta, limpa cache/lixeira/
# temporarios e mata processos do usuario (Conky, x11vnc). Nao aplica
# nenhuma configuracao - isso e trabalho do core_sync.sh.
#
# Os placeholders VARIAVEL sao substituidos automaticamente
# pelo sistema na geracao do bundle.
# ============================================================================

set -e

source /usr/local/lib/seederlinux/diag.sh 2>/dev/null || true
SCRIPT_ID="21-logoff"

echo "============================================================"
echo "Logoff minimalista"
echo "============================================================"

# ============================================================
# Variaveis (substituidas no bundle)
# ============================================================
DOMINIO_NETBIOS="{{DOMINIO_NETBIOS}}"
SERVIDOR_ARQUIVOS="{{SERVIDOR_ARQUIVOS}}"
COMPARTILHAMENTOS="{{COMPARTILHAMENTOS}}"
MOUNT_BASE="{{MOUNT_BASE}}"

# ============================================================
# 1. Criar o script PERMANENTE em /usr/local/bin/seederlinux-logoff
# ============================================================
log_nivel INFO "Criando script permanente: /usr/local/bin/seederlinux-logoff"

cat > /usr/local/bin/seederlinux-logoff <<'PERMSCRIPT'
#!/bin/bash
# seederlinux-logoff - script MINIMALISTA de logoff do SeederLinux.
# Chamado pelo display manager (root) a cada logoff.

CONFIG_FILE="/etc/seederlinux/config.env"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

# ============================================================
# Resolver o usuario que esta saindo - nao confiar so em $USER
# ============================================================
USERNAME="${1:-}"
[ -z "$USERNAME" ] && USERNAME="${PAM_USER:-}"
if [ -z "$USERNAME" ] || [ "$USERNAME" = "root" ]; then
    # Fallback: sessao grafica mais recente via loginctl
    USERNAME="$(loginctl list-sessions --no-legend 2>/dev/null \
                | awk '{print $3}' | grep -v '^root$' | tail -n1)"
fi
[ -z "$USERNAME" ] && USERNAME="${USER:-}"

if [ -z "$USERNAME" ] || [ "$USERNAME" = "root" ]; then
    echo ">>> [logoff] AVISO: nao foi possivel determinar o usuario da sessao. Abortando limpeza."
    exit 0
fi

USER_HOME="$(getent passwd "$USERNAME" | cut -d: -f6)"
[ -z "$USER_HOME" ] && USER_HOME="/home/$USERNAME"

LOG_DIR="/var/log/logon-logoff"
LOG_FILE="$LOG_DIR/logoff_${USERNAME}.log"
mkdir -p "$LOG_DIR"

exec >> "$LOG_FILE" 2>&1
echo "=== Logoff (minimo): $(date) - Usuario: $USERNAME ==="

# ============================================================
# Desmontar compartilhamentos CIFS do usuario
# ============================================================
if [ -n "$COMPARTILHAMENTOS" ]; then
    MOUNT_DIR="${MOUNT_BASE:-/mnt/servidor}"
    IFS=',' read -ra _shares_arr <<< "$COMPARTILHAMENTOS"
    for SHARE in "${_shares_arr[@]}"; do
        SHARE="${SHARE#"${SHARE%%[![:space:]]*}"}"
        SHARE="${SHARE%"${SHARE##*[![:space:]]}"}"
        [ -z "$SHARE" ] && continue

        SHARE_MOUNT="${MOUNT_DIR}/${SHARE}"
        if mountpoint -q "$SHARE_MOUNT" 2>/dev/null; then
            umount "$SHARE_MOUNT" 2>/dev/null || umount -l "$SHARE_MOUNT" 2>/dev/null || {
                echo ">>> [logoff] AVISO: falha ao desmontar ${SHARE_MOUNT}"
            }
            echo ">>> [logoff] Compartilhamento desmontado: ${SHARE}"
        fi
    done
fi

# ============================================================
# Limpar cache de navegadores
# ============================================================
rm -rf "$USER_HOME/.cache/mozilla" 2>/dev/null || true
rm -rf "$USER_HOME/.cache/google-chrome" 2>/dev/null || true
rm -rf "$USER_HOME/.cache/chromium" 2>/dev/null || true
rm -rf "$USER_HOME/.cache/thumbnails" 2>/dev/null || true

# ============================================================
# Esvaziar lixeira
# ============================================================
rm -rf "${USER_HOME:?}/.local/share/Trash"/* 2>/dev/null || true

# ============================================================
# Remover temporarios do usuario (mais de 60min)
# ============================================================
find /tmp -user "$USERNAME" -type f -mmin +60 -delete 2>/dev/null || true

# ============================================================
# Remover atalhos de compartilhamentos (evita atalho morto se o
# mapeamento mudar antes do proximo login)
# ============================================================
if [ -n "$COMPARTILHAMENTOS" ]; then
    IFS=',' read -ra _shares_arr <<< "$COMPARTILHAMENTOS"
    for SHARE in "${_shares_arr[@]}"; do
        SHARE="${SHARE#"${SHARE%%[![:space:]]*}"}"
        SHARE="${SHARE%"${SHARE##*[![:space:]]}"}"
        [ -z "$SHARE" ] && continue
        rm -f "$USER_HOME/Desktop/${SHARE}.desktop" 2>/dev/null || true
    done
fi

# ============================================================
# Finalizar processos do usuario (Conky, x11vnc)
# ============================================================
killall -u "$USERNAME" conky 2>/dev/null || true
killall -u "$USERNAME" x11vnc 2>/dev/null || true

# ============================================================
# Rotacionar logs (manter 7 dias)
# ============================================================
find "$LOG_DIR" -name "logoff_*.log" -mtime +7 -delete 2>/dev/null || true
find "$LOG_DIR" -name "logon_*.log" -mtime +7 -delete 2>/dev/null || true

echo "=== Logoff concluido: $(date) ==="
exit 0
PERMSCRIPT

chmod 755 /usr/local/bin/seederlinux-logoff
log_nivel INFO "Script permanente criado: /usr/local/bin/seederlinux-logoff"
log_nivel OK "Logoff minimalista instalado!"
echo "============================================================"
$SeederScript$,
    TRUE,
    TRUE,
    21,
    ARRAY['core_domain.sh']::TEXT[],
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    depends_on = EXCLUDED.depends_on,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Proxy de CLI (ordem 22) - core_proxy.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, depends_on, version, organization_id)
VALUES (
    'Proxy de CLI',
    'core_proxy.sh',
    'Configura proxy corporativo no sistema (apt, curl, wget, env).',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_proxy.sh
# SeederLinux Lite - Proxy de CLI (wget/curl/git do usuário)
# ============================================================================
# Configura /etc/environment com as variáveis de proxy que afetam
# ferramentas de linha de comando. NÃO configura browsers (isso é
# responsabilidade de core_browser.sh) NEM apt (responsabilidade de
# core_repositories.sh).
#
# POLÍTICAS SUPORTADAS (CLI_POLICY):
#   DIRECT          -> sem proxy, limpa /etc/environment (default)
#   PROXY_NO_AUTH   -> via proxy sem autenticação
#   PROXY_WITH_AUTH -> via proxy com user/senha
#   PAC             -> NÃO SUPORTADO por wget/curl/git; cai pra DIRECT
#                      com aviso (PAC só faz sentido pra browsers, que
#                      são configurados no core_browser.sh)
#
# MÚLTIPLOS PROXIES:
#   A OM pode ter 0..N proxies nomeados. CLI_PROXY_NAME aponta para um
#   deles; se vazio, usa PROXY_DEFAULT_NAME.
#
# IMPORTANTE - NÃO DERRUBA SESSÃO:
#   Este script só escreve em /etc/environment e nos arquivos de config
#   dos proxies. NÃO reinicia serviços de sessão, NÃO toca em
#   /etc/apt/apt.conf.d, NÃO mexe em DNS. Roda com segurança em estações
#   já em uso.
#
# Os placeholders VARIAVEL são substituídos automaticamente
# pelo sistema na geração do bundle.
# ============================================================================

set -e

source /usr/local/lib/seederlinux/diag.sh 2>/dev/null || true
SCRIPT_ID="22-proxy"

echo "============================================================"
echo "Configurar proxy de CLI"
echo "============================================================"

# ============================================================
# Variáveis (substituídas no bundle)
# ============================================================
CLI_POLICY="{{CLI_POLICY}}"
CLI_PROXY_NAME="{{CLI_PROXY_NAME}}"
SEEDER_SERVER="{{SEEDER_SERVER}}"
DC_IP="{{DC_IP}}"
DC_IP_LIST="{{DC_IP_LIST}}"
DOMINIO="{{DOMINIO}}"

# Múltiplos proxies (dinâmicos, vem do header do bundle)
PROXY_COUNT="${PROXY_COUNT:-0}"
PROXY_DEFAULT_NAME="${PROXY_DEFAULT_NAME:-}"

# Defaults defensivos
[ -z "$CLI_POLICY" ] && CLI_POLICY="DIRECT"
SEEDER_SERVER="${SEEDER_SERVER%/}"

log_nivel INFO "CLI_POLICY: $CLI_POLICY"
log_nivel INFO "CLI_PROXY_NAME: ${CLI_PROXY_NAME:-<default>}"
log_nivel INFO "Proxies cadastrados: $PROXY_COUNT"

# ============================================================
# Helper: resolver proxy por nome -> URL com user:pass
# ============================================================
_resolver_proxy_url() {
    local name="$1"
    [ -z "$name" ] && return 1
    [ "$PROXY_COUNT" -lt 1 ] 2>/dev/null && return 1

    local i=1
    while [ "$i" -le "$PROXY_COUNT" ]; do
        local v_name="PROXY_${i}_NAME"
        if [ "${!v_name}" = "$name" ]; then
            local v_url="PROXY_${i}_URL"
            local v_user="PROXY_${i}_USER"
            local v_pass_b64="PROXY_${i}_PASS_B64"
            local url="${!v_url}"
            local user="${!v_user}"
            local pass_b64="${!v_pass_b64}"

            [ -z "$url" ] && return 1
            [ -z "$user" ] && { echo "$url"; return 0; }

            local pass=""
            if [ -n "$pass_b64" ]; then
                pass="$(printf '%s' "$pass_b64" | base64 -d 2>/dev/null)" || pass=""
            fi

            local user_esc="${user//@/%40}"
            user_esc="${user_esc//:/%3A}"
            local pass_esc="${pass//@/%40}"
            pass_esc="${pass_esc//:/%3A}"

            if echo "$url" | grep -qE '^https?://'; then
                echo "$url" | sed -E "s|^(https?://)|\1${user_esc}:${pass_esc}@|"
            else
                echo "http://${user_esc}:${pass_esc}@${url}"
            fi
            return 0
        fi
        i=$((i+1))
    done
    return 1
}

# ============================================================
# Helper: NO_PROXY específico de um proxy
# ============================================================
_resolver_proxy_no_proxy() {
    local name="$1"
    [ -z "$name" ] && return 1
    [ "$PROXY_COUNT" -lt 1 ] 2>/dev/null && return 1

    local i=1
    while [ "$i" -le "$PROXY_COUNT" ]; do
        local v_name="PROXY_${i}_NAME"
        if [ "${!v_name}" = "$name" ]; then
            local v="PROXY_${i}_NO_PROXY"
            echo "${!v}"
            return 0
        fi
        i=$((i+1))
    done
    return 1
}

# ============================================================
# Helper: nome efetivo do proxy
# ============================================================
_resolver_proxy_nome_efetivo() {
    if [ -n "$CLI_PROXY_NAME" ]; then
        echo "$CLI_PROXY_NAME"
    else
        echo "$PROXY_DEFAULT_NAME"
    fi
}

# ============================================================
# Helper: montar NO_PROXY final
# ============================================================
_build_no_proxy() {
    local extra="$1"
    local base="localhost,127.0.0.1"

    if [ -n "$SEEDER_SERVER" ]; then
        local host
        host="$(echo "$SEEDER_SERVER" | sed -E 's|https?://([^/]+).*|\1|')"
        if [ -n "$host" ]; then
            base="${base},${host}"
            local ip
            ip="$(getent hosts "$host" 2>/dev/null | awk '{print $1}' | head -1)"
            [ -n "$ip" ] && base="${base},${ip}"
        fi
    fi

    if [ -n "$DOMINIO" ]; then
        base="${base},.${DOMINIO}"
    fi

    if [ -n "$DC_IP" ]; then
        case ",$base," in
            *",$DC_IP,"*) ;;
            *) base="${base},${DC_IP}" ;;
        esac
    fi

    if [ -n "$DC_IP_LIST" ]; then
        local dc
        for dc in $(echo "$DC_IP_LIST" | tr ',' ' '); do
            [ -z "$dc" ] && continue
            case ",$base," in
                *",$dc,"*) ;;
                *) base="${base},${dc}" ;;
            esac
        done
    fi

    if [ -n "$extra" ]; then
        base="${base},${extra}"
    fi

    # Normalizar: painel guarda "a;b; *.dom" — wget/curl/git
    # esperam virgula e sem "*".
    base="$(echo "$base" | tr ';' ',' | tr -d ' ')"
    base="$(echo "$base" | sed 's/^\*\././; s/,\*\./,./g')"

    echo "$base"
}

# ============================================================
# Helper: escrever proxy em /etc/environment
# ============================================================
_escrever_environment_proxy() {
    local url="$1"
    local no_proxy="$2"

    touch /etc/environment

    sed -i '/^http_proxy=/d;/^https_proxy=/d;/^ftp_proxy=/d;/^no_proxy=/d' /etc/environment 2>/dev/null || true
    sed -i '/^HTTP_PROXY=/d;/^HTTPS_PROXY=/d;/^FTP_PROXY=/d;/^NO_PROXY=/d' /etc/environment 2>/dev/null || true
    sed -i '/^all_proxy=/d;/^ALL_PROXY=/d' /etc/environment 2>/dev/null || true
    sed -i '/^# Proxy configurado por SeederLinux/d' /etc/environment 2>/dev/null || true

    {
        echo ""
        echo "# Proxy configurado por SeederLinux (core_proxy.sh)"
        echo "http_proxy=\"${url}\""
        echo "https_proxy=\"${url}\""
        echo "ftp_proxy=\"${url}\""
        echo "HTTP_PROXY=\"${url}\""
        echo "HTTPS_PROXY=\"${url}\""
        echo "FTP_PROXY=\"${url}\""
        if [ -n "$no_proxy" ]; then
            echo "no_proxy=\"${no_proxy}\""
            echo "NO_PROXY=\"${no_proxy}\""
        fi
    } >> /etc/environment

    chmod 644 /etc/environment

    log_nivel INFO "/etc/environment atualizado"
    log_nivel INFO "http_proxy=${url}"
    log_nivel INFO "no_proxy=${no_proxy}"
}

# ============================================================
# Helper: limpar proxy de /etc/environment
# ============================================================
_limpar_environment_proxy() {
    if [ -f /etc/environment ]; then
        sed -i '/^http_proxy=/d;/^https_proxy=/d;/^ftp_proxy=/d;/^no_proxy=/d' /etc/environment 2>/dev/null || true
        sed -i '/^HTTP_PROXY=/d;/^HTTPS_PROXY=/d;/^FTP_PROXY=/d;/^NO_PROXY=/d' /etc/environment 2>/dev/null || true
        sed -i '/^all_proxy=/d;/^ALL_PROXY=/d' /etc/environment 2>/dev/null || true
        sed -i '/^# Proxy configurado por SeederLinux/d' /etc/environment 2>/dev/null || true
        log_nivel INFO "/etc/environment limpo (sem proxy)"
    fi
}

# ============================================================
# Aplicar CLI_POLICY
# ============================================================
case "$CLI_POLICY" in

    DIRECT|"")
        log_nivel INFO "Policy: DIRECT - sem proxy para CLI."
        _limpar_environment_proxy
        ;;

    PROXY|PROXY_NO_AUTH|PROXY_WITH_AUTH)
        NOME_EFETIVO="$(_resolver_proxy_nome_efetivo)"
        if [ -z "$NOME_EFETIVO" ]; then
            log_nivel ERRO "CLI_POLICY=$CLI_POLICY mas nenhum proxy configurado."
            log_nivel INFO "Configurando CLI como DIRECT para nao travar o bundle."
            _limpar_environment_proxy
        else
            URL="$(_resolver_proxy_url "$NOME_EFETIVO")" || URL=""
            if [ -z "$URL" ]; then
                log_nivel ERRO "proxy '$NOME_EFETIVO' nao encontrado na lista de proxies da OM."
                log_nivel INFO "Configurando CLI como DIRECT para nao travar o bundle."
                _limpar_environment_proxy
            else
                NO_PROXY_ESPECIFICO="$(_resolver_proxy_no_proxy "$NOME_EFETIVO")" || NO_PROXY_ESPECIFICO=""
                NO_PROXY_FINAL="$(_build_no_proxy "$NO_PROXY_ESPECIFICO")"
                _escrever_environment_proxy "$URL" "$NO_PROXY_FINAL"
            fi
        fi
        ;;

    PAC)
        log_nivel AVISO "PAC nao e suportado por wget/curl/git."
        log_nivel INFO "Ferramentas de CLI so entendem proxy explicito, nao PAC."
        log_nivel INFO "Para browsers (que suportam PAC), configure BROWSER_POLICY=PAC."
        log_nivel INFO "Aplicando DIRECT para CLI."
        _limpar_environment_proxy
        ;;

    *)
        log_nivel AVISO "CLI_POLICY desconhecida '$CLI_POLICY'. Tratando como DIRECT."
        _limpar_environment_proxy
        ;;
esac

log_nivel OK "Proxy de CLI configurado!"

# ============================================================
# Gerar resolve-proxy.sh — funções compartilhadas para
# core_logon.sh e seeder-sync resolverem o proxy por grupo do AD.
# ============================================================
log_nivel INFO "Gerando /usr/local/lib/seederlinux/resolve-proxy.sh..."
mkdir -p /usr/local/lib/seederlinux
cat > /usr/local/lib/seederlinux/resolve-proxy.sh <<'RESOLVE_EOF'
# resolve-proxy.sh — cascata de decisão de proxy para o Firefox.
# Carregado via source pelo core_logon.sh e pelo seeder-sync.
#
# Requer: PROXY_COUNT, PROXY_DEFAULT_NAME, PROXY_N_NAME, PROXY_N_URL,
#         PROXY_N_AD_GROUP, PROXY_N_NO_PROXY (definidos no ambiente).
#
# Regra especial: AD_GROUP="Domain Users" (case-insensitive) é tratado
# como vazio — todo usuário do domínio pertence a esse grupo, então ele
# não serve como critério de match.

# _proxy_grupo_eh_domain_users <valor>
_proxy_grupo_eh_domain_users() {
    local g="$1"
    [ -z "$g" ] && return 1
    g="$(echo "$g" | tr -d ' ' | tr '[:upper:]' '[:lower:]')"
    [ "$g" = "domainusers" ] || [ "$g" = "domain users" ]
}

# _resolver_proxy_index_para_usuario <usuario>
# Cascata: grupo-específico → default → catch-all → DIRECT
_resolver_proxy_index_para_usuario() {
    local user="$1"
    [ -z "$user" ] && return 1

    local grupos
    grupos="$(id -nG "$user" 2>/dev/null)" || return 1

    # ESTÁGIO 1: proxy com AD_GROUP definido (e não Domain Users) que casa
    local i=1
    while [ "$i" -le "${PROXY_COUNT:-0}" ]; do
        local vg="PROXY_${i}_AD_GROUP"
        local g="${!vg}"
        if [ -n "$g" ] && ! _proxy_grupo_eh_domain_users "$g"; then
            if echo "$grupos" | tr ' ' '\n' | grep -qxF "$g"; then
                echo "$i"
                return 0
            fi
        fi
        i=$((i+1))
    done

    # ESTÁGIO 2: PROXY_DEFAULT_NAME
    if [ -n "${PROXY_DEFAULT_NAME:-}" ]; then
        i=1
        while [ "$i" -le "${PROXY_COUNT:-0}" ]; do
            local vn="PROXY_${i}_NAME"
            if [ "${!vn}" = "$PROXY_DEFAULT_NAME" ]; then
                echo "$i"
                return 0
            fi
            i=$((i+1))
        done
    fi

    # ESTÁGIO 3: primeiro proxy com AD_GROUP vazio OU Domain Users
    i=1
    while [ "$i" -le "${PROXY_COUNT:-0}" ]; do
        local vg="PROXY_${i}_AD_GROUP"
        local g="${!vg}"
        if [ -z "$g" ] || _proxy_grupo_eh_domain_users "$g"; then
            echo "$i"
            return 0
        fi
        i=$((i+1))
    done

    return 1
}

_proxy_hostport_por_index() {
    local i="$1"
    local vu="PROXY_${i}_URL"
    echo "${!vu}" | sed -E 's|^https?://||' | sed 's|/$||'
}

_proxy_no_proxy_por_index() {
    local i="$1"
    local v="PROXY_${i}_NO_PROXY"
    echo "${!v}"
}

_proxy_name_por_index() {
    local i="$1"
    local v="PROXY_${i}_NAME"
    echo "${!v}"
}
RESOLVE_EOF
chmod 644 /usr/local/lib/seederlinux/resolve-proxy.sh
log_nivel INFO "resolve-proxy.sh gerado."

echo "============================================================"
$SeederScript$,
    TRUE,
    TRUE,
    22,
    ARRAY['core_domain.sh']::TEXT[],
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    depends_on = EXCLUDED.depends_on,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Agente SeederLinux (ordem 23) - core_agent.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, depends_on, version, organization_id)
VALUES (
    'Agente SeederLinux',
    'core_agent.sh',
    'Instala e configura o agente SeederLinux.',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_agent.sh
# SeederLinux Lite - Instalacao do agente de check-in periodico
# ============================================================================
# Baixa o agent.py do servidor, configura cron a cada 15 minutos e
# executa o primeiro check-in em background.
#
# IMPORTANTE - NAO USA PROXY:
#   O wget que baixa o agent.py aponta para o proprio SEEDER_SERVER,
#   que esta sempre no NO_PROXY corporativo. Como wget NAO respeita
#   wildcards no no_proxy (ex: "*.intraer"), usamos --no-proxy
#   explicito para garantir conexao direta, independente do estado
#   do /etc/environment da estacao.
#
#   Isso e' seguro: o unico destino deste wget e' o Seeder, que por
#   design nao deve passar por proxy nenhum.
#
# AGRESSIVIDADE DO --no-proxy:
#   NAO afeta outros wgets do sistema nem usuarios. E' flag pontual
#   deste comando. Nao mexe em /etc/environment.
#
# Os placeholders VARIAVEL sao substituidos automaticamente
# pelo sistema na geracao do bundle.
# ============================================================================

(
set -e

source /usr/local/lib/seederlinux/diag.sh 2>/dev/null || true
SCRIPT_ID="23-agent"

echo "============================================================"
echo "Instalar agente de check-in (seeder-agent)"
echo "============================================================"

INSTALL_AGENT="{{INSTALL_AGENT}}"
if [ "$INSTALL_AGENT" != "true" ]; then
    log_nivel INFO "Instalacao do agente desativada (INSTALL_AGENT=false). Pulando."
    echo "============================================================"
    exit 0
fi

SEEDER_SERVER="{{SEEDER_SERVER}}"
OM_ACRONYM="{{OM_ACRONYM}}"
AGENT_NO_CHECK_CERT="{{AGENT_NO_CHECK_CERT}}"

SEEDER_SERVER="${SEEDER_SERVER%/}"

log_nivel INFO "Servidor: $SEEDER_SERVER"
log_nivel INFO "Organizacao: $OM_ACRONYM"
log_nivel INFO "Ignorar cert SSL: $AGENT_NO_CHECK_CERT"

# ============================================================
# Montar flag do certificado
# ============================================================
CERT_FLAG=""
if [ "$AGENT_NO_CHECK_CERT" = "true" ]; then
    CERT_FLAG="--no-check-certificate"
fi

# ============================================================
# Baixar o agente
# ============================================================
# --no-proxy e' obrigatorio: o Seeder esta sempre no NO_PROXY, mas
# wget nao respeita wildcards. Sem isso, se o /etc/environment
# tiver http_proxy configurado (por OM com proxy de CLI), o wget
# tenta passar pelo proxy e recebe 407.

log_nivel INFO "Baixando agente de ${SEEDER_SERVER}/downloads/agent.py ..."
mkdir -p /usr/local/bin

AGENT_URL="${SEEDER_SERVER}/downloads/agent.py"
AGENT_TMP="/tmp/seeder-agent-download.$$"

if wget -q --no-check-certificate --no-proxy --timeout=30 -O "$AGENT_TMP" "$AGENT_URL"; then
    if [ ! -s "$AGENT_TMP" ]; then
        log_nivel ERRO "Agente baixado mas arquivo esta vazio. Verifique $AGENT_URL"
        rm -f "$AGENT_TMP"
        echo "============================================================"
        exit 1
    fi
    install -m 0755 "$AGENT_TMP" /usr/local/bin/seeder-agent
    rm -f "$AGENT_TMP"
    log_nivel INFO "Agente instalado em /usr/local/bin/seeder-agent"

    # Sanity check: verifica que o arquivo tem o cabecalho esperado
    if ! head -5 /usr/local/bin/seeder-agent | grep -q "SeederLinux"; then
        log_nivel AVISO "agente baixado nao parece ser o esperado."
        log_nivel INFO "Primeiras linhas:"
        head -3 /usr/local/bin/seeder-agent | sed 's/^/    /'
    fi
else
    log_nivel ERRO "Falha ao baixar o agente de $AGENT_URL"
    log_nivel INFO "Verifique conectividade L3 com o Seeder."
    rm -f "$AGENT_TMP"
    echo "============================================================"
    exit 1
fi

# ============================================================
# Criar configuracao
# ============================================================
mkdir -p /etc/seeder
cat > /etc/seeder/agent.conf <<EOF
[server]
url = ${SEEDER_SERVER}
no_check_certificate = ${AGENT_NO_CHECK_CERT}
EOF
chmod 644 /etc/seeder/agent.conf

# ============================================================
# Configurar cron
# ============================================================
# O agente se auto-protege contra proxy (remove variaveis do proprio
# processo antes de fazer requests). Nao precisa de env -i nem de
# wrapper. O cron chama direto.
cat > /etc/cron.d/seeder-agent <<EOF
# SeederLinux Agent - check-in a cada 15 minutos
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/15 * * * * root /usr/local/bin/seeder-agent --no-check-certificate >> /var/log/seeder/agent.log 2>&1
EOF
chmod 644 /etc/cron.d/seeder-agent

log_nivel INFO "Cron configurado: /etc/cron.d/seeder-agent"

# ============================================================
# Primeiro check-in (em background, sem bloquear o bundle)
# ============================================================
log_nivel INFO "Executando primeiro check-in em background..."
mkdir -p /var/log/seeder
nohup /usr/local/bin/seeder-agent --org "$OM_ACRONYM" --no-check-certificate \
    > /tmp/seeder-first-checkin.log 2>&1 &

log_nivel OK "Agente instalado e agendado!"
echo "============================================================"
)
$SeederScript$,
    TRUE,
    TRUE,
    23,
    ARRAY['core_proxy.sh']::TEXT[],
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    depends_on = EXCLUDED.depends_on,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Aplicador de Politicas (seeder-sync) (ordem 24) - core_sync.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, depends_on, version, organization_id)
VALUES (
    'Aplicador de Politicas (seeder-sync)',
    'core_sync.sh',
    'Instala o seeder-sync e um timer systemd (10 em 10 minutos) que reaplica de forma idempotente toda a configuracao corporativa da OM (estilo GPO).',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_sync.sh
# SeederLinux Lite - seeder-sync: aplicador de politicas (estilo GPO)
# ============================================================================
# Instala /usr/local/bin/seeder-sync + timer systemd (10 em 10 minutos),
# responsavel por REAPLICAR de forma idempotente toda a configuracao
# corporativa da OM (branding, politicas de navegador, proxy de CLI,
# impressoras, Conky, compartilhamentos), independente de login/logoff.
#
# MODELO MULTI-PROXY:
#   Le as 3 politicas (APT/CLI/BROWSER) do config.env. Reaplica CLI_POLICY
#   em /etc/environment e BROWSER_POLICY em policies.json. APT_POLICY nao
#   e reaplicada pelo sync (repositorios nao mudam a cada 10min) - fica
#   sob responsabilidade de core_repositories.sh na provision.
#
# LIMITACAO CONHECIDA: modulos de impressoras e certificados sao
# subconjunto simplificado. Revisar antes de producao.
#
# Os placeholders VARIAVEL sao substituidos automaticamente
# pelo sistema na geracao do bundle.
# ============================================================================

set -e

source /usr/local/lib/seederlinux/diag.sh 2>/dev/null || true
SCRIPT_ID="24-sync"

echo "============================================================"
echo "Instalar seeder-sync (aplicador GPO) + timer systemd"
echo "============================================================"

mkdir -p /etc/seederlinux
mkdir -p /var/log/seederlinux

# ============================================================
# 1. Script principal /usr/local/bin/seeder-sync
# ============================================================
log_nivel INFO "Criando /usr/local/bin/seeder-sync..."

cat > /usr/local/bin/seeder-sync <<'SYNCSCRIPT'
#!/bin/bash
# seeder-sync - aplicador idempotente de politicas (GPO-like)
set -u

CONFIG_FILE="/etc/seederlinux/config.env"
SECRETS_FILE="/etc/seederlinux/secrets.env"
STATE_FILE="/etc/seederlinux/sync-state.env"
LOG_FILE="/var/log/seederlinux/sync.log"

mkdir -p /var/log/seederlinux
exec >> "$LOG_FILE" 2>&1
echo "=== seeder-sync: $(date -Is) ==="

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERRO: $CONFIG_FILE nao encontrado. Nada a sincronizar."
    exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"

# Secrets (senhas de proxy). Opcional - pode nao existir em OM sem proxy.
if [ -f "$SECRETS_FILE" ]; then
    # shellcheck disable=SC1090
    source "$SECRETS_FILE"
fi

# ============================================================
# HELPERS DE PROXY (multi-proxy)
# ============================================================
PROXY_COUNT="${PROXY_COUNT:-0}"
PROXY_DEFAULT_NAME="${PROXY_DEFAULT_NAME:-}"

# Retorna URL do proxy com user:pass embutido (se houver credencial)
_resolver_proxy_url() {
    local name="$1"
    [ -z "$name" ] && return 1
    [ "$PROXY_COUNT" -lt 1 ] 2>/dev/null && return 1

    local i=1
    while [ "$i" -le "$PROXY_COUNT" ]; do
        local v_name="PROXY_${i}_NAME"
        if [ "${!v_name}" = "$name" ]; then
            local v_url="PROXY_${i}_URL"
            local v_user="PROXY_${i}_USER"
            local v_pass="PROXY_${i}_PASS"
            local url="${!v_url}"
            local user="${!v_user}"
            local pass="${!v_pass}"

            [ -z "$url" ] && return 1
            [ -z "$user" ] && { echo "$url"; return 0; }

            local user_esc="${user//@/%40}"
            user_esc="${user_esc//:/%3A}"
            local pass_esc="${pass//@/%40}"
            pass_esc="${pass_esc//:/%3A}"

            if echo "$url" | grep -qE '^https?://'; then
                echo "$url" | sed -E "s|^(https?://)|\1${user_esc}:${pass_esc}@|"
            else
                echo "http://${user_esc}:${pass_esc}@${url}"
            fi
            return 0
        fi
        i=$((i+1))
    done
    return 1
}

# Retorna host:port (sem scheme, sem user) ou user:pass@host:port
_resolver_proxy_hostport() {
    local name="$1"
    local fmt="${2:-plain}"
    [ -z "$name" ] && return 1
    [ "$PROXY_COUNT" -lt 1 ] 2>/dev/null && return 1

    local i=1
    while [ "$i" -le "$PROXY_COUNT" ]; do
        local v_name="PROXY_${i}_NAME"
        if [ "${!v_name}" = "$name" ]; then
            local v_url="PROXY_${i}_URL"
            local v_user="PROXY_${i}_USER"
            local v_pass="PROXY_${i}_PASS"
            local url="${!v_url}"
            local user="${!v_user}"
            local pass="${!v_pass}"

            [ -z "$url" ] && return 1

            local hostport
            hostport="$(echo "$url" | sed -E 's|^https?://||' | sed 's|/$||')"

            if [ "$fmt" = "plain" ] || [ -z "$user" ]; then
                echo "$hostport"
                return 0
            fi

            local user_esc="${user//@/%40}"
            user_esc="${user_esc//:/%3A}"
            local pass_esc="${pass//@/%40}"
            pass_esc="${pass_esc//:/%3A}"

            echo "${user_esc}:${pass_esc}@${hostport}"
            return 0
        fi
        i=$((i+1))
    done
    return 1
}

# Retorna o PAC_URL ou vazio
_resolver_proxy_pac() {
    local name="$1"
    [ -z "$name" ] && return 1
    [ "$PROXY_COUNT" -lt 1 ] 2>/dev/null && return 1

    local i=1
    while [ "$i" -le "$PROXY_COUNT" ]; do
        local v_name="PROXY_${i}_NAME"
        if [ "${!v_name}" = "$name" ]; then
            local v="PROXY_${i}_PAC_URL"
            echo "${!v}"
            return 0
        fi
        i=$((i+1))
    done
    return 1
}

# NO_PROXY específico do proxy
_resolver_proxy_no_proxy() {
    local name="$1"
    [ -z "$name" ] && return 1
    [ "$PROXY_COUNT" -lt 1 ] 2>/dev/null && return 1

    local i=1
    while [ "$i" -le "$PROXY_COUNT" ]; do
        local v_name="PROXY_${i}_NAME"
        if [ "${!v_name}" = "$name" ]; then
            local v="PROXY_${i}_NO_PROXY"
            echo "${!v}"
            return 0
        fi
        i=$((i+1))
    done
    return 1
}

# Nome efetivo do proxy conforme a policy
_proxy_nome_efetivo() {
    local especifico="$1"
    if [ -n "$especifico" ]; then
        echo "$especifico"
    else
        echo "$PROXY_DEFAULT_NAME"
    fi
}

# NO_PROXY final (base + específico do proxy)
_build_no_proxy() {
    local extra="$1"
    local base="localhost,127.0.0.1"

    if [ -n "${SEEDER_SERVER:-}" ]; then
        local host
        host="$(echo "$SEEDER_SERVER" | sed -E 's|https?://([^/]+).*|\1|')"
        if [ -n "$host" ]; then
            base="${base},${host}"
            local ip
            ip="$(getent hosts "$host" 2>/dev/null | awk '{print $1}' | head -1)"
            [ -n "$ip" ] && base="${base},${ip}"
        fi
    fi
    [ -n "${DOMINIO:-}" ] && base="${base},.${DOMINIO}"
    if [ -n "${DC_IP:-}" ]; then
        case ",$base," in *",$DC_IP,"*) ;; *) base="${base},${DC_IP}" ;; esac
    fi
    if [ -n "${DC_IP_LIST:-}" ]; then
        local dc
        for dc in $(echo "$DC_IP_LIST" | tr ',' ' '); do
            [ -z "$dc" ] && continue
            case ",$base," in *",$dc,"*) ;; *) base="${base},${dc}" ;; esac
        done
    fi
    [ -n "$extra" ] && base="${base},${extra}"

    # Normalizar: painel guarda "a;b; *.dom" — wget/curl/git
    # esperam virgula e sem "*".
    base="$(echo "$base" | tr ';' ',' | tr -d ' ')"
    base="$(echo "$base" | sed 's/^\*\././; s/,\*\./,./g')"

    echo "$base"
}

# ============================================================
# Resolucao de serial
# ============================================================
FORCE_SYNC="false"
SERVER_SERIAL=""
for arg in "$@"; do
    case "$arg" in
        --force) FORCE_SYNC="true" ;;
        [0-9]*) SERVER_SERIAL="$arg" ;;
    esac
done

if [ -z "$SERVER_SERIAL" ] && [ -n "${SERIAL_CONFIG:-}" ]; then
    SERVER_SERIAL="$SERIAL_CONFIG"
fi
if [ -z "$SERVER_SERIAL" ] && [ -f /etc/seederlinux/server-serial.env ]; then
    SERVER_SERIAL="$(grep -m1 '^SERIAL_CONFIG=' /etc/seederlinux/server-serial.env 2>/dev/null | cut -d= -f2- | tr -d '"')"
fi

SERIAL_APLICADO_ATUAL="${SERIAL_APLICADO:-0}"

if [ "$FORCE_SYNC" != "true" ] && [ -n "$SERVER_SERIAL" ]; then
    if [ "$SERVER_SERIAL" -le "$SERIAL_APLICADO_ATUAL" ] 2>/dev/null; then
        echo "SERIAL_APLICADO ($SERIAL_APLICADO_ATUAL) ja em dia com servidor ($SERVER_SERIAL). Nada a fazer."
        echo "=== seeder-sync concluido (sem alteracoes): $(date -Is) ==="
        exit 0
    fi
    echo "Serial do servidor ($SERVER_SERIAL) > aplicado ($SERIAL_APLICADO_ATUAL). Sincronizando..."
elif [ "$FORCE_SYNC" = "true" ]; then
    echo "Execucao forcada (timer) - reaplicando tudo."
else
    echo "Nenhum serial disponivel - reaplicando por seguranca."
fi

# ============================================================
# Deteccao de ambiente
# ============================================================
detectar_de() {
    if command -v cinnamon-session &>/dev/null; then echo "cinnamon"
    elif command -v mate-session &>/dev/null; then echo "mate"
    elif command -v gnome-session &>/dev/null; then echo "gnome"
    elif command -v startxfce4 &>/dev/null; then echo "xfce"
    elif command -v startplasma-x11 &>/dev/null; then echo "kde"
    elif command -v lxqt-session &>/dev/null; then echo "lxqt"
    elif command -v startlxde &>/dev/null; then echo "lxde"
    else echo "unknown"
    fi
}
[ -z "${DESKTOP_ENV:-}" ] && DESKTOP_ENV="$(detectar_de)"

detectar_dm() {
    if systemctl is-active --quiet lightdm 2>/dev/null; then echo "lightdm"
    elif systemctl is-active --quiet gdm3 2>/dev/null; then echo "gdm3"
    elif systemctl is-active --quiet sddm 2>/dev/null; then echo "sddm"
    elif [ -f /etc/X11/default-display-manager ]; then
        basename "$(cat /etc/X11/default-display-manager)"
    else echo "unknown"
    fi
}
[ -z "${DISPLAY_MANAGER:-}" ] && DISPLAY_MANAGER="$(detectar_dm)"

usuarios_com_sessao_grafica() {
    loginctl list-sessions --no-legend 2>/dev/null | awk '{print $3}' | grep -v '^root$' | sort -u
}

# Helper: prefixar URL relativa com SEEDER_SERVER
_prefixar_seeder_url() {
    local url="$1"
    [ -z "$url" ] && { echo ""; return; }
    echo "$url" | grep -qE '^https?://[^/]+/' && { echo "$url"; return; }
    [ -z "${SEEDER_SERVER:-}" ] && { echo "$url"; return; }
    local server_clean="${SEEDER_SERVER%/}"
    if echo "$url" | grep -q '^/'; then
        echo "${server_clean}${url}"
    else
        echo "${server_clean}/${url}"
    fi
}

_json_get() {
    local json="$1" key="$2" default="$3" val
    val=$(echo "$json" | jq -r "if has(\"${key}\") then .${key} else \"\" end" 2>/dev/null)
    if [ -z "$val" ] || [ "$val" = "null" ] || [ "$val" = "" ]; then
        echo "$default"
    else
        echo "$val"
    fi
}

# ============================================================
# MODULO: proxy de CLI
# ============================================================
sync_cli_proxy() {
    echo "--- proxy CLI ---"
    local policy="${CLI_POLICY:-DIRECT}"

    case "$policy" in
        DIRECT|"")
            if [ -f /etc/environment ]; then
                sed -i '/^http_proxy=/d;/^https_proxy=/d;/^ftp_proxy=/d;/^no_proxy=/d' /etc/environment 2>/dev/null || true
                sed -i '/^HTTP_PROXY=/d;/^HTTPS_PROXY=/d;/^FTP_PROXY=/d;/^NO_PROXY=/d' /etc/environment 2>/dev/null || true
                sed -i '/^all_proxy=/d;/^ALL_PROXY=/d' /etc/environment 2>/dev/null || true
                sed -i '/^# Proxy configurado por SeederLinux/d' /etc/environment 2>/dev/null || true
            fi
            echo "OK: /etc/environment sem proxy (DIRECT)"
            ;;
        PROXY|PROXY_NO_AUTH|PROXY_WITH_AUTH)
            local nome
            nome="$(_proxy_nome_efetivo "${CLI_PROXY_NAME:-}")"
            if [ -z "$nome" ]; then
                echo "AVISO: CLI_POLICY=$policy sem proxy configurado - mantendo DIRECT"
                return 0
            fi
            local url
            url="$(_resolver_proxy_url "$nome")" || url=""
            if [ -z "$url" ]; then
                echo "AVISO: proxy '$nome' nao encontrado - mantendo DIRECT"
                return 0
            fi
            local no_proxy_extra no_proxy_final
            no_proxy_extra="$(_resolver_proxy_no_proxy "$nome")" || no_proxy_extra=""
            no_proxy_final="$(_build_no_proxy "$no_proxy_extra")"

            touch /etc/environment
            sed -i '/^http_proxy=/d;/^https_proxy=/d;/^ftp_proxy=/d;/^no_proxy=/d' /etc/environment 2>/dev/null || true
            sed -i '/^HTTP_PROXY=/d;/^HTTPS_PROXY=/d;/^FTP_PROXY=/d;/^NO_PROXY=/d' /etc/environment 2>/dev/null || true
            sed -i '/^all_proxy=/d;/^ALL_PROXY=/d' /etc/environment 2>/dev/null || true
            sed -i '/^# Proxy configurado por SeederLinux/d' /etc/environment 2>/dev/null || true
            {
                echo ""
                echo "# Proxy configurado por SeederLinux (seeder-sync)"
                echo "http_proxy=\"${url}\""
                echo "https_proxy=\"${url}\""
                echo "ftp_proxy=\"${url}\""
                echo "HTTP_PROXY=\"${url}\""
                echo "HTTPS_PROXY=\"${url}\""
                echo "FTP_PROXY=\"${url}\""
                echo "no_proxy=\"${no_proxy_final}\""
                echo "NO_PROXY=\"${no_proxy_final}\""
            } >> /etc/environment
            chmod 644 /etc/environment
            echo "OK: /etc/environment atualizado (proxy: $nome)"
            ;;
        PAC)
            echo "AVISO: PAC nao suportado em CLI (wget/curl/git) - mantendo DIRECT"
            ;;
    esac
}

# ============================================================
# MODULO: politica do Firefox (com proxy)
# ============================================================
sync_firefox_policy() {
    echo "--- firefox policy ---"
    command -v firefox-esr &>/dev/null || command -v firefox &>/dev/null || { echo "Firefox nao instalado, pulando"; return 0; }

    # Modelo B: Firefox não recebe proxy em policies.json.
    # O proxy por grupo do AD é resolvido via user.js no logon e reaplicado pelo seeder-sync.
    local json
    read -r -d '' json <<EOF || true
{
  "policies": {
    "DisableTelemetry": true,
    "DisableFirefoxStudies": true,
    "DisablePocket": true,
    "DisableDeveloperTools": false,
    "BlockAboutConfig": false,
    "Homepage": {
      "URL": "${HOMEPAGE:-}",
      "Locked": true,
      "StartPage": "homepage"
    },
    "SearchBar": "unified",
    "SearchEngines": {
      "Add": [
        { "Name": "${OM_ACRONYM:-}", "URL": "${HOMEPAGE:-}", "Method": "GET" }
      ]
    },
    "Certificates": { "ImportEnterpriseRoots": true },
    "ExtensionSettings": { "*": { "installation_mode": "allowed" } },
    "DisableSetDesktopBackground": false,
    "DontCheckDefaultBrowser": true,
    "PrimaryPassword": false,
    "OfferToSaveLogins": false,
    "PasswordManagerEnabled": false,
    "SanitizeOnShutdown": {
      "Cache": true,
      "Cookies": false,
      "Downloads": false,
      "FormData": true,
      "History": false,
      "Sessions": false,
      "SiteSettings": false,
      "OfflineApps": false
    }
  }
}
EOF

    for DIR in /usr/lib/firefox-esr /usr/lib/firefox; do
        [ -d "$DIR" ] || continue
        mkdir -p "$DIR/distribution"
        echo "$json" > "$DIR/distribution/policies.json"
    done
    for DIR in /etc/firefox/policies /etc/firefox-esr/policies; do
        PARENT="$(dirname "$DIR")"
        [ -d "$PARENT" ] || continue
        mkdir -p "$DIR"
        echo "$json" > "$DIR/policies.json"
    done
    if [ -d /opt/firefox-moderno ]; then
        mkdir -p /opt/firefox-moderno/distribution
        echo "$json" > /opt/firefox-moderno/distribution/policies.json
    fi
    echo "OK: Firefox policy aplicada (sem Proxy em policies.json - Modelo B)"
}

# ============================================================
# MODULO: politica do Chrome/Chromium (com proxy)
# ============================================================
sync_chrome_policy() {
    echo "--- chrome/chromium policy ---"
    local policy="${BROWSER_POLICY:-DIRECT}"
    local proxy_json=", \"ProxyMode\": \"direct\""

    case "$policy" in
        DIRECT|"")
            proxy_json=", \"ProxyMode\": \"direct\""
            ;;
        SYSTEM)
            proxy_json=", \"ProxyMode\": \"system\""
            ;;
        PROXY|PROXY_NO_AUTH|PROXY_WITH_AUTH)
            local nome authport no_proxy_extra no_proxy_final
            nome="${PROXY_DEFAULT_NAME:-}"
            authport="$(_resolver_proxy_hostport "$nome" plain)" || authport=""
            if [ -z "$authport" ]; then
                proxy_json=", \"ProxyMode\": \"direct\""
                echo "AVISO: proxy '$nome' nao encontrado - Chrome em DIRECT"
            else
                no_proxy_extra="$(_resolver_proxy_no_proxy "$nome")" || no_proxy_extra=""
                no_proxy_final="$(_build_no_proxy "$no_proxy_extra")"
                proxy_json=", \"ProxyMode\": \"fixed_servers\", \"ProxyServer\": \"http=${authport};https=${authport}\", \"ProxyBypassList\": \"${no_proxy_final}\""
            fi
            ;;
        PAC)
            local nome pac
            nome="${PROXY_DEFAULT_NAME:-}"
            pac="$(_resolver_proxy_pac "$nome")" || pac=""
            if [ -z "$pac" ]; then
                proxy_json=", \"ProxyMode\": \"direct\""
                echo "AVISO: PAC_URL vazio - Chrome em DIRECT"
            else
                proxy_json=", \"ProxyMode\": \"pac_script\", \"ProxyPacUrl\": \"${pac}\""
            fi
            ;;
    esac

    local json
    read -r -d '' json <<EOF || true
{
    "HomepageLocation": "${HOMEPAGE:-}",
    "HomepageIsNewTabPage": false,
    "RestoreOnStartup": 1,
    "RestoreOnStartupURLs": ["${HOMEPAGE:-}"],
    "BrowserSignin": 0,
    "SyncDisabled": true,
    "BlockThirdPartyCookies": true,
    "BackgroundModeEnabled": false,
    "TelemetryReportingEnabled": false${proxy_json},
    "DefaultCookiesSetting": 1,
    "DefaultBrowserSettingEnabled": false
}
EOF

    for DIR in /etc/opt/chrome/policies/managed \
               /etc/chromium/policies/managed \
               /etc/chromium-browser/policies/managed \
               /var/snap/chromium/current/policies/managed \
               /var/snap/chromium/common/policies/managed; do
        mkdir -p "$DIR" 2>/dev/null || continue
        echo "$json" > "$DIR/seederlinux.json"
        chmod 644 "$DIR/seederlinux.json"
    done
    echo "OK: Chrome/Chromium policy aplicada (modo: $policy)"
}

# ============================================================
# MODULO: user.js do Firefox por grupo do AD (Modelo B)
# ============================================================
sync_firefox_user_js() {
    echo "--- firefox user.js ---"

    if [ -f /usr/local/lib/seederlinux/resolve-proxy.sh ]; then
        # shellcheck disable=SC1091
        source /usr/local/lib/seederlinux/resolve-proxy.sh
    else
        echo "AVISO: resolve-proxy.sh nao encontrado - pulando"
        return 0
    fi

    local u
    for u in $(usuarios_com_sessao_grafica); do
        local uid gid uhome
        uid="$(id -u "$u" 2>/dev/null)" || continue
        gid="$(id -g "$u" 2>/dev/null)" || continue
        uhome="$(getent passwd "$u" | cut -d: -f6)"
        [ -z "$uhome" ] && continue

        local fdir="$uhome/.mozilla/firefox"
        local pdir="$fdir/seederlinux.default"
        local pini="$fdir/profiles.ini"

        [ -d "$pdir" ] || { echo "  $u: perfil ausente - pulando"; continue; }
        [ -f "$pini" ] || { echo "  $u: profiles.ini ausente - pulando"; continue; }

        local userjs="$pdir/user.js"

        local idx hostport no_proxy pname
        idx="$(_resolver_proxy_index_para_usuario "$u")" || idx=""

        if [ -z "$idx" ]; then
            if [ -f "$userjs" ]; then
                rm -f "$userjs"
                echo "  $u: user.js removido (DIRECT)"
            fi
            continue
        fi

        hostport="$(_proxy_hostport_por_index "$idx")"
        no_proxy="$(_proxy_no_proxy_por_index "$idx")"
        pname="$(_proxy_name_por_index "$idx")"

        [ -z "$hostport" ] && continue

        local phost pport
        phost="${hostport%:*}"
        pport="${hostport##*:}"

        no_proxy="$(echo "$no_proxy" | tr ';' ',' | tr -d ' ')"
        no_proxy="$(echo "$no_proxy" | sed 's/^\*\././; s/,\*\./,./g')"

        local tmp
        tmp="$(mktemp /tmp/seeder-userjs.XXXXXX)"
        cat > "$tmp" <<EOFPREF
// SeederLinux — proxy por grupo do AD
// Proxy: ${pname}
// Gerado em: $(date -Is)
user_pref("network.proxy.type", 1);
user_pref("network.proxy.http", "${phost}");
user_pref("network.proxy.http_port", ${pport});
user_pref("network.proxy.ssl", "${phost}");
user_pref("network.proxy.ssl_port", ${pport});
user_pref("network.proxy.no_proxies_on", "${no_proxy}");
EOFPREF

        if [ -f "$userjs" ] && cmp -s "$tmp" "$userjs"; then
            rm -f "$tmp"
            continue
        fi

        chown "$uid:$gid" "$tmp" 2>/dev/null || true
        chmod 644 "$tmp"
        mv -f "$tmp" "$userjs"
        echo "  $u: user.js atualizado (proxy: $pname)"
    done
}

# ============================================================
# MODULO: branding (inalterado)
# ============================================================
sync_branding() {
    echo "--- branding ---"
    mkdir -p /usr/share/backgrounds/seederlinux /usr/share/pixmaps
    chmod 0755 /usr/share/backgrounds/seederlinux /usr/share/pixmaps

    local STATE_ASSETS="/etc/seederlinux/sync-assets.state"
    local LAST_WALLPAPER_URL="" LAST_WALLPAPER_LOGIN_URL="" LAST_LOGO_URL=""
    if [ -f "$STATE_ASSETS" ]; then
        # shellcheck disable=SC1090
        source "$STATE_ASSETS"
    fi
    local WP_FULL WP_LOGIN_FULL LOGO_FULL
    WP_FULL="$(_prefixar_seeder_url "${WALLPAPER_URL:-}")"
    WP_LOGIN_FULL="$(_prefixar_seeder_url "${WALLPAPER_LOGIN_URL:-}")"
    LOGO_FULL="$(_prefixar_seeder_url "${LOGO_URL:-}")"

    _baixar_ativo() {
        local url
        url="$(_prefixar_seeder_url "$1")"
        local dest="$2"
        local tmp
        tmp="$(mktemp /tmp/seeder-asset.XXXXXX)"

        if ! wget -q --no-check-certificate --no-proxy --timeout=20 -O "$tmp" "$url"; then
            rm -f "$tmp"
            echo "AVISO: falha de download de $(basename "$dest") ($url)"
            return 1
        fi
        if [ ! -s "$tmp" ]; then
            rm -f "$tmp"
            echo "AVISO: $(basename "$dest") baixou 0 bytes"
            return 1
        fi
        local mime
        mime="$(file -b --mime-type "$tmp" 2>/dev/null || echo "application/octet-stream")"
        if ! echo "$mime" | grep -q '^image/'; then
            rm -f "$tmp"
            echo "AVISO: $(basename "$dest") baixou $mime (nao imagem)"
            return 1
        fi
        install -m 0644 "$tmp" "$dest"
        rm -f "$tmp"
        echo "OK: $(basename "$dest") ($mime)"
    }

    if [ -n "$WP_FULL" ] && { [ "$WP_FULL" != "$LAST_WALLPAPER_URL" ] || [ ! -s /usr/share/backgrounds/seederlinux/wallpaper.jpg ]; }; then
        _baixar_ativo "$WP_FULL" /usr/share/backgrounds/seederlinux/wallpaper.jpg
    fi
    if [ -n "$WP_LOGIN_FULL" ] && { [ "$WP_LOGIN_FULL" != "$LAST_WALLPAPER_LOGIN_URL" ] || [ ! -s /usr/share/backgrounds/seederlinux/wallpaper-login.jpg ]; }; then
        _baixar_ativo "$WP_LOGIN_FULL" /usr/share/backgrounds/seederlinux/wallpaper-login.jpg
    fi
    if [ -n "$LOGO_FULL" ] && { [ "$LOGO_FULL" != "$LAST_LOGO_URL" ] || [ ! -s /usr/share/pixmaps/seederlinux-logo.png ]; }; then
        _baixar_ativo "$LOGO_FULL" /usr/share/pixmaps/seederlinux-logo.png
    fi

    local LOGIN_WP="/usr/share/backgrounds/seederlinux/wallpaper-login.jpg"
    local SESSION_WP="/usr/share/backgrounds/seederlinux/wallpaper.jpg"
    if [ ! -s "$LOGIN_WP" ] && [ -s "$SESSION_WP" ]; then
        install -m 0644 "$SESSION_WP" "$LOGIN_WP"
    fi

    local THEME_APLICAR=false
    if [ -n "${THEME:-}" ] && [ "${THEME}" != "DEFAULT" ] && [ -d "/usr/share/themes/${THEME}" ]; then
        THEME_APLICAR=true
    fi

    mkdir -p /etc/dconf/profile
    if [ ! -f /etc/dconf/profile/user ]; then
        printf 'user-db:user\nsystem-db:local\n' > /etc/dconf/profile/user
    elif ! grep -q '^system-db:local$' /etc/dconf/profile/user; then
        echo "system-db:local" >> /etc/dconf/profile/user
    fi
    mkdir -p /etc/dconf/db/local.d

    case "$DESKTOP_ENV" in
        cinnamon)
            cat > /etc/dconf/db/local.d/seederlinux-branding-cinnamon <<EOF
[org/cinnamon/desktop/background]
picture-uri='file:///usr/share/backgrounds/seederlinux/wallpaper.jpg'
picture-options='zoom'
EOF
            [ "$THEME_APLICAR" = "true" ] && cat >> /etc/dconf/db/local.d/seederlinux-branding-cinnamon <<EOF

[org/cinnamon/desktop/interface]
gtk-theme='${THEME}'
icon-theme-name='Adwaita'

[org/cinnamon/theme]
name='${THEME}'
EOF
            dconf update 2>/dev/null || true
            ;;
        mate)
            cat > /etc/dconf/db/local.d/seederlinux-branding-mate <<EOF
[org/mate/desktop/background]
picture-filename='/usr/share/backgrounds/seederlinux/wallpaper.jpg'
picture-options='zoom'
EOF
            dconf update 2>/dev/null || true
            ;;
        gnome)
            cat > /etc/dconf/db/local.d/seederlinux-branding-gnome <<EOF
[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/seederlinux/wallpaper.jpg'
picture-uri-dark='file:///usr/share/backgrounds/seederlinux/wallpaper.jpg'
picture-options='zoom'

[org/gnome/login-screen]
logo='/usr/share/pixmaps/seederlinux-logo.png'
EOF
            dconf update 2>/dev/null || true
            ;;
    esac

    {
        echo "LAST_WALLPAPER_URL=\"$WP_FULL\""
        echo "LAST_WALLPAPER_LOGIN_URL=\"$WP_LOGIN_FULL\""
        echo "LAST_LOGO_URL=\"$LOGO_FULL\""
    } > "$STATE_ASSETS"
    chmod 600 "$STATE_ASSETS"

    case "$DISPLAY_MANAGER" in
        lightdm)
            if [ -s "$LOGIN_WP" ]; then
                mkdir -p /etc/lightdm
                cat > /etc/lightdm/lightdm-gtk-greeter.conf <<EOF
[greeter]
background=${LOGIN_WP}
logo=/usr/share/pixmaps/seederlinux-logo.png
icon-theme-name=Adwaita
font-name=DejaVu Sans 10
EOF
                chmod 0644 /etc/lightdm/lightdm-gtk-greeter.conf
            fi
            ;;
        gdm3)
            if [ -s "$LOGIN_WP" ]; then
                mkdir -p /etc/dconf/db/gdm.d
                cat > /etc/dconf/db/gdm.d/01-seederlinux-background <<EOF
[org/gnome/desktop/background]
picture-uri='file://${LOGIN_WP}'
picture-options='zoom'
EOF
                dconf update 2>/dev/null || true
            fi
            ;;
    esac
}

# ============================================================
# MODULO: impressoras (inalterado)
# ============================================================
sync_printers() {
    echo "--- impressoras ---"
    [ -z "${PRINT_SERVER:-}" ] && { echo "PRINT_SERVER vazio, pulando"; return 0; }
    command -v cupsctl &>/dev/null || { echo "CUPS nao instalado, pulando"; return 0; }

    systemctl enable cups 2>/dev/null || true
    if ! systemctl is-active --quiet cups; then
        systemctl start cups 2>/dev/null || true
    fi
    cupsctl --remote-admin --remote-any --share-printers 2>/dev/null || true

    local PREV NEW
    PREV="$(cat /etc/cups/client.conf 2>/dev/null || true)"
    NEW="# Cliente CUPS - SeederLinux
ServerName ${PRINT_SERVER}"
    printf '%s\n' "$NEW" > /etc/cups/client.conf

    if [ -n "${PRINTERS:-}" ]; then
        for PRINTER in $PRINTERS; do
            if ! lpstat -p "$PRINTER" &>/dev/null; then
                lpadmin -p "$PRINTER" -E -v "ipp://${PRINT_SERVER}/printers/${PRINTER}" \
                    -m everywhere 2>/dev/null || echo "AVISO: falha fila '$PRINTER'"
            fi
        done
    fi

    [ -n "${DEFAULT_PRINTER:-}" ] && lpadmin -d "$DEFAULT_PRINTER" 2>/dev/null || true
    if [ "$PREV" != "$NEW" ]; then
        systemctl restart cups 2>/dev/null || true
    fi
}

# ============================================================
# MODULO: Conky (inalterado)
# ============================================================
sync_conky() {
    echo "--- conky ---"
    command -v conky &>/dev/null || return 0
    command -v jq &>/dev/null || return 0
    [ -z "${CONKY_CONFIG:-}" ] && return 0

    case "$DESKTOP_ENV" in
        cinnamon|mate|gnome|xfce|kde|lxde|lxqt) ;;
        *) return 0 ;;
    esac

    local CFG_POSITION CFG_TRANSPARENT CFG_COLOR_TEXT CFG_COLOR_BG
    local CFG_FONT_SIZE CFG_GAP_X CFG_GAP_Y CFG_UPDATE_INTERVAL
    local CFG_SHOW_CPU CFG_SHOW_RAM CFG_SHOW_DISK CFG_DISK_PARTITION
    local CFG_SHOW_NETWORK CFG_NETWORK_IFACE CFG_SHOW_TOP
    local CFG_SHOW_DATETIME CFG_SHOW_HOSTNAME CFG_HOSTNAME_FONT_SIZE

    CFG_POSITION="$(_json_get "$CONKY_CONFIG" position "top_right")"
    CFG_TRANSPARENT="$(_json_get "$CONKY_CONFIG" transparent "true")"
    CFG_COLOR_TEXT="$(_json_get "$CONKY_CONFIG" color_text "#FFFFFF")"
    CFG_COLOR_BG="$(_json_get "$CONKY_CONFIG" color_bg "#000000")"
    CFG_FONT_SIZE="$(_json_get "$CONKY_CONFIG" font_size "10")"
    CFG_GAP_X="$(_json_get "$CONKY_CONFIG" gap_x "10")"
    CFG_GAP_Y="$(_json_get "$CONKY_CONFIG" gap_y "40")"
    CFG_UPDATE_INTERVAL="$(_json_get "$CONKY_CONFIG" update_interval "1.0")"
    CFG_SHOW_CPU="$(_json_get "$CONKY_CONFIG" show_cpu "true")"
    CFG_SHOW_RAM="$(_json_get "$CONKY_CONFIG" show_ram "true")"
    CFG_SHOW_DISK="$(_json_get "$CONKY_CONFIG" show_disk "true")"
    CFG_DISK_PARTITION="$(_json_get "$CONKY_CONFIG" disk_partition "/")"
    CFG_SHOW_NETWORK="$(_json_get "$CONKY_CONFIG" show_network "true")"
    CFG_NETWORK_IFACE="$(_json_get "$CONKY_CONFIG" network_interface "eth0")"

    # Validar interface de rede: se a configurada nao existir,
    # detectar a interface default. Evita ${addr eth0} falhar.
    if ! ip link show "$CFG_NETWORK_IFACE" &>/dev/null 2>&1; then
        local DETECTED_IFACE
        DETECTED_IFACE="$(ip route 2>/dev/null | awk '/default/ {print $5; exit}')"
        if [ -n "$DETECTED_IFACE" ]; then
            echo ">>> interface '$CFG_NETWORK_IFACE' nao existe, usando '$DETECTED_IFACE'"
            CFG_NETWORK_IFACE="$DETECTED_IFACE"
        fi
    fi

    CFG_SHOW_TOP="$(_json_get "$CONKY_CONFIG" show_top_processes "true")"
    CFG_SHOW_DATETIME="$(_json_get "$CONKY_CONFIG" show_datetime "true")"
    CFG_SHOW_HOSTNAME="$(_json_get "$CONKY_CONFIG" show_hostname "true")"
    CFG_HOSTNAME_FONT_SIZE="$(_json_get "$CONKY_CONFIG" font_size_hostname "14")"

    local COLOR_TEXT_LUA="${CFG_COLOR_TEXT#\#}"
    local COLOR_BG_LUA="${CFG_COLOR_BG#\#}"
    local OWN_TRANSPARENT OWN_ARGB_VALUE
    if [ "$CFG_TRANSPARENT" = "true" ]; then
        OWN_TRANSPARENT="true"; OWN_ARGB_VALUE="0"
    else
        OWN_TRANSPARENT="false"; OWN_ARGB_VALUE="200"
    fi

    local CONKY_DIR="/etc/seederlinux/conky"
    local CONKY_CONF="$CONKY_DIR/conky.conf"
    local NEW_CONF
    NEW_CONF="$(mktemp /tmp/seeder-conky.XXXXXX)"

    local CONKY_TEXT=""
    if [ "$CFG_SHOW_HOSTNAME" = "true" ]; then
        CONKY_TEXT="\${font DejaVu Sans Mono:size=${CFG_HOSTNAME_FONT_SIZE}}\${color ${COLOR_TEXT_LUA}}Host: \${nodename}
\${font DejaVu Sans Mono:size=${CFG_FONT_SIZE}}
\${color ${COLOR_TEXT_LUA}}${OM_ACRONYM:-} - ${OM_NAME:-}
\${color ${COLOR_TEXT_LUA}}\${hr}"
    else
        CONKY_TEXT="\${color ${COLOR_TEXT_LUA}}${OM_ACRONYM:-} - ${OM_NAME:-}
\${color ${COLOR_TEXT_LUA}}\${hr}"
    fi

    CONKY_TEXT="${CONKY_TEXT}
\${color ${COLOR_TEXT_LUA}}Uptime: \${color grey}\${uptime}
\${color ${COLOR_TEXT_LUA}}\${hr}"

    if [ "$CFG_SHOW_CPU" = "true" ]; then
        CONKY_TEXT="${CONKY_TEXT}
\${color ${COLOR_TEXT_LUA}}CPU:  \${color grey}\${cpu}% \${cpubar 4}"
    fi
    if [ "$CFG_SHOW_RAM" = "true" ]; then
        CONKY_TEXT="${CONKY_TEXT}
\${color ${COLOR_TEXT_LUA}}RAM:  \${color grey}\${mem}/\${memmax} \${membar 4}
\${color ${COLOR_TEXT_LUA}}SWAP: \${color grey}\${swap}/\${swapmax} \${swapbar 4}"
    fi
    if [ "$CFG_SHOW_DISK" = "true" ]; then
        CONKY_TEXT="${CONKY_TEXT}
\${color ${COLOR_TEXT_LUA}}Disco (${CFG_DISK_PARTITION}): \${color grey}\${fs_used ${CFG_DISK_PARTITION}}/\${fs_size ${CFG_DISK_PARTITION}} \${fs_bar 6 ${CFG_DISK_PARTITION}}"
    fi
    if [ "$CFG_SHOW_NETWORK" = "true" ]; then
        CONKY_TEXT="${CONKY_TEXT}
\${color ${COLOR_TEXT_LUA}}Rede (${CFG_NETWORK_IFACE}):
\${color ${COLOR_TEXT_LUA}}IP:   \${color grey}\${addr ${CFG_NETWORK_IFACE}}
\${color ${COLOR_TEXT_LUA}}Down: \${color grey}\${downspeed ${CFG_NETWORK_IFACE}}
\${color ${COLOR_TEXT_LUA}}Up:   \${color grey}\${upspeed ${CFG_NETWORK_IFACE}}"
    fi
    if [ "$CFG_SHOW_TOP" = "true" ]; then
        CONKY_TEXT="${CONKY_TEXT}
\${color ${COLOR_TEXT_LUA}}\${hr}
\${color ${COLOR_TEXT_LUA}}Top CPU:
\${color grey}\${top name 1} \${top cpu 1}%
\${color grey}\${top name 2} \${top cpu 2}%
\${color grey}\${top name 3} \${top cpu 3}%"
    fi
    if [ "$CFG_SHOW_DATETIME" = "true" ]; then
        CONKY_TEXT="${CONKY_TEXT}
\${color ${COLOR_TEXT_LUA}}\${hr}
\${color ${COLOR_TEXT_LUA}}\${time %A, %d/%m/%Y %H:%M:%S}"
    fi

    cat > "$NEW_CONF" <<EOF
-- Configuracao Conky - SeederLinux (seeder-sync)
conky.config = {
    alignment = '${CFG_POSITION}',
    background = false,
    border_width = 1,
    cpu_avg_samples = 2,
    default_color = '${COLOR_TEXT_LUA}',
    double_buffer = true,
    draw_borders = false,
    draw_graph_borders = true,
    font = 'DejaVu Sans Mono:size=${CFG_FONT_SIZE}',
    gap_x = ${CFG_GAP_X},
    gap_y = ${CFG_GAP_Y},
    minimum_width = 200,
    net_avg_samples = 2,
    no_buffers = true,
    own_window = true,
    own_window_class = 'Conky',
    own_window_type = 'desktop',
    own_window_argb_visual = true,
    own_window_argb_value = ${OWN_ARGB_VALUE},
    own_window_transparent = ${OWN_TRANSPARENT},
    own_window_colour = '${COLOR_BG_LUA}',
    own_window_hints = 'undecorated,below,sticky,skip_taskbar,skip_pager',
    update_interval = ${CFG_UPDATE_INTERVAL},
    use_xft = true,
}
conky.text = [[
${CONKY_TEXT}
]]
EOF

    mkdir -p "$CONKY_DIR"
    local CONF_CHANGED=false
    if [ ! -f "$CONKY_CONF" ] || ! cmp -s "$NEW_CONF" "$CONKY_CONF"; then
        install -m 0644 "$NEW_CONF" "$CONKY_CONF"
        CONF_CHANGED=true
        echo "OK: conky.conf regravado"
    else
        echo "OK: conky.conf em dia"
    fi
    rm -f "$NEW_CONF"

    install -m 0755 /dev/stdin /usr/local/bin/seederlinux-conky <<'LAUNCHER'
#!/bin/bash
CONKY_CONF="/etc/seederlinux/conky/conky.conf"
sleep 3
if [ -f "$CONKY_CONF" ]; then
    killall conky 2>/dev/null || true
    conky -c "$CONKY_CONF" &
fi
LAUNCHER

    local u
    for u in $(usuarios_com_sessao_grafica); do
        if [ "$CONF_CHANGED" = "true" ]; then
            su - "$u" -c "pkill -u '$u' conky 2>/dev/null; sleep 1; DISPLAY=:0 /usr/local/bin/seederlinux-conky" 2>/dev/null &
            echo "OK: conky reiniciado para $u"
        else
            pgrep -u "$u" conky &>/dev/null || \
                su - "$u" -c "DISPLAY=:0 /usr/local/bin/seederlinux-conky" 2>/dev/null &
        fi
    done
}

# ============================================================
# MODULO: compartilhamentos (inalterado)
# ============================================================
sync_shares() {
    echo "--- compartilhamentos ---"
    [ -z "${SERVIDOR_ARQUIVOS:-}" ] && return 0
    [ -z "${COMPARTILHAMENTOS:-}" ] && return 0
    local MOUNT_DIR="${MOUNT_BASE:-/mnt}"
    local u
    for u in $(usuarios_com_sessao_grafica); do
        local uid gid
        uid="$(id -u "$u" 2>/dev/null)" || continue
        gid="$(id -g "$u" 2>/dev/null)" || continue
        local SHARE
        IFS=',' read -ra _shares_arr <<< "$COMPARTILHAMENTOS"
        for SHARE in "${_shares_arr[@]}"; do
            SHARE="${SHARE#"${SHARE%%[![:space:]]*}"}"
            SHARE="${SHARE%"${SHARE##*[![:space:]]}"}"
            [ -z "$SHARE" ] && continue

            local SHARE_MOUNT="${MOUNT_DIR}/${SHARE}"
            mkdir -p "$SHARE_MOUNT"
            mountpoint -q "$SHARE_MOUNT" 2>/dev/null && continue
            mount -t cifs "//${SERVIDOR_ARQUIVOS}/${SHARE}" "$SHARE_MOUNT" \
                -o "username=${u},domain=${DOMINIO_NETBIOS:-},uid=${uid},gid=${gid},iocharset=utf8,vers=3.0" \
                2>/dev/null || echo "AVISO: falha remontar ${SHARE} para ${u}"
        done
    done
}

# ============================================================
# MODULO: certificados (inalterado)
# ============================================================
sync_certificates() {
    echo "--- certificados ---"
    [ "${CERTIFICATE_AUTO_INSTALL:-}" = "true" ] || return 0
    [ -z "${CERTIFICATE_BUNDLE:-}" ] && return 0

    local CERT_URL
    CERT_URL="$(_prefixar_seeder_url "$CERTIFICATE_BUNDLE")"

    local CERT_TMP="/tmp/seederlinux-cert-bundle"
    local CERT_DEST_DIR="/usr/local/share/ca-certificates/seederlinux"
    mkdir -p "$CERT_DEST_DIR"

    if ! wget -q --no-check-certificate --timeout=20 -O "$CERT_TMP" "$CERT_URL" 2>/dev/null; then
        echo "AVISO: falha baixar CERTIFICATE_BUNDLE"
        return 0
    fi
    [ ! -s "$CERT_TMP" ] && { rm -f "$CERT_TMP"; return 0; }

    local FILETYPE
    FILETYPE="$(file -b "$CERT_TMP" 2>/dev/null)"
    case "$FILETYPE" in
        *gzip*|*tar*)
            mkdir -p /tmp/seederlinux-certs-extract
            tar xzf "$CERT_TMP" -C /tmp/seederlinux-certs-extract 2>/dev/null || \
                tar xf "$CERT_TMP" -C /tmp/seederlinux-certs-extract 2>/dev/null
            find /tmp/seederlinux-certs-extract -type f \( -name "*.crt" -o -name "*.pem" -o -name "*.cer" \) \
                -exec cp {} "$CERT_DEST_DIR/" \;
            rm -rf /tmp/seederlinux-certs-extract
            ;;
        *)
            cp "$CERT_TMP" "$CERT_DEST_DIR/seederlinux-${OM_ACRONYM:-om}.crt"
            ;;
    esac
    rm -f "$CERT_TMP"
    update-ca-certificates 2>/dev/null || true
}

# ============================================================
# Execucao
# ============================================================
sync_branding
sync_firefox_policy
sync_chrome_policy
sync_firefox_user_js
sync_cli_proxy
sync_printers
sync_conky
sync_shares
sync_certificates

# ============================================================
# Atualizar SERIAL_APLICADO
# ============================================================
if [ -n "$SERVER_SERIAL" ]; then
    if grep -q '^SERIAL_APLICADO=' "$CONFIG_FILE" 2>/dev/null; then
        sed -i "s/^SERIAL_APLICADO=.*/SERIAL_APLICADO=\"${SERVER_SERIAL}\"/" "$CONFIG_FILE"
    else
        echo "SERIAL_APLICADO=\"${SERVER_SERIAL}\"" >> "$CONFIG_FILE"
    fi
    SERIAL_APLICADO_ATUAL="$SERVER_SERIAL"
    echo "SERIAL_APLICADO atualizado para $SERVER_SERIAL"
fi

{
    echo "LAST_SYNC=$(date -Is)"
    echo "SERIAL_APLICADO=${SERIAL_APLICADO_ATUAL}"
    echo "FORCE_SYNC=${FORCE_SYNC}"
} > "$STATE_FILE"

echo "=== seeder-sync concluido: $(date -Is) ==="
SYNCSCRIPT

chmod 750 /usr/local/bin/seeder-sync
log_nivel INFO "/usr/local/bin/seeder-sync criado"

# ============================================================
# 2. Units systemd
# ============================================================
cat > /etc/systemd/system/seeder-sync.service <<EOF
[Unit]
Description=SeederLinux - Aplicador de politicas (GPO-like)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/seeder-sync --force
EOF

cat > /etc/systemd/system/seeder-sync.timer <<EOF
[Unit]
Description=SeederLinux - Timer do seeder-sync (10 em 10 minutos)

[Timer]
OnBootSec=2min
OnUnitActiveSec=10min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now seeder-sync.timer
systemctl start seeder-sync.service 2>/dev/null || true

log_nivel INFO "seeder-sync instalado e timer ativo (10min)"
echo "============================================================"
$SeederScript$,
    TRUE,
    TRUE,
    24,
    ARRAY['core_dns.sh', 'core_ntp.sh', 'core_repositories.sh', 'core_packages.sh', 'core_legados.sh', 'core_apps.sh', 'core_domain.sh', 'core_ssh.sh', 'core_browser.sh', 'core_inventory.sh', 'core_printers.sh', 'core_vnc.sh', 'core_conky.sh', 'core_config.sh', 'core_branding.sh', 'core_session_lightdm.sh', 'core_session_gdm3.sh', 'core_session_sddm.sh', 'core_logon.sh', 'core_password_change.sh', 'core_logoff.sh', 'core_proxy.sh', 'core_agent.sh']::TEXT[],
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    depends_on = EXCLUDED.depends_on,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;



-- ============================================================================
-- FIM: 24 scripts core inseridos.
-- Ordem de execucao:
--   01 core_dns.sh              (configura DNS ANTES de apt-get update)
--   02 core_ntp.sh              (NTP adaptativo; roda ANTES do core_domain)
--   03 core_repositories.sh     (agora tem DNS resolvendo)
--   04 core_packages.sh
--   05 core_legados.sh
--   06 core_apps.sh
--   07 core_domain.sh
--   08 core_ssh.sh
--   09 core_browser.sh
--   10 core_inventory.sh
--   11 core_printers.sh
--   12 core_vnc.sh
--   13 core_conky.sh
--   14 core_config.sh
--   15 core_branding.sh
--   16 core_session_lightdm.sh   (bundle mantem apenas 1 dos 3 conforme DISPLAY_MANAGER)
--   17 core_session_gdm3.sh
--   18 core_session_sddm.sh
--   19 core_logon.sh
--   20 core_password_change.sh
--   21 core_logoff.sh
--   22 core_proxy.sh
--   23 core_agent.sh
--   24 core_sync.sh              (seeder-sync + timer systemd: reaplica politicas)
-- ============================================================================
