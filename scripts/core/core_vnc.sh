#!/bin/bash
# SeederLinux Lite - core_vnc.sh v4-fixed
# ============================================================================
# Consolidado: v3 (arquitetura estavel) + listener_check do v4.
#
# CORRECOES APLICADAS NO v4-fixed (em relacao ao v4 original):
#
#   1. /etc/seederlinux NAO e mais chmod 700. A sessao do usuario le
#      config.env, conky.conf e branding.env dali (escritos pelo
#      core_config.sh / core_conky.sh / core_branding.sh). Trancar em
#      0700 quebra a sessao. Agora:
#        /etc/seederlinux      -> 0755
#        /etc/seederlinux/vnc  -> 0700 (nova pasta dedicada)
#        $PASSFILE dentro da pasta vnc/ com 0600
#
#   2. Restaurado -noipv6 e -logappend no x11vnc. Sem -noipv6 a
#      compilacao pode escutar em [::]:PORT (todos os IPs). Sem
#      -logappend o -o trunca o log a cada restart do supervisor.
#
#   3. BACKEND_NAO_SUPORTADO movido para fora do detect_display. No v4
#      o proprio detect_display chamava set_status, e o caller
#      sobrescrevia com AGUARDANDO_SESSAO. Agora detect_display so
#      retorna o display (ou vazio); o loop principal decide o estado
#      comparando com wayland_session_present().
#
#   4. set_status com LAST_STATE: nao escreve no journal a cada 5s em
#      AGUARDANDO_REDE / AGUARDANDO_SESSAO. So loga quando o estado
#      muda de verdade.
#
#   5. Placeholders do supervisor trocados de {{VAR}} para __VAR__.
#      O PHP substitui {{VAR}} no bundle INTEIRO antes do sed rodar,
#      entao `LISTEN="{{VNC_LISTEN_ADDRESS}}"` virava `LISTEN="auto"`
#      (valor da OM) e o sed do v4 nao encontrava nada para trocar
#      pelo IP resolvido em runtime. Agora o supervisor tem
#      `LISTEN="__VNC_LISTEN_ADDRESS__"` e o sed substitui com o
#      valor realmente resolvido (auto ou explicito).
#
#   6. PASSFILE movido para /etc/seederlinux/vnc/vncpasswd (dentro da
#      pasta 0700). Antes ficava em /etc/seederlinux/vncpasswd, que
#      passa a ser 0755.
#
# SE MANTEVE DO v4 ORIGINAL:
#   - listener_check() com ss: ATIVO so e publicado apos confirmar
#     que o unico listener na porta e IP:PORT esperado. Fail-closed
#     se aparecer escuta em outro endereco ou se ss/iproute2 faltar.
#   - valid_ipv4() com checagem octeto a octeto.
#   - deteccao de display por loginctl (sessao x11 ativa), com
#     fallback para "Xorg com display explicito" se loginctl nao
#     ajudar.
#   - auto-IP via `ip route get $DC_IP` (com fallback para o primeiro
#     IP de DC_IP_LIST).
#
# NAO FAZ:
#   - Nao instala pacotes (x11vnc, x11-utils, xauth, logrotate vem do
#     core_packages.sh, Fase 1).
#   - Nao reinicia display-manager.
#   - Nao captura Wayland. Sessao Wayland ativa e' reportada como
#     BACKEND_NAO_SUPORTADO, sem quebrar a estacao.
# ============================================================================

