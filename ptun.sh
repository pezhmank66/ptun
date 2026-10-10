#!/usr/bin/env bash
# =============================================================================
#  ptun - private encrypted TCP+UDP port-forward tunnel
#  Core : Xray  (VLESS + Reality + Vision, TLS 1.3, X25519, uTLS chrome)
#  Use  : run on the FOREIGN server first, then on the IRAN server.
#         sudo ptun          -> interactive menu
#         ptun status|logs|restart|code|update|uninstall
# =============================================================================
set -u

VERSION="1.0.0"
# Put your own raw URL here after uploading to GitHub (used for self-install/update)
REPO_RAW="${PTUN_REPO_RAW:-https://raw.githubusercontent.com/pezhmank66/ptun/main/ptun.sh}"
XRAY_VERSION="${XRAY_VERSION:-latest}"

BASE=/etc/ptun
CONF=$BASE/ptun.conf
XCONF=$BASE/config.json
XDIR=/opt/ptun
BIN=$XDIR/xray
SELF=/usr/local/bin/ptun
UNIT=/etc/systemd/system
SYSCTL=/etc/sysctl.d/99-ptun.conf
DEF_SNI="www.microsoft.com"
DEF_TUN_PORT=7443
HEALTH_PORT=41099
WATCH_FAILS=3
NOGRP=$(id -gn nobody 2>/dev/null || echo nogroup)

ROLE=""; PEER_IP=""; TUN_PORT=""; SNI=""; UUID=""; PRIV=""; PUB=""; SID=""; PORTS=""; PUBIP=""

C0=$'\033[0m'; CR=$'\033[31m'; CG=$'\033[32m'; CY=$'\033[33m'; CB=$'\033[36m'; CD=$'\033[2m'
info(){ echo -e "${CB}[*]${C0} $*"; }
ok(){   echo -e "${CG}[+]${C0} $*"; }
warn(){ echo -e "${CY}[!]${C0} $*"; }
err(){  echo -e "${CR}[x]${C0} $*" >&2; }
die(){  err "$*"; exit 1; }
pause(){ read -rp "Press Enter to continue..." _; }

# ----------------------------------------------------------------- helpers ---
need_root(){ [ "$(id -u)" -eq 0 ] || die "Run as root (sudo ptun)."; }

