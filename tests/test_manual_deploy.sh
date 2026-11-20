#!/usr/bin/env bash
# 验证：不用脚本，纯 heredoc 手写配置能否跑起来
set -uo pipefail
HY=/mnt/e/mDocument/mWorkSpace/dsh-remote-ws/sbp-lite/bin/hysteria-linux-amd64
T=$(mktemp -d)

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout "$T/key.pem" -out "$T/cert.pem" -days 90 -nodes \
  -subj "/CN=www.bing.com" -addext "subjectAltName=DNS:www.bing.com" >/dev/null 2>&1

PWD1=$(openssl rand -base64 24 | tr -d '\n')
PWD2=$(openssl rand -base64 24 | tr -d '\n')

echo "=== 极简配置（heredoc 直接写，不依赖脚本）==="
cat > "$T/config.yaml" <<EOF
listen: :18443
tls:
  cert: $T/cert.pem
  key: $T/key.pem
obfs:
  type: gecko
  gecko:
    password: "$PWD2"
    minPacketSize: 512
    maxPacketSize: 1200
auth:
  type: password
  password: "$PWD1"
masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true
EOF
cat "$T/config.yaml" | sed 's/^/  /'

echo
echo "=== 真实启动验证 ==="
timeout 3 "$HY" server -c "$T/config.yaml" 2>&1 | head -5 | sed 's/^/  /'

echo
echo "=== 生成的链接（手算）==="
PWD_ENC=$(printf '%s' "$PWD1" | sed 's|/|%2F|g; s|+|%2B|g; s|=|%3D|g')
OBFS_ENC=$(printf '%s' "$PWD2" | sed 's|/|%2F|g; s|+|%2B|g; s|=|%3D|g')
echo "  hysteria2://${PWD_ENC}@SERVER_IP:18443?sni=www.bing.com&insecure=1&obfs=gecko&obfs-password=${OBFS_ENC}"

echo
echo "=== 行数统计 ==="
echo "  配置 $(wc -l < "$T/config.yaml") 行，密码 2 个"
echo "  → 不需要脚本也能部署"

rm -rf "$T"
