#!/bin/zsh
set -e
cd "$(dirname "$0")"
APP=Organize.app
rm -rf $APP; mkdir -p $APP/Contents/MacOS
swiftc -O Sources/main.swift -o $APP/Contents/MacOS/Organize
cat > $APP/Contents/Info.plist <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Organize</string>
<key>CFBundleIdentifier</key><string>com.local.organize</string>
<key>CFBundleExecutable</key><string>Organize</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
</dict></plist>
P
# Ad-hoc sign with a *stable* designated requirement (identifier only). Without this, macOS ties the
# Accessibility permission to the exact binary hash, so every rebuild silently invalidates it.
codesign --force --sign - -r='designated => identifier "com.local.organize"' $APP
echo "Built $APP"
