-- ============================================================================
-- SeederLinux Lite - Insercao dos Scripts Core
-- ============================================================================
-- Este arquivo popula a tabela 'scripts' com todos os scripts Core.
-- Gerado automaticamente a partir dos arquivos em scripts/core/.
--
-- ESCAPING: Usa dollar-quoting do PostgreSQL ($SeederScript$) para o conteudo
-- dos scripts, eliminando problemas com aspas simples, aspas duplas,
-- backslashes e qualquer outro caractere especial no bash.
-- ============================================================================

-- Limpar scripts core existentes (opcional - descomente se necessario)
-- DELETE FROM scripts WHERE is_core = TRUE;


-- ============================================================================
-- Configuracao de DNS (ordem 1) - core_dns.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, version, organization_id)
VALUES (
    'Configuracao de DNS',
    'core_dns.sh',
    'Configura DNS temporario, NTP e /etc/hosts. Roda ANTES de repositorios para permitir apt-get update.',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_dns.sh
# SeederLinux Lite - DNS, NTP e resolucao de nomes
# ============================================================================
# Configura DNS temporario para permitir resolucao durante o provisionamento,
# ajusta /etc/resolv.conf, /etc/hosts e sincroniza NTP.
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

# Remover protocolo indevido do NTP_SERVER
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
# DNS temporário (para permitir apt-get durante o provisionamento)
# ============================================================
echo ">>> Configurando DNS temporario (internet primeiro para baixar pacotes)..."
echo "nameserver $DNS_INTERNET" > /etc/resolv.conf
if [ -n "$DNS_PRIMARIO" ] && [ "$DNS_PRIMARIO" != "" ]; then
    echo "nameserver $DNS_PRIMARIO" >> /etc/resolv.conf
fi
if [ -n "$DNS_SECUNDARIO" ] && [ "$DNS_SECUNDARIO" != "" ]; then
    echo "nameserver $DNS_SECUNDARIO" >> /etc/resolv.conf
fi
echo "search $DOMINIO" >> /etc/resolv.conf
echo ">>> DNS temporario configurado"

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
$SeederScript$,
    TRUE,
    TRUE,
    1,
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Configuracao de Repositorios (ordem 2) - core_repositories.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, version, organization_id)
VALUES (
    'Configuracao de Repositorios',
    'core_repositories.sh',
    'Configura repositorios APT (oficial, espelho ou customizado) apos o DNS estar resolvendo.',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_repositories.sh
# SeederLinux Lite - Configurar sources.list (APT)
# ============================================================================
# Detecta a distribuicao (Debian, Ubuntu, Mint, Zorin) e configura os
# repositorios APT conforme o modo e as variaveis por distro:
#   REPOSITORY_DEBIAN_ENABLED / REPOSITORY_DEBIAN_URL
#   REPOSITORY_UBUNTU_ENABLED / REPOSITORY_UBUNTU_URL
#   REPOSITORY_MINT_ENABLED   / REPOSITORY_MINT_URL
#   REPOSITORY_ZORIN_ENABLED  / REPOSITORY_ZORIN_URL
# NUNCA altera sources.list se o modo for PUBLIC ou se o mirror da distro
# detectada nao estiver habilitado.
# Os placeholders VARIAVEL sao substituidos automaticamente
# pelo sistema na geracao do bundle.
# ============================================================================

set -e

echo "============================================================"
echo "02 - Configurar repositorios APT"
echo "============================================================"

# ============================================================
# Variaveis globais
# ============================================================
REPOSITORY_MODE="{{REPOSITORY_MODE}}"
REPOSITORY_URL="{{REPOSITORY_URL}}"
REPOSITORY_FALLBACK="{{REPOSITORY_FALLBACK}}"

# Variaveis por distro
REPOSITORY_DEBIAN_ENABLED="{{REPOSITORY_DEBIAN_ENABLED}}"
REPOSITORY_DEBIAN_URL="{{REPOSITORY_DEBIAN_URL}}"
REPOSITORY_UBUNTU_ENABLED="{{REPOSITORY_UBUNTU_ENABLED}}"
REPOSITORY_UBUNTU_URL="{{REPOSITORY_UBUNTU_URL}}"
REPOSITORY_MINT_ENABLED="{{REPOSITORY_MINT_ENABLED}}"
REPOSITORY_MINT_URL="{{REPOSITORY_MINT_URL}}"
REPOSITORY_ZORIN_ENABLED="{{REPOSITORY_ZORIN_ENABLED}}"
REPOSITORY_ZORIN_URL="{{REPOSITORY_ZORIN_URL}}"

echo ">>> Modo de repositorio: $REPOSITORY_MODE"

# ============================================================
# Detectar a distribuicao
# ============================================================
detect_distro() {
    if [ -f /etc/linuxmint/info ]; then
        echo "mint"
    elif [ -f /etc/zorin-release ]; then
        echo "zorin"
    elif grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
        echo "ubuntu"
    elif grep -qi "debian" /etc/os-release 2>/dev/null; then
        echo "debian"
    else
        echo "unknown"
    fi
}

DISTRO=$(detect_distro)
echo ">>> Distribuicao detectada: $DISTRO"

# ============================================================
# Backup do sources.list original
# ============================================================
backup_sources() {
    if [ -f /etc/apt/sources.list ]; then
        cp /etc/apt/sources.list /etc/apt/sources.list.bak.$(date +%Y%m%d%H%M%S)
        echo ">>> Backup do sources.list criado"
    fi
}

# ============================================================
# Obter codename da distro
# ============================================================
# CORRECAO: antes dependia exclusivamente de `lsb_release -cs`. O
# pacote que fornece esse comando (lsb-release) so e instalado no
# core_packages.sh, que roda na etapa 03 - mas este script (repos)
# roda na etapa 02, ANTES. Numa instalacao minima sem lsb_release
# presente, caia direto no fallback hardcoded (ex.: "noble"), que so
# acerta por coincidencia se a estacao realmente for essa versao -
# numa frota com versoes misturadas, aponta pro codename errado e
# quebra o apt-get update.
#
# Agora le VERSION_CODENAME direto de /etc/os-release primeiro: esse
# arquivo existe por padrao em qualquer Debian/Ubuntu/Mint/Zorin, sem
# precisar de nenhum pacote extra instalado, e reflete a versao real
# da estacao com mais confianca. lsb_release fica como segunda opcao
# (caso ja esteja instalado) e o parametro passado como ultimo
# fallback, igual antes.
get_codename() {
    local fallback="$1"
    local codename=""

    if [ -f /etc/os-release ]; then
        codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
    fi

    if [ -z "$codename" ] && command -v lsb_release &>/dev/null; then
        codename="$(lsb_release -cs 2>/dev/null)"
    fi

    if [ -z "$codename" ]; then
        echo ">>> AVISO: nao foi possivel determinar o codename real da estacao." >&2
        echo ">>> Usando fallback hardcoded: $fallback" >&2
        codename="$fallback"
    fi

    echo "$codename"
}

# ============================================================
# Configuracao conforme o modo
# ============================================================
case "$REPOSITORY_MODE" in
    PUBLIC|"")
        echo ">>> Modo PUBLIC: mantendo repositorios padrao da distribuicao ($DISTRO)."
        echo ">>> Nenhuma alteracao em sources.list foi feita."
        ;;

    MIRROR|HYBRID)
        case "$DISTRO" in
            debian)
                if [ "${REPOSITORY_DEBIAN_ENABLED:-false}" = "true" ] && [ -n "${REPOSITORY_DEBIAN_URL:-}" ]; then
                    echo ">>> Configurando mirror Debian: $REPOSITORY_DEBIAN_URL"
                    backup_sources
                    DEBIAN_CODENAME=$(get_codename trixie)
                    cat > /etc/apt/sources.list <<EOF
deb $REPOSITORY_DEBIAN_URL/debian $DEBIAN_CODENAME main contrib non-free non-free-firmware
deb $REPOSITORY_DEBIAN_URL/debian-security $DEBIAN_CODENAME-security main contrib non-free non-free-firmware
deb $REPOSITORY_DEBIAN_URL/debian $DEBIAN_CODENAME-updates main contrib non-free non-free-firmware
EOF
                    if [ "$REPOSITORY_MODE" = "HYBRID" ] && [ -n "$REPOSITORY_FALLBACK" ]; then
                        echo ">>> Adicionando fallback Debian..."
                        cat >> /etc/apt/sources.list <<EOF
deb $REPOSITORY_FALLBACK/debian $DEBIAN_CODENAME main contrib non-free non-free-firmware
deb $REPOSITORY_FALLBACK/debian-security $DEBIAN_CODENAME-security main contrib non-free non-free-firmware
deb $REPOSITORY_FALLBACK/debian $DEBIAN_CODENAME-updates main contrib non-free non-free-firmware
EOF
                    fi
                else
                    echo ">>> Mirror Debian nao habilitado. Mantendo repositorios oficiais."
                fi
                ;;

            ubuntu)
                if [ "${REPOSITORY_UBUNTU_ENABLED:-false}" = "true" ] && [ -n "${REPOSITORY_UBUNTU_URL:-}" ]; then
                    echo ">>> Configurando mirror Ubuntu: $REPOSITORY_UBUNTU_URL"
                    backup_sources
                    UBUNTU_CODENAME=$(get_codename noble)
                    cat > /etc/apt/sources.list <<EOF
deb $REPOSITORY_UBUNTU_URL/ubuntu $UBUNTU_CODENAME main restricted universe multiverse
deb $REPOSITORY_UBUNTU_URL/ubuntu $UBUNTU_CODENAME-updates main restricted universe multiverse
deb $REPOSITORY_UBUNTU_URL/ubuntu $UBUNTU_CODENAME-security main restricted universe multiverse
EOF
                    if [ "$REPOSITORY_MODE" = "HYBRID" ] && [ -n "$REPOSITORY_FALLBACK" ]; then
                        echo ">>> Adicionando fallback Ubuntu..."
                        cat >> /etc/apt/sources.list <<EOF
deb $REPOSITORY_FALLBACK/ubuntu $UBUNTU_CODENAME main restricted universe multiverse
deb $REPOSITORY_FALLBACK/ubuntu $UBUNTU_CODENAME-updates main restricted universe multiverse
deb $REPOSITORY_FALLBACK/ubuntu $UBUNTU_CODENAME-security main restricted universe multiverse
EOF
                    fi
                else
                    echo ">>> Mirror Ubuntu nao habilitado. Mantendo repositorios oficiais."
                fi
                ;;

            mint)
                MINT_CODENAME=$(get_codename wilma)
                UBUNTU_CODENAME=$(grep UBUNTU_CODENAME /etc/linuxmint/info 2>/dev/null | cut -d= -f2 || echo noble)
                MINT_OK=false

                if [ "${REPOSITORY_MINT_ENABLED:-false}" = "true" ] && [ -n "${REPOSITORY_MINT_URL:-}" ]; then
                    MINT_OK=true
                fi

                if [ "$MINT_OK" = "true" ]; then
                    echo ">>> Configurando mirror Mint: $REPOSITORY_MINT_URL"
                    backup_sources
                    cat > /etc/apt/sources.list <<EOF
deb $REPOSITORY_MINT_URL/mint $MINT_CODENAME main upstream import backport
EOF
                    if [ "${REPOSITORY_UBUNTU_ENABLED:-false}" = "true" ] && [ -n "${REPOSITORY_UBUNTU_URL:-}" ]; then
                        echo ">>> Configurando mirror Ubuntu base para Mint: $REPOSITORY_UBUNTU_URL"
                        cat >> /etc/apt/sources.list <<EOF
deb $REPOSITORY_UBUNTU_URL/ubuntu $UBUNTU_CODENAME main restricted universe multiverse
deb $REPOSITORY_UBUNTU_URL/ubuntu $UBUNTU_CODENAME-updates main restricted universe multiverse
deb $REPOSITORY_UBUNTU_URL/ubuntu $UBUNTU_CODENAME-security main restricted universe multiverse
EOF
                    else
                        echo ">>> Mirror Ubuntu nao habilitado. Mantendo repositorios oficiais do Ubuntu base."
                        cat >> /etc/apt/sources.list <<EOF
deb http://archive.ubuntu.com/ubuntu $UBUNTU_CODENAME main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu $UBUNTU_CODENAME-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu $UBUNTU_CODENAME-security main restricted universe multiverse
EOF
                    fi

                    if [ "$REPOSITORY_MODE" = "HYBRID" ] && [ -n "$REPOSITORY_FALLBACK" ]; then
                        echo ">>> Adicionando fallback..."
                        cat >> /etc/apt/sources.list <<EOF
deb $REPOSITORY_FALLBACK/mint $MINT_CODENAME main upstream import backport
deb $REPOSITORY_FALLBACK/ubuntu $UBUNTU_CODENAME main restricted universe multiverse
deb $REPOSITORY_FALLBACK/ubuntu $UBUNTU_CODENAME-updates main restricted universe multiverse
deb $REPOSITORY_FALLBACK/ubuntu $UBUNTU_CODENAME-security main restricted universe multiverse
EOF
                    fi
                else
                    echo ">>> Mirror Mint nao habilitado. Mantendo repositorios oficiais."
                fi
                ;;

            zorin)
                if [ "${REPOSITORY_ZORIN_ENABLED:-false}" = "true" ] && [ -n "${REPOSITORY_ZORIN_URL:-}" ]; then
                    echo ">>> Configurando mirror Zorin: $REPOSITORY_ZORIN_URL"
                    backup_sources
                    UBUNTU_CODENAME=$(get_codename jammy)
                    cat > /etc/apt/sources.list <<EOF
deb $REPOSITORY_ZORIN_URL/ubuntu $UBUNTU_CODENAME main restricted universe multiverse
deb $REPOSITORY_ZORIN_URL/ubuntu $UBUNTU_CODENAME-updates main restricted universe multiverse
deb $REPOSITORY_ZORIN_URL/ubuntu $UBUNTU_CODENAME-security main restricted universe multiverse
EOF
                    if [ "$REPOSITORY_MODE" = "HYBRID" ] && [ -n "$REPOSITORY_FALLBACK" ]; then
                        echo ">>> Adicionando fallback Zorin..."
                        cat >> /etc/apt/sources.list <<EOF
deb $REPOSITORY_FALLBACK/ubuntu $UBUNTU_CODENAME main restricted universe multiverse
deb $REPOSITORY_FALLBACK/ubuntu $UBUNTU_CODENAME-updates main restricted universe multiverse
deb $REPOSITORY_FALLBACK/ubuntu $UBUNTU_CODENAME-security main restricted universe multiverse
EOF
                    fi
                else
                    echo ">>> Mirror Zorin nao habilitado. Mantendo repositorios oficiais."
                fi
                ;;

            *)
                echo ">>> Distribuicao nao reconhecida. Mantendo sources.list padrao."
                ;;
        esac
        ;;

    CUSTOM)
        if [ -z "$REPOSITORY_URL" ] || [ "$REPOSITORY_URL" = "" ]; then
            echo ">>> ERRO: REPOSITORY_URL nao definido para modo CUSTOM"
            read -p ">>> Deseja continuar mesmo assim? (S/n): " CONTINUE
            if [[ "$CONTINUE" =~ ^[Nn]$ ]]; then
                echo ">>> Instalacao abortada pelo usuario."
                exit 1
            fi
            echo ">>> Continuando apesar do erro..."
        fi

        echo ">>> Configurando repositorio personalizado"
        backup_sources

        cat > /etc/apt/sources.list <<EOF
$REPOSITORY_URL
EOF
        ;;

    *)
        echo ">>> ERRO: Modo de repositorio invalido: $REPOSITORY_MODE"
        read -p ">>> Deseja continuar mesmo assim? (S/n): " CONTINUE
        if [[ "$CONTINUE" =~ ^[Nn]$ ]]; then
            echo ">>> Instalacao abortada pelo usuario."
            exit 1
        fi
        echo ">>> Continuando apesar do erro..."
        ;;
esac

# ============================================================
# Atualizar indice de pacotes
# ============================================================
echo ">>> Atualizando apt-get update..."
apt-get update

