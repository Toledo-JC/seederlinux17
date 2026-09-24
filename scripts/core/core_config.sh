#!/bin/bash
# ============================================================================
# Core Script: core_config.sh
# SeederLinux Lite - Arquivo de Configuracao Persistente
# ============================================================================
# Cria /etc/seederlinux/config.env com todas as variaveis nao-sensiveis
# da OM. Este arquivo e lido pelos scripts permanentes (seederlinux-logon,
# seederlinux-logoff, seeder-sync) apos reboot, quando as variaveis
# exportadas no bundle ja nao existem mais na memoria.
#
# MODELO MULTI-PROXY:
#   A OM pode ter 0..N proxies nomeados. As 3 politicas (APT/CLI/BROWSER)
#   referenciam um proxy pelo nome. config.env guarda o array de proxies
#   SEM as senhas; as senhas vao para /etc/seederlinux/secrets.env (600).
#
# Variaveis sensiveis (senha VNC, senha de proxy) NAO sao escritas em
# config.env. Vao em secrets.env, com permissao 600.
#
# Os placeholders VARIAVEL sao substituidos automaticamente
# pelo sistema na geracao do bundle.
# ============================================================================

set -e

echo "============================================================"
echo "13.5 - Criar arquivo de configuracao persistente"
echo "============================================================"

# ============================================================
# Diretorio base
# ============================================================
mkdir -p /etc/seederlinux

CONFIG_FILE="/etc/seederlinux/config.env"
SECRETS_FILE="/etc/seederlinux/secrets.env"

# ============================================================
# Normalizacao de URLs de assets
# ============================================================
SEEDER_SERVER="{{SEEDER_SERVER}}"
SEEDER_SERVER="${SEEDER_SERVER%/}"

WALLPAPER_URL="{{WALLPAPER_URL}}"
WALLPAPER_LOGIN_URL="{{WALLPAPER_LOGIN_URL}}"
LOGO_URL="{{LOGO_URL}}"
GREETER_URL="{{GREETER_URL}}"

echo ">>> Normalizando URLs de assets para forma absoluta..."
for url_var in WALLPAPER_URL WALLPAPER_LOGIN_URL LOGO_URL GREETER_URL; do
    url_val="${!url_var}"
    [ -z "$url_val" ] && continue
    echo "$url_val" | grep -qE '^https?://[^/]+/' && continue
    if [ -n "$SEEDER_SERVER" ]; then
        if echo "$url_val" | grep -q '^/'; then
            eval "${url_var}=\"${SEEDER_SERVER}${url_val}\""
        else
            eval "${url_var}=\"${SEEDER_SERVER}/${url_val}\""
        fi
    fi
done

# ============================================================
# NTP_SERVER: remover protocolo
# ============================================================
NTP_SERVER="{{NTP_SERVER}}"
NTP_SERVER="${NTP_SERVER#http://}"
NTP_SERVER="${NTP_SERVER#https://}"

# ============================================================
# Politicas de proxy (multi-proxy)
# ============================================================
APT_POLICY="{{APT_POLICY}}"
APT_PROXY_NAME="{{APT_PROXY_NAME}}"
CLI_POLICY="{{CLI_POLICY}}"
CLI_PROXY_NAME="{{CLI_PROXY_NAME}}"
BROWSER_POLICY="{{BROWSER_POLICY}}"
BROWSER_PROXY_NAME="{{BROWSER_PROXY_NAME}}"
MIRROR_LOCAL_SEEDER_PATH="{{MIRROR_LOCAL_SEEDER_PATH}}"
MIRROR_LOCAL_OM_URL="{{MIRROR_LOCAL_OM_URL}}"

[ -z "$APT_POLICY" ] && APT_POLICY="DIRECT"
[ -z "$CLI_POLICY" ] && CLI_POLICY="DIRECT"
[ -z "$BROWSER_POLICY" ] && BROWSER_POLICY="DIRECT"
[ -z "$MIRROR_LOCAL_SEEDER_PATH" ] && MIRROR_LOCAL_SEEDER_PATH="/mirror/"

# Array de proxies (vem do header do bundle)
PROXY_COUNT="${PROXY_COUNT:-0}"
PROXY_DEFAULT_NAME="${PROXY_DEFAULT_NAME:-}"

echo ">>> APT_POLICY: $APT_POLICY"
echo ">>> CLI_POLICY: $CLI_POLICY"
echo ">>> BROWSER_POLICY: $BROWSER_POLICY"
echo ">>> Proxies: $PROXY_COUNT (default: ${PROXY_DEFAULT_NAME:-<nenhum>})"

