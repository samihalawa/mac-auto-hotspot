# Security

Auto Hotspot runs as your user, needs no administrator rights and sends nothing anywhere
except one request to `captive.apple.com` to check for internet. The hotspot password is
received from your iPhone by macOS and passed to `networksetup`; it is never logged or stored.

Report a vulnerability privately through
[GitHub security advisories](https://github.com/samihalawa/mac-auto-hotspot/security/advisories/new).
Only the latest release is supported.