echo ">>> [02] Repositorios configurados com sucesso!"
echo "============================================================"
$SeederScript$,
    TRUE,
    TRUE,
    2,
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Instalacao de Pacotes (ordem 3) - core_packages.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, version, organization_id)
VALUES (
    'Instalacao de Pacotes',
    'core_packages.sh',
    'Instala TODOS os pacotes necessarios (sistema, OCS, CUPS, VNC, Conky, Java, etc).',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_packages.sh
# SeederLinux Lite - Instalar pacotes essenciais
# ============================================================================
# Instala todos os pacotes necessarios para o funcionamento da estacao:
# ferramentas de rede, autenticacao, sistema grafico, utilitarios.
#
# CORRECAO: a instalacao do ambiente grafico (DE) antes era uma unica
# chamada atomica "apt-get install -y pacote1 pacote2 pacote3" sem
# fallback. Como este script roda no nivel raiz do bundle (sem
# subshell) sob `set -e`, se QUALQUER nome de pacote estivesse errado,
# obsoleto ou renomeado numa versao mais nova da distro, o apt-get
# falhava e O BUNDLE INTEIRO ABORTAVA ali, na etapa 03 - nunca chegando
# no ingresso AD, sessao, etc. Agora a instalacao de DE segue o mesmo
# padrao ja usado em AUTH_PACKAGES: loop pacote a pacote, avisa e
# continua em vez de derrubar o bundle.
#
# Os placeholders VARIAVEL são substituídos automaticamente
# pelo sistema na geração do bundle.
# ============================================================================

set -e

echo "============================================================"
echo "03 - Instalar pacotes essenciais"
echo "============================================================"

# ============================================================
# Variáveis
# ============================================================
DESKTOP_ENV="{{DESKTOP_ENV}}"
INSTALL_DESKTOP="{{INSTALL_DESKTOP}}"

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
# Instalar pacotes com fallback por item (nao aborta o bundle
# se um pacote individual nao existir/falhar)
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
    policykit-1
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

apt-get install -y "${BASE_PACKAGES[@]}"

# ============================================================
# Garantir repositorio universe (necessario antes de auth e ocsinventory)
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
# Por padrao NAO instala DE. Somente instala se INSTALL_DESKTOP=true
# e DESKTOP_ENV estiver definido. Caso contrario, usa o ambiente
# grafico ja presente na estacao (detectado em DETECTED_DE).
#
# Cada DE instala pacote a pacote (instalar_pacotes) em vez de uma
# unica chamada atomica: se um nome de pacote estiver errado/renomeado
# numa versao mais nova da distro, avisa e continua os demais, em vez
# de abortar o bundle inteiro.
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

    # Verificacao pos-instalacao: alerta se, mesmo apos o loop, o DE
    # pedido continua ausente (ajuda a diagnosticar nomes de pacote
    # desatualizados sem precisar vasculhar o log inteiro)
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
$SeederScript$,
    TRUE,
    TRUE,
    3,
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Suporte a Sistemas Legados (ordem 4) - core_legados.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, version, organization_id)
VALUES (
    'Suporte a Sistemas Legados',
    'core_legados.sh',
    'Instala Java 8 e Firefox 52 ESR para compatibilidade com sistemas legados.',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_legados.sh
# SeederLinux Lite - Java 8, Firefox 52.7 ESR (sistemas legados)
# ============================================================================
# Instala Java 8 (OpenJDK) e/ou Firefox 52.7 ESR para compatibilidade
# com sistemas legados (applets Java, sistemas antigos da intranet).
# Cada componente e controlado por seu proprio toggle:
#   INSTALL_JAVA8     - Instalar Java 8?
#   INSTALL_FIREFOX52 - Instalar Firefox 52.7 ESR?
# Os placeholders VARIAVEL sao substituidos automaticamente
# pelo sistema na geracao do bundle.
# Executado ANTES de core_domain.sh para evitar erro 407 de proxy.
# ============================================================================

(
set -e

echo "============================================================"
echo "05 - Configurar sistemas legados (Java 8, Firefox 52.7)"
echo "============================================================"

# ============================================================
# Variaveis
# ============================================================
INSTALL_JAVA8="{{INSTALL_JAVA8}}"
INSTALL_FIREFOX52="{{INSTALL_FIREFOX52}}"
BASE_URL="{{BASE_URL}}"
PROXY_MODE="{{PROXY_MODE}}"
PROXY_HTTP="{{PROXY_HTTP}}"
PROXY_PORTA="{{PROXY_PORTA}}"
JAVA_EXCEPTIONS="{{JAVA_EXCEPTIONS}}"

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

# Configurar proxy para downloads
##if [ "$PROXY_MODE" = "MANUAL" ] && [ -n "$PROXY_HTTP" ] && [ "$PROXY_HTTP" != "" ]; then
##    export http_proxy="http://${PROXY_HTTP}:${PROXY_PORTA}"
##   export https_proxy="http://${PROXY_HTTP}:${PROXY_PORTA}"
##fi

# ============================================================
# Java 8 (OpenJDK 8) - apenas se INSTALL_JAVA8=true
# ============================================================
if [ "$INSTALL_JAVA8" = "true" ]; then
    echo ">>> Instalando Java 8 (OpenJDK 8)..."

    if command -v java &>/dev/null; then
        JAVA_VERSION=$(java -version 2>&1 | head -1)
        echo ">>> Java ja instalado: $JAVA_VERSION"
    else
        echo ">>> AVISO: Java 8 nao foi instalado no core_packages.sh."
        echo ">>> Tentando instalar via repositorio Adoptium/Temurin..."

        if wget -q -O /tmp/adoptium-key.asc "https://packages.adoptium.net/artifactory/api/gpg/key/public" 2>/dev/null; then
            gpg --dearmor < /tmp/adoptium-key.asc > /usr/share/keyrings/adoptium-keyring.gpg 2>/dev/null || true

            # CORRECAO: "bookworm" (codename Debian) estava fixo aqui,
            # mesmo rodando em Ubuntu/Mint/Zorin - o Adoptium tem suites
            # por distro/codename de verdade, entao isso podia causar
            # apt-get update falhando (404) ou puxando pacote
            # incompativel. Mesma tecnica ja usada no core_repositories.sh:
            # ler VERSION_CODENAME de /etc/os-release em vez de chutar.
            ADOPTIUM_CODENAME=""
            if [ -f /etc/os-release ]; then
                ADOPTIUM_CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
            fi
            [ -z "$ADOPTIUM_CODENAME" ] && command -v lsb_release &>/dev/null && \
                ADOPTIUM_CODENAME="$(lsb_release -cs 2>/dev/null)"
            if [ -z "$ADOPTIUM_CODENAME" ]; then
                echo ">>> AVISO: nao foi possivel detectar o codename da distro."
                echo ">>> Usando fallback: bookworm (pode falhar se nao for Debian)"
                ADOPTIUM_CODENAME="bookworm"
            fi
            echo ">>> Codename detectado para o repositorio Adoptium: $ADOPTIUM_CODENAME"

            echo "deb [signed-by=/usr/share/keyrings/adoptium-keyring.gpg] https://packages.adoptium.net/artifactory/deb ${ADOPTIUM_CODENAME} main" \
                > /etc/apt/sources.list.d/adoptium.list
            apt-get update
            apt-get install -y temurin-8-jre || {
                echo ">>> AVISO: Falha ao instalar Java 8 via Adoptium."
                echo ">>> Verifique se o Adoptium tem suporte ao codename '$ADOPTIUM_CODENAME'."
            }
            rm -f /tmp/adoptium-key.asc
        else
            echo ">>> AVISO: Nao foi possivel obter chave do repositorio Java 8."
        fi
    fi

    # Configurar excecoes Java (deployment.properties) se fornecidas
    if [ -n "$JAVA_EXCEPTIONS" ] && [ "$JAVA_EXCEPTIONS" != "" ]; then
        echo ">>> Configurando excecoes Java..."
        DEPLOY_DIR="/usr/lib/jvm/.deployment"
        mkdir -p "$DEPLOY_DIR"
        DEPLOY_FILE="$DEPLOY_DIR/deployment.properties"
        echo "# Excecoes Java - SeederLinux" > "$DEPLOY_FILE"
        echo "deployment.security.level=MEDIUM" >> "$DEPLOY_FILE"

        IFS=$'\n,' read -ra EXC_URLS <<< "$JAVA_EXCEPTIONS"
        IDX=0
        for EXC_URL in "${EXC_URLS[@]}"; do
            EXC_URL=$(echo "$EXC_URL" | xargs)
            if [ -n "$EXC_URL" ] && [ "$EXC_URL" != "" ]; then
                echo "javaws.allow.${IDX}=$EXC_URL" >> "$DEPLOY_FILE"
                IDX=$((IDX+1))
            fi
        done
        echo ">>> Excecoes Java configuradas ($IDX URLs)"
    fi

    if command -v java &>/dev/null; then
        JAVA_VERSION=$(java -version 2>&1 | head -1)
        echo ">>> Java instalado: $JAVA_VERSION"
    else
        echo ">>> AVISO: Java nao instalado."
    fi
else
    echo ">>> Java 8 desativado (INSTALL_JAVA8=false). Pulando."
fi

# ============================================================
# Firefox 52.7 ESR (para applets Java) - apenas se INSTALL_FIREFOX52=true
# ============================================================
if [ "$INSTALL_FIREFOX52" = "true" ]; then
    echo ">>> Instalando Firefox 52.7 ESR..."

    FF_LEGADO_DIR="/opt/firefox-legado"
    FF_LEGADO_TARBALL="/tmp/firefox-52.7-esr.tar.bz2"
    FF_LEGADO_URL="${BASE_URL}/downloads/firefox-52.7.3esr.tar.bz2"

    mkdir -p /opt

    if wget -q -O "$FF_LEGADO_TARBALL" "$FF_LEGADO_URL" 2>/dev/null; then
        echo ">>> Firefox 52.7 baixado do repositorio interno"
        tar xjf "$FF_LEGADO_TARBALL" -C /opt/
        mv /opt/firefox "$FF_LEGADO_DIR" 2>/dev/null || true
        rm -f "$FF_LEGADO_TARBALL"
    else
        echo ">>> AVISO: Nao foi possivel baixar Firefox 52.7 do repositorio interno."
        echo ">>> Tentando download da Mozilla..."

        FF_MOZILLA_URL="https://ftp.mozilla.org/pub/firefox/releases/52.7.3esr/linux-x86_64/en-US/firefox-52.7.3esr.tar.bz2"
        if wget -q -O "$FF_LEGADO_TARBALL" "$FF_MOZILLA_URL" 2>/dev/null; then
            tar xjf "$FF_LEGADO_TARBALL" -C /opt/
            mv /opt/firefox "$FF_LEGADO_DIR" 2>/dev/null || true
            rm -f "$FF_LEGADO_TARBALL"
        else
            echo ">>> AVISO: Nao foi possivel baixar Firefox 52.7."
        fi
    fi

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
        echo ">>> Entrada de desktop criada"
    else
        echo ">>> AVISO: Firefox 52.7 ESR nao instalado."
    fi

    echo ">>> Configurando plugin Java para Firefox legado..."
    if [ -d "$FF_LEGADO_DIR" ] && command -v java &>/dev/null; then
        JAVA_HOME_DIR=$(dirname $(dirname $(readlink -f $(which java))))
        PLUGIN_DIR="${FF_LEGADO_DIR}/browser/plugins"
        mkdir -p "$PLUGIN_DIR"

        find "$JAVA_HOME_DIR" -name "libnpjp2.so" -exec ln -sf {} "$PLUGIN_DIR/libnpjp2.so" \; 2>/dev/null || {
            echo ">>> AVISO: Plugin Java (libnpjp2.so) nao encontrado."
        }
        echo ">>> Plugin Java configurado"
    fi
else
    echo ">>> Firefox 52.7 desativado (INSTALL_FIREFOX52=false). Pulando."
fi

echo ">>> [05] Sistemas legados configurados!"
echo "============================================================"
)
$SeederScript$,
    TRUE,
    TRUE,
    4,
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Instalacao de Aplicacoes Extras (ordem 5) - core_apps.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, version, organization_id)
VALUES (
    'Instalacao de Aplicacoes Extras',
    'core_apps.sh',
    'Instala aplicacoes extras (OnlyOffice, Chrome, etc).',
    $SeederScript$#!/bin/bash
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
$SeederScript$,
    TRUE,
    TRUE,
    5,
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Ingresso em Dominio AD (ordem 6) - core_domain.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, version, organization_id)
VALUES (
    'Ingresso em Dominio AD',
    'core_domain.sh',
    'Ingressa a estacao no Active Directory (SSSD/Winbind com fallback).',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_domain.sh (v3 - State Machine)
# SeederLinux Lite - Gerenciador de Estado do Active Directory
# ============================================================================
# Implementa uma máquina de estados para diagnosticar, classificar e
# corrigir o ingresso no AD, suportando SSSD (realm join) e Winbind
# (net ads join) como fallback.
#
# Estagios: 1) Diagnostico  2) Classificacao  3) Decisao
#           4) Execucao (somente se necessario)  5) Pos-ingresso + Validacao
#
# Os placeholders {{VARIAVEL}} sao substituidos automaticamente
# pelo sistema na geracao do bundle. Variaveis sensiveis usam o
# formato __VARIAVEL__ (substituicao separada, nunca em texto plano
# no restante do bundle).
# ============================================================================

set -e

echo "============================================================"
echo "04 - Gerenciador de Estado do Active Directory"
echo "============================================================"

# ============================================================
# Variáveis (substituídas no bundle)
# ============================================================
DOMINIO="{{DOMINIO}}"
DOMINIO_NETBIOS="{{DOMINIO_NETBIOS}}"
DC_IP="{{DC_IP}}"
DC_IP_LIST="{{DC_IP_LIST}}"
DNS_PRIMARIO="{{DNS_PRIMARIO}}"
DNS_SECUNDARIO="{{DNS_SECUNDARIO}}"
OU_PADRAO="{{OU_PADRAO}}"
GRUPO_ADMIN="{{GRUPO_ADMIN}}"
GRUPO_ADMIN_AD="{{GRUPO_ADMIN_AD}}"
GRUPO_ADMIN_LINUX="{{GRUPO_ADMIN_LINUX}}"
GRUPO_DASTI="{{GRUPO_DASTI}}"
OFFLINE_AUTH_ENABLED="{{OFFLINE_AUTH_ENABLED}}"
OFFLINE_AUTH_DAYS="{{OFFLINE_AUTH_DAYS}}"
ADMIN_USERNAME="{{ADMIN_USERNAME}}"
ADMIN_PASSWORD_B64="__ADMIN_PASSWORD_B64__"
AUTH_METHOD="{{AUTH_METHOD}}"

# ============================================================
# Checagem de sanidade: o backend PHP deve ter substituido os
# placeholders criticos antes de gerar o bundle. Se algum deles
# aparecer literal aqui, e bug do backend (nao deste script) -
# abortar cedo com mensagem clara em vez de deixar o kinit falhar
# silenciosamente mais adiante.
# ============================================================
if [[ "$ADMIN_USERNAME" == *"{{"* ]]; then
    echo ">>> ERRO: placeholder ADMIN_USERNAME nao foi substituido pelo backend."
    exit 1
fi
if [[ "$ADMIN_PASSWORD_B64" == "__"* && "$ADMIN_PASSWORD_B64" == *"__" ]]; then
    echo ">>> ERRO: placeholder ADMIN_PASSWORD_B64 nao foi substituido pelo backend."
    exit 1
fi

ADMIN_PASSWORD=""
if [ -n "$ADMIN_PASSWORD_B64" ]; then
    ADMIN_PASSWORD=$(printf '%s' "$ADMIN_PASSWORD_B64" | base64 -d 2>/dev/null) || ADMIN_PASSWORD=""
fi
unset ADMIN_PASSWORD_B64

NON_INTERACTIVE="${NON_INTERACTIVE:-false}"
if [ "$NON_INTERACTIVE" = "true" ]; then
    echo ">>> Modo não interativo ativado."
fi

echo ">>> Dominio: $DOMINIO"
echo ">>> NetBIOS: $DOMINIO_NETBIOS"
echo ">>> DC principal: $DC_IP"
[ -n "$DC_IP_LIST" ] && echo ">>> DCs adicionais: $DC_IP_LIST"

# ============================================================
# ESTÁGIO 1: DIAGNÓSTICO
# ============================================================
echo "============================================================"
echo ">>> ESTÁGIO 1: Diagnóstico do ambiente AD"
echo "============================================================"

# Funções de diagnóstico
check_dns() {
    if host "$DOMINIO" > /dev/null 2>&1; then
        echo "DNS............. OK ($DOMINIO resolve)"
        return 0
    else
        echo "DNS............. FALHA ($DOMINIO não resolve)"
        return 1
    fi
}

check_kerberos_config() {
    if [ -f /etc/krb5.conf ]; then
        echo "Kerberos........ OK (configurado)"
        return 0
    else
        echo "Kerberos........ FALHA (não configurado)"
        return 1
    fi
}

check_ticket() {
    if klist -s 2>/dev/null; then
        echo "Ticket.......... OK ($(klist | grep 'Default principal' | awk '{print $3}'))"
        return 0
    else
        echo "Ticket.......... NÃO (sem ticket ativo)"
        return 1
    fi
}

check_realm() {
    if realm list 2>/dev/null | grep -q "$DOMINIO"; then
        echo "Realm........... OK (associado)"
        return 0
    else
        echo "Realm........... NÃO (não associado)"
        return 1
    fi
}

check_sssd() {
    if systemctl is-active --quiet sssd 2>/dev/null; then
        echo "SSSD............ OK (ativo)"
        return 0
    else
        echo "SSSD............ NÃO (parado)"
        return 1
    fi
}

check_winbind() {
    if systemctl is-active --quiet winbind 2>/dev/null; then
        echo "Winbind......... OK (ativo)"
        return 0
    else
        echo "Winbind......... NÃO (parado)"
        return 1
    fi
}

check_keytab() {
    if [ -f /etc/krb5.keytab ] && [ -s /etc/krb5.keytab ]; then
        echo "Keytab.......... OK (presente)"
        return 0
    else
        echo "Keytab.......... NÃO (ausente ou vazio)"
        return 1
    fi
}

check_machine_account() {
    if net ads testjoin > /dev/null 2>&1; then
        echo "Conta AD........ OK (verificada)"
        return 0
    else
        if adcli testjoin --domain="$DOMINIO" > /dev/null 2>&1; then
            echo "Conta AD........ OK (adcli)"
            return 0
        else
            echo "Conta AD........ NÃO (não verificada)"
            return 1
        fi
    fi
}

check_time_sync() {
    if timedatectl status 2>/dev/null | grep -q "synchronized: yes"; then
        echo "Sinc. Tempo..... OK"
        return 0
    else
        echo "Sinc. Tempo..... NÃO (pode afetar Kerberos)"
        return 1
    fi
}

# Executar diagnóstico
echo ""
echo "--- Coletando informações ---"
DNS_OK=true && check_dns || DNS_OK=false
KRB5_OK=true && check_kerberos_config || KRB5_OK=false
TICKET_OK=true && check_ticket || TICKET_OK=false
REALM_OK=true && check_realm || REALM_OK=false
SSSD_OK=true && check_sssd || SSSD_OK=false
WINBIND_OK=true && check_winbind || WINBIND_OK=false
KEYTAB_OK=true && check_keytab || KEYTAB_OK=false
MACHINE_OK=true && check_machine_account || MACHINE_OK=false
TIME_OK=true && check_time_sync || TIME_OK=false
echo "================================"

# ============================================================
# Helpers de saida do dominio - sempre com senha via stdin (ou
# /dev/null se nao houver) para nunca ficar esperando prompt
# interativo em execucao via cron/push remoto.
# ============================================================
realm_leave_safe() {
    if [ -n "$ADMIN_PASSWORD" ]; then
        echo "$ADMIN_PASSWORD" | realm leave "$DOMINIO" -U "$ADMIN_USERNAME" 2>/dev/null || true
    else
        realm leave "$DOMINIO" -U "$ADMIN_USERNAME" < /dev/null 2>/dev/null || true
    fi
}

net_ads_leave_safe() {
    if [ -n "$ADMIN_PASSWORD" ]; then
        echo "$ADMIN_PASSWORD" | net ads leave -U "$ADMIN_USERNAME" 2>/dev/null || true
    else
        net ads leave -U "$ADMIN_USERNAME" < /dev/null 2>/dev/null || true
    fi
}

# ============================================================
# ESTÁGIO 2: CLASSIFICAR ESTADO
# ============================================================
echo ""
echo ">>> ESTÁGIO 2: Classificando estado atual"

if [ "$REALM_OK" = "true" ] && [ "$SSSD_OK" = "true" ] && [ "$KEYTAB_OK" = "true" ]; then
    if [ "$WINBIND_OK" = "true" ]; then
        ESTADO="INGRESSADO_HIBRIDO"
    else
        ESTADO="INGRESSADO_SSSD"
    fi
elif [ "$WINBIND_OK" = "true" ] && [ "$MACHINE_OK" = "true" ]; then
    ESTADO="INGRESSADO_WINBIND"
elif [ "$REALM_OK" = "false" ] && [ "$WINBIND_OK" = "false" ] && [ "$MACHINE_OK" = "false" ] && [ "$KEYTAB_OK" = "false" ]; then
    ESTADO="NAO_INGRESSADO"
elif [ "$REALM_OK" = "true" ] && [ "$KEYTAB_OK" = "false" ]; then
    ESTADO="CORROMPIDO"
elif [ "$REALM_OK" = "true" ] && [ "$SSSD_OK" = "false" ]; then
    ESTADO="PARCIAL"
elif [ "$MACHINE_OK" = "true" ] || [ "$KEYTAB_OK" = "true" ]; then
    # Ha vestigios de um ingresso anterior (conta AD e/ou keytab) que nao
    # bate com nenhum padrao "limpo" acima - tratar como CORROMPIDO em vez
    # de INDETERMINADO, para passar pela limpeza (leave + remove keytab)
    # antes de tentar um join novo. Evita duplicar a conta no AD.
    ESTADO="CORROMPIDO"
else
    ESTADO="INDETERMINADO"
fi

echo ">>> Estado detectado: $ESTADO"

# ============================================================
# Bloqueio preventivo: DNS/tempo quebrados antes de tentar ingresso
# Kerberos depende diretamente dos dois - sem isso, kinit/realm join
# falham de forma confusa la na frente. Avisamos aqui, cedo.
# ============================================================
if [ "$ESTADO" = "NAO_INGRESSADO" ] || [ "$ESTADO" = "INDETERMINADO" ]; then
    if [ "$DNS_OK" = "false" ] || [ "$TIME_OK" = "false" ]; then
        echo ""
        echo ">>> AVISO: pre-requisitos do Kerberos com problema:"
        [ "$DNS_OK" = "false" ] && echo "    - DNS nao resolve $DOMINIO (verifique DC_IP/DNS_PRIMARIO)"
        [ "$TIME_OK" = "false" ] && echo "    - Relogio fora de sincronia (Kerberos rejeita diferenca > 5min)"
        if [ "$NON_INTERACTIVE" = "true" ]; then
            echo ">>> Modo nao interativo: prosseguindo mesmo assim (provavel falha adiante)."
        else
            read -p ">>> Deseja continuar mesmo assim? (s/N): " CONTINUE_APESAR_DE
            if [[ ! "$CONTINUE_APESAR_DE" =~ ^[Ss]$ ]]; then
                echo ">>> Instalação abortada pelo usuário."
                exit 1
            fi
        fi
    fi
fi

# ============================================================
# ESTÁGIO 3: DECISÃO
# ============================================================
echo ""
echo ">>> ESTÁGIO 3: Decisão sobre ação necessária"

case "$ESTADO" in
    INGRESSADO_SSSD|INGRESSADO_HIBRIDO)
        echo ">>> A máquina já está ingressada via SSSD."
        if [ "$NON_INTERACTIVE" = "true" ]; then
            REINGRESSAR="n"
        else
            read -p ">>> Deseja reingressar (remover e ingressar novamente)? (s/N): " REINGRESSAR
        fi
        if [[ "$REINGRESSAR" =~ ^[Ss]$ ]]; then
            echo ">>> Removendo ingresso existente..."
            realm_leave_safe
            net_ads_leave_safe
            ESTADO="NAO_INGRESSADO"
        else
            echo ">>> Mantendo ingresso existente. Pulando ingresso."
        fi
        ;;

    INGRESSADO_WINBIND)
        echo ">>> A máquina está ingressada via Winbind (método legado)."
        echo ">>> Recomenda-se migrar para SSSD."
        if [ "$NON_INTERACTIVE" = "true" ]; then
            MIGRAR="s"
        else
            read -p ">>> Deseja migrar para SSSD (remover Winbind e ingressar via realm)? (S/n): " MIGRAR
        fi
        if [[ ! "$MIGRAR" =~ ^[Nn]$ ]]; then
            echo ">>> Removendo ingresso Winbind..."
            net_ads_leave_safe
            systemctl stop winbind 2>/dev/null || true
            ESTADO="NAO_INGRESSADO"
        else
            echo ">>> Mantendo Winbind. Pulando ingresso."
        fi
        ;;

    CORROMPIDO|PARCIAL)
        echo ">>> AVISO: Estado inconsistente detectado ($ESTADO)."
        echo ">>> Possíveis causas: keytab ausente, SSSD parado, ou ingresso parcial."
        if [ "$NON_INTERACTIVE" = "true" ]; then
            REPARAR="s"
        else
            read -p ">>> Deseja reparar automaticamente? (S/n): " REPARAR
        fi
        if [[ ! "$REPARAR" =~ ^[Nn]$ ]]; then
            echo ">>> Executando limpeza completa..."
            realm_leave_safe
            net_ads_leave_safe
            rm -f /etc/krb5.keytab
            systemctl stop sssd 2>/dev/null || true
            systemctl stop winbind 2>/dev/null || true
            # Limpar caches
            rm -rf /var/lib/sss/db/* 2>/dev/null || true
            rm -rf /var/lib/sss/mc/* 2>/dev/null || true
            ESTADO="NAO_INGRESSADO"
            echo ">>> Limpeza concluída."
        else
            echo ">>> Prosseguindo sem reparar (pode falhar)."
        fi
        ;;

    INDETERMINADO)
        echo ">>> Estado indeterminado. Tentando ingresso como máquina nova."
        ESTADO="NAO_INGRESSADO"
        ;;
esac

# ============================================================
# ESTÁGIO 4: EXECUÇÃO (apenas se necessário)
# ============================================================
if [ "$ESTADO" = "NAO_INGRESSADO" ]; then
    echo ""
    echo ">>> ESTÁGIO 4: Executando ingresso no domínio"

    # ------------------------------------------------------------
    # Ajustar DNS para o ingresso, usando os servidores DNS
    # designados pela OM (DNS_PRIMARIO/DNS_SECUNDARIO), nao a lista
    # de controladores de dominio (DC_IP_LIST) - ver correcao abaixo.
    # ------------------------------------------------------------
    echo ">>> Ajustando DNS para ingresso no dominio..."
    # CORRECAO (achado em teste real): systemd-resolved intercepta
    # /etc/resolv.conf via symlink para 127.0.0.53 e nao encaminha
    # corretamente consultas SRV (_ldap._tcp.DOMINIO) para o AD nesse
    # modo, quebrando o SSSD. chattr -i remove qualquer imutabilidade
    # deixada por uma execucao anterior.
    systemctl disable --now systemd-resolved 2>/dev/null || true
    chattr -i /etc/resolv.conf 2>/dev/null || true
    rm -f /etc/resolv.conf
    # DNS primario + secundario (nao usar DC_IP_LIST aqui - sao
    # conceitos diferentes: DC_IP_LIST e a lista de controladores de
    # dominio redundantes, DNS_PRIMARIO/DNS_SECUNDARIO sao os
    # servidores DNS de fato designados pela OM, que podem ter IPs
    # distintos dos DCs. Usar DC_IP_LIST aqui descartava
    # DNS_SECUNDARIO sempre que ele nao coincidisse com nenhum IP da
    # lista de DCs - achado em teste real na COMARA.
    # Fallback para DC_IP so se DNS_PRIMARIO nao foi informado.
    {
        [ -n "$DNS_PRIMARIO" ]   && echo "nameserver $DNS_PRIMARIO"
        [ -n "$DNS_SECUNDARIO" ] && echo "nameserver $DNS_SECUNDARIO"
        [ -z "$DNS_PRIMARIO" ]   && [ -n "$DC_IP" ] && echo "nameserver $DC_IP"
        echo "search $DOMINIO"
    } > /etc/resolv.conf

    # Configurar Kerberos
    echo ">>> Configurando Kerberos..."
    REALM="${DOMINIO^^}"
    # CORRECAO: dns_lookup_kdc=false (era true) - nao depender de SRV
    # ja que acabamos de desativar o encaminhamento via
    # systemd-resolved; kdc listado por FQDN E IP como redundancia;
    # default_ccache_name para integracao com keyring do systemd;
    # kpasswd_server para permitir troca de senha pelo usuario.
    cat > /etc/krb5.conf <<EOF
[libdefaults]
    default_realm = ${REALM}
    dns_lookup_realm = false
    dns_lookup_kdc = false
    rdns = false
    ticket_lifetime = 24h
    forwardable = yes
    renew_lifetime = 7d
    udp_preference_limit = 0
    default_ccache_name = KEYRING:persistent:%{uid}

[realms]
    ${REALM} = {
        kdc = dc-${OM_ACRONYM,,}.${DOMINIO}
        kdc = ${DC_IP}
        admin_server = dc-${OM_ACRONYM,,}.${DOMINIO}
        kpasswd_server = dc-${OM_ACRONYM,,}.${DOMINIO}
    }

[domain_realm]
    .${DOMINIO} = ${REALM}
    ${DOMINIO} = ${REALM}
EOF

    # Configurar Samba
    echo ">>> Configurando Samba..."
    cat > /etc/samba/smb.conf <<EOF
[global]
    workgroup = ${DOMINIO_NETBIOS}
    realm = ${DOMINIO}
    security = ads
    dns forwarder = ${DC_IP}
    kerberos method = secrets and keytab
    idmap config * : backend = tdb
    idmap config * : range = 3000-7999
    idmap config ${DOMINIO_NETBIOS} : backend = rid
    idmap config ${DOMINIO_NETBIOS} : range = 10000-999999
    template shell = /bin/bash
    template homedir = /home/%D/%U
    winbind use default domain = true
    winbind offline logon = false
    winbind nss info = rfc2307
    winbind enum users = no
    winbind enum groups = no
    load printers = no
    printing = bsd
    printcap name = /dev/null
    disable spoolss = yes
EOF

    # Obter ticket Kerberos
    echo ">>> Obtendo ticket Kerberos..."
    KINIT_OK=false

    # Tentar com pipe se ADMIN_PASSWORD estiver disponível
    if [ -n "$ADMIN_PASSWORD" ]; then
        echo ">>> Tentando obter ticket com senha pre-definida..."
        KINIT_HAS_PWFILE=false
        if kinit --help 2>&1 | grep -q -- '--password-file'; then
            KINIT_HAS_PWFILE=true
        fi
        echo ">>>   suporte a --password-file: $KINIT_HAS_PWFILE"

        for TRY_USER in \
            "${ADMIN_USERNAME}@${REALM}" \
            "${ADMIN_USERNAME}@${DOMINIO_NETBIOS}" \
            "${ADMIN_USERNAME,,}@${REALM}" \
            "${ADMIN_USERNAME,,}@${DOMINIO,,}"; do
            echo ">>>   tentando kinit para ${TRY_USER}..."
            if [ "$KINIT_HAS_PWFILE" = "true" ]; then
                if printf '%s\n' "$ADMIN_PASSWORD" | kinit --password-file=- "$TRY_USER" >/tmp/kinit-out.txt 2>&1; then
                    KINIT_OK=true
                    echo ">>>   OK"
                    break
                else
                    echo ">>>   falhou: $(head -3 /tmp/kinit-out.txt 2>/dev/null | tr '\n' ' ')"
                fi
            else
                if printf '%s\n' "$ADMIN_PASSWORD" | kinit "$TRY_USER" >/tmp/kinit-out.txt 2>&1; then
                    KINIT_OK=true
                    echo ">>>   OK"
                    break
                else
                    echo ">>>   falhou: $(head -3 /tmp/kinit-out.txt 2>/dev/null | tr '\n' ' ')"
                fi
            fi
        done
        rm -f /tmp/kinit-out.txt
    elif [ "$NON_INTERACTIVE" = "true" ]; then
        echo ">>> ERRO: ADMIN_PASSWORD nao definido em modo nao interativo."
    fi

    # Modo interativo se pipe falhou
    if [ "$KINIT_OK" != "true" ] && [ "$NON_INTERACTIVE" != "true" ]; then
        echo ">>> Não foi possível obter ticket automaticamente."
        echo ">>> Solicitando credenciais interativamente..."
        while [ "$KINIT_OK" != "true" ]; do
            if [ -z "$ADMIN_USERNAME" ] || [ "$ADMIN_USERNAME" = "Administrator" ]; then
                read -p ">>> Usuário do domínio: " input_user
                [ -n "$input_user" ] && ADMIN_USERNAME="$input_user"
            else
                echo ">>> Usuário: ${ADMIN_USERNAME}"
            fi

            echo ">>> Tentando kinit para ${ADMIN_USERNAME}@${REALM} ..."
            if kinit "${ADMIN_USERNAME}@${REALM}"; then
                KINIT_OK=true
            else
                echo ">>> Falhou. Verifique a senha e conectividade com o DC."
                read -p ">>> Tentar novamente? (S/n): " try_again
                [[ "$try_again" =~ ^[Nn]$ ]] && break
                ADMIN_USERNAME=""
            fi
        done
    fi

    if [ "$KINIT_OK" != "true" ]; then
        echo ">>> ERRO: Falha ao obter ticket Kerberos."
        echo ">>> Verifique as credenciais e conectividade com o DC."
        exit 1
    fi
    echo ">>> Ticket Kerberos obtido com sucesso!"

    # Tentar ingresso via realm join (SSSD)
    JOIN_OK=false
    JOIN_METHOD=""

    # --computer-ou so e passado quando definido; vazio faz o AD
    # usar a OU padrao de computadores em vez de rejeitar o join
    REALM_JOIN_ARGS=(--user="$ADMIN_USERNAME" --verbose)
    if [ -n "$OU_PADRAO" ]; then
        REALM_JOIN_ARGS+=(--computer-ou="$OU_PADRAO")
    fi

    echo ">>> Ingressando no domínio via realm join (SSSD)..."
    if echo "$ADMIN_PASSWORD" | realm join "$DOMINIO" "${REALM_JOIN_ARGS[@]}" 2>&1; then
        JOIN_OK=true
        JOIN_METHOD="sssd"
        echo ">>> Ingresso via SSSD (realm join) bem-sucedido!"
    else
        echo ">>> realm join falhou."
    fi

    # Fallback: net ads join (Winbind)
    if [ "$JOIN_OK" != "true" ]; then
        echo ">>> Tentando fallback com net ads join (Winbind)..."

        if ! grep -q "kerberos method" /etc/samba/smb.conf; then
            sed -i '/\[global\]/a\    kerberos method = secrets and keytab' /etc/samba/smb.conf
        fi

        # -S aceita IP diretamente; usar DC_IP em vez de tentar
        # adivinhar o hostname do DC por convencao de nome
        NET_JOIN_ARGS=(-U "$ADMIN_USERNAME" -S "$DC_IP")
        if [ -n "$OU_PADRAO" ]; then
            NET_JOIN_ARGS+=(createcomputer="$OU_PADRAO")
        fi

        if echo "$ADMIN_PASSWORD" | net ads join "$DOMINIO" "${NET_JOIN_ARGS[@]}" 2>&1; then
            JOIN_OK=true
            JOIN_METHOD="winbind"
            echo ">>> Ingresso via Winbind (net ads join) bem-sucedido!"

            # net ads join NAO gera o keytab de maquina sozinho.
            # Como ja temos um ticket Kerberos valido em cache (kinit
            # acima), "net ads keytab create" usa esse cache
            # automaticamente - nao aceita/precisa de senha via -P.
            echo ">>> Gerando keytab..."
            if ! net ads keytab create 2>/dev/null; then
                echo ">>> net ads keytab create falhou. Tentando via adcli..."
                echo "$ADMIN_PASSWORD" | adcli join "$DOMINIO" \
                    --login-user="$ADMIN_USERNAME" \
                    ${OU_PADRAO:+--domain-ou="$OU_PADRAO"} \
                    --stdin-password 2>&1 || {
                    echo ">>> AVISO: Falha ao gerar keytab. Login offline pode nao funcionar."
                }
            fi
        else
            echo ">>> net ads join falhou."
        fi
    fi

    if [ "$JOIN_OK" != "true" ]; then
        echo ">>> ERRO: Falha ao ingressar no domínio com todos os métodos."
        if [ "$NON_INTERACTIVE" = "true" ]; then
            CONTINUE="s"
        else
            read -p ">>> Deseja continuar mesmo assim? (S/n): " CONTINUE
        fi
        if [[ "$CONTINUE" =~ ^[Nn]$ ]]; then
            echo ">>> Instalação abortada pelo usuário."
            exit 1
        fi
        JOIN_METHOD="nenhum"
    fi
fi  # Fim do bloco de ingresso

# ============================================================
# ESTÁGIO 5: CONFIGURAÇÃO PÓS-INGRESSO E VALIDAÇÃO
# ============================================================
echo ""
echo ">>> ESTÁGIO 5: Configuração e validação"

# Configurar SSSD (se método for sssd)
if [ "$JOIN_METHOD" = "sssd" ] || [ "$ESTADO" = "INGRESSADO_SSSD" ] || [ "$ESTADO" = "INGRESSADO_HIBRIDO" ]; then
    echo ">>> Configurando SSSD..."
    OFFLINE_CACHE=""
    if [ "$OFFLINE_AUTH_ENABLED" = "true" ]; then
        DAYS="${OFFLINE_AUTH_DAYS:-3}"
        OFFLINE_CACHE="cache_credentials = true
        krb5_store_password_if_offline = true
        offline_credentials_expiration = ${DAYS}"
    fi

    cat > /etc/sssd/sssd.conf <<EOF
[sssd]
services = nss, pam, sudo
config_file_version = 2
domains = ${DOMINIO}

[domain/${DOMINIO}]
    id_provider = ad
    ad_domain = ${DOMINIO}
    ad_server = dc-${OM_ACRONYM,,}.${DOMINIO}
    ad_backup_server = ${DC_IP}
    krb5_server = ${DC_IP}
    krb5_backup_server = ${DC_IP}
    ad_hostname = $(hostname).${DOMINIO}
    ldap_id_mapping = true
    ldap_schema = ad
    ldap_user_principal = userPrincipalName
    ldap_user_name = sAMAccountName
    ldap_user_gecos = displayName
    ldap_user_home_directory = unixHomeDirectory
    ldap_user_shell = loginShell
    enumerate = false
    use_fully_qualified_names = false
    fallback_homedir = /home/%d/%u
    default_shell = /bin/bash
    krb5_use_fast = never
    ${OFFLINE_CACHE}
    dyndns_update = false
EOF

    chmod 600 /etc/sssd/sssd.conf
    echo ">>> SSSD configurado"
fi

# Configurar NSS
echo ">>> Configurando NSS..."
if [ "$JOIN_METHOD" = "winbind" ]; then
    cat > /etc/nsswitch.conf <<EOF
passwd:     files systemd winbind
shadow:     files winbind
group:      files systemd winbind
gshadow:    files

hosts:      files dns

services:   files
netgroup:   files
sudoers:    files

automount:  files
EOF
else
    cat > /etc/nsswitch.conf <<EOF
passwd:     files systemd sss
shadow:     files sss
group:      files systemd sss
gshadow:    files

hosts:      files dns

services:   files sss
netgroup:   files sss
sudoers:    files sss

automount:  files sss
EOF
fi

echo ">>> NSS configurado"

# Configurar PAM (mkhomedir)
echo ">>> Configurando PAM e mkhomedir..."
pam-auth-update --enable mkhomedir --force 2>/dev/null || true

if [ -f /etc/pam.d/common-session ]; then
    grep -q "pam_mkhomedir" /etc/pam.d/common-session || \
        echo "session required pam_mkhomedir.so skel=/etc/skel umask=0022" >> /etc/pam.d/common-session
fi

echo ">>> PAM configurado"

# Configurar sudo para grupos do domínio
echo ">>> Configurando sudo..."
SUDO_FILE="/etc/sudoers.d/seederlinux-domain"
cat > "$SUDO_FILE" <<EOF
# SeederLinux - Acesso sudo para grupos do domínio
%${GRUPO_ADMIN_AD}    ALL=(ALL:ALL) ALL
%${GRUPO_ADMIN_LINUX}  ALL=(ALL:ALL) ALL
EOF

if [ -n "$GRUPO_DASTI" ] && [ "$GRUPO_DASTI" != "" ]; then
    echo "%${GRUPO_DASTI}    ALL=(ALL:ALL) ALL" >> "$SUDO_FILE"
fi

chmod 440 "$SUDO_FILE"
visudo -cf "$SUDO_FILE" || {
    echo ">>> ERRO: sintaxe do sudoers inválida"
    exit 1
}

echo ">>> Sudo configurado"

# Reiniciar serviços
echo ">>> Reiniciando serviços..."
if [ "$JOIN_METHOD" = "sssd" ] || [ "$ESTADO" = "INGRESSADO_SSSD" ] || [ "$ESTADO" = "INGRESSADO_HIBRIDO" ]; then
    systemctl restart sssd 2>/dev/null || true
    systemctl enable sssd
fi

if [ "$JOIN_METHOD" = "winbind" ] || [ "$ESTADO" = "INGRESSADO_WINBIND" ]; then
    systemctl restart winbind 2>/dev/null || true
    systemctl enable winbind
fi

systemctl restart samba 2>/dev/null || true

# ============================================================
# VALIDAÇÃO FINAL
# ============================================================
echo ""
echo ">>> Validação final..."

VALIDATION_OK=true

if [ "$JOIN_METHOD" = "sssd" ] || [ "$ESTADO" = "INGRESSADO_SSSD" ] || [ "$ESTADO" = "INGRESSADO_HIBRIDO" ]; then
    echo "--- Testes SSSD ---"
    if systemctl is-active --quiet sssd; then
        echo "✔ SSSD ativo"
    else
        echo "✘ SSSD NÃO está ativo"
        VALIDATION_OK=false
    fi

    if [ -f /etc/krb5.keytab ] && [ -s /etc/krb5.keytab ]; then
        echo "✔ Keytab presente"
    else
        echo "✘ Keytab ausente ou vazio"
        VALIDATION_OK=false
    fi

    if realm list 2>/dev/null | grep -q "$DOMINIO"; then
        echo "✔ Realm associado"
    else
        echo "✘ Realm NÃO associado"
        VALIDATION_OK=false
    fi
fi

if [ "$JOIN_METHOD" = "winbind" ] || [ "$ESTADO" = "INGRESSADO_WINBIND" ]; then
    echo "--- Testes Winbind ---"
    if systemctl is-active --quiet winbind; then
        echo "✔ Winbind ativo"
    else
        echo "✘ Winbind NÃO está ativo"
        VALIDATION_OK=false
    fi

    if net ads testjoin > /dev/null 2>&1; then
        echo "✔ Testjoin OK"
    else
        echo "✘ Testjoin FALHOU"
        VALIDATION_OK=false
    fi

    if [ -f /etc/krb5.keytab ] && [ -s /etc/krb5.keytab ]; then
        echo "✔ Keytab presente"
    else
        echo "✘ Keytab ausente ou vazio (login offline pode nao funcionar)"
        VALIDATION_OK=false
    fi
fi

if [ "$VALIDATION_OK" = "false" ]; then
    echo ""
    echo ">>> AVISO: Alguns testes de validação falharam."
    echo ">>> O ingresso pode não estar completamente funcional."
    if [ "$NON_INTERACTIVE" = "true" ]; then
        CONTINUE="s"
    else
        read -p ">>> Deseja continuar mesmo assim? (S/n): " CONTINUE
    fi
fi

echo ""
echo ">>> [04] Gerenciamento de AD concluído! Método: ${JOIN_METHOD:-$ESTADO}"
echo "============================================================="
$SeederScript$,
    TRUE,
    TRUE,
    6,
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Configuracao SSH (ordem 7) - core_ssh.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, version, organization_id)
VALUES (
    'Configuracao SSH',
    'core_ssh.sh',
    'Configura acesso SSH e politicas de seguranca.',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_ssh.sh
# SeederLinux Lite - Configuracao SSH (porta, AllowGroups)
# Executado APOS o ingresso no AD para que os grupos do dominio existam.
# ============================================================================

set -e

echo "============================================================"
echo "07 - Configurar SSH"
echo "============================================================"

SSH_PORT="{{SSH_PORT}}"
SSH_GROUPS="{{SSH_GROUPS}}"

echo ">>> Porta SSH: ${SSH_PORT:-22}"
echo ">>> Grupos SSH: ${SSH_GROUPS:-nenhum}"

# Configurar porta
if [ -n "$SSH_PORT" ] && [ "$SSH_PORT" != "" ] && [ "$SSH_PORT" != "22" ]; then
    echo ">>> Configurando porta SSH: $SSH_PORT"
    if [ -f /etc/ssh/sshd_config ]; then
        cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S) 2>/dev/null || true
        sed -i "s/^#*Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
        echo ">>> Porta SSH alterada para $SSH_PORT"
    fi
fi

# Configurar AllowGroups
if [ -n "$SSH_GROUPS" ] && [ "$SSH_GROUPS" != "" ]; then
    echo ">>> Configurando AllowGroups: $SSH_GROUPS"
    if [ -f /etc/ssh/sshd_config ]; then
        IFS=$'\n,' read -ra GRP_ARRAY <<< "$SSH_GROUPS"
        GRP_LIST=""
        for GRP in "${GRP_ARRAY[@]}"; do
            GRP=$(echo "$GRP" | xargs)
            if [ -n "$GRP" ] && [ "$GRP" != "" ]; then
                if [ -z "$GRP_LIST" ]; then
                    GRP_LIST="$GRP"
                else
                    GRP_LIST="$GRP_LIST $GRP"
                fi
            fi
        done
        if [ -n "$GRP_LIST" ]; then
            sed -i "s/^#*AllowGroups .*/AllowGroups $GRP_LIST/" /etc/ssh/sshd_config
            if ! grep -q "^AllowGroups " /etc/ssh/sshd_config; then
                echo "AllowGroups $GRP_LIST" >> /etc/ssh/sshd_config
            fi
            echo ">>> AllowGroups configurado: $GRP_LIST"
        fi
    fi
