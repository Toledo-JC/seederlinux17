#!/bin/bash
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
