#!/bin/bash
# ============================================================================
# Core Script: core_repositories.sh
# SeederLinux Lite - Configurar sources.list (APT)
# ============================================================================
# Detecta a distribuição (Debian, Ubuntu, Mint, Zorin) e configura os
# repositórios APT conforme APT_POLICY da OM.
#
# POLÍTICAS SUPORTADAS (APT_POLICY):
#   DIRECT              -> mirrors oficiais, direto (Fase 1 clássica)
#   PROXY_NO_AUTH       -> mirrors oficiais via proxy (sem auth)
#   PROXY_WITH_AUTH     -> mirrors oficiais via proxy (com user/senha)
#   MIRROR_LOCAL_SEEDER -> mirror hospedado no próprio SeederLinux,
#                          acessado direto (rede local, sem proxy)
#   MIRROR_LOCAL_OM     -> mirror customizado da OM; se APT_PROXY_NAME
#                          definido, acessa via proxy, senão direto
#   MIRROR_OFFICIAL     -> mirrors oficiais, direto (alias explícito
#                          de DIRECT, mantido por clareza semântica)
#
# MÚLTIPLOS PROXIES:
#   A OM pode ter 0..N proxies nomeados. APT_PROXY_NAME aponta para um
#   deles; se vazio, usa PROXY_DEFAULT_NAME. O proxy é resolvido aqui
#   e escrito em /etc/apt/apt.conf.d/95seederlinux-proxy.
#
# Os placeholders VARIAVEL são substituídos automaticamente
# pelo sistema na geração do bundle.
# ============================================================================

set -e

echo "============================================================"
echo "02 - Configurar repositorios APT"
echo "============================================================"

# ============================================================
# Variáveis (substituídas no bundle)
# ============================================================
APT_POLICY="{{APT_POLICY}}"
APT_PROXY_NAME="{{APT_PROXY_NAME}}"
MIRROR_LOCAL_SEEDER_PATH="{{MIRROR_LOCAL_SEEDER_PATH}}"
MIRROR_LOCAL_OM_URL="{{MIRROR_LOCAL_OM_URL}}"
SEEDER_SERVER="{{SEEDER_SERVER}}"

# Múltiplos proxies (dinâmicos, vem do header do bundle)
PROXY_COUNT="${PROXY_COUNT:-0}"
PROXY_DEFAULT_NAME="${PROXY_DEFAULT_NAME:-}"

# Defaults defensivos
[ -z "$APT_POLICY" ] && APT_POLICY="DIRECT"
[ -z "$MIRROR_LOCAL_SEEDER_PATH" ] && MIRROR_LOCAL_SEEDER_PATH="/mirror/"
SEEDER_SERVER="${SEEDER_SERVER%/}"

echo ">>> APT_POLICY: $APT_POLICY"
echo ">>> APT_PROXY_NAME: ${APT_PROXY_NAME:-<default>}"
echo ">>> Proxies cadastrados: $PROXY_COUNT"

# ============================================================
# Fase 1 — limpar estado de proxy herdado
# ============================================================
# O apt nao respeita wildcards no no_proxy. Se um snapshot herdou
# um 95seederlinux-proxy de execucao anterior com proxy nao
# resolvivel, o apt-get update quebra antes mesmo deste script
# decidir qual politica aplicar.
#
# Comecamos SEMPRE limpo. Se a policy escolhida for PROXY_*, o
# arquivo sera reescrito no fim deste script, ANTES do apt-get
# update.
echo ">>> Limpando config de proxy do apt de execucoes anteriores..."
rm -f /etc/apt/apt.conf.d/95seederlinux-proxy 2>/dev/null || true

# ============================================================
# Detectar distribuição
# ============================================================
detect_distro() {
    if [ -f /etc/linuxmint/info ]; then
        echo "mint"
    elif [ -f /etc/zorin-release ]; then
        echo "zorin"
    elif grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
        echo "ubuntu"
    elif grep -qi "debian" /etc/os-release 2>/dev/null; then
        echo "debian"
    else
        echo "unknown"
    fi
}

DISTRO="$(detect_distro)"
echo ">>> Distribuicao detectada: $DISTRO"