fi

# Reiniciar SSH
if [ -f /etc/ssh/sshd_config ]; then
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
fi

echo ">>> [07] SSH configurado!"
echo "============================================================"
$SeederScript$,
    TRUE,
    TRUE,
    7,
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Configuracao de Navegador (ordem 8) - core_browser.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, version, organization_id)
VALUES (
    'Configuracao de Navegador',
    'core_browser.sh',
    'Configura Firefox ESR e Chrome (homepage, proxy, bookmarks) via politicas corporativas.',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_browser.sh
# SeederLinux Lite - Politicas Firefox/Chrome
# ============================================================================
# Configura politicas corporativas para Firefox ESR, Google Chrome e Chromium
# via arquivos de policies (JSON) no sistema.
# Os placeholders VARIAVEL são substituídos automaticamente
# pelo sistema na geração do bundle.
# ============================================================================

set -e

echo "============================================================"
echo "06 - Configurar politicas de navegadores"
echo "============================================================"

# ============================================================
# Variáveis
# ============================================================
HOMEPAGE="{{HOMEPAGE}}"
PROXY_MODE="{{PROXY_MODE}}"
PROXY_HTTP="{{PROXY_HTTP}}"
PROXY_PORTA="{{PROXY_PORTA}}"
PAC_URL="{{PAC_URL}}"
NO_PROXY="{{NO_PROXY}}"
DOMINIO="{{DOMINIO}}"
OM_ACRONYM="{{OM_ACRONYM}}"
CERTIFICATE_BUNDLE="{{CERTIFICATE_BUNDLE}}"

echo ">>> Homepage: $HOMEPAGE"
echo ">>> Modo de proxy: $PROXY_MODE"

# ============================================================
# Montar o bloco "Proxy" do policies.json de forma dinamica.
#
# CORRECAO: a versao anterior tinha "Proxy": {"Mode": "system"} FIXO
# no JSON, independente de PROXY_MODE. Como policies.json e o
# mecanismo mais novo do Firefox e tem precedencia sobre o
# autoconfig.js/lockPref legado (usado mais abaixo para PAC/MANUAL),
# na pratica o proxy configurado pela OM (manual ou PAC) nunca
# chegava a valer - o Firefox sempre ficava em "usar proxy do
# sistema". Agora o bloco reflete PROXY_MODE de verdade.
# ============================================================
case "$PROXY_MODE" in
    MANUAL)
        FIREFOX_PROXY_JSON="\"Proxy\": {
            \"Mode\": \"manual\",
            \"HTTPProxy\": \"${PROXY_HTTP}:${PROXY_PORTA}\",
            \"SSLProxy\": \"${PROXY_HTTP}:${PROXY_PORTA}\",
            \"Passthrough\": \"${NO_PROXY}\",
            \"Locked\": true
        }"
        ;;
    PAC)
        FIREFOX_PROXY_JSON="\"Proxy\": {
            \"Mode\": \"autoConfig\",
            \"AutoConfigURL\": \"${PAC_URL}\",
            \"Passthrough\": \"${NO_PROXY}\",
            \"Locked\": true
        }"
        ;;
    NONE)
        FIREFOX_PROXY_JSON="\"Proxy\": {
            \"Mode\": \"none\",
            \"Locked\": true
        }"
        ;;
    *)
        FIREFOX_PROXY_JSON="\"Proxy\": {
            \"Mode\": \"system\",
            \"Locked\": true
        }"
        ;;
esac

# ============================================================
# Firefox ESR - Politicas (policies.json)
# ============================================================
echo ">>> Configurando politicas do Firefox ESR..."
mkdir -p /usr/lib/firefox-esr/distribution

cat > /usr/lib/firefox-esr/distribution/policies.json <<EOF
{
    "policies": {
        "DisableTelemetry": true,
        "DisableFirefoxStudies": true,
        "DisablePocket": true,
        "DisableDeveloperTools": false,
        "BlockAboutConfig": false,
        "Homepage": {
            "URL": "${HOMEPAGE}",
            "Locked": true,
            "StartPage": "homepage"
        },
        "HomepageURL": "${HOMEPAGE}",
        "SearchBar": "unified",
        "SearchEngines": {
            "Add": [
                {
                    "Name": "${OM_ACRONYM}",
                    "URL": "${HOMEPAGE}",
                    "Method": "GET"
                }
            ]
        },
        ${FIREFOX_PROXY_JSON},
        "Certificates": {
            "ImportEnterpriseRoots": true
        },
        "ExtensionSettings": {
            "*": {
                "installation_mode": "allowed"
            }
        },
        "DisableSetDesktopBackground": false,
        "DontCheckDefaultBrowser": true,
        "PrimaryPassword": false,
        "OfferToSaveLogins": false,
        "PasswordManagerEnabled": false,
        "SanitizeOnShutdown": {
            "Cache": true,
            "Cookies": false,
            "Downloads": false,
            "FormData": true,
            "History": false,
            "Sessions": false,
            "SiteSettings": false,
            "OfflineApps": false
        }
    }
}
EOF

echo ">>> Politicas do Firefox configuradas"

# ============================================================
# Firefox ESR - autoconfig (para proxy PAC)
# ============================================================
if [ "$PROXY_MODE" = "PAC" ]; then
    echo ">>> Configurando PAC no Firefox..."
    mkdir -p /usr/lib/firefox-esr/defaults/pref
    cat > /usr/lib/firefox-esr/defaults/pref/autoconfig.js <<EOF
pref("general.config.filename", "seederlinux.cfg");
pref("general.config.obscure_value", 0);
EOF

    cat > /usr/lib/firefox-esr/seederlinux.cfg <<EOF
lockPref("network.proxy.type", 2);
lockPref("network.proxy.autoconfig_url", "${PAC_URL}");
lockPref("network.proxy.no_proxies_on", "${NO_PROXY}");
EOF
    echo ">>> PAC configurado no Firefox"
elif [ "$PROXY_MODE" = "MANUAL" ]; then
    echo ">>> Configurando proxy manual no Firefox..."
    mkdir -p /usr/lib/firefox-esr/defaults/pref
    cat > /usr/lib/firefox-esr/defaults/pref/autoconfig.js <<EOF
pref("general.config.filename", "seederlinux.cfg");
pref("general.config.obscure_value", 0);
EOF

    cat > /usr/lib/firefox-esr/seederlinux.cfg <<EOF
lockPref("network.proxy.type", 1);
lockPref("network.proxy.http", "${PROXY_HTTP}");
lockPref("network.proxy.http_port", ${PROXY_PORTA});
lockPref("network.proxy.https", "${PROXY_HTTP}");
lockPref("network.proxy.https_port", ${PROXY_PORTA});
lockPref("network.proxy.no_proxies_on", "${NO_PROXY}");
EOF
    echo ">>> Proxy manual configurado no Firefox"
fi

# ============================================================
# Google Chrome - Politicas
# ============================================================
echo ">>> Configurando politicas do Google Chrome..."
mkdir -p /etc/opt/chrome/policies/managed
mkdir -p /etc/opt/chrome/policies/recommended

# Proxy config para Chrome
case "$PROXY_MODE" in
    NONE)
        CHROME_PROXY_MODE="direct"
        ;;
    MANUAL)
        CHROME_PROXY_MODE="fixed_servers"
        CHROME_PROXY_SERVERS="http=${PROXY_HTTP}:${PROXY_PORTA};https=${PROXY_HTTP}:${PROXY_PORTA}"
        ;;
    PAC)
        CHROME_PROXY_MODE="pac_script"
        CHROME_PROXY_PAC_URL="$PAC_URL"
        ;;
    *)
        CHROME_PROXY_MODE="system"
        ;;
esac

# Construir JSON de proxy
PROXY_JSON=""
if [ "$CHROME_PROXY_MODE" = "fixed_servers" ]; then
    PROXY_JSON=", \"ProxyMode\": \"${CHROME_PROXY_MODE}\", \"ProxyServer\": \"${CHROME_PROXY_SERVERS}\""
elif [ "$CHROME_PROXY_MODE" = "pac_script" ]; then
    PROXY_JSON=", \"ProxyMode\": \"${CHROME_PROXY_MODE}\", \"ProxyPacUrl\": \"${CHROME_PROXY_PAC_URL}\""
else
    PROXY_JSON=", \"ProxyMode\": \"${CHROME_PROXY_MODE}\""
fi

cat > /etc/opt/chrome/policies/managed/seederlinux.json <<EOF
{
    "HomepageLocation": "${HOMEPAGE}",
    "HomepageIsNewTabPage": false,
    "RestoreOnStartup": 1,
    "RestoreOnStartupURLs": ["${HOMEPAGE}"],
    "BrowserSignin": 0,
    "SyncDisabled": true,
    "BlockThirdPartyCookies": true,
    "BackgroundModeEnabled": false,
    "TelemetryReportingEnabled": false,
    "UrlKeyboardsEnabled": false${PROXY_JSON},
    "DefaultCookiesSetting": 1,
    "AutoSelectCertificateForUrls": ["{\"pattern\":\"https://*\",\"filter\":{}}"],
    "ChromeCertProtectorEnabled": false
}
EOF

echo ">>> Politicas do Chrome configuradas"

# ============================================================
# Chromium - Politicas (mesmas do Chrome)
# ============================================================
echo ">>> Configurando politicas do Chromium..."
mkdir -p /etc/chromium/policies/managed
mkdir -p /etc/chromium/policies/recommended

cp /etc/opt/chrome/policies/managed/seederlinux.json \
   /etc/chromium/policies/managed/seederlinux.json 2>/dev/null || true

echo ">>> Politicas do Chromium configuradas"

echo ">>> [06] Politicas de navegadores configuradas!"
echo "============================================================"
$SeederScript$,
    TRUE,
    TRUE,
    8,
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Agente de Inventario OCS (ordem 9) - core_inventory.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, version, organization_id)
VALUES (
    'Agente de Inventario OCS',
    'core_inventory.sh',
    'Configura OCS Inventory Agent (sem apt-get; pacote instalado em core_packages.sh).',
    $SeederScript$#!/bin/bash
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

echo "============================================================"
echo "06 - Configurar OCS Inventory Agent"
echo "============================================================"

# ============================================================
# Variaveis
# ============================================================
INVENTORY_ENABLED="{{INVENTORY_ENABLED}}"
OCS_SERVER="{{OCS_SERVER}}"
OCS_TAG="{{OCS_TAG}}"
GLPI_SERVER="{{GLPI_SERVER}}"

echo ">>> Inventario habilitado: $INVENTORY_ENABLED"

# ============================================================
# Verificar se o inventario esta habilitado
# ============================================================
if [ "$INVENTORY_ENABLED" != "true" ]; then
    echo ">>> Inventario desativado. Pulando configuracao."
    echo ">>> [06] OCS Inventory desativado."
    echo "============================================================"
    exit 0
fi

if [ -z "$OCS_SERVER" ] || [ "$OCS_SERVER" = "" ]; then
    echo ">>> AVISO: OCS_SERVER nao definido. Pulando configuracao."
    echo ">>> [06] OCS Inventory nao configurado (servidor ausente)."
    echo "============================================================"
    exit 0
fi

echo ">>> Servidor OCS: $OCS_SERVER"
echo ">>> Tag OCS: $OCS_TAG"

# ============================================================
# Verificar se o pacote foi instalado (no core_packages.sh)
# ============================================================
if ! command -v ocsinventory-agent &>/dev/null; then
    echo ">>> AVISO: ocsinventory-agent nao instalado. Pulando configuracao."
    echo ">>> [06] OCS Inventory nao configurado (pacote ausente)."
    echo "============================================================"
    exit 0
fi

# ============================================================
# Configurar agente OCS
# ============================================================
echo ">>> Configurando agente OCS..."
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
echo ">>> Configurando cron do OCS..."
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
    echo ">>> Configurando integracao GLPI..."
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
echo ">>> Executando coleta inicial de inventario..."
ocsinventory-agent --server="$OCS_SERVER" --tag="$OCS_TAG" --lazy 2>/dev/null || {
    echo ">>> AVISO: Falha na coleta inicial. Sera refeito via cron."
}

echo ">>> [06] OCS Inventory configurado!"
echo "============================================================"
)
$SeederScript$,
    TRUE,
    TRUE,
    9,
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Configuracao de Impressoras (ordem 10) - core_printers.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, version, organization_id)
VALUES (
    'Configuracao de Impressoras',
    'core_printers.sh',
    'Configura CUPS e impressoras via servidor remoto.',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_printers.sh
# SeederLinux Lite - CUPS e impressoras (configuracao apenas)
# ============================================================================
# Configura o CUPS e instala as impressoras compartilhadas via servidor
# de impressao. A instalacao de pacotes e feita no core_packages.sh.
# Os placeholders VARIAVEL sao substituidos automaticamente
# pelo sistema na geracao do bundle.
# ============================================================================

(
set -e

echo "============================================================"
echo "07 - Configurar CUPS e impressoras"
echo "============================================================"

# ============================================================
# Variaveis
# ============================================================
PRINT_SERVER="{{PRINT_SERVER}}"
DEFAULT_PRINTER="{{DEFAULT_PRINTER}}"
PRINTERS="{{PRINTERS}}"
DOMINIO="{{DOMINIO}}"

echo ">>> Servidor de impressao: $PRINT_SERVER"
echo ">>> Impressora padrao: $DEFAULT_PRINTER"

# ============================================================
# Verificar se ha servidor de impressao
# ============================================================
if [ -z "$PRINT_SERVER" ] || [ "$PRINT_SERVER" = "" ]; then
    echo ">>> AVISO: PRINT_SERVER nao definido. Pulando configuracao."
    echo ">>> [07] Impressoras nao configuradas (servidor ausente)."
    echo "============================================================"
    exit 0
fi

# ============================================================
# Verificar se o CUPS foi instalado (no core_packages.sh)
# ============================================================
if ! command -v cupsctl &>/dev/null; then
    echo ">>> AVISO: CUPS nao instalado. Pulando configuracao."
    echo ">>> [07] Impressoras nao configuradas (CUPS ausente)."
    echo "============================================================"
    exit 0
fi

# ============================================================
# Configurar CUPS
# ============================================================
echo ">>> Configurando CUPS..."

# Habilitar e iniciar CUPS
systemctl enable cups
systemctl start cups

# Permitir administracao remota e compartilhamento
cupsctl --remote-admin --remote-any --share-printers 2>/dev/null || true

# Configurar cupsd.conf
cat > /etc/cups/cupsd.conf <<EOF
# Configuracao CUPS - SeederLinux
Browsing On
BrowseLocalProtocols dnssd
DefaultAuthType Basic
WebInterface Yes

Listen localhost:631
Listen /run/cups/cups.sock

<Location />
    Order allow,deny
    Allow all
</Location>

<Location /admin>
    Order allow,deny
    Allow all
</Location>

<Location /admin/conf>
    AuthType Default
    Require user @SYSTEM
    Order allow,deny
    Allow all
</Location>
EOF

systemctl restart cups

# ============================================================
# Configurar impressoras via servidor CUPS remoto
# ============================================================
echo ">>> Configurando impressoras via servidor remoto..."

# Criar arquivo de configuracao client.conf do CUPS
cat > /etc/cups/client.conf <<EOF
# Cliente CUPS - SeederLinux
ServerName ${PRINT_SERVER}
EOF

# ============================================================
# Instalar cada impressora listada
# ============================================================
if [ -n "$PRINTERS" ] && [ "$PRINTERS" != "" ]; then
    echo ">>> Instalando impressoras listadas..."
    for PRINTER in $PRINTERS; do
        echo ">>> Configurando impressora: $PRINTER"
        # Adicionar impressora via lpadmin (IPP via servidor)
        lpadmin -p "$PRINTER" -E -v "ipp://${PRINT_SERVER}/printers/${PRINTER}" \
            -m everywhere 2>/dev/null || {
            echo ">>> AVISO: Falha ao adicionar impressora $PRINTER"
        }
    done
else
    echo ">>> Nenhuma impressora listada. Usando descoberta automatica."
    # Descoberta automatica via servidor remoto
    lpinfo -h "$PRINT_SERVER" -v 2>/dev/null | grep ipp | while read -r line; do
        PRINTER_URI=$(echo "$line" | awk '{print $2}')
        PRINTER_NAME=$(basename "$PRINTER_URI")
        echo ">>> Impressora encontrada: $PRINTER_NAME"
        lpadmin -p "$PRINTER_NAME" -E -v "$PRINTER_URI" -m everywhere 2>/dev/null || true
    done
fi

# ============================================================
# Definir impressora padrao
# ============================================================
if [ -n "$DEFAULT_PRINTER" ] && [ "$DEFAULT_PRINTER" != "" ]; then
    echo ">>> Definindo impressora padrao: $DEFAULT_PRINTER"
    lpadmin -d "$DEFAULT_PRINTER" 2>/dev/null || {
        echo ">>> AVISO: Falha ao definir impressora padrao"
    }
fi

# ============================================================
# Reiniciar CUPS para aplicar
# ============================================================
systemctl restart cups

echo ">>> [07] CUPS e impressoras configurados!"
echo "============================================================"
)
$SeederScript$,
    TRUE,
    TRUE,
    10,
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Configuracao VNC (ordem 11) - core_vnc.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, version, organization_id)
VALUES (
    'Configuracao VNC',
    'core_vnc.sh',
    'Configura x11vnc para acesso remoto assistido.',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_vnc.sh
# SeederLinux Lite - x11vnc (configuracao apenas)
# ============================================================================
# Configura o x11vnc para suporte remoto, incluindo servico systemd e
# senha de acesso. A instalacao de pacotes e feita no core_packages.sh.
#
# SEGURANCA: A senha VNC e recebida como VNC_PASSWORD_B64 (base64),
# decodificada em memoria e usada com x11vnc -storepasswd. Nunca
# armazenada em texto plano no bundle ou no disco.
#
# Os placeholders VARIAVEL sao substituidos automaticamente
# pelo sistema na geracao do bundle.
# ============================================================================

(
set -e

echo "============================================================"
echo "08 - Configurar x11vnc"
echo "============================================================"

# ============================================================
# Variaveis
# ============================================================
VNC_ENABLED="{{VNC_ENABLED}}"
VNC_PASSWORD_B64="__VNC_PASSWORD_B64__"
DISPLAY_MANAGER="{{DISPLAY_MANAGER}}"

# Decodificar senha VNC (armazenada em base64)
if [ -n "$VNC_PASSWORD_B64" ] && [ "$VNC_PASSWORD_B64" != "" ]; then
    VNC_PASSWORD=$(echo "$VNC_PASSWORD_B64" | base64 -d 2>/dev/null)
    if [ -z "$VNC_PASSWORD" ]; then
        echo ">>> AVISO: Falha ao decodificar VNC_PASSWORD_B64. Sera gerada senha aleatoria."
    fi
fi
unset VNC_PASSWORD_B64

echo ">>> VNC habilitado: $VNC_ENABLED"

# ============================================================
# Verificar se VNC esta habilitado
# ============================================================
if [ "$VNC_ENABLED" != "true" ]; then
    echo ">>> VNC desativado. Pulando configuracao."
    echo ">>> [08] x11vnc desativado."
    echo "============================================================"
    exit 0
fi

# ============================================================
# Verificar se o x11vnc foi instalado (no core_packages.sh)
# ============================================================
if ! command -v x11vnc &>/dev/null; then
    echo ">>> AVISO: x11vnc nao instalado. Pulando configuracao."
    echo ">>> [08] x11vnc nao configurado (pacote ausente)."
    echo "============================================================"
    exit 0
fi

# ============================================================
# Detectar Display Manager se nao definido
# ============================================================
if [ -z "$DISPLAY_MANAGER" ] || [ "$DISPLAY_MANAGER" = "" ]; then
    if systemctl is-active --quiet lightdm 2>/dev/null; then DISPLAY_MANAGER="lightdm"
    elif systemctl is-active --quiet gdm3 2>/dev/null; then DISPLAY_MANAGER="gdm3"
    elif systemctl is-active --quiet sddm 2>/dev/null; then DISPLAY_MANAGER="sddm"
    else DISPLAY_MANAGER="lightdm"
    fi
    echo ">>> Display Manager detectado: $DISPLAY_MANAGER"
fi

# ============================================================
# Configurar senha do VNC (SEM expor em texto plano)
# ============================================================
echo ">>> Configurando senha do VNC..."
mkdir -p /etc/x11vnc
mkdir -p /etc/seederlinux

SECRETS_FILE="/etc/seederlinux/secrets.env"

if [ -n "$VNC_PASSWORD" ] && [ "$VNC_PASSWORD" != "" ]; then
    x11vnc -storepasswd "$VNC_PASSWORD" /etc/x11vnc/vncpasswd
    chmod 600 /etc/x11vnc/vncpasswd
    echo ">>> Senha VNC configurada (fornecida pela OM)"
    echo "VNC_PASSWORD_SET=true" >> "$SECRETS_FILE"
else
    echo ">>> VNC_PASSWORD nao definido. Gerando senha aleatoria."
    RANDOM_PASS=$(openssl rand -base64 12)
    x11vnc -storepasswd "$RANDOM_PASS" /etc/x11vnc/vncpasswd
    chmod 600 /etc/x11vnc/vncpasswd
    echo ">>> Senha VNC gerada com sucesso"
    echo "VNC_PASSWORD_SET=true" >> "$SECRETS_FILE"
fi

chmod 600 "$SECRETS_FILE" 2>/dev/null || true
unset VNC_PASSWORD
unset VNC_PASSWORD_B64
unset RANDOM_PASS

# ============================================================
# Criar servico systemd para x11vnc
# ============================================================
echo ">>> Criando servico systemd x11vnc..."

case "$DISPLAY_MANAGER" in
    lightdm)
        VNC_DISPLAY=":0"
        VNC_AUTH="/var/run/lightdm/root/:0"
        ;;
    gdm3)
        VNC_DISPLAY=":0"
        VNC_AUTH="/run/user/0/gdm/Xauthority"
        ;;
    sddm)
        VNC_DISPLAY=":0"
        VNC_AUTH="/var/run/sddm/:0"
        ;;
    *)
        VNC_DISPLAY=":0"
        VNC_AUTH="/tmp/.X0-lock"
        ;;
