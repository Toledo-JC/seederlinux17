#!/bin/bash
# ============================================================================
# Core Script: core_browser.sh
# SeederLinux Lite - Políticas de navegadores (Firefox, Chrome, Chromium)
# ============================================================================
# Configura políticas corporativas para Firefox ESR, Google Chrome e
# Chromium, incluindo homepage, proxy, certificados e telemetria.
#
# POLÍTICAS SUPORTADAS (BROWSER_POLICY):
#   DIRECT          -> sem proxy (default)
#   PROXY_NO_AUTH   -> via proxy sem autenticação
#   PROXY_WITH_AUTH -> via proxy com user/senha (Chrome aceita user:pass
#                      embutido; Firefox NÃO - ver limitação abaixo)
#   PAC             -> via PAC (suportado por ambos)
#   SYSTEM          -> herda proxy do sistema (libproxy)
#
# MÚLTIPLOS PROXIES:
#   BROWSER_PROXY_NAME aponta para um dos proxies nomeados da OM; se
#   vazio, usa PROXY_DEFAULT_NAME.
#
# LIMITAÇÃO CONHECIDA - Firefox + proxy autenticado:
#   O enterprise policy "Proxy" do Firefox NÃO aceita credenciais
#   embutidas na URL (HTTPProxy=user:pass@host NÃO funciona). Se o
#   proxy exigir Basic auth, o Firefox vai pedir a senha no primeiro
#   acesso (comportamento esperado, sem alternativa limpa). Para NTLM/
#   Kerberos, use BROWSER_POLICY=SYSTEM (herda do SO).
#   Já o Chrome/Chromium aceitam "http=user:pass@host:port" direto no
#   JSON de política, então essa limitação não os afeta.
#
# Os placeholders VARIAVEL são substituídos automaticamente
# pelo sistema na geração do bundle.
# ============================================================================

set -e

echo "============================================================"
echo "06 - Configurar politicas de navegadores"
echo "============================================================"

# ============================================================
# Variáveis (substituídas no bundle)
# ============================================================
HOMEPAGE="{{HOMEPAGE}}"
BROWSER_POLICY="{{BROWSER_POLICY}}"
BROWSER_PROXY_NAME="{{BROWSER_PROXY_NAME}}"
DOMINIO="{{DOMINIO}}"
OM_ACRONYM="{{OM_ACRONYM}}"
SEEDER_SERVER="{{SEEDER_SERVER}}"
DC_IP="{{DC_IP}}"
DC_IP_LIST="{{DC_IP_LIST}}"

# Múltiplos proxies
PROXY_COUNT="${PROXY_COUNT:-0}"
PROXY_DEFAULT_NAME="${PROXY_DEFAULT_NAME:-}"

# Defaults defensivos
[ -z "$BROWSER_POLICY" ] && BROWSER_POLICY="DIRECT"

echo ">>> Homepage: $HOMEPAGE"
echo ">>> BROWSER_POLICY: $BROWSER_POLICY"
echo ">>> BROWSER_PROXY_NAME: ${BROWSER_PROXY_NAME:-<default>}"

