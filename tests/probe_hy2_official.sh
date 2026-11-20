#!/usr/bin/env bash
# 验证官方 Hysteria 2 的配置结构
set -uo pipefail
HY="/mnt/e/mDocument/mWorkSpace/dsh-remote-ws/sbp-lite/tests/hysteria"
T=$(mktemp -d)

echo "=== 版本 ==="
"$HY" version 2>&1 | grep -iE 'version|v2\.' | head -2

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout "$T/k.pem" -out "$T/c.pem" -days 90 -nodes -subj "/CN=www.bing.com" \
  -addext "subjectAltName=DNS:www.bing.com" >/dev/null 2>&1

try(){ # try <名称> <yaml>
  printf '%s' "$2" > "$T/s.yaml"
  echo -n "  $1: "
  if out="$("$HY" server -c "$T/s.yaml" -f /dev/null 2>&1 &)"; then :; fi
  # 用 --help 不行，改成短暂启动看是否报配置错
  timeout 2 "$HY" server -c "$T/s.yaml" > "$T/out.log" 2>&1 || true
  if grep -qiE 'failed to (load|parse)|invalid|unknown field|error' "$T/out.log"; then
    echo "配置有问题:"
    grep -iE 'failed|invalid|unknown|error' "$T/out.log" | head -2 | sed 's/^/      /'
  else
    echo "启动无配置错误"
    grep -iE 'server up|listening|started' "$T/out.log" | head -1 | sed 's/^/      /'
  fi
}

BASE_LISTEN='listen: :8443'

echo
echo "=== 1) 最简配置（password 认证 + 基本 TLS）==="
try "最简" "listen: :8443
acme:
  domains: [example.com]
  email: a@b.com
auth:
  type: password
  password: testpass
"

echo
echo "=== 2) tls 证书模式 ==="
try "tls 证书" "listen: :8443
tls:
  cert: $T/c.pem
  key: $T/k.pem
auth:
  type: password
  password: testpass
"

echo
echo "=== 3) salamander 混淆 ==="
try "salamander" "listen: :8443
tls:
  cert: $T/c.pem
  key: $T/k.pem
obfs:
  type: salamander
  salamander:
    password: obfspass
auth:
  type: password
  password: testpass
"

echo
echo "=== 4) gecko 混淆 ==="
try "gecko" "listen: :8443
tls:
  cert: $T/c.pem
  key: $T/k.pem
obfs:
  type: gecko
  gecko:
    password: obfspass
    minPacketSize: 512
    maxPacketSize: 1200
auth:
  type: password
  password: testpass
"

echo
echo "=== 5) masquerade proxy ==="
try "masquerade proxy" "listen: :8443
tls:
  cert: $T/c.pem
  key: $T/k.pem
auth:
  type: password
  password: testpass
masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true
"

echo
echo "=== 6) ACL 分流 ==="
try "ACL" "listen: :8443
tls:
  cert: $T/c.pem
  key: $T/k.pem
auth:
  type: password
  password: testpass
acl:
  inline:
    - reject(geoip:cn)
    - reject(suffix:example.com)
outbounds:
  - name: default
    type: direct
"

echo
echo "=== 7) 端口跳跃 ==="
try "端口段" "listen: :20000-50000
tls:
  cert: $T/c.pem
  key: $T/k.pem
auth:
  type: password
  password: testpass
"

echo
echo "=== 8) udpIdleTimeout + bandwidth ==="
try "拥塞参数" "listen: :8443
tls:
  cert: $T/c.pem
  key: $T/k.pem
auth:
  type: password
  password: testpass
bandwidth:
  up: 100 mbps
  down: 100 mbps
udpIdleTimeout: 60s
congestion:
  type: bbr
  bbrProfile: standard
"

rm -rf "$T"
