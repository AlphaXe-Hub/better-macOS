#!/usr/bin/env bash
# 吐司端到端自证：一条命令看到逐项 PASS。
#
#   ./app/e2e.sh              构建 debug 后跑一次
#   ./app/e2e.sh --no-build   用现有二进制跑（迭代时快）
#
# 它回答的是 issue #2 的核心问题：「吐司已发出」之后，**窗口真的在屏幕上吗**。
# 日志能证明代码走到了 hud.show()，但证明不了屏幕上有没有东西——
# 这个 App 历史上就栽在「调用过 orderFront，但 NSPanel.hidesOnDeactivate 把它藏了」
# （commit 7e9b9a5）。所以这里的断言全部以 Window Server 的 onscreen 列表为准。
#
# 不依赖任何 TCC 授权：拿不到「辅助功能」时合成按键两项会 FAIL 并回退到
# 直接调用 handleKey，窗口那一段照样真跑真断言。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/better-macOS.app/Contents/MacOS/better-macOS"

if [ ! -x "$APP" ] || [ "${1:-}" != "--no-build" ]; then
  echo "==> 构建（debug）"
  "$ROOT/build.sh" debug >/dev/null || { echo "✗ 构建失败"; exit 1; }
fi

# 隔离 HOME：自证会往 Diag 日志写内容，并临时改动 hud.enabled / hud.show-unknown。
# 用独立的 CFFIXED_USER_HOME 免得污染真实日志与用户偏好，也让「日志里有没有那行」
# 的断言只看到本次运行的输出。
SANDBOX_HOME="$ROOT/build/e2e-home"

run_once() {
  rm -rf "$SANDBOX_HOME"
  mkdir -p "${SANDBOX_HOME}/Library/Logs"
  echo "==> 端到端自证（隔离 HOME：${SANDBOX_HOME}）"
  echo
  # 超时兜底：任何时候卡住都不该让人干等（正常全程约 6s）
  perl -e 'alarm shift; exec @ARGV' 90 \
    env CFFIXED_USER_HOME="$SANDBOX_HOME" "$APP" --e2e-toast
}

run_once
RC=$?

# 145 = 146-1 → 被 SIGTERM（128+15）。本机另一个 worker 可能正在跑
# ./app/run.sh，它里面的 `pkill -x better-macOS` 会连自证进程一起杀掉。
# 这不是产品 bug，重试一次即可；别让人对着一份被腰斩的报告猜。
if [ "$RC" -ge 128 ]; then
  echo
  echo "⚠️  进程被信号中断（exit=${RC}）——很可能有别的进程执行了 pkill -x better-macOS"
  echo "    重试一次……"
  echo
  sleep 1
  run_once
  RC=$?
fi

echo
if [ "$RC" -eq 0 ]; then
  echo "✓ 吐司端到端自证通过（exit 0）"
else
  echo "✗ 吐司端到端自证失败（exit ${RC}）"
  echo "  完整日志：${SANDBOX_HOME}/Library/Logs/better-macOS.log"
fi
exit "$RC"