# ============================================================
# Helper: resolver proxy por nome
# ============================================================
# Retorna "HOST_PORT" (sem user:pass, formato do policy Firefox) ou
# "user:pass@host:port" (formato que o Chrome aceita). A função recebe
# o formato desejado como $2.
#
# $2 = "plain"  -> host:port
# $2 = "auth"   -> user:pass@host:port (se houver credencial)
_resolver_proxy() {
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
            local v_pass_b64="PROXY_${i}_PASS_B64"
            local url="${!v_url}"
            local user="${!v_user}"
            local pass_b64="${!v_pass_b64}"

            [ -z "$url" ] && return 1

            # Extrai só o host:port da URL (tira http:// ou https://)
            local hostport
            hostport="$(echo "$url" | sed -E 's|^https?://||' | sed 's|/$||')"

            if [ "$fmt" = "plain" ] || [ -z "$user" ]; then
                echo "$hostport"
                return 0
            fi

            # Formato com auth
            local pass=""
            if [ -n "$pass_b64" ]; then
                pass="$(printf '%s' "$pass_b64" | base64 -d 2>/dev/null)" || pass=""
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

# ============================================================
# Helper: NO_PROXY para browsers
# ============================================================
# Formato aceito por Firefox e Chrome:
#   - hostnames exatos: host1,host2
#   - sufixo de domínio: .dominio.com (Firefox aceita, Chrome aceita)
#   - IPs e CIDR
#
# Monta uma lista com:
#   - sempre localhost, 127.0.0.1
#   - seeder hostname + IP
#   - domínio (.dominio)
#   - DC principal + secundários
#   - no_proxy específico do proxy
_build_no_proxy_browser() {
    local extra="$1"
    local base="localhost,127.0.0.1"

    if [ -n "$SEEDER_SERVER" ]; then
        local host
        host="$(echo "$SEEDER_SERVER" | sed -E 's|https?://([^/]+).*|\1|')"
        if [ -n "$host" ]; then
            base="${base},${host}"
            local ip
            ip="$(getent hosts "$host" 2>/dev/null | awk '{print $1}' | head -1)"
            [ -n "$ip" ] && base="${base},${ip}"
        fi
    fi

    [ -n "$DOMINIO" ] && base="${base},.${DOMINIO}"

    if [ -n "$DC_IP" ]; then
        case ",$base," in
            *",$DC_IP,"*) ;;
            *) base="${base},${DC_IP}" ;;
        esac
    fi

    if [ -n "$DC_IP_LIST" ]; then
        local dc
        for dc in $(echo "$DC_IP_LIST" | tr ',' ' '); do
            [ -z "$dc" ] && continue
            case ",$base," in
                *",$dc,"*) ;;
                *) base="${base},${dc}" ;;
            esac
        done
    fi

    [ -n "$extra" ] && base="${base},${extra}"

    echo "$base"
}

_resolver_proxy_nome_efetivo() {
    if [ -n "$BROWSER_PROXY_NAME" ]; then
        echo "$BROWSER_PROXY_NAME"
    else
        echo "$PROXY_DEFAULT_NAME"
    fi
}

# ============================================================
# Resolver URL de proxy e NO_PROXY conforme a policy
# ============================================================
FF_PROXY_MODE="none"
FF_PROXY_HTTP=""
FF_PROXY_SSL=""
FF_PROXY_PAC=""
FF_NO_PROXY=""
CHROME_PROXY_MODE="direct"
CHROME_PROXY_SERVER=""
CHROME_PROXY_PAC=""
CHROME_NO_PROXY=""

