#!/usr/bin/env bash
# 从两张 2048x2048 源图生成 App 图标与菜单栏图标。
#
#   源图：app/Resources/source-app.png    蓝色字形（主体图标用）
#         app/Resources/source-status.png 白色字形（菜单栏模板图用）
#   产物：app/Resources/AppIcon.icns
#         app/Resources/MenuBarIcon.png
#         app/Resources/MenuBarIcon@2x.png
#
# 为什么要这个脚本而不是直接 sips 缩放：
#   源图是 AI 出图，背景不是真透明——有大量 alpha 最高到 32 的压缩噪点。
#   直接缩放会让菜单栏模板图带一圈脏边，而且字形只占画布 58%x83%，
#   不按包围盒重新排布，贴上去会又偏又小。处理逻辑在 make-icons.swift 里。
#
# 用法：
#   ./app/tools/gen-icons.sh              用 Resources 里的源图重新生成
#   ./app/tools/gen-icons.sh <blue> <white>   指定源图
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$ROOT/tools"
RES="$ROOT/Resources"
OUT="$ROOT/build/icongen"
CACHE="$ROOT/build/.modulecache"

BLUE="${1:-$RES/source-app.png}"
WHITE="${2:-$RES/source-status.png}"

for f in "$BLUE" "$WHITE"; do
  if [ ! -f "$f" ]; then
    echo "✗ 找不到源图：$f" >&2
    echo "  先把两张 PNG 放到 app/Resources/source-app.png 与 source-status.png" >&2
    exit 1
  fi
done

mkdir -p "$OUT" "$CACHE"
mkdir -p "$RES"

echo "==> 编译图标生成器"
swiftc -O -target arm64-apple-macos14.0 -module-cache-path "$CACHE" \
  -o "$OUT/make-icons" "$TOOLS/make-icons.swift"

echo "==> 生成"
"$OUT/make-icons" render "$BLUE" "$WHITE" "$OUT"

echo "==> 安装到 Resources"
cp "$OUT/Resources/AppIcon.icns"    "$RES/AppIcon.icns"
cp "$OUT/Resources/MenuBarIcon.png"  "$RES/MenuBarIcon.png"
cp "$OUT/Resources/MenuBarIcon@2x.png" "$RES/MenuBarIcon@2x.png"
cp "$OUT/icon-1024.png"             "$RES/icon-1024.png"

# 预览图给 docs 引用
mkdir -p "$ROOT/../docs/assets"
cp "$OUT/icon-1024.png"         "$ROOT/../docs/assets/icon.png"
cp "$OUT/icon-variants.png"     "$ROOT/../docs/assets/icon-variants.png"
cp "$OUT/menubar-preview.png"   "$ROOT/../docs/assets/icon-menubar.png"

echo "==> 完成"
ls -lh "$RES/AppIcon.icns" "$RES/MenuBarIcon.png" "$RES/MenuBarIcon@2x.png" | awk '{print "    "$5"  "$9}'
