#!/bin/bash
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

# ============================================================
# Google Chrome (instalado via .deb/wget, nao via apt-get)
# ============================================================
if [ "$INSTALL_CHROME" = "true" ]; then
    echo ">>> Instalando Google Chrome..."
    CHROME_DEB="/tmp/google-chrome-stable.deb"

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
    apt-get install -y chromium 2>/dev/null || \
        apt-get install -y chromium-browser 2>/dev/null || {
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
echo ">>> Verificando instalacoes..."

# Firefox: aceita firefox-esr OU firefox (varia por distro)
if command -v firefox-esr &>/dev/null; then
    echo ">>> Firefox ESR: OK (firefox-esr)"
elif command -v firefox &>/dev/null; then
    echo ">>> Firefox ESR: OK (firefox)"
else
    echo ">>> Firefox ESR: NAO INSTALADO"
fi

# Chrome: aceita google-chrome OU google-chrome-stable
if command -v google-chrome &>/dev/null; then
    echo ">>> Google Chrome: OK (google-chrome)"
elif command -v google-chrome-stable &>/dev/null; then
    echo ">>> Google Chrome: OK (google-chrome-stable)"
else
    echo ">>> Google Chrome: NAO INSTALADO"
fi

# Chromium: aceita chromium OU chromium-browser
if command -v chromium &>/dev/null; then
    echo ">>> Chromium: OK (chromium)"
elif command -v chromium-browser &>/dev/null; then
    echo ">>> Chromium: OK (chromium-browser)"
else
    # So reporta "nao instalado" se INSTALL_CHROMIUM=true. Caso
    # contrario, e' o comportamento esperado (toggle desligado).
    if [ "$INSTALL_CHROMIUM" = "true" ]; then
        echo ">>> Chromium: NAO INSTALADO (toggle estava ativo)"
    else
        echo ">>> Chromium: desativado (toggle=false)"
    fi
fi

# OnlyOffice
if command -v onlyoffice-desktopeditors &>/dev/null; then
    echo ">>> OnlyOffice: OK"
else
    if [ "$INSTALL_ONLYOFFICE" = "true" ]; then
        echo ">>> OnlyOffice: NAO INSTALADO (toggle estava ativo)"
    else
        echo ">>> OnlyOffice: desativado (toggle=false)"
    fi
fi

# Firefox 52.7 ESR legado (instalado pelo core_legados.sh, roda antes)
if [ -x /opt/firefox-legado/firefox ]; then
    echo ">>> Firefox 52.7 ESR (legado): OK (/opt/firefox-legado)"
elif [ -x /usr/local/bin/firefox-legado ]; then
    echo ">>> Firefox 52.7 ESR (legado): OK (symlink em /usr/local/bin)"
else
    echo ">>> Firefox 52.7 ESR (legado): nao instalado"
fi

echo ">>> [10] Aplicativos instalados!"
echo "============================================================"
)
