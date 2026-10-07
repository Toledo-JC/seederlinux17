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
# PROXY DO FIREFOX — NÃO É CONFIGURADO AQUI (Modelo B)
# ==================================================
# O Firefox recebe proxy POR GRUPO DO AD via
# ~/.mozilla/firefox/seederlinux.default/user.js, escrito pelo
# core_logon.sh (no logon) e reaplicado pelo seeder-sync (a cada
# 10min via seeder-sync.timer). Para isso funcionar, o policies.json
# do Firefox NÃO PODE ter a seção "Proxy" com "Locked": true — se
# tiver, o Firefox ignora o user.js por precedência de policy.
#
# O Chrome/Chromium usa SEMPRE PROXY_DEFAULT_NAME (catch-all) via
# policies.json. Ele não suporta proxy por usuário em máquina
# multi-usuário sem PAC dinâmico (V2).
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
# Modelo B: Firefox NÃO recebe proxy em policies.json; o proxy do
# Firefox é resolvido por AD_GROUP via user.js em core_logon.sh.
# O Chrome/Chromium continua recebendo fixed_servers/system/direct.
CHROME_PROXY_MODE="direct"
CHROME_PROXY_SERVER=""
CHROME_PROXY_PAC=""
CHROME_NO_PROXY=""

case "$BROWSER_POLICY" in

    DIRECT|"")
        CHROME_PROXY_MODE="direct"
        ;;

    # PROXY, PROXY_NO_AUTH e PROXY_WITH_AUTH fazem a mesma coisa para
    # browser: aplicam o proxy sem credencial. Os nomes "NO_AUTH" e
    # "WITH_AUTH" são legados do modelo single-proxy e não têm mais
    # significado distinto para navegadores.
    PROXY|PROXY_NO_AUTH|PROXY_WITH_AUTH)
        # Chrome SEMPRE usa PROXY_DEFAULT_NAME (catch-all). Modelo B:
        # Firefox tem proxy por grupo via user.js; Chrome não tem esse
        # mecanismo em multi-usuário. Ignoramos BROWSER_PROXY_NAME aqui.
        NOME="${PROXY_DEFAULT_NAME:-}"
        HOSTPORT="$(_resolver_proxy_hostport "$NOME")" || HOSTPORT=""
        if [ -z "$HOSTPORT" ]; then
            log_nivel AVISO "BROWSER_POLICY=$BROWSER_POLICY mas proxy '${NOME:-<nenhum>}' nao encontrado."
            log_nivel INFO "Aplicando DIRECT para os navegadores."
            CHROME_PROXY_MODE="direct"
        else
            CHROME_NO_PROXY="$(_build_no_proxy_browser "$(_resolver_proxy_no_proxy "$NOME" || echo "")")"

            # --- Chrome: fixed_servers com host:port e bypass list ---
            # Formato OBRIGATÓRIO: "scheme=host:port;scheme=host:port".
            # Se vier user:pass@, o Chrome ignora a policy.
            CHROME_PROXY_MODE="fixed_servers"
            CHROME_PROXY_SERVER="http=${HOSTPORT};https=${HOSTPORT}"

            log_nivel INFO "Proxy aplicado ao Chrome: $HOSTPORT"
            log_nivel INFO "Firefox continua por grupo do AD via user.js; autenticacao por usuario (popup ou SSO)."
        fi
        ;;

    PAC)
        NOME="${PROXY_DEFAULT_NAME:-}"
        PAC_URL="$(_resolver_proxy_pac "$NOME")" || PAC_URL=""
        if [ -z "$PAC_URL" ]; then
            log_nivel AVISO "BROWSER_POLICY=PAC mas PAC_URL vazio para o proxy '${NOME:-<nenhum>}'."
            log_nivel INFO "Aplicando DIRECT para os navegadores."
            CHROME_PROXY_MODE="direct"
        else
            CHROME_PROXY_MODE="pac_script"
            CHROME_PROXY_PAC="$PAC_URL"
        fi
        ;;

    SYSTEM)
        CHROME_PROXY_MODE="system"
        ;;

    *)
        log_nivel AVISO "BROWSER_POLICY desconhecida '$BROWSER_POLICY'. Aplicando DIRECT."
        CHROME_PROXY_MODE="direct"
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
        "SearchBar": "unified",
        "SearchEngines": {
            "Add": [
                { "Name": "${OM_ACRONYM}", "URL": "${HOMEPAGE}", "Method": "GET" }
            ]
        },
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

log_nivel INFO "Firefox configurado (sem Proxy em policies.json; proxy por user.js via AD)"

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
# AUTENTICACAO DE PROXY NOS NAVEGADORES — NAO E CONFIGURADA AQUI
# ============================================================
# Firefox e Chrome recebem apenas host:port do proxy. Quando o
# proxy exige autenticacao (ex: GAPE-BE), o usuario digita suas
# credenciais no popup nativo do navegador na primeira navegacao.
# Cada usuario tem a sua — o bundle nao injeta credencial.
#
# Isso vale para os dois navegadores. A extensao Chrome que
# existia antes (chrome.webRequest.onAuthRequired) foi removida
# por decisao de projeto: credencial de usuario nao fica em
# arquivo global lido por todos.
#
# Nota: Chrome/Chromium NAO exibem popup de auth em
# `fixed_servers` — comportamento conhecido. Usuarios precisam
# de extensao manual ou proxy transparente. Isso e' documentado
# no AVISO-PROXY.txt para o usuario final.
# ============================================================

# ============================================================
# Aviso ao usuario sobre proxy por grupo do AD
# ============================================================
log_nivel INFO "Criando aviso de proxy para o usuario..."
mkdir -p /usr/share/doc/seederlinux
cat > /usr/share/doc/seederlinux/AVISO-PROXY.txt <<'AVISOEOF'
AVISO — PROXY CORPORATIVO

Este computador usa proxies corporativos com autenticacao.

- O FIREFOX pede a sua senha do proxy na primeira navegacao
  (popup nativo do browser). Cada usuario tem a sua.
- O CHROME/CHROMIUM nao exibe popup com proxy fixo (limitacao
  conhecida do navegador). Se voce precisar autenticar no
  Chrome, procure o administrador da OM.

O proxy padrao da OM e' o mesmo para todos os usuarios.
Se voce pertence a um grupo especifico (ex: _SPTF), o FIREFOX
usa o proxy do seu grupo apos o login. O CHROME sempre usa o
proxy padrao.

Se voce foi movido de grupo, faca LOGOFF e LOGON novamente
para que o Firefox receba o novo proxy.

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
