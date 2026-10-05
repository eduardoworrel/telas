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

# Ad-hoc signature with a requirement pinned to the bundle identifier, so the
# Screen Recording and Accessibility permissions survive rebuilds.
codesign -s - --force -r='designated => identifier "io.github.eduardoworrel.telas"' $APP
echo "Built $APP"

if [[ "$1" == "--install" ]]; then
  pkill -f Telas.app/Contents/MacOS || true
  rm -rf ~/Applications/Telas.app
  mkdir -p ~/Applications
  cp -R $APP ~/Applications/
  open ~/Applications/Telas.app
  echo "Installed ~/Applications/Telas.app"
fi
