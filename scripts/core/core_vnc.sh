#!/bin/bash
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

source /usr/local/lib/seederlinux/diag.sh 2>/dev/null || true
SCRIPT_ID="12-vnc"

echo "============================================================"
echo "Configurar x11vnc"
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
        log_nivel AVISO "Falha ao decodificar VNC_PASSWORD_B64. Sera gerada senha aleatoria."
    fi
fi
unset VNC_PASSWORD_B64

log_nivel INFO "VNC habilitado: $VNC_ENABLED"

# ============================================================
# Verificar se VNC esta habilitado
# ============================================================
if [ "$VNC_ENABLED" != "true" ]; then
    log_nivel INFO "VNC desativado. Pulando configuracao."
    log_nivel INFO "[08] x11vnc desativado."
    echo "============================================================"
    exit 0
fi

# ============================================================
# Verificar se o x11vnc foi instalado (no core_packages.sh)
# ============================================================
if ! command -v x11vnc &>/dev/null; then
    log_nivel AVISO "x11vnc nao instalado. Pulando configuracao."
    log_nivel INFO "[08] x11vnc nao configurado (pacote ausente)."
    echo "============================================================"
    exit 0
fi

# ============================================================
# Configurar senha do VNC (SEM expor em texto plano)
# ============================================================
log_nivel INFO "Configurando senha do VNC..."
mkdir -p /etc/x11vnc
mkdir -p /etc/seederlinux

SECRETS_FILE="/etc/seederlinux/secrets.env"

if [ -n "$VNC_PASSWORD" ] && [ "$VNC_PASSWORD" != "" ]; then
    x11vnc -storepasswd "$VNC_PASSWORD" /etc/x11vnc/vncpasswd
    chmod 600 /etc/x11vnc/vncpasswd
    log_nivel INFO "Senha VNC configurada (fornecida pela OM)"
    echo "VNC_PASSWORD_SET=true" >> "$SECRETS_FILE"
else
    log_nivel INFO "VNC_PASSWORD nao definido. Gerando senha aleatoria."
    RANDOM_PASS=$(openssl rand -base64 12)
    x11vnc -storepasswd "$RANDOM_PASS" /etc/x11vnc/vncpasswd
    chmod 600 /etc/x11vnc/vncpasswd
    log_nivel INFO "Senha VNC gerada com sucesso"
    echo "VNC_PASSWORD_SET=true" >> "$SECRETS_FILE"
fi

chmod 600 "$SECRETS_FILE" 2>/dev/null || true
unset VNC_PASSWORD
unset VNC_PASSWORD_B64
unset RANDOM_PASS

# ============================================================
# Criar servico systemd para x11vnc
# ============================================================
log_nivel INFO "Criando servico systemd x11vnc..."

# ============================================================
# Detectar o Display Manager ativo ou instalado
# ============================================================
detectar_dm_ativo() {
    if systemctl is-active --quiet lightdm 2>/dev/null; then echo "lightdm"
    elif systemctl is-active --quiet gdm3 2>/dev/null; then echo "gdm3"
    elif systemctl is-active --quiet sddm 2>/dev/null; then echo "sddm"
    elif systemctl is-active --quiet lxdm 2>/dev/null; then echo "lxdm"
    elif systemctl is-active --quiet slim 2>/dev/null; then echo "slim"
    else echo ""
    fi
}

detectar_dm_instalado() {
    if dpkg -l lightdm 2>/dev/null | grep -q "^ii"; then echo "lightdm"
    elif dpkg -l gdm3 2>/dev/null | grep -q "^ii"; then echo "gdm3"
    elif dpkg -l sddm 2>/dev/null | grep -q "^ii"; then echo "sddm"
    elif dpkg -l lxdm 2>/dev/null | grep -q "^ii"; then echo "lxdm"
    elif dpkg -l slim 2>/dev/null | grep -q "^ii"; then echo "slim"
    else echo ""
    fi
}

DISPLAY_MANAGER="$(detectar_dm_ativo)"
[ -z "$DISPLAY_MANAGER" ] && DISPLAY_MANAGER="$(detectar_dm_instalado)"
[ -n "$DISPLAY_MANAGER" ] && log_nivel INFO "Display Manager: $DISPLAY_MANAGER"

# ============================================================
# Resolver Xauthority para o Display Manager detectado
# ============================================================
VNC_XAUTH=""

case "$DISPLAY_MANAGER" in
    lightdm)
        if [ -r /var/run/lightdm/root/:0 ]; then
            VNC_XAUTH="/var/run/lightdm/root/:0"
        fi
        ;;
    sddm)
        for d in /var/run/sddm/xauth_* /run/sddm/xauth_*; do
            [ -r "$d" ] && VNC_XAUTH="$d" && break
        done
        ;;
    lxdm)
        if [ -r /var/run/lxdm/lxdm.auth ]; then
            VNC_XAUTH="/var/run/lxdm/lxdm.auth"
        fi
        ;;
    slim)
        if [ -r /var/run/slim.auth ]; then
            VNC_XAUTH="/var/run/slim.auth"
        fi
        ;;
    gdm3)
        for d in /run/user/*/gdm/Xauthority /var/run/gdm3/*/database/Xauthority /run/gdm3/*/database/Xauthority; do
            if [ -r "$d" ]; then
                mkdir -p /etc/x11vnc
                cp -f "$d" /etc/x11vnc/Xauthority 2>/dev/null && \
                    chmod 600 /etc/x11vnc/Xauthority && \
                    VNC_XAUTH="/etc/x11vnc/Xauthority"
                break
            fi
        done
        ;;
esac

if [ -z "$VNC_XAUTH" ]; then
    for d in /var/run/*/root/:0 /var/run/*/*.auth /run/*/*.auth /run/user/*/gdm/Xauthority; do
        if [ -r "$d" ]; then
            VNC_XAUTH="$d"
            break
        fi
    done
fi

if [ -n "$VNC_XAUTH" ]; then
    VNC_AUTH_ARG="-auth $VNC_XAUTH"
    log_nivel INFO "Xauthority: $VNC_XAUTH"
else
    VNC_AUTH_ARG="-auth guess"
    log_nivel AVISO "Xauthority nao encontrado - usando '-auth guess' (pode falhar em GDM3)"
fi

VNC_DISPLAY=":0"
log_nivel INFO "Display: $VNC_DISPLAY"
log_nivel INFO "Argumento de auth: $VNC_AUTH_ARG"

cat > /etc/systemd/system/x11vnc.service <<EOF
[Unit]
Description=x11vnc Server - SeederLinux
After=display-manager.service
Wants=display-manager.service

[Service]
Type=simple
ExecStart=/usr/bin/x11vnc -display ${VNC_DISPLAY} ${VNC_AUTH_ARG} -forever -loop -noxdamage -repeat -rfbauth /etc/x11vnc/vncpasswd -rfbport 5900 -shared -o /var/log/x11vnc.log
ExecStop=/usr/bin/killall x11vnc
Restart=on-failure
RestartSec=15

[Install]
WantedBy=graphical.target
EOF

systemctl daemon-reload
systemctl enable x11vnc.service
systemctl start x11vnc.service 2>/dev/null || {
    log_nivel AVISO "Nao foi possivel iniciar x11vnc agora."
    log_nivel INFO "O servico sera iniciado apos o display manager."
}

log_nivel OK "x11vnc configurado!"
echo "============================================================"
)
