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

source /usr/local/lib/seederlinux/diag.sh 2>/dev/null || true
SCRIPT_ID="04-packages"

echo "============================================================"
echo "Instalar pacotes essenciais"
echo "============================================================"

# ============================================================
# Variáveis
# ============================================================
REINSTALL_MODE="${REINSTALL_MODE:-auto}"
DESKTOP_ENV=""
INSTALL_DESKTOP="false"

case "$REINSTALL_MODE" in
    repair|diagnostic)
        log_nivel AVISO "REINSTALL_MODE=$REINSTALL_MODE ainda nao implementado - usando 'auto'"
        REINSTALL_MODE="auto"
        ;;
    auto|force) ;;
    *)
        log_nivel AVISO "REINSTALL_MODE desconhecido '$REINSTALL_MODE' - usando 'auto'"
        REINSTALL_MODE="auto"
        ;;
esac

log_nivel INFO "Ambiente grafico solicitado (opcional): $DESKTOP_ENV"
log_nivel INFO "Instalar ambiente grafico: $INSTALL_DESKTOP"
log_nivel INFO "REINSTALL_MODE: $REINSTALL_MODE"

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
    local faltando=()
    local pulados=0
    local pkg

    for pkg in "$@"; do
        if [ "$REINSTALL_MODE" = "auto" ] && dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
            pulados=$((pulados + 1))
            continue
        fi
        faltando+=("$pkg")
    done

    if [ "${#faltando[@]}" -eq 0 ]; then
        log_nivel INFO "[$grupo] todos os $# pacotes ja instalados - pulando"
        return 0
    fi

    log_nivel INFO "[$grupo] instalando ${#faltando[@]} de $# pacotes (pulados: $pulados)..."

    local falhou=0
    for pkg in "${faltando[@]}"; do
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
APT_STATE="/var/lib/seederlinux/last-apt-update"
mkdir -p /var/lib/seederlinux

_apt_recente=false
if [ "$REINSTALL_MODE" = "auto" ] && [ -f "$APT_STATE" ]; then
    _age=$(( $(date +%s) - $(stat -c %Y "$APT_STATE" 2>/dev/null || echo 0) ))
    if [ "$_age" -lt 86400 ]; then
        log_nivel INFO "apt-get update executado ha ${_age}s (<24h) - pulando (auto)"
        _apt_recente=true
    fi
fi

if [ "$_apt_recente" != "true" ]; then
    apt-get update
    apt-get -y upgrade
    touch "$APT_STATE"
fi

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

if [ "$REINSTALL_MODE" = "auto" ] && [ -x /opt/firefox-moderno/firefox ]; then
    log_nivel INFO "Firefox moderno ja instalado em /opt/firefox-moderno - pulando download (auto)"
elif [ "$TEM_DEB" = "true" ] && [ "$TEM_SNAP" != "true" ]; then
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
