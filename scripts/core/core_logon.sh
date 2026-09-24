#!/bin/bash
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
# PRIVILEGIO:
# Como o script agora roda como usuario comum (nao root), mount/umount
# de CIFS precisam de sudo. Mas sudo 1.9.x+ (Ubuntu 24.04/26.04)
# REJEITA wildcards em argumentos de comando dentro do sudoers:
#
#   /etc/sudoers.d/xxx: syntax error:
#   wildcards are not allowed in command arguments
#
# (sudo antigo do Mint aceitava; por isso o bundle passava la e
# abortava no Ubuntu 26.04 sob `set -e`.)
#
# SOLUCAO: expor dois wrappers em /usr/local/bin/ que fazem a
# validacao do share internamente (whitelist via config.env) e
# chamam /bin/mount e /bin/umount com caminhos absolutos. O sudoers
# autoriza apenas os wrappers - sem wildcards, sem argumentos com
# padroes. Funciona identico em qualquer versao de sudo.
#
# Os placeholders VARIAVEL sao substituidos automaticamente
# pelo sistema na geracao do bundle.
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

MOUNT_DIR="${MOUNT_BASE:-/mnt/servidor}"

# ============================================================
# 1. Wrappers de mount/umount
#
# Motivo: sudo 1.9.x+ rejeita wildcards em argumentos. Em vez de
# autorizar /bin/mount -t cifs * e /bin/umount <dir>/* no sudoers,
# autorizamos dois wrappers que:
#   - leem /etc/seederlinux/config.env (fonte de verdade da OM)
#   - validam que o share pedido esta em COMPARTILHAMENTOS
#   - validam que o caminho resolvido fica dentro de MOUNT_BASE
#   - chamam /bin/mount | /bin/umount com caminhos absolutos
#
# Isso da uma superficie de ataque MENOR que a versao anterior com
# wildcards - e funciona em qualquer versao de sudo.
# ============================================================
echo ">>> Criando wrappers de mount/umount (compat sudo 1.9.x+)..."
mkdir -p /usr/local/bin

cat > /usr/local/bin/seederlinux-mount-share <<'MOUNT_WRAPPER'
#!/bin/bash
# seederlinux-mount-share - mount CIFS com whitelist interna.
# Uso: seederlinux-mount-share <share> <servidor> <usuario> <uid> <gid>
#
# Seguranca: valida que <share> esta em COMPARTILHAMENTOS do
# /etc/seederlinux/config.env, que <servidor> nao tem path traversal,
# e que o alvo resolvido fica dentro de MOUNT_BASE. So entao chama
# /bin/mount com caminhos absolutos. NAO aceita flags do usuario.
set -euo pipefail

SHARE="${1:?share obrigatorio}"
SERVER="${2:?servidor obrigatorio}"
RUN_USER="${3:?usuario obrigatorio}"
RUN_UID="${4:?uid obrigatorio}"
RUN_GID="${5:?gid obrigatorio}"

if [ -f /etc/seederlinux/config.env ]; then
    # shellcheck disable=SC1090
    . /etc/seederlinux/config.env
fi

# Whitelist: share precisa estar na lista COMPARTILHAMENTOS.
AUTORIZADO=false
for s in ${COMPARTILHAMENTOS:-}; do
    if [ "$s" = "$SHARE" ]; then AUTORIZADO=true; break; fi
done
if [ "$AUTORIZADO" != "true" ]; then
    echo "seederlinux-mount-share: share nao autorizado: $SHARE" >&2
    exit 1
fi