case "$BROWSER_POLICY" in

    DIRECT|"")
        FF_PROXY_MODE="none"
        CHROME_PROXY_MODE="direct"
        ;;

    PROXY_NO_AUTH)
        NOME="$(_resolver_proxy_nome_efetivo)"
        HOSTPORT="$(_resolver_proxy "$NOME" plain)" || HOSTPORT=""
        if [ -z "$HOSTPORT" ]; then
            echo ">>> AVISO: BROWSER_POLICY=$BROWSER_POLICY mas proxy nao encontrado. Aplicando DIRECT."
            FF_PROXY_MODE="none"
            CHROME_PROXY_MODE="direct"
        else
            FF_PROXY_MODE="manual"
            FF_PROXY_HTTP="$HOSTPORT"
            FF_PROXY_SSL="$HOSTPORT"
            CHROME_PROXY_MODE="fixed_servers"
            CHROME_PROXY_SERVER="http=${HOSTPORT};https=${HOSTPORT}"
            FF_NO_PROXY="$(_build_no_proxy_browser "")"
            CHROME_NO_PROXY="$FF_NO_PROXY"
        fi
        ;;

    PROXY_WITH_AUTH)
        NOME="$(_resolver_proxy_nome_efetivo)"
        HOSTPORT="$(_resolver_proxy "$NOME" plain)" || HOSTPORT=""
        AUTHPORT="$(_resolver_proxy "$NOME" auth)" || AUTHPORT=""
        if [ -z "$HOSTPORT" ]; then
            echo ">>> AVISO: BROWSER_POLICY=$BROWSER_POLICY mas proxy nao encontrado. Aplicando DIRECT."
            FF_PROXY_MODE="none"
            CHROME_PROXY_MODE="direct"
        else
            # Firefox: sem credenciais (limitação conhecida - ver topo)
            FF_PROXY_MODE="manual"
            FF_PROXY_HTTP="$HOSTPORT"
            FF_PROXY_SSL="$HOSTPORT"
            # Chrome: com credenciais embutidas (funciona)
            CHROME_PROXY_MODE="fixed_servers"
            CHROME_PROXY_SERVER="http=${AUTHPORT};https=${AUTHPORT}"
            FF_NO_PROXY="$(_build_no_proxy_browser "")"
            CHROME_NO_PROXY="$FF_NO_PROXY"
            echo ">>> AVISO: Firefox nao aceita credencial embutida no policy de proxy."
            echo ">>>        Se o proxy exigir Basic auth, o usuario digitara a senha 1x."
            echo ">>>        Chrome/Chromium receberam as credenciais embutidas."
        fi
        ;;

    PAC)
        NOME="$(_resolver_proxy_nome_efetivo)"
        PAC_URL="$(_resolver_proxy "$NOME" plain)" || PAC_URL=""
        # Fallback: tentar variável PAC_URL do proxy direto
        if [ "$PROXY_COUNT" -ge 1 ]; then
            i=1
            while [ "$i" -le "$PROXY_COUNT" ]; do
                v_name="PROXY_${i}_NAME"
                if [ "${!v_name}" = "$NOME" ]; then
                    v_pac="PROXY_${i}_PAC_URL"
                    PAC_URL="${!v_pac}"
                    break
                fi
                i=$((i+1))
            done
        fi

        if [ -z "$PAC_URL" ]; then
            echo ">>> AVISO: BROWSER_POLICY=PAC mas PAC_URL vazio. Aplicando DIRECT."
            FF_PROXY_MODE="none"
            CHROME_PROXY_MODE="direct"
        else
            FF_PROXY_MODE="autoConfig"
            FF_PROXY_PAC="$PAC_URL"
            CHROME_PROXY_MODE="pac_script"
            CHROME_PROXY_PAC="$PAC_URL"
        fi
        ;;

    SYSTEM)
        FF_PROXY_MODE="system"
        CHROME_PROXY_MODE="system"
        ;;

    *)
        echo ">>> AVISO: BROWSER_POLICY desconhecida '$BROWSER_POLICY'. Aplicando DIRECT."
        FF_PROXY_MODE="none"
        CHROME_PROXY_MODE="direct"
        ;;
esac

# ============================================================
# Montar bloco "Proxy" do policies.json do Firefox
# ============================================================
case "$FF_PROXY_MODE" in
    none)
        FIREFOX_PROXY_JSON='"Proxy": { "Mode": "none", "Locked": true }'
        ;;
    system)
        FIREFOX_PROXY_JSON='"Proxy": { "Mode": "system", "Locked": true }'
        ;;
    manual)
        FIREFOX_PROXY_JSON="\"Proxy\": {
            \"Mode\": \"manual\",
            \"HTTPProxy\": \"${FF_PROXY_HTTP}\",
            \"SSLProxy\": \"${FF_PROXY_SSL}\",
            \"Passthrough\": \"${FF_NO_PROXY}\",
            \"Locked\": true
        }"
        ;;
    autoConfig)
        FIREFOX_PROXY_JSON="\"Proxy\": {
            \"Mode\": \"autoConfig\",
            \"AutoConfigURL\": \"${FF_PROXY_PAC}\",
            \"Passthrough\": \"${FF_NO_PROXY}\",
            \"Locked\": true
        }"
        ;;
esac

