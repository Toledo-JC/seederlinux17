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
#   PROXY           -> via proxy (host:port, sem credencial embutida)
#   PROXY_NO_AUTH   -> alias legado de PROXY (retrocompatibilidade)
#   PROXY_WITH_AUTH -> alias legado de PROXY (retrocompatibilidade)
#   PAC             -> via PAC
#   SYSTEM          -> herda proxy do sistema (libproxy)
#
# IMPORTANTE — BROWSER NUNCA RECEBE CREDENCIAL DE PROXY
# ====================================================
# A autenticação de proxy para navegadores é SEMPRE do usuário, não da
# estação. Isso vale para os 3 mecanismos possíveis:
#
#   1. Popup interativo: o browser exibe um diálogo pedindo user/senha
#      na primeira navegação. O usuário digita, o browser guarda no
#      keyring do usuário. Nada disso passa pelo bundle.
#
#   2. SSO/Kerberos: o proxy aceita Negociate/NTLM usando o ticket
#      Kerberos da sessão do usuário (que existe porque a estação
#      está ingressada no AD). Nada a configurar.
#
#   3. Proxy transparente: o proxy não pede auth, o browser só usa.
#
# Por isso NUNCA embutimos user:pass na URL do proxy configurada no
# navegador. Duas razões técnicas, além da conceitual:
#
#   - Chrome/Chromium: o campo "ProxyServer" da policy aceita apenas
#     o formato "scheme=host:port". Se vier com user:pass@, o Chrome
#     IGNORA a policy de proxy (bug silencioso — o browser fica sem
#     proxy sem avisar).
#
#   - Firefox: o enterprise policy "Proxy.HTTPProxy" aceita
#     user:pass@host:port na sintaxe, mas expõe a credencial no
#     arquivo /usr/lib/firefox-esr/distribution/policies.json (modo
#     644, legível por qualquer usuário). Além de inseguro, se o
#     operador trocar a senha dele, o arquivo fica desatualizado
#     silenciosamente. O Firefox também pede a senha no primeiro
#     acesso se o proxy exigir Basic auth — comportamento melhor
#     que credencial estática.
#
# CONCLUSÃO: browser recebe apenas host:port + lista de exceções.
# Credenciais para APT/CLI continuam no cadastro do proxy, mas o
# core_browser.sh as ignora completamente.
#
# MÚLTIPLOS PROXIES:
#   BROWSER_PROXY_NAME aponta para um dos proxies nomeados da OM; se
#   vazio, usa PROXY_DEFAULT_NAME.
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
echo ">>> Proxies cadastrados: $PROXY_COUNT"

# ============================================================
# Helper: resolver proxy por nome -> host:port (SEMPRE sem credencial)
# ============================================================
# Uso neste script: SOMENTE formato "plain" (host:port).
# A variante "auth" existe em outros scripts (core_proxy.sh,
# core_repositories.sh) para APT/CLI, que precisam de user:pass
# quando o proxy exige auth estática. Aqui NÃO.
#
# Retorna vazio se o proxy não existir, ou se a URL for inválida.
_resolver_proxy_hostport() {
    local name="$1"
    [ -z "$name" ] && return 1
    [ "$PROXY_COUNT" -lt 1 ] 2>/dev/null && return 1

    local i=1
    while [ "$i" -le "$PROXY_COUNT" ]; do
        local v_name="PROXY_${i}_NAME"
        if [ "${!v_name}" = "$name" ]; then
            local v_url="PROXY_${i}_URL"
            local url="${!v_url}"
            [ -z "$url" ] && return 1

            # Extrai só host:port — remove http:// ou https:// e barra
            # final. Ignora PROXY_${i}_USER e PROXY_${i}_PASS_B64 de
            # propósito (ver cabeçalho para o motivo).
            echo "$url" | sed -E 's|^https?://||' | sed 's|/$||'
            return 0
        fi
        i=$((i+1))
    done
    return 1
}

# ============================================================
# Helper: retorna o PAC_URL do proxy nomeado (usado se policy=PAC)
# ============================================================
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

# ============================================================
# Helper: NO_PROXY específico de um proxy
# ============================================================
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

