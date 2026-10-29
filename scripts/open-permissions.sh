#!/usr/bin/env bash
# Opens the two System Settings panes SwiftCUA needs. You still have to toggle
# the app on by hand — macOS does not allow scripts to grant TCC permissions.
set -euo pipefail
APP="${1:-$HOME/Applications/SwiftCUA.app}"
echo "Add / enable: $APP"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture" 2>/dev/null || true
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
echo "Then restart the service: launchctl kickstart -k gui/$(id -u)/dev.v1ki.swiftcua.service"
echo "Verify: $APP/Contents/MacOS/cua doctor"
