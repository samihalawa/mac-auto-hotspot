#!/bin/sh
# Builds build/AutoHotspot.app (universal). With "dist": also dist/*.zip, *.dmg and SHA256SUMS.txt.
# Ad-hoc signed by default. For a Developer ID build set SIGN_IDENTITY (and SIGN_KEYCHAIN if it is not in
# the default search list); to notarize and staple set NOTARY_KEY, NOTARY_KEY_ID and NOTARY_ISSUER
# (an App Store Connect API key).
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
SIGN=${SIGN_IDENTITY:--}
if [ "$SIGN" = - ]; then codesign --force --sign - "$APP"
else codesign --force --options runtime --timestamp --sign "$SIGN" ${SIGN_KEYCHAIN:+--keychain "$SIGN_KEYCHAIN"} "$APP"; fi
notarize() { [ -n "${NOTARY_KEY:-}" ] || return 0
  xcrun notarytool submit "$1" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
  xcrun stapler staple "$2"; }
echo "built $APP ($VER)"
[ "${1:-}" = dist ] || exit 0
rm -rf dist && mkdir dist
ditto -c -k --keepParent "$APP" "dist/AutoHotspot-$VER.zip"
if [ -n "${NOTARY_KEY:-}" ]; then notarize "dist/AutoHotspot-$VER.zip" "$APP"; ditto -c -k --keepParent "$APP" "dist/AutoHotspot-$VER.zip"; fi
S=$(mktemp -d); cp -R "$APP" "$S/"; ln -s /Applications "$S/Applications"
hdiutil create -quiet -volname "Auto Hotspot" -srcfolder "$S" -fs HFS+ -format UDZO -ov "dist/AutoHotspot-$VER.dmg"; rm -rf "$S"
if [ "$SIGN" != - ]; then codesign --force --timestamp --sign "$SIGN" ${SIGN_KEYCHAIN:+--keychain "$SIGN_KEYCHAIN"} "dist/AutoHotspot-$VER.dmg"; fi
notarize "dist/AutoHotspot-$VER.dmg" "dist/AutoHotspot-$VER.dmg"
( cd dist && shasum -a 256 ./*.zip ./*.dmg 2>/dev/null | sed 's# \./# #' > SHA256SUMS.txt && cat SHA256SUMS.txt )
