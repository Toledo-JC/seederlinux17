#!/bin/bash
# ============================================================================
# Core Script: core_proxy.sh
# SeederLinux Lite - Proxy de CLI (wget/curl/git do usuário)
# ============================================================================
# Configura /etc/environment com as variáveis de proxy que afetam
# ferramentas de linha de comando. NÃO configura browsers (isso é
# responsabilidade de core_browser.sh) NEM apt (responsabilidade de
# core_repositories.sh).
#
# POLÍTICAS SUPORTADAS (CLI_POLICY):
#   DIRECT          -> sem proxy, limpa /etc/environment (default)
#   PROXY_NO_AUTH   -> via proxy sem autenticação
#   PROXY_WITH_AUTH -> via proxy com user/senha
#   PAC             -> NÃO SUPORTADO por wget/curl/git; cai pra DIRECT
#                      com aviso (PAC só faz sentido pra browsers, que
#                      são configurados no core_browser.sh)
#
# MÚLTIPLOS PROXIES:
#   A OM pode ter 0..N proxies nomeados. CLI_PROXY_NAME aponta para um
#   deles; se vazio, usa PROXY_DEFAULT_NAME.
#
# IMPORTANTE - NÃO DERRUBA SESSÃO:
#   Este script só escreve em /etc/environment e nos arquivos de config
#   dos proxies. NÃO reinicia serviços de sessão, NÃO toca em
#   /etc/apt/apt.conf.d, NÃO mexe em DNS. Roda com segurança em estações
#   já em uso.
#
# Os placeholders VARIAVEL são substituídos automaticamente
# pelo sistema na geração do bundle.
# ============================================================================

set -e

echo "============================================================"
echo "17 - Configurar proxy de CLI"
echo "============================================================"

# ============================================================
# Variáveis (substituídas no bundle)
# ============================================================
CLI_POLICY="{{CLI_POLICY}}"
CLI_PROXY_NAME="{{CLI_PROXY_NAME}}"
SEEDER_SERVER="{{SEEDER_SERVER}}"
DC_IP="{{DC_IP}}"
DC_IP_LIST="{{DC_IP_LIST}}"
DOMINIO="{{DOMINIO}}"

# Múltiplos proxies (dinâmicos, vem do header do bundle)
PROXY_COUNT="${PROXY_COUNT:-0}"
PROXY_DEFAULT_NAME="${PROXY_DEFAULT_NAME:-}"

# Defaults defensivos
[ -z "$CLI_POLICY" ] && CLI_POLICY="DIRECT"
SEEDER_SERVER="${SEEDER_SERVER%/}"

echo ">>> CLI_POLICY: $CLI_POLICY"
echo ">>> CLI_PROXY_NAME: ${CLI_PROXY_NAME:-<default>}"
echo ">>> Proxies cadastrados: $PROXY_COUNT"

# ============================================================
# Helper: resolver proxy por nome -> URL com user:pass
# ============================================================
# Retorna a URL completa (com credenciais se houver) ou vazio.
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
            local v_pass_b64="PROXY_${i}_PASS_B64"
            local url="${!v_url}"
            local user="${!v_user}"
            local pass_b64="${!v_pass_b64}"

            [ -z "$url" ] && return 1
            [ -z "$user" ] && { echo "$url"; return 0; }

            local pass=""
            if [ -n "$pass_b64" ]; then
                pass="$(printf '%s' "$pass_b64" | base64 -d 2>/dev/null)" || pass=""
            fi

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

# ============================================================
# Helper: NO_PROXY específico de um proxy
# ============================================================
# Cada proxy pode ter seu próprio no_proxy. Retorna o valor (ou vazio).
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
# Helper: nome efetivo do proxy
# ============================================================
_resolver_proxy_nome_efetivo() {
    if [ -n "$CLI_PROXY_NAME" ]; then
        echo "$CLI_PROXY_NAME"
    else
        echo "$PROXY_DEFAULT_NAME"
    fi
}

# ============================================================
# Helper: montar NO_PROXY final
# ============================================================
# Regra:
#   - Sempre inclui localhost e 127.0.0.1
#   - Inclui o hostname e IP do SEEDER_SERVER
#   - Inclui todos os DCs (DC_IP + DC_IP_LIST)
#   - Inclui o domínio (para cobrir subdomínios que clientes
#     entendem - Firefox aceita ".dominio", wget não, mas não faz mal)
#   - Anexa o NO_PROXY específico do proxy (se houver)
#
# NOTA sobre wildcards:
#   apt/wget/curl/git NÃO respeitam wildcards tipo "*.intraer".
#   Por isso incluímos o domínio literal ".comara.intraer" - alguns
#   clientes (Firefox) interpretam como sufixo; os que não interpretam
#   simplesmente ignoram. IPs e hostnames exatos são o mecanismo
#   confiável.
_build_no_proxy() {
    local extra="$1"
    local base="localhost,127.0.0.1"

    # Seeder hostname + IP
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

    # Domínio
    if [ -n "$DOMINIO" ]; then
        base="${base},.${DOMINIO}"
    fi

    # DC principal
    if [ -n "$DC_IP" ]; then
        case ",$base," in
            *",$DC_IP,"*) ;;
            *) base="${base},${DC_IP}" ;;
        esac
    fi

    # DCs adicionais (DC_IP_LIST pode ser "ip1,ip2" ou "ip1 ip2")
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

    # Extra específico do proxy
    if [ -n "$extra" ]; then
        base="${base},${extra}"
    fi

    echo "$base"
}

