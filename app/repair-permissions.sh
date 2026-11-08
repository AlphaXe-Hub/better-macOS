#!/usr/bin/env bash
# 修复「授权后功能不工作」。
#
# 为什么需要这个：我们用的是 ad-hoc 签名，它的 designated requirement
# 就是那一次编译产物的 cdhash。每次重新编译 cdhash 都变，而 TCC 里存的
# 是旧 cdhash → 设置面板里开关还亮着，但 API 调用全部失败。
# 这是签名机制决定的，不是 bug。拿到 Developer ID 后就不会再出现。
#
# 用法：./app/repair-permissions.sh
set -euo pipefail
APP="better-macOS"
BUNDLE_ID="dev.better-mac.app"

echo "==> 退出正在运行的 App"
pkill -x "$APP" 2>/dev/null || true
sleep 1

echo "==> 清除 TCC 中的旧授权记录（bundle id: ${BUNDLE_ID}）"
tccutil reset Accessibility "$BUNDLE_ID" 2>&1 || true
tccutil reset ListenEvent "$BUNDLE_ID" 2>&1 || true

echo "==> 重新安装"
ROOT="$(cd "$(dirname "$0")" && pwd)"
rm -rf "/Applications/${APP}.app"
cp -R "${ROOT}/build/${APP}.app" "/Applications/"

echo "==> 启动（会引导你重新授权）"
open "/Applications/${APP}.app"
sleep 2
echo ""
echo "完成。请在弹出的引导窗口里重新拖一次图标，或在系统设置里重新勾选。"
