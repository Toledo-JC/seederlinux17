#!/bin/bash
# ============================================================================
# Core Script: core_sync.sh
# SeederLinux Lite - seeder-sync: aplicador de politicas (estilo GPO)
# ============================================================================
# Instala /usr/local/bin/seeder-sync + timer systemd (10 em 10 minutos),
# responsavel por REAPLICAR de forma idempotente toda a configuracao
# corporativa da OM (branding, politicas de navegador, proxy de CLI,
# impressoras, Conky, compartilhamentos), independente de login/logoff.
#
# MODELO MULTI-PROXY:
#   Le as 3 politicas (APT/CLI/BROWSER) do config.env. Reaplica CLI_POLICY
#   em /etc/environment e BROWSER_POLICY em policies.json. APT_POLICY nao
#   e reaplicada pelo sync (repositorios nao mudam a cada 10min) - fica
#   sob responsabilidade de core_repositories.sh na provision.
#
# LIMITACAO CONHECIDA: modulos de impressoras e certificados sao
# subconjunto simplificado. Revisar antes de producao.
#
# Os placeholders VARIAVEL sao substituidos automaticamente
# pelo sistema na geracao do bundle.
# ============================================================================

set -e

echo "============================================================"
echo "19 - Instalar seeder-sync (aplicador GPO) + timer systemd"
echo "============================================================"

mkdir -p /etc/seederlinux
mkdir -p /var/log/seederlinux

# ============================================================
# 1. Script principal /usr/local/bin/seeder-sync
# ============================================================
echo ">>> Criando /usr/local/bin/seeder-sync..."

cat > /usr/local/bin/seeder-sync <<'SYNCSCRIPT'
#!/bin/bash
# seeder-sync - aplicador idempotente de politicas (GPO-like)
set -u

CONFIG_FILE="/etc/seederlinux/config.env"
SECRETS_FILE="/etc/seederlinux/secrets.env"
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

# Secrets (senhas de proxy). Opcional - pode nao existir em OM sem proxy.
if [ -f "$SECRETS_FILE" ]; then
    # shellcheck disable=SC1090
    source "$SECRETS_FILE"
fi

# ============================================================
# HELPERS DE PROXY (multi-proxy)
# ============================================================
PROXY_COUNT="${PROXY_COUNT:-0}"
PROXY_DEFAULT_NAME="${PROXY_DEFAULT_NAME:-}"

# Retorna URL do proxy com user:pass embutido (se houver credencial)
_resolver_proxy_url() {
    local name="$1"
    [ -z "$name" ] && return 1
    [ "$PROXY_COUNT" -lt 1 ] 2>/dev/null && return 1

    local i=1
    while [ "$i" -le "$PROXY_COUNT" ]; do
        local v_name="PROXY_${i}_NAME"
        if [ "${!v_name}" = "$name" ]; then
            local v_url="PROXY_${i}_URL"
            local v_user="PROXY_${i}_USER"
            local v_pass="PROXY_${i}_PASS"
            local url="${!v_url}"
            local user="${!v_user}"
            local pass="${!v_pass}"

            [ -z "$url" ] && return 1
            [ -z "$user" ] && { echo "$url"; return 0; }

            local user_esc="${user//@/%40}"
            user_esc="${user_esc//:/%3A}"
            local pass_esc="${pass//@/%40}"
            pass_esc="${pass_esc//:/%3A}"

            if echo "$url" | grep -qE '^https?://'; then
                echo "$url" | sed -E "s|^(https?://)|\1${user_esc}:${pass_esc}@|"
            else
                echo "http://${user_esc}:${pass_esc}@${url}"
            fi
            return 0
        fi
        i=$((i+1))
    done
    return 1
}

