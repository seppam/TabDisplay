#!/bin/zsh
# Builds dist/TabDisplay.app (universal, ad-hoc signed) and dist/TabDisplay-<version>.dmg.
# Usage: packaging/build-app.sh [version]
set -euo pipefail
cd "${0:A:h}/.."

VERSION=${1:-1.0.0}
APP=dist/TabDisplay.app

echo "==> Building universal binary"
swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)

echo "==> Assembling $APP"
rm -rf dist
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp "$BIN/tabdisplay" $APP/Contents/MacOS/TabDisplay
cp Sources/tabdisplay/Resources/index.html $APP/Contents/Resources/
sed "s/__VERSION__/$VERSION/g" packaging/Info.plist > $APP/Contents/Info.plist

ICONSET=$(mktemp -d)/AppIcon.iconset
swift packaging/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o $APP/Contents/Resources/AppIcon.icns

# Ad-hoc signature: no Apple Developer account, so the app is not notarized (see README).
codesign --force --sign - $APP

echo "==> Creating DMG"
STAGE=$(mktemp -d)
cp -R $APP "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "TabDisplay" -srcfolder "$STAGE" -ov -format UDZO "dist/TabDisplay-$VERSION.dmg" >/dev/null

echo "==> Done: dist/TabDisplay-$VERSION.dmg"