esac

cat > /etc/systemd/system/x11vnc.service <<EOF
[Unit]
Description=x11vnc Server - SeederLinux
After=display-manager.service
Requires=display-manager.service

[Service]
Type=simple
ExecStart=/usr/bin/x11vnc -display ${VNC_DISPLAY} -auth ${VNC_AUTH} -forever -loop -noxdamage -repeat -rfbauth /etc/x11vnc/vncpasswd -rfbport 5900 -shared -bg -o /var/log/x11vnc.log
ExecStop=/usr/bin/killall x11vnc
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical.target
EOF

systemctl daemon-reload
systemctl enable x11vnc.service
systemctl start x11vnc.service 2>/dev/null || {
    echo ">>> AVISO: Nao foi possivel iniciar x11vnc agora."
    echo ">>> O servico sera iniciado apos o display manager."
}

echo ">>> [08] x11vnc configurado!"
echo "============================================================"
)
$SeederScript$,
    TRUE,
    TRUE,
    11,
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Configuracao de Conky (ordem 12) - core_conky.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, version, organization_id)
VALUES (
    'Configuracao de Conky',
    'core_conky.sh',
    'Configura o Conky (monitor de sistema no desktop) com perfil dinamico via JSON.',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_conky.sh
# SeederLinux Lite - Conky (configuracao apenas)
# ============================================================================
# Configura o Conky para exibicao de informacoes do sistema no desktop,
# com perfil personalizavel. A instalacao de pacotes e feita no core_packages.sh.
# Os placeholders VARIAVEL sao substituidos automaticamente
# pelo sistema na geracao do bundle.
# ============================================================================

(
set -e

echo "============================================================"
echo "09 - Configurar Conky"
echo "============================================================"

# ============================================================
# Variaveis
# ============================================================
CONKY_PROFILE="{{CONKY_PROFILE}}"
CONKY_CONFIG='{{CONKY_CONFIG}}'
DESKTOP_ENV="{{DESKTOP_ENV}}"
OM_ACRONYM="{{OM_ACRONYM}}"
OM_NAME="{{OM_NAME}}"

echo ">>> Perfil Conky: $CONKY_PROFILE"
echo ">>> Ambiente: $DESKTOP_ENV"

# ============================================================
# Detectar ambiente grafico se nao definido
# ============================================================
if [ -z "$DESKTOP_ENV" ] || [ "$DESKTOP_ENV" = "" ]; then
    if command -v cinnamon-session &>/dev/null; then DESKTOP_ENV="cinnamon"
    elif command -v mate-session &>/dev/null; then DESKTOP_ENV="mate"
    elif command -v gnome-session &>/dev/null; then DESKTOP_ENV="gnome"
    elif command -v startxfce4 &>/dev/null; then DESKTOP_ENV="xfce"
    elif command -v startplasma-x11 &>/dev/null; then DESKTOP_ENV="kde"
    elif command -v lxqt-session &>/dev/null; then DESKTOP_ENV="lxqt"
    elif command -v startlxde &>/dev/null; then DESKTOP_ENV="lxde"
    else DESKTOP_ENV="unknown"
    fi
fi

# ============================================================
# Verificar se o Conky foi instalado (no core_packages.sh)
# ============================================================
if ! command -v conky &>/dev/null; then
    echo ">>> AVISO: Conky nao instalado. Pulando configuracao."
    echo ">>> [09] Conky nao configurado (pacote ausente)."
    echo "============================================================"
    exit 0
fi

# ============================================================
# Parse do CONKY_CONFIG (JSON) com fallbacks
# ============================================================
parse_json() {
    local key="$1"
    local default="$2"
    local val
    val=$(echo "$CONKY_CONFIG" | jq -r "if has(\"${key}\") then .${key} else \"__UNSET__\" end" 2>/dev/null)
    if [ -z "$val" ] || [ "$val" = "null" ] || [ "$val" = "__UNSET__" ]; then
        echo "$default"
    else
        echo "$val"
    fi
}

CFG_POSITION=$(parse_json position "top_right")
CFG_TRANSPARENT=$(parse_json transparent "true")
CFG_COLOR_TEXT=$(parse_json color_text "#FFFFFF")
CFG_COLOR_BG=$(parse_json color_bg "#000000")
CFG_FONT_SIZE=$(parse_json font_size "10")
CFG_GAP_X=$(parse_json gap_x "10")
CFG_GAP_Y=$(parse_json gap_y "40")
CFG_UPDATE_INTERVAL=$(parse_json update_interval "1.0")
CFG_SHOW_CPU=$(parse_json show_cpu "true")
CFG_SHOW_RAM=$(parse_json show_ram "true")
CFG_SHOW_DISK=$(parse_json show_disk "true")
CFG_DISK_PARTITION=$(parse_json disk_partition "/")
CFG_SHOW_NETWORK=$(parse_json show_network "true")
CFG_NETWORK_IFACE=$(parse_json network_interface "eth0")
CFG_SHOW_TOP=$(parse_json show_top_processes "true")
CFG_SHOW_DATETIME=$(parse_json show_datetime "true")
CFG_SHOW_HOSTNAME=$(parse_json show_hostname "true")
CFG_HOSTNAME_FONT_SIZE=$(parse_json font_size_hostname "14")

COLOR_TEXT_LUA="${CFG_COLOR_TEXT#\#}"
COLOR_BG_LUA="${CFG_COLOR_BG#\#}"

if [ "$CFG_TRANSPARENT" = "true" ]; then
    OWN_TRANSPARENT="true"
    OWN_ARGB_VALUE="0"
else
    OWN_TRANSPARENT="false"
    OWN_ARGB_VALUE="200"
fi

# ============================================================
# Criar diretorio de configuracao global
# ============================================================
mkdir -p /etc/seederlinux/conky

# ============================================================
# Gerar configuracao do Conky (usando CONKY_CONFIG JSON)
# ============================================================
echo ">>> Gerando configuracao do Conky (CONKY_CONFIG=${CONKY_CONFIG:-vazio})..."

if [ "$CFG_SHOW_HOSTNAME" = "true" ]; then
    CONKY_TEXT="\${font DejaVu Sans Mono:size=${CFG_HOSTNAME_FONT_SIZE}}\${color ${COLOR_TEXT_LUA}}Host: \${nodename}
\${font DejaVu Sans Mono:size=${CFG_FONT_SIZE}}
\${color ${COLOR_TEXT_LUA}}${OM_ACRONYM} - ${OM_NAME}
\${color ${COLOR_TEXT_LUA}}\${hr}"
else
    CONKY_TEXT="\${color ${COLOR_TEXT_LUA}}${OM_ACRONYM} - ${OM_NAME}
\${color ${COLOR_TEXT_LUA}}\${hr}"
fi

CONKY_TEXT="${CONKY_TEXT}
\${color ${COLOR_TEXT_LUA}}Uptime: \${color grey}\${uptime}
\${color ${COLOR_TEXT_LUA}}\${hr}"

if [ "$CFG_SHOW_CPU" = "true" ]; then
    CONKY_TEXT="${CONKY_TEXT}
\${color ${COLOR_TEXT_LUA}}CPU:  \${color grey}\${cpu}% \${cpubar 4}"
fi
if [ "$CFG_SHOW_RAM" = "true" ]; then
    CONKY_TEXT="${CONKY_TEXT}
\${color ${COLOR_TEXT_LUA}}RAM:  \${color grey}\${mem}/\${memmax} \${membar 4}
\${color ${COLOR_TEXT_LUA}}SWAP: \${color grey}\${swap}/\${swapmax} \${swapbar 4}"
fi
if [ "$CFG_SHOW_DISK" = "true" ]; then
    CONKY_TEXT="${CONKY_TEXT}
\${color ${COLOR_TEXT_LUA}}Disco (${CFG_DISK_PARTITION}): \${color grey}\${fs_used ${CFG_DISK_PARTITION}}/\${fs_size ${CFG_DISK_PARTITION}} \${fs_bar 6 ${CFG_DISK_PARTITION}}"
fi
if [ "$CFG_SHOW_NETWORK" = "true" ]; then
    CONKY_TEXT="${CONKY_TEXT}
\${color ${COLOR_TEXT_LUA}}Rede (${CFG_NETWORK_IFACE}):
\${color ${COLOR_TEXT_LUA}}IP:   \${color grey}\${addr ${CFG_NETWORK_IFACE}}
\${color ${COLOR_TEXT_LUA}}Down: \${color grey}\${downspeed ${CFG_NETWORK_IFACE}}
\${color ${COLOR_TEXT_LUA}}Up:   \${color grey}\${upspeed ${CFG_NETWORK_IFACE}}"
fi
if [ "$CFG_SHOW_TOP" = "true" ]; then
    CONKY_TEXT="${CONKY_TEXT}
\${color ${COLOR_TEXT_LUA}}\${hr}
\${color ${COLOR_TEXT_LUA}}Top CPU:
\${color grey}\${top name 1} \${top cpu 1}%
\${color grey}\${top name 2} \${top cpu 2}%
\${color grey}\${top name 3} \${top cpu 3}%"
fi
if [ "$CFG_SHOW_DATETIME" = "true" ]; then
    CONKY_TEXT="${CONKY_TEXT}
\${color ${COLOR_TEXT_LUA}}\${hr}
\${color ${COLOR_TEXT_LUA}}\${time %A, %d/%m/%Y %H:%M:%S}"
fi

cat > /etc/seederlinux/conky/conky.conf <<EOF
-- Configuracao Conky - SeederLinux (gerada dinamicamente)
-- Perfil: ${CONKY_PROFILE:-default}

conky.config = {
    alignment = '${CFG_POSITION}',
    background = false,
    border_width = 1,
    cpu_avg_samples = 2,
    default_color = '${COLOR_TEXT_LUA}',
    double_buffer = true,
    draw_borders = false,
    draw_graph_borders = true,
    font = 'DejaVu Sans Mono:size=${CFG_FONT_SIZE}',
    gap_x = ${CFG_GAP_X},
    gap_y = ${CFG_GAP_Y},
    minimum_width = 200,
    net_avg_samples = 2,
    no_buffers = true,
    own_window = true,
    own_window_class = 'Conky',
    own_window_type = 'desktop',
    own_window_argb_visual = true,
    own_window_argb_value = ${OWN_ARGB_VALUE},
    own_window_transparent = ${OWN_TRANSPARENT},
    own_window_colour = '${COLOR_BG_LUA}',
    own_window_hints = 'undecorated,below,sticky,skip_taskbar,skip_pager',
    update_interval = ${CFG_UPDATE_INTERVAL},
    use_xft = true,
}

conky.text = [[
${CONKY_TEXT}
]]
EOF

# ============================================================
# Criar script de inicializacao do Conky
# ============================================================
echo ">>> Criando script de inicializacao..."
cat > /usr/local/bin/seederlinux-conky <<'SCRIPT'
#!/bin/bash
CONKY_CONF="/etc/seederlinux/conky/conky.conf"
sleep 5
if [ -f "$CONKY_CONF" ]; then
    killall conky 2>/dev/null || true
    conky -c "$CONKY_CONF" &
else
    echo "Configuracao do Conky nao encontrada: $CONKY_CONF"
fi
SCRIPT

chmod +x /usr/local/bin/seederlinux-conky

# ============================================================
# Adicionar Conky ao autostart conforme o DE
# ============================================================
echo ">>> Configurando autostart do Conky para: $DESKTOP_ENV"

case "$DESKTOP_ENV" in
    cinnamon|mate|xfce|lxde|lxqt|gnome)
        mkdir -p /etc/xdg/autostart
        cat > /etc/xdg/autostart/seederlinux-conky.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Conky (SeederLinux)
Exec=/usr/local/bin/seederlinux-conky
Terminal=false
X-GNOME-Autostart-enabled=true
NoDisplay=false
EOF
        ;;
    kde)
        mkdir -p /usr/share/autostart
        cat > /usr/share/autostart/seederlinux-conky.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Conky (SeederLinux)
Exec=/usr/local/bin/seederlinux-conky
Terminal=false
X-KDE-autostart-enabled=true
EOF
        ;;
esac

