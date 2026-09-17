#!/bin/bash
# ClipNote ビルド: swiftc → .app 組立 → ad-hoc 署名 (sandbox) → 外部通信ゼロ検証
set -euo pipefail
cd "$(dirname "$0")"

APP=ClipNote
BUILD=build
BIN="$BUILD/$APP"
BUNDLE="$BUILD/$APP.app"

mkdir -p "$BUILD"

echo "▶ compile"
SOURCES=$(find Sources -name '*.swift' | sort)
swiftc -O -parse-as-library \
  -target arm64-apple-macos14.0 \
  -framework AppKit -framework SwiftUI -framework ScreenCaptureKit \
  -framework Vision -framework Carbon -framework ServiceManagement -framework UniformTypeIdentifiers -framework ImageIO -lsqlite3 \
  -o "$BIN" $SOURCES

HELPER_BIN="$BUILD/ClipNoteStatus"
echo "▶ compile status helper"
swiftc -O -parse-as-library \
  -target arm64-apple-macos14.0 \
  -framework AppKit \
  -o "$HELPER_BIN" StatusHelper/main.swift Sources/StatusBridge.swift

echo "▶ bundle"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/$APP"
cp "$HELPER_BIN" "$BUNDLE/Contents/MacOS/ClipNoteStatus"
cp Info.plist "$BUNDLE/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/"
[ -f Resources/MenuBarIcon.png ] && cp Resources/MenuBarIcon.png "$BUNDLE/Contents/Resources/"
echo -n 'APPL????' > "$BUNDLE/Contents/PkgInfo"

echo "▶ codesign (ad-hoc, App Sandbox)"
codesign -s - -f --entitlements StatusHelper.entitlements -i obdist.hsp.clipnote.status "$BUNDLE/Contents/MacOS/ClipNoteStatus" 2>&1 | grep -v 'replacing existing signature' || true
codesign -s - -f --entitlements "$APP.entitlements" -i obdist.hsp.clipnote "$BUNDLE" 2>&1 | grep -v 'replacing existing signature' || true

echo
echo "════════ 外部通信ゼロ 証明レポート ════════"
fail=0
check() { # $1=label $2=hits
  if [ -z "$2" ]; then echo "  PASS  $1"; else echo "  FAIL  $1"; echo "$2" | sed 's/^/          /'; fail=1; fi
}
ENT=$(codesign -d --entitlements - "$BUNDLE" 2>/dev/null)
HELPER_ENT=$(codesign -d --entitlements - "$BUNDLE/Contents/MacOS/ClipNoteStatus" 2>/dev/null)
check "エンティトルメントに app-sandbox がある"        "$(echo "$ENT" | grep -q 'com.apple.security.app-sandbox' || echo 'app-sandbox missing')"
check "エンティトルメントに network.* が無い"           "$(echo "$ENT" | grep -i 'security.network' || true)"
check "ヘルパーが sandbox inherit である"               "$(echo "$HELPER_ENT" | grep -q 'com.apple.security.inherit' || echo 'inherit missing')"
check "ヘルパーに network.* が無い"                     "$(echo "$HELPER_ENT" | grep -i 'security.network' || true)"
check "バイナリにネットワーク系シンボル参照が無い"       "$(nm -u "$BIN" | grep -iE 'NSURLSession|NSURLConnection|NWConnection|NWListener|nw_connection|CFSocket|CFStreamCreatePairWithSocket|^_socket$|^_connect$|^_sendto$|^_getaddrinfo$' || true)"
check "ヘルパーにネットワーク系シンボル参照が無い"       "$(nm -u "$HELPER_BIN" | grep -iE 'NSURLSession|NSURLConnection|NWConnection|NWListener|nw_connection|CFSocket|CFStreamCreatePairWithSocket|^_socket$|^_connect$|^_sendto$|^_getaddrinfo$' || true)"
check "CFNetwork / Network.framework を直接リンクしていない" "$(otool -L "$BIN" | grep -E 'CFNetwork|/Network\.framework' || true)"
echo "  ---- リンクしているフレームワーク ----"
otool -L "$BIN" | tail -n +2 | awk '{print "          " $1}'
echo "═══════════════════════════════════════════"
if [ $fail -ne 0 ]; then echo "検証失敗"; exit 1; fi
echo "✅ build OK: $BUNDLE"
