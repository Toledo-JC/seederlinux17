#!/bin/bash
# ============================================================================
# Core Script: core_browser.sh
# SeederLinux Lite - Políticas de navegadores (Firefox, Chrome, Chromium)
# ============================================================================
# LIMITAÇÃO DO CHROMIUM (não é bug do bundle):
# Chrome e Chromium NÃO exibem popup de autenticação quando a
# política de proxy é 'fixed_servers' e o proxy exige Basic auth.
# Eles ignoram silenciosamente a credencial e caem em DIRECT.
#
# Para resolver, é preciso uma extensão Chrome com
# chrome.webRequest.onAuthRequired. Firefox suporta popup nativo
# mas apenas no pacote .deb (o snap ignora policies.json).
#
# Recomendação para as OMs: preferir Firefox .deb + Squid
# transparente, ou aceitar que o usuário precisará de extensão
# no Chrome.
#
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

source /usr/local/lib/seederlinux/diag.sh 2>/dev/null || true
SCRIPT_ID="09-browser"

echo "============================================================"
echo "Configurar politicas de navegadores"
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

log_nivel INFO "Homepage: $HOMEPAGE"
log_nivel INFO "BROWSER_POLICY: $BROWSER_POLICY"
log_nivel INFO "BROWSER_PROXY_NAME: ${BROWSER_PROXY_NAME:-<default>}"
log_nivel INFO "Proxies cadastrados: $PROXY_COUNT"

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

    # Normalizar: painel guarda "a;b; *.dom" — Firefox/Chrome
    # esperam virgula e sem "*".
    base="$(echo "$base" | tr ';' ',' | tr -d ' ')"
    base="$(echo "$base" | sed 's/^\*\././; s/,\*\./,./g')"

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
            log_nivel AVISO "BROWSER_POLICY=$BROWSER_POLICY mas proxy '${NOME:-<nenhum>}' nao encontrado."
            log_nivel INFO "Aplicando DIRECT para os navegadores."
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

            log_nivel INFO "Proxy aplicado aos navegadores: $HOSTPORT"
            log_nivel INFO "Autenticacao de proxy sera feita pelo usuario (popup ou SSO)."
        fi
        ;;

    PAC)
        NOME="$(_resolver_proxy_nome_efetivo)"
        PAC_URL="$(_resolver_proxy_pac "$NOME")" || PAC_URL=""
        if [ -z "$PAC_URL" ]; then
            log_nivel AVISO "BROWSER_POLICY=PAC mas PAC_URL vazio para o proxy '${NOME:-<nenhum>}'."
            log_nivel INFO "Aplicando DIRECT para os navegadores."
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
        log_nivel AVISO "BROWSER_POLICY desconhecida '$BROWSER_POLICY'. Aplicando DIRECT."
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
log_nivel INFO "Configurando policies.json do Firefox..."
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

if [ -d /opt/firefox-moderno ]; then
    mkdir -p /opt/firefox-moderno/distribution
    cp /usr/lib/firefox-esr/distribution/policies.json \
       /opt/firefox-moderno/distribution/policies.json 2>/dev/null || true
fi

log_nivel INFO "Firefox configurado (policy de proxy: $FF_PROXY_MODE)"

# ============================================================
# Chrome / Chromium
# ============================================================
log_nivel INFO "Configurando politicas do Chrome/Chromium..."

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
    "RestoreOnStartup": 4,
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
           /etc/chromium-browser/policies/managed \
           /var/snap/chromium/current/policies/managed \
           /var/snap/chromium/common/policies/managed; do
    mkdir -p "$DIR" 2>/dev/null || continue
    echo "$CHROME_POLICY_JSON" > "$DIR/seederlinux.json"
    chmod 644 "$DIR/seederlinux.json"
    chown root:root "$DIR/seederlinux.json" 2>/dev/null || true
done

log_nivel INFO "Chrome/Chromium configurado (policy de proxy: $CHROME_PROXY_MODE)"

# Diagnostico: verificar onde a policy realmente ficou gravada
echo ">>> Diagnostico de politicas Chrome/Chromium:"
for DIR in /etc/opt/chrome/policies/managed \
           /etc/chromium/policies/managed \
           /etc/chromium-browser/policies/managed \
           /var/snap/chromium/current/policies/managed \
           /var/snap/chromium/common/policies/managed; do
    if [ -f "$DIR/seederlinux.json" ]; then
        PERMS="$(stat -c '%a %U:%G' "$DIR/seederlinux.json" 2>/dev/null)"
        echo "    [OK] $DIR/seederlinux.json ($PERMS)"
    fi
