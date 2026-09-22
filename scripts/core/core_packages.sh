#!/bin/bash
# ============================================================================
# Core Script: core_packages.sh
# SeederLinux Lite - Instalar pacotes essenciais
# ============================================================================
# Instala todos os pacotes necessarios para o funcionamento da estacao:
# ferramentas de rede, autenticacao, sistema grafico, utilitarios.
#
# CORRECOES NESTA VERSAO:
#   1. DE e DM/greeter ja eram instalados via instalar_pacotes (loop
#      per-package, tolerante a pacotes faltantes). Mas BASE_PACKAGES
#      ainda usava uma unica chamada atomica `apt-get install -y` -
#      se QUALQUER nome nao existisse na distro, o apt falhava e,
#      sob `set -e`, O BUNDLE INTEIRO ABORTAVA ali na etapa 03. Isso
#      aconteceu em teste real com Ubuntu 26.04: o pacote `policykit-1`
#      nao existe mais (foi renomeado para `polkitd` + `pkexec`), e o
#      bundle morreu sem chance de recuperacao. Agora BASE_PACKAGES
#      tambem usa instalar_pacotes.
#   2. policykit-1 convive com polkitd e pkexec na lista de base
#      packages. Em distros antigas (Debian 11, Ubuntu 20.04) so
#      `policykit-1` existe; em distros modernas (Ubuntu 22.04+,
#      Debian 12+) so `polkitd` e `pkexec`. Listar os tres e' seguro
#      porque instalar_pacotes tenta cada um e so emite AVISO para os
#      que nao existem.
#   3. `apt-get update` do topo ficou tolerante: se a OM tem um repo
#      com chave GPG faltando (ou rede instavel), o cache do apt
#      continua valido e o bundle pode seguir em frente. Antes, uma
#      falha aqui abortava tudo. Alinhado com a mesma decisao aplicada
#      no core_repositories.sh em modo PUBLIC.
#   4. `apt-get -y upgrade` permanece ESTRITO: se falhar (dpkg
#      travado, disco cheio, conflito de pacote), queremos saber.
#   5. Comentarios atualizados sobre o que e' virtual vs real
#      (dnsutils -> bind9-dnsutils no Ubuntu 24.04+).
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
#
# Esta funcao e' o padrao obrigatorio para instalacao de QUALQUER
# conjunto de pacotes neste script: itera um por um, emite AVISO
# para os que falharem, e NUNCA aborta o bundle inteiro por causa
# de um pacote individual que nao existe na distro.
#
# Motivo: nomes de pacote mudam entre versoes de distro
# (policykit-1 -> polkitd + pkexec, dnsutils -> bind9-dnsutils,
# etc). Uma chamada atomica com nome desatualizado derruba o
# bundle sob `set -e`, sem chance de recuperacao.
# ============================================================
instalar_pacotes() {
    # $1 = nome do grupo (so para o log), restante = lista de pacotes
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
#
# apt-get update: TOLERANTE. So refresca o cache do indice. Se um
#   repo especifico falhar (chave GPG faltando, rede instavel), o
#   cache antigo continua valido e podemos prosseguir. Mesma decisao
#   aplicada no core_repositories.sh em modo PUBLIC.
#
# apt-get -y upgrade: ESTRITO. Isso muda o sistema de verdade. Se
#   falhar (dpkg travado por outro processo, disco cheio, conflito),
#   queremos abortar com mensagem clara, nao seguir com estado
#   indefinido.
# ============================================================
echo ">>> Atualizando pacotes do sistema..."
export DEBIAN_FRONTEND=noninteractive
apt-get update || {
    echo ">>> AVISO: apt-get update retornou erro (repo com chave faltando? rede?)."
    echo ">>>        Prosseguindo com o cache do apt."
}
apt-get -y upgrade

# ============================================================
# Pacotes base do sistema
#
# Notas sobre nomes:
#   - dnsutils: no Ubuntu 24.04+ virou bind9-dnsutils, mas o apt
#     resolve automaticamente via pacote virtual (mensagem "Nota,
#     selecionando 'bind9-dnsutils' em vez de 'dnsutils'"). Pode
#     deixar o nome antigo.
#   - policykit-1: nome LEGADO, existe em Debian 11 / Ubuntu 20.04.
#     Em Ubuntu 22.04+ foi renomeado para polkitd + pkexec. Listamos
#     os tres; instalar_pacotes tenta cada um e ignora os ausentes.
#   - apt-transport-https: virou virtual nas distros modernas, mas
#     continua instalavel como transicional.
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
    dnsutils
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
    # policykit-1 (legado) + polkitd + pkexec (moderno) - ver
    # comentario acima. So um dos dois conjuntos vai existir.
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
)

