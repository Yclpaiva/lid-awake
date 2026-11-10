#!/usr/bin/env bash
# Runs the checks and builds .build/Lid Awake.app with ad-hoc signing.
# --digest prints the source hash that install.sh compares with the installed app.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/.build/Lid Awake.app"
digest() {
  cat "$root"/Sources/* "$root"/Resources/AppIcon.icns "$root"/Resources/*.lproj/* | shasum -a 256 | cut -d' ' -f1
}
if [[ "${1:-}" == --digest ]]; then digest; exit 0; fi
mkdir -p "$root/.build"
xcrun swiftc "$root/Sources/StopPolicy.swift" "$root/Tests/main.swift" -o "$root/.build/checks"
"$root/.build/checks" "$root"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
xcrun swiftc -O -framework AppKit -framework IOKit \
  "$root/Sources/StopPolicy.swift" "$root/Sources/main.swift" -o "$app/Contents/MacOS/LidAwake"
cp "$root/Sources/Info.plist" "$app/Contents/Info.plist"
cp "$root/Resources/AppIcon.icns" "$app/Contents/Resources/"
cp -R "$root/Resources/en.lproj" "$root/Resources/pt-BR.lproj" "$app/Contents/Resources/"
digest >"$app/Contents/Resources/source.sha256"
codesign --force --sign - --identifier dev.yclpaiva.lid-awake "$app"
codesign --verify --deep --strict "$app"
printf '%s\n' "$app"