ask(){ # ask "prompt" "default" VARNAME
  local _p="$1" _d="${2:-}" _v
  if [ -n "$_d" ]; then read -rp "$_p [$_d]: " _v; _v="${_v:-$_d}"; else read -rp "$_p: " _v; fi
  printf -v "$3" '%s' "$_v"
}
yesno(){ # yesno "question" default(y|n)
  local _d="${2:-n}" _a _h="y/N"; [ "$_d" = y ] && _h="Y/n"
  read -rp "$1 [$_h]: " _a; _a="${_a:-$_d}"; [[ "$_a" =~ ^[Yy] ]]
}
valid_ip(){
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS=. o; for o in $1; do [ "$((10#$o))" -le 255 ] || return 1; done; return 0
}
valid_port(){ [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
port_busy(){ ss -Hltn "sport = :$1" 2>/dev/null | grep -q . || ss -Hlun "sport = :$1" 2>/dev/null | grep -q .; }

parse_ports(){ # "443,2083 10000-10005" -> "443 2083 10000 ..." (rc 1 on error)
  local raw="${1//,/ }" t a b p out=() seen=" "
  for t in $raw; do
    if [[ "$t" =~ ^[0-9]+-[0-9]+$ ]]; then
      a=${t%-*}; b=${t#*-}
      valid_port "$a" && valid_port "$b" && [ "$a" -le "$b" ] && [ $((b-a)) -le 200 ] || return 1
      for ((p=a; p<=b; p++)); do [[ "$seen" == *" $p "* ]] || { out+=("$p"); seen+="$p "; }; done
    else
      valid_port "$t" || return 1
      [[ "$seen" == *" $t "* ]] || { out+=("$t"); seen+="$t "; }
    fi
  done
  [ "${#out[@]}" -ge 1 ] && [ "${#out[@]}" -le 300 ] || return 1
  echo "${out[*]}"
}

pm_install(){
  if   command -v apt-get >/dev/null 2>&1; then apt-get update -y >/dev/null 2>&1 || true; DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >/dev/null 2>&1
  elif command -v dnf     >/dev/null 2>&1; then dnf install -y "$@" >/dev/null 2>&1
  elif command -v yum     >/dev/null 2>&1; then yum install -y "$@" >/dev/null 2>&1
  else return 1; fi
}
need(){ local c; for c in "$@"; do command -v "$c" >/dev/null 2>&1 || { info "Installing $c ..."; pm_install "$c" || die "Could not install $c"; }; done; }

myip(){ curl -4 -fsS -m 8 https://api.ipify.org 2>/dev/null || ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'; }
check_sni(){ echo | timeout 10 openssl s_client -connect "$1:443" -servername "$1" -tls1_3 2>/dev/null | grep -qi "TLSv1.3"; }
ufw_on(){ command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "^Status: active"; }

save_conf(){
  mkdir -p "$BASE"
  ( umask 077; cat > "$CONF" <<EOF
ROLE="$ROLE"
PEER_IP="$PEER_IP"
PUBIP="$PUBIP"
TUN_PORT="$TUN_PORT"
SNI="$SNI"
UUID="$UUID"
PRIV="$PRIV"
PUB="$PUB"
SID="$SID"
PORTS="$PORTS"
EOF
  )
}
load_conf(){ [ -f "$CONF" ] || return 1; # shellcheck disable=SC1090
  . "$CONF"; return 0; }

# ------------------------------------------------------------- xray core -----
install_core(){
  [ -x "$BIN" ] && return 0
  need curl unzip openssl
  local A tmp url want have lp
  case "$(uname -m)" in
    x86_64|amd64)  A=64 ;;
    aarch64|arm64) A=arm64-v8a ;;
    armv7l)        A=arm32-v7a ;;
    *) die "Unsupported CPU: $(uname -m)" ;;
  esac
  tmp=$(mktemp -d)
  if [ "$XRAY_VERSION" = latest ]; then url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-$A.zip"
  else url="https://github.com/XTLS/Xray-core/releases/download/$XRAY_VERSION/Xray-linux-$A.zip"; fi
  info "Downloading Xray core ($XRAY_VERSION) ..."
  if curl -fL --retry 3 --connect-timeout 15 -m 180 -o "$tmp/x.zip" "$url"; then
    if curl -fsL --connect-timeout 15 -m 30 -o "$tmp/x.dgst" "$url.dgst"; then
      want=$(grep -i 'sha2-256' "$tmp/x.dgst" | awk -F'= ' '{print $2}' | tr -d ' \r\n' | head -c 64)
      have=$(sha256sum "$tmp/x.zip" | awk '{print $1}')
      if [[ "$want" =~ ^[0-9a-fA-F]{64}$ ]]; then
        [ "${want,,}" = "$have" ] || { rm -rf "$tmp"; die "Checksum mismatch - aborting."; }
        ok "Checksum verified"
      else warn "Could not parse checksum file, continuing."; fi
    else warn "Checksum file unavailable, continuing."; fi
  else
    warn "Download failed (GitHub unreachable from this server?)."
    echo "Copy the xray binary (or Xray-linux-64.zip) to this server first, for example:"
    echo "   scp root@OTHER_SERVER:/opt/ptun/xray /root/xray"
    read -rp "Path to local xray binary or zip (empty = abort): " lp
    [ -n "$lp" ] && [ -f "$lp" ] || { rm -rf "$tmp"; die "Aborted."; }
    if [[ "$lp" == *.zip ]]; then cp "$lp" "$tmp/x.zip"
    else
      mkdir -p "$XDIR"; install -m 755 "$lp" "$BIN"; rm -rf "$tmp"
      "$BIN" version >/dev/null 2>&1 || { rm -f "$BIN"; die "Not a valid xray binary."; }
      ok "Xray installed from local file"; return 0
    fi
  fi
  mkdir -p "$XDIR"
  unzip -o -q "$tmp/x.zip" xray -d "$XDIR" || { rm -rf "$tmp"; die "unzip failed"; }
  chmod 755 "$XDIR" "$BIN"; rm -rf "$tmp"
  ok "$("$BIN" version 2>/dev/null | head -1)"
}

