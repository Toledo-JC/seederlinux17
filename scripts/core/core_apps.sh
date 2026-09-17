#!/bin/bash
# ============================================================================
# Core Script: core_apps.sh
# SeederLinux Lite - OnlyOffice, Chrome, Firefox ESR
# ============================================================================
# Instala aplicativos adicionais: OnlyOffice Desktop Editors, Google Chrome
# estavel e Firefox ESR.
# Os placeholders VARIAVEL são substituídos automaticamente
# pelo sistema na geração do bundle.
# ============================================================================

(
set -e

echo "============================================================"
echo "10 - Instalar aplicativos (Chrome, OnlyOffice via .deb/wget)"
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

echo ">>> Instalar OnlyOffice: $INSTALL_ONLYOFFICE"
echo ">>> Instalar Chrome: $INSTALL_CHROME"
echo ">>> Instalar Chromium: $INSTALL_CHROMIUM"

# ============================================================
# Verificar se pelo menos um toggle esta ativo
# ============================================================
if [ "$INSTALL_ONLYOFFICE" != "true" ] && [ "$INSTALL_CHROME" != "true" ] && [ "$INSTALL_CHROMIUM" != "true" ]; then
    echo ">>> Instalacao de apps desativada. Pulando."
    echo ">>> [10] Aplicativos nao instalados (desativado)."
    echo "============================================================"
    exit 0
fi

export DEBIAN_FRONTEND=noninteractive

# Configurar proxy para downloads se necessario
##if [ "$PROXY_MODE" = "MANUAL" ] && [ -n "$PROXY_HTTP" ] && [ "$PROXY_HTTP" != "" ]; then
##    export http_proxy="http://${PROXY_HTTP}:${PROXY_PORTA}"
##    export https_proxy="http://${PROXY_HTTP}:${PROXY_PORTA}"
##fi

# ============================================================
# Google Chrome (instalado via .deb/wget, nao via apt-get)
# ============================================================
if [ "$INSTALL_CHROME" = "true" ]; then
    echo ">>> Instalando Google Chrome..."
    CHROME_DEB="/tmp/google-chrome-stable.deb"

    # Baixar Chrome
    if wget -q -O "$CHROME_DEB" "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"; then
        apt-get install -y "$CHROME_DEB" || {
            echo ">>> AVISO: Falha ao instalar Google Chrome. Tentando dependencias..."
            apt-get install -y -f
            apt-get install -y "$CHROME_DEB" || {
                echo ">>> AVISO: Google Chrome nao instalado."
            }
        }
        rm -f "$CHROME_DEB"
    else
        echo ">>> AVISO: Nao foi possivel baixar Google Chrome."
        echo ">>> Verifique conectividade e configuracao de proxy."
    fi
else
    echo ">>> Google Chrome desativado (INSTALL_CHROME=false). Pulando."
fi

# ============================================================
# Chromium (via apt-get)
# ============================================================
if [ "$INSTALL_CHROMIUM" = "true" ]; then
    echo ">>> Instalando Chromium..."
    apt-get install -y chromium 2>/dev/null || apt-get install -y chromium-browser 2>/dev/null || {
        echo ">>> AVISO: Nao foi possivel instalar Chromium."
    }
else
    echo ">>> Chromium desativado (INSTALL_CHROMIUM=false). Pulando."
fi

# ============================================================
# OnlyOffice Desktop Editors
# ============================================================
if [ "$INSTALL_ONLYOFFICE" = "true" ]; then
    echo ">>> Instalando OnlyOffice Desktop Editors..."

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
        echo ">>> AVISO: Falha ao instalar OnlyOffice via repositorio."
        echo ">>> Tentando download direto..."

        # Metodo 2: Download direto do .deb
        ONLYOFFICE_DEB="/tmp/onlyoffice-desktopeditors.deb"
        if wget -q -O "$ONLYOFFICE_DEB" "https://download.onlyoffice.com/install/desktop/editors/linux/onlyoffice-desktopeditors_amd64.deb"; then
            apt-get install -y "$ONLYOFFICE_DEB" || {
                echo ">>> AVISO: Falha ao instalar OnlyOffice via .deb direto."
            }
            rm -f "$ONLYOFFICE_DEB"
        else
            echo ">>> AVISO: Nao foi possivel baixar OnlyOffice."
        fi
    }
    rm -f "$ONLYOFFICE_KEY"
else
    echo ">>> AVISO: Nao foi possivel obter chave do OnlyOffice."
    echo ">>> Tentando instalar via repositorio Debian..."

    apt-get install -y onlyoffice-desktopeditors 2>/dev/null || {
            echo ">>> AVISO: OnlyOffice nao disponivel. Instalacao ignorada."
        }
    fi
else
    echo ">>> OnlyOffice desativado (INSTALL_ONLYOFFICE=false). Pulando."
fi

# ============================================================
# Verificar instalacoes
# ============================================================
echo ">>> Verificando instalacoes..."
command -v firefox-esr &> /dev/null && echo ">>> Firefox ESR: OK" || echo ">>> Firefox ESR: NAO INSTALADO"
command -v google-chrome &> /dev/null && echo ">>> Google Chrome: OK" || echo ">>> Google Chrome: NAO INSTALADO"
command -v onlyoffice-desktopeditors &> /dev/null && echo ">>> OnlyOffice: OK" || echo ">>> OnlyOffice: NAO INSTALADO"

echo ">>> [10] Aplicativos instalados!"
echo "============================================================"
)