# Retorna host:port (sem scheme, sem user) ou user:pass@host:port
_resolver_proxy_hostport() {
    local name="$1"
    local fmt="${2:-plain}"
    [ -z "$name" ] && return 1
    [ "$PROXY_COUNT" -lt 1 ] 2>/dev/null && return 1

    local i=1
    while [ "$i" -le "$PROXY_COUNT" ]; do
        local v_name="PROXY_${i}_NAME"
        if [ "${!v_name}" = "$name" ]; then
            local v_url="PROXY_${i}_URL"
            local v_user="PROXY_${i}_USER"
            local v_pass="PROXY_${i}_PASS"
            local url="${!v_url}"
            local user="${!v_user}"
            local pass="${!v_pass}"

            [ -z "$url" ] && return 1

            local hostport
            hostport="$(echo "$url" | sed -E 's|^https?://||' | sed 's|/$||')"

            if [ "$fmt" = "plain" ] || [ -z "$user" ]; then
                echo "$hostport"
                return 0
            fi

            local user_esc="${user//@/%40}"
            user_esc="${user_esc//:/%3A}"
            local pass_esc="${pass//@/%40}"
            pass_esc="${pass_esc//:/%3A}"

            echo "${user_esc}:${pass_esc}@${hostport}"
            return 0
        fi
        i=$((i+1))
    done
    return 1
}

# Retorna o PAC_URL ou vazio
_resolver_proxy_pac() {
    local name="$1"
    [ -z "$name" ] && return 1
    [ "$PROXY_COUNT" -lt 1 ] 2>/dev/null && return 1

    local i=1
    while [ "$i" -le "$PROXY_COUNT" ]; do
        local v_name="PROXY_${i}_NAME"
        if [ "${!v_name}" = "$name" ]; then
            local v="PROXY_${i}_PAC_URL"
            echo "${!v}"
            return 0
        fi
        i=$((i+1))
    done
    return 1
}

# NO_PROXY específico do proxy
_resolver_proxy_no_proxy() {
    local name="$1"
    [ -z "$name" ] && return 1
    [ "$PROXY_COUNT" -lt 1 ] 2>/dev/null && return 1

    local i=1
    while [ "$i" -le "$PROXY_COUNT" ]; do
        local v_name="PROXY_${i}_NAME"
        if [ "${!v_name}" = "$name" ]; then
            local v="PROXY_${i}_NO_PROXY"
            echo "${!v}"
            return 0
        fi
        i=$((i+1))
    done
    return 1
}

# Nome efetivo do proxy conforme a policy
_proxy_nome_efetivo() {
    local especifico="$1"
    if [ -n "$especifico" ]; then
        echo "$especifico"
    else
        echo "$PROXY_DEFAULT_NAME"
    fi
}

# NO_PROXY final (base + específico do proxy)
_build_no_proxy() {
    local extra="$1"
    local base="localhost,127.0.0.1"

    if [ -n "${SEEDER_SERVER:-}" ]; then
        local host
        host="$(echo "$SEEDER_SERVER" | sed -E 's|https?://([^/]+).*|\1|')"
        if [ -n "$host" ]; then
            base="${base},${host}"
            local ip
            ip="$(getent hosts "$host" 2>/dev/null | awk '{print $1}' | head -1)"
            [ -n "$ip" ] && base="${base},${ip}"
        fi
    fi
    [ -n "${DOMINIO:-}" ] && base="${base},.${DOMINIO}"
    if [ -n "${DC_IP:-}" ]; then
        case ",$base," in *",$DC_IP,"*) ;; *) base="${base},${DC_IP}" ;; esac
    fi
    if [ -n "${DC_IP_LIST:-}" ]; then
        local dc
        for dc in $(echo "$DC_IP_LIST" | tr ',' ' '); do
            [ -z "$dc" ] && continue
            case ",$base," in *",$dc,"*) ;; *) base="${base},${dc}" ;; esac
        done
    fi
    [ -n "$extra" ] && base="${base},${extra}"
    echo "$base"
}

# ============================================================
# Resolucao de serial
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
    SERVER_SERIAL="$(grep -m1 '^SERIAL_CONFIG=' /etc/seederlinux/server-serial.env 2>/dev/null | cut -d= -f2- | tr -d '"')"
fi

SERIAL_APLICADO_ATUAL="${SERIAL_APLICADO:-0}"

if [ "$FORCE_SYNC" != "true" ] && [ -n "$SERVER_SERIAL" ]; then
    if [ "$SERVER_SERIAL" -le "$SERIAL_APLICADO_ATUAL" ] 2>/dev/null; then
        echo "SERIAL_APLICADO ($SERIAL_APLICADO_ATUAL) ja em dia com servidor ($SERVER_SERIAL). Nada a fazer."
        echo "=== seeder-sync concluido (sem alteracoes): $(date -Is) ==="
        exit 0
    fi
    echo "Serial do servidor ($SERVER_SERIAL) > aplicado ($SERIAL_APLICADO_ATUAL). Sincronizando..."
