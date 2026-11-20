#!/usr/bin/env bash
# 验证几个边界场景的配置生成
set -uo pipefail
root=/mnt/e/mDocument/mWorkSpace/dsh-remote-ws/sbp-lite
cd "$root"
T=$(mktemp -d)
mkdir -p "$T/bin" "$T/hy"
cp -f tests/bin/jq "$T/bin/jq" 2>/dev/null || { echo "缺 jq"; exit 1; }
chmod +x "$T/bin/jq"
export PATH="$T/bin:$PATH"
export BIN_PATH="$root/bin/hysteria-linux-amd64"
export HY_DIR="$T/hy" CONF_YAML="$T/hy/config.yaml" ACME_DIR="$T/hy/acme"
export ENV_FILE="$T/hy/env.conf"
export TLS_MODE=manual TLS_CERT="$T/hy/c.pem" TLS_KEY="$T/hy/k.pem"
export HY2_LISTEN=:18443
export SBP_TEST_ROOT=1

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout "$T/hy/k.pem" -out "$T/hy/c.pem" -days 90 -nodes -subj "/CN=www.bing.com" \
  -addext "subjectAltName=DNS:www.bing.com" >/dev/null 2>&1

r(){ ( export "$@"; bash sbp-hy2.sh render ) 2>/dev/null; }

echo "=== 1) OBFS_TYPE=none 但设了 OBFS_PASSWORD ==="
r OBFS_TYPE=none OBFS_PASSWORD=shouldbeignored > "$T/a.yaml"
echo "  生成的 obfs 段:"
grep -A3 '^obfs:' "$T/a.yaml" 2>/dev/null | sed 's/^/    /' || echo "    （无 obfs 段，正确）"
echo "  密码是否泄漏到配置: $(grep -c 'shouldbeignored' "$T/a.yaml" || echo 0) 处（应为 0）"

echo
echo "=== 2) ACL 开启但 ACL_REJECT_CN=false（inline 为空？）==="
r ENABLE_ACL=true ACL_REJECT_CN=false > "$T/b.yaml"
echo "  生成的 acl 段:"
grep -A3 '^acl:' "$T/b.yaml" | sed 's/^/    /'
echo "  --- 真实校验 ---"
timeout 3 "$BIN_PATH" server -c "$T/b.yaml" 2>&1 | grep -E 'server up|FATAL|invalid|error' | head -2 | sed 's/^/    /'

echo
echo "=== 3) ignoreClientBandwidth 单独设置（无 BW_UP/DOWN）==="
r IGNORE_CLIENT_BW=true > "$T/c.yaml"
echo "  bandwidth 段是否存在: $(grep -c '^bandwidth:' "$T/c.yaml" || echo 0)（当前逻辑：只在有 BW 时输出）"
grep -A3 '^bandwidth:' "$T/c.yaml" 2>/dev/null | sed 's/^/    /' || echo "    （无 bandwidth 段）"
echo "  → ignoreClientBandwidth 被忽略了，这是缺陷吗？"

echo
echo "=== 4) 密码含特殊字符 ==="
r OBFS_TYPE=salamander OBFS_PASSWORD='pa"ss\wo/rd+=' > "$T/d.yaml"
echo "  生成的 obfs 密码行:"
grep -A3 'salamander:' "$T/d.yaml" | grep password | sed 's/^/    /'
echo "  --- 真实校验 ---"
timeout 3 "$BIN_PATH" server -c "$T/d.yaml" 2>&1 | grep -E 'server up|FATAL|invalid|yaml' | head -3 | sed 's/^/    /'

echo
echo "=== 5) 端口跳跃 + masquerade 双栈（端口冲突？）==="
r ENABLE_PORT_HOP=true HY2_PORT_START=20000 HY2_PORT_END=50000 \
  ENABLE_LISTEN_HTTPS=true > "$T/e.yaml"
echo "  listen 与 listenHTTPS:"
grep -E '^listen:|listenHTTPS:' "$T/e.yaml" | sed 's/^/    /'
echo "  → listenHTTPS :443 (TCP) 与 listen :20000-50000 (UDP) 不冲突，OK"

rm -rf "$T"
