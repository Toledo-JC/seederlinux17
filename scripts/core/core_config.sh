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
# Variaveis sensiveis (senha VNC, usuario admin do AD) NAO sao escritas
# neste arquivo. Elas sao gravadas em /etc/seederlinux/secrets.env (perm 600)
# apenas pelo core_vnc.sh e core_domain.sh respectivamente.
#
# CORRECOES NESTA VERSAO:
#   1. URLs de assets (WALLPAPER_URL, WALLPAPER_LOGIN_URL, LOGO_URL,
#      GREETER_URL) sao NORMALIZADAS para forma ABSOLUTA antes de serem
#      gravadas no config.env. Antes, iam como caminho relativo
#      ("/assets/wallpapers/xxx.jpg"), o que quebrava o seeder-sync:
#      ele faz wget DIRETO com o valor lido do config.env, e wget nao
#      aceita URL sem scheme. Resultado pratico: trocar uma imagem no
#      painel nunca chegava na estacao - o sync falhava silenciosamente
#      a cada ciclo. O core_branding.sh prefixava internamente para uso
#      proprio, mas o que ficava gravado no config.env era o valor cru.
#   2. SEEDER_SERVER e BASE_URL passam a ser declaradas como variaveis
#      no topo (antes eram literais so no here-doc do config.env), para
#      que a normalizacao de URLs possa usa-las.
#   3. Removida a duplicacao do bloco "NTP_SERVER=${NTP_SERVER#http://}"
#      que aparecia duas vezes seguidas no script original (efeito
#      pratico zero, mas confundia leitura).
#   4. Comentario explicito sobre SERIAL_APLICADO no config.env gerado,
#      para deixar claro que o agente (nao o bundle) e' quem avanca o
#      serial apos o provisionamento completo.
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

# ============================================================
# Variaveis usadas na NORMALIZACAO (prefixacao de URLs)
# ============================================================
# Vem do backend com substituicao de placeholder. Sao usadas apenas
# aqui, para montar as URLs absolutas que vao para o config.env.
SEEDER_SERVER="{{SEEDER_SERVER}}"

# Normalizacao defensiva: se o backend devolver algo com barra no final,
# removemos para nao gerar "https://host//assets/...".
SEEDER_SERVER="${SEEDER_SERVER%/}"

# URLs de assets, recebidas como podem vir relativas ("/assets/...") ou
# absolutas ("https://host/assets/...").
WALLPAPER_URL="{{WALLPAPER_URL}}"
WALLPAPER_LOGIN_URL="{{WALLPAPER_LOGIN_URL}}"
LOGO_URL="{{LOGO_URL}}"
GREETER_URL="{{GREETER_URL}}"

# ============================================================
# Normalizacao de URLs: prefixar com SEEDER_SERVER quando relativa
# ============================================================
# Regra:
#   - Se a URL ja comeca com "http://" ou "https://", mantemos intacta.
#   - Se comeca com "/", e' relativa ao host do Seeder: prefixamos.
#   - Se nao comeca com "/" (ex: "assets/xxx.jpg"), tratamos como
#     relativa tambem e prefixamos com "/".
#   - Vazio continua vazio (o core_branding.sh e o sync lidam com isso).
#
# Sem essa normalizacao, o config.env fica com URL sem scheme, e o
# seeder-sync (que le direto daqui) falha no wget a cada 10min.
echo ">>> Normalizando URLs de assets para forma absoluta..."
for url_var in WALLPAPER_URL WALLPAPER_LOGIN_URL LOGO_URL GREETER_URL; do
    url_val="${!url_var}"

    # Vazio: nao mexe
    if [ -z "$url_val" ] || [ "$url_val" = "" ]; then
        continue
    fi

    # Ja e' absoluta: nao mexe
    if echo "$url_val" | grep -qE '^https?://[^/]+/'; then
        echo ">>>   $url_var: ja absoluta ($url_val)"
        continue
    fi

    # E' relativa: prefixa com SEEDER_SERVER
    if [ -z "$SEEDER_SERVER" ] || [ "$SEEDER_SERVER" = "" ]; then
        echo ">>>   AVISO: $url_var e' relativa ('$url_val') mas SEEDER_SERVER esta vazio."
        echo ">>>   Mantendo como esta (sera tratado pelo core_branding.sh se possivel)."
        continue
    fi

    if echo "$url_val" | grep -q '^/'; then
        eval "${url_var}=\"${SEEDER_SERVER}${url_val}\""
    else
        eval "${url_var}=\"${SEEDER_SERVER}/${url_val}\""
    fi
    echo ">>>   $url_var: ${url_val} -> ${!url_var}"
