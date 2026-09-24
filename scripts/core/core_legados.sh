#!/bin/bash
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

echo "============================================================"
echo "05 - Configurar sistemas legados (Java 8, Firefox 52.7)"
echo "============================================================"

# ============================================================
# Variaveis (substituidas no bundle)
# ============================================================
INSTALL_JAVA8="{{INSTALL_JAVA8}}"
INSTALL_FIREFOX52="{{INSTALL_FIREFOX52}}"
BASE_URL="{{BASE_URL}}"
JAVA_EXCEPTIONS="{{JAVA_EXCEPTIONS}}"

BASE_URL="${BASE_URL%/}"

echo ">>> Instalar Java 8: $INSTALL_JAVA8"
echo ">>> Instalar Firefox 52.7: $INSTALL_FIREFOX52"
echo ">>> Excecoes Java: ${JAVA_EXCEPTIONS:-nenhuma}"

# ============================================================
# Verificar se pelo menos um toggle esta ativo
# ============================================================
if [ "$INSTALL_JAVA8" != "true" ] && [ "$INSTALL_FIREFOX52" != "true" ]; then
    echo ">>> Sistemas legados desativados. Pulando."
    echo ">>> [05] Sistemas legados nao instalados (desativado)."
    echo "============================================================"
    exit 0
fi

export DEBIAN_FRONTEND=noninteractive

# ============================================================
# Java 8 (OpenJDK) - apenas se INSTALL_JAVA8=true
# ============================================================
if [ "$INSTALL_JAVA8" = "true" ]; then
    echo ">>> Instalando Java 8 (OpenJDK 8)..."

    if command -v java &>/dev/null; then
        JAVA_VERSION=$(java -version 2>&1 | head -1)
        echo ">>> Java ja instalado: $JAVA_VERSION"
    else
        echo ">>> Java 8 nao encontrado. Tentando repositorio Adoptium/Temurin..."

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
            echo ">>> AVISO: nao foi possivel detectar codename. Usando bookworm."
            ADOPTIUM_CODENAME="bookworm"
        fi
        echo ">>> Codename Adoptium: $ADOPTIUM_CODENAME"

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
                echo ">>> Temurin 8 instalado via Adoptium"
            else
                echo ">>> AVISO: Falha ao instalar temurin-8-jre."
                echo ">>>        Verifique se Adoptium tem suite '$ADOPTIUM_CODENAME'."
                # Limpa o repo para nao atrapalhar proximos apt-get update
                rm -f /etc/apt/sources.list.d/adoptium.list
                apt-get update -qq 2>/dev/null || true
            fi
        else
            echo ">>> AVISO: Nao foi possivel baixar a chave GPG do Adoptium."
            echo ">>>        Java 8 legado nao sera instalado por aqui."
        fi
    fi

    # ------------------------------------------------------------------
    # Excecoes Java (deployment.properties) - se fornecidas
    # ------------------------------------------------------------------
    if [ -n "$JAVA_EXCEPTIONS" ]; then
        echo ">>> Configurando excecoes Java..."
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
        echo ">>> Excecoes Java configuradas ($IDX URLs)"
    fi

    if command -v java &>/dev/null; then
        echo ">>> Java instalado: $(java -version 2>&1 | head -1)"
    else
        echo ">>> AVISO: Java nao instalado."
    fi
else
    echo ">>> Java 8 desativado (INSTALL_JAVA8=false). Pulando."
fi

# ============================================================
# Firefox 52.7 ESR - apenas se INSTALL_FIREFOX52=true
# ============================================================
if [ "$INSTALL_FIREFOX52" = "true" ]; then
    echo ">>> Instalando Firefox 52.7 ESR..."

    # ------------------------------------------------------------------
    # Pre-requisito: bzip2 para extrair .tar.bz2
    # ------------------------------------------------------------------
    if ! command -v bzip2 &>/dev/null; then
        echo ">>> bzip2 nao instalado. Tentando instalar..."
        apt-get install -y bzip2 2>/dev/null || true
    fi
    if ! command -v bzip2 &>/dev/null; then
        echo ">>> AVISO: bzip2 indisponivel - impossivel extrair o tarball do Firefox 52.7."
        echo ">>>        Pulando instalacao do Firefox legado (nao e' critico para o ingresso AD)."
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
            echo ">>> Firefox 52.7 baixado do repositorio interno do Seeder"
            if tar xjf "$FF_LEGADO_TARBALL" -C /opt/ 2>/dev/null; then
                mv /opt/firefox "$FF_LEGADO_DIR" 2>/dev/null || true
            else
                echo ">>> AVISO: falha ao extrair tarball do Seeder."
            fi
        else
            echo ">>> AVISO: tarball do Seeder baixou vazio."
        fi
        rm -f "$FF_LEGADO_TARBALL"
    else
        # ------------------------------------------------------------------
        # Fallback: Mozilla (download publico)
        # Respeita proxy do ambiente se houver.
        # ------------------------------------------------------------------
        echo ">>> AVISO: Nao foi possivel baixar do repositorio interno."
        echo ">>>        Tentando Mozilla (ftp.mozilla.org)..."

        FF_MOZILLA_URL="https://ftp.mozilla.org/pub/firefox/releases/52.7.3esr/linux-x86_64/en-US/firefox-52.7.3esr.tar.bz2"
        if wget -q --timeout=60 -O "$FF_LEGADO_TARBALL" "$FF_MOZILLA_URL" 2>/dev/null; then
            if [ -s "$FF_LEGADO_TARBALL" ]; then
                echo ">>> Firefox 52.7 baixado da Mozilla"
                if tar xjf "$FF_LEGADO_TARBALL" -C /opt/ 2>/dev/null; then
                    mv /opt/firefox "$FF_LEGADO_DIR" 2>/dev/null || true
                else
                    echo ">>> AVISO: falha ao extrair tarball da Mozilla."
                fi
            else
                echo ">>> AVISO: tarball da Mozilla baixou vazio."
            fi
            rm -f "$FF_LEGADO_TARBALL"
        else
            echo ">>> AVISO: Nao foi possivel baixar Firefox 52.7 de nenhuma fonte."
        fi
    fi

    # ------------------------------------------------------------------
    # Se extraiu, configura symlink + .desktop
    # ------------------------------------------------------------------
    if [ -d "$FF_LEGADO_DIR" ]; then
        ln -sf "${FF_LEGADO_DIR}/firefox" /usr/local/bin/firefox-legado
        echo ">>> Firefox 52.7 ESR instalado em: $FF_LEGADO_DIR"

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
        echo ">>> Entrada de desktop criada"

        # Plugin Java (para applets)
        if command -v java &>/dev/null; then
            echo ">>> Configurando plugin Java para Firefox legado..."
            JAVA_HOME_DIR="$(dirname "$(dirname "$(readlink -f "$(which java)")")")"
            PLUGIN_DIR="${FF_LEGADO_DIR}/browser/plugins"
            mkdir -p "$PLUGIN_DIR"
            if find "$JAVA_HOME_DIR" -name "libnpjp2.so" -exec ln -sf {} "$PLUGIN_DIR/libnpjp2.so" \; 2>/dev/null; then
                echo ">>> Plugin Java configurado"
            else
                echo ">>> AVISO: Plugin Java (libnpjp2.so) nao encontrado."
            fi
        fi
    else
        echo ">>> AVISO: Firefox 52.7 ESR nao instalado (nenhuma fonte funcionou)."
    fi
else
    echo ">>> Firefox 52.7 desativado (INSTALL_FIREFOX52=false). Pulando."
fi

echo ">>> [05] Sistemas legados configurados!"
echo "============================================================"
)