done

# Aviso: Chrome/Chromium so releem policies no startup.
# Se estiverem rodando agora, o usuario precisa fechar e reabrir
# (ou reiniciar a sessao) para as policies valerem.
CHROME_RODANDO=false
pgrep -x chrome >/dev/null 2>&1 && CHROME_RODANDO=true
pgrep -x chromium >/dev/null 2>&1 && CHROME_RODANDO=true

if [ "$CHROME_RODANDO" = "true" ]; then
    echo ">>> AVISO: Chrome/Chromium estao rodando."
    echo ">>>        Eles NAO releem policies.json ate reiniciar."
    echo ">>>        Feche todos os processos e reabra."
fi

# Detectar snap-chromium (AppArmor pode bloquear leitura de /etc)
if command -v snap >/dev/null 2>&1 && snap list chromium 2>/dev/null | grep -q "^chromium"; then
    echo ">>> AVISO: Chromium via SNAP detectado."
    echo ">>>        AppArmor da snap pode impedir leitura de /etc/chromium/."
    echo ">>>        Se a policy nao aplicar, use: snap set chromium proxy..."
    echo ">>>        ou instale o Chromium via apt (nao snap)."
fi

# ============================================================
# Extensao Chrome para autenticacao de proxy (Basic auth)
# ============================================================
# Chrome/Chromium NAO exibem popup de auth quando a policy de proxy
# e 'fixed_servers'. Esta extensao usa chrome.webRequest.onAuthRequired
# para responder automaticamente com as credenciais do proxy, lidas de
# /etc/seederlinux/proxy-auth.json (gerado abaixo a partir das vars
# PROXY_K_USER / PROXY_K_PASS_B64 do proxy selecionado).
#
# So e criada quando a policy de proxy e PROXY/PROXY_NO_AUTH/PROXY_WITH_AUTH
# (ou seja, CHROME_PROXY_MODE=fixed_servers) e ha credenciais disponiveis.
# ------------------------------------------------------------
if [ "$CHROME_PROXY_MODE" = "fixed_servers" ]; then
    NOME_EXT="$(_resolver_proxy_nome_efetivo)"

    # Resolver credenciais do proxy nomeado
    PROXY_AUTH_USER=""
    PROXY_AUTH_PASS=""
    if [ -n "$NOME_EXT" ] && [ "${PROXY_COUNT:-0}" -ge 1 ] 2>/dev/null; then
        _i=1
        while [ "$_i" -le "$PROXY_COUNT" ]; do
            _v_name="PROXY_${_i}_NAME"
            if [ "${!_v_name}" = "$NOME_EXT" ]; then
                _v_user="PROXY_${_i}_USER"
                _v_pass_b64="PROXY_${_i}_PASS_B64"
                PROXY_AUTH_USER="${!_v_user}"
                                _v_pass_b64_val="${!_v_pass_b64}"
                if [[ "$_v_pass_b64_val" == "__"*"__" ]] || [ -z "$_v_pass_b64_val" ]; then
                    PROXY_AUTH_PASS=""
                else
                    PROXY_AUTH_PASS="$(printf '%s' "$_v_pass_b64_val" | base64 -d 2>/dev/null || true)"
                fi
                break
            fi
            _i=$((_i+1))
        done
    fi

    if [ -n "$PROXY_AUTH_USER" ] && [ -n "$PROXY_AUTH_PASS" ]; then
        log_nivel INFO "Criando extensao Chrome para auth de proxy (onAuthRequired)..."

        EXT_DIR="/opt/seederlinux/extensions/proxy-auth"
        mkdir -p "$EXT_DIR"

        # manifest.json — MV3 com webRequestAuthProvider
        cat > "$EXT_DIR/manifest.json" <<MANIFEST
{
    "manifest_version": 3,
    "name": "SeederLinux Proxy Auth",
    "version": "1.0",
    "description": "Autenticacao automatica de proxy corporativo",
    "permissions": ["webRequest", "webRequestAuthProvider"],
    "host_permissions": ["<all_urls>"],
    "background": { "service_worker": "background.js" }
}
MANIFEST

        # background.js — credenciais injetadas via sed abaixo.
        # Um UNICO listener onAuthRequired (dois listeners causam
        # comportamento indefinido em MV3 service workers).
        cat > "$EXT_DIR/background.js" <<'BGJS'
// SeederLinux Proxy Auth — responde automaticamente aos desafios
// de Basic auth do proxy corporativo. As credenciais sao injetadas
// neste arquivo no momento da geracao do bundle pelo core_browser.sh.
const PROXY_USER = "__PROXY_AUTH_USER__";
const PROXY_PASS = "__PROXY_AUTH_PASS__";