# ============================================================
# Helper: montar lista de exceções (Passthrough / ProxyBypassList)
# ============================================================
# A lista inclui automaticamente:
#   - localhost e 127.0.0.1 (sempre)
#   - hostname e IP do SEEDER_SERVER (DNS resolvido em runtime)
#   - o domínio AD (sufixo .dominio — Firefox e Chrome aceitam)
#   - DC principal e todos os DCs adicionais
#   - o no_proxy específico do proxy escolhido (se houver)
#
# Formato: lista separada por vírgula. Firefox e Chrome aceitam
# hostname, IP, CIDR e sufixo .dominio.
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

# ============================================================
# Helper: nome efetivo do proxy conforme a policy
# ============================================================
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
# Estados possíveis:
#   FF_PROXY_MODE    / CHROME_PROXY_MODE
#     none           / direct
#     manual         / fixed_servers
#     autoConfig     / pac_script
#     system         / system
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

    # PROXY, PROXY_NO_AUTH e PROXY_WITH_AUTH fazem a mesma coisa para
    # browser: aplicam o proxy sem credencial. Os nomes "NO_AUTH" e
    # "WITH_AUTH" são legados do modelo single-proxy e não têm mais
    # significado distinto para navegadores.
    PROXY|PROXY_NO_AUTH|PROXY_WITH_AUTH)
        NOME="$(_resolver_proxy_nome_efetivo)"
        HOSTPORT="$(_resolver_proxy_hostport "$NOME")" || HOSTPORT=""
        if [ -z "$HOSTPORT" ]; then
            echo ">>> AVISO: BROWSER_POLICY=$BROWSER_POLICY mas proxy '${NOME:-<nenhum>}' nao encontrado."
            echo ">>>        Aplicando DIRECT para os navegadores."
            FF_PROXY_MODE="none"
            CHROME_PROXY_MODE="direct"
        else
            FF_NO_PROXY="$(_build_no_proxy_browser "$(_resolver_proxy_no_proxy "$NOME" || echo "")")"
            CHROME_NO_PROXY="$FF_NO_PROXY"

            # --- Firefox: manual com host:port e passthrough ---
            FF_PROXY_MODE="manual"
            FF_PROXY_HTTP="$HOSTPORT"
            FF_PROXY_SSL="$HOSTPORT"

            # --- Chrome: fixed_servers com host:port e bypass list ---
            # Formato OBRIGATÓRIO: "scheme=host:port;scheme=host:port".
            # Se vier user:pass@, o Chrome ignora a policy.
            CHROME_PROXY_MODE="fixed_servers"
            CHROME_PROXY_SERVER="http=${HOSTPORT};https=${HOSTPORT}"

            echo ">>> Proxy aplicado aos navegadores: $HOSTPORT"
            echo ">>> Autenticacao de proxy sera feita pelo usuario (popup ou SSO)."
        fi
        ;;

    PAC)
        NOME="$(_resolver_proxy_nome_efetivo)"
        PAC_URL="$(_resolver_proxy_pac "$NOME")" || PAC_URL=""
        if [ -z "$PAC_URL" ]; then
            echo ">>> AVISO: BROWSER_POLICY=PAC mas PAC_URL vazio para o proxy '${NOME:-<nenhum>}'."
            echo ">>>        Aplicando DIRECT para os navegadores."
            FF_PROXY_MODE="none"
            CHROME_PROXY_MODE="direct"
        else
            FF_PROXY_MODE="autoConfig"
            FF_PROXY_PAC="$PAC_URL"
            FF_NO_PROXY="$(_build_no_proxy_browser "$(_resolver_proxy_no_proxy "$NOME" || echo "")")"
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

# Caminho canônico Debian (firefox-esr) e fallback Ubuntu (firefox).
# Copia para os dois se ambos existirem — em instalações mistas.
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

echo ">>> Firefox configurado (policy de proxy: $FF_PROXY_MODE)"

# ============================================================
# Chrome / Chromium
# ============================================================
echo ">>> Configurando politicas do Chrome/Chromium..."

case "$CHROME_PROXY_MODE" in
    fixed_servers)
        # Formato: "scheme=host:port;scheme=host:port"
        # SEM user:pass@ — o Chrome não aceita e ignora a policy.
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

echo ">>> Chrome/Chromium configurado (policy de proxy: $CHROME_PROXY_MODE)"

echo ">>> [06] Politicas de navegadores configuradas!"
echo "============================================================"
