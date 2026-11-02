#!/usr/bin/env bash
# demo-up.sh — bring up the KioMeet demo stack for two-device testing.
#
# THE SINGLE CHANGE POINT. Run this on the HOST Mac after any network change
# (hotspot reconnect, Wi-Fi switch). It auto-detects the host IP and applies it
# everywhere it is needed:
#
#   1. token-server/.env  -> LIVEKIT_SERVER_URL / LIVEKIT_HTTP_URL
#   2. livekit-server     -> --bind 0.0.0.0 --node-ip <IP>
#   3. prints the exact command to run on the SECOND device
#
# You never edit an IP by hand. Just re-run this.
#
#   ./scripts/demo-up.sh            # auto-detect
#   ./scripts/demo-up.sh 10.0.0.5   # or force a specific IP
#
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO/token-server/.env"
LK_LOG=/tmp/kiomeet-livekit.log
TS_LOG=/tmp/kiomeet-token-server.log

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }
bad()  { printf "  \033[31m✗\033[0m %s\n" "$1"; }
info() { printf "  • %s\n" "$1"; }

# ---------------------------------------------------------------- detect IP
detect_ip() {
    local ip
    for iface in en0 en1 en2 en3; do
        ip="$(ipconfig getifaddr "$iface" 2>/dev/null)"
        [ -n "$ip" ] && { echo "$ip"; return 0; }
    done
    # last resort: first non-loopback IPv4
    ip="$(ifconfig 2>/dev/null | awk '/inet /&&$2!="127.0.0.1"{print $2; exit}')"
    [ -n "$ip" ] && { echo "$ip"; return 0; }
    return 1
}

IP="${1:-$(detect_ip)}"
if [ -z "${IP:-}" ]; then
    bad "No network IP found. Connect to Wi-Fi/hotspot and re-run."
    exit 1
fi

bold "KioMeet demo stack"
info "host IP: $IP"
echo

# ------------------------------------------------------- prerequisite checks
bold "1. Prerequisites"
if pg_isready >/dev/null 2>&1; then ok "PostgreSQL up"
else bad "PostgreSQL down — run: brew services start postgresql"; exit 1; fi

if [ "$(redis-cli ping 2>/dev/null)" = "PONG" ]; then ok "Redis up"
else bad "Redis down — run: brew services start redis"; exit 1; fi

command -v livekit-server >/dev/null 2>&1 && ok "livekit-server installed" \
    || { bad "livekit-server not found — brew install livekit"; exit 1; }
echo

# -------------------------------------------------------------- update .env
bold "2. Point token-server at $IP"
if [ ! -f "$ENV_FILE" ]; then bad "missing $ENV_FILE"; exit 1; fi
# Back up OUTSIDE the repo: a .env.bak inside it would not be gitignored.
cp "$ENV_FILE" "/tmp/kiomeet-env-backup-$(date +%s).env"
sed -i '' "s|^LIVEKIT_SERVER_URL=.*|LIVEKIT_SERVER_URL=ws://$IP:7880|"   "$ENV_FILE"
sed -i '' "s|^LIVEKIT_HTTP_URL=.*|LIVEKIT_HTTP_URL=http://$IP:7880|"     "$ENV_FILE"
ok "LIVEKIT_SERVER_URL=ws://$IP:7880"
ok "LIVEKIT_HTTP_URL=http://$IP:7880"
info "backup in /tmp (outside repo, so secrets cannot leak into git)"
echo

# ------------------------------------------------------- stop stale servers
bold "3. Stop anything stale"
# Stale loopback-only livekit is the #1 cause of "[room/create] LiveKit
# unreachable: fetch failed" — plain `livekit-server --dev` binds 127.0.0.1.
if pkill -f "livekit-server" 2>/dev/null; then ok "stopped old livekit-server"; else info "no livekit-server running"; fi
TS_PIDS="$(pgrep -f "node .*index\.js" 2>/dev/null || true)"
if [ -n "$TS_PIDS" ]; then kill $TS_PIDS 2>/dev/null; ok "stopped old token-server"; else info "no token-server running"; fi
sleep 2
echo

# ------------------------------------------------------------ start servers
bold "4. Start servers"
nohup livekit-server --dev --bind 0.0.0.0 --node-ip "$IP" >"$LK_LOG" 2>&1 &
sleep 3
nohup env -C "$REPO/token-server" node index.js >"$TS_LOG" 2>&1 &
sleep 4

if grep -q '"bindAddresses": \["0.0.0.0"\]' "$LK_LOG" 2>/dev/null; then
    ok "livekit bound to 0.0.0.0 (reachable from other devices)"
else
    bad "livekit may be loopback-only — check $LK_LOG"
fi
grep -q "nodeIP\":\"$IP\"\|nodeIP\": \"$IP\"" "$LK_LOG" 2>/dev/null \
    && ok "livekit advertising $IP" \
    || info "check nodeIP in $LK_LOG"
echo

# ------------------------------------------------------------------ verify
bold "5. Verify over the network (not loopback)"
LK_CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "http://$IP:7880" 2>/dev/null || echo 000)"
[ "$LK_CODE" = "200" ] && ok "livekit  http://$IP:7880 -> 200" || bad "livekit unreachable on $IP:7880 (HTTP $LK_CODE)"

HEALTH="$(curl -sS --max-time 5 "http://$IP:3000/health" 2>/dev/null || echo '')"
case "$HEALTH" in
    *'"status":"ok"'*) ok "backend  http://$IP:3000/health -> ok" ;;
    *) bad "backend unreachable on $IP:3000 — check $TS_LOG" ;;
esac

# Bind check: *:PORT means all interfaces; 127.0.0.1:PORT means loopback only.
for p in 3000 7880; do
    if lsof -iTCP:"$p" -sTCP:LISTEN -P -n 2>/dev/null | grep -q "\*:$p"; then
        ok "port $p bound to all interfaces"
    else
        bad "port $p NOT bound to all interfaces — second device cannot reach it"
    fi
done
echo

# -------------------------------------------------------- second-device copy
bold "6. Run this on the SECOND device"
echo
echo "    defaults write Secure.inter InterTokenServerURLOverride \"http://$IP:3000\""
echo
info "then relaunch the app. Verify first with:"
echo "    curl http://$IP:3000/health"
echo
info "if curl hangs, the network is isolating clients (some Android hotspots do)"
echo
bold "Logs"
info "livekit      : tail -f $LK_LOG"
info "token-server : tail -f $TS_LOG"
echo
info "Re-run this script after every network change. Do not start livekit-server"
info "by hand — plain 'livekit-server --dev' binds loopback only and silently"
info "breaks the second device."
