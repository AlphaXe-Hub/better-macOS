#!/usr/bin/env bash
# 编译并运行 AX 探针。
#
# 为什么要显式 -target 和 -module-cache-path：见 README「swiftc 必须带 -target」。
# CLT 的 SDK(6.3.2) 与编译器(6.3.3) 版本不一致，不指定 target 会撞 arm64e slice 不匹配，
# 报错信息会误导成「SDK 不支持」。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/app/build/ax-probe"
CACHE="$ROOT/app/build/.modulecache"
SDK="$(xcrun --show-sdk-path)"
mkdir -p "$CACHE" "$(dirname "$OUT")"

swiftc -Onone -g \
  -sdk "$SDK" \
  -target arm64-apple-macos14.0 \
  -module-cache-path "$CACHE" \
  -framework AppKit -framework ApplicationServices \
  "$ROOT/scripts/ax-probe/main.swift" \
  -o "$OUT"

exec "$OUT" "$@"