elif [ "$FORCE_SYNC" = "true" ]; then
    echo "Execucao forcada (timer) - reaplicando tudo."
else
    echo "Nenhum serial disponivel - reaplicando por seguranca."
fi

# ============================================================
# Deteccao de ambiente
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

detectar_dm() {
    if systemctl is-active --quiet lightdm 2>/dev/null; then echo "lightdm"
    elif systemctl is-active --quiet gdm3 2>/dev/null; then echo "gdm3"
    elif systemctl is-active --quiet sddm 2>/dev/null; then echo "sddm"
    elif [ -f /etc/X11/default-display-manager ]; then
        basename "$(cat /etc/X11/default-display-manager)"
    else echo "unknown"
    fi
}
[ -z "${DISPLAY_MANAGER:-}" ] && DISPLAY_MANAGER="$(detectar_dm)"

usuarios_com_sessao_grafica() {
    loginctl list-sessions --no-legend 2>/dev/null | awk '{print $3}' | grep -v '^root$' | sort -u
}

# Helper: prefixar URL relativa com SEEDER_SERVER
_prefixar_seeder_url() {
    local url="$1"
    [ -z "$url" ] && { echo ""; return; }
    echo "$url" | grep -qE '^https?://[^/]+/' && { echo "$url"; return; }
    [ -z "${SEEDER_SERVER:-}" ] && { echo "$url"; return; }
    local server_clean="${SEEDER_SERVER%/}"
    if echo "$url" | grep -q '^/'; then
        echo "${server_clean}${url}"
    else
        echo "${server_clean}/${url}"
    fi
}

_json_get() {
    local json="$1" key="$2" default="$3" val
    val=$(echo "$json" | jq -r "if has(\"${key}\") then .${key} else \"\" end" 2>/dev/null)
    if [ -z "$val" ] || [ "$val" = "null" ] || [ "$val" = "" ]; then
        echo "$default"
    else
        echo "$val"
    fi
}

# ============================================================
# MODULO: proxy de CLI
# ============================================================
sync_cli_proxy() {
    echo "--- proxy CLI ---"
    local policy="${CLI_POLICY:-DIRECT}"

    case "$policy" in
        DIRECT|"")
            if [ -f /etc/environment ]; then
                sed -i '/^http_proxy=/d;/^https_proxy=/d;/^ftp_proxy=/d;/^no_proxy=/d' /etc/environment 2>/dev/null || true
                sed -i '/^HTTP_PROXY=/d;/^HTTPS_PROXY=/d;/^FTP_PROXY=/d;/^NO_PROXY=/d' /etc/environment 2>/dev/null || true
                sed -i '/^all_proxy=/d;/^ALL_PROXY=/d' /etc/environment 2>/dev/null || true
                sed -i '/^# Proxy configurado por SeederLinux/d' /etc/environment 2>/dev/null || true
            fi
            echo "OK: /etc/environment sem proxy (DIRECT)"
            ;;
        PROXY|PROXY_NO_AUTH|PROXY_WITH_AUTH)
            local nome
            nome="$(_proxy_nome_efetivo "${CLI_PROXY_NAME:-}")"
            if [ -z "$nome" ]; then
                echo "AVISO: CLI_POLICY=$policy sem proxy configurado - mantendo DIRECT"
                return 0
            fi
            local url
            url="$(_resolver_proxy_url "$nome")" || url=""
            if [ -z "$url" ]; then
                echo "AVISO: proxy '$nome' nao encontrado - mantendo DIRECT"
                return 0
            fi
            local no_proxy_extra no_proxy_final
            no_proxy_extra="$(_resolver_proxy_no_proxy "$nome")" || no_proxy_extra=""
            no_proxy_final="$(_build_no_proxy "$no_proxy_extra")"

            touch /etc/environment
            sed -i '/^http_proxy=/d;/^https_proxy=/d;/^ftp_proxy=/d;/^no_proxy=/d' /etc/environment 2>/dev/null || true
            sed -i '/^HTTP_PROXY=/d;/^HTTPS_PROXY=/d;/^FTP_PROXY=/d;/^NO_PROXY=/d' /etc/environment 2>/dev/null || true
            sed -i '/^all_proxy=/d;/^ALL_PROXY=/d' /etc/environment 2>/dev/null || true
            sed -i '/^# Proxy configurado por SeederLinux/d' /etc/environment 2>/dev/null || true
            {
                echo ""
                echo "# Proxy configurado por SeederLinux (seeder-sync)"
                echo "http_proxy=\"${url}\""
                echo "https_proxy=\"${url}\""
                echo "ftp_proxy=\"${url}\""
                echo "HTTP_PROXY=\"${url}\""
                echo "HTTPS_PROXY=\"${url}\""
                echo "FTP_PROXY=\"${url}\""
                echo "no_proxy=\"${no_proxy_final}\""
                echo "NO_PROXY=\"${no_proxy_final}\""
            } >> /etc/environment
            chmod 644 /etc/environment
            echo "OK: /etc/environment atualizado (proxy: $nome)"
            ;;
        PAC)
            echo "AVISO: PAC nao suportado em CLI (wget/curl/git) - mantendo DIRECT"
            ;;
    esac
}

