#!/bin/bash
# SeederLinux Lite - core_vnc.sh v4
# v4 corrigido: isolamento em subshell, segredos em diretório próprio, IPv4 fail-closed,
# verificação real do listener e estados que não anunciam ATIVO sem escuta confirmada.
# Instala supervisor VNC adaptativo para sessões X11 existentes.
# Wayland nativo é detectado e reportado como não suportado pelo backend
# genérico; não desativa Wayland nem reinicia o Display Manager.
(
source /usr/local/lib/seederlinux/diag.sh 2>/dev/null || true
SCRIPT_ID="12-vnc"
if ! declare -F log_nivel >/dev/null 2>&1; then
  log_nivel() { local n="$1"; shift; printf '>>> [%s] %s\n' "$n" "$*"; }
fi

set -Eeuo pipefail
umask 077

VNC_ENABLED="{{VNC_ENABLED}}"
VNC_PASSWORD_B64="__VNC_PASSWORD_B64__"
# Obrigatório: endereço IPv4 da interface interna da OM. Nunca usar 0.0.0.0.
VNC_LISTEN_ADDRESS="{{VNC_LISTEN_ADDRESS}}"
DC_IP="{{DC_IP}}"
DC_IP_LIST="{{DC_IP_LIST}}"
VNC_PORT="{{VNC_PORT}}"
if [[ ! "$VNC_PORT" =~ ^[0-9]{1,5}$ ]] || (( 10#$VNC_PORT < 1024 || 10#$VNC_PORT > 65535 )); then
  log_nivel AVISO "VNC_PORT inválida; usando 5900."
  VNC_PORT=5900
else
  VNC_PORT=$((10#$VNC_PORT))
fi

UNIT="seederlinux-vnc.service"
SUPERVISOR="/usr/local/sbin/seederlinux-vnc-supervisor"
PASSFILE="/etc/seederlinux/vnc/vncpasswd"
LOGROTATE_FILE="/etc/logrotate.d/seederlinux-vnc"
STATUS_FILE="/run/seederlinux-vnc.status"

if [[ $EUID -ne 0 ]]; then
  log_nivel ERRO "Este módulo precisa ser executado como root."
  exit 0
fi

disable_vnc() {
  systemctl disable --now "$UNIT" 2>/dev/null || true
  rm -f "/etc/systemd/system/$UNIT" "$SUPERVISOR" "$PASSFILE" /etc/seederlinux/vncpasswd /etc/seederlinux/.vncpasswd.* "$LOGROTATE_FILE" "$STATUS_FILE" "$STATUS_FILE.tmp"
  systemctl daemon-reload 2>/dev/null || true
  log_nivel INFO "VNC desativado; serviço, supervisor, credencial e configurações removidos."
}

if [[ "$VNC_ENABLED" != "true" ]]; then
  disable_vnc
  exit 0
fi

if ! command -v x11vnc >/dev/null 2>&1 || ! command -v xdpyinfo >/dev/null 2>&1; then
  log_nivel ERRO "Dependências ausentes: instale x11vnc e x11-utils em core_packages.sh. VNC antigo será desativado por segurança."
  disable_vnc
  exit 0
fi

AUTO_IP=false
if [[ -z "$VNC_LISTEN_ADDRESS" || "$VNC_LISTEN_ADDRESS" == "auto" || "$VNC_LISTEN_ADDRESS" == "{{VNC_LISTEN_ADDRESS}}" ]]; then
  AUTO_IP=true
  # Em modo automático, usa exclusivamente a rota para o DC. Não escolhe
  # arbitrariamente a primeira interface ativa, o que poderia expor outra rede.
  if [[ -z "$DC_IP" || "$DC_IP" == "{{DC_IP}}" ]]; then
    DC_IP="$(printf '%s' "$DC_IP_LIST" | tr ',;' '\n' | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1 || true)"
  fi
  if [[ -z "$DC_IP" ]]; then
    log_nivel ERRO "VNC_LISTEN_ADDRESS está em auto, mas DC_IP/DC_IP_LIST não define um controlador de domínio. Configure o IP explicitamente ou informe o DC."
    disable_vnc
    exit 0
  fi
  VNC_LISTEN_ADDRESS="$(ip route get "$DC_IP" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
fi
if [[ ! "$VNC_LISTEN_ADDRESS" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  log_nivel ERRO "Não foi possível resolver um IPv4 interno válido para VNC. Configuração recusada."
  disable_vnc
  exit 0
fi
IFS=. read -r _v1 _v2 _v3 _v4 <<< "$VNC_LISTEN_ADDRESS"
for _octet in "$_v1" "$_v2" "$_v3" "$_v4"; do
  if [[ ! "$_octet" =~ ^[0-9]{1,3}$ ]] || (( 10#$_octet > 255 )); then
    log_nivel ERRO "VNC_LISTEN_ADDRESS contém um octeto IPv4 inválido."
    disable_vnc
    exit 0
  fi
done
unset _v1 _v2 _v3 _v4 _octet
if [[ "$VNC_LISTEN_ADDRESS" == "0.0.0.0" || "$VNC_LISTEN_ADDRESS" == 127.* || "$VNC_LISTEN_ADDRESS" == 169.254.* || "$VNC_LISTEN_ADDRESS" == 224.* || "$VNC_LISTEN_ADDRESS" == 255.255.255.255 ]]; then
  log_nivel ERRO "VNC_LISTEN_ADDRESS é um endereço não permitido para escuta VNC: $VNC_LISTEN_ADDRESS"
  disable_vnc
  exit 0
fi
if ! ip -o -4 addr show | awk '{split($4,a,"/"); print a[1]}' | grep -Fxq "$VNC_LISTEN_ADDRESS"; then
  log_nivel ERRO "O endereço interno $VNC_LISTEN_ADDRESS não está configurado nesta estação. VNC não será habilitado."
  disable_vnc
  exit 0
fi

# x11vnc usa autenticação VNC clássica, que considera no máximo 8 caracteres.
# Recusamos senhas mais longas para não criar a falsa impressão de que todos
# os caracteres estão sendo verificados.
VNC_PASSWORD=""
if [[ -n "$VNC_PASSWORD_B64" && "$VNC_PASSWORD_B64" != "__VNC_PASSWORD_B64__" ]]; then
  VNC_PASSWORD="$(printf '%s' "$VNC_PASSWORD_B64" | base64 -d 2>/dev/null || true)"
fi
unset VNC_PASSWORD_B64

if [[ -z "$VNC_PASSWORD" ]]; then
  log_nivel ERRO "Senha VNC da OM ausente ou inválida. Não será criada senha aleatória desconhecida."
  disable_vnc
  exit 0
fi
if (( ${#VNC_PASSWORD} < 6 || ${#VNC_PASSWORD} > 8 )); then
  unset VNC_PASSWORD
  log_nivel ERRO "A senha VNC clássica deve ter de 6 a 8 caracteres. Não use senha longa presumindo que x11vnc a validará integralmente."
  disable_vnc
  exit 0
fi

X11VNC_BIN="$(command -v x11vnc)"
# Preserve permissions of the shared SeederLinux directory: config.env,
# branding and session files must remain readable by the workstation user.
if [[ ! -d /etc/seederlinux ]]; then
  install -d -o root -g root -m 755 /etc/seederlinux
fi
# Only VNC-specific secrets belong in this root-only directory.
install -d -o root -g root -m 700 /etc/seederlinux/vnc
install -d -o root -g root -m 755 /usr/local/sbin
install -d -o root -g root -m 755 /usr/local/lib/seederlinux

# A senha é gravada no formato de autenticação esperado por x11vnc.
# O valor nunca é enviado ao log. O argumento pode ser visível brevemente
# em listagens de processos durante a criação do arquivo.
tmp_pass="$(mktemp /etc/seederlinux/vnc/.vncpasswd.XXXXXX)"
trap 'rm -f "${tmp_pass:-}"; unset VNC_PASSWORD' EXIT
if ! "$X11VNC_BIN" -storepasswd "$VNC_PASSWORD" "$tmp_pass" >/dev/null 2>&1; then
  log_nivel ERRO "Falha ao gerar arquivo de autenticação VNC; desativando configuração anterior por segurança."
  disable_vnc
  exit 0
fi
chown root:root "$tmp_pass"
chmod 600 "$tmp_pass"
mv -f "$tmp_pass" "$PASSFILE"
unset VNC_PASSWORD
trap - EXIT
chmod 600 "$PASSFILE"

cat > "$SUPERVISOR" <<'SUPERVISOR_EOF'
#!/bin/bash
set -u
umask 077
PASSFILE="/etc/seederlinux/vnc/vncpasswd"
LISTEN="{{VNC_LISTEN_ADDRESS}}"
AUTO_IP="{{AUTO_IP}}"
DC_IP="{{DC_IP}}"
PORT="{{VNC_PORT}}"
X11VNC_BIN="{{X11VNC_BIN}}"
STATUS="/run/seederlinux-vnc.status"
CHILD=""
CHILD_SIG=""

log() { logger -t seederlinux-vnc -- "$*"; }

valid_ipv4() {
  local ip="$1" a b c d oct
  [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
  IFS=. read -r a b c d <<< "$ip"
  for oct in "$a" "$b" "$c" "$d"; do
    [[ "$oct" =~ ^[0-9]{1,3}$ ]] || return 1
    (( 10#$oct <= 255 )) || return 1
  done
  [[ "$ip" != "0.0.0.0" && "$ip" != 127.* && "$ip" != 169.254.* && "$ip" != 224.* && "$ip" != 255.255.255.255 ]]
}

# Retornos: 0 = listener correto confirmado; 1 = ainda não está escutando;
# 2 = listener encontrado em endereço inesperado; 3 = não foi possível validar.
listener_check() {
  local output line local_addr found=0 unexpected=0
  command -v ss >/dev/null 2>&1 || return 3
  output="$(ss -H -ltn 2>/dev/null)" || return 3
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    # Formato usual: State Recv-Q Send-Q Local Address:Port Peer Address:Port.
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

LAST_STATE=""
LAST_DETAIL=""
set_status() {
  local state="$1"; shift
  local detail="$*"
  local tmp="${STATUS}.$$"
  # Always refresh the status file, but avoid flooding journald every loop.
  printf '%s %s\n' "$state" "$detail" > "$tmp" || return 0
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$STATUS" 2>/dev/null || rm -f "$tmp"
  if [[ "$state" != "$LAST_STATE" || "$detail" != "$LAST_DETAIL" ]]; then
    log "estado=$state $detail"
    LAST_STATE="$state"
    LAST_DETAIL="$detail"
  fi
}

cleanup() {
  if [[ -n "${CHILD:-}" ]]; then
    kill -TERM "$CHILD" 2>/dev/null || true
    # Give x11vnc a short opportunity to flush logs and close the listener.
    for _i in 1 2 3 4 5; do
      kill -0 "$CHILD" 2>/dev/null || break
      sleep 1
    done
    kill -KILL "$CHILD" 2>/dev/null || true
    wait "$CHILD" 2>/dev/null || true
    CHILD=""
  fi
}
stop_child() {
  cleanup
  CHILD_SIG=""
}
trap 'stop_child; set_status "PARADO" "Supervisor encerrado"; exit 0' TERM INT
trap cleanup EXIT

# Localiza o display associado ao Xorg de um UID mesmo quando o GDM usa
# -displayfd e loginctl deixa Display vazio. A associação exige o -auth do
# processo Xorg daquele UID e validação efetiva com xdpyinfo; não escolhe
# apenas o primeiro socket encontrado.
display_for_xorg_uid() {
  local wanted_uid="$1" line proc_uid args auth socket base disp found="" count=0
  while IFS= read -r line; do
    proc_uid="${line%% *}"
    args="${line#* }"
    [[ "$proc_uid" == "$wanted_uid" ]] || continue
    [[ "$args" =~ (^|/|[[:space:]])Xorg([[:space:]]|$) ]] || continue
    auth="$(printf '%s\n' "$args" | sed -nE 's/.*[[:space:]]-auth[[:space:]]+([^[:space:]]+).*/\1/p')"
    [[ -n "$auth" && -r "$auth" && -s "$auth" ]] || continue
    for socket in /tmp/.X11-unix/X*; do
      [[ -S "$socket" ]] || continue
      base="${socket##*/}"
      [[ "$base" =~ ^X[0-9]+$ ]] || continue
      disp=":${base#X}"
      if auth_works "$disp" "$auth"; then
        found="$disp"
        ((count+=1))
      fi
    done
  done < <(ps -eo uid=,args= 2>/dev/null || true)
  if (( count == 1 )); then
    printf '%s\n' "$found"
    return 0
  fi
  return 1
}

# Seleciona sessão X11 real. Display pode vir vazio no loginctl; nesse caso,
# infere apenas por Xorg pertencente ao UID da sessão + Xauthority validado.
detect_display() {
  local sid uid typ disp state inferred fallback="" fallback_uid=""
  if command -v loginctl >/dev/null 2>&1; then
    while read -r sid uid _; do
      [[ -n "$sid" && "$uid" =~ ^[0-9]+$ ]] || continue
      typ="$(loginctl show-session "$sid" -p Type --value 2>/dev/null || true)"
      disp="$(loginctl show-session "$sid" -p Display --value 2>/dev/null || true)"
      state="$(loginctl show-session "$sid" -p State --value 2>/dev/null || true)"
      [[ "$typ" == x11 ]] || continue
      if [[ ! "$disp" =~ ^:[0-9]+([.][0-9]+)?$ ]]; then
        disp="$(display_for_xorg_uid "$uid" 2>/dev/null || true)"
      fi
      [[ "$disp" =~ ^:[0-9]+([.][0-9]+)?$ ]] || continue
      if [[ "$state" == active ]]; then printf '%s|%s\n' "$disp" "$uid"; return 0; fi
      if [[ -z "$fallback" ]]; then fallback="$disp"; fallback_uid="$uid"; fi
    done < <(loginctl list-sessions --no-legend 2>/dev/null || true)
  fi
  if [[ -n "$fallback" ]]; then printf '%s|%s\n' "$fallback" "$fallback_uid"; return 0; fi
  # Greeter fallback permanece conservador: display explícito, socket real e
  # autenticação validável. Xorg com -displayfd sem sessão associável aguarda.
  local line d candidate="" count=0
  while IFS= read -r line; do
    [[ "$line" =~ (^|/|[[:space:]])Xorg([[:space:]]|$) ]] || continue
    d="$(printf '%s\n' "$line" | grep -oE ':[0-9]+([.][0-9]+)?' | head -n1 || true)"
    [[ -n "$d" && -S "/tmp/.X11-unix/X${d#:}" ]] || continue
    candidate="$d"
    ((count+=1))
  done < <(ps -eo args= 2>/dev/null || true)
  if (( count == 1 )); then printf '%s|greeter\n' "$candidate"; return 0; fi
  return 1
}

# Extrai -auth apenas do processo X server que contém o display procurado.
# Não aceita arbitrariamente o primeiro Xauthority encontrado no sistema.
auth_works() {
  local disp="$1" auth="$2"
  [[ -r "$auth" && -s "$auth" ]] || return 1
  # Validação real da credencial contra o display. x11-utils fornece xdpyinfo.
  command -v xdpyinfo >/dev/null 2>&1 || return 2
  DISPLAY="$disp" XAUTHORITY="$auth" xdpyinfo >/dev/null 2>&1
}

detect_xauth() {
  local disp="$1" uid="${2:-}" line f proc_uid args
  # Primeiro, o -auth do Xorg que realmente atende ao display solicitado.
  while IFS= read -r line; do
    proc_uid="${line%% *}"
    args="${line#* }"
    [[ "$args" =~ (^|/|[[:space:]])Xorg([[:space:]]|$) ]] || continue
    f="$(printf '%s\n' "$args" | sed -nE 's/.*[[:space:]]-auth[[:space:]]+([^[:space:]]+).*/\1/p')"
    [[ -n "$f" ]] || continue
    if auth_works "$disp" "$f"; then printf '%s\n' "$f"; return 0; fi
  done < <(ps -eo uid=,args= 2>/dev/null || true)

  # Ubuntu 24.04/GDM: Xauthority pode ficar no runtime do usuário, não em
  # /var/lib/gdm3 nem em /run/gdm3/auth-for-*/database.
  local -a candidates=()
  [[ "$uid" =~ ^[0-9]+$ ]] && candidates+=("/run/user/$uid/gdm/Xauthority" "/run/user/$uid/Xauthority")
  if [[ "$uid" =~ ^[0-9]+$ ]]; then
    local home
    home="$(getent passwd "$uid" | cut -d: -f6 || true)"
    [[ -n "$home" ]] && candidates+=("$home/.Xauthority")
  fi
  shopt -s nullglob
  candidates+=(/run/gdm3/auth-for-*/database /run/gdm/auth-for-*/database
    /var/lib/gdm3/.Xauthority /var/lib/gdm/.Xauthority
    /run/sddm/xauth_* /var/run/sddm/xauth_*)
  candidates+=("/run/lightdm/root/$disp" "/var/run/lightdm/root/$disp" "/var/run/lxdm/lxdm-$disp.auth" /var/run/slim.auth)
  for f in "${candidates[@]}"; do
    [[ -f "$f" ]] || continue
    if auth_works "$disp" "$f"; then printf '%s\n' "$f"; return 0; fi
  done
  return 1
}

wayland_session_present() {
  local sid uid typ state
  command -v loginctl >/dev/null 2>&1 || return 1
  while read -r sid uid _; do
    [[ -n "$sid" && "$uid" =~ ^[0-9]+$ ]] || continue
    typ="$(loginctl show-session "$sid" -p Type --value 2>/dev/null || true)"
    state="$(loginctl show-session "$sid" -p State --value 2>/dev/null || true)"
    if [[ "$typ" == wayland && "$state" == active ]]; then
      return 0
    fi
  done < <(loginctl list-sessions --no-legend 2>/dev/null || true)
  return 1
}

session_signature() {
  local found disp uid auth
  found="$(detect_display)" || return 1
  disp="${found%%|*}"
  uid="${found#*|}"
  auth="$(detect_xauth "$disp" "$uid")" || return 1
  printf '%s|%s|%s\n' "$disp" "$uid" "$auth"
}

while :; do
  # Em modo auto, acompanha DHCP pela rota ao DC; nunca usa 0.0.0.0 nem
  # escolhe arbitrariamente outra interface quando a rota não existe.
  if [[ "$AUTO_IP" == "true" ]]; then
    NEW_LISTEN="$(ip route get "$DC_IP" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
    if ! valid_ipv4 "$NEW_LISTEN" || ! ip -o -4 addr show | awk '{split($4,a,"/"); print a[1]}' | grep -Fxq "$NEW_LISTEN"; then
      set_status "AGUARDANDO_REDE" "Sem rota interna válida para DC $DC_IP; transmissão suspensa."
      stop_child
      sleep 5
      continue
    fi
    if [[ "$NEW_LISTEN" != "$LISTEN" ]]; then
      set_status "RECONFIGURANDO_REDE" "IP interno mudou de $LISTEN para $NEW_LISTEN; reiniciando apenas o backend VNC."
      stop_child
      LISTEN="$NEW_LISTEN"
    fi
  fi
  # Fail closed: rejeita endereço inválido ou não configurado localmente.
  if ! valid_ipv4 "$LISTEN"; then
    set_status "ERRO_CONFIGURACAO" "Endereço de escuta IPv4 inválido ou não permitido; VNC suspenso."
    stop_child
    sleep 5
    continue
  fi
  if ! ip -o -4 addr show | awk '{split($4,a,"/"); print a[1]}' | grep -Fxq "$LISTEN"; then
    set_status "AGUARDANDO_REDE" "Endereço interno $LISTEN indisponível; fail-closed ativo."
    stop_child
    sleep 5
    continue
  fi

  SIG="$(session_signature 2>/dev/null || true)"
  if [[ -z "$SIG" ]]; then
    [[ -n "$CHILD" ]] && stop_child
    if wayland_session_present; then
      set_status "BACKEND_NAO_SUPORTADO" "Sessão Wayland ativa detectada; x11vnc não captura Wayland diretamente."
    else
      set_status "AGUARDANDO_SESSAO" "Nenhuma sessão X11 com Xauthority validada; transmissão suspensa."
    fi
    sleep 3
    continue
  fi

  if [[ "$SIG" != "$CHILD_SIG" || -z "$CHILD" ]] || ! kill -0 "$CHILD" 2>/dev/null; then
    if [[ -n "$CHILD" ]]; then
      kill "$CHILD" 2>/dev/null || true
      wait "$CHILD" 2>/dev/null || true
    fi
    DISP="${SIG%%|*}"
    SIG_REST="${SIG#*|}"
    SESSION_UID="${SIG_REST%%|*}"
    AUTH="${SIG_REST#*|}"
    set_status "INICIANDO" "backend=x11vnc display=$DISP sessão=$SESSION_UID escuta=$LISTEN:$PORT"
    "$X11VNC_BIN" \
      -display "$DISP" -auth "$AUTH" \
      -rfbauth "$PASSFILE" -rfbport "$PORT" -listen "$LISTEN" \
      -forever -shared -repeat -noxdamage -nolookup -noipv6 \
      -logappend -o /var/log/seederlinux-vnc.log &
    CHILD=$!
    CHILD_SIG="$SIG"
    # Não anuncia ATIVO apenas porque o processo existe: exige que ss confirme
    # o socket na interface/porta esperadas. Falha de inspeção nunca vira sucesso.
    listener_rc=1
    for _try in 1 2 3 4 5 6; do
      if ! kill -0 "$CHILD" 2>/dev/null; then break; fi
      listener_check; listener_rc=$?
      [[ "$listener_rc" -eq 0 ]] && break
      sleep 1
    done
    if ! kill -0 "$CHILD" 2>/dev/null; then
      wait "$CHILD" 2>/dev/null || true
      CHILD=""
      CHILD_SIG=""
      set_status "ERRO_RECUPERAVEL" "x11vnc encerrou durante a inicialização; nova tentativa."
      sleep 3
    elif [[ "$listener_rc" -eq 0 ]]; then
      set_status "ATIVO" "backend=x11vnc display=$DISP sessão=$SESSION_UID escuta=$LISTEN:$PORT"
    elif [[ "$listener_rc" -eq 3 ]]; then
      stop_child
      set_status "ERRO_VALIDACAO" "Não foi possível verificar o listener (ss/iproute2 ausente ou erro); backend encerrado por segurança."
      sleep 5
    elif [[ "$listener_rc" -eq 2 ]]; then
      stop_child
      set_status "ERRO_SEGURANCA" "Listener detectado em endereço inesperado; backend encerrado."
      sleep 5
    else
      stop_child
      set_status "ERRO_RECUPERAVEL" "x11vnc não abriu a porta esperada; nova tentativa."
      sleep 3
    fi
  fi
  sleep 3
done
SUPERVISOR_EOF
# Substitui somente os placeholders controlados pelo provisionador.
sed -i \
  -e "s|{{VNC_LISTEN_ADDRESS}}|$VNC_LISTEN_ADDRESS|g" \
  -e "s|{{VNC_PORT}}|$VNC_PORT|g" \
  -e "s|{{X11VNC_BIN}}|$X11VNC_BIN|g" \
  -e "s|{{AUTO_IP}}|$AUTO_IP|g" \
  -e "s|{{DC_IP}}|$DC_IP|g" "$SUPERVISOR"
chmod 750 "$SUPERVISOR"
chown root:root "$SUPERVISOR"

cat > "/etc/systemd/system/$UNIT" <<'UNIT_EOF'
[Unit]
Description=SeederLinux Lite - VNC adaptativo para sessão gráfica existente
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
ReadWritePaths=/run /var/log/seederlinux-vnc.log
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
LockPersonality=true

[Install]
WantedBy=multi-user.target
UNIT_EOF

touch /var/log/seederlinux-vnc.log
chown root:root /var/log/seederlinux-vnc.log
chmod 600 /var/log/seederlinux-vnc.log

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

systemctl daemon-reload
systemctl enable --now "$UNIT"
log_nivel INFO "Supervisor VNC v4 instalado e habilitado; ATIVO só é publicado após confirmação do listener por ss."
log_nivel AVISO "Backend implementado: X11/x11vnc. Wayland ativo é detectado e marcado como BACKEND_NAO_SUPORTADO; não há captura Wayland universal segura neste módulo."
log_nivel INFO "Status: /run/seederlinux-vnc.status; logs: journalctl -u $UNIT e /var/log/seederlinux-vnc.log."
log_nivel INFO "Escuta inicial limitada a ${VNC_LISTEN_ADDRESS}:${VNC_PORT} (modo_auto=$AUTO_IP); confirme também a política de firewall da OM."
) || echo ">>> [AVISO] core_vnc.sh terminou com erro (veja as linhas acima); o bundle continua."