gen_secrets(){
  local k; k=$("$BIN" x25519 2>/dev/null) || { err "xray x25519 failed"; return 1; }
  PRIV=$(echo "$k" | sed -n 1p | awk '{print $NF}')
  PUB=$(echo "$k" | sed -n 2p | awk '{print $NF}')
  [ "${#PRIV}" -ge 40 ] && [ "${#PUB}" -ge 40 ] || { err "Key generation failed: $k"; return 1; }
  UUID=$(cat /proc/sys/kernel/random/uuid)
  SID=$(openssl rand -hex 8)
}

write_xconf(){
  mkdir -p "$BASE"
  local tmp inb="" p; tmp=$(mktemp)
  if [ "$ROLE" = foreign ]; then
    cat > "$tmp" <<EOF
{
 "log": {"loglevel": "warning", "access": "none"},
 "inbounds": [{
  "tag": "tun-in", "listen": "0.0.0.0", "port": $TUN_PORT, "protocol": "vless",
  "settings": {"clients": [{"id": "$UUID", "flow": "xtls-rprx-vision"}], "decryption": "none"},
  "streamSettings": {
   "network": "tcp", "security": "reality",
   "realitySettings": {"show": false, "dest": "$SNI:443", "xver": 0,
     "serverNames": ["$SNI"], "privateKey": "$PRIV", "shortIds": ["$SID"]},
   "sockopt": {"tcpKeepAliveIdle": 30, "tcpKeepAliveInterval": 15}
  }
 }],
 "outbounds": [
  {"protocol": "freedom", "tag": "direct"},
  {"protocol": "blackhole", "tag": "block"}
 ],
 "routing": {"rules": [
  {"type": "field", "ip": ["127.0.0.1/32", "1.1.1.1/32"], "outboundTag": "direct"},
  {"type": "field", "network": "tcp,udp", "outboundTag": "block"}
 ]}
}
EOF
  else
    for p in $PORTS; do
      inb+="{\"tag\":\"in-$p\",\"listen\":\"0.0.0.0\",\"port\":$p,\"protocol\":\"dokodemo-door\",\"settings\":{\"address\":\"127.0.0.1\",\"port\":$p,\"network\":\"tcp,udp\"}},"
    done
    inb+="{\"tag\":\"health\",\"listen\":\"127.0.0.1\",\"port\":$HEALTH_PORT,\"protocol\":\"dokodemo-door\",\"settings\":{\"address\":\"1.1.1.1\",\"port\":443,\"network\":\"tcp\"}}"
    cat > "$tmp" <<EOF
{
 "log": {"loglevel": "warning", "access": "none"},
 "inbounds": [$inb],
 "outbounds": [{
  "tag": "tun", "protocol": "vless",
  "settings": {"vnext": [{"address": "$PEER_IP", "port": $TUN_PORT,
    "users": [{"id": "$UUID", "encryption": "none", "flow": "xtls-rprx-vision"}]}]},
  "streamSettings": {
   "network": "tcp", "security": "reality",
   "realitySettings": {"serverName": "$SNI", "fingerprint": "chrome",
     "publicKey": "$PUB", "shortId": "$SID", "spiderX": "/"},
   "sockopt": {"tcpKeepAliveIdle": 30, "tcpKeepAliveInterval": 15}
  }
 }]
}
EOF
  fi
  if ! "$BIN" run -test -config "$tmp" >/dev/null 2>&1; then
    err "Generated config failed validation:"; "$BIN" run -test -config "$tmp"; rm -f "$tmp"; return 1
  fi
  install -m 640 -o root -g "$NOGRP" "$tmp" "$XCONF"; rm -f "$tmp"
}

