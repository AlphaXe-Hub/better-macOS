#!/usr/bin/env bash
# 创建并信任一个**本地自签名证书**，用于给 better-macOS 签名。
#
# 为什么需要它：ad-hoc 签名的 designated requirement 就是当次编译产物的 cdhash，
# 每重编译一次，TCC 里的旧授权就作废——表现为「设置里开关还亮着，但功能全挂」。
# 用一个固定的签名身份后，cdhash 会变但签名身份不变，授权可以跨迭代保留。
#
# 这不是 $99 的 Developer ID，不能用来给**别人**分发免 Gatekeeper 的包。
# 它只解决**自己的机器上反复重新授权**这个开发期痛点。
set -euo pipefail
NAME="better-macOS Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "✓ 证书 \"$NAME\" 已存在"
  security find-identity -v -p codesigning | grep "$NAME"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

cat > openssl.cnf <<CNF
[ req ]
distinguished_name = dn
x509_extensions = v3_codesign
prompt = no
[ dn ]
CN = $NAME
O = better-macOS
[ v3_codesign ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

echo "==> 生成自签名证书"
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem \
  -days 3650 -nodes -config openssl.cnf 2>/dev/null
openssl pkcs12 -export -out id.p12 -inkey key.pem -in cert.pem \
  -passout pass:bmac -name "$NAME" -legacy 2>/dev/null

echo "==> 导入登录钥匙串"
security import id.p12 -k "$KEYCHAIN" -P "bmac" \
  -T /usr/bin/codesign -T /usr/bin/security 2>&1 | tail -1

echo "==> 设为受信任的代码签名证书"
security add-trusted-cert -d -r trustRoot -p codeSign -k "$KEYCHAIN" cert.pem 2>/dev/null || true

echo ""
security find-identity -v -p codesigning | grep "$NAME" || {
  echo "✗ 创建失败。请在「钥匙串访问」里手动把 \"$NAME\" 的信任设为「始终信任」。"
  exit 1
}
echo ""
echo "✓ 完成。现在 ./app/build.sh 会自动使用这个身份签名。"
