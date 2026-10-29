#!/usr/bin/env bash
# Foreground service for development, hermetic home + socket under .devhome.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$ROOT/.build-dev"
swift build --scratch-path "$SCRATCH" --product cua-service
export SWIFTCUA_HOME="$ROOT/.devhome"
mkdir -p "$SWIFTCUA_HOME"
exec "$SCRATCH/debug/cua-service" "$@"
