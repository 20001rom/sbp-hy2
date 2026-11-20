#!/usr/bin/env bash
# 验证 Hysteria 的 masquerade file 模式是否支持子路径（/assets/style.css）
set -uo pipefail
HY=/mnt/e/mDocument/mWorkSpace/dsh-remote-ws/sbp-lite/bin/hysteria-linux-amd64
T=$(mktemp -d)

mkdir -p "$T/www/assets"
echo "<html><body>INDEX</body></html>" > "$T/www/index.html"
echo "body{color:red}" > "$T/www/assets/style.css"

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout "$T/k.pem" -out "$T/c.pem" -days 90 -nodes -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost" >/dev/null 2>&1

cat > "$T/c.yaml" <<EOF
listen: :18443
tls:
  cert: "$T/c.pem"
  key: "$T/k.pem"
auth:
  type: password
  password: "testpass"
masquerade:
  type: file
  file:
    dir: "$T/www"
outbounds:
  - name: default
    type: direct
EOF

echo "=== 启动服务 ==="
"$HY" server -c "$T/c.yaml" > "$T/srv.log" 2>&1 &
P=$!
sleep 2
ss -Huln | grep -q ':18443' && echo "  已监听 18443" || { echo "  启动失败"; head -5 "$T/srv.log"; kill $P 2>/dev/null; rm -rf "$T"; exit 1; }

echo
echo "=== 检查 Hysteria 文档关于 file 模式的说明 ==="
"$HY" server --help 2>&1 | grep -iE 'masquerade|file' | head -3 || echo "  (help 无相关信息)"

echo
echo "=== 关键：Hysteria 的 file 模式是否支持子目录 ==="
echo "  这点无法用 openssl 验证（需要 HTTP/3 客户端）"
echo "  但可以从源码/文档推断："

# 查 hysteria 二进制里的路径处理逻辑
strings "$HY" 2>/dev/null | grep -iE 'http\.FileServer|stripPrefix|filepath\.' | head -8 | sed 's/^/    /'

echo
echo "=== 保守做法：内联 CSS 最安全 ==="
echo "  如果 file 模式只返回 index.html，子路径会 404"
echo "  → CSS 加载失败 → 页面裸奔"
echo "  → 这本身就是可疑特征（真实网站一定有样式）"

kill $P 2>/dev/null
rm -rf "$T"