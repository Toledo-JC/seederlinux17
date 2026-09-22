#!/bin/bash
# ============================================================================
# Core Script: core_dns.sh
# SeederLinux Lite - DNS, NTP e resolucao de nomes
# ============================================================================
# Configura DNS temporario para permitir resolucao durante o
# provisionamento, ajusta /etc/resolv.conf, /etc/hosts e sincroniza NTP.
#
# CONTRATO DE FASES DO BUNDLE:
#   Fase 1 (este script, etapa 01): DNS de internet na frente. Permite
#     apt-get/wget nos scripts 02..05 (repositorios, pacotes, legados,
#     apps).
#   Fase 2 (core_domain.sh, etapa 06): reescreve /etc/resolv.conf
#     apontando SOMENTE para DNS_PRIMARIO + DNS_SECUNDARIO do AD.
#   Fase 3 (scripts 07..23): DNS do AD mantido, sem apt-get.
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

echo "============================================================"
echo "01 - Configurar DNS, NTP e resolucao de nomes"
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
NTP_SERVER="{{NTP_SERVER}}"
OM_ACRONYM="{{OM_ACRONYM}}"

# Remover protocolo indevido do NTP_SERVER (a OM pode ter cadastrado
# "http://host" em vez de "host"; normalizamos aqui para nao quebrar
# o chrony/ntp, que esperam apenas hostname/IP).
NTP_SERVER="${NTP_SERVER#http://}"
NTP_SERVER="${NTP_SERVER#https://}"

NON_INTERACTIVE="${NON_INTERACTIVE:-false}"

# ============================================================
# Exibir informacoes
# ============================================================
echo ">>> Dominio: $DOMINIO"
echo ">>> DNS primario: $DNS_PRIMARIO"
echo ">>> DNS secundario: ${DNS_SECUNDARIO}"
echo ">>> NTP: $NTP_SERVER"

# ============================================================
# Hostname interativo
# ============================================================
CURRENT_HOSTNAME=$(hostname)
echo ">>> Hostname atual: $CURRENT_HOSTNAME"

if [ "$NON_INTERACTIVE" = "true" ]; then
    CHANGE_HOST="n"
else
    read -p ">>> Deseja alterar o hostname? (s/N): " CHANGE_HOST
fi

if [[ "$CHANGE_HOST" =~ ^[Ss]$ ]]; then
    if [ "$NON_INTERACTIVE" = "true" ]; then
        echo ">>> Modo não interativo: mantendo hostname atual."
    else
        read -p ">>> Novo hostname: " NEW_HOSTNAME
        hostnamectl set-hostname "$NEW_HOSTNAME"
        echo ">>> Hostname alterado para: $NEW_HOSTNAME"
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
echo ">>> Configurando DNS temporario (Fase 1: internet primeiro para baixar pacotes)..."

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
    echo "# Sera reescrito pelo core_domain.sh (script 06) na Fase 2."
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
echo ">>> DNS temporario configurado:"
sed 's/^/    /' /etc/resolv.conf

# ============================================================
# /etc/hosts - garantir resolucao do proprio host e do dominio
# ============================================================
echo ">>> Configurando /etc/hosts..."

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

echo ">>> /etc/hosts configurado"

# ============================================================
# NTP - sincronizar horario com o servidor
# ============================================================
echo ">>> Configurando NTP..."
if command -v timedatectl &> /dev/null; then
    timedatectl set-ntp true 2>/dev/null || true
fi

if [ -n "$NTP_SERVER" ] && [ "$NTP_SERVER" != "" ]; then
    # Tenta sincronizar imediatamente
    if command -v ntpdate &> /dev/null; then
        ntpdate "$NTP_SERVER" 2>/dev/null || true
    elif command -v chronyc &> /dev/null; then
        chronyc -a makestep 2>/dev/null || true
    fi

    # Configura NTP permanente
    if [ -d /etc/chrony ]; then
        cat > /etc/chrony/chrony.conf <<EOF
server $NTP_SERVER iburst
driftfile /var/lib/chrony/chrony.drift
makestep 1.0 3
rtcsync
EOF
        systemctl restart chrony 2>/dev/null || true
    elif [ -f /etc/ntp.conf ]; then
        cp /etc/ntp.conf /etc/ntp.conf.bak 2>/dev/null || true
        cat > /etc/ntp.conf <<EOF
server $NTP_SERVER iburst
driftfile /var/lib/ntp/ntp.drift
restrict default kod nomodify notrap nopeer noquery
restrict 127.0.0.1
EOF
        systemctl restart ntp 2>/dev/null || true
    fi
    echo ">>> NTP configurado: $NTP_SERVER"
else
    echo ">>> NTP_SERVER nao definido, usando padrao do sistema"
fi

echo ">>> [01] DNS, NTP e resolucao de nomes configurados!"
echo "============================================================"
