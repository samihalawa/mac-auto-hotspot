#!/bin/sh
# Auto Hotspot installer. Safe to re-run.
#   curl -fsSL https://raw.githubusercontent.com/samihalawa/mac-auto-hotspot/main/install.sh | sh
#   ... | sh -s -- --from-source   build with the Xcode command line tools instead of downloading
#   ... | sh -s -- uninstall       remove everything it installed
set -eu
REPO=samihalawa/mac-auto-hotspot
LABEL=io.github.samihalawa.autohotspot
APP="$HOME/Applications/AutoHotspot.app"
BIN="$APP/Contents/MacOS/AutoHotspot"
CLI="$HOME/.local/bin/autohotspot"; OLDCLI="$HOME/.local/bin/auto-hotspot"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/AutoHotspot.log"
DOMAIN="gui/$(id -u)"

if [ "${1:-}" = uninstall ]; then
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  rm -rf "$APP" "$PLIST" "$CLI" "$OLDCLI" "$HOME/Library/Logs/.AutoHotspot.lock"
  defaults delete "$LABEL" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$LABEL.plist"; killall -u "$(id -un)" cfprefsd 2>/dev/null || true
  echo "Auto Hotspot removed (log kept at $LOG)"; exit 0
fi

[ "$(uname -s)" = Darwin ] || { echo "Auto Hotspot runs on macOS only" >&2; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$HOME/Applications" "$HOME/.local/bin" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

ZIP=""
if [ "${1:-}" != --from-source ]; then
  ZIP=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null | grep -o '"browser_download_url": *"[^"]*\.zip"' | head -1 | cut -d'"' -f4 || true)
fi
if [ -n "$ZIP" ]; then
  echo "Downloading $ZIP"
  curl -fsSL "$ZIP" -o "$T/app.zip"
  SUMS=$(dirname "$ZIP")/SHA256SUMS.txt
  if curl -fsSL "$SUMS" -o "$T/sums" 2>/dev/null; then
    want=$(grep "$(basename "$ZIP")" "$T/sums" | cut -d' ' -f1); got=$(shasum -a 256 "$T/app.zip" | cut -d' ' -f1)
    [ "$want" = "$got" ] || { echo "checksum mismatch for $(basename "$ZIP")" >&2; exit 1; }
    echo "Checksum OK"
  fi
  ditto -x -k "$T/app.zip" "$T/out"
else
  command -v clang >/dev/null || { echo "Needs the Xcode command line tools: xcode-select --install" >&2; exit 1; }
  echo "Building from source"
  curl -fsSL "https://github.com/$REPO/archive/refs/heads/main.tar.gz" | tar -xz -C "$T" --strip-components=1
  sh "$T/build.sh" >/dev/null; mkdir -p "$T/out"; mv "$T/build/AutoHotspot.app" "$T/out/"
fi

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
rm -rf "$APP"; mv "$T/out/AutoHotspot.app" "$APP"
/usr/bin/xattr -dr com.apple.quarantine "$APP" >/dev/null 2>&1 || true
rm -f "$OLDCLI"; ln -sf "$BIN" "$CLI"
defaults write "$LABEL" launchedBefore -bool true

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>$BIN</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
<key>ThrottleInterval</key><integer>5</integer>
<key>ProcessType</key><string>Interactive</string>
<key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
EOF
launchctl bootstrap "$DOMAIN" "$PLIST"
sleep 2
echo "Installed Auto Hotspot $("$BIN" --version) -> $APP"
echo "Menu bar icon is up. Check it: autohotspot --status   Log: $LOG"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "(add ~/.local/bin to PATH to use the autohotspot command)";; esac