# ============================================================
# MODULO: politica do Firefox (com proxy)
# ============================================================
sync_firefox_policy() {
    echo "--- firefox policy ---"
    command -v firefox-esr &>/dev/null || command -v firefox &>/dev/null || { echo "Firefox nao instalado, pulando"; return 0; }

    local policy="${BROWSER_POLICY:-DIRECT}"
    local ff_proxy_json=''

    case "$policy" in
        DIRECT|"")
            ff_proxy_json='"Proxy": { "Mode": "none", "Locked": true }'
            ;;
        SYSTEM)
            ff_proxy_json='"Proxy": { "Mode": "system", "Locked": true }'
            ;;
        PROXY|PROXY_NO_AUTH|PROXY_WITH_AUTH)
            local nome hostport no_proxy_extra no_proxy_final
            nome="$(_proxy_nome_efetivo "${BROWSER_PROXY_NAME:-}")"
            hostport="$(_resolver_proxy_hostport "$nome" plain)" || hostport=""
            if [ -z "$hostport" ]; then
                ff_proxy_json='"Proxy": { "Mode": "none", "Locked": true }'
                echo "AVISO: proxy '$nome' nao encontrado - Firefox em DIRECT"
            else
                no_proxy_extra="$(_resolver_proxy_no_proxy "$nome")" || no_proxy_extra=""
                no_proxy_final="$(_build_no_proxy "$no_proxy_extra")"
                ff_proxy_json="\"Proxy\": {
      \"Mode\": \"manual\",
      \"HTTPProxy\": \"${hostport}\",
      \"SSLProxy\": \"${hostport}\",
      \"Passthrough\": \"${no_proxy_final}\",
      \"Locked\": true
    }"
            fi
            ;;
        PAC)
            local nome pac
            nome="$(_proxy_nome_efetivo "${BROWSER_PROXY_NAME:-}")"
            pac="$(_resolver_proxy_pac "$nome")" || pac=""
            if [ -z "$pac" ]; then
                ff_proxy_json='"Proxy": { "Mode": "none", "Locked": true }'
                echo "AVISO: PAC_URL vazio - Firefox em DIRECT"
            else
                ff_proxy_json="\"Proxy\": {
      \"Mode\": \"autoConfig\",
      \"AutoConfigURL\": \"${pac}\",
      \"Locked\": true
    }"
            fi
            ;;
        *)
            ff_proxy_json='"Proxy": { "Mode": "none", "Locked": true }'
            ;;
    esac

    local json
    read -r -d '' json <<EOF || true
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
    ${ff_proxy_json},
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

    for DIR in /usr/lib/firefox-esr /usr/lib/firefox; do
        [ -d "$DIR" ] || continue
        mkdir -p "$DIR/distribution"
        echo "$json" > "$DIR/distribution/policies.json"
    done
    for DIR in /etc/firefox/policies /etc/firefox-esr/policies; do
        PARENT="$(dirname "$DIR")"
        [ -d "$PARENT" ] || continue
        mkdir -p "$DIR"
        echo "$json" > "$DIR/policies.json"
    done
    echo "OK: Firefox policy aplicada (modo: $policy)"
}