instalar_pacotes "base" "${BASE_PACKAGES[@]}"

# ============================================================
# Garantir repositorio universe (necessario antes de auth e ocsinventory)
#
# add-apt-repository e' tolerante por natureza (`|| true`). O
# apt-get update apos adicionar universe tambem: se falhar por rede
# ou chave, seguimos.
# ============================================================
echo ">>> Garantindo repositorio universe..."
if command -v add-apt-repository &>/dev/null; then
    add-apt-repository -y universe 2>/dev/null || true
fi
apt-get update -qq || true

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
# Por padrao NAO instala DE. Somente instala se INSTALL_DESKTOP=true
# e DESKTOP_ENV estiver definido. Caso contrario, usa o ambiente
# grafico ja presente na estacao (detectado em DETECTED_DE).
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

    case "$DESKTOP_ENV" in
        cinnamon) command -v cinnamon-session &>/dev/null || echo ">>> AVISO: cinnamon-session nao encontrado apos instalacao." ;;
        mate)     command -v mate-session &>/dev/null || echo ">>> AVISO: mate-session nao encontrado apos instalacao." ;;
        gnome)    command -v gnome-session &>/dev/null || echo ">>> AVISO: gnome-session nao encontrado apos instalacao." ;;
        xfce)     command -v startxfce4 &>/dev/null || echo ">>> AVISO: startxfce4 nao encontrado apos instalacao." ;;
        kde)      command -v startplasma-x11 &>/dev/null || echo ">>> AVISO: startplasma-x11 nao encontrado apos instalacao." ;;
        lxqt)     command -v lxqt-session &>/dev/null || echo ">>> AVISO: lxqt-session nao encontrado apos instalacao." ;;
        lxde)     command -v startlxde &>/dev/null || echo ">>> AVISO: startlxde nao encontrado apos instalacao." ;;
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
    openjdk-8-jre
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

# ============================================================
# Display Manager + greeter
# ============================================================
# CORRECAO CRITICA (achado em teste real): os DMs precisam ser
# instalados AQUI (etapa 03, com DNS de internet ainda ativo) -
# porque os scripts de sessao (14a/14b/14c) rodam DEPOIS do ingresso
# no AD (core_domain.sh), quando o DNS ja foi trocado para apontar
# so pro controlador de dominio. Nesse ponto, apt-get nao consegue
# mais alcancar repositorios publicos - instalar o DM la (como o
# fluxo antigo fazia) falhava silenciosamente sem conectividade.
#
# Deteccao nessa ordem: DISPLAY_MANAGER/DESKTOP_ENV da OM -> deteccao
# em runtime na estacao -> mapeamento DE->DM padrao.
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
# OCS Inventory Agent (pacote critico para inventario)
# Instalado separadamente para garantir verificacao e diagnostico
# ============================================================
echo ">>> Instalando OCS Inventory Agent..."
if ! apt-get install -y ocsinventory-agent 2>/dev/null; then
    echo ">>> AVISO: Falha ao instalar ocsinventory-agent."
    echo ">>> Verifique se o repositorio universe esta habilitado."
    echo ">>> Comando manual: sudo add-apt-repository universe && sudo apt-get update && sudo apt-get install -y ocsinventory-agent"
else
    echo ">>> OCS Inventory Agent instalado com sucesso"
fi

# Firefox ESR com fallback para firefox
# Debian: firefox-esr. Ubuntu/Mint/Zorin: firefox.
# Cada tentativa e' tolerante; se nenhuma funcionar, seguimos.
apt-get install -y firefox-esr firefox-esr-l10n-pt-br 2>/dev/null || \
    apt-get install -y firefox firefox-l10n-pt-br 2>/dev/null || true

# Firmware opcional (varia por distro)
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
if [ "false" = "true" ]; then
    echo ">>> Removendo LibreOffice..."
    apt-get remove --purge -y libreoffice* libreoffice-core libreoffice-common
fi

# ============================================================
# Limpar cache do APT
# ============================================================
echo ">>> Limpando cache do APT..."
apt-get clean
apt-get autoremove -y 2>/dev/null || true

echo ">>> [03] Pacotes essenciais instalados!"
echo "============================================================"
