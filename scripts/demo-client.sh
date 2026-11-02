#!/usr/bin/env bash
# demo-client.sh — point this Mac's KioMeet app at the host Mac.
#
# Run on the SECOND device after the host's IP changes.
#
#   ./scripts/demo-client.sh 10.88.184.82
#
# The host IP is printed by scripts/demo-up.sh on the host Mac.
#
set -uo pipefail

BUNDLE_ID="Secure.inter"          # from inter/Info.plist CFBundleIdentifier
KEY="InterTokenServerURLOverride" # read by InterAppConfig.resolve()

ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }
bad()  { printf "  \033[31m✗\033[0m %s\n" "$1"; }
info() { printf "  • %s\n" "$1"; }

IP="${1:-}"
if [ -z "$IP" ]; then
    echo "usage: $0 <host-ip>"
    echo "       e.g. $0 10.88.184.82   (get it from demo-up.sh on the host)"
    exit 1
fi

URL="http://$IP:3000"
printf "\033[1mPointing app at %s\033[0m\n" "$URL"

# Reachability first: this separates a network problem from an app problem.
echo
info "checking the host is reachable…"
HEALTH="$(curl -sS --max-time 6 "$URL/health" 2>/dev/null || echo '')"
case "$HEALTH" in
    *'"status":"ok"'*)
        ok "host reachable: $HEALTH"
        ;;
    *)
        bad "cannot reach $URL/health"
        info "check: both devices on the same network; demo-up.sh run on the host;"
        info "       the host IP is current; hotspot not isolating clients"
        echo
        info "setting the override anyway so it is ready when the host comes up"
        ;;
esac

defaults write "$BUNDLE_ID" "$KEY" "$URL"
ok "set $KEY = $(defaults read "$BUNDLE_ID" "$KEY" 2>/dev/null)"

echo
info "now relaunch the app:"
info "    ./inter.app/Contents/MacOS/inter      (logs to terminal)"
echo
info "to watch the app's own log line confirming the server it resolved:"
info "    log stream --predicate 'process == \"inter\"' --level info"
echo
info "to undo: defaults delete $BUNDLE_ID $KEY"
