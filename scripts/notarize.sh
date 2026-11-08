#!/usr/bin/env bash
# 公证 DMG。**没有 Developer ID 就不会跑通**，这里如实报错而不是假装成功。
#
# 前置条件（三样缺一不可）：
#   1. Developer ID Application 证书（$99/年 Apple Developer Program）
#   2. App 用该证书签名（不是自签名 / ad-hoc）
#   3. Hardened Runtime 已开启（notarytool 的硬性要求）
#
# 用法：
#   ./scripts/notarize.sh <file.dmg|app>
#
# 凭据（二选一，都不写进仓库）：
#   xcrun notarytool store-credentials better-macOS-notary \
#       --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
#   然后：export NOTARY_PROFILE=better-macOS-notary
#
#   或者直接给三个环境变量：APPLE_ID / TEAM_ID / APP_SPECIFIC_PASSWORD
set -euo pipefail

TARGET="${1:-}"
[ -n "$TARGET" ] || { echo "用法：$0 <file.dmg|app>" >&2; exit 2; }
[ -e "$TARGET" ] || { echo "✗ 找不到：$TARGET" >&2; exit 1; }

# —— 前置检查：先把"注定失败"的情况说清楚，别让用户等 10 分钟才看到超时 ——
echo "==> 前置检查"

SIG_INFO="$(codesign -dv "$TARGET" 2>&1 || true)"
if ! grep -q 'Authority=Developer ID Application' <<<"$SIG_INFO"; then
  cat >&2 <<'FAIL'
✗ 这不是 Developer ID 签名，公证必然被拒。

  Apple 只接受 Developer ID Application 证书签名的产物。
  自签名（better-macOS Dev）和 ad-hoc 都不行——这不是脚本的限制，是公证服务的规则。

  需要：
    1. Apple Developer Program（$99/年，个人或公司）
    2. 生成 Developer ID Application 证书并导入钥匙串
    3. 重新签名：
         codesign --force --deep --options runtime \
           --sign "Developer ID Application: <你的名字> (TEAMID)" \
           better-macOS.app
       注意 --options runtime 不能省：公证强制要求 Hardened Runtime。

  拿到证书前，分发方式是「DMG + 右键打开」，见 docs/distribution.md。
FAIL
  exit 3
fi

if ! codesign -d --entitlements - "$TARGET" 2>/dev/null | grep -q 'get-task-allow'; then
  echo "   ✓ Hardened Runtime 合规（无 get-task-allow）"
else
  echo "✗ 存在 get-task-allow entitlement，公证会拒。发布构建必须去掉。" >&2
  exit 3
fi

# —— 凭据 ——
if [ -n "${NOTARY_PROFILE:-}" ]; then
  CRED=(--keychain-profile "$NOTARY_PROFILE")
  echo "   凭据：keychain profile '$NOTARY_PROFILE'"
elif [ -n "${APPLE_ID:-}" ] && [ -n "${TEAM_ID:-}" ] && [ -n "${APP_SPECIFIC_PASSWORD:-}" ]; then
  CRED=(--apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_SPECIFIC_PASSWORD")
  echo "   凭据：环境变量（APPLE_ID/TEAM_ID/APP_SPECIFIC_PASSWORD）"
else
  cat >&2 <<'FAIL'
✗ 没有公证凭据。

  二选一：
    xcrun notarytool store-credentials better-macOS-notary \
        --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
    export NOTARY_PROFILE=better-macOS-notary

  或：
    export APPLE_ID=... TEAM_ID=... APP_SPECIFIC_PASSWORD=...

  注意：密码必须是 App 专用密码，不是你的 Apple ID 密码。
FAIL
  exit 4
fi

# —— 提交 ——
echo "==> 提交公证（通常 1–15 分钟）"
SUBMIT_JSON="$(xcrun notarytool submit "$TARGET" "${CRED[@]}" --output-format json)"
SUB_ID="$(python3 -c 'import json,sys;print(json.load(sys.stdin).get("id",""))' <<<"$SUBMIT_JSON")"
STATUS="$(python3 -c 'import json,sys;print(json.load(sys.stdin).get("status",""))' <<<"$SUBMIT_JSON")"
echo "   id=$SUB_ID status=$STATUS"

if [ "$STATUS" != "Accepted" ]; then
  echo "==> 取日志"
  xcrun notarytool log "$SUB_ID" "${CRED[@]}" 2>&1 | tail -60 || true
  echo "✗ 公证未通过（status=$STATUS）。上面的日志是唯一可信的原因。" >&2
  exit 5
fi

# —— 装订 ——
echo "==> 装订票据（stapler）"
# 注意：.app 不能被直接提交公证，"you can't upload the .app bundle directly"，
# 必须先打进 dmg/zip。装订同理：对 dmg 装订才会随分发走。
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"

echo "==> 完成：$TARGET 已公证并装订"
# 冒烟：Gatekeeper 认为它可分发
spctl -a -vv -t open --context context:primary-signature "$TARGET" 2>&1 || \
  spctl -a -vv "$TARGET" 2>&1 || true
