#!/bin/bash
# ============================================================================
# Core Script: core_ssh.sh
# SeederLinux Lite - Configuracao SSH (porta, AllowGroups)
# Executado APOS o ingresso no AD para que os grupos do dominio existam.
# ============================================================================

set -e

source /usr/local/lib/seederlinux/diag.sh 2>/dev/null || true
SCRIPT_ID="08-ssh"

echo "============================================================"
echo "Configurar SSH"
echo "============================================================"

SSH_PORT="{{SSH_PORT}}"
# Herdar do header do bundle (fonte de verdade).
# Formato canônico do painel: 'domain+admins' representa 'domain admins'.
SSH_GROUPS="${SSH_GROUPS:-root,_dasti}"

log_nivel INFO "Porta SSH: ${SSH_PORT:-22}"
log_nivel INFO "Grupos SSH: ${SSH_GROUPS:-nenhum}"

# Configurar porta
if [ -n "$SSH_PORT" ] && [ "$SSH_PORT" != "" ] && [ "$SSH_PORT" != "22" ]; then
    log_nivel INFO "Configurando porta SSH: $SSH_PORT"
    if [ -f /etc/ssh/sshd_config ]; then
        cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S) 2>/dev/null || true
        sed -i "s/^#*Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
        log_nivel INFO "Porta SSH alterada para $SSH_PORT"
    fi
fi

# ============================================================
# Configurar AllowGroups do sshd
#
# Parse CSV (respeitando aspas duplas) via Python. O resultado
# é um array Bash — NUNCA concatenar em string com espaço,
# senão nomes com espaço (ex: "Domain Admins") são quebrados
# em dois tokens no loop seguinte.
#
# Formato canônico do painel usa '+' no lugar de espaço
# (ex: domain+admins). Aqui revertimos + → espaço antes de
# validar o grupo.
#
# sshd AllowGroups suporta aspas duplas para grupos com espaco
# (man 5 sshd_config). Grupos com espaco SAO validos, desde que
# escritos com aspas. Ex: AllowGroups root _dasti "Admins. do domínio".
# ============================================================
if [ -n "$SSH_GROUPS" ] && [ "$SSH_GROUPS" != "" ]; then
    log_nivel INFO "Configurando AllowGroups: $SSH_GROUPS"
    if [ -f /etc/ssh/sshd_config ]; then

        # Parse CSV (respeitando aspas) → array Bash
        GRP_ARRAY=()
        while IFS= read -r _item; do
            [ -z "$_item" ] && continue
            GRP_ARRAY+=("$_item")
        done < <(python3 - "$SSH_GROUPS" <<'PY'
import csv, sys
raw = sys.argv[1] if len(sys.argv) > 1 else ""
for row in csv.reader([raw], skipinitialspace=True):
    for item in row:
        item = item.strip()
        if item:
            print(item)
PY
        )

        # Filtrar: só entra no AllowGroups se existir via getent E não tiver espaço
        GRP_LIST_FILTRADO=""
        _sem_espaco_count=0
        _com_espaco_count=0
        _inexistente_count=0

        for GRP in "${GRP_ARRAY[@]}"; do
            [ -z "$GRP" ] && continue

            # Reverter + para espaço (formato canônico do painel)
            GRP="$(printf '%s' "$GRP" | tr '+' ' ')"

            # OpenSSH suporta aspas em AllowGroups para grupos com espaco.
            if ! getent group "$GRP" >/dev/null 2>&1; then
                log_nivel AVISO "grupo '$GRP' nao existe - removido do AllowGroups."
                _inexistente_count=$((_inexistente_count + 1))
                continue
            fi

            if echo "$GRP" | grep -q ' '; then
                if [ -z "$GRP_LIST_FILTRADO" ]; then
                    GRP_LIST_FILTRADO="\"$GRP\""
                else
                    GRP_LIST_FILTRADO="$GRP_LIST_FILTRADO \"$GRP\""
                fi
                _com_espaco_count=$((_com_espaco_count + 1))
            else
                if [ -z "$GRP_LIST_FILTRADO" ]; then
                    GRP_LIST_FILTRADO="$GRP"
                else
                    GRP_LIST_FILTRADO="$GRP_LIST_FILTRADO $GRP"
                fi
                _sem_espaco_count=$((_sem_espaco_count + 1))
            fi
        done

        # Escrever o AllowGroups final (só com grupos válidos e sem espaço)
        if [ -n "$GRP_LIST_FILTRADO" ]; then
            sed -i "s/^#*AllowGroups .*/AllowGroups $GRP_LIST_FILTRADO/" /etc/ssh/sshd_config
            if ! grep -q "^AllowGroups " /etc/ssh/sshd_config; then
                echo "AllowGroups $GRP_LIST_FILTRADO" >> /etc/ssh/sshd_config
            fi

            if sshd -t 2>/dev/null; then
                log_nivel INFO "AllowGroups final: $GRP_LIST_FILTRADO"
                log_nivel INFO "  (grupos validos: $_sem_espaco_count | com espaco (com aspas): $_com_espaco_count | inexistentes: $_inexistente_count)"
            else
                log_nivel ERRO "sshd -t FALHOU com AllowGroups '$GRP_LIST_FILTRADO'. Revertendo."
                sed -i '/^AllowGroups /d' /etc/ssh/sshd_config
                log_nivel AVISO "AllowGroups removido do sshd_config. Revise o SSH_GROUPS no painel."
            fi
        else
            log_nivel ERRO "nenhum grupo do AllowGroups e' valido - NAO aplicando AllowGroups."
            log_nivel INFO "Verifique o SSH_GROUPS no painel da OM."
            sed -i '/^AllowGroups /d' /etc/ssh/sshd_config 2>/dev/null || true
        fi
    fi
fi

# Ubuntu 24.04+ usa ssh.socket (socket activation) com ListenStream=22
# hardcoded que ignora "Port" do sshd_config. Desabilitar o socket
# para a porta customizada valer e usar o ssh.service tradicional.
if [ -n "$SSH_PORT" ] && [ "$SSH_PORT" != "" ] && [ "$SSH_PORT" != "22" ]; then
    if systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
        systemctl disable --now ssh.socket 2>/dev/null || true
        systemctl mask ssh.socket 2>/dev/null || true
    fi
fi
systemctl enable ssh 2>/dev/null || true

# Reiniciar SSH
if [ -f /etc/ssh/sshd_config ]; then
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
fi

log_nivel OK "SSH configurado!"
echo "============================================================"
