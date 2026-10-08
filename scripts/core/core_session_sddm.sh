#!/bin/bash
# ============================================================================
# Core Script: core_session_sddm.sh
# SeederLinux Lite - SDDM: logon/logoff (KDE)
# ============================================================================
# Configura o SDDM como display manager e define os scripts de logon
# e logoff que serao executados nas transicoes de sessao.
#
# Resolucao de DESKTOP_ENV/DISPLAY_MANAGER (nessa ordem):
#   1) Valor injetado pela OM ( / )
#   2) Valor ja persistido em /etc/seederlinux/config.env (escrito pelo
#      core_session_lightdm.sh/core_session_gdm3.sh ou por este mesmo
#      script)
#   3) Deteccao em runtime: DM ja ativo -> DM ja instalado -> padrao
#      por DE (gnome->gdm3, kde->sddm, qualquer outro->lightdm)
#
# CORRECAO CRITICA (v1): a versao anterior usava `return 0` dentro deste
# subshell "( ... )", o que nao e uma funcao e gera erro em runtime,
# abortando o BUNDLE INTEIRO sob `set -e`. Este script usa `exit`
# em todos os pontos de saida antecipada.
#
# CORRECAO CRITICA (v2, esta versao): o bloco final de "reiniciar
# SDDM" foi REMOVIDO. Mesmo motivo do LightDM/GDM3: quando o bundle
# roda via cron/agente, $DISPLAY e $SSH_CONNECTION nao existem, entao
# o guard nao protegia nada - reiniciava e matava a sessao do usuario.
# Regra do projeto: o bundle NAO reinicia display manager.
#
# Os placeholders VARIAVEL sao substituidos automaticamente
# pelo sistema na geracao do bundle.
# ============================================================================

(
set -e

source /usr/local/lib/seederlinux/diag.sh 2>/dev/null || true
SCRIPT_ID="18-session-sddm"

echo "============================================================"
echo "Configurar SDDM (KDE)"
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
    log_nivel INFO "DESKTOP_ENV nao informado. Detectado em runtime: $DESKTOP_ENV"
else
    log_nivel INFO "DESKTOP_ENV: $DESKTOP_ENV"
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
    log_nivel INFO "DISPLAY_MANAGER nao informado. Resolvido automaticamente: $DISPLAY_MANAGER"
else
    log_nivel INFO "DISPLAY_MANAGER: $DISPLAY_MANAGER"
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
    log_nivel INFO "DISPLAY_MANAGER resolvido e '$DISPLAY_MANAGER' (nao e sddm). Pulando."
    echo "============================================================"
    exit 0
fi

log_nivel INFO "Display Manager: $DISPLAY_MANAGER"
log_nivel INFO "Ambiente: $DESKTOP_ENV"

# ============================================================
# Verificar se SDDM esta presente.
# CORRECAO: NAO instalar aqui - este script roda DEPOIS do ingresso
# no AD, quando o DNS ja foi trocado pro controlador de dominio e
# nao resolve mais repositorios publicos. A instalacao real acontece
# no core_packages.sh (etapa 04), enquanto o DNS de internet ainda
# esta ativo.
# ============================================================
if ! dpkg -l sddm 2>/dev/null | grep -q "^ii"; then
    log_nivel ERRO "sddm nao instalado (deveria ter sido no core_packages.sh)."
    log_nivel INFO "Pulando configuracao do SDDM."
    echo "============================================================"
    exit 0
fi

echo "sddm shared/default-x-display-manager select sddm" | debconf-set-selections 2>/dev/null || true
echo "sddm sddm/daemon_name string sddm" | debconf-set-selections 2>/dev/null || true
echo "/usr/sbin/sddm" > /etc/X11/default-display-manager

# ============================================================
# Configurar SDDM
# ============================================================
log_nivel INFO "Configurando SDDM..."
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

log_nivel INFO "SDDM configurado"

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
log_nivel INFO "Configurando script de logoff no SDDM..."

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

log_nivel INFO "Scripts de logon/logoff configurados no SDDM"

# ============================================================
# Garantir que os scripts de logon/logoff existam
# ============================================================
log_nivel INFO "Verificando scripts de logon/logoff..."
for SCRIPT in seederlinux-logon seederlinux-logoff; do
    if [ ! -f "/usr/local/bin/${SCRIPT}" ]; then
        log_nivel AVISO "/usr/local/bin/${SCRIPT} nao encontrado."
        log_nivel INFO "Os scripts core_logon.sh e core_logoff.sh devem ser executados antes."
    fi
done

# ============================================================
# Desabilitar outros display managers
# ============================================================
log_nivel INFO "Desabilitando outros display managers..."
systemctl disable lightdm 2>/dev/null || true
systemctl disable gdm3 2>/dev/null || true

systemctl enable sddm 2>/dev/null || true
ln -sf /lib/systemd/system/sddm.service /etc/systemd/system/display-manager.service

# ============================================================
# Aplicacao da config: NAO reiniciar o DM.
# Mesmo motivo do core_session_lightdm.sh/gdm3.sh - o guard baseado
# em $DISPLAY/$SSH_CONNECTION falha quando o bundle roda via cron
# (agente Python), matando a sessao do usuario logado.
# ============================================================
log_nivel INFO "Configuracao de SDDM sera aplicada no proximo boot."
log_nivel INFO "(NAO reiniciamos o DM aqui - ver comentario no topo deste script.)"

log_nivel OK "SDDM configurado!"
echo "============================================================"
)
