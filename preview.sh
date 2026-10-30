#!/bin/bash
# Runs the ambient viewer in a browser window for quick iteration.
#   ./preview.sh                default 30s scenes, random zones
#   ./preview.sh "ambient=1&zone=Varrock%20Square&debug=1"
set -euo pipefail

cd "$(dirname "$0")"
PORT="${PORT:-3200}"
QUERY="${1:-ambient=1&debug=1}"

if [ ! -d repo/build ] && [ ! -d repo/node_modules ]; then
    echo "Run ./install.sh first" >&2
    exit 1
fi

pkill -f "serve.mjs --port $PORT" 2>/dev/null || true
node repo/scripts/serve.mjs --port "$PORT" --root repo/build --caches repo/caches >/tmp/osrs-preview.log 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT

sleep 1
URL="http://127.0.0.1:$PORT/?$QUERY"
echo "Serving on $URL"
echo "Logs: /tmp/osrs-preview.log"
open "$URL"

wait $SERVER_PID
