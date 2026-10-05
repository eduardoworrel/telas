#!/bin/zsh
# Builds Telas.app into ./build. With --install, also copies it to ~/Applications and opens it.
set -e
cd "$(dirname "$0")"

APP=build/Telas.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS
cat > $APP/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Telas</string>
<key>CFBundleIdentifier</key><string>io.github.eduardoworrel.telas</string>
<key>CFBundleExecutable</key><string>Telas</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST

swiftc -O -parse-as-library -import-objc-header Sources/VirtualDisplay.h Sources/Telas.swift -o $APP/Contents/MacOS/Telas

# Plain ad-hoc signature: macOS lists the app in Privacy & Security on its own when it asks for
# permissions. (A rebuilt binary is a "new" app to macOS, so permissions must be granted again.)
codesign -s - --force $APP
echo "Built $APP"

if [[ "$1" == "--install" ]]; then
  pkill -f Telas.app/Contents/MacOS || true
  rm -rf /Applications/Telas.app
  cp -R $APP /Applications/
  open /Applications/Telas.app
  echo "Installed /Applications/Telas.app"
fi
