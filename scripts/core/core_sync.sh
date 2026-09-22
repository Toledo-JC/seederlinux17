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
# CORRECOES NESTA VERSAO:
#   1. sync_conky passa a REGERAR o /etc/seederlinux/conky/conky.conf
#      a partir do CONKY_CONFIG do config.env, e a REINICIAR o processo
#      do usuario quando o arquivo muda. Antes, o modulo so verificava
#      se o conky estava rodando - mudar "position" no painel nunca
#      chegava na estacao, mesmo com bundle novo e reboot. Esta era a
#      causa raiz do "conky continua embaixo mesmo depois de trocar".
#   2. _prefixar_seeder_url helper global: URLs relativas de assets
#      ("/assets/wallpapers/xxx.jpg") sao prefixadas com SEEDER_SERVER
#      antes do wget. Isso e' defesa em profundidade - o core_config.sh
#      ja corrigiu a origem gravando URLs absolutas, mas estacoes
#      provisionadas com bundle ANTIGO ainda tem URLs relativas no
#      config.env. Este fix faz o sync funcionar nelas.
#   3. _baixar_ativo (dentro de sync_branding) e sync_certificates
#      usam _prefixar_seeder_url antes do wget.
#   4. sync_conky agora cobre todos os DEs com suporte a autostart
#      (cinnamon, mate, gnome, xfce, kde, lxde, lxqt) - antes so
#      cinnamon|mate eram tratados, deixando usuarios de outros DEs
#      com conky "morto" (autostart dispara 1x no login, mas o sync
#      nunca reiniciava se o usuario fechasse acidentalmente).
#   5. launcher /usr/local/bin/seederlinux-conky reescrito a cada
#      ciclo com install -m 0755 (idempotente, autocorrige chmod).
#
# LIMITACAO CONHECIDA: os modulos de impressoras (fila/protocolo
# completo) e certificados aqui sao um subconjunto simplificado.
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
# Helper global: prefixar URL relativa com SEEDER_SERVER
# ============================================================
# Regra:
#   - Vazio -> retorna vazio
#   - Ja absoluta (http:// ou https://host/...) -> mantem
#   - Relativa ("/assets/...") -> prefixa com SEEDER_SERVER
#   - SEEDER_SERVER vazio -> retorna como veio (deixa o wget falhar
#     com erro claro em vez de gravar algo quebrado)
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

# ============================================================
# Helper global: ler chave de um JSON com fallback
# (usado pelo sync_conky para parsear CONKY_CONFIG)
# ============================================================
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

# ============================================================
# MODULO: branding (wallpaper, logo, tema via dconf/xfconf/kde)
#
# CORRECOES (mesmas aplicadas no core_branding.sh):
#   - _baixar_ativo usa `install -m 0644` em vez de `mv` e valida
#     MIME `image/*` alem do tamanho. Causa raiz da tela preta: o
#     `mv` de um arquivo criado por `mktemp` (0600) preservava o
#     modo restritivo, e o greeter do LightDM (usuario `lightdm`)
#     tomava EACCES ao tentar ler o wallpaper.
#   - chmod 0755 no diretorio a cada ciclo, para autocorrigir se
#     algo externo mudou o modo (evita greeter sem acesso ao dir).
#   - fallback wallpaper-login.jpg <- wallpaper.jpg quando o
#     primeiro nao existe (URL vazia, download falho, HTML de erro).
#   - reaplica config do greeter (LightDM/GDM3/SDDM). Antes o sync
#     nao tocava nisso - so o core_branding.sh na Fase 1 fazia, o
#     que contraria a filosofia GPO "reaplicar tudo".
#   - chmod 0644 nos arquivos de wallpaper por usuario (xfce/kde/
#     lxde), que antes herdavam umask do root no `cat >`.
#   - NOVO: _baixar_ativo agora prefixa URLs relativas com
#     SEEDER_SERVER via _prefixar_seeder_url. Protege estacoes que
#     foram provisionadas com bundle antigo (URL relativa no
#     config.env).
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
            echo "AVISO: falha de download de $(basename "$dest") ($url) - mantendo o existente"
            return 1
        fi

        if [ ! -s "$tmp" ]; then
            rm -f "$tmp"
            echo "AVISO: $(basename "$dest") baixou 0 bytes (404/proxy/DNS?) - mantendo o existente"
            return 1
        fi

        # Validacao de tipo: aceita apenas image/*. Se o servidor
        # devolver HTML de erro (proxy 407, 404 estilizado, portal
        # cativo), o arquivo tem bytes mas nao e' imagem.
        local mime
        mime="$(file -b --mime-type "$tmp" 2>/dev/null || echo "application/octet-stream")"
        if ! echo "$mime" | grep -q '^image/'; then
            rm -f "$tmp"
            echo "AVISO: $(basename "$dest") baixou $mime (nao e imagem - HTML de erro?) - mantendo o existente"
            return 1
        fi

        install -m 0644 "$tmp" "$dest"
        rm -f "$tmp"
        echo "OK: $(basename "$dest") ($mime)"
        return 0
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

    # Fallback do wallpaper de login: se nao existe no disco mas o
    # da sessao existe, copia por cima. Greeter nunca fica preto.
    local LOGIN_WP="/usr/share/backgrounds/seederlinux/wallpaper-login.jpg"
    local SESSION_WP="/usr/share/backgrounds/seederlinux/wallpaper.jpg"
    if [ ! -s "$LOGIN_WP" ] && [ -s "$SESSION_WP" ]; then
        install -m 0644 "$SESSION_WP" "$LOGIN_WP"
        echo "OK: wallpaper-login.jpg (fallback do wallpaper de sessao)"
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