# ============================================================
# Obter codename da distro
# ============================================================
get_codename() {
    local fallback="$1"
    local codename=""

    if [ -f /etc/os-release ]; then
        codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
    fi
    if [ -z "$codename" ] && command -v lsb_release &>/dev/null; then
        codename="$(lsb_release -cs 2>/dev/null)"
    fi
    if [ -z "$codename" ]; then
        echo ">>> AVISO: nao foi possivel detectar o codename. Usando fallback: $fallback" >&2
        codename="$fallback"
    fi
    echo "$codename"
}

# ============================================================
# Helper: resolver proxy por nome
# ============================================================
# Procura PROXY_N_NAME == $1 e retorna a URL montada (com user:pass
# embutido se houver). Vazio se nao encontrar.
#
# Formato aceito pelo apt: http://user:pass@host:port/
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

            if [ -z "$url" ]; then
                echo ">>> AVISO: proxy '$name' encontrado mas URL vazia." >&2
                return 1
            fi

            # Sem user: retorna URL como esta
            if [ -z "$user" ]; then
                echo "$url"
                return 0
            fi

            # Com user: decodifica senha e embute na URL
            local pass=""
            if [ -n "$pass_b64" ]; then
                pass="$(printf '%s' "$pass_b64" | base64 -d 2>/dev/null)" || pass=""
            fi

            # URL-encode muito basico de @ e : no user/pass
            # (se contiverem, quebram a sintaxe user:pass@host)
            local user_esc="${user//@/%40}"
            user_esc="${user_esc//:/%3A}"
            local pass_esc="${pass//@/%40}"
            pass_esc="${pass_esc//:/%3A}"

            # http://user:pass@host:port
            if echo "$url" | grep -qE '^https?://'; then
                echo "$url" | sed -E "s|^(https?://)|\1${user_esc}:${pass_esc}@|"
            else
                # URL sem scheme (raro, mas defensivo)
                echo "http://${user_esc}:${pass_esc}@${url}"
            fi
            return 0
        fi
        i=$((i+1))
    done
    return 1
}

# Resolve o nome efetivo do proxy (policy name ou default)
_resolver_proxy_nome_efetivo() {
    if [ -n "$APT_PROXY_NAME" ]; then
        echo "$APT_PROXY_NAME"
    else
        echo "$PROXY_DEFAULT_NAME"
    fi
}

# ============================================================
# Helper: escrever 95seederlinux-proxy
# ============================================================
_escrever_proxy_apt() {
    local url="$1"
    echo ">>> Configurando apt via proxy: $url"
    cat > /etc/apt/apt.conf.d/95seederlinux-proxy <<EOF
Acquire::http::Proxy "${url}";
Acquire::https::Proxy "${url}";
Acquire::ftp::Proxy "${url}";
EOF
}

# ============================================================
# Resolver config de proxy (se aplicável)
# ============================================================
APT_PROXY_URL=""

case "$APT_POLICY" in
    PROXY_NO_AUTH|PROXY_WITH_AUTH)
        NOME_EFETIVO="$(_resolver_proxy_nome_efetivo)"
        if [ -z "$NOME_EFETIVO" ]; then
            echo ">>> ERRO: APT_POLICY=$APT_POLICY mas nenhum proxy configurado (APT_PROXY_NAME vazio e PROXY_DEFAULT_NAME vazio)."
            echo ">>> Configurando apt como DIRECT para nao travar o bundle."
            APT_POLICY="DIRECT"
        else
            APT_PROXY_URL="$(_resolver_proxy_url "$NOME_EFETIVO")" || APT_PROXY_URL=""
            if [ -z "$APT_PROXY_URL" ]; then
                echo ">>> ERRO: proxy '$NOME_EFETIVO' nao encontrado na lista de proxies da OM."
                echo ">>> Configurando apt como DIRECT para nao travar o bundle."
                APT_POLICY="DIRECT"
            else
                _escrever_proxy_apt "$APT_PROXY_URL"
            fi
        fi
        ;;
    MIRROR_LOCAL_OM)
        # Mirror da OM pode estar em outra rede; se a OM definiu proxy
        # para ele, usamos; senao, direto.
        NOME_EFETIVO="$(_resolver_proxy_nome_efetivo)"
        if [ -n "$NOME_EFETIVO" ]; then
            APT_PROXY_URL="$(_resolver_proxy_url "$NOME_EFETIVO")" || APT_PROXY_URL=""
            if [ -n "$APT_PROXY_URL" ]; then
                _escrever_proxy_apt "$APT_PROXY_URL"
            fi
        fi
        ;;
    DIRECT|MIRROR_LOCAL_SEEDER|MIRROR_OFFICIAL|*)
        # Sem proxy. O 95seederlinux-proxy ja foi removido no topo.
        ;;
