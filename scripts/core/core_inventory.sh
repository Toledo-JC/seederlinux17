#!/bin/bash
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
