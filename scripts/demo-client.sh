#!/usr/bin/env bash
# demo-client.sh — point this Mac's KioMeet app at the host Mac.
#
# Run on the SECOND device after the host's IP changes.
#
#   ./scripts/demo-client.sh 10.88.184.82
#
# Accepts a bare IP, host:port, or a full URL — all normalise to the same thing:
#   10.88.184.82            http://10.88.184.82:3000
#   10.88.184.82:3000       http://10.88.184.82:3000
#   http://10.88.184.82:3000  http://10.88.184.82:3000
#
# The host IP is printed by scripts/demo-up.sh on the host Mac.
#
set -uo pipefail

BUNDLE_ID="Secure.inter"          # from inter/Info.plist CFBundleIdentifier
KEY="InterTokenServerURLOverride" # read by InterAppConfig.resolve()
PORT_DEFAULT=3000
TIMEOUT=15                        # hotspots can be slow; 6s was too tight
ATTEMPTS=3

ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }
bad()  { printf "  \033[31m✗\033[0m %s\n" "$1"; }
info() { printf "  • %s\n" "$1"; }

RAW="${1:-}"
if [ -z "$RAW" ]; then
    echo "usage: $0 <host-ip>"
    echo "       e.g. $0 10.88.184.82   (get it from demo-up.sh on the host)"
    exit 1
fi

# -------------------------------------------------------------- normalise
# Strip any scheme, any trailing slash/path, then re-add the default port if
# one was not supplied. This makes the script forgiving about what you paste.
HOSTPORT="${RAW#http://}"
HOSTPORT="${HOSTPORT#https://}"
HOSTPORT="${HOSTPORT%%/*}"
case "$HOSTPORT" in
    *:*) ;;                                   # port already present
    *)   HOSTPORT="$HOSTPORT:$PORT_DEFAULT" ;;
esac
URL="http://$HOSTPORT"

printf "\033[1mPointing app at %s\033[0m\n" "$URL"
[ "$RAW" != "${HOSTPORT%:$PORT_DEFAULT}" ] && [ "$RAW" != "$HOSTPORT" ] \
    && info "(normalised from \"$RAW\")"
echo

# ------------------------------------------------------------ reachability
# Do NOT hide curl's error — not knowing *why* it failed was the original flaw.
REACHED=0
for i in $(seq 1 "$ATTEMPTS"); do
    info "attempt $i/$ATTEMPTS: GET $URL/health (timeout ${TIMEOUT}s)"
    ERRFILE="$(mktemp)"
    BODY="$(curl -sS --max-time "$TIMEOUT" -w $'\n%{http_code}' "$URL/health" 2>"$ERRFILE")"
    RC=$?
    CURL_ERR="$(cat "$ERRFILE")"; rm -f "$ERRFILE"

    CODE="$(printf '%s' "$BODY" | tail -1)"
    JSON="$(printf '%s' "$BODY" | sed '$d')"

    if [ "$RC" -eq 0 ] && [ "$CODE" = "200" ]; then
        case "$JSON" in
            *'"status":"ok"'*) ok "host reachable — $JSON"; REACHED=1; break ;;
            *) bad "HTTP 200 but unexpected body: $JSON"
               info "something else may be listening on that port (not our backend)"
               break ;;
        esac
    fi

    # Surface the real reason rather than a generic failure.
    [ -n "$CURL_ERR" ] && info "curl: $CURL_ERR"
    [ "$RC" -ne 0 ] && info "curl exit code: $RC"
    [ "$RC" -eq 0 ] && [ "$CODE" != "200" ] && info "HTTP $CODE"
    [ "$i" -lt "$ATTEMPTS" ] && sleep 2
done

if [ "$REACHED" -ne 1 ]; then
    echo
    bad "could not reach $URL/health after $ATTEMPTS attempts"
    info "checklist:"
    info "  1. demo-up.sh has been run on the HOST, and printed this IP"
    info "  2. the IP is current — it changes on every hotspot reconnect"
    info "  3. both Macs are on the same network (compare the first 3 octets)"
    info "  4. this device's own IP: $(ipconfig getifaddr en0 2>/dev/null || echo 'none on en0')"
    info "  5. if curl says 'Operation timed out', the network is isolating"
    info "     clients from each other — some Android hotspots do this"
    info "  6. if it says 'Connection refused', the host is reachable but the"
    info "     backend is not running — re-run demo-up.sh on the host"
    echo
    info "setting the override anyway so it is ready once the host is up"
fi

echo
defaults write "$BUNDLE_ID" "$KEY" "$URL"
ok "set $KEY = $(defaults read "$BUNDLE_ID" "$KEY" 2>/dev/null)"

echo
info "now relaunch the app:"
info "    ./inter.app/Contents/MacOS/inter      (logs to terminal)"
echo
info "to watch the app's resolved-server log line:"
info "    log stream --predicate 'process == \"inter\"' --level info"
echo
info "to undo: defaults delete $BUNDLE_ID $KEY"