# ============================================================
# Preservar SERIAL_APLICADO
# ============================================================
SERIAL_APLICADO_ATUAL="0"
if [ -f "$CONFIG_FILE" ]; then
    VALOR_EXISTENTE="$(grep -m1 '^SERIAL_APLICADO=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"')"
    [ -n "$VALOR_EXISTENTE" ] && SERIAL_APLICADO_ATUAL="$VALOR_EXISTENTE"
fi
echo ">>> SERIAL_APLICADO preservado: $SERIAL_APLICADO_ATUAL"

# ============================================================
# Escrever config.env (cabecalho + variaveis + array de proxies)
# ============================================================
cat > "$CONFIG_FILE" <<EOF
# SeederLinux Lite - Configuracao Persistente
# NAO EDITAR MANUALMENTE - gerado pelo core_config.sh
# Gerado em: $(date '+%Y-%m-%d %H:%M:%S')

# Dominio e Autenticacao
DOMINIO="{{DOMINIO}}"
DOMINIO_NETBIOS="{{DOMINIO_NETBIOS}}"
DC_IP="{{DC_IP}}"
DC_IP_LIST="{{DC_IP_LIST}}"
DC_SECUNDARIO_IP="{{DC_SECUNDARIO_IP}}"
DNS_PRIMARIO="{{DNS_PRIMARIO}}"
DNS_SECUNDARIO="{{DNS_SECUNDARIO}}"
DNS_INTERNET="{{DNS_INTERNET}}"
NTP_SERVER="${NTP_SERVER}"
OU_PADRAO="{{OU_PADRAO}}"
GRUPO_ADMIN="{{GRUPO_ADMIN}}"
GRUPO_ADMIN_AD="{{GRUPO_ADMIN_AD}}"
GRUPO_ADMIN_LINUX="{{GRUPO_ADMIN_LINUX}}"
GRUPO_DASTI="{{GRUPO_DASTI}}"
AUTH_METHOD="{{AUTH_METHOD}}"
OFFLINE_AUTH_ENABLED="{{OFFLINE_AUTH_ENABLED}}"
OFFLINE_AUTH_DAYS="{{OFFLINE_AUTH_DAYS}}"

# Politicas de proxy (modelo multi-proxy)
APT_POLICY="${APT_POLICY}"
APT_PROXY_NAME="${APT_PROXY_NAME}"
CLI_POLICY="${CLI_POLICY}"
CLI_PROXY_NAME="${CLI_PROXY_NAME}"
BROWSER_POLICY="${BROWSER_POLICY}"
BROWSER_PROXY_NAME="${BROWSER_PROXY_NAME}"
MIRROR_LOCAL_SEEDER_PATH="${MIRROR_LOCAL_SEEDER_PATH}"
MIRROR_LOCAL_OM_URL="${MIRROR_LOCAL_OM_URL}"

# URLs e Servidores
BASE_URL="{{BASE_URL}}"
HOMEPAGE="{{HOMEPAGE}}"
OCS_SERVER="{{OCS_SERVER}}"
OCS_TAG="{{OCS_TAG}}"
GLPI_SERVER="{{GLPI_SERVER}}"
PRINT_SERVER="{{PRINT_SERVER}}"
SERVIDOR_ARQUIVOS="{{SERVIDOR_ARQUIVOS}}"

# Identidade Visual
OM_ACRONYM="{{OM_ACRONYM}}"
OM_NAME="{{OM_NAME}}"
DISPLAY_NAME="{{DISPLAY_NAME}}"
WALLPAPER_URL="${WALLPAPER_URL}"
WALLPAPER_LOGIN_URL="${WALLPAPER_LOGIN_URL}"
LOGO_URL="${LOGO_URL}"
GREETER_URL="${GREETER_URL}"
THEME="{{THEME}}"

# Ambiente Grafico
DESKTOP_ENV="{{DESKTOP_ENV}}"
DISPLAY_MANAGER="{{DISPLAY_MANAGER}}"

# Aplicacoes e Funcionalidades
INSTALL_ONLYOFFICE="{{INSTALL_ONLYOFFICE}}"
INSTALL_CHROME="{{INSTALL_CHROME}}"
INSTALL_CHROMIUM="{{INSTALL_CHROMIUM}}"
INSTALL_JAVA8="{{INSTALL_JAVA8}}"
INSTALL_FIREFOX52="{{INSTALL_FIREFOX52}}"
VNC_ENABLED="{{VNC_ENABLED}}"
INVENTORY_ENABLED="{{INVENTORY_ENABLED}}"

# Repositorios
REPOSITORY_MODE="{{REPOSITORY_MODE}}"
REPOSITORY_URL="{{REPOSITORY_URL}}"
REPOSITORY_FALLBACK="{{REPOSITORY_FALLBACK}}"

