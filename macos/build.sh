#!/bin/bash
# Builds OSRSMapSaver.saver (and the dev harness app) with swiftc.
#
#   ./build.sh            build saver + host into macos/build
#   ./build.sh install    additionally install into ~/Library/Screen Savers
set -euo pipefail

cd "$(dirname "$0")"

BUILD_DIR="build"
SAVER_NAME="OSRSMapSaver.saver"
SAVER_PATH="$BUILD_DIR/$SAVER_NAME"
REPO_ROOT="$(cd ../repo && pwd)"
DEPLOYMENT_TARGET="13.0"

echo "==> Cleaning $BUILD_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$SAVER_PATH/Contents/MacOS" "$SAVER_PATH/Contents/Resources"

FRAMEWORKS=(-framework AppKit -framework ScreenSaver -framework WebKit -framework Network)

arch_flags=()
for arch in arm64 x86_64; do
    echo "==> Building saver ($arch)"
    swiftc \
        -O \
        -target "$arch-apple-macos$DEPLOYMENT_TARGET" \
        -emit-library \
        -module-name OSRSMapSaver \
        -o "$BUILD_DIR/osrs-$arch" \
        "${FRAMEWORKS[@]}" \
        Saver/*.swift \
        -Xlinker -install_name -Xlinker @rpath/OSRSMapSaver
    arch_flags+=("$BUILD_DIR/osrs-$arch")
done

lipo -create "${arch_flags[@]}" -output "$SAVER_PATH/Contents/MacOS/OSRSMapSaver"
rm -f "$BUILD_DIR"/osrs-arm64 "$BUILD_DIR"/osrs-x86_64

echo "==> Bundling resources"
cp Saver/Info.plist "$SAVER_PATH/Contents/Info.plist"
cp Saver/AppIcon.icns "$SAVER_PATH/Contents/Resources/AppIcon.icns"

if [ -d "$REPO_ROOT/build" ] && [ -f "$REPO_ROOT/build/index.html" ]; then
    echo "    web build: $REPO_ROOT/build"
    cp -R "$REPO_ROOT/build" "$SAVER_PATH/Contents/Resources/web"
else
    echo "    warning: no web build found, run 'npm run build' in the repo root"
fi

echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$SAVER_PATH"

echo "==> Building harness app"
HARNESS_APP="$BUILD_DIR/OSRSMapSaverHarness.app"
mkdir -p "$HARNESS_APP/Contents/MacOS"
cp Host/Info.plist "$HARNESS_APP/Contents/Info.plist"
swiftc \
    -O \
    -target "$(uname -m)-apple-macos$DEPLOYMENT_TARGET" \
    -o "$HARNESS_APP/Contents/MacOS/OSRSMapSaverHarness" \
    -framework AppKit -framework ScreenSaver \
    Host/main.swift
codesign --force --sign - --entitlements Host/Harness.entitlements "$HARNESS_APP"

if [ "${1:-}" = "install" ]; then
    DEST="$HOME/Library/Screen Savers"
    echo "==> Installing to $DEST"
    mkdir -p "$DEST"
    rm -rf "$DEST/$SAVER_NAME"
    cp -R "$SAVER_PATH" "$DEST/$SAVER_NAME"
    echo "==> Restarting screen saver host"
    killall ScreenSaverEngine 2>/dev/null || true
fi

echo "==> Done: $SAVER_PATH"
