#!/bin/bash
# Build "EPUB Quickviewer.app" with its Quick Look preview extension using only
# the Command Line Tools (no Xcode required). Ad-hoc signed, arm64.
set -euo pipefail
cd "$(dirname "$0")"

TARGET="arm64-apple-macos13.0"
BUILD=build
APP="$BUILD/EPUB Quickviewer.app"
APPEX="$APP/Contents/PlugIns/EPUBPreview.appex"
CORE=(Sources/Core/ZipArchive.swift Sources/Core/EPUBBook.swift Sources/Core/PreviewBuilder.swift)
SWIFTC=(swiftc -O -target "$TARGET")

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APPEX/Contents/MacOS"

echo "==> Compiling CLI test harness"
"${SWIFTC[@]}" -module-name epubcli "${CORE[@]}" Sources/CLI/main.swift \
    -o "$BUILD/epub-preview-cli"

echo "==> Compiling app"
"${SWIFTC[@]}" -parse-as-library -module-name EPUBQuickviewer \
    "${CORE[@]}" Sources/App/AppMain.swift \
    -framework AppKit -framework WebKit \
    -o "$APP/Contents/MacOS/EPUB Quickviewer"

echo "==> Compiling Quick Look extension"
"${SWIFTC[@]}" -parse-as-library -application-extension -module-name EPUBPreview \
    "${CORE[@]}" Sources/Extension/PreviewProvider.swift \
    -framework QuickLookUI \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -o "$APPEX/Contents/MacOS/EPUBPreview"

echo "==> Assembling bundles"
cp Resources/App-Info.plist "$APP/Contents/Info.plist"
cp Resources/Appex-Info.plist "$APPEX/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing (ad-hoc)"
xattr -cr "$APP"
codesign --force --sign - --entitlements Resources/appex.entitlements \
    --options runtime "$APPEX"
codesign --force --sign - --entitlements Resources/app.entitlements \
    --options runtime "$APP"

echo "==> Done: $APP"
