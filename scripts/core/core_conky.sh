#!/bin/bash
# ============================================================================
# Core Script: core_conky.sh
# SeederLinux Lite - Conky (configuracao apenas)
# ============================================================================
# Configura o Conky para exibicao de informacoes do sistema no desktop,
# com perfil personalizavel. A instalacao de pacotes e feita no core_packages.sh.
# Os placeholders VARIAVEL sao substituidos automaticamente
# pelo sistema na geracao do bundle.
# ============================================================================

(
set -e

source /usr/local/lib/seederlinux/diag.sh 2>/dev/null || true
SCRIPT_ID="13-conky"

echo "============================================================"
echo "Configurar Conky"
echo "============================================================"

# ============================================================
# Variaveis
# ============================================================
CONKY_PROFILE="{{CONKY_PROFILE}}"
CONKY_CONFIG='{{CONKY_CONFIG}}'
DESKTOP_ENV="{{DESKTOP_ENV}}"
OM_ACRONYM="{{OM_ACRONYM}}"
OM_NAME="{{OM_NAME}}"

log_nivel INFO "Perfil Conky: $CONKY_PROFILE"
log_nivel INFO "Ambiente: $DESKTOP_ENV"

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

# ============================================================
# Verificar se o Conky foi instalado (no core_packages.sh)
# ============================================================
if ! command -v conky &>/dev/null; then
    log_nivel AVISO "Conky nao instalado. Pulando configuracao."
    log_nivel INFO "[09] Conky nao configurado (pacote ausente)."
    echo "============================================================"
    exit 0
fi

# ============================================================
# Parse do CONKY_CONFIG (JSON) com fallbacks
# ============================================================
parse_json() {
    local key="$1"
    local default="$2"
    local val
    val=$(echo "$CONKY_CONFIG" | jq -r "if has(\"${key}\") then .${key} else \"__UNSET__\" end" 2>/dev/null)
    if [ -z "$val" ] || [ "$val" = "null" ] || [ "$val" = "__UNSET__" ]; then
        echo "$default"
    else
        echo "$val"
    fi
}

CFG_POSITION=$(parse_json position "top_right")
CFG_TRANSPARENT=$(parse_json transparent "true")
CFG_COLOR_TEXT=$(parse_json color_text "#FFFFFF")
CFG_COLOR_BG=$(parse_json color_bg "#000000")
CFG_FONT_SIZE=$(parse_json font_size "10")
CFG_GAP_X=$(parse_json gap_x "10")
CFG_GAP_Y=$(parse_json gap_y "40")
CFG_UPDATE_INTERVAL=$(parse_json update_interval "1.0")
CFG_SHOW_CPU=$(parse_json show_cpu "true")
CFG_SHOW_RAM=$(parse_json show_ram "true")
CFG_SHOW_DISK=$(parse_json show_disk "true")
CFG_DISK_PARTITION=$(parse_json disk_partition "/")
CFG_SHOW_NETWORK=$(parse_json show_network "true")
CFG_NETWORK_IFACE=$(parse_json network_interface "eth0")

# Validar interface de rede: se a configurada nao existir, detectar
# a interface default do sistema. Evita ${addr eth0} falhar em
# estacoes com interface enp0s3, wlp2s0, etc.
if ! ip link show "$CFG_NETWORK_IFACE" &>/dev/null 2>&1; then
    DETECTED_IFACE="$(ip route 2>/dev/null | awk '/default/ {print $5; exit}')"
    if [ -n "$DETECTED_IFACE" ]; then
        log_nivel INFO "interface '$CFG_NETWORK_IFACE' nao existe, usando '$DETECTED_IFACE'"
        CFG_NETWORK_IFACE="$DETECTED_IFACE"
    fi
fi
CFG_SHOW_TOP=$(parse_json show_top_processes "true")
CFG_SHOW_DATETIME=$(parse_json show_datetime "true")
CFG_SHOW_HOSTNAME=$(parse_json show_hostname "true")
CFG_HOSTNAME_FONT_SIZE=$(parse_json font_size_hostname "14")

COLOR_TEXT_LUA="${CFG_COLOR_TEXT#\#}"
COLOR_BG_LUA="${CFG_COLOR_BG#\#}"

if [ "$CFG_TRANSPARENT" = "true" ]; then
    OWN_TRANSPARENT="true"
    OWN_ARGB_VALUE="0"
else
    OWN_TRANSPARENT="false"
    OWN_ARGB_VALUE="200"
fi

# ============================================================
# Criar diretorio de configuracao global
# ============================================================
mkdir -p /etc/seederlinux/conky

# ============================================================
# Gerar configuracao do Conky (usando CONKY_CONFIG JSON)
# ============================================================
log_nivel INFO "Gerando configuracao do Conky (CONKY_CONFIG=${CONKY_CONFIG:-vazio})..."

if [ "$CFG_SHOW_HOSTNAME" = "true" ]; then
    CONKY_TEXT="\${font DejaVu Sans Mono:size=${CFG_HOSTNAME_FONT_SIZE}}\${color ${COLOR_TEXT_LUA}}Host: \${nodename}
\${font DejaVu Sans Mono:size=${CFG_FONT_SIZE}}
\${color ${COLOR_TEXT_LUA}}${OM_ACRONYM} - ${OM_NAME}
\${color ${COLOR_TEXT_LUA}}\${hr}"
else
    CONKY_TEXT="\${color ${COLOR_TEXT_LUA}}${OM_ACRONYM} - ${OM_NAME}
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

cat > /etc/seederlinux/conky/conky.conf <<EOF
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

# ============================================================
# Criar script de inicializacao do Conky
# ============================================================
log_nivel INFO "Criando script de inicializacao..."
cat > /usr/local/bin/seederlinux-conky <<'SCRIPT'
#!/bin/bash
CONKY_CONF="/etc/seederlinux/conky/conky.conf"
sleep 5
if [ -f "$CONKY_CONF" ]; then
    killall conky 2>/dev/null || true
    conky -c "$CONKY_CONF" &
else
    echo "Configuracao do Conky nao encontrada: $CONKY_CONF"
fi
SCRIPT

chmod +x /usr/local/bin/seederlinux-conky

# ============================================================
# Adicionar Conky ao autostart conforme o DE
# ============================================================
log_nivel INFO "Configurando autostart do Conky para: $DESKTOP_ENV"

case "$DESKTOP_ENV" in
    cinnamon|mate|xfce|lxde|lxqt|gnome)
        mkdir -p /etc/xdg/autostart
        cat > /etc/xdg/autostart/seederlinux-conky.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Conky (SeederLinux)
Exec=/usr/local/bin/seederlinux-conky
Terminal=false
X-GNOME-Autostart-enabled=true
NoDisplay=false
EOF
        ;;
    kde)
        mkdir -p /usr/share/autostart
        cat > /usr/share/autostart/seederlinux-conky.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Conky (SeederLinux)
Exec=/usr/local/bin/seederlinux-conky
Terminal=false
X-KDE-autostart-enabled=true
EOF
        ;;
esac

log_nivel OK "Conky configurado!"
echo "============================================================"
)
