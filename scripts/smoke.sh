#!/usr/bin/env bash
# End-to-end smoke test that needs no TCC permissions:
#   service boot -> ping -> list_apps -> session authorization -> MCP handshake.
# It never injects input and never captures the screen; permission-dependent
# calls are expected to fail cleanly and are asserted as such.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="${SCRATCH:-$ROOT/.build-smoke}"
TMP="$(mktemp -d)"
export SWIFTCUA_HOME="$TMP/home"
mkdir -p "$SWIFTCUA_HOME"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

cleanup() {
    if [[ -n "${SVC_PID:-}" ]] && kill -0 "$SVC_PID" 2>/dev/null; then
        kill "$SVC_PID" 2>/dev/null || true
        wait "$SVC_PID" 2>/dev/null || true
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT

echo "==> build"
swift build --scratch-path "$SCRATCH" --product cua-service >/dev/null
swift build --scratch-path "$SCRATCH" --product cua >/dev/null
SERVICE="$SCRATCH/debug/cua-service"
CLI="$SCRATCH/debug/cua"

echo "==> start service"
"$SERVICE" --no-peer-check --headless > "$TMP/service.log" 2>&1 &
SVC_PID=$!
for _ in $(seq 1 50); do [[ -S "$SWIFTCUA_HOME/IPC/computeruse.sock" ]] && break; sleep 0.1; done

echo "==> protocol"
check "socket exists" "[[ -S '$SWIFTCUA_HOME/IPC/computeruse.sock' ]]"
check "ping responds" "'$CLI' ping"
check "list_apps responds" "'$CLI' apps"
check "list_windows responds" "'$CLI' windows"
check "doctor passes connectivity" "'$CLI' doctor"
check "session TOML written" "ls '$SWIFTCUA_HOME'/sessions/*.toml"
check "unknown method is rejected" "! '$CLI' call no_such_method"

echo "==> permission-gated call fails cleanly (expected without TCC)"
if "$CLI" state --app com.apple.finder >/dev/null 2>"$TMP/state.err"; then
    echo "  [INFO] state succeeded (permissions already granted to the responsible process)"
else
    grep -qE "permissionMissing|Accessibility|ScreenRecording|1001" "$TMP/state.err" \
        && ok "unprivileged state returns permission error" \
        || bad "unexpected state error: $(head -2 "$TMP/state.err")"
fi

echo "==> MCP handshake"
printf '%s\n%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | "$CLI" mcp 2>/dev/null > "$TMP/mcp.out"
check "MCP initialize" "grep -q '\"id\":1' '$TMP/mcp.out'"
check "MCP 17 tools" "[[ \$(grep -o '\"name\":\"[a-z_]*\"' '$TMP/mcp.out' | sort -u | wc -l | tr -d ' ') -ge 17 ]]"

echo
echo "smoke: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