esac

# ============================================================
# Backup do sources.list antes de mexer
# ============================================================
backup_sources() {
    if [ -f /etc/apt/sources.list ]; then
        cp /etc/apt/sources.list /etc/apt/sources.list.bak.$(date +%Y%m%d%H%M%S)
    fi
}

# ============================================================
# Escrever sources.list conforme a policy
# ============================================================
case "$APT_POLICY" in

    DIRECT|PROXY_NO_AUTH|PROXY_WITH_AUTH)
        echo ">>> Policy: mirrors oficiais da distro ($DISTRO)."
        echo ">>> Nenhuma alteracao em sources.list (mantendo o que ja esta)."
        # Nao mexe: a estacao ja veio com sources.list da distro
        ;;

    MIRROR_OFFICIAL)
        echo ">>> Policy: mirrors oficiais explicitos."
        echo ">>> Nenhuma alteracao em sources.list."
        ;;

    MIRROR_LOCAL_SEEDER)
        echo ">>> Policy: mirror local hospedado no SeederLinux."
        echo ">>> Base: ${SEEDER_SERVER}${MIRROR_LOCAL_SEEDER_PATH}"

        backup_sources

        case "$DISTRO" in
            ubuntu)
                UBUNTU_CODENAME="$(get_codename noble)"
                cat > /etc/apt/sources.list <<EOF
deb ${SEEDER_SERVER}${MIRROR_LOCAL_SEEDER_PATH}ubuntu $UBUNTU_CODENAME main restricted universe multiverse
deb ${SEEDER_SERVER}${MIRROR_LOCAL_SEEDER_PATH}ubuntu $UBUNTU_CODENAME-updates main restricted universe multiverse
deb ${SEEDER_SERVER}${MIRROR_LOCAL_SEEDER_PATH}ubuntu $UBUNTU_CODENAME-security main restricted universe multiverse
EOF
                ;;
            mint)
                MINT_CODENAME="$(get_codename wilma)"
                UBUNTU_CODENAME="$(grep UBUNTU_CODENAME /etc/linuxmint/info 2>/dev/null | cut -d= -f2 || echo noble)"
                cat > /etc/apt/sources.list <<EOF
deb ${SEEDER_SERVER}${MIRROR_LOCAL_SEEDER_PATH}mint $MINT_CODENAME main upstream import backport
deb ${SEEDER_SERVER}${MIRROR_LOCAL_SEEDER_PATH}ubuntu $UBUNTU_CODENAME main restricted universe multiverse
deb ${SEEDER_SERVER}${MIRROR_LOCAL_SEEDER_PATH}ubuntu $UBUNTU_CODENAME-updates main restricted universe multiverse
deb ${SEEDER_SERVER}${MIRROR_LOCAL_SEEDER_PATH}ubuntu $UBUNTU_CODENAME-security main restricted universe multiverse
EOF
                ;;
            debian)
                DEBIAN_CODENAME="$(get_codename trixie)"
                cat > /etc/apt/sources.list <<EOF
deb ${SEEDER_SERVER}${MIRROR_LOCAL_SEEDER_PATH}debian $DEBIAN_CODENAME main contrib non-free non-free-firmware
deb ${SEEDER_SERVER}${MIRROR_LOCAL_SEEDER_PATH}debian-security $DEBIAN_CODENAME-security main contrib non-free non-free-firmware
deb ${SEEDER_SERVER}${MIRROR_LOCAL_SEEDER_PATH}debian $DEBIAN_CODENAME-updates main contrib non-free non-free-firmware
EOF
                ;;
            zorin)
                UBUNTU_CODENAME="$(get_codename jammy)"
                cat > /etc/apt/sources.list <<EOF
