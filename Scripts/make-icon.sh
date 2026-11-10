#!/usr/bin/env bash
# Rebuilds Resources/AppIcon.icns and docs/images/logo.png from Scripts/make-icon.swift.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
xcrun swiftc -framework AppKit "$root/Scripts/make-icon.swift" -o "$work/make-icon"
"$work/make-icon" "$work/AppIcon.iconset" "$root/docs/images/logo.png"
iconutil -c icns "$work/AppIcon.iconset" -o "$root/Resources/AppIcon.icns"
printf '%s\n' "$root/Resources/AppIcon.icns" "$root/docs/images/logo.png"