(
source /usr/local/lib/seederlinux/diag.sh 2>/dev/null || true
SCRIPT_ID="12-vnc"
if ! declare -F log_nivel >/dev/null 2>&1; then
    log_nivel() { local n="$1"; shift; printf '>>> [%s] %s\n' "$n" "$*"; }
fi

set -Eeuo pipefail
umask 077

# ============================================================
# Variaveis substituidas pelo backend (OM)
# ============================================================
VNC_ENABLED="{{VNC_ENABLED}}"
VNC_PASSWORD_B64="__VNC_PASSWORD_B64__"
VNC_LISTEN_ADDRESS="{{VNC_LISTEN_ADDRESS}}"
DC_IP="{{DC_IP}}"
DC_IP_LIST="{{DC_IP_LIST}}"
VNC_PORT="{{VNC_PORT}}"

# Normalizacao de VNC_PORT
if [[ ! "$VNC_PORT" =~ ^[0-9]{1,5}$ ]] || (( 10#$VNC_PORT < 1024 || 10#$VNC_PORT > 65535 )); then
    log_nivel AVISO "VNC_PORT invalida ou nao definida; usando 5900."
    VNC_PORT=5900
else
    VNC_PORT=$((10#$VNC_PORT))
fi

# ============================================================
# Constantes
# ============================================================
UNIT="seederlinux-vnc.service"
SUPERVISOR="/usr/local/sbin/seederlinux-vnc-supervisor"
VNC_DIR="/etc/seederlinux/vnc"
PASSFILE="${VNC_DIR}/vncpasswd"
LOGROTATE_FILE="/etc/logrotate.d/seederlinux-vnc"
STATUS_FILE="/run/seederlinux-vnc.status"
LOG_FILE="/var/log/seederlinux-vnc.log"

if [[ $EUID -ne 0 ]]; then
    log_nivel ERRO "Este modulo precisa ser executado como root."
    exit 0
fi

# ============================================================
# Funcoes auxiliares
# ============================================================
disable_vnc() {
    systemctl disable --now "$UNIT" 2>/dev/null || true
    rm -f "/etc/systemd/system/$UNIT" "$SUPERVISOR" \
          "$LOGROTATE_FILE" "$STATUS_FILE" "$STATUS_FILE".*
    rm -rf "$VNC_DIR"
    systemctl daemon-reload 2>/dev/null || true
    log_nivel INFO "VNC desativado; servico, supervisor, credencial e configuracoes removidos."
}

vnc_fail() {
    log_nivel ERRO "$*"
    disable_vnc
    exit 0
}

local_has_ip() {
    local a
    a="$(ip -o -4 addr show 2>/dev/null | awk '{split($4,x,"/"); print x[1]}' || true)"
    grep -Fxq -- "$1" <<< "$a"
}

ip_allowed() {
    local ip="$1" o1 o2 o3 o4
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r o1 o2 o3 o4 <<< "$ip"
    local o
    for o in "$o1" "$o2" "$o3" "$o4"; do
        (( 10#$o <= 255 )) || return 1
    done
    (( 10#$o1 == 0 || 10#$o1 == 127 || 10#$o1 >= 224 )) && return 1
    [[ "$ip" == 169.254.* ]] && return 1
    return 0
}

# ============================================================
# VNC desligado na OM: converge estacao para desligado
# ============================================================
if [[ "$VNC_ENABLED" != "true" ]]; then
    disable_vnc
    exit 0
fi

# ============================================================
# Dependencias (instaladas no core_packages.sh, Fase 1)
# ============================================================
if ! command -v x11vnc >/dev/null 2>&1; then
    vnc_fail "x11vnc nao instalado. Instale em core_packages.sh. VNC antigo desativado por seguranca."
fi
if ! command -v xdpyinfo >/dev/null 2>&1 && ! command -v xset >/dev/null 2>&1; then
    log_nivel AVISO "xdpyinfo/xset ausentes (pacote x11-utils): a credencial X sera validada apenas por existir e nao estar vazia."
fi
X11VNC_BIN="$(command -v x11vnc)"

# ============================================================
# Resolucao do IP interno (auto ou explicito)
# ============================================================
# AUTO quando:
#   - VNC_LISTEN_ADDRESS vazio, ou
#   - literal "auto", ou
#   - o placeholder nao foi substituido ({"{"} incluido no valor)
AUTO_IP=false
case "$VNC_LISTEN_ADDRESS" in
    ""|auto|*"{"*) AUTO_IP=true ;;
esac
# Se DC_IP / DC_IP_LIST contiverem chave, o placeholder nao foi
# substituido — tratar como vazio.
[[ "$DC_IP" == *"{"* ]] && DC_IP=""
[[ "$DC_IP_LIST" == *"{"* ]] && DC_IP_LIST=""

if [[ "$AUTO_IP" == "true" ]]; then
    # Em modo auto, o DC_IP e' usado como alvo da rota. Se vazio,
    # tenta extrair o primeiro IPv4 de DC_IP_LIST.
    if [[ -z "$DC_IP" ]]; then
        DC_IP="$(printf '%s' "$DC_IP_LIST" | tr ',;' '\n\n' \
            | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1 || true)"
    fi
    [[ -n "$DC_IP" ]] || vnc_fail "VNC_LISTEN_ADDRESS em auto, mas DC_IP/DC_IP_LIST nao define um controlador. Configure VNC_LISTEN_ADDRESS explicitamente."
    VNC_LISTEN_ADDRESS="$(ip route get "$DC_IP" 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
else
    # Explicito: DC_IP nao e' mais usado daqui em diante.
    DC_IP=""
fi

ip_allowed "$VNC_LISTEN_ADDRESS" \
    || vnc_fail "Nao foi possivel resolver um IPv4 interno valido para o VNC (valor: '${VNC_LISTEN_ADDRESS}'). Configuracao recusada."
local_has_ip "$VNC_LISTEN_ADDRESS" \
    || vnc_fail "O endereco $VNC_LISTEN_ADDRESS nao esta configurado nesta estacao. VNC nao sera habilitado."

# ============================================================
# Senha VNC (classica: 6-8 caracteres)
# ============================================================
VNC_PASSWORD=""
if [[ -n "$VNC_PASSWORD_B64" && "$VNC_PASSWORD_B64" != __*__ ]]; then
    VNC_PASSWORD="$(printf '%s' "$VNC_PASSWORD_B64" | base64 -d 2>/dev/null || true)"
fi
unset VNC_PASSWORD_B64

[[ -n "$VNC_PASSWORD" ]] || vnc_fail "Senha VNC da OM ausente ou invalida. Nao sera criada senha aleatoria desconhecida."

pw_bytes="$(printf '%s' "$VNC_PASSWORD" | LC_ALL=C wc -c | tr -d ' ')"
if (( pw_bytes < 6 || pw_bytes > 8 )); then
    unset VNC_PASSWORD
    vnc_fail "A senha VNC classica deve ter de 6 a 8 caracteres (x11vnc so verifica os 8 primeiros)."
fi

# ============================================================
# Diretorios (CORRECAO 1: /etc/seederlinux continua 0755)
# ============================================================
install -d -o root -g root -m 0755 /etc/seederlinux
install -d -o root -g root -m 0700 "$VNC_DIR"
install -d -o root -g root -m 0755 /usr/local/sbin
install -d -o root -g root -m 0755 /usr/local/lib/seederlinux

# ============================================================
# Arquivo de senha VNC
# ============================================================
tmp_pass="$(mktemp "${VNC_DIR}/.vncpasswd.XXXXXX")"
trap 'rm -f "${tmp_pass:-}"; unset VNC_PASSWORD' EXIT
if ! "$X11VNC_BIN" -storepasswd "$VNC_PASSWORD" "$tmp_pass" >/dev/null 2>&1; then
    vnc_fail "Falha ao gerar o arquivo de autenticacao VNC; configuracao anterior desativada por seguranca."
fi
chown root:root "$tmp_pass"
chmod 600 "$tmp_pass"
mv -f "$tmp_pass" "$PASSFILE"
unset VNC_PASSWORD
trap - EXIT
chmod 600 "$PASSFILE"

# ============================================================
# Supervisor (CORRECAO 5: placeholders __VAR__ para o sed)
# ============================================================
cat > "$SUPERVISOR" <<'SUPERVISOR_EOF'
#!/bin/bash
# seederlinux-vnc-supervisor - mantem o x11vnc apontando para a sessao
# X11 ativa, escutando apenas no IP interno. Nao reinicia o DM.
set -u
umask 077

PASSFILE="__VNC_PASSFILE__"
LISTEN="__VNC_LISTEN_ADDRESS__"
AUTO_IP="__VNC_AUTO_IP__"
DC_IP="__VNC_DC_IP__"
PORT="__VNC_PORT__"
X11VNC_BIN="__VNC_X11VNC_BIN__"
STATUS="/run/seederlinux-vnc.status"
LOGFILE="/var/log/seederlinux-vnc.log"

CHILD=""
CHILD_SIG=""
CHILD_START=0
LAST_STATE=""

log() { logger -t seederlinux-vnc -- "$*"; }

# So grava/loga quando o estado muda (evita inundar o journal)
set_status() {
    local line="$*"
    [[ "$line" == "$LAST_STATE" ]] && return 0
    LAST_STATE="$line"
    local tmp="${STATUS}.$$"
    printf '%s %s\n' "$(date -Is)" "$line" > "$tmp" 2>/dev/null || return 0
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$STATUS" 2>/dev/null || rm -f "$tmp"
    log "estado: $line"
}

cleanup() {
    if [[ -n "${CHILD:-}" ]]; then
        kill -TERM "$CHILD" 2>/dev/null || true
        local i
        for i in 1 2 3 4 5; do
            kill -0 "$CHILD" 2>/dev/null || break
            sleep 1
        done
        kill -KILL "$CHILD" 2>/dev/null || true
        wait "$CHILD" 2>/dev/null || true
        CHILD=""
    fi
}
stop_child() { cleanup; CHILD_SIG=""; }
trap 'stop_child; set_status "PARADO" "Supervisor encerrado"; exit 0' TERM INT
trap cleanup EXIT

# ------------------------------------------------------------
# Validacao de IPv4
# ------------------------------------------------------------
valid_ipv4() {
    local ip="$1" a b c d o
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r a b c d <<< "$ip"
    for o in "$a" "$b" "$c" "$d"; do
        [[ "$o" =~ ^[0-9]{1,3}$ ]] || return 1
        (( 10#$o <= 255 )) || return 1
    done
    (( 10#$a == 0 || 10#$a == 127 || 10#$a >= 224 )) && return 1
    [[ "$ip" == 169.254.* ]] && return 1
    return 0
}

local_has_ip() {
    local a
    a="$(ip -o -4 addr show 2>/dev/null | awk '{split($4,x,"/"); print x[1]}')"
    grep -Fxq -- "$1" <<< "$a"
}

route_src() {
    ip route get "$DC_IP" 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}

# ------------------------------------------------------------
# Wayland ativo?
# ------------------------------------------------------------
wayland_session_present() {
    command -v loginctl >/dev/null 2>&1 || return 1
    local sid typ
    while read -r sid _; do
        [[ -n "$sid" ]] || continue
        typ="$(loginctl show-session "$sid" -p Type --value 2>/dev/null || true)"
        [[ "$typ" == "wayland" ]] && return 0
    done < <(loginctl list-sessions --no-legend 2>/dev/null || true)
    return 1
}

# ------------------------------------------------------------
# Detecta sessao X11: display|uid. Sem efeito colateral.
# ------------------------------------------------------------
detect_display() {
    local sid uid typ disp state fallback="" fallback_uid=""
    if command -v loginctl >/dev/null 2>&1; then
        while read -r sid uid _; do
            [[ -n "$sid" && "$uid" =~ ^[0-9]+$ ]] || continue
            typ="$(loginctl show-session "$sid" -p Type --value 2>/dev/null || true)"
            disp="$(loginctl show-session "$sid" -p Display --value 2>/dev/null || true)"
            state="$(loginctl show-session "$sid" -p State --value 2>/dev/null || true)"
            if [[ "$typ" == "x11" && "$disp" =~ ^:[0-9]+([.][0-9]+)?$ ]]; then
                if [[ "$state" == "active" ]]; then
                    printf '%s|%s\n' "$disp" "$uid"; return 0
                fi
                if [[ -z "$fallback" ]]; then
                    fallback="$disp"; fallback_uid="$uid"
                fi
            fi
        done < <(loginctl list-sessions --no-legend 2>/dev/null || true)
    fi
    if [[ -n "$fallback" ]]; then
        printf '%s|%s\n' "$fallback" "$fallback_uid"; return 0
    fi
    # Fallback: Xorg com display explicito na linha de comando e socket
    # correspondente. Se houver ambiguidade (multiplos Xorg ou Xorg com
    # -displayfd), nao chuta.
    local line d candidate="" count=0
    while IFS= read -r line; do
        [[ "$line" =~ (^|/|[[:space:]])Xorg([[:space:]]|$) ]] || continue
        d="$(printf '%s\n' "$line" | grep -oE ':[0-9]+([.][0-9]+)?' | head -n1 || true)"
        [[ -n "$d" && -S "/tmp/.X11-unix/X${d#:}" ]] || continue
        candidate="$d"
        ((count+=1))
    done < <(ps -eo args= 2>/dev/null || true)
    if (( count == 1 )); then
        printf '%s|greeter\n' "$candidate"
        return 0
    fi
    return 1
}

# ------------------------------------------------------------
# Xauthority valido para o display informado.
# ------------------------------------------------------------
auth_works() {
    local disp="$1" auth="$2"
    [[ -r "$auth" && -s "$auth" ]] || return 1
    if command -v xdpyinfo >/dev/null 2>&1; then
        DISPLAY="$disp" XAUTHORITY="$auth" xdpyinfo >/dev/null 2>&1
        return $?
    fi
    if command -v xset >/dev/null 2>&1; then
        DISPLAY="$disp" XAUTHORITY="$auth" xset q >/dev/null 2>&1
        return $?
    fi
    return 0
}

detect_xauth() {
    local disp="$1" line f
    while IFS= read -r line; do
        [[ "$line" == *" $disp "* || "$line" == *" $disp" ]] || continue
        f="$(printf '%s\n' "$line" | sed -nE 's/.*[[:space:]]-auth[[:space:]]+([^[:space:]]+).*/\1/p')"
        if [[ -n "$f" ]] && auth_works "$disp" "$f"; then
            printf '%s\n' "$f"; return 0
        fi
    done < <(ps -eo args= 2>/dev/null | grep -E '(^|/)(Xorg|X)([[:space:]]|$)' || true)

    shopt -s nullglob
    local f
    for f in \
        "/run/lightdm/root/$disp" "/var/run/lightdm/root/$disp" \
        /run/gdm3/auth-for-*/database /run/gdm/auth-for-*/database \
        /var/lib/gdm3/.Xauthority /var/lib/gdm/.Xauthority \
        /run/sddm/xauth_* /var/run/sddm/xauth_* \
        "/var/run/lxdm/lxdm-$disp.auth" /var/run/slim.auth; do
        [[ -f "$f" ]] || continue
        if auth_works "$disp" "$f"; then
            printf '%s\n' "$f"; return 0
        fi
    done
    return 1
}

# ------------------------------------------------------------
# Assinatura da sessao: display|uid|auth. Vazio se nao ha X11.
# ------------------------------------------------------------
session_signature() {
    local found disp uid auth
    found="$(detect_display)" || return 1
    disp="${found%%|*}"
    uid="${found#*|}"
    auth="$(detect_xauth "$disp")" || return 1
    printf '%s|%s|%s\n' "$disp" "$uid" "$auth"
}

# ------------------------------------------------------------
# Confere com ss que o unico listener na porta e' LISTEN:PORT.
# Retornos: 0=OK, 1=ainda nao escuta, 2=escuta em outro addr, 3=sem ss
# ------------------------------------------------------------
listener_check() {
    command -v ss >/dev/null 2>&1 || return 3
    local output line local_addr found=0 unexpected=0
    output="$(ss -H -ltn 2>/dev/null)" || return 3
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        local_addr="$(awk '{print $4}' <<< "$line")"
        [[ "$local_addr" == *":$PORT" ]] || continue
        found=1
        case "$local_addr" in
            "$LISTEN:$PORT"|"[$LISTEN]:$PORT") ;;
            *) unexpected=1 ;;
        esac
    done <<< "$output"
    (( unexpected == 1 )) && return 2
    (( found == 1 )) && return 0
    return 1
}

# ============================================================
# Loop principal
# ============================================================
log "Supervisor VNC iniciado. LISTEN=${LISTEN:-<auto>} PORT=$PORT AUTO_IP=$AUTO_IP"

while :; do
    # --- Rede: acompanha DHCP pela rota ao DC; fail-closed ---
    if [[ "$AUTO_IP" == "true" ]]; then
        NEW_LISTEN="$(route_src)"
        if ! valid_ipv4 "${NEW_LISTEN:-}" || ! local_has_ip "$NEW_LISTEN"; then
            set_status AGUARDANDO_REDE "Sem rota interna valida para o DC ${DC_IP}; transmissao suspensa."
            stop_child
            sleep 5
            continue
        fi
        if [[ "$NEW_LISTEN" != "$LISTEN" ]]; then
            set_status RECONFIGURANDO_REDE "IP interno mudou de ${LISTEN:-<vazio>} para $NEW_LISTEN; reiniciando backend."
            stop_child
            LISTEN="$NEW_LISTEN"
        fi
    fi
    if ! valid_ipv4 "$LISTEN" || ! local_has_ip "$LISTEN"; then
        set_status AGUARDANDO_REDE "Endereco interno ${LISTEN:-<vazio>} indisponivel; fail-closed ativo."
        stop_child
        sleep 5
        continue
    fi

    # --- Sessao X11 ---
    SIG="$(session_signature 2>/dev/null || true)"
    if [[ -z "$SIG" ]]; then
        if wayland_session_present; then
            set_status BACKEND_NAO_SUPORTADO "Sessao Wayland ativa; x11vnc nao captura Wayland. Transmissao suspensa."
        else
            set_status AGUARDANDO_SESSAO "Nenhuma sessao X11 com Xauthority validada; transmissao suspensa."
        fi
        [[ -n "$CHILD" ]] && stop_child
        sleep 3
        continue
    fi

    # --- (Re)inicia x11vnc se necessario ---
    if [[ "$SIG" != "$CHILD_SIG" || -z "$CHILD" ]] || ! kill -0 "$CHILD" 2>/dev/null; then
        [[ -n "$CHILD" ]] && stop_child

        DISP="${SIG%%|*}"
        SIG_REST="${SIG#*|}"
        SESSION_UID="${SIG_REST%%|*}"
        AUTH="${SIG_REST#*|}"

        set_status INICIANDO "backend=x11vnc display=$DISP sessao=$SESSION_UID escuta=$LISTEN:$PORT"

        "$X11VNC_BIN" \
            -display "$DISP" \
            -auth "$AUTH" \
            -rfbauth "$PASSFILE" \
            -rfbport "$PORT" \
            -listen "$LISTEN" \
            -noipv6 \
            -forever -shared -repeat -noxdamage -nolookup \
            -logappend "$LOGFILE" &
        CHILD=$!
        CHILD_SIG="$SIG"
        CHILD_START=$SECONDS

        # Aguarda 1s e tenta confirmar o listener por ate 6s.
        # Nao publica ATIVO sem confirmacao do ss.
        listener_rc=1
        local_i=0
        while (( local_i < 6 )); do
            sleep 1
            if ! kill -0 "$CHILD" 2>/dev/null; then
                break
            fi
            listener_check
            listener_rc=$?
            (( listener_rc == 0 )) && break
            ((local_i++))
        done

        if ! kill -0 "$CHILD" 2>/dev/null; then
            wait "$CHILD" 2>/dev/null || true
            CHILD=""; CHILD_SIG=""
            set_status ERRO_RECUPERAVEL "x11vnc encerrou durante a inicializacao; nova tentativa."
            sleep 3
        elif (( listener_rc == 0 )); then
            set_status ATIVO "backend=x11vnc display=$DISP sessao=$SESSION_UID escuta=$LISTEN:$PORT"
        elif (( listener_rc == 3 )); then
            stop_child
            set_status ERRO_VALIDACAO "Nao foi possivel verificar o listener (ss/iproute2 ausente); backend encerrado por seguranca."
            sleep 5
        elif (( listener_rc == 2 )); then
            stop_child
            set_status ERRO_SEGURANCA "Listener detectado em endereco inesperado; backend encerrado."
            sleep 5
        else
            stop_child
            set_status ERRO_RECUPERAVEL "x11vnc nao abriu a porta esperada; nova tentativa."
            sleep 3
        fi
    fi
    sleep 3
done
SUPERVISOR_EOF

# Substituicao dos __VAR__ pelos valores resolvidos em runtime
sed -i \
    -e "s|__VNC_PASSFILE__|${PASSFILE}|g" \
    -e "s|__VNC_LISTEN_ADDRESS__|${VNC_LISTEN_ADDRESS}|g" \
    -e "s|__VNC_AUTO_IP__|${AUTO_IP}|g" \
    -e "s|__VNC_DC_IP__|${DC_IP}|g" \
    -e "s|__VNC_PORT__|${VNC_PORT}|g" \
    -e "s|__VNC_X11VNC_BIN__|${X11VNC_BIN}|g" \
    "$SUPERVISOR"
chmod 750 "$SUPERVISOR"
chown root:root "$SUPERVISOR"

# ============================================================
# systemd unit
# ============================================================
cat > "/etc/systemd/system/$UNIT" <<'UNIT_EOF'
[Unit]
Description=SeederLinux Lite - VNC adaptativo para sessao grafica existente
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/usr/local/sbin/seederlinux-vnc-supervisor
Restart=always
RestartSec=5
User=root
UMask=0077
NoNewPrivileges=true
PrivateTmp=false
ProtectHome=read-only
ProtectSystem=full
ReadWritePaths=/run /var/log/seederlinux-vnc.log /etc/seederlinux/vnc
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
LockPersonality=true

[Install]
WantedBy=multi-user.target
UNIT_EOF

# ============================================================
# Logrotate
# ============================================================
touch "$LOG_FILE"
chown root:root "$LOG_FILE"
chmod 600 "$LOG_FILE"

cat > "$LOGROTATE_FILE" <<'LOGROTATE_EOF'
/var/log/seederlinux-vnc.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 0600 root root
    copytruncate
}
LOGROTATE_EOF
chmod 644 "$LOGROTATE_FILE"

# ============================================================
# Habilita e (re)inicia
# ============================================================
systemctl daemon-reload
systemctl enable "$UNIT"
systemctl restart "$UNIT" 2>/dev/null \
    || log_nivel AVISO "Nao foi possivel iniciar $UNIT agora; systemd tentara de novo."

log_nivel INFO "Supervisor VNC v4-fixed instalado. Escuta ${VNC_LISTEN_ADDRESS}:${VNC_PORT} (modo_auto=${AUTO_IP})."
log_nivel AVISO "Backend: X11/x11vnc. Wayland ativo reportado como BACKEND_NAO_SUPORTADO. Restrinja a porta por firewall."
log_nivel INFO "Status: cat ${STATUS_FILE} | journalctl -t seederlinux-vnc | ${LOG_FILE}"
) || echo ">>> [AVISO] core_vnc.sh terminou com erro (veja as linhas acima); o bundle continua."
