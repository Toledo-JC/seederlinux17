#!/bin/bash
# ============================================================================
# Core Script: core_session_lightdm.sh
# SeederLinux Lite - LightDM: logon/logoff (MATE, Cinnamon, XFCE, LXDE)
# ============================================================================
# Configura o LightDM como display manager e define os scripts de logon
# e logoff que serao executados nas transicoes de sessao.
#
# Resolucao de DESKTOP_ENV/DISPLAY_MANAGER (nessa ordem):
#   1) Valor injetado pela OM ( / )
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
# CORRECAO CRITICA (v1): a versao anterior usava `return 0` dentro deste
# subshell "( ... )", o que nao e uma funcao. Isso gera erro em
# runtime ("return: can only `return' from a function or sourced
# script"), o subshell termina com exit code != 0 e, como o bundle
# roda com `set -e`, o erro ABORTA O BUNDLE INTEIRO ali mesmo -
# em qualquer distro/DE. Este script usa `exit` (valido dentro do
# subshell) em todos os pontos de saida antecipada.
#
# CORRECAO CRITICA (v2, esta versao): o bloco final de "reiniciar
# LightDM" foi REMOVIDO. Motivo:
#   - A tentativa de guarda era: reiniciar so se estiver via TTY/cron
#     (sem $DISPLAY) ou se vier por SSH ($SSH_CONNECTION), para nao
#     matar sessao local.
#   - O caso NAO pensado: o agente Python roda via cron, sem $DISPLAY
#     e sem $SSH_CONNECTION. Cai exatamente na condicao que reinicia
#     o LightDM -> mata a sessao do usuario logado, sem aviso.
#   - Nao ha necessidade de reiniciar o DM para aplicar a config: ele
#     le os arquivos quando sobe, no proximo boot. Reiniciar em
#     runtime so serve para "aplicar agora", e isso nunca justifica
#     matar sessao de usuario.
#   - Regra do projeto: o bundle NAO reinicia display manager.
#
# Os placeholders VARIAVEL sao substituidos automaticamente
# pelo sistema na geracao do bundle.
# ============================================================================

(
set -e

echo "============================================================"
echo "14a - Configurar LightDM (MATE, Cinnamon, XFCE, LXDE)"
echo "============================================================"

# ============================================================
# Variáveis
# ============================================================
DISPLAY_MANAGER=""
DESKTOP_ENV=""
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

systemctl enable lightdm 2>/dev/null || true
ln -sf /lib/systemd/system/lightdm.service /etc/systemd/system/display-manager.service

# ============================================================
# Aplicacao da config: NAO reiniciar o DM.
#
# Versao anterior tentava reiniciar "so quando seguro" usando
# `[ -z "$DISPLAY" ] || [ -n "$SSH_CONNECTION" ]`. Isso FALHAVA
# quando o bundle era invocado pelo agente Python (via cron):
# cron nao tem $DISPLAY nem $SSH_CONNECTION, entao a condicao dava
# verdadeiro, o restart acontecia e MATAVA A SESSAO DO USUARIO.
#
# Solucao: nao reiniciar nunca. A config do LightDM e' lida pelo
# daemon quando ele sobe - no proximo boot a config ja vale. Nao
# ha caso legitimo de "precisa aplicar agora" que justifique matar
# sessao de usuario logado.
# ============================================================
echo ">>> Configuracao de LightDM sera aplicada no proximo boot."
echo ">>> (NAO reiniciamos o DM aqui: se o bundle rodar via cron/agente,"
echo ">>>  ele nao tem \$DISPLAY nem \$SSH_CONNECTION - qualquer restart"
echo ">>>  mataria a sessao do usuario logado.)"

echo ">>> [14a] LightDM configurado!"
echo "============================================================"
)