# ============================================================
# Helper: escrever proxy em /etc/environment
# ============================================================
# Preserva todo o resto do arquivo, remove linhas de proxy antigas e
# anexa as novas.
_escrever_environment_proxy() {
    local url="$1"
    local no_proxy="$2"

    # Garante que o arquivo existe
    touch /etc/environment

    # Remove linhas de proxy antigas (idempotente)
    sed -i '/^http_proxy=/d;/^https_proxy=/d;/^ftp_proxy=/d;/^no_proxy=/d' /etc/environment 2>/dev/null || true
    sed -i '/^HTTP_PROXY=/d;/^HTTPS_PROXY=/d;/^FTP_PROXY=/d;/^NO_PROXY=/d' /etc/environment 2>/dev/null || true
    sed -i '/^all_proxy=/d;/^ALL_PROXY=/d' /etc/environment 2>/dev/null || true

    # Anexa novas
    {
        echo ""
        echo "# Proxy configurado por SeederLinux (core_proxy.sh)"
        echo "http_proxy=\"${url}\""
        echo "https_proxy=\"${url}\""
        echo "ftp_proxy=\"${url}\""
        echo "HTTP_PROXY=\"${url}\""
        echo "HTTPS_PROXY=\"${url}\""
        echo "FTP_PROXY=\"${url}\""
        if [ -n "$no_proxy" ]; then
            echo "no_proxy=\"${no_proxy}\""
            echo "NO_PROXY=\"${no_proxy}\""
        fi
    } >> /etc/environment

    # Modo canônico
    chmod 644 /etc/environment

    echo ">>> /etc/environment atualizado"
    echo ">>>   http_proxy=${url}"
    echo ">>>   no_proxy=${no_proxy}"
}

# ============================================================
# Helper: limpar proxy de /etc/environment
# ============================================================
_limpar_environment_proxy() {
    if [ -f /etc/environment ]; then
        sed -i '/^http_proxy=/d;/^https_proxy=/d;/^ftp_proxy=/d;/^no_proxy=/d' /etc/environment 2>/dev/null || true
        sed -i '/^HTTP_PROXY=/d;/^HTTPS_PROXY=/d;/^FTP_PROXY=/d;/^NO_PROXY=/d' /etc/environment 2>/dev/null || true
        sed -i '/^all_proxy=/d;/^ALL_PROXY=/d' /etc/environment 2>/dev/null || true
        # Remove o comentário marcador para não acumular lixo
        sed -i '/^# Proxy configurado por SeederLinux (core_proxy.sh)$/d' /etc/environment 2>/dev/null || true
        echo ">>> /etc/environment limpo (sem proxy)"
    fi
}

# ============================================================
# Aplicar CLI_POLICY
# ============================================================
case "$CLI_POLICY" in

    DIRECT|"")
        echo ">>> Policy: DIRECT - sem proxy para CLI."
        _limpar_environment_proxy
        ;;

    PROXY_NO_AUTH|PROXY_WITH_AUTH)
        NOME_EFETIVO="$(_resolver_proxy_nome_efetivo)"
        if [ -z "$NOME_EFETIVO" ]; then
            echo ">>> ERRO: CLI_POLICY=$CLI_POLICY mas nenhum proxy configurado."
            echo ">>> Configurando CLI como DIRECT para nao travar o bundle."
            _limpar_environment_proxy
        else
            URL="$(_resolver_proxy_url "$NOME_EFETIVO")" || URL=""
            if [ -z "$URL" ]; then
                echo ">>> ERRO: proxy '$NOME_EFETIVO' nao encontrado na lista de proxies da OM."
                echo ">>> Configurando CLI como DIRECT para nao travar o bundle."
                _limpar_environment_proxy
            else
                NO_PROXY_ESPECIFICO="$(_resolver_proxy_no_proxy "$NOME_EFETIVO")" || NO_PROXY_ESPECIFICO=""
                NO_PROXY_FINAL="$(_build_no_proxy "$NO_PROXY_ESPECIFICO")"
                _escrever_environment_proxy "$URL" "$NO_PROXY_FINAL"
            fi
        fi
        ;;

    PAC)
        echo ">>> AVISO: PAC nao e suportado por wget/curl/git."
        echo ">>>        Ferramentas de CLI so entendem proxy explicito, nao PAC."
        echo ">>>        Para browsers (que suportam PAC), configure BROWSER_POLICY=PAC."
        echo ">>>        Aplicando DIRECT para CLI."
        _limpar_environment_proxy
        ;;

    *)
        echo ">>> AVISO: CLI_POLICY desconhecida '$CLI_POLICY'. Tratando como DIRECT."
        _limpar_environment_proxy
        ;;
esac

# ============================================================
# Nota sobre o agente Seeder
# ============================================================
# O agente Seeder NAO respeita /etc/environment para decidir se usa
# proxy - ele remove as variaveis do proprio processo antes de fazer
# qualquer request (ver disable_proxy_for_process() no agent.py).
# Isso e' intencional: o agente so fala com o SEEDER_SERVER, que esta
# sempre no NO_PROXY, e nunca deve passar por proxy corporativo.
# Nada a fazer aqui para o agente.

echo ">>> [17] Proxy de CLI configurado!"
echo "============================================================"
