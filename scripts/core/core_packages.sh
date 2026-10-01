#!/bin/bash
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

echo "============================================================"
echo "03 - Instalar pacotes essenciais"
echo "============================================================"

# ============================================================
# Variáveis
# ============================================================
DESKTOP_ENV=""
INSTALL_DESKTOP="false"

echo ">>> Ambiente grafico solicitado (opcional): $DESKTOP_ENV"
echo ">>> Instalar ambiente grafico: $INSTALL_DESKTOP"

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

echo ">>> DE detectado na estacao: $DETECTED_DE"
echo ">>> DM detectado na estacao: $DETECTED_DM"

# ============================================================
# Instalar pacotes com fallback por item
# ============================================================
instalar_pacotes() {
    local grupo="$1"; shift
    local falhou=0
    for pkg in "$@"; do
        if ! apt-get install -y "$pkg" 2>/dev/null; then
            echo ">>> AVISO [$grupo]: falha ao instalar pacote '$pkg'"
            falhou=$((falhou + 1))
        fi
    done
    if [ "$falhou" -gt 0 ]; then
        echo ">>> [$grupo] concluido com $falhou pacote(s) nao instalado(s)."
    fi
}

# ============================================================
# Atualizar sistema
# ============================================================
echo ">>> Atualizando pacotes do sistema..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y upgrade

# ============================================================
# Pacotes base do sistema
# ============================================================
echo ">>> Instalando pacotes base..."
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
echo ">>> Garantindo repositorio universe..."
if command -v add-apt-repository &>/dev/null; then
    add-apt-repository -y universe 2>/dev/null || true
fi
apt-get update -qq

# ============================================================
# Pacotes de autenticacao (AD/Kerberos/SSSD)
# ============================================================
echo ">>> Instalando pacotes de autenticacao..."
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
    echo ">>> Instalando ambiente grafico solicitado: $DESKTOP_ENV"
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
            echo ">>> AVISO: Ambiente grafico nao reconhecido: $DESKTOP_ENV"
            echo ">>> Nenhum DE sera instalado. Usando o ja presente: $DETECTED_DE"
            ;;
    esac
else
    echo ">>> INSTALL_DESKTOP != true. Nao instalando DE."
    echo ">>> Utilizando ambiente grafico ja presente: $DETECTED_DE"
fi

# ============================================================
# Pacotes complementares
# ============================================================
echo ">>> Instalando pacotes complementares..."
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

echo ">>> DE efetivo: $DE_EFFECTIVE"
echo ">>> DM efetivo: $DM_EFFECTIVE"

case "$DM_EFFECTIVE" in
    lightdm)
        instalar_pacotes "dm-lightdm" lightdm lightdm-slick-greeter
        if ! dpkg -l lightdm-slick-greeter 2>/dev/null | grep -q "^ii"; then
            echo ">>> slick-greeter indisponivel - tentando lightdm-gtk-greeter..."
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
        echo ">>> AVISO: DM '$DM_EFFECTIVE' desconhecido - instalando lightdm."
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
    echo ">>> ERRO: nenhum display manager foi instalado com sucesso."
else
    echo ">>> Display manager instalado com sucesso."
fi

# ============================================================
# OCS Inventory Agent
# ============================================================
echo ">>> Instalando OCS Inventory Agent..."
if ! apt-get install -y ocsinventory-agent 2>/dev/null; then
    echo ">>> AVISO: Falha ao instalar ocsinventory-agent."
else
    echo ">>> OCS Inventory Agent instalado com sucesso"
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
echo ">>> Verificando instalacao existente do Firefox..."
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
    echo ">>> Firefox .deb nativo ja instalado. Nenhuma acao necessaria."
elif [ "$TEM_SNAP" = "true" ]; then
    # Snap presente — baixar tarball da Mozilla em /opt/firefox-moderno
    # (NAO remover o snap)
    echo ">>> Firefox snap detectado. Instalando tarball da Mozilla em /opt/firefox-moderno..."
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

        echo ">>> Firefox tarball instalado em /opt/firefox-moderno (snap mantido)."
    else
        echo ">>> AVISO: Falha ao baixar tarball do Firefox. Snap mantido."
    fi
else
    # Nenhum Firefox instalado — baixar tarball da Mozilla
    echo ">>> Nenhum Firefox detectado. Instalando tarball da Mozilla..."
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

        echo ">>> Firefox tarball instalado em /opt/firefox-moderno."
    else
        echo ">>> AVISO: Falha ao baixar tarball do Firefox."
        echo ">>> Tentando firefox-esr via apt..."
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
echo ">>> Detectando placa de video..."
if lspci | grep -qi nvidia; then
    echo ">>> Placa NVIDIA detectada. Instalando drivers..."
    apt-get install -y nvidia-driver-550 2>/dev/null || {
        echo ">>> AVISO: Falha ao instalar driver NVIDIA. Tentando ubuntu-drivers..."
        ubuntu-drivers autoinstall 2>/dev/null || true
    }
elif lspci | grep -qi amd; then
    echo ">>> Placa AMD detectada. Instalando drivers..."
    apt-get install -y mesa-utils xserver-xorg-video-amdgpu 2>/dev/null || true
else
    echo ">>> GPU NVIDIA/AMD nao detectada. Usando driver generico."
fi

# ============================================================
# Remover LibreOffice (opcional)
# ============================================================
if [ "{{REMOVER_LIBREOFFICE}}" = "true" ]; then
    echo ">>> Removendo LibreOffice..."
    apt-get remove --purge -y libreoffice* libreoffice-core libreoffice-common
fi

# ============================================================
# Limpar cache do APT
# ============================================================
echo ">>> Limpando cache do APT..."
apt-get clean
apt-get autoremove -y

echo ">>> [03] Pacotes essenciais instalados!"
echo "============================================================"
