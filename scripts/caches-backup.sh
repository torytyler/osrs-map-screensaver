#!/bin/bash
# Snapshot / restore the RuneScape caches.
#
# The caches (~250 MB) are downloaded once from archive.openrs2.org and then
# served to the viewer from disk. Keeping a local archive means the screen saver
# can be reinstalled on a machine (or restored after an accident) even if that
# archive site is slow, moved or gone.
#
#   scripts/caches-backup.sh create [archive]        snapshot the installed caches
#   scripts/caches-backup.sh verify <archive>        list/verify an archive
#   scripts/caches-backup.sh restore <archive> [--force] [--dir <caches dir>]
#
# Defaults: caches live in ~/Library/Application Support/OSRSMapSaver/caches
# and archives are written to ~/Documents/osrs_map_screensaver-offline/.
#
# Restoring needs only `tar`: macOS bsdtar reads .tar.zst, .tar.gz and .tar.
set -euo pipefail

CACHE_DIR="${OSRS_CACHE_DIR:-$HOME/Library/Application Support/OSRSMapSaver/caches}"
ARCHIVE_DIR="${OSRS_ARCHIVE_DIR:-$HOME/Documents/osrs_map_screensaver-offline}"

usage() {
    sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

human() { du -sh "$1" 2>/dev/null | cut -f1 | tr -d ' '; }

compression_tool() {
    if command -v zstd >/dev/null 2>&1; then
        echo zstd
    else
        echo gzip
    fi
}

cmd_create() {
    local archive="${1:-}"
    local tool
    tool="$(compression_tool)"

    if [ ! -f "$CACHE_DIR/caches.json" ]; then
        echo "error: no caches at $CACHE_DIR (run ./install.sh --caches first)" >&2
        exit 1
    fi

    mkdir -p "$ARCHIVE_DIR"
    if [ -z "$archive" ]; then
        archive="$ARCHIVE_DIR/osrs-caches-$(date +%Y-%m-%d).tar.$([ "$tool" = zstd ] && echo zst || echo gz)"
    fi

    echo "==> Snapshotting $(human "$CACHE_DIR") from $CACHE_DIR"
    if [ "$tool" = zstd ]; then
        tar -cf - -C "$(dirname "$CACHE_DIR")" "$(basename "$CACHE_DIR")" \
            | zstd -T0 -19 --long=27 -q -o "$archive"
    else
        tar -czf "$archive" -C "$(dirname "$CACHE_DIR")" "$(basename "$CACHE_DIR")"
    fi

    (cd "$(dirname "$archive")" && shasum -a 256 "$(basename "$archive")" > "$(basename "$archive").sha256")

    echo "==> Wrote $archive ($(human "$archive"))"
    echo "    checksum: $(cut -d' ' -f1 "$archive.sha256")"
    echo
    echo "Restore later with:"
    echo "  scripts/caches-backup.sh restore \"$archive\""
    echo "  ./install.sh --offline \"$archive\""
}

cmd_verify() {
    local archive="${1:-}"
    [ -n "$archive" ] || usage 1

    if [ ! -f "$archive" ]; then
        echo "error: no such archive: $archive" >&2
        exit 1
    fi

    if [ -f "$archive.sha256" ]; then
        echo "==> Checksum"
        (cd "$(dirname "$archive")" && shasum -a 256 -c "$(basename "$archive").sha256")
    else
        echo "==> No .sha256 sidecar, skipping checksum"
    fi

    echo "==> Contents"
    local listing
    listing="$(tar -tf "$archive")" || { echo "error: cannot read $archive" >&2; exit 1; }
    if ! printf '%s\n' "$listing" | grep -qx 'caches/caches.json'; then
        echo "error: archive does not contain caches/caches.json" >&2
        exit 1
    fi
    printf '%s\n' "$listing" | grep -c 'main_file_cache' | xargs echo "    cache index/data files:"
    printf '%s\n' "$listing" | awk -F/ '/\/$/ && NF>=3 {print $2}' | sort -u | sed 's/^/    cache: /'

    echo "==> caches.json"
    tar -xOf "$archive" caches/caches.json \
        | python3 -c "import json,sys; [print(f\"    {c['name']}  rev {c['revision']}  {c['size']/1e6:.0f} MB\") for c in json.load(sys.stdin)]"
}

cmd_restore() {
    local archive="${1:-}"
    shift || true
    local force=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --force) force=1 ;;
            --dir) shift; CACHE_DIR="${1:?--dir needs a path}" ;;
            *) echo "unknown option: $1" >&2; exit 1 ;;
        esac
        shift
    done

    [ -n "$archive" ] || usage 1
    [ -f "$archive" ] || { echo "error: no such archive: $archive" >&2; exit 1; }

    if [ -f "$CACHE_DIR/caches.json" ] && [ "$force" -eq 0 ]; then
        echo "Caches already present at $CACHE_DIR"
        echo "(use --force to replace them)"
        return 1
    fi

    mkdir -p "$(dirname "$CACHE_DIR")"
    staging="$(mktemp -d)"
    trap 'rm -rf "${staging:-}"' EXIT

    echo "==> Extracting $(human "$archive") from $archive"
    tar -xf "$archive" -C "$staging"

    if [ ! -f "$staging/caches/caches.json" ]; then
        echo "error: unexpected archive layout (no caches/caches.json)" >&2
        exit 1
    fi

    echo "==> Installing into $CACHE_DIR"
    rm -rf "$CACHE_DIR"
    mv "$staging/caches" "$CACHE_DIR"

    local count
    count="$(find "$CACHE_DIR" -name main_file_cache.dat* | wc -l | tr -d ' ')"
    echo "==> Restored $(human "$CACHE_DIR") ($count cache data files)"
    python3 -c "import json;print('    ' + ', '.join(c['name'] for c in json.load(open('$CACHE_DIR/caches.json'))))"
}

case "${1:-}" in
    create) shift; cmd_create "$@" ;;
    verify) shift; cmd_verify "$@" ;;
    restore) shift; cmd_restore "$@" ;;
    -h|--help|help) usage ;;
    *) usage 1 ;;
esac