# ============================================================
# MODULO: politica do Chrome/Chromium (com proxy)
# ============================================================
sync_chrome_policy() {
    echo "--- chrome/chromium policy ---"
    local policy="${BROWSER_POLICY:-DIRECT}"
    local proxy_json=", \"ProxyMode\": \"direct\""

    case "$policy" in
        DIRECT|"")
            proxy_json=", \"ProxyMode\": \"direct\""
            ;;
        SYSTEM)
            proxy_json=", \"ProxyMode\": \"system\""
            ;;
        PROXY|PROXY_NO_AUTH|PROXY_WITH_AUTH)
            local nome authport no_proxy_extra no_proxy_final
            nome="$(_proxy_nome_efetivo "${BROWSER_PROXY_NAME:-}")"
            authport="$(_resolver_proxy_hostport "$nome" auth)" || authport=""
            if [ -z "$authport" ]; then
                proxy_json=", \"ProxyMode\": \"direct\""
                echo "AVISO: proxy '$nome' nao encontrado - Chrome em DIRECT"
            else
                no_proxy_extra="$(_resolver_proxy_no_proxy "$nome")" || no_proxy_extra=""
                no_proxy_final="$(_build_no_proxy "$no_proxy_extra")"
                proxy_json=", \"ProxyMode\": \"fixed_servers\", \"ProxyServer\": \"http=${authport};https=${authport}\", \"ProxyBypassList\": \"${no_proxy_final}\""
            fi
            ;;
        PAC)
            local nome pac
            nome="$(_proxy_nome_efetivo "${BROWSER_PROXY_NAME:-}")"
            pac="$(_resolver_proxy_pac "$nome")" || pac=""
            if [ -z "$pac" ]; then
                proxy_json=", \"ProxyMode\": \"direct\""
                echo "AVISO: PAC_URL vazio - Chrome em DIRECT"
            else
                proxy_json=", \"ProxyMode\": \"pac_script\", \"ProxyPacUrl\": \"${pac}\""
            fi
            ;;
    esac

    local json
    read -r -d '' json <<EOF || true
{
    "HomepageLocation": "${HOMEPAGE:-}",
    "HomepageIsNewTabPage": false,
    "RestoreOnStartup": 1,
    "RestoreOnStartupURLs": ["${HOMEPAGE:-}"],
    "BrowserSignin": 0,
    "SyncDisabled": true,
    "BlockThirdPartyCookies": true,
    "BackgroundModeEnabled": false,
    "TelemetryReportingEnabled": false${proxy_json},
    "DefaultCookiesSetting": 1,
    "DefaultBrowserSettingEnabled": false
}
EOF

    for DIR in /etc/opt/chrome/policies/managed \
               /etc/chromium/policies/managed \
               /etc/chromium-browser/policies/managed; do
        GRANDPARENT="$(dirname "$(dirname "$DIR")")"
        [ -d "$GRANDPARENT" ] || continue
        mkdir -p "$DIR"
        echo "$json" > "$DIR/seederlinux.json"
        chmod 644 "$DIR/seederlinux.json"
    done
    echo "OK: Chrome/Chromium policy aplicada (modo: $policy)"
}

# ============================================================
# MODULO: branding (inalterado)
# ============================================================
sync_branding() {
    echo "--- branding ---"
    mkdir -p /usr/share/backgrounds/seederlinux /usr/share/pixmaps
    chmod 0755 /usr/share/backgrounds/seederlinux /usr/share/pixmaps

    _baixar_ativo() {
        local url
        url="$(_prefixar_seeder_url "$1")"
        local dest="$2"
        local tmp
        tmp="$(mktemp /tmp/seeder-asset.XXXXXX)"

        if ! wget -q --no-check-certificate --no-proxy --timeout=20 -O "$tmp" "$url"; then
            rm -f "$tmp"
            echo "AVISO: falha de download de $(basename "$dest") ($url)"
            return 1
        fi
        if [ ! -s "$tmp" ]; then
            rm -f "$tmp"
            echo "AVISO: $(basename "$dest") baixou 0 bytes"
            return 1
        fi
        local mime
        mime="$(file -b --mime-type "$tmp" 2>/dev/null || echo "application/octet-stream")"
        if ! echo "$mime" | grep -q '^image/'; then
            rm -f "$tmp"
            echo "AVISO: $(basename "$dest") baixou $mime (nao imagem)"
            return 1
        fi
        install -m 0644 "$tmp" "$dest"
        rm -f "$tmp"
        echo "OK: $(basename "$dest") ($mime)"
    }

    [ -n "${WALLPAPER_URL:-}" ] && _baixar_ativo "$WALLPAPER_URL" /usr/share/backgrounds/seederlinux/wallpaper.jpg
    [ -n "${WALLPAPER_LOGIN_URL:-}" ] && _baixar_ativo "$WALLPAPER_LOGIN_URL" /usr/share/backgrounds/seederlinux/wallpaper-login.jpg
    [ -n "${LOGO_URL:-}" ] && _baixar_ativo "$LOGO_URL" /usr/share/pixmaps/seederlinux-logo.png

    local LOGIN_WP="/usr/share/backgrounds/seederlinux/wallpaper-login.jpg"
    local SESSION_WP="/usr/share/backgrounds/seederlinux/wallpaper.jpg"
    if [ ! -s "$LOGIN_WP" ] && [ -s "$SESSION_WP" ]; then
        install -m 0644 "$SESSION_WP" "$LOGIN_WP"
    fi

    local THEME_APLICAR=false
    if [ -n "${THEME:-}" ] && [ "${THEME}" != "DEFAULT" ] && [ -d "/usr/share/themes/${THEME}" ]; then
        THEME_APLICAR=true
    fi

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
            [ "$THEME_APLICAR" = "true" ] && cat >> /etc/dconf/db/local.d/seederlinux-branding-cinnamon <<EOF

[org/cinnamon/desktop/interface]
gtk-theme='${THEME}'
icon-theme-name='Adwaita'

[org/cinnamon/theme]
name='${THEME}'
EOF
            dconf update 2>/dev/null || true
            ;;
        mate)
            cat > /etc/dconf/db/local.d/seederlinux-branding-mate <<EOF
