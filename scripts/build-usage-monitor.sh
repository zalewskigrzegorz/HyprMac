#!/bin/bash
# Builds tools/usage-monitor.swift into "HyprMac Usage.app" and (re)launches it.
# Signed with the Apple Development identity when present, so the Accessibility grant survives rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."

app="build/usage-monitor/HyprMac Usage.app"
bin="$app/Contents/MacOS/HyprMacUsage"
mkdir -p "$app/Contents/MacOS"
swiftc -O tools/usage-monitor.swift -o "$bin"
"$bin" --selftest

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.zachgray.HyprMac.usage-monitor</string>
  <key>CFBundleName</key><string>HyprMac Usage</string>
  <key>CFBundleExecutable</key><string>HyprMacUsage</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

identity=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign --force --sign "${identity:--}" "$app"

pkill -x HyprMacUsage || true
open "$app"
echo "launched: $app (signed: ${identity:-ad-hoc})"
