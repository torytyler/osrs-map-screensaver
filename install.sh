#!/bin/bash
# Installs the "RuneScape World" macOS screen saver.
#
#   ./install.sh             build everything from source and install
#   ./install.sh --source    same thing, explicit
#   ./install.sh --binary    install the prebuilt .saver from GitHub Releases
#   ./install.sh --caches    only fetch/repair the RuneScape caches
#
# Cache sources (pick one when archive.openrs2.org is unreachable):
#
#   --caches-mirror          download the cache snapshot from this project's
#                            releases instead of archive.openrs2.org
#   --offline <archive>      restore from a local .tar.zst/.tar.gz snapshot
#                            (see scripts/caches-backup.sh)
#
# Source mode needs Node.js (>=18) and Xcode Command Line Tools.
# Binary mode needs only curl, unzip and python3.
set -euo pipefail

cd "$(dirname "$0")"

VIEWER_REPO="${VIEWER_REPO:-https://github.com/torytyler/rs-map-viewer.git}"
BINARY_URL="${BINARY_URL:-https://github.com/torytyler/osrs-map-screensaver/releases/latest/download/OSRSMapSaver.saver.zip}"

# Cache snapshot published as its own release; bump both when re-snapshotting.
CACHE_RELEASE="${CACHE_RELEASE:-caches-2026-10-30}"
CACHE_ASSET="${CACHE_ASSET:-osrs-caches-2026-10-30.tar.zst}"
CACHE_MIRROR_URL="${CACHE_MIRROR_URL:-https://github.com/torytyler/osrs-map-screensaver/releases/download/$CACHE_RELEASE/$CACHE_ASSET}"

DESTINATION="$HOME/Library/Screen Savers"
SUPPORT="$HOME/Library/Application Support/OSRSMapSaver"
CACHE_DIR="$SUPPORT/caches"

MODE="source"
OFFLINE_ARCHIVE=""
USE_MIRROR=0
BUNDLED_FETCHER=""

while [ $# -gt 0 ]; do
    case "$1" in
        --binary) MODE="binary" ;;
        --source) MODE="source" ;;
        --caches) MODE="caches-only" ;;
        --caches-mirror|--mirror) USE_MIRROR=1 ;;
        --offline) shift; OFFLINE_ARCHIVE="${1:?--offline needs an archive path}" ;;
        -h|--help)
            sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "unknown option: $1 (try --help)" >&2
            exit 1
            ;;
    esac
    shift
done

say() { printf '==> %s\n' "$*"; }

install_bundle() {
    local bundle="$1"
    say "Installing into $DESTINATION"
    mkdir -p "$DESTINATION"
    rm -rf "$DESTINATION/OSRSMapSaver.saver"
    cp -R "$bundle" "$DESTINATION/OSRSMapSaver.saver"
    xattr -dr com.apple.quarantine "$DESTINATION/OSRSMapSaver.saver" 2>/dev/null || true
}

restore_caches_archive() {
    local archive="$1"
    [ -f "$archive" ] || { echo "error: archive not found: $archive" >&2; exit 1; }

    say "Restoring caches from $archive"
    local staging
    staging="$(mktemp -d)"
    if ! tar -xf "$archive" -C "$staging" 2>/dev/null; then
        rm -rf "$staging"
        echo "error: cannot read $archive (tar cannot handle the format?)" >&2
        exit 1
    fi
    if [ ! -f "$staging/caches/caches.json" ]; then
        rm -rf "$staging"
        echo "error: unexpected archive layout (no caches/caches.json)" >&2
        exit 1
    fi

    mkdir -p "$(dirname "$CACHE_DIR")"
    rm -rf "$CACHE_DIR"
    mv "$staging/caches" "$CACHE_DIR"
    rm -rf "$staging"
    say "Caches restored ($(du -sh "$CACHE_DIR" | cut -f1))"
}

download_mirror_archive() {
    command -v curl >/dev/null 2>&1 || { echo "error: curl is required" >&2; exit 1; }

    local staging
    staging="$(mktemp -d)"

    say "Downloading cache snapshot from the release (~209 MB)"
    echo "    $CACHE_MIRROR_URL"
    if ! curl -fL --progress-bar "$CACHE_MIRROR_URL" -o "$staging/$CACHE_ASSET"; then
        rm -rf "$staging"
        echo "error: download failed. Try again, or fetch a snapshot by hand" >&2
        echo "       (see scripts/caches-backup.sh --help)." >&2
        exit 1
    fi

    restore_caches_archive "$staging/$CACHE_ASSET"
    rm -rf "$staging"
}

fetch_caches() {
    if [ -f "$CACHE_DIR/caches.json" ]; then
        say "Caches already present in $CACHE_DIR"
        return
    fi

    if [ -n "$OFFLINE_ARCHIVE" ]; then
        restore_caches_archive "$OFFLINE_ARCHIVE"
        return
    fi

    if [ "$USE_MIRROR" -eq 1 ]; then
        download_mirror_archive
        return
    fi

    mkdir -p "$CACHE_DIR"
    say "Downloading RuneScape caches from the OpenRS2 archive (~250 MB, one time)"

    if [ -f "scripts/fetch-caches.py" ]; then
        python3 scripts/fetch-caches.py --dir "$CACHE_DIR" || cache_download_failed
        return
    fi
    if [ -n "$BUNDLED_FETCHER" ] && [ -f "$BUNDLED_FETCHER" ]; then
        python3 "$BUNDLED_FETCHER" --dir "$CACHE_DIR" || cache_download_failed
        return
    fi
    if [ -f "repo/scripts/fetch-cache.mjs" ] && command -v node >/dev/null 2>&1; then
        (cd repo && node scripts/fetch-cache.mjs) || cache_download_failed
        rm -rf "$CACHE_DIR"
        cp -R repo/caches "$CACHE_DIR"
        return
    fi

    echo "error: no cache fetcher available (need scripts/fetch-caches.py or node)" >&2
    echo "       try: ./install.sh --caches --caches-mirror" >&2
    exit 1
}

cache_download_failed() {
    echo "error: could not download the caches from archive.openrs2.org" >&2
    echo "       retry with the published snapshot instead:" >&2
    echo "         ./install.sh --caches --caches-mirror" >&2
    echo "       or restore a local archive:" >&2
    echo "         ./install.sh --caches --offline <archive.tar.zst>" >&2
    exit 1
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

The 250 MB of map data lives in:
  ~/Library/Application Support/OSRSMapSaver/caches
Snapshot it (so a reinstall never needs archive.openrs2.org again):
  ./scripts/caches-backup.sh create
Restore it later:
  ./install.sh --offline ~/Documents/osrs_map_screensaver-offline/osrs-caches-YYYY-MM-DD.tar.zst
Or take the published snapshot instead of OpenRS2:
  ./install.sh --caches --caches-mirror
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
        trap 'rm -rf "${work:-}"' EXIT

        say "Downloading prebuilt screen saver"
        curl -fL --progress-bar "$BINARY_URL" -o "$work/saver.zip"
        unzip -q "$work/saver.zip" -d "$work"

        install_bundle "$work/OSRSMapSaver.saver"

        BUNDLED_FETCHER="$work/fetch-caches.py"
        fetch_caches

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