echo ">>> [09] Conky configurado!"
echo "============================================================"
)
$SeederScript$,
    TRUE,
    TRUE,
    12,
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Configuracoes Adicionais (ordem 13) - core_config.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, version, organization_id)
VALUES (
    'Configuracoes Adicionais',
    'core_config.sh',
    'Configuracoes diversas do sistema (sysctl, limits, etc).',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_config.sh
# SeederLinux Lite - Arquivo de Configuracao Persistente
# ============================================================================
# Cria /etc/seederlinux/config.env com todas as variaveis nao-sensiveis
# da OM. Este arquivo e lido pelos scripts permanentes (seederlinux-logon,
# seederlinux-logoff) apos reboot, quando as variaveis exportadas no bundle
# ja nao existem mais na memoria.
#
# Variaveis sensiveis (senha VNC, usuario admin do AD) NAO sao escritas
# neste arquivo. Elas sao gravadas em /etc/seederlinux/secrets.env (perm 600)
# apenas pelo core_vnc.sh e core_domain.sh respectivamente.
#
# Os placeholders VARIAVEL sao substituidos automaticamente
# pelo sistema na geracao do bundle.
# ============================================================================

set -e

echo "============================================================"
echo "13.5 - Criar arquivo de configuracao persistente"
echo "============================================================"

# ============================================================
# Diretorio base
# ============================================================
mkdir -p /etc/seederlinux

CONFIG_FILE="/etc/seederlinux/config.env"

# ============================================================
# Escrever variaveis nao-sensiveis no config.env
# Variaveis sensiveis (VNC_PASSWORD_B64, ADMIN_USERNAME) ficam em
# /etc/seederlinux/secrets.env, gravadas por seus respectivos scripts.
# ============================================================
NTP_SERVER="${NTP_SERVER#http://}"
NTP_SERVER="${NTP_SERVER#https://}"

# Remover protocolo em valores vindos do bundle
NTP_SERVER="${NTP_SERVER#http://}"
NTP_SERVER="${NTP_SERVER#https://}"

# ============================================================
# SERIAL_APLICADO e ESTADO LOCAL da estacao (o ultimo serial de
# configuracao que ela aplicou com sucesso), NAO um valor da OM.
# Se este script rodar de novo (bundle regenerado e reaplicado numa
# estacao ja provisionada), NAO podemos simplesmente sobrescrever
# com "0" de novo - isso faria a estacao "esquecer" que ja estava
# em dia e forcaria o seeder-sync a reaplicar tudo, alem de
# atrapalhar o agente na comparacao de serial com o servidor.
# Preservamos o valor existente se ja houver um; so usamos "0" na
# primeira geracao (estacao nova, sem config.env ainda).
# ============================================================
SERIAL_APLICADO_ATUAL="0"
if [ -f "$CONFIG_FILE" ]; then
    VALOR_EXISTENTE="$(grep -m1 '^SERIAL_APLICADO=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"')"
    [ -n "$VALOR_EXISTENTE" ] && SERIAL_APLICADO_ATUAL="$VALOR_EXISTENTE"
fi
echo ">>> SERIAL_APLICADO preservado: $SERIAL_APLICADO_ATUAL"

cat > "$CONFIG_FILE" <<EOF
# SeederLinux Lite - Configuracao Persistente
# NAO EDITAR MANUALMENTE - gerado pelo core_config.sh
# Gerado em: $(date '+%Y-%m-%d %H:%M:%S')

# Dominio e Autenticacao
DOMINIO="{{DOMINIO}}"
DOMINIO_NETBIOS="{{DOMINIO_NETBIOS}}"
DC_IP="{{DC_IP}}"
DC_IP_LIST="{{DC_IP_LIST}}"
DC_SECUNDARIO_IP="{{DC_SECUNDARIO_IP}}"
DNS_PRIMARIO="{{DNS_PRIMARIO}}"
DNS_SECUNDARIO="{{DNS_SECUNDARIO}}"
DNS_INTERNET="{{DNS_INTERNET}}"
NTP_SERVER="{{NTP_SERVER}}"
OU_PADRAO="{{OU_PADRAO}}"
GRUPO_ADMIN="{{GRUPO_ADMIN}}"
GRUPO_ADMIN_AD="{{GRUPO_ADMIN_AD}}"
GRUPO_ADMIN_LINUX="{{GRUPO_ADMIN_LINUX}}"
GRUPO_DASTI="{{GRUPO_DASTI}}"
AUTH_METHOD="{{AUTH_METHOD}}"
OFFLINE_AUTH_ENABLED="{{OFFLINE_AUTH_ENABLED}}"
OFFLINE_AUTH_DAYS="{{OFFLINE_AUTH_DAYS}}"

# Rede e Proxy
PROXY_HTTP="{{PROXY_HTTP}}"
PROXY_PORTA="{{PROXY_PORTA}}"
PROXY_URL="{{PROXY_URL}}"
PROXY_MODE="{{PROXY_MODE}}"
PAC_URL="{{PAC_URL}}"
NO_PROXY="{{NO_PROXY}}"

# URLs e Servidores
BASE_URL="{{BASE_URL}}"
HOMEPAGE="{{HOMEPAGE}}"
OCS_SERVER="{{OCS_SERVER}}"
OCS_TAG="{{OCS_TAG}}"
GLPI_SERVER="{{GLPI_SERVER}}"
PRINT_SERVER="{{PRINT_SERVER}}"
SERVIDOR_ARQUIVOS="{{SERVIDOR_ARQUIVOS}}"

# Identidade Visual
OM_ACRONYM="{{OM_ACRONYM}}"
OM_NAME="{{OM_NAME}}"
DISPLAY_NAME="{{DISPLAY_NAME}}"
WALLPAPER_URL="{{WALLPAPER_URL}}"
WALLPAPER_LOGIN_URL="{{WALLPAPER_LOGIN_URL}}"
LOGO_URL="{{LOGO_URL}}"
GREETER_URL="{{GREETER_URL}}"
THEME="{{THEME}}"

# Ambiente Grafico
DESKTOP_ENV="{{DESKTOP_ENV}}"
DISPLAY_MANAGER="{{DISPLAY_MANAGER}}"

# Aplicacoes e Funcionalidades (toggles individuais)
INSTALL_ONLYOFFICE="{{INSTALL_ONLYOFFICE}}"
INSTALL_CHROME="{{INSTALL_CHROME}}"
INSTALL_CHROMIUM="{{INSTALL_CHROMIUM}}"
INSTALL_JAVA8="{{INSTALL_JAVA8}}"
INSTALL_FIREFOX52="{{INSTALL_FIREFOX52}}"
VNC_ENABLED="{{VNC_ENABLED}}"
INVENTORY_ENABLED="{{INVENTORY_ENABLED}}"

# Repositorios
REPOSITORY_MODE="{{REPOSITORY_MODE}}"
REPOSITORY_URL="{{REPOSITORY_URL}}"
REPOSITORY_FALLBACK="{{REPOSITORY_FALLBACK}}"

# Compartilhamentos e Impressoras
COMPARTILHAMENTOS="{{COMPARTILHAMENTOS}}"
MOUNT_BASE="{{MOUNT_BASE}}"
DEFAULT_PRINTER="{{DEFAULT_PRINTER}}"
PRINTERS="{{PRINTERS}}"

# Acesso Remoto
REMOTE_METHOD="{{REMOTE_METHOD}}"
SSH_PORT="{{SSH_PORT}}"
SSH_GROUPS="{{SSH_GROUPS}}"

# Certificados
CERTIFICATE_BUNDLE="{{CERTIFICATE_BUNDLE}}"
CERTIFICATE_AUTO_INSTALL="{{CERTIFICATE_AUTO_INSTALL}}"

# Conky
CONKY_PROFILE="{{CONKY_PROFILE}}"
CONKY_CONFIG='{{CONKY_CONFIG}}'

# Servidor SeederLinux (para o agente Python)
SEEDER_SERVER="{{SEEDER_SERVER}}"

# Estado local (GPO) - NAO e uma variavel da OM, e o progresso desta
# estacao. Preservado entre regeneracoes do bundle (ver logica acima).
SERIAL_APLICADO="${SERIAL_APLICADO_ATUAL}"
EOF

chmod 644 "$CONFIG_FILE"

echo ">>> Configuracao persistente gravada em $CONFIG_FILE"
echo ">>> [13.5] Arquivo de configuracao criado!"
echo "============================================================"
$SeederScript$,
    TRUE,
    TRUE,
    13,
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Identidade Visual (Branding) (ordem 14) - core_branding.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, version, organization_id)
VALUES (
    'Identidade Visual (Branding)',
    'core_branding.sh',
    'Aplica wallpaper, logo, tema GTK e branding da OM.',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_branding.sh
# SeederLinux Lite - Wallpaper, logo, tema (varia por DE)
# ============================================================================
# Aplica identidade visual da OM: wallpaper, logo, tema GTK e configuracoes
# de aparencia. Varia conforme o ambiente grafico (DE).
# Os placeholders VARIAVEL são substituídos automaticamente
# pelo sistema na geração do bundle.
# ============================================================================

set -e

# CORRECAO: script envolvido em subshell - uma falha aqui (ex: asset
# externo que nao baixa/extrai direito) nao pode mais derrubar o
# bundle inteiro, so este modulo.
(
set -e

echo "============================================================"
echo "13 - Aplicar identidade visual (branding)"
echo "============================================================"

# ============================================================
# Variáveis
# ============================================================
OM_ACRONYM="{{OM_ACRONYM}}"
OM_NAME="{{OM_NAME}}"
DISPLAY_NAME="{{DISPLAY_NAME}}"
WALLPAPER_URL="{{WALLPAPER_URL}}"
WALLPAPER_LOGIN_URL="{{WALLPAPER_LOGIN_URL}}"
LOGO_URL="{{LOGO_URL}}"
GREETER_URL="{{GREETER_URL}}"
THEME="{{THEME}}"
DESKTOP_ENV="{{DESKTOP_ENV}}"
DISPLAY_MANAGER="{{DISPLAY_MANAGER}}"
SEEDER_SERVER="{{SEEDER_SERVER}}"

# ============================================================
# Prefixar URLs de assets com SEEDER_SERVER quando relativas
# ============================================================
for url_var in WALLPAPER_URL WALLPAPER_LOGIN_URL LOGO_URL GREETER_URL; do
    url_val="${!url_var}"
    if [ -n "$url_val" ] && [ "$url_val" != "" ]; then
        if echo "$url_val" | grep -qE '^https?://[^/]+/'; then
            continue
        fi
        server_clean="${SEEDER_SERVER%/}"
        if echo "$url_val" | grep -q '^/'; then
            eval "${url_var}=\"${server_clean}${url_val}\""
        else
            eval "${url_var}=\"${server_clean}/${url_val}\""
        fi
    fi
done

# ============================================================
# Detectar ambiente grafico se nao definido
# ============================================================
if [ -z "$DESKTOP_ENV" ] || [ "$DESKTOP_ENV" = "" ]; then
    if command -v cinnamon-session &>/dev/null; then DESKTOP_ENV="cinnamon"
    elif command -v mate-session &>/dev/null; then DESKTOP_ENV="mate"
    elif command -v gnome-session &>/dev/null; then DESKTOP_ENV="gnome"
    elif command -v startxfce4 &>/dev/null; then DESKTOP_ENV="xfce"
    elif command -v startplasma-x11 &>/dev/null; then DESKTOP_ENV="kde"
    elif command -v lxqt-session &>/dev/null; then DESKTOP_ENV="lxqt"
    elif command -v startlxde &>/dev/null; then DESKTOP_ENV="lxde"
    else DESKTOP_ENV="unknown"
    fi
fi
echo ">>> Ambiente detectado: $DESKTOP_ENV"

# ============================================================
# Detectar display manager se nao definido
# ============================================================
if [ -z "$DISPLAY_MANAGER" ] || [ "$DISPLAY_MANAGER" = "" ]; then
    if systemctl is-active --quiet lightdm 2>/dev/null; then DISPLAY_MANAGER="lightdm"
    elif systemctl is-active --quiet gdm3 2>/dev/null; then DISPLAY_MANAGER="gdm3"
    elif systemctl is-active --quiet sddm 2>/dev/null; then DISPLAY_MANAGER="sddm"
    elif [ -f /etc/X11/default-display-manager ]; then
        DISPLAY_MANAGER="$(basename "$(cat /etc/X11/default-display-manager)")"
    else DISPLAY_MANAGER="unknown"
    fi
fi
echo ">>> Display Manager detectado: $DISPLAY_MANAGER"

echo ">>> OM: $OM_ACRONYM - $OM_NAME"
echo ">>> Ambiente: $DESKTOP_ENV / $DISPLAY_MANAGER"
echo ">>> Tema: $THEME"

# ============================================================
# Criar diretorios de branding
# ============================================================
mkdir -p /usr/share/seederlinux/branding
mkdir -p /usr/share/backgrounds/seederlinux
mkdir -p /usr/share/pixmaps

# ============================================================
# Garantir perfil dconf "user" com o banco system-db:local incluido.
# Sem isso, TUDO que escrevemos em /etc/dconf/db/local.d/ (GNOME,
# Cinnamon, MATE) e ignorado pelos usuarios - dconf so aplica um
# banco de sistema se o perfil do usuario listar explicitamente
# "system-db:<nome>". Alguns pacotes de DE ja criam isso no
# postinst, mas nao e garantido em toda combinacao de distro/DE -
# entao garantimos aqui de forma idempotente.
# ============================================================
mkdir -p /etc/dconf/profile
if [ ! -f /etc/dconf/profile/user ]; then
    cat > /etc/dconf/profile/user <<EOF
user-db:user
system-db:local
EOF
elif ! grep -q "^system-db:local$" /etc/dconf/profile/user; then
    echo "system-db:local" >> /etc/dconf/profile/user
fi

# ============================================================
# Helper: baixar asset validando tamanho. Evita que um download
# falho (wget -O cria arquivo vazio) sobrescreva o asset correto -
# causa da tela preta (wallpaper zerado).
# ============================================================
_baixar_ativo() {
    local url="$1"
    local dest="$2"
    local tmp
    tmp="$(mktemp /tmp/seeder-asset.XXXXXX)"
    if wget -q --no-check-certificate --no-proxy -O "$tmp" "$url" && [ -s "$tmp" ]; then
        mv "$tmp" "$dest"
        echo ">>> $(basename "$dest") instalado"
        return 0
    else
        rm -f "$tmp"
        echo ">>> AVISO: falha/arquivo vazio ao baixar $(basename "$dest") - mantendo o existente"
        return 1
    fi
}

# ============================================================
# Baixar e instalar wallpaper
# ============================================================
echo ">>> Baixando wallpaper..."
if [ -n "$WALLPAPER_URL" ] && [ "$WALLPAPER_URL" != "" ]; then
    _baixar_ativo "$WALLPAPER_URL" /usr/share/backgrounds/seederlinux/wallpaper.jpg
else
    echo ">>> WALLPAPER_URL nao definido. Pulando wallpaper."
fi

# ============================================================
# Baixar e instalar wallpaper de login
# ============================================================
echo ">>> Baixando wallpaper de login..."
if [ -n "$WALLPAPER_LOGIN_URL" ] && [ "$WALLPAPER_LOGIN_URL" != "" ]; then
    _baixar_ativo "$WALLPAPER_LOGIN_URL" /usr/share/backgrounds/seederlinux/wallpaper-login.jpg
else
    echo ">>> WALLPAPER_LOGIN_URL nao definido. Pulando wallpaper de login."
fi

# ============================================================
# Baixar e instalar logo
# ============================================================
echo ">>> Baixando logo..."
if [ -n "$LOGO_URL" ] && [ "$LOGO_URL" != "" ]; then
    _baixar_ativo "$LOGO_URL" /usr/share/pixmaps/seederlinux-logo.png
else
    echo ">>> LOGO_URL nao definido. Pulando logo."
fi

# ============================================================
# Baixar e instalar greeter personalizado
# ============================================================
# GREETER_URL pode ser:
#   - um pacote compactado (tar/gzip/bzip2/xz) com tema de greeter
#     personalizado, OU
#   - uma imagem (.jpg, .jpeg, .png, .bmp, .gif, .webp, .tif, ...)
#     que sera usada como wallpaper de login.
#
# Deteccao por conteudo (MIME type via magic bytes), NAO por
# extensao do arquivo - funciona com qualquer formato, mesmo que o
# nome/extensao esteja errado. Corrige o achado em teste real (Linux
# Mint Cinnamon): GREETER_URL apontando pra .jpg fazia `tar xzf`
# falhar e, como este script nao estava em subshell, derrubava o
# bundle inteiro. Agora, alem de nao travar mais nada, a imagem e
# de fato aproveitada em vez de descartada.
# ============================================================
echo ">>> Baixando greeter..."
if [ -n "$GREETER_URL" ] && [ "$GREETER_URL" != "" ]; then
    GREETER_TARBALL="/tmp/seederlinux-greeter.bin"
    if wget -q --no-check-certificate --no-proxy -O "$GREETER_TARBALL" "$GREETER_URL" && [ -s "$GREETER_TARBALL" ]; then
        GREETER_MIME="$(file -b --mime-type "$GREETER_TARBALL" 2>/dev/null)"
        echo ">>> Greeter detectado como: ${GREETER_MIME:-desconhecido}"

        case "$GREETER_MIME" in
            # --- Caso 1: arquivo compactado (tar/gzip/bzip2/xz) ---
            application/gzip|application/x-gzip|application/x-tar|\
            application/x-bzip2|application/x-xz|application/octet-stream)
                # octet-stream e ambiguo - confirmar via file -b (magic)
                GREETER_FILETYPE="$(file -b "$GREETER_TARBALL" 2>/dev/null)"
                if echo "$GREETER_FILETYPE" | grep -qiE 'gzip|tar|bzip2|xz'; then
                    mkdir -p /tmp/seederlinux-greeter
                    if tar xf "$GREETER_TARBALL" -C /tmp/seederlinux-greeter 2>/dev/null; then
                        case "$DISPLAY_MANAGER" in
                            lightdm)
                                cp -r /tmp/seederlinux-greeter/* /usr/share/lightdm/ 2>/dev/null || true
                                ;;
                            gdm3)
                                cp -r /tmp/seederlinux-greeter/* /usr/share/gdm/ 2>/dev/null || true
                                ;;
                            sddm)
                                cp -r /tmp/seederlinux-greeter/* /usr/share/sddm/themes/ 2>/dev/null || true
                                ;;
                        esac
                        echo ">>> Greeter (pacote) instalado"
                    else
                        echo ">>> AVISO: falha ao extrair o pacote do greeter."
                    fi
                    rm -rf /tmp/seederlinux-greeter
                else
                    echo ">>> AVISO: conteudo nao reconhecido como tar/gzip/bzip2/xz."
                fi
                ;;

            # --- Caso 2: qualquer imagem ---
            image/*)
                GREETER_EXT="${GREETER_MIME#image/}"
                case "$GREETER_EXT" in
                    jpeg) GREETER_EXT="jpg" ;;
                    x-ms-bmp) GREETER_EXT="bmp" ;;
                    x-icon) GREETER_EXT="ico" ;;
                    svg+xml) GREETER_EXT="svg" ;;
                    x-portable-pixmap) GREETER_EXT="ppm" ;;
                    tiff) GREETER_EXT="tif" ;;
                esac
                GREETER_IMG="/usr/share/backgrounds/seederlinux/greeter.${GREETER_EXT}"
                cp "$GREETER_TARBALL" "$GREETER_IMG"
                echo ">>> Greeter (imagem ${GREETER_EXT}) instalado: $GREETER_IMG"

                # Se WALLPAPER_LOGIN_URL nao foi definido OU o arquivo
                # de wallpaper de login ainda nao existe, usar o
                # greeter como wallpaper de login. Copiado com nome
                # fixo wallpaper-login.jpg independente do formato
                # real - GTK/LightDM/GDM3/SDDM detectam o formato pelo
                # conteudo (magic bytes), nao pela extensao, entao
                # isso nao quebra a leitura. Ressalva: formatos menos
                # comuns (webp, svg) dependem do loader gdk-pixbuf
                # correspondente estar instalado na imagem do SO.
                if [ -z "$WALLPAPER_LOGIN_URL" ] || [ ! -f /usr/share/backgrounds/seederlinux/wallpaper-login.jpg ]; then
                    cp "$GREETER_TARBALL" /usr/share/backgrounds/seederlinux/wallpaper-login.jpg
                    echo ">>> Greeter usado como wallpaper de login"
                else
                    echo ">>> Wallpaper de login proprio ja instalado - greeter mantido apenas em $GREETER_IMG"
                fi
                ;;

            # --- Caso 3: qualquer outra coisa ---
            *)
                echo ">>> AVISO: GREETER_URL nao e imagem nem pacote compactado valido"
                echo ">>> (detectado como: ${GREETER_MIME:-desconhecido}). Pulando greeter customizado."
                ;;
        esac

        rm -f "$GREETER_TARBALL"
    else
        echo ">>> AVISO: greeter baixado vazio ou com falha - pulando"
        rm -f "$GREETER_TARBALL"
    fi
fi

# ============================================================
# ============================================================
# Aplicar tema GTK (SOMENTE se THEME foi definido explicitamente)
# ============================================================
# CORRECAO (achado em teste real): THEME="DEFAULT" (valor de fato
# configurado nas OMs) NAO e um tema GTK valido - "DEFAULT" nao
# existe em /usr/share/themes, entao gtk-theme-name=DEFAULT e
# simplesmente ignorado pelo GTK. Pior: theme-name=DEFAULT no
# greeter e ColorScheme=DEFAULT no KDE tambem nao fazem nada. Agora
# so aplicamos tema se THEME vier definido E existir de verdade em
# /usr/share/themes - caso contrario mantemos o tema atual do
# sistema/DE, sem sobrescrever nada.
echo ">>> Aplicando tema GTK: $THEME"
THEME_APLICAR=false

if [ -z "$THEME" ] || [ "$THEME" = "DEFAULT" ]; then
    echo ">>> THEME=DEFAULT (ou vazio) - mantendo tema atual do sistema."
elif [ -d "/usr/share/themes/$THEME" ]; then
    THEME_APLICAR=true
    echo ">>> THEME=$THEME - tema encontrado em /usr/share/themes."
else
    echo ">>> AVISO: THEME=$THEME nao existe em /usr/share/themes - mantendo tema atual."
fi

if [ "$THEME_APLICAR" = "true" ]; then
    mkdir -p /etc/skel/.config/gtk-3.0
    cat > /etc/skel/.config/gtk-3.0/settings.ini <<EOF
[Settings]
gtk-theme-name=${THEME}
gtk-icon-theme-name=Adwaita
gtk-font-name=DejaVu Sans 10
gtk-cursor-theme-name=Adwaita
gtk-cursor-theme-size=16
gtk-toolbar-style=GTK_TOOLBAR_BOTH
gtk-toolbar-icon-size=GTK_ICON_SIZE_LARGE_TOOLBAR
gtk-button-images=1
gtk-menu-images=1
gtk-application-prefer-dark-theme=0
EOF
    echo ">>> Tema GTK configurado: $THEME"
else
    echo ">>> Tema GTK NAO foi alterado (DEFAULT ou inexistente)."
fi

# ============================================================
# Aplicar wallpaper e configuracoes conforme o DE
# ============================================================
echo ">>> Aplicando configuracoes para: $DESKTOP_ENV"

case "$DESKTOP_ENV" in
    cinnamon)
        # CORRECAO: Cinnamon usa dconf (e um fork do GNOME), nao um
        # arquivo de configuracao solto. A versao anterior escrevia em
        # /etc/skel/.config/cinnamon-settings.conf, que o Cinnamon
        # nunca le - nao tinha efeito nenhum. Usar dconf keyfile igual
        # ao branch do GNOME, com sintaxe de caminho (barras), nao a
        # notacao com pontos do schema id.
        mkdir -p /etc/dconf/db/local.d
        cat > /etc/dconf/db/local.d/seederlinux-branding-cinnamon <<EOF
[org/cinnamon/desktop/background]
picture-uri='file:///usr/share/backgrounds/seederlinux/wallpaper.jpg'
picture-options='zoom'
EOF
        if [ "$THEME_APLICAR" = "true" ]; then
            cat >> /etc/dconf/db/local.d/seederlinux-branding-cinnamon <<EOF

[org/cinnamon/desktop/interface]
gtk-theme='${THEME}'
icon-theme-name='Adwaita'

[org/cinnamon/theme]
name='${THEME}'
EOF
        fi
        dconf update 2>/dev/null || true
        ;;

    mate)
        # CORRECAO: mesmo problema do Cinnamon - MATE tambem usa dconf,
        # nao /etc/skel/.config/mate-background.conf (nunca lido).
        mkdir -p /etc/dconf/db/local.d
        cat > /etc/dconf/db/local.d/seederlinux-branding-mate <<EOF
[org/mate/desktop/background]
picture-filename='/usr/share/backgrounds/seederlinux/wallpaper.jpg'
picture-options='zoom'
EOF
        if [ "$THEME_APLICAR" = "true" ]; then
            cat >> /etc/dconf/db/local.d/seederlinux-branding-mate <<EOF

[org/mate/desktop/interface]
gtk-theme='${THEME}'
icon-theme='Adwaita'
EOF
        fi
        dconf update 2>/dev/null || true
        ;;

    gnome)
        # GNOME - via gsettings (dconf)
        mkdir -p /etc/dconf/db/local.d
        cat > /etc/dconf/db/local.d/seederlinux-branding <<EOF
[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/seederlinux/wallpaper.jpg'
picture-uri-dark='file:///usr/share/backgrounds/seederlinux/wallpaper.jpg'
picture-options='zoom'

[org/gnome/login-screen]
logo='/usr/share/pixmaps/seederlinux-logo.png'
EOF
        if [ "$THEME_APLICAR" = "true" ]; then
            cat >> /etc/dconf/db/local.d/seederlinux-branding <<EOF

[org/gnome/desktop/interface]
gtk-theme='${THEME}'
icon-theme='Adwaita'
EOF
        fi
        dconf update 2>/dev/null || true
        ;;

    xfce)
        # XFCE - via xfconf
        mkdir -p /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml
        cat > /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitor0" type="empty">
        <property name="image-path" type="string" value="/usr/share/backgrounds/seederlinux/wallpaper.jpg"/>
        <property name="image-style" type="int" value="5"/>
      </property>
    </property>
  </property>
</channel>
EOF
        ;;

    kde)
        # KDE Plasma - via kdeglobals (SOMENTE se THEME_APLICAR)
        if [ "$THEME_APLICAR" = "true" ]; then
            mkdir -p /etc/skel/.config
            cat > /etc/skel/.config/kdeglobals <<EOF
[General]
ColorScheme=${THEME}
Name=${THEME}

[KDE]
widgetStyle=${THEME}
EOF
        fi
        # Wallpaper via plasma config (independe de tema)
        mkdir -p /etc/skel/.config
        cat > /etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc <<EOF
[Containments][1][Wallpaper][org.kde.image][General]
Image=file:///usr/share/backgrounds/seederlinux/wallpaper.jpg
EOF
        ;;

    lxde)
        # LXDE - via pcmanfm
        mkdir -p /etc/skel/.config/pcmanfm/LXDE
        cat > /etc/skel/.config/pcmanfm/LXDE/pcmanfm.conf <<EOF
[desktop]
wallpaper_mode=crop
wallpaper=/usr/share/backgrounds/seederlinux/wallpaper.jpg
EOF
        ;;
esac

# ============================================================
# Configurar wallpaper de login (greeter)
# CORRECAO: theme-name=${THEME} incondicional removido do LightDM -
# mesmo problema do THEME=DEFAULT explicado acima.
# ============================================================
echo ">>> Configurando wallpaper de login..."
case "$DISPLAY_MANAGER" in
    lightdm)
        mkdir -p /etc/lightdm
        if [ -f /usr/share/backgrounds/seederlinux/wallpaper-login.jpg ]; then
            cat > /etc/lightdm/lightdm-gtk-greeter.conf <<EOF
[greeter]
background=/usr/share/backgrounds/seederlinux/wallpaper-login.jpg
logo=/usr/share/pixmaps/seederlinux-logo.png
icon-theme-name=Adwaita
font-name=DejaVu Sans 10
EOF
            if [ "$THEME_APLICAR" = "true" ]; then
                echo "theme-name=${THEME}" >> /etc/lightdm/lightdm-gtk-greeter.conf
            fi
        fi
        ;;
    gdm3)
        if [ -f /usr/share/backgrounds/seederlinux/wallpaper-login.jpg ]; then
            # GDM3 usa dconf para configuracao
            mkdir -p /etc/dconf/db/gdm.d
            cat > /etc/dconf/db/gdm.d/01-seederlinux-background <<EOF
[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/seederlinux/wallpaper-login.jpg'
picture-options='zoom'
EOF
            dconf update 2>/dev/null || true
        fi
        ;;
    sddm)
        if [ -f /usr/share/backgrounds/seederlinux/wallpaper-login.jpg ]; then
            mkdir -p /etc/sddm.conf.d
            cat > /etc/sddm.conf.d/seederlinux.conf <<EOF
[Theme]
ThemeDir=/usr/share/sddm/themes
Current=seederlinux
Background=/usr/share/backgrounds/seederlinux/wallpaper-login.jpg
EOF
        fi
        ;;
esac

echo ">>> [13] Identidade visual aplicada!"
echo "============================================================"
)
$SeederScript$,
    TRUE,
    TRUE,
    14,
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Script de Logon Persistente (ordem 15) - core_logon.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, version, organization_id)
VALUES (
    'Script de Logon Persistente',
    'core_logon.sh',
    'Script executado a cada logon de usuario (multi-DE).',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_logon.sh
# SeederLinux Lite - Logon MINIMALISTA (via autostart XDG)
# ============================================================================
# MUDANCA DE ARQUITETURA:
# A versao anterior era chamada pelo display manager via
# session-setup-script (LightDM) / PreSession (GDM3) / Xsetup (SDDM) -
# hooks que rodam como ROOT, ANTES da sessao grafica existir. Isso e
# documentado assim nos tres DMs: sem $HOME/$USER do usuario real e
# sem D-Bus de sessao, o que tornava suspeita a eficacia de tudo que
# dependia desses dois (montagem em $HOME, gsettings, etc).
#
# Agora o /usr/local/bin/seederlinux-logon roda via ENTRADA DE
# AUTOSTART XDG (/etc/xdg/autostart/), que e honrada por GNOME,
# Cinnamon, MATE, XFCE, KDE e LXDE de forma padronizada - executando
# DENTRO da sessao ja iniciada, como o proprio usuario, com $HOME,
# $USER e D-Bus corretos. Um mecanismo so para qualquer DE/DM.
#
# ESCOPO REDUZIDO (minimalista, conforme especificacao original):
# so o que precisa rodar em TODO login e e rapido (< 3s): montar
# compartilhamentos, impressora padrao, atalhos. Branding, tema,
# politicas de navegador, proxy, certificados etc. NAO rodam mais
# aqui - isso agora e responsabilidade do core_sync.sh (aplicador
# tipo GPO, rodando via timer systemd, independente de login).
#
# PRIVILEGIO: como o script agora roda como usuario comum (nao root),
# `mount`/`umount` dos compartilhamentos CIFS precisam de sudo. Uma
# regra sudoers bem restrita (so mount.cifs/umount na pasta de
# compartilhamentos + o binario seeder-sync, nada generico) e criada
# abaixo.
#
# Os placeholders VARIAVEL são substituídos automaticamente
# pelo sistema na geração do bundle.
# ============================================================================

set -e

echo "============================================================"
echo "15 - Logon minimalista (via autostart)"
echo "============================================================"

# ============================================================
# Variáveis
# ============================================================
SERVIDOR_ARQUIVOS="{{SERVIDOR_ARQUIVOS}}"
COMPARTILHAMENTOS="{{COMPARTILHAMENTOS}}"
MOUNT_BASE="{{MOUNT_BASE}}"
DEFAULT_PRINTER="{{DEFAULT_PRINTER}}"
HOMEPAGE="{{HOMEPAGE}}"
OM_ACRONYM="{{OM_ACRONYM}}"
DOMINIO_NETBIOS="{{DOMINIO_NETBIOS}}"

MOUNT_DIR="${MOUNT_BASE:-/mnt}"

# ============================================================
# 1. Regra sudoers restrita - mount/umount de CIFS (so na pasta de
#    compartilhamentos) e o binario seeder-sync (sem argumentos).
#    Nada mais e liberado por essa regra.
# ============================================================
echo ">>> Configurando sudoers restrito para logon..."
SUDOERS_FILE="/etc/sudoers.d/seederlinux-logon"
cat > "$SUDOERS_FILE" <<EOF
# SeederLinux - permissoes minimas para o logon do usuario (nao roda
# mais como root). Restrito a mount/umount de CIFS dentro de
# ${MOUNT_DIR} e ao disparo do seeder-sync - nada generico.
Cmnd_Alias SEEDERLINUX_MOUNT = /bin/mount -t cifs *, /usr/bin/mount -t cifs *
Cmnd_Alias SEEDERLINUX_UMOUNT = /bin/umount ${MOUNT_DIR}/*, /usr/bin/umount ${MOUNT_DIR}/*
Cmnd_Alias SEEDERLINUX_SYNC = /usr/local/bin/seeder-sync
ALL ALL=(root) NOPASSWD: SEEDERLINUX_MOUNT, SEEDERLINUX_UMOUNT, SEEDERLINUX_SYNC
EOF
chmod 440 "$SUDOERS_FILE"
if ! visudo -cf "$SUDOERS_FILE"; then
    echo ">>> ERRO: sintaxe invalida no sudoers gerado. Removendo."
    rm -f "$SUDOERS_FILE"
    exit 1
fi
echo ">>> sudoers configurado: $SUDOERS_FILE"

# ============================================================
# 2. Preparar diretorio de log (mundo-gravavel com sticky bit, ja
#    que quem escreve agora e o usuario comum, nao mais root)
# ============================================================
mkdir -p /var/log/logon-logoff
chmod 1777 /var/log/logon-logoff

# ============================================================
# 3. Pre-criar os pontos de montagem (como root, agora, uma vez)
# ============================================================
mkdir -p "$MOUNT_DIR"
if [ -n "$COMPARTILHAMENTOS" ]; then
    for SHARE in $COMPARTILHAMENTOS; do
        mkdir -p "${MOUNT_DIR}/${SHARE}"
    done
fi
chmod 755 "$MOUNT_DIR"

# ============================================================
# 4. Criar o script PERMANENTE em /usr/local/bin/seederlinux-logon
#    Sera chamado via autostart XDG a cada login, DENTRO da sessao
#    do usuario (nao mais como hook do display manager).
# ============================================================
echo ">>> Criando script permanente: /usr/local/bin/seederlinux-logon"

cat > /usr/local/bin/seederlinux-logon <<'PERMSCRIPT'
#!/bin/bash
# seederlinux-logon - script MINIMALISTA de logon do SeederLinux.
# Executado via autostart XDG (dentro da sessao do usuario).
# Alvo: menos de 3 segundos. So o que precisa rodar em TODO login.

CONFIG_FILE="/etc/seederlinux/config.env"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
else
    exit 0
fi

USERNAME="${USER:-$(whoami)}"
USER_HOME="${HOME:-/home/$USERNAME}"
LOG_FILE="/var/log/logon-logoff/logon_${USERNAME}.log"

exec >> "$LOG_FILE" 2>&1
echo "=== Logon (minimo): $(date) - Usuario: $USERNAME ==="

# ============================================================
# Diretorios basicos do usuario (idempotente, rapido)
# ============================================================
mkdir -p "$USER_HOME/Desktop" "$USER_HOME/Downloads" "$USER_HOME/Documents" 2>/dev/null || true

# ============================================================
# Montar compartilhamentos CIFS (via sudo restrito - ver sudoers)
# ============================================================
if [ -n "$SERVIDOR_ARQUIVOS" ] && [ -n "$COMPARTILHAMENTOS" ]; then
    MOUNT_DIR="${MOUNT_BASE:-/mnt}"
    for SHARE in $COMPARTILHAMENTOS; do
        SHARE_MOUNT="${MOUNT_DIR}/${SHARE}"
        if ! mountpoint -q "$SHARE_MOUNT" 2>/dev/null; then
            sudo -n mount -t cifs "//${SERVIDOR_ARQUIVOS}/${SHARE}" "$SHARE_MOUNT" \
                -o "username=${USERNAME},domain=${DOMINIO_NETBIOS},uid=$(id -u),gid=$(id -g),iocharset=utf8,vers=3.0" \
                2>/dev/null && echo "Compartilhamento montado: ${SHARE}" \
                || echo "AVISO: falha ao montar ${SHARE} (verifique credenciais/sudoers)"
        fi

        cat > "$USER_HOME/Desktop/${SHARE}.desktop" <<EOF
[Desktop Entry]
Type=Link
Name=${SHARE}
URL=file://${SHARE_MOUNT}
Icon=folder
EOF
        chmod +x "$USER_HOME/Desktop/${SHARE}.desktop" 2>/dev/null || true
    done
fi

# ============================================================
# Impressora padrao (config per-user do CUPS, nao precisa root)
# ============================================================
if [ -n "$DEFAULT_PRINTER" ]; then
    lpoptions -d "$DEFAULT_PRINTER" 2>/dev/null || true
fi

# ============================================================
# Atalho do portal
# ============================================================
if [ -n "$HOMEPAGE" ]; then
    cat > "$USER_HOME/Desktop/Portal-${OM_ACRONYM}.desktop" <<EOF
[Desktop Entry]
Type=Link
Name=Portal ${OM_ACRONYM}
URL=${HOMEPAGE}
Icon=web-browser
EOF
    chmod +x "$USER_HOME/Desktop/Portal-${OM_ACRONYM}.desktop" 2>/dev/null || true
fi

# ============================================================
# Disparar seeder-sync em background, so se o timer ainda nao
# estiver ativo (ex: bundle rodado antes do core_sync.sh, ou timer
# desabilitado manualmente) - nao bloqueia o login esperando.
# ============================================================
if ! systemctl is-active --quiet seeder-sync.timer 2>/dev/null; then
    ( sudo -n /usr/local/bin/seeder-sync >/dev/null 2>&1 & ) 2>/dev/null || true
fi

echo "=== Logon concluido: $(date) ==="
exit 0
PERMSCRIPT

chmod 755 /usr/local/bin/seederlinux-logon
echo ">>> Script permanente criado: /usr/local/bin/seederlinux-logon"

# ============================================================
# 5. Registrar via autostart XDG (funciona em GNOME, Cinnamon, MATE,
#    XFCE, KDE, LXDE/LXQt de forma padronizada - um mecanismo so)
# ============================================================
echo ">>> Registrando autostart..."
mkdir -p /etc/xdg/autostart
cat > /etc/xdg/autostart/seederlinux-logon.desktop <<EOF
[Desktop Entry]
Type=Application
Name=SeederLinux Logon
Comment=Monta compartilhamentos e aplica configuracoes essenciais de logon
Exec=/usr/local/bin/seederlinux-logon
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
X-KDE-autostart-after=panel
EOF

echo ">>> [15] Logon minimalista instalado (via autostart)!"
echo "============================================================"
$SeederScript$,
    TRUE,
    TRUE,
    15,
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Alteracao de Senha (ordem 16) - core_password_change.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, version, organization_id)
VALUES (
    'Alteracao de Senha',
    'core_password_change.sh',
    'Configura a alteracao de senha do usuario no dominio.',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_password_change.sh
# SeederLinux Lite - Troca de Senha do Active Directory
# ============================================================================
# Instala um aplicativo gráfico (Zenity) para troca de senha no AD.
# É executado pelo bundle para instalar o script; a troca de senha
# em si é feita pelo usuário quando desejar.
# ============================================================================

(
set -e

echo "============================================================"
echo "16 - Instalar aplicativo de troca de senha AD"
echo "============================================================"

INSTALL_PASSWORD_CHANGER="{{INSTALL_PASSWORD_CHANGER}}"

if [ "$INSTALL_PASSWORD_CHANGER" != "true" ]; then
    echo ">>> Instalacao do trocador de senha desativada. Pulando."
    echo ">>> [16] Trocador de senha ignorado."
    echo "============================================================"
    exit 0
fi

DOMINIO="{{DOMINIO}}"
OM_ACRONYM="{{OM_ACRONYM}}"

echo ">>> Instalando aplicativo de troca de senha..."

# Criar o script de troca de senha
cat > /usr/local/bin/trocar-senha << 'EOFSCRIPT'
#!/bin/bash
# ============================================================================
# Troca de Senha - Active Directory
# Interface gráfica com Zenity para alteração de senha no domínio
# ============================================================================

DOMINIO="{{DOMINIO}}"
OM_ACRONYM="{{OM_ACRONYM}}"

trocar_senha() {
    IFS='|' read -r OldPasswd NewPasswd1 NewPasswd2 <<< \
    $(zenity --forms --title="Trocar Senha do Usuário" \
        --text="Usuário: $USER\nDomínio: $DOMINIO" \
        --add-password="Senha atual" \
        --add-password="Nova Senha" \
        --add-password="Confirme a nova senha" \
        --width=450 \
        --height=250)

    if [ -z "$OldPasswd" ] || [ -z "$NewPasswd1" ]; then
        zenity --error --title="Erro" --text="Todos os campos devem ser preenchidos."
        return 1
    fi

    while [ "$NewPasswd1" != "$NewPasswd2" ]; do
        NewPasswd1=$(zenity --entry \
            --title="Trocar Senha" \
            --text="As senhas não coincidem!\n\nDigite a nova senha:" \
            --hide-text \
            --width=400)

        if [ -z "$NewPasswd1" ]; then
            zenity --error --title="Erro" --text="Operação cancelada."
            return 1
        fi

        NewPasswd2=$(zenity --entry \
            --title="Trocar Senha" \
            --text="Confirme a nova senha:" \
            --hide-text \
            --width=400)
    done

    if [ ${#NewPasswd1} -lt 7 ]; then
        zenity --error \
            --title="Senha muito curta" \
            --text="A nova senha deve ter no mínimo 7 caracteres.\n\nRequisitos do Active Directory:\n• Mínimo 7 caracteres\n• Pelo menos 3 dos 4 tipos:\n  - Maiúsculas (A-Z)\n  - Minúsculas (a-z)\n  - Números (0-9)\n  - Símbolos (@#\$% etc)"
        return 1
    fi

    DC_ONLINE=""
    for DC in $(host -t SRV _ldap._tcp.$DOMINIO 2>/dev/null | awk '{print $NF}' | sed 's/\.$//'); do
        if ping -c 1 -W 2 "$DC" > /dev/null 2>&1; then
            DC_ONLINE="$DC"
            break
        fi
    done

    if [ -z "$DC_ONLINE" ]; then
        DC_ONLINE="dc-${OM_ACRONYM,,}.$DOMINIO"
    fi

    echo -e "$OldPasswd\n$NewPasswd1\n$NewPasswd1" | smbpasswd -r "$DC_ONLINE" -U "$USER" > /tmp/password-change.log 2>&1

    if grep -q "Password changed" /tmp/password-change.log; then
        zenity --info \
            --title="Sucesso" \
            --text="Senha alterada com sucesso!\n\nA nova senha entrará em vigor imediatamente.\nRecomenda-se fazer logoff e login novamente." \
            --width=400
        rm -f /tmp/password-change.log
        return 0
    else
        ERRO=$(cat /tmp/password-change.log 2>/dev/null | tail -5)
        zenity --error \
            --title="Erro ao trocar senha" \
            --text="Não foi possível alterar a senha.\n\nMotivos possíveis:\n• Senha atual incorreta\n• Senha nova não atende aos requisitos\n• Controlador de domínio indisponível\n\nDetalhes técnicos:\n$ERRO" \
            --width=500
        rm -f /tmp/password-change.log
        return 1
    fi
}

if ! command -v zenity &>/dev/null; then
    echo "Erro: zenity não está instalado."
    echo "Execute: sudo apt-get install -y zenity"
    exit 1
fi

if ! command -v smbpasswd &>/dev/null; then
    echo "Erro: smbpasswd não está instalado."
    echo "Execute: sudo apt-get install -y samba-common-bin"
    exit 1
fi

trocar_senha

exit $?
EOFSCRIPT

chmod 755 /usr/local/bin/trocar-senha
echo ">>> Script de troca de senha instalado em /usr/local/bin/trocar-senha"

# Criar entrada no menu de aplicativos
cat > /usr/share/applications/trocar-senha.desktop << EOF
[Desktop Entry]
Version=1.0
Name=Trocar Senha
Name[pt_BR]=Trocar Senha
Comment=Alterar senha do Active Directory
Comment[pt_BR]=Alterar senha do Active Directory
Exec=/usr/local/bin/trocar-senha
Icon=dialog-password
Terminal=false
Type=Application
Categories=System;Settings;
StartupNotify=true
EOF

echo ">>> Atalho no menu criado"

# Criar atalho na área de trabalho (todos os usuários futuros via /etc/skel)
if [ -d /etc/skel ]; then
    mkdir -p /etc/skel/Desktop
    cp /usr/share/applications/trocar-senha.desktop /etc/skel/Desktop/
    chmod +x /etc/skel/Desktop/trocar-senha.desktop 2>/dev/null || true
fi

# Criar atalho para usuários existentes com diretório home em /home
for USER_HOME in /home/*/; do
    if [ -d "${USER_HOME}Desktop" ]; then
        cp /usr/share/applications/trocar-senha.desktop "${USER_HOME}Desktop/"
        chmod +x "${USER_HOME}Desktop/trocar-senha.desktop" 2>/dev/null || true
    fi