[org/mate/desktop/background]
picture-filename='/usr/share/backgrounds/seederlinux/wallpaper.jpg'
picture-options='zoom'
EOF
            dconf update 2>/dev/null || true
            ;;
        gnome)
            cat > /etc/dconf/db/local.d/seederlinux-branding-gnome <<EOF
[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/seederlinux/wallpaper.jpg'
picture-uri-dark='file:///usr/share/backgrounds/seederlinux/wallpaper.jpg'
picture-options='zoom'

[org/gnome/login-screen]
logo='/usr/share/pixmaps/seederlinux-logo.png'
EOF
            dconf update 2>/dev/null || true
            ;;
    esac

    case "$DISPLAY_MANAGER" in
        lightdm)
            if [ -s "$LOGIN_WP" ]; then
                mkdir -p /etc/lightdm
                cat > /etc/lightdm/lightdm-gtk-greeter.conf <<EOF
[greeter]
background=${LOGIN_WP}
logo=/usr/share/pixmaps/seederlinux-logo.png
icon-theme-name=Adwaita
font-name=DejaVu Sans 10
EOF
                chmod 0644 /etc/lightdm/lightdm-gtk-greeter.conf
            fi
            ;;
        gdm3)
            if [ -s "$LOGIN_WP" ]; then
                mkdir -p /etc/dconf/db/gdm.d
                cat > /etc/dconf/db/gdm.d/01-seederlinux-background <<EOF
[org/gnome/desktop/background]
picture-uri='file://${LOGIN_WP}'
picture-options='zoom'
EOF
                dconf update 2>/dev/null || true
            fi
            ;;
    esac
}

# ============================================================
# MODULO: impressoras (inalterado)
# ============================================================
sync_printers() {
    echo "--- impressoras ---"
    [ -z "${PRINT_SERVER:-}" ] && { echo "PRINT_SERVER vazio, pulando"; return 0; }
    command -v cupsctl &>/dev/null || { echo "CUPS nao instalado, pulando"; return 0; }

    systemctl enable cups 2>/dev/null || true
    systemctl start cups 2>/dev/null || true
    cupsctl --remote-admin --remote-any --share-printers 2>/dev/null || true

    cat > /etc/cups/client.conf <<EOF
# Cliente CUPS - SeederLinux
ServerName ${PRINT_SERVER}
EOF

    if [ -n "${PRINTERS:-}" ]; then
        for PRINTER in $PRINTERS; do
            if ! lpstat -p "$PRINTER" &>/dev/null; then
                lpadmin -p "$PRINTER" -E -v "ipp://${PRINT_SERVER}/printers/${PRINTER}" \
                    -m everywhere 2>/dev/null || echo "AVISO: falha fila '$PRINTER'"
            fi
        done
    fi

    [ -n "${DEFAULT_PRINTER:-}" ] && lpadmin -d "$DEFAULT_PRINTER" 2>/dev/null || true
    systemctl restart cups 2>/dev/null || true
}

