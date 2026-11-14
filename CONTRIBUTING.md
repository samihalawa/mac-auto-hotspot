# Contributing

Thanks for helping. Auto Hotspot is deliberately small: one Objective-C file, no dependencies.

1. `./build.sh` builds `build/AutoHotspot.app`. Run `build/AutoHotspot.app/Contents/MacOS/AutoHotspot --status` to check it.
2. Test the real thing: turn Wi-Fi's network off (or walk away from it) and watch `~/Library/Logs/AutoHotspot.log`.
3. In the pull request, say which macOS and iOS versions and which Mac you tested on.

Please keep changes focused, and do not add a setting when a sensible default works.
