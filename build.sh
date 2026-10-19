#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="TDZStatus.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

xcrun swiftc -O \
  -target arm64-apple-macos13.0 \
  -framework AppKit \
  -framework SwiftUI \
  -framework ImageIO \
  -framework UserNotifications \
  -framework CoreWLAN \
  -framework IOKit \
  -framework Network \
  -framework Security \
  -framework ServiceManagement \
  -lsqlite3 \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/TDZStatus"

rm -rf "$APP/Contents/Resources/Assets"
cp -R Assets "$APP/Contents/Resources/Assets"
cp Resources/codex_usage_bridge.py "$APP/Contents/Resources/codex_usage_bridge.py"
chmod 755 "$APP/Contents/MacOS/TDZStatus" "$APP/Contents/Resources/codex_usage_bridge.py"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>TDZStatus</string>
    <key>CFBundleDisplayName</key>
    <string>TDZStatus</string>
    <key>CFBundleIdentifier</key>
    <string>com.reecedove.tdzstatus</string>
    <key>CFBundleExecutable</key>
    <string>TDZStatus</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Give the app a stable bundle signature identifier. This keeps the app's
# Keychain access requirement consistent across local rebuilds.
codesign --force --deep --sign - \
  --identifier com.reecedove.tdzstatus \
  -r '=designated => identifier "com.reecedove.tdzstatus"' \
  "$APP"

echo "Built $APP"