done

echo ">>> Atalhos na area de trabalho criados"
echo ">>> [16] Aplicativo de troca de senha instalado!"
echo "============================================================"
)
$SeederScript$,
    TRUE,
    TRUE,
    16,
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Script de Logoff Persistente (ordem 17) - core_logoff.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, version, organization_id)
VALUES (
    'Script de Logoff Persistente',
    'core_logoff.sh',
    'Script executado a cada logoff de usuario.',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_logoff.sh
# SeederLinux Lite - Logoff MINIMALISTA
# ============================================================================
# Ao contrario do logon, o logoff CONTINUA sendo chamado pelo display
# manager (session-cleanup-script no LightDM / PostSession no GDM3 /
# Xstop no SDDM) - roda como root. Isso e adequado aqui: desmontar
# compartilhamentos e matar processos por usuario nao depende de D-Bus
# de sessao, e precisa de privilegio de root de qualquer forma.
#
# CORRECAO: a versao anterior confiava em `$USER`/`whoami` para saber
# de quem e a sessao que esta terminando. Nesses hooks de DM (rodando
# como root, ANTES/DURANTE o encerramento da sessao), $USER nao e
# garantidamente o usuario que esta saindo - pode nao estar setado,
# ou apontar pra root. Agora a resolucao do usuario segue uma cascata:
#   1) $1 (primeiro argumento - e como LightDM/GDM3 normalmente
#      informam o usuario da sessao para esses hooks)
#   2) $PAM_USER (presente se invocado via pam_exec em algum fluxo)
#   3) loginctl - sessao grafica mais recente
#   4) $USER como ultimo recurso
#
# ESCOPO REDUZIDO (minimalista): so desmonta, limpa cache/lixeira/
# temporarios e mata processos do usuario (Conky, x11vnc). Nao aplica
# nenhuma configuracao - isso e trabalho do core_sync.sh.
#
# Os placeholders VARIAVEL sao substituidos automaticamente
# pelo sistema na geracao do bundle.
# ============================================================================

set -e

echo "============================================================"
echo "16 - Logoff minimalista"
echo "============================================================"

# ============================================================
# Variaveis (substituidas no bundle)
# ============================================================
DOMINIO_NETBIOS="{{DOMINIO_NETBIOS}}"
SERVIDOR_ARQUIVOS="{{SERVIDOR_ARQUIVOS}}"
COMPARTILHAMENTOS="{{COMPARTILHAMENTOS}}"
MOUNT_BASE="{{MOUNT_BASE}}"

# ============================================================
# 1. Criar o script PERMANENTE em /usr/local/bin/seederlinux-logoff
# ============================================================
echo ">>> Criando script permanente: /usr/local/bin/seederlinux-logoff"

cat > /usr/local/bin/seederlinux-logoff <<'PERMSCRIPT'
#!/bin/bash
# seederlinux-logoff - script MINIMALISTA de logoff do SeederLinux.
# Chamado pelo display manager (root) a cada logoff.

CONFIG_FILE="/etc/seederlinux/config.env"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

# ============================================================
# Resolver o usuario que esta saindo - nao confiar so em $USER
# ============================================================
USERNAME="${1:-}"
[ -z "$USERNAME" ] && USERNAME="${PAM_USER:-}"
if [ -z "$USERNAME" ] || [ "$USERNAME" = "root" ]; then
    # Fallback: sessao grafica mais recente via loginctl
    USERNAME="$(loginctl list-sessions --no-legend 2>/dev/null \
                | awk '{print $3}' | grep -v '^root$' | tail -n1)"
fi
[ -z "$USERNAME" ] && USERNAME="${USER:-}"

if [ -z "$USERNAME" ] || [ "$USERNAME" = "root" ]; then
    echo ">>> [logoff] AVISO: nao foi possivel determinar o usuario da sessao. Abortando limpeza."
    exit 0
fi

USER_HOME="$(getent passwd "$USERNAME" | cut -d: -f6)"
[ -z "$USER_HOME" ] && USER_HOME="/home/$USERNAME"

LOG_DIR="/var/log/logon-logoff"
LOG_FILE="$LOG_DIR/logoff_${USERNAME}.log"
mkdir -p "$LOG_DIR"

exec >> "$LOG_FILE" 2>&1
echo "=== Logoff (minimo): $(date) - Usuario: $USERNAME ==="

# ============================================================
# Desmontar compartilhamentos CIFS do usuario
# ============================================================
if [ -n "$COMPARTILHAMENTOS" ]; then
    MOUNT_DIR="${MOUNT_BASE:-/mnt}"
    for SHARE in $COMPARTILHAMENTOS; do
        SHARE_MOUNT="${MOUNT_DIR}/${SHARE}"
        if mountpoint -q "$SHARE_MOUNT" 2>/dev/null; then
            umount "$SHARE_MOUNT" 2>/dev/null || umount -l "$SHARE_MOUNT" 2>/dev/null || {
                echo ">>> [logoff] AVISO: falha ao desmontar ${SHARE_MOUNT}"
            }
            echo ">>> [logoff] Compartilhamento desmontado: ${SHARE}"
        fi
    done
fi

# ============================================================
# Limpar cache de navegadores
# ============================================================
rm -rf "$USER_HOME/.cache/mozilla" 2>/dev/null || true
rm -rf "$USER_HOME/.cache/google-chrome" 2>/dev/null || true
rm -rf "$USER_HOME/.cache/chromium" 2>/dev/null || true
rm -rf "$USER_HOME/.cache/thumbnails" 2>/dev/null || true

# ============================================================
# Esvaziar lixeira
# ============================================================
rm -rf "${USER_HOME:?}/.local/share/Trash"/* 2>/dev/null || true

# ============================================================
# Remover temporarios do usuario (mais de 60min)
# ============================================================
find /tmp -user "$USERNAME" -type f -mmin +60 -delete 2>/dev/null || true

# ============================================================
# Remover atalhos de compartilhamentos (evita atalho morto se o
# mapeamento mudar antes do proximo login)
# ============================================================
if [ -n "$COMPARTILHAMENTOS" ]; then
    for SHARE in $COMPARTILHAMENTOS; do
        rm -f "$USER_HOME/Desktop/${SHARE}.desktop" 2>/dev/null || true
    done
fi

# ============================================================
# Finalizar processos do usuario (Conky, x11vnc)
# ============================================================
killall -u "$USERNAME" conky 2>/dev/null || true
killall -u "$USERNAME" x11vnc 2>/dev/null || true

# ============================================================
# Rotacionar logs (manter 7 dias)
# ============================================================
find "$LOG_DIR" -name "logoff_*.log" -mtime +7 -delete 2>/dev/null || true
find "$LOG_DIR" -name "logon_*.log" -mtime +7 -delete 2>/dev/null || true

echo "=== Logoff concluido: $(date) ==="
exit 0
PERMSCRIPT

chmod 755 /usr/local/bin/seederlinux-logoff
echo ">>> Script permanente criado: /usr/local/bin/seederlinux-logoff"
echo ">>> [16] Logoff minimalista instalado!"
echo "============================================================"
$SeederScript$,
    TRUE,
    TRUE,
    17,
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Sessao LightDM (ordem 18) - core_session_lightdm.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, version, organization_id)
VALUES (
    'Sessao LightDM',
    'core_session_lightdm.sh',
    'Configura LightDM como display manager (autoselecao via DISPLAY_MANAGER=lightdm).',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_session_lightdm.sh
# SeederLinux Lite - LightDM: logon/logoff (MATE, Cinnamon, XFCE, LXDE)
# ============================================================================
# Configura o LightDM como display manager e define os scripts de logon
# e logoff que serao executados nas transicoes de sessao.
#
# Resolucao de DESKTOP_ENV/DISPLAY_MANAGER (nessa ordem):
#   1) Valor injetado pela OM ({{DESKTOP_ENV}} / {{DISPLAY_MANAGER}})
#   2) Valor ja persistido em /etc/seederlinux/config.env (escrito por
#      este mesmo script em uma execucao anterior, ou por outro dos
#      scripts de sessao no mesmo bundle)
#   3) Deteccao em runtime: DM ja ativo -> DM ja instalado -> padrao
#      por DE (gnome->gdm3, kde->sddm, qualquer outro->lightdm)
#
# O resultado final e sempre regravado em config.env, para que os
# demais scripts de sessao (gdm3/sddm) e as fases seguintes (branding,
# logon, logoff) reaproveitem a mesma resposta sem redetectar.
#
# CORRECAO CRITICA: a versao anterior usava `return 0` dentro deste
# subshell "( ... )", o que nao e uma funcao. Isso gera erro em
# runtime ("return: can only `return' from a function or sourced
# script"), o subshell termina com exit code != 0 e, como o bundle
# roda com `set -e`, o erro ABORTA O BUNDLE INTEIRO ali mesmo -
# em qualquer distro/DE. Este script usa `exit` (valido dentro do
# subshell) em todos os pontos de saida antecipada.
#
# Os placeholders VARIAVEL são substituídos automaticamente
# pelo sistema na geração do bundle.
# ============================================================================

(
set -e

echo "============================================================"
echo "14a - Configurar LightDM (MATE, Cinnamon, XFCE, LXDE)"
echo "============================================================"

# ============================================================
# Variáveis
# ============================================================
DISPLAY_MANAGER="{{DISPLAY_MANAGER}}"
DESKTOP_ENV="{{DESKTOP_ENV}}"
BASE_URL="{{BASE_URL}}"
DOMINIO="{{DOMINIO}}"
DOMINIO_NETBIOS="{{DOMINIO_NETBIOS}}"
GRUPO_ADMIN_AD="{{GRUPO_ADMIN_AD}}"
THEME="{{THEME}}"

CONFIG_FILE="/etc/seederlinux/config.env"

# ============================================================
# Funcoes de deteccao (usadas somente se nao vier persistido)
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

detectar_dm_ativo() {
    if systemctl is-active --quiet lightdm 2>/dev/null; then echo "lightdm"
    elif systemctl is-active --quiet gdm3 2>/dev/null; then echo "gdm3"
    elif systemctl is-active --quiet sddm 2>/dev/null; then echo "sddm"
    else echo ""
    fi
}

detectar_dm_instalado() {
    if dpkg -l lightdm 2>/dev/null | grep -q "^ii"; then echo "lightdm"
    elif dpkg -l gdm3 2>/dev/null | grep -q "^ii"; then echo "gdm3"
    elif dpkg -l sddm 2>/dev/null | grep -q "^ii"; then echo "sddm"
    else echo ""
    fi
}

dm_padrao_para_de() {
    case "$1" in
        gnome) echo "gdm3" ;;
        kde)   echo "sddm" ;;
        *)     echo "lightdm" ;;  # cinnamon, mate, xfce, lxde, lxqt, unknown
    esac
}

# ============================================================
# 1. Resolver DESKTOP_ENV (OM -> config.env -> deteccao)
# ============================================================
if [ -z "$DESKTOP_ENV" ] && [ -f "$CONFIG_FILE" ]; then
    DESKTOP_ENV="$(grep -m1 '^DESKTOP_ENV=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"')"
fi
if [ -z "$DESKTOP_ENV" ]; then
    DESKTOP_ENV="$(detectar_de)"
    echo ">>> DESKTOP_ENV nao informado. Detectado em runtime: $DESKTOP_ENV"
else
    echo ">>> DESKTOP_ENV: $DESKTOP_ENV"
fi

# ============================================================
# 2. Resolver DISPLAY_MANAGER (OM -> config.env -> deteccao)
# ============================================================
if [ -z "$DISPLAY_MANAGER" ] && [ -f "$CONFIG_FILE" ]; then
    DISPLAY_MANAGER="$(grep -m1 '^DISPLAY_MANAGER=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"')"
fi
if [ -z "$DISPLAY_MANAGER" ]; then
    DISPLAY_MANAGER="$(detectar_dm_ativo)"
    [ -z "$DISPLAY_MANAGER" ] && DISPLAY_MANAGER="$(detectar_dm_instalado)"
    [ -z "$DISPLAY_MANAGER" ] && DISPLAY_MANAGER="$(dm_padrao_para_de "$DESKTOP_ENV")"
    echo ">>> DISPLAY_MANAGER nao informado. Resolvido automaticamente: $DISPLAY_MANAGER"
else
    echo ">>> DISPLAY_MANAGER: $DISPLAY_MANAGER"
fi

# ============================================================
# 3. Persistir o resultado para os proximos scripts (gdm3/sddm,
#    branding, logon, logoff) reaproveitarem sem redetectar
# ============================================================
mkdir -p /etc/seederlinux
touch "$CONFIG_FILE"
sed -i '/^DESKTOP_ENV=/d;/^DISPLAY_MANAGER=/d' "$CONFIG_FILE"
{
    echo "DESKTOP_ENV=${DESKTOP_ENV}"
    echo "DISPLAY_MANAGER=${DISPLAY_MANAGER}"
} >> "$CONFIG_FILE"

# ============================================================
# 4. Este script so configura LightDM. Se o DM resolvido for
#    outro, encerra este bloco (nao o bundle) e segue para 14b/14c.
# ============================================================
if [ "$DISPLAY_MANAGER" != "lightdm" ]; then
    echo ">>> DISPLAY_MANAGER resolvido e '$DISPLAY_MANAGER' (nao e lightdm). Pulando."
    echo "============================================================"
    exit 0
fi

echo ">>> Display Manager: $DISPLAY_MANAGER"
echo ">>> Ambiente: $DESKTOP_ENV"

# ============================================================
# Verificar se LightDM + greeter estao presentes.
# CORRECAO: NAO instalar aqui - este script roda DEPOIS do ingresso
# no AD, quando o DNS ja foi trocado pro controlador de dominio e
# nao resolve mais repositorios publicos. A instalacao real acontece
# no core_packages.sh (etapa 03), enquanto o DNS de internet ainda
# esta ativo. Aqui so verificamos e configuramos.
# ============================================================
if ! dpkg -l lightdm 2>/dev/null | grep -q "^ii"; then
    echo ">>> ERRO: lightdm nao instalado (deveria ter sido no core_packages.sh)."
    echo ">>> Pulando configuracao de LightDM."
    echo "============================================================"
    exit 0
fi

if dpkg -l lightdm-slick-greeter 2>/dev/null | grep -q "^ii"; then
    GREETER_SESSION="lightdm-slick-greeter"
elif dpkg -l lightdm-gtk-greeter 2>/dev/null | grep -q "^ii"; then
    GREETER_SESSION="lightdm-gtk-greeter"
else
    echo ">>> ERRO: nenhum greeter instalado."
    echo ">>> Pulando configuracao de LightDM."
    echo "============================================================"
    exit 0
fi
echo ">>> Greeter a usar: $GREETER_SESSION"

# Registrar LightDM como DM padrao (arquivo canonico do Debian/Ubuntu)
echo "lightdm shared/default-x-display-manager select lightdm" | debconf-set-selections 2>/dev/null || true
echo "lightdm lightdm/daemon_name string lightdm" | debconf-set-selections 2>/dev/null || true
echo "/usr/sbin/lightdm" > /etc/X11/default-display-manager

# ============================================================
# Configurar LightDM
# ============================================================
echo ">>> Configurando LightDM..."
mkdir -p /etc/lightdm

cat > /etc/lightdm/lightdm.conf <<EOF
# Configuracao LightDM - SeederLinux
[Seat:*]
greeter-session=${GREETER_SESSION}
user-session=${DESKTOP_ENV}
allow-guest=false
greeter-hide-users=true
greeter-show-manual-login=true
session-wrapper=/etc/lightdm/Xsession
pam-service=lightdm
pam-autologin-service=lightdm-autologin

# Logoff via hook do DM (root, tolerante - so desmonta/mata processo).
# Logon NAO fica mais aqui: passou a rodar via autostart XDG dentro da
# sessao do usuario (ver core_logon.sh), porque session-setup-script
# roda como root ANTES da sessao existir - sem D-Bus/HOME do usuario
# corretos, os gsettings/mounts/atalhos nao aplicavam de verdade.
session-cleanup-script=/usr/local/bin/seederlinux-logoff
EOF

echo ">>> LightDM configurado"

# ============================================================
# Configurar greeter do LightDM
# CORRECAO: theme-name = ${THEME} removido daqui incondicionalmente -
# quando THEME="DEFAULT" (ou vazio), "DEFAULT" nao e um tema GTK
# valido; o core_branding.sh ja decide se THEME deve ser aplicado
# (grava em outro arquivo quando aplicavel). Este greeter.conf fica
# sem theme-name explicito, usando o tema padrao do sistema.
# ============================================================
echo ">>> Configurando greeter..."
mkdir -p /etc/lightdm

cat > /etc/lightdm/lightdm-gtk-greeter.conf <<EOF
[greeter]
icon-theme-name = Adwaita
font-name = DejaVu Sans 10
background = /usr/share/backgrounds/seederlinux/wallpaper-login.jpg
logo = /usr/share/pixmaps/seederlinux-logo.png
show-indicators = ~host;~spacer;~clock;~spacer;~session;~spacer;~power
EOF

echo ">>> Greeter configurado"

# ============================================================
# Configurar Xsession
# ============================================================
echo ">>> Configurando Xsession..."
if [ ! -f /etc/lightdm/Xsession ]; then
    cat > /etc/lightdm/Xsession <<'XSESSION'
#!/bin/bash
# Xsession do SeederLinux para LightDM
exec /etc/X11/Xsession "$@"
XSESSION
    chmod +x /etc/lightdm/Xsession
fi

# ============================================================
# Garantir que os scripts de logon/logoff existam
# ============================================================
echo ">>> Verificando scripts de logon/logoff..."
for SCRIPT in seederlinux-logon seederlinux-logoff; do
    if [ ! -f "/usr/local/bin/${SCRIPT}" ]; then
        echo ">>> AVISO: /usr/local/bin/${SCRIPT} nao encontrado."
        echo ">>> Os scripts core_logon.sh e core_logoff.sh devem ser executados antes."
    fi
done

# ============================================================
# Desabilitar outros display managers
# ============================================================
echo ">>> Desabilitando outros display managers..."
systemctl disable gdm3 2>/dev/null || true
systemctl disable sddm 2>/dev/null || true
# CORRECAO: "systemctl enable lightdm" removido - o unit e estatico
# (sem secao [Install]), o enable so emitia warning sem efeito; quem
# registra o DM padrao e o arquivo /etc/X11/default-display-manager
# (ja escrito acima).

# ============================================================
# Reiniciar servico
# CORRECAO: reiniciar o LightDM enquanto o bundle roda DENTRO de uma
# sessao grafica ativa (console, nao SSH) mata a propria sessao que
# esta executando o bundle. So reinicia se nao ha $DISPLAY (execucao
# via TTY/cron) ou se veio por SSH (nao afeta sessao grafica local).
# ============================================================
if [ -z "$DISPLAY" ] || [ -n "$SSH_CONNECTION" ]; then
    echo ">>> Reiniciando LightDM..."
    systemctl restart lightdm 2>/dev/null || {
        echo ">>> AVISO: LightDM sera iniciado no proximo boot."
    }
else
    echo ">>> Rodando dentro da sessao grafica - LightDM sera aplicado no proximo boot."
fi

echo ">>> [14a] LightDM configurado!"
echo "============================================================"
)
$SeederScript$,
    TRUE,
    TRUE,
    18,
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Sessao GDM3 (ordem 19) - core_session_gdm3.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, version, organization_id)
VALUES (
    'Sessao GDM3',
    'core_session_gdm3.sh',
    'Configura GDM3 como display manager (autoselecao via DISPLAY_MANAGER=gdm3).',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_session_gdm3.sh
# SeederLinux Lite - GDM3: logon/logoff (GNOME)
# ============================================================================
# Configura o GDM3 como display manager e define os scripts de logon
# e logoff que serao executados nas transicoes de sessao.
#
# Resolucao de DESKTOP_ENV/DISPLAY_MANAGER (nessa ordem):
#   1) Valor injetado pela OM ({{DESKTOP_ENV}} / {{DISPLAY_MANAGER}})
#   2) Valor ja persistido em /etc/seederlinux/config.env (escrito pelo
#      core_session_lightdm.sh ou por este mesmo script)
#   3) Deteccao em runtime: DM ja ativo -> DM ja instalado -> padrao
#      por DE (gnome->gdm3, kde->sddm, qualquer outro->lightdm)
#
# CORRECAO CRITICA: a versao anterior usava `return 0` dentro deste
# subshell "( ... )", o que nao e uma funcao e gera erro em runtime,
# abortando o BUNDLE INTEIRO sob `set -e`. Este script usa `exit`
# em todos os pontos de saida antecipada.
#
# Os placeholders VARIAVEL são substituídos automaticamente
# pelo sistema na geração do bundle.
# ============================================================================

(
set -e

echo "============================================================"
echo "14b - Configurar GDM3 (GNOME)"
echo "============================================================"

# ============================================================
# Variáveis
# ============================================================
DISPLAY_MANAGER="{{DISPLAY_MANAGER}}"
DESKTOP_ENV="{{DESKTOP_ENV}}"
BASE_URL="{{BASE_URL}}"
DOMINIO="{{DOMINIO}}"
DOMINIO_NETBIOS="{{DOMINIO_NETBIOS}}"
GRUPO_ADMIN_AD="{{GRUPO_ADMIN_AD}}"

CONFIG_FILE="/etc/seederlinux/config.env"

# ============================================================
# Funcoes de deteccao (usadas somente se nao vier persistido)
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

detectar_dm_ativo() {
    if systemctl is-active --quiet lightdm 2>/dev/null; then echo "lightdm"
    elif systemctl is-active --quiet gdm3 2>/dev/null; then echo "gdm3"
    elif systemctl is-active --quiet sddm 2>/dev/null; then echo "sddm"
    else echo ""
    fi
}

detectar_dm_instalado() {
    if dpkg -l lightdm 2>/dev/null | grep -q "^ii"; then echo "lightdm"
    elif dpkg -l gdm3 2>/dev/null | grep -q "^ii"; then echo "gdm3"
    elif dpkg -l sddm 2>/dev/null | grep -q "^ii"; then echo "sddm"
    else echo ""
    fi
}

dm_padrao_para_de() {
    case "$1" in
        gnome) echo "gdm3" ;;
        kde)   echo "sddm" ;;
        *)     echo "lightdm" ;;
    esac
}

# ============================================================
# 1. Resolver DESKTOP_ENV (OM -> config.env -> deteccao)
# ============================================================
if [ -z "$DESKTOP_ENV" ] && [ -f "$CONFIG_FILE" ]; then
    DESKTOP_ENV="$(grep -m1 '^DESKTOP_ENV=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"')"
fi
if [ -z "$DESKTOP_ENV" ]; then
    DESKTOP_ENV="$(detectar_de)"
    echo ">>> DESKTOP_ENV nao informado. Detectado em runtime: $DESKTOP_ENV"
else
    echo ">>> DESKTOP_ENV: $DESKTOP_ENV"
fi

# ============================================================
# 2. Resolver DISPLAY_MANAGER (OM -> config.env -> deteccao)
# ============================================================
if [ -z "$DISPLAY_MANAGER" ] && [ -f "$CONFIG_FILE" ]; then
    DISPLAY_MANAGER="$(grep -m1 '^DISPLAY_MANAGER=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"')"
fi
if [ -z "$DISPLAY_MANAGER" ]; then
    DISPLAY_MANAGER="$(detectar_dm_ativo)"
    [ -z "$DISPLAY_MANAGER" ] && DISPLAY_MANAGER="$(detectar_dm_instalado)"
    [ -z "$DISPLAY_MANAGER" ] && DISPLAY_MANAGER="$(dm_padrao_para_de "$DESKTOP_ENV")"
    echo ">>> DISPLAY_MANAGER nao informado. Resolvido automaticamente: $DISPLAY_MANAGER"
else
    echo ">>> DISPLAY_MANAGER: $DISPLAY_MANAGER"
fi

# ============================================================
# 3. Persistir o resultado (idempotente - reafirma o mesmo valor
#    se o core_session_lightdm.sh ja tiver gravado)
# ============================================================
mkdir -p /etc/seederlinux
touch "$CONFIG_FILE"
sed -i '/^DESKTOP_ENV=/d;/^DISPLAY_MANAGER=/d' "$CONFIG_FILE"
{
    echo "DESKTOP_ENV=${DESKTOP_ENV}"
    echo "DISPLAY_MANAGER=${DISPLAY_MANAGER}"
} >> "$CONFIG_FILE"

# ============================================================
# 4. Este script so configura GDM3. Se o DM resolvido for outro,
#    encerra este bloco (nao o bundle) e segue para 14c.
# ============================================================
if [ "$DISPLAY_MANAGER" != "gdm3" ]; then
    echo ">>> DISPLAY_MANAGER resolvido e '$DISPLAY_MANAGER' (nao e gdm3). Pulando."
    echo "============================================================"
    exit 0
fi

echo ">>> Display Manager: $DISPLAY_MANAGER"
echo ">>> Ambiente: $DESKTOP_ENV"

# ============================================================
# Verificar se GDM3 esta presente.
# CORRECAO: NAO instalar aqui - este script roda DEPOIS do ingresso
# no AD, quando o DNS ja foi trocado pro controlador de dominio e
# nao resolve mais repositorios publicos. A instalacao real acontece
# no core_packages.sh (etapa 03), enquanto o DNS de internet ainda
# esta ativo.
# ============================================================
if ! dpkg -l gdm3 2>/dev/null | grep -q "^ii"; then
    echo ">>> ERRO: gdm3 nao instalado (deveria ter sido no core_packages.sh)."
    echo ">>> Pulando configuracao do GDM3."
    echo "============================================================"
    exit 0
fi

echo "gdm3 shared/default-x-display-manager select gdm3" | debconf-set-selections 2>/dev/null || true
echo "gdm3 gdm3/daemon_name string gdm3" | debconf-set-selections 2>/dev/null || true
echo "/usr/sbin/gdm3" > /etc/X11/default-display-manager

# ============================================================
# Configurar GDM3
# ============================================================
echo ">>> Configurando GDM3..."
mkdir -p /etc/gdm3

cat > /etc/gdm3/daemon.conf <<EOF
# Configuracao GDM3 - SeederLinux
[daemon]
WaylandEnable=false
AutomaticLoginEnable=false
TimedLoginEnable=false

[security]
DisallowRoot=true

[greeter]
Session=${DESKTOP_ENV}
EOF

echo ">>> GDM3 configurado"

# ============================================================
# Configurar script de logoff via PostSession
# ============================================================
# Logon NAO fica mais aqui (PreSession removido): PreSession roda como
# root ANTES da sessao existir - sem D-Bus/HOME do usuario corretos,
# os gsettings/mounts/atalhos nao aplicavam de verdade. O logon passou
# a rodar via autostart XDG dentro da sessao (ver core_logon.sh).
# Logoff continua aqui pois so desmonta/mata processo (tolerante a
# rodar como root).
echo ">>> Configurando script de logoff no GDM3..."

POSTSESSION_FILE="/etc/gdm3/PostSession/Default"
mkdir -p /etc/gdm3/PostSession

cat > "$POSTSESSION_FILE" <<'POSTSESSION'
#!/bin/bash
# PostSession do GDM3 - SeederLinux
if [ -x /usr/local/bin/seederlinux-logoff ]; then
    /usr/local/bin/seederlinux-logoff "$@"
fi

exit "${EXIT_STATUS:-0}"
POSTSESSION
chmod +x "$POSTSESSION_FILE"

echo ">>> Script de logoff configurado no GDM3"

# ============================================================
# Garantir que os scripts de logon/logoff existam
# ============================================================
echo ">>> Verificando scripts de logon/logoff..."
for SCRIPT in seederlinux-logon seederlinux-logoff; do
    if [ ! -f "/usr/local/bin/${SCRIPT}" ]; then
        echo ">>> AVISO: /usr/local/bin/${SCRIPT} nao encontrado."
        echo ">>> Os scripts core_logon.sh e core_logoff.sh devem ser executados antes."
    fi
done

# ============================================================
# Desabilitar outros display managers
# ============================================================
echo ">>> Desabilitando outros display managers..."
systemctl disable lightdm 2>/dev/null || true
systemctl disable sddm 2>/dev/null || true
# CORRECAO: "systemctl enable gdm3" removido - registro do DM padrao
# ja feito via /etc/X11/default-display-manager acima.

# ============================================================
# Reiniciar servico
# CORRECAO: mesmo guard do LightDM - reiniciar dentro de uma sessao
# grafica ativa mataria a propria sessao rodando o bundle.
# ============================================================
if [ -z "$DISPLAY" ] || [ -n "$SSH_CONNECTION" ]; then
    echo ">>> Reiniciando GDM3..."
    systemctl restart gdm3 2>/dev/null || {
        echo ">>> AVISO: GDM3 sera iniciado no proximo boot."
    }
else
    echo ">>> Rodando dentro da sessao grafica - GDM3 sera aplicado no proximo boot."
fi

echo ">>> [14b] GDM3 configurado!"
echo "============================================================"
)
$SeederScript$,
    TRUE,
    TRUE,
    19,
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Sessao SDDM (ordem 20) - core_session_sddm.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, version, organization_id)
VALUES (
    'Sessao SDDM',
    'core_session_sddm.sh',
    'Configura SDDM como display manager (autoselecao via DISPLAY_MANAGER=sddm).',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_session_sddm.sh
# SeederLinux Lite - SDDM: logon/logoff (KDE)
# ============================================================================
# Configura o SDDM como display manager e define os scripts de logon
# e logoff que serao executados nas transicoes de sessao.
#
# Resolucao de DESKTOP_ENV/DISPLAY_MANAGER (nessa ordem):
#   1) Valor injetado pela OM ({{DESKTOP_ENV}} / {{DISPLAY_MANAGER}})
#   2) Valor ja persistido em /etc/seederlinux/config.env (escrito pelo
#      core_session_lightdm.sh/core_session_gdm3.sh ou por este mesmo
#      script)
#   3) Deteccao em runtime: DM ja ativo -> DM ja instalado -> padrao
#      por DE (gnome->gdm3, kde->sddm, qualquer outro->lightdm)
#
# CORRECAO CRITICA: a versao anterior usava `return 0` dentro deste
# subshell "( ... )", o que nao e uma funcao e gera erro em runtime,
# abortando o BUNDLE INTEIRO sob `set -e`. Este script usa `exit`
# em todos os pontos de saida antecipada.
#
# Os placeholders VARIAVEL são substituídos automaticamente
# pelo sistema na geração do bundle.
# ============================================================================

(
set -e

echo "============================================================"
echo "14c - Configurar SDDM (KDE)"
echo "============================================================"

# ============================================================
# Variáveis
# ============================================================
DISPLAY_MANAGER="{{DISPLAY_MANAGER}}"
DESKTOP_ENV="{{DESKTOP_ENV}}"
BASE_URL="{{BASE_URL}}"
DOMINIO="{{DOMINIO}}"
DOMINIO_NETBIOS="{{DOMINIO_NETBIOS}}"
GRUPO_ADMIN_AD="{{GRUPO_ADMIN_AD}}"

CONFIG_FILE="/etc/seederlinux/config.env"

# ============================================================
# Funcoes de deteccao (usadas somente se nao vier persistido)
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

detectar_dm_ativo() {
    if systemctl is-active --quiet lightdm 2>/dev/null; then echo "lightdm"
    elif systemctl is-active --quiet gdm3 2>/dev/null; then echo "gdm3"
    elif systemctl is-active --quiet sddm 2>/dev/null; then echo "sddm"
    else echo ""
    fi
}

detectar_dm_instalado() {
    if dpkg -l lightdm 2>/dev/null | grep -q "^ii"; then echo "lightdm"
    elif dpkg -l gdm3 2>/dev/null | grep -q "^ii"; then echo "gdm3"
    elif dpkg -l sddm 2>/dev/null | grep -q "^ii"; then echo "sddm"
    else echo ""
    fi
}

dm_padrao_para_de() {
    case "$1" in
        gnome) echo "gdm3" ;;
        kde)   echo "sddm" ;;
        *)     echo "lightdm" ;;
    esac
}

# ============================================================
# 1. Resolver DESKTOP_ENV (OM -> config.env -> deteccao)
# ============================================================
if [ -z "$DESKTOP_ENV" ] && [ -f "$CONFIG_FILE" ]; then
    DESKTOP_ENV="$(grep -m1 '^DESKTOP_ENV=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"')"
fi
if [ -z "$DESKTOP_ENV" ]; then
    DESKTOP_ENV="$(detectar_de)"
    echo ">>> DESKTOP_ENV nao informado. Detectado em runtime: $DESKTOP_ENV"
else
    echo ">>> DESKTOP_ENV: $DESKTOP_ENV"
fi

# ============================================================
# 2. Resolver DISPLAY_MANAGER (OM -> config.env -> deteccao)
# ============================================================
if [ -z "$DISPLAY_MANAGER" ] && [ -f "$CONFIG_FILE" ]; then
    DISPLAY_MANAGER="$(grep -m1 '^DISPLAY_MANAGER=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"')"
fi
if [ -z "$DISPLAY_MANAGER" ]; then
    DISPLAY_MANAGER="$(detectar_dm_ativo)"
    [ -z "$DISPLAY_MANAGER" ] && DISPLAY_MANAGER="$(detectar_dm_instalado)"
    [ -z "$DISPLAY_MANAGER" ] && DISPLAY_MANAGER="$(dm_padrao_para_de "$DESKTOP_ENV")"
    echo ">>> DISPLAY_MANAGER nao informado. Resolvido automaticamente: $DISPLAY_MANAGER"
else
    echo ">>> DISPLAY_MANAGER: $DISPLAY_MANAGER"
fi

# ============================================================
# 3. Persistir o resultado (idempotente - reafirma o mesmo valor
#    se um dos scripts anteriores ja tiver gravado)
# ============================================================
mkdir -p /etc/seederlinux
touch "$CONFIG_FILE"
sed -i '/^DESKTOP_ENV=/d;/^DISPLAY_MANAGER=/d' "$CONFIG_FILE"
{
    echo "DESKTOP_ENV=${DESKTOP_ENV}"
    echo "DISPLAY_MANAGER=${DISPLAY_MANAGER}"
} >> "$CONFIG_FILE"

# ============================================================
# 4. Este script so configura SDDM. Se o DM resolvido for outro,
#    encerra este bloco (nao o bundle).
# ============================================================
if [ "$DISPLAY_MANAGER" != "sddm" ]; then
    echo ">>> DISPLAY_MANAGER resolvido e '$DISPLAY_MANAGER' (nao e sddm). Pulando."
    echo "============================================================"
    exit 0
fi

echo ">>> Display Manager: $DISPLAY_MANAGER"
echo ">>> Ambiente: $DESKTOP_ENV"

# ============================================================
# Verificar se SDDM esta presente.
# CORRECAO: NAO instalar aqui - este script roda DEPOIS do ingresso
# no AD, quando o DNS ja foi trocado pro controlador de dominio e
# nao resolve mais repositorios publicos. A instalacao real acontece
# no core_packages.sh (etapa 03), enquanto o DNS de internet ainda
# esta ativo.
# ============================================================
if ! dpkg -l sddm 2>/dev/null | grep -q "^ii"; then
    echo ">>> ERRO: sddm nao instalado (deveria ter sido no core_packages.sh)."
    echo ">>> Pulando configuracao do SDDM."
    echo "============================================================"
    exit 0
fi

echo "sddm shared/default-x-display-manager select sddm" | debconf-set-selections 2>/dev/null || true
echo "sddm sddm/daemon_name string sddm" | debconf-set-selections 2>/dev/null || true
echo "/usr/sbin/sddm" > /etc/X11/default-display-manager

# ============================================================
# Configurar SDDM
# ============================================================
echo ">>> Configurando SDDM..."
mkdir -p /etc/sddm.conf.d

cat > /etc/sddm.conf.d/seederlinux.conf <<EOF
# Configuracao SDDM - SeederLinux
[Theme]
Current=breeze
ThemeDir=/usr/share/sddm/themes

[Users]
MaximumUid=60000
MinimumUid=1000

[Autologin]
User=
Session=
EOF

echo ">>> SDDM configurado"

# ============================================================
# Configurar script de logoff via Xstop
# ============================================================
# Logon NAO fica mais aqui (Xsetup removido): Xsetup roda como root
# na fase de setup do X, ANTES/fora do contexto de sessao do usuario
# (nem sempre ha usuario resolvido ainda nesse ponto) - sem D-Bus/HOME
# corretos, os gsettings/mounts/atalhos nao aplicavam de verdade. O
# logon passou a rodar via autostart XDG dentro da sessao (ver
# core_logon.sh). Logoff continua aqui pois so desmonta/mata processo
# (tolerante a rodar como root).
echo ">>> Configurando script de logoff no SDDM..."

mkdir -p /usr/share/sddm/scripts

XSTOP_FILE="/usr/share/sddm/scripts/Xstop"

cat > "$XSTOP_FILE" <<'XSTOP'
#!/bin/bash
# Xstop do SDDM - SeederLinux
if [ -x /usr/local/bin/seederlinux-logoff ]; then
    /usr/local/bin/seederlinux-logoff "$@"
fi

exit "${EXIT_STATUS:-0}"
XSTOP
chmod +x "$XSTOP_FILE"

echo ">>> Scripts de logon/logoff configurados no SDDM"

# ============================================================
# Garantir que os scripts de logon/logoff existam
# ============================================================
echo ">>> Verificando scripts de logon/logoff..."
for SCRIPT in seederlinux-logon seederlinux-logoff; do
    if [ ! -f "/usr/local/bin/${SCRIPT}" ]; then
        echo ">>> AVISO: /usr/local/bin/${SCRIPT} nao encontrado."
        echo ">>> Os scripts core_logon.sh e core_logoff.sh devem ser executados antes."
    fi
done

# ============================================================
# Desabilitar outros display managers
# ============================================================
echo ">>> Desabilitando outros display managers..."
systemctl disable lightdm 2>/dev/null || true
systemctl disable gdm3 2>/dev/null || true
# CORRECAO: "systemctl enable sddm" removido - registro do DM padrao
# ja feito via /etc/X11/default-display-manager acima.

# ============================================================
# Reiniciar servico
# CORRECAO: mesmo guard do LightDM/GDM3 - reiniciar dentro de uma
# sessao grafica ativa mataria a propria sessao rodando o bundle.
# ============================================================
if [ -z "$DISPLAY" ] || [ -n "$SSH_CONNECTION" ]; then
    echo ">>> Reiniciando SDDM..."
    systemctl restart sddm 2>/dev/null || {
        echo ">>> AVISO: SDDM sera iniciado no proximo boot."
    }
else
    echo ">>> Rodando dentro da sessao grafica - SDDM sera aplicado no proximo boot."
fi

echo ">>> [14c] SDDM configurado!"
echo "============================================================"
)
$SeederScript$,
    TRUE,
    TRUE,
    20,
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Agente SeederLinux (ordem 21) - core_agent.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, version, organization_id)
VALUES (
    'Agente SeederLinux',
    'core_agent.sh',
    'Instala e configura o agente SeederLinux.',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_agent.sh
# SeederLinux Lite - Instalacao do agente de check-in periodico
# ============================================================================
# Baixa o agent.py do servidor, configura cron a cada 15 minutos e
# executa o primeiro check-in em background.
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

echo ">>> Servidor: $SEEDER_SERVER"
echo ">>> Organizacao: $OM_ACRONYM"

# Baixar o agente
mkdir -p /usr/local/bin
if wget -q --no-check-certificate -O /usr/local/bin/seeder-agent "${SEEDER_SERVER}/downloads/agent.py"; then
    # Verificar que o arquivo nao esta vazio
    if [ ! -s /usr/local/bin/seeder-agent ]; then
        echo ">>> ERRO: Agente baixado mas arquivo esta vazio. Verifique $SEEDER_SERVER"
        echo "============================================================"
        exit 1
    fi
    chmod 755 /usr/local/bin/seeder-agent
    echo ">>> Agente baixado com sucesso"
else
    echo ">>> ERRO: Falha ao baixar o agente. Verifique conectividade com $SEEDER_SERVER"
    echo "============================================================"
    exit 1
fi

# Criar configuracao
mkdir -p /etc/seeder
cat > /etc/seeder/agent.conf <<EOF
[server]
url = ${SEEDER_SERVER}
no_check_certificate = ${AGENT_NO_CHECK_CERT}
EOF

# Configurar cron
cat > /etc/cron.d/seeder-agent <<EOF
# SeederLinux Agent - check-in a cada 15 minutos
*/15 * * * * root /usr/local/bin/seeder-agent --no-check-certificate >> /var/log/seeder/agent.log 2>&1
EOF

# Primeiro check-in (em background, sem bloquear o bundle)
echo ">>> Executando primeiro check-in em background..."
nohup /usr/local/bin/seeder-agent --org "$OM_ACRONYM" --no-check-certificate > /tmp/seeder-first-checkin.log 2>&1 &

echo ">>> [18] Agente instalado e agendado!"
echo "============================================================"
)
$SeederScript$,
    TRUE,
    TRUE,
    21,
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Configuracao de Proxy (ordem 22) - core_proxy.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, version, organization_id)
VALUES (
    'Configuracao de Proxy',
    'core_proxy.sh',
    'Configura proxy corporativo no sistema (apt, curl, wget, env).',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_proxy.sh
# SeederLinux Lite - Proxy do sistema
# ============================================================================
# Configura o proxy HTTP/HTTPS no nivel do sistema (/etc/environment,
# /etc/apt/apt.conf.d) e em variaveis de ambiente globais.
# Os placeholders VARIAVEL são substituídos automaticamente
# pelo sistema na geração do bundle.
# ============================================================================

set -e

echo "============================================================"
echo "ATENCAO: Proxy sera configurado agora."
echo "Todos os pacotes ja foram instalados."
echo "A partir deste ponto, a internet pode exigir autenticacao."
echo "============================================================"
echo "17 - Configurar proxy do sistema"
echo "============================================================"

# ============================================================
# Variáveis
# ============================================================
PROXY_MODE="{{PROXY_MODE}}"
PROXY_HTTP="{{PROXY_HTTP}}"
PROXY_PORTA="{{PROXY_PORTA}}"
PROXY_URL="{{PROXY_URL}}"
PAC_URL="{{PAC_URL}}"
NO_PROXY="{{NO_PROXY}}"
SEEDER_SERVER="{{SEEDER_SERVER}}"

echo ">>> Modo de proxy: $PROXY_MODE"

# ============================================================
# Configurar conforme o modo
# ============================================================
case "$PROXY_MODE" in
    NONE)
        echo ">>> Proxy desativado (NONE)"
        # Remover configuracoes de proxy existentes
        rm -f /etc/apt/apt.conf.d/95seederlinux-proxy 2>/dev/null || true
        # Limpar /etc/environment de entradas de proxy
        if [ -f /etc/environment ]; then
            sed -i '/^http_proxy=/d; /^https_proxy=/d; /^ftp_proxy=/d; /^no_proxy=/d; /^HTTP_PROXY=/d; /^HTTPS_PROXY=/d; /^FTP_PROXY=/d; /^NO_PROXY=/d' /etc/environment || true
        fi
        echo ">>> Configuracoes de proxy removidas"
        ;;

    MANUAL)
        echo ">>> Configurando proxy manual: ${PROXY_HTTP}:${PROXY_PORTA}"

        # Construir URL do proxy
        if [ -n "$PROXY_URL" ] && [ "$PROXY_URL" != "" ]; then
            PROXY_FULL_URL="$PROXY_URL"
        else
            PROXY_FULL_URL="http://${PROXY_HTTP}:${PROXY_PORTA}"
        fi

        # Configurar APT
        cat > /etc/apt/apt.conf.d/95seederlinux-proxy <<EOF
