#!/bin/bash
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
            # Trim leading/trailing whitespace sem xargs (xargs consome "\ ")
            GRP="${GRP#"${GRP%%[![:space:]]*}"}"
            GRP="${GRP%"${GRP##*[![:space:]]}"}"
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

# Validar grupos do AllowGroups (evita lockout silencioso)
if [ -n "$GRP_LIST" ]; then
    for GRP in $GRP_LIST; do
        if ! getent group "$GRP" >/dev/null 2>&1; then
            echo ">>> AVISO: grupo '$GRP' nao existe no sistema/AD."
            echo ">>>        AllowGroups vai BLOQUEAR todo mundo ate corrigir."
        fi
    done
fi

# Ubuntu 24.04+ usa ssh.socket (socket activation) com ListenStream=22
# hardcoded que ignora "Port" do sshd_config. Desabilitar o socket
# para a porta customizada valer e usar o ssh.service tradicional.
if systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
    systemctl disable --now ssh.socket 2>/dev/null || true
fi
systemctl enable ssh 2>/dev/null || true

# Reiniciar SSH
if [ -f /etc/ssh/sshd_config ]; then
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
fi

echo ">>> [07] SSH configurado!"
echo "============================================================"