# ============================================================
# MODULO: Conky (inalterado)
# ============================================================
sync_conky() {
    echo "--- conky ---"
    command -v conky &>/dev/null || return 0
    command -v jq &>/dev/null || return 0
    [ -z "${CONKY_CONFIG:-}" ] && return 0

    case "$DESKTOP_ENV" in
        cinnamon|mate|gnome|xfce|kde|lxde|lxqt) ;;
        *) return 0 ;;
    esac

    local CFG_POSITION CFG_TRANSPARENT CFG_COLOR_TEXT CFG_COLOR_BG
    local CFG_FONT_SIZE CFG_GAP_X CFG_GAP_Y CFG_UPDATE_INTERVAL
    local CFG_SHOW_CPU CFG_SHOW_RAM CFG_SHOW_DISK CFG_DISK_PARTITION
    local CFG_SHOW_NETWORK CFG_NETWORK_IFACE CFG_SHOW_TOP
    local CFG_SHOW_DATETIME CFG_SHOW_HOSTNAME CFG_HOSTNAME_FONT_SIZE

    CFG_POSITION="$(_json_get "$CONKY_CONFIG" position "top_right")"
    CFG_TRANSPARENT="$(_json_get "$CONKY_CONFIG" transparent "true")"
    CFG_COLOR_TEXT="$(_json_get "$CONKY_CONFIG" color_text "#FFFFFF")"
    CFG_COLOR_BG="$(_json_get "$CONKY_CONFIG" color_bg "#000000")"
    CFG_FONT_SIZE="$(_json_get "$CONKY_CONFIG" font_size "10")"
    CFG_GAP_X="$(_json_get "$CONKY_CONFIG" gap_x "10")"
    CFG_GAP_Y="$(_json_get "$CONKY_CONFIG" gap_y "40")"
    CFG_UPDATE_INTERVAL="$(_json_get "$CONKY_CONFIG" update_interval "1.0")"
    CFG_SHOW_CPU="$(_json_get "$CONKY_CONFIG" show_cpu "true")"
    CFG_SHOW_RAM="$(_json_get "$CONKY_CONFIG" show_ram "true")"
    CFG_SHOW_DISK="$(_json_get "$CONKY_CONFIG" show_disk "true")"
    CFG_DISK_PARTITION="$(_json_get "$CONKY_CONFIG" disk_partition "/")"
    CFG_SHOW_NETWORK="$(_json_get "$CONKY_CONFIG" show_network "true")"
    CFG_NETWORK_IFACE="$(_json_get "$CONKY_CONFIG" network_interface "eth0")"
    CFG_SHOW_TOP="$(_json_get "$CONKY_CONFIG" show_top_processes "true")"
    CFG_SHOW_DATETIME="$(_json_get "$CONKY_CONFIG" show_datetime "true")"
    CFG_SHOW_HOSTNAME="$(_json_get "$CONKY_CONFIG" show_hostname "true")"
    CFG_HOSTNAME_FONT_SIZE="$(_json_get "$CONKY_CONFIG" font_size_hostname "14")"

    local COLOR_TEXT_LUA="${CFG_COLOR_TEXT#\#}"
    local COLOR_BG_LUA="${CFG_COLOR_BG#\#}"
    local OWN_TRANSPARENT OWN_ARGB_VALUE
    if [ "$CFG_TRANSPARENT" = "true" ]; then
        OWN_TRANSPARENT="true"; OWN_ARGB_VALUE="0"
    else
        OWN_TRANSPARENT="false"; OWN_ARGB_VALUE="200"
    fi

    local CONKY_DIR="/etc/seederlinux/conky"
    local CONKY_CONF="$CONKY_DIR/conky.conf"
    local NEW_CONF
    NEW_CONF="$(mktemp /tmp/seeder-conky.XXXXXX)"

    cat > "$NEW_CONF" <<EOF