Acquire::http::Proxy "${PROXY_FULL_URL}";
Acquire::https::Proxy "${PROXY_FULL_URL}";
Acquire::ftp::Proxy "${PROXY_FULL_URL}";
EOF

        # Garantir que o servidor Seeder esteja sempre no NO_PROXY - o
        # agente Python faz check-in nele e nao pode passar pelo proxy
        # corporativo (recebe 407 Proxy Authentication Required).
        SEEDER_HOST=""
        if [ -n "${SEEDER_SERVER:-}" ]; then
            SEEDER_HOST="$(echo "$SEEDER_SERVER" | sed -E 's|https?://([^/]+).*|\1|')"
        fi
        if [ -n "$SEEDER_HOST" ]; then
            case ",$NO_PROXY," in
                *",$SEEDER_HOST,"*) ;;
                *) NO_PROXY="${NO_PROXY:+${NO_PROXY},}${SEEDER_HOST}" ;;
            esac
            echo ">>> SEEDER_HOST adicionado ao NO_PROXY: $SEEDER_HOST"
        fi

        # Configurar /etc/environment
        if [ -f /etc/environment ]; then
            # Remover entradas antigas
            sed -i '/^http_proxy=/d; /^https_proxy=/d; /^ftp_proxy=/d; /^no_proxy=/d; /^HTTP_PROXY=/d; /^HTTPS_PROXY=/d; /^FTP_PROXY=/d; /^NO_PROXY=/d' /etc/environment || true
        fi

        cat >> /etc/environment <<EOF
http_proxy="${PROXY_FULL_URL}"
https_proxy="${PROXY_FULL_URL}"
ftp_proxy="${PROXY_FULL_URL}"
HTTP_PROXY="${PROXY_FULL_URL}"
HTTPS_PROXY="${PROXY_FULL_URL}"
FTP_PROXY="${PROXY_FULL_URL}"
EOF

        if [ -n "$NO_PROXY" ] && [ "$NO_PROXY" != "" ]; then
            echo "no_proxy=\"${NO_PROXY}\"" >> /etc/environment
            echo "NO_PROXY=\"${NO_PROXY}\"" >> /etc/environment
        fi

        echo ">>> Proxy manual configurado"
        ;;

    PAC)
        echo ">>> Configurando proxy via PAC: ${PAC_URL}"

        if [ -z "$PAC_URL" ] || [ "$PAC_URL" = "" ]; then
            echo ">>> ERRO: PAC_URL nao definido para modo PAC"
            read -p ">>> Deseja continuar mesmo assim? (S/n): " CONTINUE
            if [[ "$CONTINUE" =~ ^[Nn]$ ]]; then
                echo ">>> Instalacao abortada pelo usuario."
                exit 1
            fi
            echo ">>> Continuando apesar do erro..."
        fi

        # Configurar APT com PAC (apt suporta PAC via auto)
        cat > /etc/apt/apt.conf.d/95seederlinux-proxy <<EOF
Acquire::http::Proxy::Pac "${PAC_URL}";
Acquire::https::Proxy::Pac "${PAC_URL}";
EOF

        # Garantir que o servidor Seeder esteja sempre no NO_PROXY - o
        # agente Python faz check-in nele e nao pode passar pelo proxy
        # corporativo (recebe 407 Proxy Authentication Required).
        SEEDER_HOST=""
        if [ -n "${SEEDER_SERVER:-}" ]; then
            SEEDER_HOST="$(echo "$SEEDER_SERVER" | sed -E 's|https?://([^/]+).*|\1|')"
        fi
        if [ -n "$SEEDER_HOST" ]; then
            case ",$NO_PROXY," in
                *",$SEEDER_HOST,"*) ;;
                *) NO_PROXY="${NO_PROXY:+${NO_PROXY},}${SEEDER_HOST}" ;;
            esac
            echo ">>> SEEDER_HOST adicionado ao NO_PROXY: $SEEDER_HOST"
        fi

        # Para navegadores, o PAC sera configurado no core_browser.sh
        echo "PAC_URL=${PAC_URL}" > /etc/seederlinux/pac_url.conf 2>/dev/null || {
            mkdir -p /etc/seederlinux
            echo "PAC_URL=${PAC_URL}" > /etc/seederlinux/pac_url.conf
        }

        echo ">>> Proxy via PAC configurado"
        ;;

    *)
        echo ">>> ERRO: Modo de proxy invalido: $PROXY_MODE"
        read -p ">>> Deseja continuar mesmo assim? (S/n): " CONTINUE
        if [[ "$CONTINUE" =~ ^[Nn]$ ]]; then
            echo ">>> Instalacao abortada pelo usuario."
            exit 1
        fi
        echo ">>> Continuando apesar do erro..."
        ;;
esac

echo ">>> [17] Proxy do sistema configurado!"
echo "============================================================"
$SeederScript$,
    TRUE,
    TRUE,
    22,
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;


-- ============================================================================
-- Aplicador de Politicas (seeder-sync) (ordem 23) - core_sync.sh
-- ============================================================================
INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, version, organization_id)
VALUES (
    'Aplicador de Politicas (seeder-sync)',
    'core_sync.sh',
    'Instala o seeder-sync e um timer systemd (10 em 10 minutos) que reaplica de forma idempotente toda a configuracao corporativa da OM (estilo GPO).',
    $SeederScript$#!/bin/bash
# ============================================================================
# Core Script: core_sync.sh
# SeederLinux Lite - seeder-sync: aplicador de politicas (estilo GPO)
# ============================================================================
# Instala /usr/local/bin/seeder-sync + timer systemd (10 em 10 minutos),
# responsavel por REAPLICAR de forma idempotente toda a configuracao
# corporativa da OM (branding, politicas de navegador, proxy,
# impressoras, Conky, compartilhamentos), independente de login/logoff.
#
# Isso implementa o design original do SeederLinux Lite: login/logoff
# ficam minimos e rapidos (core_logon.sh / core_logoff.sh), e a
# aplicacao continua de politicas roda em segundo plano via timer -
# analogo a um refresh de GPO do Windows.
#
# O agente de check-in (core_agent.sh, a cada 15min) continua
# detectando mudanca de serial_config no servidor e, quando ha
# diferenca, baixa o bundle atualizado e aciona este script. O timer
# local (10min) roda de forma independente, garantindo que a estacao
# convirja pro estado desejado mesmo se o agente estiver offline ou
# o download do bundle falhar.
#
# IDEMPOTENCIA: seeder-sync pode rodar quantas vezes for necessario
# sem efeito colateral - ele nao usa `set -e` (uma falha isolada, ex.
# wallpaper que nao baixou, nao pode interromper os demais modulos).
#
# LIMITACAO CONHECIDA: os modulos de impressoras (fila/protocolo
# completo) e certificados aqui sao um subconjunto simplificado,
# porque este script foi escrito sem acesso ao core_printers.sh /
# lógica completa de certificados da OM (nao foram enviados ainda).
# Revisar com atencao antes de usar em producao - ver comentarios
# "REVISAR" nos respectivos modulos.
#
# Os placeholders VARIAVEL sao substituidos automaticamente
# pelo sistema na geracao do bundle.
# ============================================================================

set -e

echo "============================================================"
echo "19 - Instalar seeder-sync (aplicador GPO) + timer systemd"
echo "============================================================"

SEEDER_SERVER="{{SEEDER_SERVER}}"

mkdir -p /etc/seederlinux
mkdir -p /var/log/seederlinux

# ============================================================
# 1. Script principal /usr/local/bin/seeder-sync
# ============================================================
echo ">>> Criando /usr/local/bin/seeder-sync..."

cat > /usr/local/bin/seeder-sync <<'SYNCSCRIPT'
#!/bin/bash
# seeder-sync - aplicador idempotente de politicas (GPO-like)
# Le /etc/seederlinux/config.env e reaplica tudo. Sem `set -e`: a
# falha de um modulo isolado nao pode impedir os demais de rodar.
set -u

CONFIG_FILE="/etc/seederlinux/config.env"
STATE_FILE="/etc/seederlinux/sync-state.env"
LOG_FILE="/var/log/seederlinux/sync.log"

mkdir -p /var/log/seederlinux
exec >> "$LOG_FILE" 2>&1
echo "=== seeder-sync: $(date -Is) ==="

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERRO: $CONFIG_FILE nao encontrado. Nada a sincronizar."
    exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"

# ============================================================
# Resolucao de modo: --force (sempre usado pelo timer systemd, a
# cada 10min, para autocorrecao de drift independente de serial) ou
# comparacao de serial (usado quando chamado sem --force, tipicamente
# pelo agente apos um check-in, ou manualmente).
#
# O SERVER_SERIAL (serial atual no servidor) pode chegar de tres
# formas, nessa ordem de prioridade:
#   1) primeiro argumento posicional nao-flag (ex: seeder-sync 15)
#   2) variavel de ambiente SERIAL_CONFIG (ex: SERIAL_CONFIG=15 seeder-sync)
#   3) arquivo /etc/seederlinux/server-serial.env (SERIAL_CONFIG=15),
#      que o agent.py pode escrever apos um check-in bem-sucedido
#
# Sem nenhuma dessas fontes, nao ha como comparar - o script roda
# de forma completa mesmo assim (comportamento seguro por padrao).
# ============================================================
FORCE_SYNC="false"
SERVER_SERIAL=""
for arg in "$@"; do
    case "$arg" in
        --force) FORCE_SYNC="true" ;;
        [0-9]*) SERVER_SERIAL="$arg" ;;
    esac
done

if [ -z "$SERVER_SERIAL" ] && [ -n "${SERIAL_CONFIG:-}" ]; then
    SERVER_SERIAL="$SERIAL_CONFIG"
fi
if [ -z "$SERVER_SERIAL" ] && [ -f /etc/seederlinux/server-serial.env ]; then
    # shellcheck disable=SC1090
    SERVER_SERIAL="$(grep -m1 '^SERIAL_CONFIG=' /etc/seederlinux/server-serial.env 2>/dev/null | cut -d= -f2- | tr -d '"')"
fi

SERIAL_APLICADO_ATUAL="${SERIAL_APLICADO:-0}"

