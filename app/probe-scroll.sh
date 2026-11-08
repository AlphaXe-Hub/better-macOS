#!/usr/bin/env bash
# issue #3 取证探针：只读观察 scrollWheel 事件的全部字段。
#
# 用法（在仓库根目录）：
#   ./app/probe-scroll.sh 15             # 真实设备：15 秒内请人去滚
#   ./app/probe-scroll.sh --exercise 8   # 合成事件：只验证字段通路与判据分支
#   ./app/probe-scroll.sh --verify-flip  # 端到端：验证装了 tap 的进程到底改没改事件
#
# 为什么要装成 .app 再跑：TCC 的辅助功能授权是按「签名身份 + bundle」记的。
# 直接 `swiftc -o /tmp/x` 的裸二进制每次都换 cdhash，授权永远对不上——
# 就会看到最坑的那条现象：tapCreate 成功、零投递。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${PROBE_CONFIG:-debug}"
APP="$ROOT/build/better-macOS.app"
BIN="$APP/Contents/MacOS/better-macOS"

if [ ! -x "$BIN" ]; then
  echo "==> 还没有构建产物，先构建 [${CONFIG}]"
  "$ROOT/build.sh" "$CONFIG"
  echo
fi

echo "==> 授权对象是这个 .app，不是 shell："
echo "    ${APP}"
echo "    如果下面 AXIsProcessTrusted=false，把它拖进"
echo "    系统设置 → 隐私与安全性 → 辅助功能，然后再跑一次。"
echo

exec "$BIN" --probe-scroll "$@"
