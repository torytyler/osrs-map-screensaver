#!/bin/bash
# Installs the "RuneScape World" macOS screen saver.
#
#   ./install.sh             build everything from source and install
#   ./install.sh --source    same thing, explicit
#   ./install.sh --binary    download the prebuilt .saver from GitHub Releases
#   ./install.sh --caches    only (re)download the RuneScape caches
#
# Source mode needs Node.js (>=18) and Xcode Command Line Tools.
# Binary mode needs only curl, unzip and python3.
set -euo pipefail

cd "$(dirname "$0")"

VIEWER_REPO="${VIEWER_REPO:-https://github.com/torytyler/rs-map-viewer.git}"
BINARY_URL="${BINARY_URL:-https://github.com/torytyler/osrs-map-screensaver/releases/latest/download/OSRSMapSaver.saver.zip}"

DESTINATION="$HOME/Library/Screen Savers"
SUPPORT="$HOME/Library/Application Support/OSRSMapSaver"
CACHE_DIR="$SUPPORT/caches"

MODE="source"
case "${1:-}" in
    --binary) MODE="binary" ;;
    --source|"") MODE="source" ;;
    --caches) MODE="caches-only" ;;
    -h|--help)
        sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "unknown option: $1 (try --help)" >&2
        exit 1
        ;;
esac

say() { printf '==> %s\n' "$*"; }

install_bundle() {
    local bundle="$1"
    say "Installing into $DESTINATION"
    mkdir -p "$DESTINATION"
    rm -rf "$DESTINATION/OSRSMapSaver.saver"
    cp -R "$bundle" "$DESTINATION/OSRSMapSaver.saver"
    xattr -dr com.apple.quarantine "$DESTINATION/OSRSMapSaver.saver" 2>/dev/null || true
}

fetch_caches() {
    if [ -f "$CACHE_DIR/caches.json" ]; then
        say "Caches already present in $CACHE_DIR"
        return
    fi

    mkdir -p "$CACHE_DIR"
    say "Downloading RuneScape caches (~250 MB, one time)"

    if [ -f "scripts/fetch-caches.py" ]; then
        python3 scripts/fetch-caches.py --dir "$CACHE_DIR"
    elif [ -f "repo/scripts/fetch-cache.mjs" ] && command -v node >/dev/null 2>&1; then
        (cd repo && node scripts/fetch-cache.mjs)
        cp -R repo/caches/. "$CACHE_DIR/"
    else
        echo "error: no cache fetcher available (need scripts/fetch-caches.py or node)" >&2
        exit 1
    fi
}

restart_host() {
    say "Restarting the screen saver host"
    killall ScreenSaverEngine 2>/dev/null || true
    killall legacyScreenSaver 2>/dev/null || true
}

finish() {
    cat <<'EOF'

Installed. Pick "RuneScape World" in System Settings -> Screen Saver,
then press "Options..." to tune the camera, pacing and which cache to use.

  ./preview.sh                     same viewer in a browser (fast iteration)
  macos/build.sh install           rebuild only the native bundle
EOF
}

case "$MODE" in
    caches-only)
        fetch_caches
        exit 0
        ;;

    binary)
        for tool in curl unzip python3; do
            command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool is required" >&2; exit 1; }
        done

        work="$(mktemp -d)"
        trap 'rm -rf "$work"' EXIT

        say "Downloading prebuilt screen saver"
        curl -fL --progress-bar "$BINARY_URL" -o "$work/saver.zip"
        unzip -q "$work/saver.zip" -d "$work"

        install_bundle "$work/OSRSMapSaver.saver"

        if [ -f "$work/fetch-caches.py" ] && [ ! -f "$CACHE_DIR/caches.json" ]; then
            mkdir -p "$CACHE_DIR"
            say "Downloading RuneScape caches (~250 MB, one time)"
            python3 "$work/fetch-caches.py" --dir "$CACHE_DIR"
        fi

        restart_host
        finish
        ;;

    source)
        command -v node >/dev/null 2>&1 || {
            echo "error: node is required for a source build (brew install node)" >&2
            echo "       or use: ./install.sh --binary" >&2
            exit 1
        }

        if [ ! -f "repo/package.json" ]; then
            say "Cloning the viewer (fork of dennisdev/rs-map-viewer)"
            git clone --depth 1 "$VIEWER_REPO" repo
        fi

        say "Web app: dependencies"
        if [ ! -d "repo/node_modules" ]; then
            (cd repo && npx -y yarn@1.22.22 install)
        fi

        say "Web app: production build"
        (cd repo && CI=false npx -y yarn@1.22.22 build)

        fetch_caches

        say "Screen saver bundle"
        macos/build.sh install

        restart_host
        finish
        ;;
esac
