#!/usr/bin/env bash
set -euo pipefail
LABEL="dev.v1ki.swiftcua.service"
APP_DEST="$HOME/Applications/SwiftCUA.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
rm -rf "$APP_DEST"
if [[ "${1:-}" == "--purge" ]]; then
    rm -rf "$HOME/Library/Application Support/SwiftCUA"
    rm -rf "$HOME/Library/Logs/SwiftCUA"
    echo "purged service data"
fi
echo "uninstalled $LABEL"