[org/cinnamon/theme]
name='${THEME}'
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
picture-uri-dark='file:///usr/share/backgrounds/seederlinux/wallpaper.jpg'
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
                # chmod antes do chown: garante modo consistente
                # independente do umask corrente do sync (roda como root).
                chmod 0644 "$uh/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml" 2>/dev/null || true
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
                chmod 0644 "$uh/.config/plasma-org.kde.plasma.desktop-appletsrc" 2>/dev/null || true
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
                chmod 0644 "$uh/.config/pcmanfm/LXDE/desktop-items-0.conf" 2>/dev/null || true
                chown "$u:$u" "$uh/.config/pcmanfm/LXDE/desktop-items-0.conf" 2>/dev/null || true
            done
            ;;
    esac

    # --------------------------------------------------------
    # Reaplica config do greeter (wallpaper de login).
    # O sync roda a cada 10min; se alguem editar/corromper a config
    # do greeter, ela volta ao estado da OM no proximo ciclo.
    # Lightdm le o arquivo como usuario `lightdm` (uid 113) - por
    # isso chmod 0644 explicito.
    # --------------------------------------------------------
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
                if [ "$THEME_APLICAR" = "true" ]; then
                    echo "theme-name=${THEME}" >> /etc/lightdm/lightdm-gtk-greeter.conf
                fi
                chmod 0644 /etc/lightdm/lightdm-gtk-greeter.conf
                echo "OK: lightdm-gtk-greeter.conf reaplicado"
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
                echo "OK: GDM3 background reaplicado"
            fi
            ;;
        sddm)
            if [ -s "$LOGIN_WP" ]; then
                mkdir -p /etc/sddm.conf.d
                cat > /etc/sddm.conf.d/seederlinux.conf <<EOF
[Theme]
ThemeDir=/usr/share/sddm/themes
Current=seederlinux
Background=${LOGIN_WP}
EOF
                echo "OK: SDDM background reaplicado"
            fi
            ;;
    esac

    # Sumario dos assets no log do sync (observabilidade)
    if [ -d /usr/share/backgrounds/seederlinux ]; then
        echo "Assets em /usr/share/backgrounds/seederlinux:"
        ls -la /usr/share/backgrounds/seederlinux/ 2>/dev/null | sed 's/^/    /'
    fi
}

