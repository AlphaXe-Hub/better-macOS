#!/usr/bin/env bash
# 把已构建的 .app 打成可分发的 DMG。
#
# 用法：
#   ./scripts/make-dmg.sh                 # 用 app/build/better-macOS.app
#   ./scripts/make-dmg.sh <app> <out.dmg>
#
# 设计取舍：不用 create-dmg 这类第三方工具（要 brew install，且把简单的事
# 藏进一层黑箱）。hdiutil 是系统自带的，行为可预测，出问题能自己查。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/app/build/better-macOS.app}"
VOLNAME="better-macOS"
APP_NAME="$(basename "$APP" .app)"

[ -d "$APP" ] || { echo "✗ 找不到 .app：$APP" >&2; echo "  先跑 ./app/build.sh release" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 0.0.0)"

# 输出名带版本号：用户下载多份时不会互相覆盖，Release 页上也一眼看出是哪个版本。
# 必须放在 VERSION 解析之后——之前用 ${OUT} 的默认值写死在参数里，拿不到版本。
OUT="${2:-$ROOT/dist/better-macOS-$VERSION.dmg}"
mkdir -p "$(dirname "$OUT")"
[ -e "$OUT" ] && rm -f "$OUT"

echo "==> 暂存"
STAGE="$(mktemp -d)"
WORK="$(mktemp -d)"
trap 'rm -rf "$STAGE" "$WORK"' EXIT
cp -R "$APP" "$STAGE/"
# 沙盒/隔离属性不该进产物：它们会随 DMG 传给用户
xattr -cr "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

# 构建产物里可能残留 ad-hoc 签名，这里不强改——签名身份的决定权在 build.sh。
SIG="$(codesign -dv "$APP" 2>&1 | grep -i 'Authority=' | head -1 || true)"
echo "   签名：${SIG:-未签名 / ad-hoc}"

echo "==> 生成 UDRW 镜像"
# RW 放在 WORK 里，绝不能放 STAGE 里——否则 hdiutil 会把正在写的镜像自己打进镜像。
RW="$WORK/tmp.dmg"
hdiutil create -quiet -srcfolder "$STAGE" -volname "$VOLNAME" \
  -fs HFS+ -format UDRW "$RW" >/dev/null

echo "==> 挂载并美化"
MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen -plist "$RW" \
  | python3 -c 'import plistlib,sys
d=plistlib.loads(sys.stdin.buffer.read())
for e in d.get("system-entities",[]):
    m=e.get("mount-point")
    if m: print(m)' | head -1)"

if [ -n "${MOUNT:-}" ] && [ -d "$MOUNT" ]; then
  # 用 AppleScript 设置 Finder 视图。
  #
  # **必须加超时且失败不致命**：osascript 驱动 Finder 需要「自动化」授权，
  # 那个授权框在某些会话里根本弹不出来，脚本会无限挂起——比丑图标的代价大得多。
  # 这里用 perl 的 alarm 给一个硬超时。
  osascript -e 'tell application "Finder"' \
           -e 'tell disk "better-macOS"' \
           -e 'open' \
           -e 'set current view of container window to icon view' \
           -e 'set the bounds of container window to {200, 120, 760, 520}' \
           -e 'set viewOptions to the icon view options of container window' \
           -e 'set arrangement of viewOptions to not arranged' \
           -e 'set icon size of viewOptions to 128' \
           -e 'close' \
           -e 'end tell' \
           -e 'end tell' >/dev/null 2>&1 &
  OSA_PID=$!
  ( sleep 20; kill -9 $OSA_PID 2>/dev/null ) >/dev/null 2>&1 &
  WATCHDOG=$!
  if wait $OSA_PID 2>/dev/null; then
    echo "   Finder 视图已设置"
  else
    echo "   （Finder 美化跳过：无 GUI 自动化授权或超时，不影响 DMG 可用性）"
  fi
  kill $WATCHDOG 2>/dev/null || true
  sync
  hdiutil detach -quiet "$MOUNT" >/dev/null 2>&1 || hdiutil detach -force "$MOUNT" >/dev/null 2>&1
else
  echo "   （未挂载成功，跳过美化）"
  hdiutil detach "$RW" >/dev/null 2>&1 || true
fi

echo "==> 压缩（UDZO，发布格式）"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null

echo "==> 校验"
hdiutil verify -quiet "$OUT" >/dev/null 2>&1 && echo "   镜像校验通过"
hdiutil imageinfo "$OUT" 2>/dev/null | grep -E 'Format:|Compressed Size' | sed 's/^/   /'

SIZE="$(du -h "$OUT" | cut -f1)"
echo "==> 完成：${OUT}（${SIZE}，版本 ${VERSION}）"

# 明确告诉用户这份产物能干什么、不能干什么
if codesign -dv "$APP" 2>&1 | grep -q 'Authority=Developer ID Application'; then
  echo "   签名身份是 Developer ID —— 可以走 ./scripts/notarize.sh 公证，用户下载双击即用"
else
  cat <<'WARN'
   注意：这份 DMG 用的是自签名 / ad-hoc 签名，**没有公证**。
   在别人机器上：需要 右键 → 打开，或在「隐私与安全性」里点「仍要打开」。
   这不是 bug，是 Apple 对未公证产物的强制拦截。
   要彻底解决需要 Developer ID（$99/年），见 docs/distribution.md。
WARN
fi
