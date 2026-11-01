#!/bin/bash
# Builds the release asset (OSRSMapSaver.saver.zip) from macos/build and verifies
# that the code signature survives a zip round trip.
#
#   scripts/make-release-zip.sh [output.zip]
#
# Two things this exists to stop happening:
#   * `zip -r` UPDATES an existing archive instead of replacing it, so reusing a
#     path shipped a bundle that mixed the old and new web builds - extra files
#     that are not in _CodeSignature/CodeResources, i.e. a broken seal.
#   * A .saver that fails `codesign --verify` inside the sandboxed appex fails at
#     load time rather than at install time, which is much harder to spot.
set -euo pipefail

cd "$(dirname "$0")/.."

BUNDLE="macos/build/OSRSMapSaver.saver"
OUT="${1:-/tmp/OSRSMapSaver.saver.zip}"
VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" macos/Saver/Info.plist)"

[ -d "$BUNDLE" ] || { echo "error: $BUNDLE not found (run macos/build.sh first)" >&2; exit 1; }

STAGE="$(mktemp -d)"
VERIFY="$(mktemp -d)"
trap 'rm -rf "$STAGE" "$VERIFY"' EXIT

cp -R "$BUNDLE" "$STAGE/"
cp scripts/fetch-caches.py "$STAGE/"

cat > "$STAGE/INSTALL.txt" <<EOF
RuneScape World - macOS screen saver ($VERSION)
$(printf '=%.0s' $(seq 1 ${#VERSION}))============================================

Quickest install (recommended):

    curl -fsSL https://raw.githubusercontent.com/torytyler/osrs-map-screensaver/main/install.sh \\
      | bash -s -- --binary

That downloads the latest release, installs the .saver and fetches the RuneScape
caches (~250 MB) into ~/Library/Application Support/OSRSMapSaver/caches.

Manual install from this zip:

    unzip OSRSMapSaver.saver.zip
    mkdir -p "\$HOME/Library/Screen Savers"
    cp -R OSRSMapSaver.saver "\$HOME/Library/Screen Savers/"
    xattr -dr com.apple.quarantine "\$HOME/Library/Screen Savers/OSRSMapSaver.saver"
    python3 fetch-caches.py --dir "\$HOME/Library/Application Support/OSRSMapSaver/caches"
    killall ScreenSaverEngine 2>/dev/null

Then: System Settings -> Screen Saver -> RuneScape World -> Options...

Source and issue tracker: https://github.com/torytyler/osrs-map-screensaver
RuneScape content (c) Jagex Ltd. Unofficial, not affiliated with Jagex.
EOF

# Never reuse an archive: `zip` would keep entries that no longer exist.
rm -f "$OUT"
(cd "$STAGE" && zip -qry "$OUT" OSRSMapSaver.saver fetch-caches.py INSTALL.txt)

echo "==> $OUT ($(du -h "$OUT" | cut -f1), version $VERSION)"

# Round-trip check: the shipped zip must unpack into a validly signed bundle with
# exactly the files the seal covers (no leftovers from an older build).
unzip -q "$OUT" -d "$VERIFY"
if ! codesign --verify --deep --strict "$VERIFY/OSRSMapSaver.saver"; then
    echo "error: code signature does not survive the zip (stale entries?)" >&2
    exit 1
fi
MAIN_COUNT="$(ls "$VERIFY/OSRSMapSaver.saver/Contents/Resources/web/static/js/" | grep -cE '^main\.[0-9a-f]+\.js$')"
if [ "$MAIN_COUNT" != "1" ]; then
    echo "error: expected one main.*.js in the bundle, found $MAIN_COUNT" >&2
    exit 1
fi
echo "==> verified: signature valid, single web build, $(unzip -l "$OUT" | tail -1 | awk '{print $2}') files"
