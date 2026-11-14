#!/bin/sh
# Builds build/AutoHotspot.app (universal, ad-hoc signed). With "dist": also dist/*.zip, *.dmg and SHA256SUMS.txt.
set -eu
cd "$(dirname "$0")"
VER=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
APP=build/AutoHotspot.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
clang -fobjc-arc -O2 -mmacosx-version-min=13.0 -arch arm64 -arch x86_64 \
  -framework AppKit -framework CoreWLAN -framework SystemConfiguration -framework IOKit \
  -o "$APP/Contents/MacOS/AutoHotspot" Sources/main.m
cp Resources/Info.plist "$APP/Contents/"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/"; fi
codesign --force --sign - "$APP"
echo "built $APP ($VER)"
[ "${1:-}" = dist ] || exit 0
rm -rf dist && mkdir dist
ditto -c -k --keepParent "$APP" "dist/AutoHotspot-$VER.zip"
S=$(mktemp -d); cp -R "$APP" "$S/"; ln -s /Applications "$S/Applications"
hdiutil create -quiet -volname "Auto Hotspot" -srcfolder "$S" -fs HFS+ -format UDZO -ov "dist/AutoHotspot-$VER.dmg"; rm -rf "$S"
( cd dist && shasum -a 256 ./*.zip ./*.dmg 2>/dev/null | sed 's# \./# #' > SHA256SUMS.txt && cat SHA256SUMS.txt )
