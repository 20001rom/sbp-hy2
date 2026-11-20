#!/usr/bin/env bash
# 验证：纯离线（无 jq、无网络）时 Hy2 能否部署
set -uo pipefail
root=/mnt/e/mDocument/mWorkSpace/dsh-remote-ws/sbp-lite
T=$(mktemp -d)

echo "=== 环境检查 ==="
echo -n "  jq: "; command -v jq >/dev/null 2>&1 && echo "有" || echo "无（正是我们要测的）"
echo -n "  curl/wget: "; (command -v curl || command -v wget) >/dev/null 2>&1 && echo "有" || echo "无"

mkdir -p "$T/hy"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout "$T/hy/k.pem" -out "$T/hy/c.pem" -days 90 -nodes \
  -subj "/CN=www.bing.com" -addext "subjectAltName=DNS:www.bing.com" >/dev/null 2>&1

export HY2_BIN="$root/bin/hysteria-linux-amd64"
export BIN_PATH="$T/bin/hysteria"
export HY_DIR="$T/hy" CONF_YAML="$T/hy/config.yaml" ACME_DIR="$T/hy/acme"
export ENV_FILE="$T/hy/env.conf"
export TLS_MODE=manual TLS_CERT="$T/hy/c.pem" TLS_KEY="$T/hy/k.pem"
export OBFS_TYPE=gecko OBFS_PASSWORD=testpass
export HY2_LISTEN=":18443"
export SBP_TEST_ROOT=1

echo
echo "=== 在「无 jq」的 PATH 下渲染配置 ==="
# 构造一个没有 jq 的 PATH
mkdir -p "$T/bin"
for t in bash openssl date cat grep sed awk mktemp mv chmod rm mkdir printf uname \
         timeout sha256sum install cp dirname basename tr head tail wc; do
  s="$(command -v "$t" 2>/dev/null)" && ln -sf "$s" "$T/bin/$t" 2>/dev/null || true
done

cd "$root"
out="$(env -i PATH="$T/bin" HOME="$T" SBP_BIN_DIR="$T/bin" \
  HY2_BIN="$HY2_BIN" BIN_PATH="$BIN_PATH" HY_DIR="$HY_DIR" CONF_YAML="$CONF_YAML" \
  ACME_DIR="$ACME_DIR" ENV_FILE="$ENV_FILE" TLS_MODE=manual \
  TLS_CERT="$TLS_CERT" TLS_KEY="$TLS_KEY" OBFS_TYPE=gecko OBFS_PASSWORD=testpass \
  HY2_LISTEN=:18443 SBP_TEST_ROOT=1 \
  bash sbp-hy2.sh render 2>&1)"
rc=$?

echo "  返回码: $rc"
echo "  --- 输出 ---"
printf '%s\n' "$out" | head -25 | sed 's/^/    /'

echo
echo "=== 判定 ==="
if printf '%s' "$out" | grep -q '^listen:'; then
  echo "  ✓ 无 jq 也能渲染配置"
else
  echo "  ✗ 渲染失败"
fi

echo
echo "=== 用真实 Hysteria 校验该配置 ==="
printf '%s\n' "$out" > "$T/c.yaml"
if timeout 3 "$root/bin/hysteria-linux-amd64" server -c "$T/c.yaml" 2>&1 | grep -qE 'server up|invalid config|failed to load'; then
  r="$(timeout 3 "$root/bin/hysteria-linux-amd64" server -c "$T/c.yaml" 2>&1 | grep -oE 'server up and running|invalid config|failed to load server config' | head -1)"
  echo "  结果: $r"
else
  echo "  结果: 无法判定"
fi

rm -rf "$T"