# ============================================================
# Firefox ESR - policies.json
# ============================================================
echo ">>> Configurando policies.json do Firefox..."
mkdir -p /usr/lib/firefox-esr/distribution
cat > /usr/lib/firefox-esr/distribution/policies.json <<EOF
{
    "policies": {
        "DisableTelemetry": true,
        "DisableFirefoxStudies": true,
        "DisablePocket": true,
        "DisableDeveloperTools": false,
        "BlockAboutConfig": false,
        "Homepage": {
            "URL": "${HOMEPAGE}",
            "Locked": true,
            "StartPage": "homepage"
        },
        "HomepageURL": "${HOMEPAGE}",
        "SearchBar": "unified",
        "SearchEngines": {
            "Add": [
                { "Name": "${OM_ACRONYM}", "URL": "${HOMEPAGE}", "Method": "GET" }
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

# Caminho canônico Debian (firefox-esr) e fallback Ubuntu (firefox)
for DIR in /usr/lib/firefox-esr /usr/lib/firefox; do
    [ -d "$DIR" ] || continue
    mkdir -p "$DIR/distribution"
    cp /usr/lib/firefox-esr/distribution/policies.json "$DIR/distribution/policies.json" 2>/dev/null || true
done

# Cobertura extra (builds que honram este local alternativo)
for DIR in /etc/firefox/policies /etc/firefox-esr/policies; do
    PARENT="$(dirname "$DIR")"
    [ -d "$PARENT" ] || continue
    mkdir -p "$DIR"
    cp /usr/lib/firefox-esr/distribution/policies.json "$DIR/policies.json" 2>/dev/null || true
done

echo ">>> Firefox configurado (policy: $FF_PROXY_MODE)"

# ============================================================
# Chrome / Chromium
# ============================================================
echo ">>> Configurando politicas do Chrome/Chromium..."

case "$CHROME_PROXY_MODE" in
    fixed_servers)
        CHROME_PROXY_JSON=", \"ProxyMode\": \"fixed_servers\", \"ProxyServer\": \"${CHROME_PROXY_SERVER}\""
        if [ -n "$CHROME_NO_PROXY" ]; then
            CHROME_PROXY_JSON="${CHROME_PROXY_JSON}, \"ProxyBypassList\": \"${CHROME_NO_PROXY}\""
        fi
        ;;
    pac_script)
        CHROME_PROXY_JSON=", \"ProxyMode\": \"pac_script\", \"ProxyPacUrl\": \"${CHROME_PROXY_PAC}\""
        ;;
    direct)
        CHROME_PROXY_JSON=", \"ProxyMode\": \"direct\""
        ;;
    system)
        CHROME_PROXY_JSON=", \"ProxyMode\": \"system\""
        ;;
esac

CHROME_POLICY_JSON=$(cat <<EOF
{
    "HomepageLocation": "${HOMEPAGE}",
    "HomepageIsNewTabPage": false,
    "RestoreOnStartup": 1,
    "RestoreOnStartupURLs": ["${HOMEPAGE}"],
    "BrowserSignin": 0,
    "SyncDisabled": true,
    "BlockThirdPartyCookies": true,
    "BackgroundModeEnabled": false,
    "TelemetryReportingEnabled": false,
    "UrlKeyboardsEnabled": false${CHROME_PROXY_JSON},
    "DefaultCookiesSetting": 1,
    "AutoSelectCertificateForUrls": ["{\"pattern\":\"https://*\",\"filter\":{}}"],
    "ChromeCertProtectorEnabled": false
}
EOF
)

for DIR in /etc/opt/chrome/policies/managed \
           /etc/chromium/policies/managed \
           /etc/chromium-browser/policies/managed; do
    GRANDPARENT="$(dirname "$(dirname "$DIR")")"
    [ -d "$GRANDPARENT" ] || continue
    mkdir -p "$DIR"
    echo "$CHROME_POLICY_JSON" > "$DIR/seederlinux.json"
    chmod 644 "$DIR/seederlinux.json"
done

echo ">>> Chrome/Chromium configurado (policy: $CHROME_PROXY_MODE)"

echo ">>> [06] Politicas de navegadores configuradas!"
echo "============================================================"
