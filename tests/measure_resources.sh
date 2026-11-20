#!/usr/bin/env bash
# 实测：Hy2 + Xray 同时运行的真实资源占用
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "需要 root"; exit 1; }
root=/mnt/e/mDocument/mWorkSpace/dsh-remote-ws/sbp-lite
cd "$root"
T=/tmp/res-test; rm -rf $T; mkdir -p $T

echo "=== 系统资源 ==="
echo "  内存: $(free -h | awk '/^Mem:/{print $2" 总 / "$7" 可用"}')"
echo "  CPU: $(nproc) 核"
echo "  磁盘: $(df -h / | awk 'NR==2{print $2" 总 / "$4" 可用"}')"

# 准备证书
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout "$T/k.pem" -out "$T/c.pem" -days 90 -nodes -subj "/CN=test.local" \
  -addext "subjectAltName=DNS:test.local" >/dev/null 2>&1

# ===== Hy2 配置 =====
cat > "$T/hy2.yaml" <<EOF
listen: :35543
tls:
  cert: "$T/c.pem"
  key: "$T/k.pem"
auth:
  type: password
  password: "testpass"
congestion:
  type: bbr
masquerade:
  type: file
  file:
    dir: "$T/www"
outbounds:
  - name: default
    type: direct
EOF
mkdir -p "$T/www"; echo "<html>test</html>" > "$T/www/index.html"

# ===== Xray 配置（用 jq 生成，避免手写错）=====
KP="$("$root/bin/xray-linux-64" x25519 2>/dev/null)"
PRIV="$(printf '%s\n' "$KP" | grep -i PrivateKey | sed 's/.*:[[:space:]]*//')"
UUID="$("$root/bin/xray-linux-64" uuid 2>/dev/null)"
cat > "$T/xray.json" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "protocol": "vless", "port": 18443,
    "settings": {"clients": [{"id": "$UUID", "flow": "xtls-rprx-vision"}], "decryption": "none"},
    "streamSettings": {
      "network": "tcp", "security": "reality",
      "realitySettings": {
        "dest": "www.bing.com:443", "serverNames": ["www.bing.com"],
        "privateKey": "$PRIV", "shortIds": ["aabbccdd11223344"]
      }
    }
  }],
  "outbounds": [{"protocol": "freedom", "tag": "direct"}]
}
EOF

echo
echo "=== 基线（都不跑）==="
BASE_MEM=$(free -m | awk '/^Mem:/{print $3}')
echo "  已用内存: ${BASE_MEM} MB"

echo
echo "=== 只跑 Hy2 ==="
"$root/bin/hysteria-linux-amd64" server -c "$T/hy2.yaml" > "$T/hy2.log" 2>&1 &
HYPID=$!
sleep 3
HY_RSS=$(ps -o rss= -p $HYPID 2>/dev/null | tr -d ' ' || echo 0)
HY_CPU=$(ps -o %cpu= -p $HYPID 2>/dev/null | tr -d ' ' || echo 0)
echo "  Hy2 PID=$HYPID  RSS=$((HY_RSS/1024)) MB  CPU=${HY_CPU}%"
grep -q 'server up' "$T/hy2.log" && echo "  状态: 运行中" || echo "  状态: 启动失败"

echo
echo "=== 只跑 Xray ==="
"$root/bin/xray-linux-64" run -c "$T/xray.json" > "$T/xray.log" 2>&1 &
XRPID=$!
sleep 3
XR_RSS=$(ps -o rss= -p $XRPID 2>/dev/null | tr -d ' ' || echo 0)
XR_CPU=$(ps -o %cpu= -p $XRPID 2>/dev/null | tr -d ' ' || echo 0)
echo "  Xray PID=$XRPID  RSS=$((XR_RSS/1024)) MB  CPU=${XR_CPU}%"
kill -0 $XRPID 2>/dev/null && echo "  状态: 运行中" || echo "  状态: 启动失败"
kill $XRPID 2>/dev/null; wait $XRPID 2>/dev/null || true

echo
echo "=== 同时跑两个 ==="
"$root/bin/xray-linux-64" run -c "$T/xray.json" > "$T/xray2.log" 2>&1 &
XRPID2=$!
sleep 3
HY_RSS2=$(ps -o rss= -p $HYPID 2>/dev/null | tr -d ' ' || echo 0)
XR_RSS2=$(ps -o rss= -p $XRPID2 2>/dev/null | tr -d ' ' || echo 0)
TOTAL_RSS=$(( (HY_RSS2 + XR_RSS2) / 1024 ))
NOW_MEM=$(free -m | awk '/^Mem:/{print $3}')
DELTA=$(( NOW_MEM - BASE_MEM ))

echo "  Hy2  RSS=$((HY_RSS2/1024)) MB"
echo "  Xray RSS=$((XR_RSS2/1024)) MB"
echo "  ---"
echo "  两进程 RSS 合计: ${TOTAL_RSS} MB"
echo "  系统内存实际增量: ${DELTA} MB（含共享库）"

echo
echo "=== 端口占用验证 ==="
ss -Huln | grep -E ':35543\b' | sed 's/^/  UDP: /' || echo "  UDP 35543 未监听"
ss -Htln | grep -E ':18443\b' | sed 's/^/  TCP: /' || echo "  TCP 18443 未监听"

echo
echo "=== 文件句柄与线程 ==="
for pid in $HYPID $XRPID2; do
  name=$(ps -o comm= -p $pid 2>/dev/null)
  [[ -z "$name" ]] && continue
  fds=$(ls /proc/$pid/fd 2>/dev/null | wc -l)
  thr=$(ls /proc/$pid/task 2>/dev/null | wc -l)
  printf '  %-10s FD=%-4s 线程=%s\n' "$name" "$fds" "$thr"
done

kill $HYPID $XRPID2 2>/dev/null
wait 2>/dev/null || true

echo
echo "=== 结论 ==="
echo "  两套核心合计常驻内存约 ${TOTAL_RSS} MB"
if (( TOTAL_RSS < 100 )); then
  echo "  → 512MB 内存的 VPS 完全够用"
elif (( TOTAL_RSS < 200 )); then
  echo "  → 512MB 够用，1GB 更宽裕"
else
  echo "  → 建议至少 1GB"
fi

rm -rf "$T"
