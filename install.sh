#!/bin/bash
# Install "EPUB Quickviewer.app" and register its Quick Look extension.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="EPUB Quickviewer.app"
SRC="build/$APP_NAME"
[ -d "$SRC" ] || { echo "run ./build.sh first" >&2; exit 1; }

# Prefer /Applications; fall back to ~/Applications when not writable.
DEST_DIR="/Applications"
if [ ! -w "$DEST_DIR" ]; then
    DEST_DIR="$HOME/Applications"
    mkdir -p "$DEST_DIR"
fi
DEST="$DEST_DIR/$APP_NAME"

echo "==> Installing to $DEST"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"

echo "==> Registering with LaunchServices"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$DEST"

echo "==> Registering Quick Look extension"
pluginkit -a "$DEST/Contents/PlugIns/EPUBPreview.appex" || true
pluginkit -e use -i com.zeekens.epubquickviewer.quicklook || true

echo "==> Resetting Quick Look cache"
qlmanage -r >/dev/null 2>&1 || true
qlmanage -r cache >/dev/null 2>&1 || true

echo "==> Verifying registration"
sleep 1
if pluginkit -m -i com.zeekens.epubquickviewer.quicklook | grep -q quicklook; then
    pluginkit -m -v -i com.zeekens.epubquickviewer.quicklook
    echo "OK — select an .epub in Finder and press space."
else
    echo "Extension not yet visible to pluginkit; launch the app once:"
    echo "  open \"$DEST\""
fi
