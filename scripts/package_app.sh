#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
BUILD_DIR="$ROOT/.build/arm64-apple-macosx/$CONFIG"
APP="$ROOT/dist/FeatherMac.app"

cd "$ROOT"
swift build -c "$CONFIG" --product FeatherMac

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$BUILD_DIR/FeatherMac" "$APP/Contents/MacOS/FeatherMac"
ditto "$BUILD_DIR/OpenSSL.framework" "$APP/Contents/Frameworks/OpenSSL.framework"
ditto "$BUILD_DIR/FeatherMac_FeatherMac.bundle" "$APP/Contents/Resources/FeatherMac_FeatherMac.bundle"
cp "$ROOT/Assets/FeatherMac.icns" "$APP/Contents/Resources/FeatherMac.icns"
chmod -R u+w "$APP"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>FeatherMac</string>
	<key>CFBundleExecutable</key>
	<string>FeatherMac</string>
	<key>CFBundleIdentifier</key>
	<string>dev.feathermac.app</string>
	<key>CFBundleIconFile</key>
	<string>FeatherMac</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>FeatherMac</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/FeatherMac" 2>/dev/null || true

codesign --force --deep --sign - "$APP"
echo "$APP"
