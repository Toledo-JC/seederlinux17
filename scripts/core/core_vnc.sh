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

[Service]
Type=simple
ExecStart=/usr/bin/x11vnc -display ${VNC_DISPLAY} -auth ${VNC_AUTH} -forever -loop -noxdamage -repeat -rfbauth /etc/x11vnc/vncpasswd -rfbport 5900 -shared -o /var/log/x11vnc.log
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