-- Configuracao Conky - SeederLinux
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
\${color ${COLOR_TEXT_LUA}}${OM_ACRONYM:-} - ${OM_NAME:-}
\${color ${COLOR_TEXT_LUA}}\${hr}
\${color ${COLOR_TEXT_LUA}}Uptime: \${color grey}\${uptime}
]]
EOF

    mkdir -p "$CONKY_DIR"
    local CONF_CHANGED=false
    if [ ! -f "$CONKY_CONF" ] || ! cmp -s "$NEW_CONF" "$CONKY_CONF"; then
        install -m 0644 "$NEW_CONF" "$CONKY_CONF"
        CONF_CHANGED=true
        echo "OK: conky.conf regravado"
    else
        echo "OK: conky.conf em dia"
    fi
    rm -f "$NEW_CONF"

    install -m 0755 /dev/stdin /usr/local/bin/seederlinux-conky <<'LAUNCHER'
#!/bin/bash
CONKY_CONF="/etc/seederlinux/conky/conky.conf"
sleep 3
if [ -f "$CONKY_CONF" ]; then
    killall conky 2>/dev/null || true
    conky -c "$CONKY_CONF" &
fi
LAUNCHER

    local u
    for u in $(usuarios_com_sessao_grafica); do
        if [ "$CONF_CHANGED" = "true" ]; then
            su - "$u" -c "pkill -u '$u' conky 2>/dev/null; sleep 1; DISPLAY=:0 /usr/local/bin/seederlinux-conky" 2>/dev/null &
            echo "OK: conky reiniciado para $u"
        else
            pgrep -u "$u" conky &>/dev/null || \
                su - "$u" -c "DISPLAY=:0 /usr/local/bin/seederlinux-conky" 2>/dev/null &
        fi
    done
}

# ============================================================
# MODULO: compartilhamentos (inalterado)
# ============================================================
sync_shares() {
    echo "--- compartilhamentos ---"
    [ -z "${SERVIDOR_ARQUIVOS:-}" ] && return 0
    [ -z "${COMPARTILHAMENTOS:-}" ] && return 0
    local MOUNT_DIR="${MOUNT_BASE:-/mnt}"
    local u
    for u in $(usuarios_com_sessao_grafica); do
        local uid gid
        uid="$(id -u "$u" 2>/dev/null)" || continue
        gid="$(id -g "$u" 2>/dev/null)" || continue
        local SHARE
        for SHARE in $COMPARTILHAMENTOS; do
            local SHARE_MOUNT="${MOUNT_DIR}/${SHARE}"
            mkdir -p "$SHARE_MOUNT"
            mountpoint -q "$SHARE_MOUNT" 2>/dev/null && continue
            mount -t cifs "//${SERVIDOR_ARQUIVOS}/${SHARE}" "$SHARE_MOUNT" \
                -o "username=${u},domain=${DOMINIO_NETBIOS:-},uid=${uid},gid=${gid},iocharset=utf8,vers=3.0" \
                2>/dev/null || echo "AVISO: falha remontar ${SHARE} para ${u}"
        done
    done
}

# ============================================================
# MODULO: certificados (inalterado)
# ============================================================
sync_certificates() {
    echo "--- certificados ---"
    [ "${CERTIFICATE_AUTO_INSTALL:-}" = "true" ] || return 0
    [ -z "${CERTIFICATE_BUNDLE:-}" ] && return 0

    local CERT_URL
    CERT_URL="$(_prefixar_seeder_url "$CERTIFICATE_BUNDLE")"

    local CERT_TMP="/tmp/seederlinux-cert-bundle"
    local CERT_DEST_DIR="/usr/local/share/ca-certificates/seederlinux"
    mkdir -p "$CERT_DEST_DIR"

    if ! wget -q --no-check-certificate --timeout=20 -O "$CERT_TMP" "$CERT_URL" 2>/dev/null; then
        echo "AVISO: falha baixar CERTIFICATE_BUNDLE"
        return 0
    fi
    [ ! -s "$CERT_TMP" ] && { rm -f "$CERT_TMP"; return 0; }

    local FILETYPE
    FILETYPE="$(file -b "$CERT_TMP" 2>/dev/null)"
    case "$FILETYPE" in
        *gzip*|*tar*)
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
    update-ca-certificates 2>/dev/null || true
}

# ============================================================
# Execucao
# ============================================================
sync_branding
sync_firefox_policy
sync_chrome_policy
sync_cli_proxy
sync_printers
sync_conky
sync_shares
sync_certificates

# ============================================================
# Atualizar SERIAL_APLICADO
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
# 2. Units systemd
# ============================================================
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
systemctl start seeder-sync.service 2>/dev/null || true

echo ">>> [19] seeder-sync instalado e timer ativo (10min)"
echo "============================================================"
