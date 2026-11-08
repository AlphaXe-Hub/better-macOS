#!/usr/bin/env bash
# 一键：构建 → 装到 /Applications → 启动 → 打开迁移清单
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="better-macOS"

echo "==> 构建"
"$ROOT/build.sh" release

echo "==> 安装到 /Applications（覆盖旧版本）"
pkill -x "$APP" 2>/dev/null || true
sleep 0.5
rm -rf "/Applications/$APP.app"
cp -R "$ROOT/build/$APP.app" "/Applications/"

echo "==> 启动"
open "/Applications/$APP.app"
sleep 2

if pgrep -x "$APP" >/dev/null; then
  echo "✓ 已启动。菜单栏右上角会出现一个键盘图标。"
else
  echo "✗ 启动失败，试着直接跑：/Applications/$APP.app/Contents/MacOS/$APP"
  exit 1
fi
