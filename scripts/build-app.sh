#!/usr/bin/env bash
# Assembles build/SwiftCUA.app from the SwiftPM products and signs it.
#
# Identity resolution order:
#   1. $CUA_SIGN_IDENTITY (name or SHA-1)
#   2. first "Apple Development" identity found in the keychain
#   3. ad-hoc ("-"), which works but makes TCC forget the grant on every rebuild
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-release}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
SCRATCH="${SCRATCH:-$ROOT/.build-release}"
APP="$ROOT/build/SwiftCUA.app"

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG" --scratch-path "$SCRATCH" --product cua-service
swift build -c "$CONFIG" --scratch-path "$SCRATCH" --product cua

BIN_DIR="$SCRATCH/$CONFIG"
for product in cua-service cua; do
    [[ -x "$BIN_DIR/$product" ]] || { echo "missing product: $BIN_DIR/$product" >&2; exit 1; }
done

echo "==> assemble $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/cua-service" "$APP/Contents/MacOS/CUAService"
cp "$BIN_DIR/cua" "$APP/Contents/MacOS/cua"
chmod 755 "$APP/Contents/MacOS/CUAService" "$APP/Contents/MacOS/cua"

sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD_NUMBER/g" \
    "$ROOT/Resources/SwiftCUA-Info.plist" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> resolve signing identity"
IDENTITY="${CUA_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Apple Development/ {print $2; exit}')"
fi

if [[ -n "$IDENTITY" ]]; then
    echo "    identity: $IDENTITY"
    SIGN=(--sign "$IDENTITY" --options runtime --timestamp=none)
else
    echo "    identity: none found, falling back to ad-hoc (TCC grants will not be stable)"
    SIGN=(--sign -)
fi

ENTITLEMENTS="$ROOT/Resources/SwiftCUA.entitlements"
echo "==> codesign"
codesign --force "${SIGN[@]}" --entitlements "$ENTITLEMENTS" "$APP/Contents/MacOS/cua"
codesign --force "${SIGN[@]}" --entitlements "$ENTITLEMENTS" "$APP/Contents/MacOS/CUAService"
codesign --force "${SIGN[@]}" "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"

echo "==> done: $APP"
codesign -dv "$APP" 2>&1 | grep -E 'Identifier|TeamIdentifier|Authority' || true