write_unit(){
  cat > "$UNIT/ptun.service" <<EOF
[Unit]
Description=ptun tunnel (xray)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
User=nobody
Group=$NOGRP
ExecStart=$BIN run -config $XCONF
Restart=always
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

start_service(){
  systemctl enable ptun >/dev/null 2>&1
  systemctl restart ptun; sleep 2
  if ! systemctl is-active -q ptun; then err "Service failed to start:"; journalctl -u ptun -n 20 --no-pager; return 1; fi
  ok "ptun service is running"
}

self_install(){
  [ "$0" = "$SELF" ] && return 0
  if [ -f "$0" ] && [[ "$0" != /dev/fd/* ]] && [[ "$0" != /proc/* ]]; then install -m 755 "$0" "$SELF"
  elif curl -fsSL -m 30 "$REPO_RAW" -o "$SELF.tmp" 2>/dev/null; then mv "$SELF.tmp" "$SELF"; chmod 755 "$SELF"
  else rm -f "$SELF.tmp"; warn "Could not install the 'ptun' command. Save this script as $SELF (chmod +x)."; fi
}

tune_net(){
  [ -f "$SYSCTL" ] && return 0
  yesno "Enable BBR + fq congestion control (recommended)?" y || return 0
  cat > "$SYSCTL" <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_slow_start_after_idle=0
EOF
  sysctl --system >/dev/null 2>&1 || true
  ok "Congestion control now: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
}

# ---------------------------------------------------------------- firewall ---
fw_foreign_add(){ ufw_on && ufw allow from "$PEER_IP" to any port "$TUN_PORT" proto tcp >/dev/null && ok "ufw: allowed $PEER_IP -> tcp/$TUN_PORT"; return 0; }
fw_foreign_del(){ ufw_on && ufw delete allow from "$PEER_IP" to any port "$TUN_PORT" proto tcp >/dev/null 2>&1; return 0; }
fw_iran_add(){ local p; ufw_on || return 0; for p in $1; do ufw allow "$p" >/dev/null; done; ok "ufw: opened $1"; return 0; }
fw_iran_del(){ local p; ufw_on || return 0; for p in $1; do ufw delete allow "$p" >/dev/null 2>&1; done; return 0; }
fw_note(){ ufw_on || warn "ufw is not active. If you use another firewall (iptables/cloud panel) open the needed ports yourself."; }

# ------------------------------------------------------------ pairing code ---
make_code(){ echo "PT1:$PUBIP|$UUID|$PUB|$SID|$SNI|$TUN_PORT"; }
parse_code(){
  local c ip u pub sid sni tp
  c=$(echo "$1" | tr -d ' \r\n'); c="${c#PT1:}"
  IFS='|' read -r ip u pub sid sni tp <<< "$c"
  valid_ip "${ip:-}" && [[ "${u:-}" =~ ^[0-9a-f-]{36}$ ]] && [ "${#pub}" -ge 40 ] \
    && [[ "${sid:-}" =~ ^[0-9a-f]{2,16}$ ]] && [ -n "${sni:-}" ] && valid_port "${tp:-x}" || return 1
  PEER_IP=$ip; UUID=$u; PUB=$pub; SID=$sid; SNI=$sni; TUN_PORT=$tp
}
show_code(){
  echo
  echo "================= PAIRING CODE (copy the whole line) ================="
  make_code
  echo "======================================================================"
  echo "On the IRAN server run: ptun  -> Install, choose IRAN, paste this code."
}

# ------------------------------------------------------------------ setup ----
ask_sni(){
  while :; do
    ask "Reality SNI / camouflage site (TLS 1.3 site reachable from this server)" "${1:-$DEF_SNI}" SNI
    if check_sni "$SNI"; then ok "TLS 1.3 OK for $SNI"; break; fi
    yesno "TLS 1.3 test failed for $SNI. Use it anyway?" n && break
  done
}

setup_foreign(){
  ROLE=foreign
  systemctl stop ptun 2>/dev/null
  while :; do ask "Iran server IP (the only IP allowed to connect)" "" PEER_IP; valid_ip "$PEER_IP" && break; err "Invalid IPv4."; done
  while :; do
    ask "Tunnel TCP port on this server" "$DEF_TUN_PORT" TUN_PORT
    valid_port "$TUN_PORT" || { err "Invalid port."; continue; }
    port_busy "$TUN_PORT" && { err "Port $TUN_PORT is already in use."; continue; }
    break
  done
  ask "This server's public IP" "$(myip)" PUBIP
  valid_ip "$PUBIP" || { err "Invalid IP."; return 1; }
  need curl openssl; ask_sni
  install_core; gen_secrets || return 1
  write_xconf || return 1
  PORTS=""; save_conf; write_unit; fw_foreign_add; fw_note; tune_net
  start_service || return 1
  self_install
  show_code
}

setup_iran(){
  ROLE=iran
  local code plist old_ports="$PORTS"
  while :; do
    read -rp "Paste the pairing code from the foreign server: " code
    parse_code "$code" && break; err "Invalid pairing code."
  done
  while :; do ask "Foreign server IP" "$PEER_IP" PEER_IP; valid_ip "$PEER_IP" && break; err "Invalid IPv4."; done
  echo "Ports to forward (TCP+UDP both). Examples: 443,2083,8444   or ranges 20000-20010"
  while :; do
    read -rp "Ports: " plist
    PORTS=$(parse_ports "$plist") && break; err "Invalid list."
  done
  systemctl stop ptun 2>/dev/null
  local p bad=0
  for p in $PORTS $HEALTH_PORT; do port_busy "$p" && { err "Port $p is already in use on this server."; bad=1; }; done
  if [ "$bad" = 1 ]; then err "Free those ports first, then run Install again."; PORTS="$old_ports"; systemctl start ptun 2>/dev/null; return 1; fi
  need curl openssl; install_core
  write_xconf || return 1
  save_conf; write_unit; fw_iran_add "$PORTS"; fw_note; tune_net
  start_service || return 1
  self_install
  info "Testing the full path through the tunnel ..."
  sleep 2
  if health_ok; then ok "Tunnel works end-to-end (Iran -> foreign -> internet)."
  else warn "Health test failed. Check: foreign firewall allows $PEER_IP -> tcp/$TUN_PORT, and run: ptun logs"; fi
}

do_install(){
  need_root; command -v ss >/dev/null 2>&1 || pm_install iproute2
  if load_conf && [ -f "$XCONF" ]; then
    warn "ptun is already installed as role: $ROLE"
    yesno "Reconfigure from scratch?" n || return 0
  fi
  echo
  echo "Which server is this?"
  echo "  1) FOREIGN server (outside Iran)   <- do this one first"
  echo "  2) IRAN server"
  read -rp "Choice [1/2]: " c
  case "$c" in 1) setup_foreign ;; 2) setup_iran ;; *) err "Invalid choice." ;; esac
}

# ------------------------------------------------------------------ health ---
health_ok(){ echo | timeout 12 openssl s_client -connect "127.0.0.1:$HEALTH_PORT" -servername one.one.one.one 2>/dev/null | grep -q "BEGIN CERTIFICATE"; }

cmd_watch(){ # non-interactive, called by ptun-watch.timer
  load_conf || exit 0
  [ "$ROLE" = iran ] || exit 0
  systemctl is-active -q ptun || { echo "service not active - starting"; systemctl start ptun; exit 0; }
  local ff=/run/ptun-watch.fail lr=/run/ptun-watch.last n now last
  if health_ok; then
    [ -f "$ff" ] && [ "$(cat "$ff" 2>/dev/null)" != 0 ] && echo "recovered"
    rm -f "$ff"; exit 0
  fi
  n=$(( $(cat "$ff" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$ff"
  echo "health check failed ($n/$WATCH_FAILS)"
  if [ "$n" -ge "$WATCH_FAILS" ]; then
    now=$(date +%s); last=$(cat "$lr" 2>/dev/null || echo 0)
    if [ $((now-last)) -ge 300 ]; then echo "restarting ptun"; systemctl restart ptun; echo "$now" > "$lr"; echo 0 > "$ff"
    else echo "restart skipped (cooldown 5 min)"; fi
  fi
}

# --------------------------------------------------------------- commands ----
cmd_status(){
  load_conf || { warn "ptun is not installed."; return; }
  echo "Role        : $ROLE"
  echo "Peer IP     : $PEER_IP"
  echo "Tunnel port : $TUN_PORT   SNI: $SNI"
  [ "$ROLE" = iran ] && echo "Forwarded   : $PORTS  (TCP+UDP)"
  if systemctl is-active -q ptun; then ok "service: active since $(systemctl show ptun -p ActiveEnterTimestamp --value)"; else err "service: NOT active"; fi
  local n
  if [ "$ROLE" = iran ]; then
    n=$(ss -Htn state established 2>/dev/null | awk -v t="$PEER_IP:$TUN_PORT" '$4==t' | wc -l)
  else
    n=$(ss -Htn state established 2>/dev/null | awk -v p=":$TUN_PORT" '$3 ~ p"$"' | wc -l)
  fi
  echo "Connections : $n established tunnel sessions"
  if [ "$ROLE" = iran ]; then
    if health_ok; then ok "end-to-end test: PASS"; else warn "end-to-end test: FAIL"; fi
  fi
  systemctl is-active -q ptun-restart.timer 2>/dev/null && echo "Auto-restart: ON  ($(systemctl show ptun-restart.timer -p NextElapseUSecRealtime --value))" || echo "Auto-restart: off"
  [ "$ROLE" = iran ] && { systemctl is-active -q ptun-watch.timer 2>/dev/null && echo "Watchdog    : ON" || echo "Watchdog    : off"; }
}

cmd_logs(){
  echo "  1) Last 100 lines     2) Follow live (Ctrl+C to stop)"
  echo "  3) Warnings/errors    4) Watchdog log"
  read -rp "Choice: " c
  case "$c" in
    1) journalctl -u ptun -n 100 --no-pager ;;
    2) trap ':' INT; journalctl -u ptun -f -n 30; trap - INT ;;
    3) journalctl -u ptun -p warning -n 100 --no-pager ;;
    4) journalctl -u ptun-watch -n 100 --no-pager ;;
  esac
}

cmd_restart(){ systemctl restart ptun && sleep 1 && systemctl is-active -q ptun && ok "restarted" || err "restart failed (ptun logs)"; }

cmd_timer(){
  local h
  if systemctl is-active -q ptun-restart.timer 2>/dev/null; then ok "Auto-restart is ON"; else echo "Auto-restart is off"; fi
  echo "  1) Enable / change interval   2) Disable"
  read -rp "Choice: " c
  case "$c" in
    1) ask "Restart the tunnel every how many hours" "6" h
       [[ "$h" =~ ^[0-9]+$ ]] && [ "$h" -ge 1 ] || { err "Invalid number."; return; }
       cat > "$UNIT/ptun-restart.service" <<EOF
[Unit]
Description=ptun scheduled restart
[Service]
Type=oneshot
ExecStart=/bin/systemctl restart ptun
EOF
       cat > "$UNIT/ptun-restart.timer" <<EOF
[Unit]
Description=ptun scheduled restart timer
[Timer]
OnBootSec=${h}h
OnUnitActiveSec=${h}h
RandomizedDelaySec=120
[Install]
WantedBy=timers.target
EOF
       systemctl daemon-reload; systemctl enable --now ptun-restart.timer >/dev/null 2>&1
       ok "Tunnel will restart every $h hour(s)" ;;
    2) systemctl disable --now ptun-restart.timer >/dev/null 2>&1; rm -f "$UNIT/ptun-restart".{service,timer}; systemctl daemon-reload; ok "Auto-restart disabled" ;;
  esac
}

cmd_watchdog(){
  load_conf || { warn "Not installed."; return; }
  [ "$ROLE" = iran ] || { warn "The watchdog runs on the Iran server only."; return; }
  [ -x "$SELF" ] || self_install
  if systemctl is-active -q ptun-watch.timer 2>/dev/null; then ok "Watchdog is ON"; else echo "Watchdog is off"; fi
  echo "It tests the real data path every minute (Iran -> foreign -> internet)"
  echo "and restarts the tunnel after $WATCH_FAILS consecutive failures (5 min cooldown)."
  echo "  1) Enable   2) Disable   3) Run one check now"
  read -rp "Choice: " c
  case "$c" in
    1) cat > "$UNIT/ptun-watch.service" <<EOF
[Unit]
Description=ptun health watchdog
[Service]
Type=oneshot
ExecStart=$SELF watch
EOF
       cat > "$UNIT/ptun-watch.timer" <<EOF
[Unit]
Description=ptun health watchdog timer
[Timer]
OnBootSec=2min
OnUnitActiveSec=60s
AccuracySec=10s
[Install]
WantedBy=timers.target
EOF
       systemctl daemon-reload; systemctl enable --now ptun-watch.timer >/dev/null 2>&1; ok "Watchdog enabled" ;;
    2) systemctl disable --now ptun-watch.timer >/dev/null 2>&1; rm -f "$UNIT/ptun-watch".{service,timer}; systemctl daemon-reload; ok "Watchdog disabled" ;;
    3) if health_ok; then ok "PASS"; else err "FAIL"; fi ;;
  esac
}

cmd_ports(){
  load_conf || { warn "Not installed."; return; }
  [ "$ROLE" = iran ] || { warn "Ports are configured on the Iran server only."; return; }
  echo "Current ports: $PORTS"
  local plist new old="$PORTS" p bad=0
  read -rp "New port list (TCP+UDP), e.g. 443,2083,10000-10010: " plist
  new=$(parse_ports "$plist") || { err "Invalid list."; return; }
  systemctl stop ptun 2>/dev/null
  for p in $new; do port_busy "$p" && { err "Port $p is already in use."; bad=1; }; done
  if [ "$bad" = 1 ]; then systemctl start ptun 2>/dev/null; return; fi
  PORTS="$new"
  write_xconf || { PORTS="$old"; systemctl start ptun 2>/dev/null; return; }
  fw_iran_del "$old"; fw_iran_add "$PORTS"; save_conf; start_service
}

cmd_pair(){
  load_conf || { warn "Not installed."; return; }
  if [ "$ROLE" = foreign ]; then show_code; return; fi
  local code
  read -rp "Paste the NEW pairing code from the foreign server: " code
  parse_code "$code" || { err "Invalid pairing code."; return; }
  write_xconf || return; save_conf; start_service
  sleep 2; if health_ok; then ok "Tunnel works end-to-end."; else warn "Health test failed (ptun logs)."; fi
}

cmd_rekey(){ # foreign: change port / SNI / rotate keys
  load_conf || { warn "Not installed."; return; }
  [ "$ROLE" = foreign ] || { warn "Run this on the foreign server."; return; }
  local oldp="$TUN_PORT"
  systemctl stop ptun 2>/dev/null
  while :; do
    ask "Tunnel TCP port" "$TUN_PORT" TUN_PORT
    valid_port "$TUN_PORT" || { err "Invalid port."; continue; }
    [ "$TUN_PORT" != "$oldp" ] && port_busy "$TUN_PORT" && { err "Port in use."; continue; }
    break
  done
  ask_sni "$SNI"
  yesno "Generate NEW keys (UUID/Reality keys)?" y && { gen_secrets || return; }
  write_xconf || return
  [ "$oldp" != "$TUN_PORT" ] && { local np="$TUN_PORT"; TUN_PORT="$oldp"; fw_foreign_del; TUN_PORT="$np"; fw_foreign_add; }
  save_conf; start_service && show_code
}

cmd_update_core(){
  [ -x "$BIN" ] || { warn "Not installed."; return; }
  mv "$BIN" "$BIN.old"
  if install_core && [ -x "$BIN" ]; then rm -f "$BIN.old"; cmd_restart
  else mv "$BIN.old" "$BIN"; err "Update failed, previous version restored."; fi
}

cmd_uninstall(){
  need_root
  yesno "Remove ptun completely (service, config, timers)?" n || return 0
  if load_conf; then
    [ "$ROLE" = iran ] && fw_iran_del "$PORTS"
    [ "$ROLE" = foreign ] && fw_foreign_del
  fi
  systemctl disable --now ptun ptun-restart.timer ptun-watch.timer >/dev/null 2>&1
  rm -f "$UNIT"/ptun.service "$UNIT"/ptun-restart.{service,timer} "$UNIT"/ptun-watch.{service,timer}
  systemctl daemon-reload
  rm -rf "$BASE" "$XDIR" /run/ptun-watch.* "$SYSCTL"
  ok "ptun removed."
  yesno "Also delete the 'ptun' command ($SELF)?" y && rm -f "$SELF"
  exit 0
}

# -------------------------------------------------------------------- menu ---
banner(){
  clear 2>/dev/null
  echo -e "${CB}ptun $VERSION${C0}  private TCP+UDP tunnel  ${CD}(Xray VLESS+Reality+Vision)${C0}"
  if load_conf 2>/dev/null; then
    local st="stopped"; systemctl is-active -q ptun && st="running"
    echo -e "role: ${CG}$ROLE${C0}  peer: $PEER_IP  tunnel port: $TUN_PORT  service: $st"
  else echo -e "${CY}not installed${C0}"; fi
  echo
}

menu(){
  need_root
  while :; do
    banner
    echo "  1) Install / reconfigure"
    echo "  2) Status"
    echo "  3) Logs"
    echo "  4) Restart tunnel"
    echo "  5) Auto-restart timer"
    echo "  6) Health watchdog (Iran)"
    echo "  7) Change forwarded ports (Iran)"
    echo "  8) Pairing code (show on foreign / paste new on Iran)"
    echo "  9) Change tunnel port / SNI / rotate keys (foreign)"
    echo " 10) Update Xray core"
    echo " 11) Uninstall"
    echo "  0) Exit"
    echo
    read -rp "Select: " c
    case "$c" in
      1) do_install; pause ;;
      2) cmd_status; pause ;;
      3) cmd_logs; pause ;;
      4) cmd_restart; pause ;;
      5) cmd_timer; pause ;;
      6) cmd_watchdog; pause ;;
      7) cmd_ports; pause ;;
      8) cmd_pair; pause ;;
      9) cmd_rekey; pause ;;
     10) cmd_update_core; pause ;;
     11) cmd_uninstall; pause ;;
      0|q) exit 0 ;;
    esac
  done
}

case "${1:-menu}" in
  menu)      menu ;;
  watch)     cmd_watch ;;
  status)    need_root; cmd_status ;;
  logs)      need_root; journalctl -u ptun -n 100 --no-pager ;;
  restart)   need_root; cmd_restart ;;
  code)      need_root; cmd_pair ;;
  update)    need_root; cmd_update_core ;;
  uninstall) cmd_uninstall ;;
  version|-v|--version) echo "ptun $VERSION" ;;
  *) echo "usage: ptun [menu|status|logs|restart|code|update|uninstall|version]"; exit 1 ;;
esac
