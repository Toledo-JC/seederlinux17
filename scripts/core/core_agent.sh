#!/bin/bash
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

echo "============================================================"
echo "18 - Instalar agente de check-in (seeder-agent)"
echo "============================================================"

INSTALL_AGENT="{{INSTALL_AGENT}}"
if [ "$INSTALL_AGENT" != "true" ]; then
    echo ">>> Instalacao do agente desativada (INSTALL_AGENT=false). Pulando."
    echo "============================================================"
    exit 0
fi

SEEDER_SERVER="{{SEEDER_SERVER}}"
OM_ACRONYM="{{OM_ACRONYM}}"
AGENT_NO_CHECK_CERT="{{AGENT_NO_CHECK_CERT}}"

SEEDER_SERVER="${SEEDER_SERVER%/}"

echo ">>> Servidor: $SEEDER_SERVER"
echo ">>> Organizacao: $OM_ACRONYM"
echo ">>> Ignorar cert SSL: $AGENT_NO_CHECK_CERT"

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

echo ">>> Baixando agente de ${SEEDER_SERVER}/downloads/agent.py ..."
mkdir -p /usr/local/bin

AGENT_URL="${SEEDER_SERVER}/downloads/agent.py"
AGENT_TMP="/tmp/seeder-agent-download.$$"

if wget -q --no-check-certificate --no-proxy --timeout=30 -O "$AGENT_TMP" "$AGENT_URL"; then
    if [ ! -s "$AGENT_TMP" ]; then
        echo ">>> ERRO: Agente baixado mas arquivo esta vazio. Verifique $AGENT_URL"
        rm -f "$AGENT_TMP"
        echo "============================================================"
        exit 1
    fi
    install -m 0755 "$AGENT_TMP" /usr/local/bin/seeder-agent
    rm -f "$AGENT_TMP"
    echo ">>> Agente instalado em /usr/local/bin/seeder-agent"

    # Sanity check: verifica que o arquivo tem o cabecalho esperado
    if ! head -5 /usr/local/bin/seeder-agent | grep -q "SeederLinux"; then
        echo ">>> AVISO: agente baixado nao parece ser o esperado."
        echo ">>>        Primeiras linhas:"
        head -3 /usr/local/bin/seeder-agent | sed 's/^/    /'
    fi
else
    echo ">>> ERRO: Falha ao baixar o agente de $AGENT_URL"
    echo ">>>        Verifique conectividade L3 com o Seeder."
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

echo ">>> Cron configurado: /etc/cron.d/seeder-agent"

# ============================================================
# Primeiro check-in (em background, sem bloquear o bundle)
# ============================================================
echo ">>> Executando primeiro check-in em background..."
mkdir -p /var/log/seeder
nohup /usr/local/bin/seeder-agent --org "$OM_ACRONYM" --no-check-certificate \
    > /tmp/seeder-first-checkin.log 2>&1 &

echo ">>> [18] Agente instalado e agendado!"
echo "============================================================"
)