chrome.webRequest.onAuthRequired.addListener(
    (details, callback) => {
        if (details.isProxy && PROXY_USER && PROXY_PASS) {
            callback({
                authCredentials: {
                    username: PROXY_USER,
                    password: PROXY_PASS
                }
            });
        } else {
            // auth de site (nao-proxy) ou credenciais vazias: deixar o browser pedir
            callback();
        }
    },
    { urls: ["<all_urls>"] },
    ["asyncBlocking"]
);
BGJS

        # Gravar credenciais em arquivo protegido (para auditoria/debug)
        mkdir -p /etc/seederlinux
        cat > /etc/seederlinux/proxy-auth.json <<AUTHJSON
{
    "username": "${PROXY_AUTH_USER}",
    "password": "${PROXY_AUTH_PASS}"
}
AUTHJSON
        chmod 600 /etc/seederlinux/proxy-auth.json

        # Injetar credenciais no background.js (substituir placeholders)
        _ESC_USER="$(printf '%s' "$PROXY_AUTH_USER" | sed 's/[\/&]/\\&/g')"
        _ESC_PASS="$(printf '%s' "$PROXY_AUTH_PASS" | sed 's/[\/&]/\\&/g')"
        sed -i "s/__PROXY_AUTH_USER__/${_ESC_USER}/g" "$EXT_DIR/background.js"
        sed -i "s/__PROXY_AUTH_PASS__/${_ESC_PASS}/g" "$EXT_DIR/background.js"

        # ============================================================
        # Empacotar como CRX3 + update.xml para ExtensionInstallForcelist
        # ============================================================
        # ExtensionInstallForcelist exige um ID de extensao valido (32
        # chars a-p) e um update_url que sirva um XML de update apontando
        # para o .crx. Geramos a chave RSA, calculamos o ID, empacotamos
        # o CRX3 e criamos o update.xml — tudo via openssl + python3.
        log_nivel INFO "Empacotando extensao como CRX3..."

        # 1. Gerar chave RSA (reutilizavel se ja existir)
        EXT_KEY="$EXT_DIR/extension.pem"
        if [ ! -f "$EXT_KEY" ]; then
            openssl genrsa -out "$EXT_KEY" 2048 2>/dev/null
        fi
        chmod 600 "$EXT_KEY"

        # 2. Extrair chave publica em DER
        openssl rsa -in "$EXT_KEY" -pubout -outform DER -out "$EXT_DIR/pubkey.der" 2>/dev/null

        # 3. Calcular ID da extensao + empacotar CRX3 via Python3
        CRX_RESULT=$(python3 - "$EXT_DIR" <<'PYCRX'
import sys, os, struct, hashlib, zipfile, io

ext_dir = sys.argv[1]
key_path = os.path.join(ext_dir, "extension.pem")
pubkey_path = os.path.join(ext_dir, "pubkey.der")

# Ler chave publica DER
with open(pubkey_path, "rb") as f:
    pub_der = f.read()

# Extension ID = first 16 bytes of SHA256(DER pubkey), hex -> a-p
digest = hashlib.sha256(pub_der).digest()[:16]
ext_id = "".join(chr(ord("a") + int(c, 16)) for c in digest.hex())
print(f"EXT_ID={ext_id}")

# Zip dos arquivos da extensao (manifest.json + background.js)
zip_buf = io.BytesIO()
with zipfile.ZipFile(zip_buf, "w", zipfile.ZIP_DEFLATED) as zf:
    for fname in ("manifest.json", "background.js"):
        fpath = os.path.join(ext_dir, fname)
        if os.path.isfile(fpath):
            zf.write(fpath, fname)
zip_data = zip_buf.getvalue()

# Assinar o zip com a chave privada RSA (SHA256 + PKCS#1 v1.5)
import subprocess
sig = subprocess.run(
    ["openssl", "dgst", "-sha256", "-sign", key_path],
    input=zip_data, capture_output=True
).stdout

# Construir CRX3 header (protobuf simplificado)
def varint(n):
    out = bytearray()
    while n > 0x7f:
        out.append(0x80 | (n & 0x7f))
        n >>= 7
    out.append(n)
    return bytes(out)

def field(field_num, data):
    return varint((field_num << 3) | 2) + varint(len(data)) + data

# AsymmetricKeyProof { bytes public_key=1; bytes signature=2; }
asym = field(1, pub_der) + field(2, sig)
# CrxFileHeader { repeated AsymmetricKeyProof sha256_with_rsa=2; }
crx_header = field(2, asym)

crx = b"Cr24" + struct.pack("<I", 3) + struct.pack("<I", len(crx_header)) + crx_header + zip_data
crx_path = os.path.join(ext_dir, "proxy-auth.crx")
with open(crx_path, "wb") as f:
    f.write(crx)
print(f"CRX={crx_path}")
PYCRX
        )
        log_nivel INFO "$CRX_RESULT"
        EXT_ID="$(echo "$CRX_RESULT" | grep '^EXT_ID=' | cut -d= -f2)"

        if [ -n "$EXT_ID" ] && [ -f "$EXT_DIR/proxy-auth.crx" ]; then
            # 4. Criar update.xml (formato GUpdate)
            cat > "$EXT_DIR/update.xml" <<UPDXML
