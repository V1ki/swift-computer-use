#!/usr/bin/env bash
# Builds, installs ~/Applications/SwiftCUA.app and registers a LaunchAgent.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SRC="$ROOT/build/SwiftCUA.app"
APP_DEST="$HOME/Applications/SwiftCUA.app"
PLIST="$HOME/Library/LaunchAgents/dev.v1ki.swiftcua.service.plist"
LABEL="dev.v1ki.swiftcua.service"

"$ROOT/scripts/build-app.sh"

echo "==> install app"
mkdir -p "$HOME/Applications" "$HOME/Library/Logs/SwiftCUA" "$HOME/Library/LaunchAgents"
rm -rf "$APP_DEST"
cp -R "$APP_SRC" "$APP_DEST"

echo "==> install launch agent"
sed -e "s#__APP__#$APP_DEST#g" -e "s#__HOME__#$HOME#g" \
    "$ROOT/Resources/dev.v1ki.swiftcua.service.plist" > "$PLIST"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"
launchctl kickstart -k "gui/$UID/$LABEL"

echo "==> wait for socket"
SOCKET="$HOME/Library/Application Support/SwiftCUA/IPC/computeruse.sock"
for _ in $(seq 1 50); do
    [[ -S "$SOCKET" ]] && break
    sleep 0.1
done
if [[ -S "$SOCKET" ]]; then
    echo "    socket ready: $SOCKET"
else
    echo "    socket missing; check ~/Library/Logs/SwiftCUA/service.err.log" >&2
fi

echo "==> grant permissions (one time)"
echo "    System Settings → Privacy & Security →"
echo "      • Screen Recording: add/enable $APP_DEST"
echo "      • Accessibility:    add/enable $APP_DEST"
echo "    Then restart the service: launchctl kickstart -k gui/$UID/$LABEL"
echo
echo "    CLI: $APP_DEST/Contents/MacOS/cua doctor"
