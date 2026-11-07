#!/bin/bash
# Builds "Pro Tools Time Tracker.app" for Intel + Apple Silicon, macOS 13+.
set -euo pipefail
cd "$(dirname "$0")"

NAME="Pro Tools Time Tracker"
APP="build/$NAME.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS" build/obj

for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos13.0" TimeTracker/*.swift -o "build/obj/tracker-$arch"
done
lipo -create build/obj/tracker-arm64 build/obj/tracker-x86_64 -output "$APP/Contents/MacOS/ProToolsTimeTracker"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Pro Tools Time Tracker</string>
  <key>CFBundleIdentifier</key><string>com.ivanarasch.protools-time-tracker</string>
  <key>CFBundleExecutable</key><string>ProToolsTimeTracker</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.11</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

codesign --force --sign - -r='designated => identifier "com.ivanarasch.protools-time-tracker"' "$APP"
(cd build && ditto -c -k --keepParent "$NAME.app" "$NAME.zip")
echo "Built: build/$NAME.app and build/$NAME.zip"
lipo -archs "$APP/Contents/MacOS/ProToolsTimeTracker"