<?xml version="1.0" encoding="UTF-8"?>
<gupdate xmlns="http://www.google.com/update2/response" protocol="2.0">
  <app appid="${EXT_ID}">
    <updatecheck codebase="file://${EXT_DIR}/proxy-auth.crx" version="1.0" />
  </app>
</gupdate>
UPDXML

            # 5. Adicionar ExtensionInstallForcelist ao policies.json do Chrome
            for POLICY_DIR in /etc/opt/chrome/policies/managed \
                               /etc/chromium/policies/managed; do
                [ -f "$POLICY_DIR/seederlinux.json" ] || continue
                python3 -c "
import json
path = '$POLICY_DIR/seederlinux.json'
with open(path) as f:
    data = json.load(f)
data['ExtensionInstallForcelist'] = ['${EXT_ID};file://${EXT_DIR}/update.xml']
data['ExtensionInstallSources'] = ['file:///opt/seederlinux/extensions/*']
with open(path, 'w') as f:
    json.dump(data, f, indent=4)
" 2>/dev/null || true
            done

            log_nivel INFO "Extensao CRX3 empacotada: ID=$EXT_ID"
            log_nivel INFO "update.xml em $EXT_DIR/update.xml"
            log_nivel INFO "ExtensionInstallForcelist adicionado as policies do Chrome"
        else
            log_nivel AVISO "Falha ao empacotar CRX3. Extensao nao sera auto-instalada."
            log_nivel INFO "Para instalar manualmente: chrome://extensions -> Modo desenvolvedor -> Carregar $EXT_DIR"
        fi

        log_nivel INFO "Credenciais gravadas em /etc/seederlinux/proxy-auth.json (600)"
        unset PROXY_AUTH_USER PROXY_AUTH_PASS _ESC_USER _ESC_PASS EXT_ID
    else
        log_nivel AVISO "Proxy exige auth mas sem credenciais (PROXY_*_USER/PASS)."
        log_nivel INFO "Extensao de auth nao criada. Chrome nao autenticara o proxy."
    fi
else
    log_nivel INFO "Policy de proxy nao e fixed_servers. Extensao de auth nao necessaria."
fi

# ============================================================
# Aviso ao usuario sobre proxy por grupo do AD
# ============================================================
log_nivel INFO "Criando aviso de proxy para o usuario..."
mkdir -p /usr/share/doc/seederlinux
cat > /usr/share/doc/seederlinux/AVISO-PROXY.txt <<'AVISOEOF'
AVISO — PROXY CORPORATIVO

Este computador usa proxies diferentes conforme o seu grupo no
Active Directory.

- O CHROME usa sempre o proxy PADRAO configurado pela OM.
- O FIREFOX usa o proxy do SEU grupo, se houver um especifico.
  Senao, usa o padrao.

IMPORTANTE:
- Se o seu grupo mudou, ou se voce foi movido para outro grupo,
  e necessario fazer LOGOFF e LOGON novamente para que o Firefox
  receba o novo proxy.
- O Chrome nao precisa de logoff — sempre usa o padrao.

Em caso de duvida, procure o administrador da sua OM.
AVISOEOF

cat > /usr/share/applications/seederlinux-aviso-proxy.desktop <<DESKTOPEOF
[Desktop Entry]
Type=Application
Name=Aviso do Proxy
Comment=Leia sobre o proxy corporativo
Exec=xdg-open /usr/share/doc/seederlinux/AVISO-PROXY.txt
Icon=dialog-information
Terminal=false
Categories=System;
DESKTOPEOF

log_nivel INFO "Aviso de proxy criado."

log_nivel OK "Politicas de navegadores configuradas!"
echo "============================================================"
