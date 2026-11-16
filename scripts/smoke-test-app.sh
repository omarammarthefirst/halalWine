#!/bin/bash
# Checks the packaged app on macOS: the bundled CLI finds its resources inside
# the .app, and the app starts and keeps running.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="dist/halalWine.app"
TMP="$(mktemp -d)"
export HALALWINE_HOME="$TMP/home"

python3 scripts/make-fixture.py "$TMP/Demo.Game.v1.2.3" >/dev/null
OUTPUT="$("$APP/Contents/MacOS/halalwine" plan "$TMP/Demo.Game.v1.2.3" --all)"
echo "$OUTPUT"
echo "$OUTPUT" | grep -q "Engine:       godot 4.5.0"
echo "$OUTPUT" | grep -Eq "1\. d3dmetal +--rendering-driver d3d12"

"$APP/Contents/MacOS/HalalWine" &
PID=$!
sleep 12
if kill -0 "$PID" 2>/dev/null; then
  echo "✔ app is running"
  kill "$PID"
else
  wait "$PID" || true
  echo "✘ app exited during startup"
  exit 1
fi
