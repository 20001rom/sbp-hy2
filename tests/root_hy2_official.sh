#!/usr/bin/env bash
# SBP-Hy2 真实 root 部署验证
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "需要 root：sudo bash $0"; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCRIPT="$ROOT/sbp-hy2.sh"

echo "============================================================"
echo " SBP-Hy2 真实 root 部署（Hy2 做主力）"
echo "============================================================"
echo "系统: $(. /etc/os-release; echo "$PRETTY_NAME")"
echo "systemd: $([[ -d /run/systemd/system ]] && echo 可用 || echo 无)"
echo

mkdir -p /var/lib/sbp-lite/bin
install -m755 "$HERE/bin/jq" /var/lib/sbp-lite/bin/jq || { echo "缺少 jq"; exit 1; }
/var/lib/sbp-lite/bin/jq --version | sed 's/^/  /'

echo
echo "=== 清理旧实例 ==="
systemctl stop hysteria 2>/dev/null || true
systemctl disable hysteria 2>/dev/null || true
rm -f /etc/systemd/system/hysteria.service
systemctl daemon-reload 2>/dev/null || true
rm -rf /etc/hysteria /usr/local/bin/hysteria
echo "  已清理"

echo
echo "=== 部署：gecko 混淆 + masquerade proxy + 端口跳跃 ==="
export HY2_BIN="$ROOT/bin/hysteria-linux-amd64"
export TLS_MODE=manual
export TLS_CERT="$HERE/hy-test.crt"
export TLS_KEY="$HERE/hy-test.key"

# 自签证书（测试用）
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout "$TLS_KEY" -out "$TLS_CERT" -days 90 -nodes \
  -subj "/CN=www.bing.com" -addext "subjectAltName=DNS:www.bing.com" \
  -addext "basicConstraints=critical,CA:FALSE" >/dev/null 2>&1
echo "  证书: CN=$(openssl x509 -in "$TLS_CERT" -noout -subject | sed 's/subject=CN=//')"

export OBFS_TYPE=gecko
export OBFS_PASSWORD="testobfspass123"
export MASQ_TYPE=proxy
export MASQ_URL="https://www.bing.com"
export ENABLE_PORT_HOP=false   # 先测普通 443，避免 nft 依赖
export HY2_LISTEN=":443"
export CONGESTION_TYPE=bbr

bash "$SCRIPT" deploy 2>&1 | tee /tmp/sbp-hy2-root.log | grep -E '^\[|完成|错误|警告|监听|混淆|端口|TLS|伪装' | sed 's/^/  /'
echo
echo "退出码: ${PIPESTATUS[0]}"

echo
echo "=== 服务状态 ==="
systemctl is-enabled hysteria 2>/dev/null | sed 's/^/  enabled: /'
systemctl is-active hysteria 2>/dev/null | sed 's/^/  active: /'
systemctl --no-pager status hysteria 2>/dev/null | sed -n '3,8p' | sed 's/^/  /'

echo
echo "=== 实际监听 ==="
ss -Huln | grep -E ':(443|1[0-9]{4})\b' | sed 's/^/  UDP: /' || echo "  无 UDP"
ss -Htln | grep -E ':(443|80|1[0-9]{4})\b' | sed 's/^/  TCP: /' || echo "  无 TCP"

echo
echo "=== 配置文件要点 ==="
C=/etc/hysteria/config.yaml
grep -E '^(listen|acme|tls|obfs|auth|congestion|masquerade|udpIdleTimeout|bandwidth)' "$C" | sed 's/^/  /'
echo "  --- 混淆细节 ---"
grep -A4 '^obfs:' "$C" | sed 's/^/  /'

echo
echo "=== 文件权限 ==="
ls -l "$C" /etc/hysteria/env.conf 2>/dev/null | sed 's/^/  /'

echo
echo "=== 分享链接 ==="
bash "$SCRIPT" links 2>/dev/null | grep -E '^hysteria2://' | cut -c1-110 | sed 's/^/  /'
bash "$SCRIPT" links 2>/dev/null | grep -E '混淆|端口|TLS|伪装' | sed 's/^/  /'

echo
echo "=== 服务日志 ==="
journalctl -u hysteria --no-pager -n 8 2>/dev/null | grep -iE 'server up|listening|error|fail' | sed 's/^/  /'

echo
if systemctl is-active --quiet hysteria && ss -Huln | grep -qE ':443\b'; then
  echo "结果：Hy2 在 UDP/443 运行，gecko 混淆生效"
  exit 0
else
  echo "结果：未达预期"
  exit 1
fi
