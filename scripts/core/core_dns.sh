#!/bin/bash
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