# ============================================================
# MODULO: politica do Firefox
#
# CONFIRMADO/ALINHADO contra o core_browser.sh real: o caminho
# canonico e /usr/lib/firefox-esr/distribution/policies.json
# (instalacao do pacote Debian/Ubuntu). Mantemos tambem
# /etc/firefox*/policies/ como cobertura extra para builds que
# suportem esse local alternativo.
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
# TelemetryReportingEnabled etc.).
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
# CONFIRMADO contra o core_printers.sh real: a convencao de fila
# ipp://PRINT_SERVER/printers/NOME + `-m everywhere` esta correta.
# Este modulo tambem reaplica a config do daemon CUPS
# (cupsd.conf/client.conf/cupsctl) e a descoberta automatica quando
# PRINTERS vem vazio.
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
# MODULO: Conky
#
# REGERENCIA o /etc/seederlinux/conky/conky.conf a partir do
# CONKY_CONFIG do config.env. Compara com o que ja esta no disco e
# so reescreve se mudou. Se mudou, REINICIA o conky dos usuarios com
# sessao grafica (senao a mudanca nao aparece ate relogar).
#
# Antes, este modulo so fazia `pgrep conky || start` - nunca regerava
# o arquivo. Era a causa raiz do "mudei a posicao no painel e nao
# aplica nem com reboot".
#
# Restricao de DE: qualquer DE onde o core_conky.sh instalou
# autostart (cinnamon, mate, gnome, xfce, kde, lxde, lxqt).
# ============================================================
sync_conky() {
    echo "--- conky ---"

    command -v conky &>/dev/null || { echo "AVISO: Conky nao instalado, pulando modulo"; return 0; }
    command -v jq &>/dev/null || { echo "AVISO: jq nao instalado, pulando modulo de conky"; return 0; }
    [ -z "${CONKY_CONFIG:-}" ] && { echo "CONKY_CONFIG vazio, pulando modulo de conky"; return 0; }

    case "$DESKTOP_ENV" in
        cinnamon|mate|gnome|xfce|kde|lxde|lxqt) ;;
        *) echo "DESKTOP_ENV='$DESKTOP_ENV' nao suportado pelo modulo conky, pulando"; return 0 ;;
    esac

    # --- Parse do JSON (mesmos defaults do core_conky.sh) ---
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

    # --- Montar CONKY_TEXT (mesma logica do core_conky.sh) ---
    local CONKY_TEXT
    if [ "$CFG_SHOW_HOSTNAME" = "true" ]; then
        CONKY_TEXT="\${font DejaVu Sans Mono:size=${CFG_HOSTNAME_FONT_SIZE}}\${color ${COLOR_TEXT_LUA}}Host: \${nodename}
\${font DejaVu Sans Mono:size=${CFG_FONT_SIZE}}
\${color ${COLOR_TEXT_LUA}}${OM_ACRONYM:-} - ${OM_NAME:-}
\${color ${COLOR_TEXT_LUA}}\${hr}"
    else
        CONKY_TEXT="\${color ${COLOR_TEXT_LUA}}${OM_ACRONYM:-} - ${OM_NAME:-}
\${color ${COLOR_TEXT_LUA}}\${hr}"
    fi

    CONKY_TEXT="${CONKY_TEXT}
\${color ${COLOR_TEXT_LUA}}Uptime: \${color grey}\${uptime}
\${color ${COLOR_TEXT_LUA}}\${hr}"

    if [ "$CFG_SHOW_CPU" = "true" ]; then
        CONKY_TEXT="${CONKY_TEXT}
\${color ${COLOR_TEXT_LUA}}CPU:  \${color grey}\${cpu}% \${cpubar 4}"
    fi
    if [ "$CFG_SHOW_RAM" = "true" ]; then
        CONKY_TEXT="${CONKY_TEXT}
\${color ${COLOR_TEXT_LUA}}RAM:  \${color grey}\${mem}/\${memmax} \${membar 4}
\${color ${COLOR_TEXT_LUA}}SWAP: \${color grey}\${swap}/\${swapmax} \${swapbar 4}"
    fi
    if [ "$CFG_SHOW_DISK" = "true" ]; then
        CONKY_TEXT="${CONKY_TEXT}
\${color ${COLOR_TEXT_LUA}}Disco (${CFG_DISK_PARTITION}): \${color grey}\${fs_used ${CFG_DISK_PARTITION}}/\${fs_size ${CFG_DISK_PARTITION}} \${fs_bar 6 ${CFG_DISK_PARTITION}}"
    fi
    if [ "$CFG_SHOW_NETWORK" = "true" ]; then
        CONKY_TEXT="${CONKY_TEXT}
\${color ${COLOR_TEXT_LUA}}Rede (${CFG_NETWORK_IFACE}):
\${color ${COLOR_TEXT_LUA}}IP:   \${color grey}\${addr ${CFG_NETWORK_IFACE}}
\${color ${COLOR_TEXT_LUA}}Down: \${color grey}\${downspeed ${CFG_NETWORK_IFACE}}
\${color ${COLOR_TEXT_LUA}}Up:   \${color grey}\${upspeed ${CFG_NETWORK_IFACE}}"
    fi
    if [ "$CFG_SHOW_TOP" = "true" ]; then
        CONKY_TEXT="${CONKY_TEXT}
