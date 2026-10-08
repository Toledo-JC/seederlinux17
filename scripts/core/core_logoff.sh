#!/bin/bash
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

source /usr/local/lib/seederlinux/diag.sh 2>/dev/null || true
SCRIPT_ID="21-logoff"

echo "============================================================"
echo "Logoff minimalista"
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
log_nivel INFO "Criando script permanente: /usr/local/bin/seederlinux-logoff"

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
    MOUNT_DIR="${MOUNT_BASE:-/mnt/servidor}"
    IFS=',' read -ra _shares_arr <<< "$COMPARTILHAMENTOS"
    for SHARE in "${_shares_arr[@]}"; do
        SHARE="${SHARE#"${SHARE%%[![:space:]]*}"}"
        SHARE="${SHARE%"${SHARE##*[![:space:]]}"}"
        [ -z "$SHARE" ] && continue

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
    IFS=',' read -ra _shares_arr <<< "$COMPARTILHAMENTOS"
    for SHARE in "${_shares_arr[@]}"; do
        SHARE="${SHARE#"${SHARE%%[![:space:]]*}"}"
        SHARE="${SHARE%"${SHARE##*[![:space:]]}"}"
        [ -z "$SHARE" ] && continue
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
log_nivel INFO "Script permanente criado: /usr/local/bin/seederlinux-logoff"
log_nivel OK "Logoff minimalista instalado!"
echo "============================================================"