done

# ============================================================
# NTP_SERVER: remover protocolo se a OM cadastrou com http:// ou
# https:// (a OM as vezes cadastra "http://host" achando que e' URL;
# chrony/ntp esperam so hostname ou IP).
# ============================================================
NTP_SERVER="{{NTP_SERVER}}"
NTP_SERVER="${NTP_SERVER#http://}"
NTP_SERVER="${NTP_SERVER#https://}"

# ============================================================
# SERIAL_APLICADO — ESTADO LOCAL da estacao
# ============================================================
# E' o ultimo serial de configuracao que a estacao aplicou com sucesso,
# NAO um valor da OM. Se este script rodar de novo (bundle regenerado e
# reaplicado numa estacao ja provisionada), NAO podemos simplesmente
# sobrescrever com "0" de novo - isso faria a estacao "esquecer" que
# ja estava em dia, forcaria o seeder-sync a reaplicar tudo, e ainda
# faria o agente reenviar serial_applied=0 ao servidor no proximo
# check-in, o que resulta em update_available=true sempre, causando
# re-provisionamento em loop.
#
# Portanto: preservamos o valor existente se ja houver um no
# config.env. So usamos "0" na primeira geracao (estacao virgem, sem
# config.env ainda). Quem AVANCA o serial ao longo do tempo e' o
# seeder-sync (apos reaplicar as politicas com sucesso) ou o agente
# (apos rodar o bundle completo em estacao virgem).
# ============================================================
SERIAL_APLICADO_ATUAL="0"
if [ -f "$CONFIG_FILE" ]; then
    VALOR_EXISTENTE="$(grep -m1 '^SERIAL_APLICADO=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"')"
    [ -n "$VALOR_EXISTENTE" ] && SERIAL_APLICADO_ATUAL="$VALOR_EXISTENTE"
fi
echo ">>> SERIAL_APLICADO preservado: $SERIAL_APLICADO_ATUAL"

# ============================================================
# Escrever config.env
# ============================================================
# Todas as variaveis vem de placeholders substituidos pelo backend.
# As URLs ja foram normalizadas acima. SERIAL_APLICADO e' calculado
# localmente (preservando o valor existente).
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

# Rede e Proxy
PROXY_HTTP="{{PROXY_HTTP}}"
PROXY_PORTA="{{PROXY_PORTA}}"
PROXY_URL="{{PROXY_URL}}"
PROXY_MODE="{{PROXY_MODE}}"
PAC_URL="{{PAC_URL}}"
NO_PROXY="{{NO_PROXY}}"

# URLs e Servidores (URLs de assets em forma absoluta - ver comentario
# no topo do script sobre normalizacao)
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

# Aplicacoes e Funcionalidades (toggles individuais)
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

# Servidor SeederLinux (usado pelo agente Python e por consumidores
# que precisam montar URLs relativas)
SEEDER_SERVER="${SEEDER_SERVER}"

# Estado local (GPO) - NAO e uma variavel da OM, e o progresso desta
# estacao. Preservado entre regeneracoes do bundle (ver logica acima).
# O agente envia este valor ao servidor no check-in (serial_applied);
# o seeder-sync o avanca apos reaplicar as politicas.
SERIAL_APLICADO="${SERIAL_APLICADO_ATUAL}"
EOF

chmod 644 "$CONFIG_FILE"

echo ">>> Configuracao persistente gravada em $CONFIG_FILE"
echo ">>> [13.5] Arquivo de configuracao criado!"
echo "============================================================"