deb ${SEEDER_SERVER}${MIRROR_LOCAL_SEEDER_PATH}ubuntu $UBUNTU_CODENAME main restricted universe multiverse
deb ${SEEDER_SERVER}${MIRROR_LOCAL_SEEDER_PATH}ubuntu $UBUNTU_CODENAME-updates main restricted universe multiverse
deb ${SEEDER_SERVER}${MIRROR_LOCAL_SEEDER_PATH}ubuntu $UBUNTU_CODENAME-security main restricted universe multiverse
EOF
                ;;
            *)
                echo ">>> AVISO: distro '$DISTRO' nao reconhecida. Mantendo sources.list atual."
                ;;
        esac
        ;;

    MIRROR_LOCAL_OM)
        if [ -z "$MIRROR_LOCAL_OM_URL" ]; then
            echo ">>> ERRO: APT_POLICY=MIRROR_LOCAL_OM mas MIRROR_LOCAL_OM_URL esta vazio."
            echo ">>> Mantendo sources.list atual."
        else
            echo ">>> Policy: mirror local da OM ($MIRROR_LOCAL_OM_URL)"
            backup_sources

            MIRROR_BASE="${MIRROR_LOCAL_OM_URL%/}"
            case "$DISTRO" in
                ubuntu|zorin)
                    UBUNTU_CODENAME="$(get_codename noble)"
                    cat > /etc/apt/sources.list <<EOF
deb ${MIRROR_BASE}/ubuntu $UBUNTU_CODENAME main restricted universe multiverse
deb ${MIRROR_BASE}/ubuntu $UBUNTU_CODENAME-updates main restricted universe multiverse
deb ${MIRROR_BASE}/ubuntu $UBUNTU_CODENAME-security main restricted universe multiverse
EOF
                    ;;
                mint)
                    MINT_CODENAME="$(get_codename wilma)"
                    UBUNTU_CODENAME="$(grep UBUNTU_CODENAME /etc/linuxmint/info 2>/dev/null | cut -d= -f2 || echo noble)"
                    cat > /etc/apt/sources.list <<EOF
deb ${MIRROR_BASE}/mint $MINT_CODENAME main upstream import backport
deb ${MIRROR_BASE}/ubuntu $UBUNTU_CODENAME main restricted universe multiverse
deb ${MIRROR_BASE}/ubuntu $UBUNTU_CODENAME-updates main restricted universe multiverse
deb ${MIRROR_BASE}/ubuntu $UBUNTU_CODENAME-security main restricted universe multiverse
EOF
                    ;;
                debian)
                    DEBIAN_CODENAME="$(get_codename trixie)"
                    cat > /etc/apt/sources.list <<EOF
deb ${MIRROR_BASE}/debian $DEBIAN_CODENAME main contrib non-free non-free-firmware
deb ${MIRROR_BASE}/debian-security $DEBIAN_CODENAME-security main contrib non-free non-free-firmware
deb ${MIRROR_BASE}/debian $DEBIAN_CODENAME-updates main contrib non-free non-free-firmware
EOF
                    ;;
                *)
                    echo ">>> AVISO: distro '$DISTRO' nao reconhecida. Mantendo sources.list atual."
                    ;;
            esac
        fi
        ;;

    *)
        echo ">>> AVISO: APT_POLICY desconhecida '$APT_POLICY'. Tratando como DIRECT."
        ;;
esac

# ============================================================
# apt-get update
# ============================================================
# Em DIRECT/PROXY_* a fonte eh mirror oficial - se falhar, e' falha
# real (internet caiu, proxy caiu), e o bundle deve abortar.
#
# Em MIRROR_* a fonte eh local ou curada - se falhar, tambem e' falha
# real (mirror fora do ar, path errado), e o bundle deve abortar.
#
# Nao toleramos falha aqui: queremos saber se o APT nao esta funcional
# ANTES de tentar instalar pacotes no script 03.
echo ">>> Atualizando apt-get update..."
apt-get update

echo ">>> [02] Repositorios configurados com sucesso (policy: $APT_POLICY)!"
echo "============================================================"
