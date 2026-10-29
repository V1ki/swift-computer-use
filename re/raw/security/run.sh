#!/bin/bash
# Read-only target acquisition; outputs only under this script's directory. Never launch target apps.
set -u
# After acquisition: python3 "$OUT/derive.py" (focused extracts and local approval snapshots).
OUT="$(cd "$(dirname "$0")" && pwd)"
APP='/Users/v1ki/.codex/computer-use/Codex Computer Use.app'
PLUGIN='/Library/Security/SecurityAgentPlugins/CodexComputerUseAuthorizationPlugin.bundle'
SHARED="$APP/Contents/SharedSupport"
capture() { local name="$1"; shift; "$@" >"$OUT/$name" 2>&1; local rc=$?; printf '\n[exit code: %s]\n' "$rc" >>"$OUT/$name"; printf '%s exit=%s\n' "$name" "$rc"; }
for spec in service guardian installer plugin bundled-plugin client; do
 case "$spec" in
 service) bundle="$APP";;
 guardian) bundle="$SHARED/CUALockScreenGuardian.app";;
 installer) bundle="$SHARED/Codex Computer Use Installer.app";;
 plugin) bundle="$PLUGIN";;
 bundled-plugin) bundle="$SHARED/Codex Computer Use Installer.app/Contents/Resources/CodexComputerUseAuthorizationPlugin.bundle";;
 client) bundle="$SHARED/SkyComputerUseClient.app";;
 esac
 capture "$spec.info.txt" /usr/bin/plutil -p "$bundle/Contents/Info.plist"
 capture "$spec.codesign.txt" /usr/bin/codesign -d -r- --entitlements :- "$bundle"
 exe=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$bundle/Contents/Info.plist")
 capture "$spec.strings.txt" /usr/bin/strings -a "$bundle/Contents/MacOS/$exe"
 capture "$spec.nm.txt" /usr/bin/nm -m "$bundle/Contents/MacOS/$exe"
 capture "$spec.dylibs.txt" /usr/bin/otool -L "$bundle/Contents/MacOS/$exe"
done
TOOL="$SHARED/Codex Computer Use Installer.app/Contents/Resources/CodexComputerUseAuthorizationPluginInstallerTool"
capture tool.strings.txt /usr/bin/strings -a "$TOOL"
capture tool.nm.txt /usr/bin/nm -m "$TOOL"
capture tool.disassembly.txt /usr/bin/otool -tvV "$TOOL"
capture plugin.disassembly.txt /usr/bin/otool -tvV "$PLUGIN/Contents/MacOS/CodexComputerUseAuthorizationPlugin"
capture backup-manifest.txt /usr/bin/plutil -p '/Library/Application Support/CodexComputerUseAuthorizationPlugin/latest-backup-manifest.plist'
capture backup-screensaver.txt /usr/bin/plutil -p '/Library/Application Support/CodexComputerUseAuthorizationPlugin/backups/system.login.screensaver.20260618-072409.plist'
capture current-screensaver.txt /usr/bin/security authorizationdb read system.login.screensaver
capture ipc-listing.txt /bin/ls -laR '/Users/v1ki/Library/Group Containers/2DC432GLL2.com.openai.sky.CUAService'
capture sessions-listing.txt /bin/ls -la '/Users/v1ki/.codex/computer-use/sessions'
capture current-remote-rule.txt /usr/bin/security authorizationdb read com.openai.sky.CUAService.AuthorizationPlugin.remote
capture lock-socket-listing.txt /bin/ls -la /tmp/com.openai.sky.CUAService
capture service.signature-details.txt /usr/bin/codesign -d -vv "$APP"
/usr/bin/otool -tvV "$APP/Contents/MacOS/SkyComputerUseService" > "$OUT/service.disassembly.txt"
xcrun swift-demangle < "$OUT/service.nm.txt" > "$OUT/service.demangled.txt"
capture launchctl.txt /bin/launchctl print "gui/$(id -u)"
capture logs.txt /usr/bin/log show --last 24h --style compact --predicate '(process == "SkyComputerUseService" OR process == "CUALockScreenGuardian" OR process == "Codex Computer Use Installer" OR subsystem CONTAINS[c] "CUAService" OR (process == "tccd" AND (eventMessage CONTAINS[c] "sky" OR eventMessage CONTAINS[c] "codex")))'