\${color ${COLOR_TEXT_LUA}}\${hr}
\${color ${COLOR_TEXT_LUA}}Top CPU:
\${color grey}\${top name 1} \${top cpu 1}%
\${color grey}\${top name 2} \${top cpu 2}%
\${color grey}\${top name 3} \${top cpu 3}%"
    fi
    if [ "$CFG_SHOW_DATETIME" = "true" ]; then
        CONKY_TEXT="${CONKY_TEXT}
\${color ${COLOR_TEXT_LUA}}\${hr}
\${color ${COLOR_TEXT_LUA}}\${time %A, %d/%m/%Y %H:%M:%S}"
    fi

    # --- Montar conteudo NOVO num tmp, comparar com o atual ---
    local CONKY_DIR="/etc/seederlinux/conky"
    local CONKY_CONF="$CONKY_DIR/conky.conf"
    local NEW_CONF
    NEW_CONF="$(mktemp /tmp/seeder-conky.XXXXXX)"

    cat > "$NEW_CONF" <<EOF
-- Configuracao Conky - SeederLinux (gerada dinamicamente)
-- Perfil: ${CONKY_PROFILE:-default}

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
${CONKY_TEXT}
]]
EOF

    mkdir -p "$CONKY_DIR"
    local CONF_CHANGED=false
    if [ ! -f "$CONKY_CONF" ] || ! cmp -s "$NEW_CONF" "$CONKY_CONF"; then
        install -m 0644 "$NEW_CONF" "$CONKY_CONF"
        CONF_CHANGED=true
        echo "OK: conky.conf regravado (config mudou)"
    else
        echo "OK: conky.conf ja em dia (sem mudancas)"
    fi
    rm -f "$NEW_CONF"

    # --- Garantir launcher /usr/local/bin/seederlinux-conky ---
    install -m 0755 /dev/stdin /usr/local/bin/seederlinux-conky <<'LAUNCHER'
#!/bin/bash
CONKY_CONF="/etc/seederlinux/conky/conky.conf"
sleep 3
if [ -f "$CONKY_CONF" ]; then
    killall conky 2>/dev/null || true
    conky -c "$CONKY_CONF" &
else
    echo "Configuracao do Conky nao encontrada: $CONKY_CONF"
fi
LAUNCHER

    # --- Para cada usuario com sessao grafica ---
    # Se a config mudou: mata o conky existente e reinicia (pega novo).
    # Se nao mudou e nao esta rodando: inicia.
    local u
    for u in $(usuarios_com_sessao_grafica); do
        if [ "$CONF_CHANGED" = "true" ]; then
            su - "$u" -c "pkill -u '$u' conky 2>/dev/null; sleep 1; DISPLAY=:0 /usr/local/bin/seederlinux-conky" 2>/dev/null &
            echo "OK: conky reiniciado para $u (config mudou)"
        else
            if ! pgrep -u "$u" conky &>/dev/null; then
                su - "$u" -c "DISPLAY=:0 /usr/local/bin/seederlinux-conky" 2>/dev/null &
                echo "OK: conky iniciado para $u (nao estava rodando)"
            else
                echo "OK: conky ja rodando para $u (sem mudancas)"
            fi
        fi
    done
}

# ============================================================
# MODULO: compartilhamentos CIFS - remonta para sessoes ativas que
# eventualmente cairam, sem esperar um novo login
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
#
# NOVO: aplica _prefixar_seeder_url antes do wget, mesma defesa em
# profundidade do modulo de branding.
# ============================================================
sync_certificates() {
    echo "--- certificados ---"
    [ "${CERTIFICATE_AUTO_INSTALL:-}" = "true" ] || { echo "CERTIFICATE_AUTO_INSTALL != true, pulando"; return 0; }
    [ -z "${CERTIFICATE_BUNDLE:-}" ] && { echo "CERTIFICATE_BUNDLE vazio, pulando"; return 0; }

    local CERT_URL
    CERT_URL="$(_prefixar_seeder_url "$CERTIFICATE_BUNDLE")"

    CERT_TMP="/tmp/seederlinux-cert-bundle"
    CERT_DEST_DIR="/usr/local/share/ca-certificates/seederlinux"
    mkdir -p "$CERT_DEST_DIR"

    if ! wget -q --no-check-certificate --timeout=20 -O "$CERT_TMP" "$CERT_URL" 2>/dev/null; then
        echo "AVISO: falha ao baixar CERTIFICATE_BUNDLE de $CERT_URL"
        return 0
    fi

    if [ ! -s "$CERT_TMP" ]; then
        echo "AVISO: CERTIFICATE_BUNDLE baixou 0 bytes - descartado"
        rm -f "$CERT_TMP"
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