# Server nao pode conter / nem ..
case "$SERVER" in
    */*|*..*)
        echo "seederlinux-mount-share: servidor invalido: $SERVER" >&2
        exit 1
        ;;
esac

MOUNT_BASE_DIR="${MOUNT_BASE:-/mnt/servidor}"
TARGET="${MOUNT_BASE_DIR%/}/${SHARE}"

# Alvo tem que estar dentro de MOUNT_BASE_DIR.
case "$TARGET" in
    "${MOUNT_BASE_DIR%/}"/*) ;;
    *)
        echo "seederlinux-mount-share: target fora de MOUNT_BASE: $TARGET" >&2
        exit 1
        ;;
esac

mkdir -p "$TARGET"

exec /bin/mount -t cifs "//${SERVER}/${SHARE}" "$TARGET" \
    -o "username=${RUN_USER},domain=${DOMINIO_NETBIOS:-},uid=${RUN_UID},gid=${RUN_GID},iocharset=utf8,vers=3.0"
MOUNT_WRAPPER
chmod 0755 /usr/local/bin/seederlinux-mount-share

cat > /usr/local/bin/seederlinux-umount-share <<'UMOUNT_WRAPPER'
#!/bin/bash
# seederlinux-umount-share - umount CIFS com whitelist interna.
# Uso: seederlinux-umount-share <share>
set -euo pipefail

SHARE="${1:?share obrigatorio}"

if [ -f /etc/seederlinux/config.env ]; then
    # shellcheck disable=SC1090
    . /etc/seederlinux/config.env
fi

AUTORIZADO=false
for s in ${COMPARTILHAMENTOS:-}; do
    if [ "$s" = "$SHARE" ]; then AUTORIZADO=true; break; fi
done
if [ "$AUTORIZADO" != "true" ]; then
    echo "seederlinux-umount-share: share nao autorizado: $SHARE" >&2
    exit 1
fi

MOUNT_BASE_DIR="${MOUNT_BASE:-/mnt/servidor}"
TARGET="${MOUNT_BASE_DIR%/}/${SHARE}"

case "$TARGET" in
    "${MOUNT_BASE_DIR%/}"/*) ;;
    *)
        echo "seederlinux-umount-share: target fora de MOUNT_BASE: $TARGET" >&2
        exit 1
        ;;
esac

exec /bin/umount "$TARGET"
UMOUNT_WRAPPER
chmod 0755 /usr/local/bin/seederlinux-umount-share

# ============================================================
# 2. sudoers restrito (sem wildcards - compat sudo 1.9.x+)
# ============================================================
echo ">>> Configurando sudoers restrito para logon..."
SUDOERS_FILE="/etc/sudoers.d/seederlinux-logon"
cat > "$SUDOERS_FILE" <<EOF
# SeederLinux - permissoes minimas para o logon do usuario.
# Restrito aos wrappers (que validam share internamente via
# /etc/seederlinux/config.env) e ao disparo do seeder-sync.
#
# NAO usar wildcards aqui: sudo 1.9.x+ (Ubuntu 24.04+) rejeita
# wildcards em argumentos de comando com "syntax error: wildcards
# are not allowed in command arguments". Os wrappers resolvem isso.
Cmnd_Alias SEEDERLINUX_MOUNT  = /usr/local/bin/seederlinux-mount-share
Cmnd_Alias SEEDERLINUX_UMOUNT = /usr/local/bin/seederlinux-umount-share
Cmnd_Alias SEEDERLINUX_SYNC   = /usr/local/bin/seeder-sync
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
# 3. Preparar diretorio de log (mundo-gravavel com sticky bit)
# ============================================================
mkdir -p /var/log/logon-logoff
chmod 1777 /var/log/logon-logoff

# ============================================================
# 4. Pre-criar os pontos de montagem (como root, agora, uma vez)
# ============================================================
mkdir -p "$MOUNT_DIR"
if [ -n "$COMPARTILHAMENTOS" ]; then
    for SHARE in $COMPARTILHAMENTOS; do
        mkdir -p "${MOUNT_DIR}/${SHARE}"
    done
fi
chmod 755 "$MOUNT_DIR"

# ============================================================
# 5. Criar o script PERMANENTE em /usr/local/bin/seederlinux-logon
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
# Montar compartilhamentos CIFS via wrapper com sudo restrito.
# O wrapper (seederlinux-mount-share) valida share/servidor/target
# internamente e chama /bin/mount. Sudoers autoriza apenas o wrapper.
# ============================================================
if [ -n "$SERVIDOR_ARQUIVOS" ] && [ -n "$COMPARTILHAMENTOS" ]; then
    MOUNT_DIR="${MOUNT_BASE:-/mnt/servidor}"
    for SHARE in $COMPARTILHAMENTOS; do
        SHARE_MOUNT="${MOUNT_DIR}/${SHARE}"
        if ! mountpoint -q "$SHARE_MOUNT" 2>/dev/null; then
            if sudo -n /usr/local/bin/seederlinux-mount-share \
                    "$SHARE" "$SERVIDOR_ARQUIVOS" "$USERNAME" "$(id -u)" "$(id -g)" \
                    >/dev/null 2>&1; then
                echo "Compartilhamento montado: ${SHARE}"
            else
                echo "AVISO: falha ao montar ${SHARE} (verifique credenciais/sudoers)"
            fi
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
# 6. Registrar via autostart XDG (funciona em GNOME, Cinnamon, MATE,
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
