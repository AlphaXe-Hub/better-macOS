#!/usr/bin/env bash
# 自测：验证纯逻辑（不需要任何 TCC 授权）。
#
# 这里测的是产品的**语义核心**，不是 UI：
#   - Carbon 位掩码解码（⌘ 隐含、bit3 = 无⌘）
#   - 虚拟键码 → 显示字符
#   - 按键 → 动作名的匹配
#   - 吐司的过滤规则（打字不弹、纯修饰键不弹）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/build/SelfTest"
SDK="$(xcrun --show-sdk-path)"
CACHE="$ROOT/build/.modulecache"
mkdir -p "$CACHE"

echo "==> 编译自测"
rm -f "$OUT"
set +e
COMPILE_LOG=$(swiftc -O -sdk "$SDK" -target arm64-apple-macos14.0 -module-cache-path "$CACHE" \
  -framework AppKit -framework ApplicationServices \
  "$ROOT"/Sources/MenuInventory.swift \
  "$ROOT"/Sources/KeyWatcher.swift \
  "$ROOT"/Sources/InlineText.swift \
  "$ROOT"/Sources/MigrationCatalog.swift \
  "$ROOT"/Sources/AppContext.swift \
  "$ROOT"/Sources/Corrections.swift \
  "$ROOT"/Tests/main.swift \
  -o "$OUT" 2>&1)
COMPILE_RC=$?
set -e
if [ $COMPILE_RC -ne 0 ] || [ ! -f "$OUT" ]; then
  echo "$COMPILE_LOG" | grep -E "error" || echo "$COMPILE_LOG"
  echo "✗ 编译失败——测试没有运行（拒绝拿旧二进制冒充通过）"
  exit 1
fi

echo "==> 运行"
"$OUT"
