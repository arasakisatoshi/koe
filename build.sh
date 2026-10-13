#!/bin/zsh
# Koe.app をこのフォルダに作る。作り直すとアクセシビリティの許可を入れ直す必要がある。
set -e
cd "$(dirname "$0")"
# iCloud同期フォルダなどではFinder情報が付いて署名に失敗するので、一時フォルダで作ってから移す
WORK=$(mktemp -d)
APP=$WORK/Koe.app
mkdir -p $APP/Contents/MacOS
xcrun swiftc -O -swift-version 5 main.swift -o $APP/Contents/MacOS/Koe
cat > $APP/Contents/Info.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.arasaki.koe</string>
<key>CFBundleName</key><string>Koe</string>
<key>CFBundleExecutable</key><string>Koe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSUIElement</key><true/>
<key>NSMicrophoneUsageDescription</key><string>右⌘を押している間の声を文字にするために使います（Macの中だけで処理）。</string>
</dict></plist>
PL
codesign --force --sign - $APP
rm -rf Koe.app
ditto $APP Koe.app
rm -rf $WORK
echo "built: $(pwd)/Koe.app"
