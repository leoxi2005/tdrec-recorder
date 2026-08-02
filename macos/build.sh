#!/bin/bash
#
#  build.sh — biên dịch TDRec và đóng thành TDRec.app
#
#  Dùng:  ./build.sh          → build + đóng gói vào ./dist/TDRec.app
#         ./build.sh test     → build rồi chạy self-test
#         ./build.sh install   → build + copy vào /Applications
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST="$ROOT/dist"
APP="$DIST/TDRec.app"

cd "$ROOT"

echo "▸ Biên dịch (release)…"
swift build -c release

BIN="$ROOT/.build/release/TDRec"
[ -x "$BIN" ] || { echo "✗ Không tìm thấy binary"; exit 1; }

if [ "${1:-}" = "test" ]; then
    echo
    "$BIN" --selftest --width "${2:-1920}" --height "${3:-1080}" --seconds "${4:-5}"
    exit $?
fi

echo "▸ Tạo icon…"
ICONSET="$DIST/TDRec.iconset"
rm -rf "$ICONSET"
swift "$ROOT/tools/makeicon.swift" "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$DIST/TDRec.icns"
rm -rf "$ICONSET"

echo "▸ Đóng gói .app…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/TDRec"
cp -R "$ROOT/Frameworks/Syphon.framework" "$APP/Contents/Frameworks/"
cp "$DIST/TDRec.icns" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>TDRec</string>
    <key>CFBundleDisplayName</key>       <string>TDRec</string>
    <key>CFBundleIdentifier</key>        <string>studio.leoxi.tdrec</string>
    <key>CFBundleVersion</key>           <string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleExecutable</key>        <string>TDRec</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>CFBundleIconFile</key>          <string>TDRec</string>
    <!-- Không cho macOS App Nap treo app khi cửa sổ bị che — sẽ rớt frame. -->
    <key>LSUIElement</key>               <false/>
    <key>NSSupportsAutomaticTermination</key>  <false/>
    <key>NSSupportsSuddenTermination</key>     <false/>
</dict>
</plist>
PLIST

# rpath trỏ vào Frameworks bên trong bundle để app chạy độc lập,
# không phụ thuộc đường dẫn build.
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP/Contents/MacOS/TDRec" 2>/dev/null || true

# Ký ad-hoc để Gatekeeper cho chạy trên chính máy này.
codesign --force --deep --sign - "$APP" 2>/dev/null || \
    echo "  (bỏ qua codesign — app vẫn chạy được trên máy này)"

echo "▸ Xong: $APP"

if [ "${1:-}" = "install" ]; then
    rm -rf /Applications/TDRec.app
    cp -R "$APP" /Applications/
    echo "▸ Đã cài vào /Applications/TDRec.app"
fi

echo
echo "Chạy giao diện :  open '$APP'"
echo "Chạy self-test  :  $APP/Contents/MacOS/TDRec --selftest"
