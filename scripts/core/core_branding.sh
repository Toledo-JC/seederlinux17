#!/bin/bash
# ============================================================================
# Core Script: core_branding.sh
# SeederLinux Lite - Wallpaper, logo, tema (varia por DE)
# ============================================================================
# Aplica identidade visual da OM: wallpaper, logo, tema GTK e configuracoes
# de aparencia. Varia conforme o ambiente grafico (DE).
# Os placeholders VARIAVEL são substituídos automaticamente
# pelo sistema na geração do bundle.
# ============================================================================

set -e

# CORRECAO: script envolvido em subshell - uma falha aqui (ex: asset
# externo que nao baixa/extrai direito) nao pode mais derrubar o
# bundle inteiro, so este modulo.
(
set -e

echo "============================================================"
echo "13 - Aplicar identidade visual (branding)"
echo "============================================================"

# ============================================================
# Variáveis
# ============================================================
OM_ACRONYM="{{OM_ACRONYM}}"
OM_NAME="{{OM_NAME}}"
DISPLAY_NAME="{{DISPLAY_NAME}}"
WALLPAPER_URL="{{WALLPAPER_URL}}"
WALLPAPER_LOGIN_URL="{{WALLPAPER_LOGIN_URL}}"
LOGO_URL="{{LOGO_URL}}"
GREETER_URL="{{GREETER_URL}}"
THEME="{{THEME}}"
DESKTOP_ENV="{{DESKTOP_ENV}}"
DISPLAY_MANAGER="{{DISPLAY_MANAGER}}"
SEEDER_SERVER="{{SEEDER_SERVER}}"

# ============================================================
# Prefixar URLs de assets com SEEDER_SERVER quando relativas
# ============================================================
for url_var in WALLPAPER_URL WALLPAPER_LOGIN_URL LOGO_URL GREETER_URL; do
    url_val="${!url_var}"
    if [ -n "$url_val" ] && [ "$url_val" != "" ]; then
        if echo "$url_val" | grep -qE '^https?://[^/]+/'; then
            continue
        fi
        server_clean="${SEEDER_SERVER%/}"
        if echo "$url_val" | grep -q '^/'; then
            eval "${url_var}=\"${server_clean}${url_val}\""
        else
            eval "${url_var}=\"${server_clean}/${url_val}\""
        fi
    fi
done

# ============================================================
# Detectar ambiente grafico se nao definido
# ============================================================
if [ -z "$DESKTOP_ENV" ] || [ "$DESKTOP_ENV" = "" ]; then
    if command -v cinnamon-session &>/dev/null; then DESKTOP_ENV="cinnamon"
    elif command -v mate-session &>/dev/null; then DESKTOP_ENV="mate"
    elif command -v gnome-session &>/dev/null; then DESKTOP_ENV="gnome"
    elif command -v startxfce4 &>/dev/null; then DESKTOP_ENV="xfce"
    elif command -v startplasma-x11 &>/dev/null; then DESKTOP_ENV="kde"
    elif command -v lxqt-session &>/dev/null; then DESKTOP_ENV="lxqt"
    elif command -v startlxde &>/dev/null; then DESKTOP_ENV="lxde"
    else DESKTOP_ENV="unknown"
    fi
fi
echo ">>> Ambiente detectado: $DESKTOP_ENV"

# ============================================================
# Detectar display manager se nao definido
# ============================================================
if [ -z "$DISPLAY_MANAGER" ] || [ "$DISPLAY_MANAGER" = "" ]; then
    if systemctl is-active --quiet lightdm 2>/dev/null; then DISPLAY_MANAGER="lightdm"
    elif systemctl is-active --quiet gdm3 2>/dev/null; then DISPLAY_MANAGER="gdm3"
    elif systemctl is-active --quiet sddm 2>/dev/null; then DISPLAY_MANAGER="sddm"
    elif [ -f /etc/X11/default-display-manager ]; then
        DISPLAY_MANAGER="$(basename "$(cat /etc/X11/default-display-manager)")"
    else DISPLAY_MANAGER="unknown"
    fi
fi
echo ">>> Display Manager detectado: $DISPLAY_MANAGER"

echo ">>> OM: $OM_ACRONYM - $OM_NAME"
echo ">>> Ambiente: $DESKTOP_ENV / $DISPLAY_MANAGER"
echo ">>> Tema: $THEME"

# ============================================================
# Criar diretorios de branding
# ============================================================
mkdir -p /usr/share/seederlinux/branding
mkdir -p /usr/share/backgrounds/seederlinux
mkdir -p /usr/share/pixmaps

# ============================================================
# Garantir perfil dconf "user" com o banco system-db:local incluido.
# Sem isso, TUDO que escrevemos em /etc/dconf/db/local.d/ (GNOME,
# Cinnamon, MATE) e ignorado pelos usuarios - dconf so aplica um
# banco de sistema se o perfil do usuario listar explicitamente
# "system-db:<nome>". Alguns pacotes de DE ja criam isso no
# postinst, mas nao e garantido em toda combinacao de distro/DE -
# entao garantimos aqui de forma idempotente.
# ============================================================
mkdir -p /etc/dconf/profile
if [ ! -f /etc/dconf/profile/user ]; then
    cat > /etc/dconf/profile/user <<EOF
user-db:user
system-db:local
EOF
elif ! grep -q "^system-db:local$" /etc/dconf/profile/user; then
    echo "system-db:local" >> /etc/dconf/profile/user
fi

# ============================================================
# Baixar e instalar wallpaper
# ============================================================
echo ">>> Baixando wallpaper..."
if [ -n "$WALLPAPER_URL" ] && [ "$WALLPAPER_URL" != "" ]; then
    if wget -q --no-check-certificate --no-proxy -O /usr/share/backgrounds/seederlinux/wallpaper.jpg "$WALLPAPER_URL"; then
        echo ">>> Wallpaper instalado"
    else
        echo ">>> AVISO: Falha ao baixar wallpaper de: $WALLPAPER_URL"
    fi
else
    echo ">>> WALLPAPER_URL nao definido. Pulando wallpaper."
fi

# ============================================================
# Baixar e instalar wallpaper de login
# ============================================================
echo ">>> Baixando wallpaper de login..."
if [ -n "$WALLPAPER_LOGIN_URL" ] && [ "$WALLPAPER_LOGIN_URL" != "" ]; then
    if wget -q --no-check-certificate --no-proxy -O /usr/share/backgrounds/seederlinux/wallpaper-login.jpg "$WALLPAPER_LOGIN_URL"; then
        echo ">>> Wallpaper de login instalado"
    else
        echo ">>> AVISO: Falha ao baixar wallpaper de login"
    fi
fi

# ============================================================
# Baixar e instalar logo
# ============================================================
echo ">>> Baixando logo..."
if [ -n "$LOGO_URL" ] && [ "$LOGO_URL" != "" ]; then
    if wget -q --no-check-certificate --no-proxy -O /usr/share/pixmaps/seederlinux-logo.png "$LOGO_URL"; then
        echo ">>> Logo instalado"
    else
        echo ">>> AVISO: Falha ao baixar logo"
    fi
fi

# ============================================================
# Baixar e instalar greeter personalizado
# ============================================================
# GREETER_URL pode ser:
#   - um pacote compactado (tar/gzip/bzip2/xz) com tema de greeter
#     personalizado, OU
#   - uma imagem (.jpg, .jpeg, .png, .bmp, .gif, .webp, .tif, ...)
#     que sera usada como wallpaper de login.
#
# Deteccao por conteudo (MIME type via magic bytes), NAO por
# extensao do arquivo - funciona com qualquer formato, mesmo que o
# nome/extensao esteja errado. Corrige o achado em teste real (Linux
# Mint Cinnamon): GREETER_URL apontando pra .jpg fazia `tar xzf`
# falhar e, como este script nao estava em subshell, derrubava o
# bundle inteiro. Agora, alem de nao travar mais nada, a imagem e
# de fato aproveitada em vez de descartada.
# ============================================================
echo ">>> Baixando greeter..."
if [ -n "$GREETER_URL" ] && [ "$GREETER_URL" != "" ]; then
    GREETER_TARBALL="/tmp/seederlinux-greeter.bin"
    if wget -q --no-check-certificate --no-proxy -O "$GREETER_TARBALL" "$GREETER_URL"; then
        GREETER_MIME="$(file -b --mime-type "$GREETER_TARBALL" 2>/dev/null)"
        echo ">>> Greeter detectado como: ${GREETER_MIME:-desconhecido}"

        case "$GREETER_MIME" in
            # --- Caso 1: arquivo compactado (tar/gzip/bzip2/xz) ---
            application/gzip|application/x-gzip|application/x-tar|\
            application/x-bzip2|application/x-xz|application/octet-stream)
                # octet-stream e ambiguo - confirmar via file -b (magic)
                GREETER_FILETYPE="$(file -b "$GREETER_TARBALL" 2>/dev/null)"
                if echo "$GREETER_FILETYPE" | grep -qiE 'gzip|tar|bzip2|xz'; then
                    mkdir -p /tmp/seederlinux-greeter
                    if tar xf "$GREETER_TARBALL" -C /tmp/seederlinux-greeter 2>/dev/null; then
                        case "$DISPLAY_MANAGER" in
                            lightdm)
                                cp -r /tmp/seederlinux-greeter/* /usr/share/lightdm/ 2>/dev/null || true
                                ;;
                            gdm3)
                                cp -r /tmp/seederlinux-greeter/* /usr/share/gdm/ 2>/dev/null || true
                                ;;
                            sddm)
                                cp -r /tmp/seederlinux-greeter/* /usr/share/sddm/themes/ 2>/dev/null || true
                                ;;
                        esac
                        echo ">>> Greeter (pacote) instalado"
                    else
                        echo ">>> AVISO: falha ao extrair o pacote do greeter."
                    fi
                    rm -rf /tmp/seederlinux-greeter
                else
                    echo ">>> AVISO: conteudo nao reconhecido como tar/gzip/bzip2/xz."
                fi
                ;;

            # --- Caso 2: qualquer imagem ---
            image/*)
                GREETER_EXT="${GREETER_MIME#image/}"
                case "$GREETER_EXT" in
                    jpeg) GREETER_EXT="jpg" ;;
                    x-ms-bmp) GREETER_EXT="bmp" ;;
                    x-icon) GREETER_EXT="ico" ;;
                    svg+xml) GREETER_EXT="svg" ;;
                    x-portable-pixmap) GREETER_EXT="ppm" ;;
                    tiff) GREETER_EXT="tif" ;;
                esac
                GREETER_IMG="/usr/share/backgrounds/seederlinux/greeter.${GREETER_EXT}"
                cp "$GREETER_TARBALL" "$GREETER_IMG"
                echo ">>> Greeter (imagem ${GREETER_EXT}) instalado: $GREETER_IMG"

                # Se WALLPAPER_LOGIN_URL nao foi definido OU o arquivo
                # de wallpaper de login ainda nao existe, usar o
                # greeter como wallpaper de login. Copiado com nome
                # fixo wallpaper-login.jpg independente do formato
                # real - GTK/LightDM/GDM3/SDDM detectam o formato pelo
                # conteudo (magic bytes), nao pela extensao, entao
                # isso nao quebra a leitura. Ressalva: formatos menos
                # comuns (webp, svg) dependem do loader gdk-pixbuf
                # correspondente estar instalado na imagem do SO.
                if [ -z "$WALLPAPER_LOGIN_URL" ] || [ ! -f /usr/share/backgrounds/seederlinux/wallpaper-login.jpg ]; then
                    cp "$GREETER_TARBALL" /usr/share/backgrounds/seederlinux/wallpaper-login.jpg
                    echo ">>> Greeter usado como wallpaper de login"
                else
                    echo ">>> Wallpaper de login proprio ja instalado - greeter mantido apenas em $GREETER_IMG"
                fi
                ;;

            # --- Caso 3: qualquer outra coisa ---
            *)
                echo ">>> AVISO: GREETER_URL nao e imagem nem pacote compactado valido"
                echo ">>> (detectado como: ${GREETER_MIME:-desconhecido}). Pulando greeter customizado."
                ;;
        esac

        rm -f "$GREETER_TARBALL"
    else
        echo ">>> AVISO: Falha ao baixar greeter"
    fi
fi

# ============================================================
# ============================================================
# Aplicar tema GTK (SOMENTE se THEME foi definido explicitamente)
# ============================================================
# CORRECAO (achado em teste real): THEME="DEFAULT" (valor de fato
# configurado nas OMs) NAO e um tema GTK valido - "DEFAULT" nao
# existe em /usr/share/themes, entao gtk-theme-name=DEFAULT e
# simplesmente ignorado pelo GTK. Pior: theme-name=DEFAULT no
# greeter e ColorScheme=DEFAULT no KDE tambem nao fazem nada. Agora
# so aplicamos tema se THEME vier definido E existir de verdade em
# /usr/share/themes - caso contrario mantemos o tema atual do
# sistema/DE, sem sobrescrever nada.
echo ">>> Aplicando tema GTK: $THEME"
THEME_APLICAR=false

if [ -z "$THEME" ] || [ "$THEME" = "DEFAULT" ]; then
    echo ">>> THEME=DEFAULT (ou vazio) - mantendo tema atual do sistema."
elif [ -d "/usr/share/themes/$THEME" ]; then
    THEME_APLICAR=true
    echo ">>> THEME=$THEME - tema encontrado em /usr/share/themes."
else
    echo ">>> AVISO: THEME=$THEME nao existe em /usr/share/themes - mantendo tema atual."
fi

if [ "$THEME_APLICAR" = "true" ]; then
    mkdir -p /etc/skel/.config/gtk-3.0
    cat > /etc/skel/.config/gtk-3.0/settings.ini <<EOF
[Settings]
gtk-theme-name=${THEME}
gtk-icon-theme-name=Adwaita
gtk-font-name=DejaVu Sans 10
gtk-cursor-theme-name=Adwaita
gtk-cursor-theme-size=16
gtk-toolbar-style=GTK_TOOLBAR_BOTH
gtk-toolbar-icon-size=GTK_ICON_SIZE_LARGE_TOOLBAR
gtk-button-images=1
gtk-menu-images=1
gtk-application-prefer-dark-theme=0
EOF
    echo ">>> Tema GTK configurado: $THEME"
else
    echo ">>> Tema GTK NAO foi alterado (DEFAULT ou inexistente)."
fi

# ============================================================
# Aplicar wallpaper e configuracoes conforme o DE
# ============================================================
echo ">>> Aplicando configuracoes para: $DESKTOP_ENV"

case "$DESKTOP_ENV" in
    cinnamon)
        # CORRECAO: Cinnamon usa dconf (e um fork do GNOME), nao um
        # arquivo de configuracao solto. A versao anterior escrevia em
        # /etc/skel/.config/cinnamon-settings.conf, que o Cinnamon
        # nunca le - nao tinha efeito nenhum. Usar dconf keyfile igual
        # ao branch do GNOME, com sintaxe de caminho (barras), nao a
        # notacao com pontos do schema id.
        mkdir -p /etc/dconf/db/local.d
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
        # CORRECAO: mesmo problema do Cinnamon - MATE tambem usa dconf,
        # nao /etc/skel/.config/mate-background.conf (nunca lido).
        mkdir -p /etc/dconf/db/local.d
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
        # GNOME - via gsettings (dconf)
        mkdir -p /etc/dconf/db/local.d
        cat > /etc/dconf/db/local.d/seederlinux-branding <<EOF
[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/seederlinux/wallpaper.jpg'
picture-uri-dark='file:///usr/share/backgrounds/seederlinux/wallpaper.jpg'
picture-options='zoom'

[org/gnome/login-screen]
logo='/usr/share/pixmaps/seederlinux-logo.png'
EOF
        if [ "$THEME_APLICAR" = "true" ]; then
            cat >> /etc/dconf/db/local.d/seederlinux-branding <<EOF

[org/gnome/desktop/interface]
gtk-theme='${THEME}'
icon-theme='Adwaita'
EOF
        fi
        dconf update 2>/dev/null || true
        ;;

    xfce)
        # XFCE - via xfconf
        mkdir -p /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml
        cat > /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml <<EOF
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
        ;;

    kde)
        # KDE Plasma - via kdeglobals (SOMENTE se THEME_APLICAR)
        if [ "$THEME_APLICAR" = "true" ]; then
            mkdir -p /etc/skel/.config
            cat > /etc/skel/.config/kdeglobals <<EOF
[General]
ColorScheme=${THEME}
Name=${THEME}

[KDE]
widgetStyle=${THEME}
EOF
        fi
        # Wallpaper via plasma config (independe de tema)
        mkdir -p /etc/skel/.config
        cat > /etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc <<EOF
[Containments][1][Wallpaper][org.kde.image][General]
Image=file:///usr/share/backgrounds/seederlinux/wallpaper.jpg
EOF
        ;;

    lxde)
        # LXDE - via pcmanfm
        mkdir -p /etc/skel/.config/pcmanfm/LXDE
        cat > /etc/skel/.config/pcmanfm/LXDE/pcmanfm.conf <<EOF
[desktop]
wallpaper_mode=crop
wallpaper=/usr/share/backgrounds/seederlinux/wallpaper.jpg
EOF
        ;;
esac

# ============================================================
# Configurar wallpaper de login (greeter)
# CORRECAO: theme-name=${THEME} incondicional removido do LightDM -
# mesmo problema do THEME=DEFAULT explicado acima.
# ============================================================
echo ">>> Configurando wallpaper de login..."
case "$DISPLAY_MANAGER" in
    lightdm)
        mkdir -p /etc/lightdm
        if [ -f /usr/share/backgrounds/seederlinux/wallpaper-login.jpg ]; then
            cat > /etc/lightdm/lightdm-gtk-greeter.conf <<EOF
[greeter]
background=/usr/share/backgrounds/seederlinux/wallpaper-login.jpg
logo=/usr/share/pixmaps/seederlinux-logo.png
icon-theme-name=Adwaita
font-name=DejaVu Sans 10
EOF
            if [ "$THEME_APLICAR" = "true" ]; then
                echo "theme-name=${THEME}" >> /etc/lightdm/lightdm-gtk-greeter.conf
            fi
        fi
        ;;
    gdm3)
        if [ -f /usr/share/backgrounds/seederlinux/wallpaper-login.jpg ]; then
            # GDM3 usa dconf para configuracao
            mkdir -p /etc/dconf/db/gdm.d
            cat > /etc/dconf/db/gdm.d/01-seederlinux-background <<EOF
[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/seederlinux/wallpaper-login.jpg'
picture-options='zoom'
EOF
            dconf update 2>/dev/null || true
        fi
        ;;
    sddm)
        if [ -f /usr/share/backgrounds/seederlinux/wallpaper-login.jpg ]; then
            mkdir -p /etc/sddm.conf.d
            cat > /etc/sddm.conf.d/seederlinux.conf <<EOF
[Theme]
ThemeDir=/usr/share/sddm/themes
Current=seederlinux
Background=/usr/share/backgrounds/seederlinux/wallpaper-login.jpg
EOF
        fi
        ;;
esac

echo ">>> [13] Identidade visual aplicada!"
echo "============================================================"
)
