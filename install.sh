#!/bin/bash
# Builds the web viewer, makes sure the RuneScape caches are available to the
# screen saver, then builds and installs OSRSMapSaver.saver.
#
#   ./install.sh                 normal install
#   ./install.sh --refresh-web   force a web rebuild (same as normal, explicit)
#   ./install.sh --caches 512    set the render distance baked into nothing yet
set -euo pipefail

cd "$(dirname "$0")"

REPO="repo"
SUPPORT="$HOME/Library/Application Support/OSRSMapSaver"
CACHE_SOURCE="$REPO/caches"
CACHE_TARGET="$SUPPORT/caches"

if ! command -v node >/dev/null 2>&1; then
    echo "node is required (brew install node)" >&2
    exit 1
fi

echo "==> Web app: install dependencies"
if [ ! -d "$REPO/node_modules" ]; then
    (cd "$REPO" && npx -y yarn@1.22.22 install)
fi

echo "==> Web app: production build"
(cd "$REPO" && CI=false npx -y yarn@1.22.22 build)

echo "==> Caches"
if [ ! -f "$CACHE_SOURCE/caches.json" ]; then
    echo "Downloading OSRS + 2005 caches from the OpenRS2 archive (~250 MB)"
    (cd "$REPO" && node scripts/fetch-cache.mjs)
fi

mkdir -p "$SUPPORT"
if [ -L "$CACHE_TARGET" ]; then
    echo "    keeping existing symlink $CACHE_TARGET"
elif [ -d "$CACHE_TARGET" ]; then
    echo "    keeping existing $CACHE_TARGET"
else
    echo "    copying $(du -sh "$CACHE_SOURCE" | cut -f1) of caches to $CACHE_TARGET"
    cp -R "$CACHE_SOURCE" "$CACHE_TARGET"
fi

echo "==> Screen saver bundle"
macos/build.sh install

echo
echo "Installed. Pick \"RuneScape World\" in System Settings > Screen Saver."
echo "Dev loop:  ./preview.sh          (browser window, hot reload)"
echo "           ./macos/build.sh install && open macos/build/OSRSMapSaverHarness.app"