# Compartilhamentos e Impressoras
COMPARTILHAMENTOS="{{COMPARTILHAMENTOS}}"
MOUNT_BASE="{{MOUNT_BASE}}"
DEFAULT_PRINTER="{{DEFAULT_PRINTER}}"
PRINTERS="{{PRINTERS}}"

# Acesso Remoto
REMOTE_METHOD="{{REMOTE_METHOD}}"
SSH_PORT="{{SSH_PORT}}"
SSH_GROUPS="{{SSH_GROUPS}}"

# Certificados
CERTIFICATE_BUNDLE="{{CERTIFICATE_BUNDLE}}"
CERTIFICATE_AUTO_INSTALL="{{CERTIFICATE_AUTO_INSTALL}}"

# Conky
CONKY_PROFILE="{{CONKY_PROFILE}}"
CONKY_CONFIG='{{CONKY_CONFIG}}'

# Servidor SeederLinux
SEEDER_SERVER="${SEEDER_SERVER}"
EOF

# ============================================================
# Anexar array de proxies (sem senhas - vao em secrets.env)
# ============================================================
{
    echo ""
    echo "# Array de proxies da OM (senhas em secrets.env)"
    echo "PROXY_COUNT=\"${PROXY_COUNT}\""
    echo "PROXY_DEFAULT_NAME=\"${PROXY_DEFAULT_NAME}\""
    echo ""

    i=1
    while [ "$i" -le "$PROXY_COUNT" ] 2>/dev/null; do
        v_name="PROXY_${i}_NAME"
        v_url="PROXY_${i}_URL"
        v_user="PROXY_${i}_USER"
        v_pac="PROXY_${i}_PAC_URL"
        v_no_proxy="PROXY_${i}_NO_PROXY"

        # Escapar valores entre aspas duplas (\ e ")
        name_v="$(printf '%s' "${!v_name}" | sed 's/\\/\\\\/g; s/"/\\"/g')"
        url_v="$(printf '%s' "${!v_url}"  | sed 's/\\/\\\\/g; s/"/\\"/g')"
        user_v="$(printf '%s' "${!v_user}" | sed 's/\\/\\\\/g; s/"/\\"/g')"
        pac_v="$(printf '%s' "${!v_pac}" | sed 's/\\/\\\\/g; s/"/\\"/g')"
        no_proxy_v="$(printf '%s' "${!v_no_proxy}" | sed 's/\\/\\\\/g; s/"/\\"/g')"

        echo "PROXY_${i}_NAME=\"${name_v}\""
        echo "PROXY_${i}_URL=\"${url_v}\""
        echo "PROXY_${i}_USER=\"${user_v}\""
        echo "PROXY_${i}_PAC_URL=\"${pac_v}\""
        echo "PROXY_${i}_NO_PROXY=\"${no_proxy_v}\""
        i=$((i+1))
    done

    echo ""
    echo "# Estado local (GPO) - progresso desta estacao"
    echo "SERIAL_APLICADO=\"${SERIAL_APLICADO_ATUAL}\""
} >> "$CONFIG_FILE"

chmod 644 "$CONFIG_FILE"
echo ">>> config.env gravado em $CONFIG_FILE"

# ============================================================
# Atualizar secrets.env com as senhas dos proxies
# ============================================================
# Preserva o que ja existe (VNC_PASSWORD_SET etc), so substitui as
# linhas PROXY_K_PASS. Arquivo criado com perm 600.
TMP_SECRETS="$(mktemp /tmp/seeder-secrets.XXXXXX)"

if [ -f "$SECRETS_FILE" ]; then
    grep -v '^PROXY_[0-9]\+_PASS=' "$SECRETS_FILE" > "$TMP_SECRETS" 2>/dev/null || : > "$TMP_SECRETS"
else
    : > "$TMP_SECRETS"
fi

i=1
while [ "$i" -le "$PROXY_COUNT" ] 2>/dev/null; do
    v_pass_b64="PROXY_${i}_PASS_B64"
    pass_b64="${!v_pass_b64}"
    pass=""
    if [ -n "$pass_b64" ]; then
        pass="$(printf '%s' "$pass_b64" | base64 -d 2>/dev/null)" || pass=""
    fi
    # Usa printf %q do bash para escape shell-safe
    pass_escaped="$(printf '%q' "$pass")"
    printf 'PROXY_%d_PASS=%s\n' "$i" "$pass_escaped" >> "$TMP_SECRETS"
    i=$((i+1))
done

install -m 0600 "$TMP_SECRETS" "$SECRETS_FILE"
rm -f "$TMP_SECRETS"

echo ">>> secrets.env atualizado (${PROXY_COUNT} senha(s) de proxy)"
echo ">>> [13.5] Arquivo de configuracao criado!"
echo "============================================================"
