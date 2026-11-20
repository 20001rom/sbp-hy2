#!/usr/bin/env bash
# 验证：gecko 混淆 + masquerade=proxy 是否冲突
# 官方文档说：启用混淆后不再是有效的 HTTP/3 服务器
# 那 masquerade（依赖 HTTP/3 响应）还能工作吗？
set -uo pipefail
HY=/mnt/e/mDocument/mWorkSpace/dsh-remote-ws/sbp-lite/bin/hysteria-linux-amd64
T=$(mktemp -d)
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout "$T/k.pem" -out "$T/c.pem" -days 90 -nodes -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost" >/dev/null 2>&1

mk(){ cat > "$T/c.yaml" <<EOF
listen: :18443
tls:
  cert: "$T/c.pem"
  key: "$T/k.pem"
auth:
  type: password
  password: "testpass"
masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true
$1
EOF
}

probe(){ # probe <名称> <extra yaml>
  mk "$2"
  echo "--- $1 ---"
  timeout 3 "$HY" server -c "$T/c.yaml" 2>&1 | grep -E 'server up|FATAL|invalid' | head -2 | sed 's/^/    /'
}

echo "=== A: 只有 masquerade（无混淆）==="
probe "无混淆" ""

echo
echo "=== B: salamander + masquerade ==="
probe "salamander" "obfs:
  type: salamander
  salamander:
    password: obfspass"

echo
echo "=== C: gecko + masquerade ==="
probe "gecko" "obfs:
  type: gecko
  gecko:
    password: obfspass
    minPacketSize: 512
    maxPacketSize: 1200"

echo
echo "=== 关键问题：开混淆后 masquerade 还能被访问吗 ==="
echo "  官方文档原话："
echo "  'Enabling obfuscation will make your server incompatible with"
echo "   standard QUIC connections and it will no longer function as a"
echo "   valid HTTP/3 server.'"
echo
echo "  含义：探测者用标准 HTTP/3 客户端访问时，"
echo "        - 无混淆 → 能拿到 masquerade 的内容（看起来像真站）"
echo "        - 有混淆 → 握手就失败（因为每包被 XOR 了）"
echo
echo "  这是本方案的一个潜在矛盾点，需要确认实际行为"

echo
echo "=== D: 实测——用 openssl 尝试 TLS 握手（模拟探测者）==="
mk "obfs:
  type: gecko
  gecko:
    password: obfspass
    minPacketSize: 512
    maxPacketSize: 1200"
"$HY" server -c "$T/c.yaml" > "$T/srv.log" 2>&1 &
P=$!
sleep 2
echo "  服务端状态: $(kill -0 $P 2>/dev/null && echo 运行中 || echo 已退出)"
echo "  尝试 TCP 连接 18443（Hy2 是 UDP，TCP 应该被拒）:"
timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/18443' 2>/dev/null && echo "    TCP 可连（异常）" || echo "    TCP 不可连（正常，Hy2 只用 UDP）"
kill $P 2>/dev/null
echo
echo "  服务端日志:"
head -5 "$T/srv.log" | sed 's/^/    /'

rm -rf "$T"
