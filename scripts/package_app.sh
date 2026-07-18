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
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsArbitraryLoads</key>
		<true/>
	</dict>
</dict>
</plist>
PLIST

install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/FeatherMac" 2>/dev/null || true

# 签名身份：默认用钥匙串里的 Developer ID Application；没有就退回 ad-hoc 自签。
# ad-hoc 的包能在本机跑，但别人下载后会被 Gatekeeper 拦住。
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"

if [ -n "$SIGN_IDENTITY" ]; then
  echo "Signing as: $SIGN_IDENTITY"
  # 公证要求强化运行时；--timestamp 让签名在证书到期后依然有效。
  CODESIGN_FLAGS=(--force --options runtime --timestamp --sign "$SIGN_IDENTITY")
else
  echo "No Developer ID Application identity found — falling back to ad-hoc signing."
  echo "The result will not pass Gatekeeper on other machines."
  CODESIGN_FLAGS=(--force --sign -)
fi

# 由内向外逐个签，不用 --deep（苹果明确不推荐，且公证会因此失败）。
codesign "${CODESIGN_FLAGS[@]}" "$APP/Contents/Frameworks/OpenSSL.framework/Versions/A"
codesign "${CODESIGN_FLAGS[@]}" "$APP/Contents/Resources/FeatherMac_FeatherMac.bundle"
codesign "${CODESIGN_FLAGS[@]}" "$APP"

codesign --verify --strict --verbose=2 "$APP"

# 公证：NOTARIZE=1 时提交给苹果并把票据装订进 app。
# 没有公证的话，即便有 Developer ID 签名，别人下载后仍会被 Gatekeeper 拦。
# 凭据直接复用 FeatherMac 里配置的 App Store Connect API 密钥，无需 app 专用密码。
if [ "${NOTARIZE:-0}" = "1" ]; then
  if [ -z "$SIGN_IDENTITY" ]; then
    echo "Cannot notarize an ad-hoc signed build." >&2
    exit 1
  fi
  CONFIG_JSON="$HOME/Library/Application Support/FeatherMac/appstoreconnect.json"
  eval "$(python3 - "$CONFIG_JSON" <<'PY'
import json, shlex, sys
key = json.load(open(sys.argv[1]))["keys"][0]
print("ASC_KEY=%s" % shlex.quote(key["privateKeyPath"]))
print("ASC_KID=%s" % shlex.quote(key["keyID"]))
print("ASC_ISS=%s" % shlex.quote(key["issuerID"]))
PY
)"
  NOTARY_ZIP="$(mktemp -d)/notarize.zip"
  ditto -c -k --keepParent --sequesterRsrc "$APP" "$NOTARY_ZIP"
  xcrun notarytool submit "$NOTARY_ZIP" \
    --key "$ASC_KEY" --key-id "$ASC_KID" --issuer "$ASC_ISS" \
    --wait --timeout 30m
  xcrun stapler staple "$APP"
  rm -f "$NOTARY_ZIP"
fi

# 最终判定：accepted 才是用户下载后能直接双击打开的状态。
spctl -a -vv "$APP" || true
echo "$APP"