if [ "$FORCE_SYNC" != "true" ] && [ -n "$SERVER_SERIAL" ]; then
    if [ "$SERVER_SERIAL" -le "$SERIAL_APLICADO_ATUAL" ] 2>/dev/null; then
        echo "SERIAL_APLICADO ($SERIAL_APLICADO_ATUAL) ja esta em dia com o servidor ($SERVER_SERIAL). Nada a fazer."
        echo "=== seeder-sync concluido (sem alteracoes): $(date -Is) ==="
        exit 0
    fi
    echo "Serial do servidor ($SERVER_SERIAL) e maior que o aplicado ($SERIAL_APLICADO_ATUAL). Sincronizando..."
elif [ "$FORCE_SYNC" = "true" ]; then
    echo "Execucao forcada (timer/autocorrecao) - reaplicando tudo independente de serial."
else
    echo "Nenhum serial do servidor disponivel para comparar - reaplicando por seguranca."
fi

# ============================================================
# Deteccao de ambiente (mesmo padrao usado no resto do bundle)
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
[ -z "${DESKTOP_ENV:-}" ] && DESKTOP_ENV="$(detectar_de)"

usuarios_com_sessao_grafica() {
    loginctl list-sessions --no-legend 2>/dev/null | awk '{print $3}' | grep -v '^root$' | sort -u
}

# ============================================================
# MODULO: branding (wallpaper, logo, tema via dconf/xfconf/kde)
# ============================================================
sync_branding() {
    echo "--- branding ---"
    mkdir -p /usr/share/backgrounds/seederlinux /usr/share/pixmaps

    _baixar_ativo() {
        local url="$1"
        local dest="$2"
        local tmp
        tmp="$(mktemp /tmp/seeder-asset.XXXXXX)"
        if wget -q --no-check-certificate --no-proxy -O "$tmp" "$url" && [ -s "$tmp" ]; then
            mv "$tmp" "$dest"
            echo "OK: $(basename "$dest")"
        else
            rm -f "$tmp"
            echo "AVISO: falha/arquivo vazio ao baixar $(basename "$dest") - mantendo o existente"
        fi
    }

    if [ -n "${WALLPAPER_URL:-}" ]; then
        _baixar_ativo "$WALLPAPER_URL" /usr/share/backgrounds/seederlinux/wallpaper.jpg
    fi
    if [ -n "${WALLPAPER_LOGIN_URL:-}" ]; then
        _baixar_ativo "$WALLPAPER_LOGIN_URL" /usr/share/backgrounds/seederlinux/wallpaper-login.jpg
    fi
    if [ -n "${LOGO_URL:-}" ]; then
        _baixar_ativo "$LOGO_URL" /usr/share/pixmaps/seederlinux-logo.png
    fi

    # THEME="DEFAULT" (ou vazio) nao e um tema GTK valido - mesma
    # regra do core_branding.sh: so aplica se existir de verdade em
    # /usr/share/themes, senao mantem o tema atual do sistema.
    THEME_APLICAR=false
    if [ -n "${THEME:-}" ] && [ "${THEME}" != "DEFAULT" ] && [ -d "/usr/share/themes/${THEME}" ]; then
        THEME_APLICAR=true
    fi

    # Perfil dconf (system-db:local) - sem isso, nada de dconf abaixo aplica
    mkdir -p /etc/dconf/profile
    if [ ! -f /etc/dconf/profile/user ]; then
        printf 'user-db:user\nsystem-db:local\n' > /etc/dconf/profile/user
    elif ! grep -q '^system-db:local$' /etc/dconf/profile/user; then
        echo "system-db:local" >> /etc/dconf/profile/user
    fi
    mkdir -p /etc/dconf/db/local.d

    case "$DESKTOP_ENV" in
        cinnamon)
            cat > /etc/dconf/db/local.d/seederlinux-branding-cinnamon <<EOF
[org/cinnamon/desktop/background]
picture-uri='file:///usr/share/backgrounds/seederlinux/wallpaper.jpg'
picture-options='zoom'
EOF
            if [ "$THEME_APLICAR" = "true" ]; then
                cat >> /etc/dconf/db/local.d/seederlinux-branding-cinnamon <<EOF

[org/cinnamon/desktop/interface]
gtk-theme='${THEME}'
icon-theme-name='Adwaita'
EOF
            fi
            dconf update 2>/dev/null || true
            ;;
        mate)
            cat > /etc/dconf/db/local.d/seederlinux-branding-mate <<EOF
[org/mate/desktop/background]
picture-filename='/usr/share/backgrounds/seederlinux/wallpaper.jpg'
picture-options='zoom'
EOF
            if [ "$THEME_APLICAR" = "true" ]; then
                cat >> /etc/dconf/db/local.d/seederlinux-branding-mate <<EOF

[org/mate/desktop/interface]
gtk-theme='${THEME}'
icon-theme='Adwaita'
EOF
            fi
            dconf update 2>/dev/null || true
            ;;
        gnome)
            cat > /etc/dconf/db/local.d/seederlinux-branding-gnome <<EOF
[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/seederlinux/wallpaper.jpg'
picture-options='zoom'

[org/gnome/login-screen]
logo='/usr/share/pixmaps/seederlinux-logo.png'
EOF
            if [ "$THEME_APLICAR" = "true" ]; then
                cat >> /etc/dconf/db/local.d/seederlinux-branding-gnome <<EOF

[org/gnome/desktop/interface]
gtk-theme='${THEME}'
icon-theme='Adwaita'
EOF
            fi
            dconf update 2>/dev/null || true
            ;;
        xfce)
            for uh in /home/*; do
                [ -d "$uh" ] || continue
                u="$(basename "$uh")"
                mkdir -p "$uh/.config/xfce4/xfconf/xfce-perchannel-xml"
                cat > "$uh/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitor0" type="empty">
        <property name="image-path" type="string" value="/usr/share/backgrounds/seederlinux/wallpaper.jpg"/>
        <property name="image-style" type="int" value="5"/>
      </property>
    </property>
  </property>
</channel>
EOF
                chown "$u:$u" "$uh/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml" 2>/dev/null || true
            done
            ;;
        kde)
            for uh in /home/*; do
                [ -d "$uh" ] || continue
                u="$(basename "$uh")"
                mkdir -p "$uh/.config"
                cat > "$uh/.config/plasma-org.kde.plasma.desktop-appletsrc" <<EOF
[Containments][1][Wallpaper][org.kde.image][General]
Image=file:///usr/share/backgrounds/seederlinux/wallpaper.jpg
EOF
                chown "$u:$u" "$uh/.config/plasma-org.kde.plasma.desktop-appletsrc" 2>/dev/null || true
            done
            ;;
        lxde|lxqt)
            for uh in /home/*; do
                [ -d "$uh" ] || continue
                u="$(basename "$uh")"
                mkdir -p "$uh/.config/pcmanfm/LXDE"
                cat > "$uh/.config/pcmanfm/LXDE/desktop-items-0.conf" <<EOF
[*]
wallpaper_mode=crop
wallpaper=/usr/share/backgrounds/seederlinux/wallpaper.jpg
EOF
                chown "$u:$u" "$uh/.config/pcmanfm/LXDE/desktop-items-0.conf" 2>/dev/null || true
            done
            ;;
    esac
}

# ============================================================
# MODULO: politica do Firefox
#
# CONFIRMADO/ALINHADO contra o core_browser.sh real (recebido depois
# deste modulo ser escrito): o caminho canonico e
# /usr/lib/firefox-esr/distribution/policies.json (instalacao do
# pacote Debian/Ubuntu), nao /etc/firefox*/policies/ que eu tinha
# inventado. Mantemos os dois: o caminho correto como primario, e o
# /etc/firefox*/policies/ como cobertura extra para builds que
# suportem esse local alternativo (nao custa nada, e idempotente).
#
# Conteudo da politica trazido para paridade com o core_browser.sh
# (telemetria, Pocket, SearchEngines, SanitizeOnShutdown etc.) -
# antes este modulo tinha uma versao simplificada demais, que a cada
# ciclo de 10min "empobrecia" a politica aplicada no provisionamento.
#
# Bloco de Proxy dinamico por PROXY_MODE - mesma correcao aplicada
# no core_browser.sh (antes ficava fixo em "system" la).
# ============================================================
sync_firefox_policy() {
    echo "--- firefox policy ---"
    command -v firefox-esr &>/dev/null || command -v firefox &>/dev/null || { echo "Firefox nao instalado, pulando"; return 0; }

    case "${PROXY_MODE:-}" in
        MANUAL)
            FIREFOX_PROXY_JSON="\"Proxy\": {
      \"Mode\": \"manual\",
      \"HTTPProxy\": \"${PROXY_HTTP:-}:${PROXY_PORTA:-}\",
      \"SSLProxy\": \"${PROXY_HTTP:-}:${PROXY_PORTA:-}\",
      \"Passthrough\": \"${NO_PROXY:-localhost,127.0.0.1}\",
      \"Locked\": true
    }"
            ;;
        PAC)
            FIREFOX_PROXY_JSON="\"Proxy\": {
      \"Mode\": \"autoConfig\",
      \"AutoConfigURL\": \"${PAC_URL:-}\",
      \"Passthrough\": \"${NO_PROXY:-localhost,127.0.0.1}\",
      \"Locked\": true
    }"
            ;;
        NONE)
            FIREFOX_PROXY_JSON="\"Proxy\": { \"Mode\": \"none\", \"Locked\": true }"
            ;;
        *)
            FIREFOX_PROXY_JSON="\"Proxy\": { \"Mode\": \"system\", \"Locked\": true }"
            ;;
    esac

    read -r -d '' FIREFOX_POLICY_JSON <<EOF || true
{
  "policies": {
    "DisableTelemetry": true,
    "DisableFirefoxStudies": true,
    "DisablePocket": true,
    "DisableDeveloperTools": false,
    "BlockAboutConfig": false,
    "Homepage": {
      "URL": "${HOMEPAGE:-}",
      "Locked": true,
      "StartPage": "homepage"
    },
    "HomepageURL": "${HOMEPAGE:-}",
    "SearchBar": "unified",
    "SearchEngines": {
      "Add": [
        { "Name": "${OM_ACRONYM:-}", "URL": "${HOMEPAGE:-}", "Method": "GET" }
      ]
    },
    ${FIREFOX_PROXY_JSON},
    "Certificates": { "ImportEnterpriseRoots": true },
    "ExtensionSettings": { "*": { "installation_mode": "allowed" } },
    "DisableSetDesktopBackground": false,
    "DontCheckDefaultBrowser": true,
    "PrimaryPassword": false,
    "OfferToSaveLogins": false,
    "PasswordManagerEnabled": false,
    "SanitizeOnShutdown": {
      "Cache": true,
      "Cookies": false,
      "Downloads": false,
      "FormData": true,
      "History": false,
      "Sessions": false,
      "SiteSettings": false,
      "OfflineApps": false
    }
  }
}
EOF

    # Caminho canonico (pacote firefox-esr do Debian/Ubuntu)
    if [ -d /usr/lib/firefox-esr ]; then
        mkdir -p /usr/lib/firefox-esr/distribution
        echo "$FIREFOX_POLICY_JSON" > /usr/lib/firefox-esr/distribution/policies.json
    fi
    if [ -d /usr/lib/firefox ]; then
        mkdir -p /usr/lib/firefox/distribution
        echo "$FIREFOX_POLICY_JSON" > /usr/lib/firefox/distribution/policies.json
    fi
    # Cobertura extra (builds/distros que honram este local alternativo)
    for DIR in /etc/firefox/policies /etc/firefox-esr/policies; do
        PARENT="$(dirname "$DIR")"
        [ -d "$PARENT" ] || continue
        mkdir -p "$DIR"
        echo "$FIREFOX_POLICY_JSON" > "$DIR/policies.json"
    done
}

# ============================================================
# MODULO: politica do Chrome/Chromium
# CONFIRMADO/ALINHADO contra o core_browser.sh - conteudo trazido
# para paridade (BlockThirdPartyCookies, SyncDisabled,
# TelemetryReportingEnabled etc.), mesmo motivo do Firefox acima.
# ============================================================
sync_chrome_policy() {
    echo "--- chrome/chromium policy ---"

    case "${PROXY_MODE:-}" in
        MANUAL)
            CHROME_PROXY_JSON=", \"ProxyMode\": \"fixed_servers\", \"ProxyServer\": \"http=${PROXY_HTTP:-}:${PROXY_PORTA:-};https=${PROXY_HTTP:-}:${PROXY_PORTA:-}\""
            ;;
        PAC)
            CHROME_PROXY_JSON=", \"ProxyMode\": \"pac_script\", \"ProxyPacUrl\": \"${PAC_URL:-}\""
            ;;
        NONE)
            CHROME_PROXY_JSON=", \"ProxyMode\": \"direct\""
            ;;
        *)
            CHROME_PROXY_JSON=", \"ProxyMode\": \"system\""
            ;;
    esac

    read -r -d '' CHROME_POLICY_JSON <<EOF || true
{
    "HomepageLocation": "${HOMEPAGE:-}",
    "HomepageIsNewTabPage": false,
    "RestoreOnStartup": 1,
    "RestoreOnStartupURLs": ["${HOMEPAGE:-}"],
    "BrowserSignin": 0,
    "SyncDisabled": true,
    "BlockThirdPartyCookies": true,
    "BackgroundModeEnabled": false,
    "TelemetryReportingEnabled": false${CHROME_PROXY_JSON},
    "DefaultCookiesSetting": 1,
    "DefaultBrowserSettingEnabled": false
}
EOF

    for DIR in /etc/opt/chrome/policies/managed /etc/chromium/policies/managed /etc/chromium-browser/policies/managed; do
        GRANDPARENT="$(dirname "$(dirname "$DIR")")"
        [ -d "$GRANDPARENT" ] || continue
        mkdir -p "$DIR"
        echo "$CHROME_POLICY_JSON" > "$DIR/seederlinux.json"
    done
}

# ============================================================
# MODULO: proxy do sistema (APT + /etc/environment)
# ============================================================
sync_proxy() {
    echo "--- proxy ---"
    case "${PROXY_MODE:-NONE}" in
        NONE)
            rm -f /etc/apt/apt.conf.d/95seederlinux-proxy
            sed -i '/^http_proxy=/d;/^https_proxy=/d;/^ftp_proxy=/d;/^no_proxy=/d;/^HTTP_PROXY=/d;/^HTTPS_PROXY=/d;/^FTP_PROXY=/d;/^NO_PROXY=/d' /etc/environment 2>/dev/null || true
            ;;
        MANUAL)
            PROXY_FULL_URL="${PROXY_URL:-http://${PROXY_HTTP:-}:${PROXY_PORTA:-}}"
            cat > /etc/apt/apt.conf.d/95seederlinux-proxy <<EOF
Acquire::http::Proxy "${PROXY_FULL_URL}";
Acquire::https::Proxy "${PROXY_FULL_URL}";
EOF
            sed -i '/^http_proxy=/d;/^https_proxy=/d;/^ftp_proxy=/d;/^no_proxy=/d;/^HTTP_PROXY=/d;/^HTTPS_PROXY=/d;/^FTP_PROXY=/d;/^NO_PROXY=/d' /etc/environment 2>/dev/null || true
            {
                echo "http_proxy=\"${PROXY_FULL_URL}\""
                echo "https_proxy=\"${PROXY_FULL_URL}\""
                echo "HTTP_PROXY=\"${PROXY_FULL_URL}\""
                echo "HTTPS_PROXY=\"${PROXY_FULL_URL}\""
                if [ -n "${NO_PROXY:-}" ]; then
                    echo "no_proxy=\"${NO_PROXY}\""
                    echo "NO_PROXY=\"${NO_PROXY}\""
                fi
            } >> /etc/environment
            ;;
        PAC)
            if [ -n "${PAC_URL:-}" ]; then
                cat > /etc/apt/apt.conf.d/95seederlinux-proxy <<EOF
Acquire::http::Proxy::Pac "${PAC_URL}";
Acquire::https::Proxy::Pac "${PAC_URL}";
EOF
            fi
            ;;
    esac
}

# ============================================================
# MODULO: impressoras (CUPS + filas via IPP Everywhere)
#
# CONFIRMADO contra o core_printers.sh real (recebido depois deste
# modulo ser escrito): a convencao de fila ipp://PRINT_SERVER/
# printers/NOME + `-m everywhere` esta correta. Este modulo agora
# tambem reaplica a config do daemon CUPS (cupsd.conf/client.conf/
# cupsctl) e a descoberta automatica quando PRINTERS vem vazio -
# ambos existiam no core_printers.sh (rodado uma vez, no
# provisionamento) mas nao no sync periodico. Por filosofia GPO
# (reaplicar tudo, nao so parte), replicamos aqui tambem.
#
# PRINTERS: lista de nomes separados por espaco (mesma convencao de
# COMPARTILHAMENTOS).
# ============================================================
sync_printers() {
    echo "--- impressoras ---"
    [ -z "${PRINT_SERVER:-}" ] && { echo "PRINT_SERVER vazio, pulando modulo de impressoras"; return 0; }
    command -v cupsctl &>/dev/null || { echo "AVISO: CUPS nao instalado, pulando modulo de impressoras"; return 0; }

    # --- daemon CUPS (idempotente - mesmos valores do core_printers.sh) ---
    systemctl enable cups 2>/dev/null || true
    systemctl start cups 2>/dev/null || true
    cupsctl --remote-admin --remote-any --share-printers 2>/dev/null || true

    cat > /etc/cups/cupsd.conf <<EOF
# Configuracao CUPS - SeederLinux (reaplicada por seeder-sync)
Browsing On
BrowseLocalProtocols dnssd
DefaultAuthType Basic
WebInterface Yes

Listen localhost:631
Listen /run/cups/cups.sock

<Location />
    Order allow,deny
    Allow all
</Location>

<Location /admin>
    Order allow,deny
    Allow all
</Location>

<Location /admin/conf>
    AuthType Default
    Require user @SYSTEM
    Order allow,deny
    Allow all
</Location>
EOF

    cat > /etc/cups/client.conf <<EOF
# Cliente CUPS - SeederLinux (reaplicado por seeder-sync)
ServerName ${PRINT_SERVER}
EOF

    # --- filas de impressora ---
    if [ -n "${PRINTERS:-}" ]; then
        for PRINTER in $PRINTERS; do
            if ! lpstat -p "$PRINTER" &>/dev/null; then
                echo "Criando fila: $PRINTER"
                lpadmin -p "$PRINTER" -E -v "ipp://${PRINT_SERVER}/printers/${PRINTER}" \
                    -m everywhere 2>/dev/null || echo "AVISO: falha ao criar fila '$PRINTER'"
            fi
        done
    else
        echo "PRINTERS vazio - usando descoberta automatica via ${PRINT_SERVER}"
        lpinfo -h "$PRINT_SERVER" -v 2>/dev/null | grep ipp | while read -r line; do
            PRINTER_URI="$(echo "$line" | awk '{print $2}')"
            PRINTER_NAME="$(basename "$PRINTER_URI")"
            lpstat -p "$PRINTER_NAME" &>/dev/null && continue
            echo "Impressora encontrada: $PRINTER_NAME"
            lpadmin -p "$PRINTER_NAME" -E -v "$PRINTER_URI" -m everywhere 2>/dev/null || true
        done
    fi

    # --- impressora padrao (sistema + por usuario com sessao ativa) ---
    if [ -n "${DEFAULT_PRINTER:-}" ]; then
        lpadmin -d "$DEFAULT_PRINTER" 2>/dev/null || echo "AVISO: falha ao definir impressora padrao do sistema"
        for u in $(usuarios_com_sessao_grafica); do
            su - "$u" -c "lpoptions -d '${DEFAULT_PRINTER}'" 2>/dev/null || true
        done
    fi

    systemctl restart cups 2>/dev/null || true
}

# ============================================================
# MODULO: Conky - garante que esta rodando pras sessoes ativas
# ============================================================
sync_conky() {
    echo "--- conky ---"
    [ -x /usr/local/bin/seederlinux-conky ] || return 0
    case "$DESKTOP_ENV" in
        cinnamon|mate)
            for u in $(usuarios_com_sessao_grafica); do
                pgrep -u "$u" conky &>/dev/null || \
                    su - "$u" -c "DISPLAY=:0 /usr/local/bin/seederlinux-conky" 2>/dev/null &
            done
            ;;
    esac
}

# ============================================================
# MODULO: compartilhamentos CIFS - remonta para sessoes ativas que
# eventualmente caíram, sem esperar um novo login
# ============================================================
sync_shares() {
    echo "--- compartilhamentos ---"
    [ -z "${SERVIDOR_ARQUIVOS:-}" ] && return 0
    [ -z "${COMPARTILHAMENTOS:-}" ] && return 0
    MOUNT_DIR="${MOUNT_BASE:-/mnt}"
    for u in $(usuarios_com_sessao_grafica); do
        uid="$(id -u "$u" 2>/dev/null)" || continue
        gid="$(id -g "$u" 2>/dev/null)" || continue
        for SHARE in $COMPARTILHAMENTOS; do
            SHARE_MOUNT="${MOUNT_DIR}/${SHARE}"
            mkdir -p "$SHARE_MOUNT"
            mountpoint -q "$SHARE_MOUNT" 2>/dev/null && continue
            mount -t cifs "//${SERVIDOR_ARQUIVOS}/${SHARE}" "$SHARE_MOUNT" \
                -o "username=${u},domain=${DOMINIO_NETBIOS:-},uid=${uid},gid=${gid},iocharset=utf8,vers=3.0" \
                2>/dev/null || echo "AVISO: falha ao remontar ${SHARE} para ${u}"
        done
    done
}

# ============================================================
# MODULO: certificados corporativos (trust store do sistema)
#
# ATENCAO: sem acesso a logica de certificados original do painel,
# assumimos que CERTIFICATE_BUNDLE pode ser: (a) um unico arquivo
# .crt/.pem, ou (b) um pacote .tar.gz com varios certificados dentro.
# Detectamos pelo Content-Type/magic bytes do download. Revisar se
# a convencao real for outra (ex: PKCS#7 .p7b, .der binario).
# ============================================================
sync_certificates() {
    echo "--- certificados ---"
    [ "${CERTIFICATE_AUTO_INSTALL:-}" = "true" ] || { echo "CERTIFICATE_AUTO_INSTALL != true, pulando"; return 0; }
    [ -z "${CERTIFICATE_BUNDLE:-}" ] && { echo "CERTIFICATE_BUNDLE vazio, pulando"; return 0; }

    CERT_TMP="/tmp/seederlinux-cert-bundle"
    CERT_DEST_DIR="/usr/local/share/ca-certificates/seederlinux"
    mkdir -p "$CERT_DEST_DIR"

    if ! wget -q --no-check-certificate -O "$CERT_TMP" "$CERTIFICATE_BUNDLE" 2>/dev/null; then
        echo "AVISO: falha ao baixar CERTIFICATE_BUNDLE de $CERTIFICATE_BUNDLE"
        return 0
    fi

    FILETYPE="$(file -b "$CERT_TMP" 2>/dev/null)"
    case "$FILETYPE" in
        *gzip*|*tar*)
            echo "Bundle detectado como arquivo compactado, extraindo..."
            mkdir -p /tmp/seederlinux-certs-extract
            tar xzf "$CERT_TMP" -C /tmp/seederlinux-certs-extract 2>/dev/null || \
                tar xf "$CERT_TMP" -C /tmp/seederlinux-certs-extract 2>/dev/null
            find /tmp/seederlinux-certs-extract -type f \( -name "*.crt" -o -name "*.pem" -o -name "*.cer" \) \
                -exec cp {} "$CERT_DEST_DIR/" \;
            rm -rf /tmp/seederlinux-certs-extract
            ;;
        *)
            cp "$CERT_TMP" "$CERT_DEST_DIR/seederlinux-${OM_ACRONYM:-om}.crt"
            ;;
    esac
    rm -f "$CERT_TMP"

    if update-ca-certificates 2>/dev/null; then
        echo "trust store do sistema atualizado ($(ls "$CERT_DEST_DIR" | wc -l) certificado(s))"
    else
        echo "AVISO: update-ca-certificates falhou"
    fi
}

# ============================================================
# Execucao (idempotente - cada modulo e independente)
# ============================================================
sync_branding
sync_firefox_policy
sync_chrome_policy
sync_proxy
sync_printers
sync_conky
sync_shares
sync_certificates

# ============================================================
# Atualizar SERIAL_APLICADO em config.env (persistencia real, nao
# so no STATE_FILE) - so avanca se um SERVER_SERIAL foi de fato
# resolvido; execucao forcada/sem serial disponivel nao "inventa"
# um numero novo, so reaplica e mantem o serial local como estava.
# ============================================================
if [ -n "$SERVER_SERIAL" ]; then
    if grep -q '^SERIAL_APLICADO=' "$CONFIG_FILE" 2>/dev/null; then
        sed -i "s/^SERIAL_APLICADO=.*/SERIAL_APLICADO=\"${SERVER_SERIAL}\"/" "$CONFIG_FILE"
    else
        echo "SERIAL_APLICADO=\"${SERVER_SERIAL}\"" >> "$CONFIG_FILE"
    fi
    SERIAL_APLICADO_ATUAL="$SERVER_SERIAL"
    echo "SERIAL_APLICADO atualizado para $SERVER_SERIAL"
fi

# ============================================================
# Registrar estado (observabilidade - historico de execucoes)
# ============================================================
{
    echo "LAST_SYNC=$(date -Is)"
    echo "SERIAL_APLICADO=${SERIAL_APLICADO_ATUAL}"
    echo "FORCE_SYNC=${FORCE_SYNC}"
} > "$STATE_FILE"

echo "=== seeder-sync concluido: $(date -Is) ==="
SYNCSCRIPT

chmod 750 /usr/local/bin/seeder-sync
echo ">>> /usr/local/bin/seeder-sync criado"

# ============================================================
# 2. Unit systemd (service oneshot + timer 10min)
# ============================================================
echo ">>> Criando servico e timer systemd..."

cat > /etc/systemd/system/seeder-sync.service <<EOF
[Unit]
Description=SeederLinux - Aplicador de politicas (GPO-like)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/seeder-sync --force
EOF

cat > /etc/systemd/system/seeder-sync.timer <<EOF
[Unit]
Description=SeederLinux - Timer do seeder-sync (10 em 10 minutos)

[Timer]
OnBootSec=2min
OnUnitActiveSec=10min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now seeder-sync.timer

# Primeira aplicacao imediata (nao espera os 10min iniciais)
systemctl start seeder-sync.service 2>/dev/null || {
    echo ">>> AVISO: primeira execucao do seeder-sync sera no proximo ciclo do timer."
}

echo ">>> [19] seeder-sync instalado e timer ativo (a cada 10min)"
echo "============================================================"
$SeederScript$,
    TRUE,
    TRUE,
    23,
    1,
    NULL
) ON CONFLICT (filename) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    execution_order = EXCLUDED.execution_order,
    version = EXCLUDED.version,
    is_active = EXCLUDED.is_active,
    updated_at = CURRENT_TIMESTAMP;



-- ============================================================================
-- FIM: 23 scripts core inseridos.
-- Ordem de execucao:
--   01 core_dns.sh              (configura DNS ANTES de apt-get update)
--   02 core_repositories.sh     (agora tem DNS resolvendo)
--   03 core_packages.sh
--   04 core_legados.sh
--   05 core_apps.sh
--   06 core_domain.sh
--   07 core_ssh.sh
--   08 core_browser.sh
--   09 core_inventory.sh
--   10 core_printers.sh
--   11 core_vnc.sh
--   12 core_conky.sh
--   13 core_config.sh
--   14 core_branding.sh
--   15 core_logon.sh
--   16 core_password_change.sh
--   17 core_logoff.sh
--   18 core_session_{lightdm|gdm3|sddm}.sh   (bundle mantem apenas 1 conforme DISPLAY_MANAGER)
--   21 core_agent.sh
--   22 core_proxy.sh
--   23 core_sync.sh              (seeder-sync + timer systemd: reaplica politicas)
-- ============================================================================
