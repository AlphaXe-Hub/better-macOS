#!/usr/bin/env bash
# 构建 better-macOS：swiftc 直接编译 + 手搓 .app bundle。
# 不需要 Xcode.app，不需要开发者证书（ad-hoc 签名即可在本机运行）。
#
# 用法：
#   ./app/build.sh            构建 release
#   ./app/build.sh debug      构建 debug
#   ./app/build.sh release run  构建并启动
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${1:-release}"
RUN="${2:-}"
APP_NAME="better-macOS"
BUNDLE_ID="dev.better-mac.app"
BUILD="$ROOT/build"
APPDIR="$BUILD/$APP_NAME.app"
SDK="$(xcrun --show-sdk-path)"

# 本机 CLT 的 SDK 与编译器版本不匹配时会撞 arm64e slice 错误，
# 必须显式指定 target；显式 module cache 路径避免沙箱不可写。
TARGET="arm64-apple-macos14.0"
CACHE="$BUILD/.modulecache"

OPT_FLAGS=(-O)
[ "$CONFIG" = "debug" ] && OPT_FLAGS=(-Onone -g)

echo "==> 清理"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/Contents/MacOS" "$APPDIR/Contents/Resources" "$CACHE"

echo "==> 编译（swiftc ${OPT_FLAGS[*]}, ${TARGET}）"
swiftc "${OPT_FLAGS[@]}" \
  -sdk "$SDK" \
  -target "$TARGET" \
  -module-cache-path "$CACHE" \
  -framework AppKit \
  -framework Foundation \
  -framework ApplicationServices \
  -framework CoreGraphics \
  "$ROOT"/Sources/*.swift \
  -o "$APPDIR/Contents/MacOS/$APP_NAME"

echo "==> 资源"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APPDIR/Contents/Resources/AppIcon.icns"
  echo "    已嵌入 AppIcon.icns"
else
  echo "    ⚠️ 缺少 Resources/AppIcon.icns（用 ./app/tools/gen-icons.sh 生成）"
fi
for f in MenuBarIcon.png MenuBarIcon@2x.png; do
  if [ -f "$ROOT/Resources/$f" ]; then
    cp "$ROOT/Resources/$f" "$APPDIR/Contents/Resources/$f"
    echo "    已嵌入 $f"
  else
    echo "    ⚠️ 缺少 Resources/$f，菜单栏会退回系统符号 keyboard"
  fi
done

echo "==> Info.plist"
cat > "$APPDIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>        <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>              <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundleDisplayName</key>       <string>better-macOS</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>LSUIElement</key>               <true/>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSHumanReadableCopyright</key>  <string>MIT License</string>
</dict>
</plist>
PLIST

plutil -lint "$APPDIR/Contents/Info.plist" >/dev/null

echo "==> 签名"
# ad-hoc 签名的问题是：designated requirement 就是当次编译的 cdhash，
# 每次重编译 TCC 授权都会失效（设置里开关还亮着，API 全挂）。
# 用固定的自签名证书可以让授权在迭代间保持有效。
# 证书用 ./app/setup-devcert.sh 创建（不需要 $99 开发者账号）。
SIGN_ID="${BMAC_SIGN_ID:-better-macOS Dev}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
  codesign --force --deep --sign "$SIGN_ID" "$APPDIR" 2>/dev/null
  echo "    已用 \"$SIGN_ID\" 签名（授权不会因重编译失效）"
else
  codesign --force --deep --sign - "$APPDIR" 2>/dev/null
  echo "    ⚠️ 未找到 \"$SIGN_ID\"，退回 ad-hoc 签名"
  echo "       这意味着每次重编译都要重新授权。运行 ./app/setup-devcert.sh 可一次性解决。"
fi
codesign -dv "$APPDIR" 2>&1 | grep -E "Signature|Identifier" || true

SIZE=$(du -sh "$APPDIR" | cut -f1)
BIN=$(stat -f%z "$APPDIR/Contents/MacOS/$APP_NAME")
echo "==> 完成：${APPDIR}（bundle ${SIZE}，binary ${BIN} B）"

if [ "$RUN" = "run" ]; then
  echo "==> 启动"
  pkill -x "$APP_NAME" 2>/dev/null || true
  open "$APPDIR"
fi
