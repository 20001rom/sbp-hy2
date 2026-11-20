#!/usr/bin/env bash
# 真实 root 部署：完全离线（无 jq、无网络），验证两套都能装
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "需要 root"; exit 1; }
root=/mnt/e/mDocument/mWorkSpace/dsh-remote-ws/sbp-lite
cd "$root"

echo "============================================================"
echo " 完全离线部署验证（无 jq / 无网络）"
echo "============================================================"

echo
echo "=== 确认没有 jq ==="
if command -v jq >/dev/null 2>&1; then
  echo "  系统有 jq: $(command -v jq)  —— 会掩盖问题，临时移开"
  mv "$(command -v jq)" /tmp/jq.bak 2>/dev/null || true
fi
command -v jq >/dev/null 2>&1 && echo "  jq 仍在 PATH 中" || echo "  ✓ 确认无 jq"

# 清掉脚本可能找到的静态 jq
rm -rf /var/lib/sbp-lite

echo
echo "=== 清理旧服务 ==="
for s in hysteria xray; do
  systemctl stop $s 2>/dev/null || true
  systemctl disable $s 2>/dev/null || true
  rm -f /etc/systemd/system/$s.service
done
systemctl daemon-reload 2>/dev/null || true
rm -rf /etc/hysteria /usr/local/etc/xray /usr/local/bin/hysteria /usr/local/bin/xray
echo "  已清理"

echo
echo "=== 准备证书 ==="
T=/tmp/offline-cert; rm -rf $T; mkdir -p $T
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout $T/key.pem -out $T/cert.pem -days 90 -nodes \
  -subj "/CN=www.bing.com" -addext "subjectAltName=DNS:www.bing.com" \
  -addext "basicConstraints=critical,CA:FALSE" >/dev/null 2>&1
echo "  CN=$(openssl x509 -in $T/cert.pem -noout -subject | sed 's/subject=CN=//')"

echo
echo "=== 部署 Hy2（离线）==="
export HY2_BIN="$root/bin/hysteria-linux-amd64"
export TLS_MODE=manual TLS_CERT="$T/cert.pem" TLS_KEY="$T/key.pem"
export OBFS_TYPE=gecko OBFS_PASSWORD="offlinetest123"
export MASQ_TYPE=proxy MASQ_URL="https://www.bing.com"
export HY2_LISTEN=":443"

bash sbp-hy2.sh deploy 2>&1 | grep -E '^\[|完成|错误|警告|无需 jq|监听' | head -20 | sed 's/^/  /'

echo
echo "=== 部署 Xray（离线，用本地 bin/）==="
export XRAY_BIN="$root/bin/xray-linux-64"
export REALITY_SERVER="www.bing.com"
export VERIFY_DEST_STRICT=0
export ENABLE_VLESS_REALITY=true

bash sbp-xray.sh deploy 2>&1 | grep -E '^\[|完成|错误|警告|本地仓库|监听' | head -20 | sed 's/^/  /'

echo
echo "=== 关键验证：两套同时监听 443（TCP + UDP）==="
echo "  --- UDP/443 ---"
ss -Huln | grep -E ':443\b' | sed 's/^/    /' || echo "    无"
echo "  --- TCP/443 ---"
ss -Htln | grep -E ':443\b' | sed 's/^/    /' || echo "    无"

echo
echo "=== 服务状态 ==="
for s in hysteria xray; do
  printf '  %-10s %s\n' "$s" "$(systemctl is-active $s 2>/dev/null || echo not-found)"
done

echo
echo "=== 恢复 jq ==="
[[ -f /tmp/jq.bak ]] && mv /tmp/jq.bak "$(dirname "$(command -v jq 2>/dev/null || echo /usr/local/bin/jq)")/jq" 2>/dev/null && echo "  已恢复" || echo "  无需恢复"

U=$(ss -Huln | grep -cE ':443\b' || true)
Tc=$(ss -Htln | grep -cE ':443\b' || true)
HS=$(systemctl is-active hysteria 2>/dev/null || true)
XS=$(systemctl is-active xray 2>/dev/null || true)

echo
echo "=== 结论 ==="
echo "  UDP/443=$U  TCP/443=$Tc  hysteria=$HS  xray=$XS"
if [[ "$U" -ge 1 && "$Tc" -ge 1 && "$HS" == "active" && "$XS" == "active" ]]; then
  echo "  ✓ 完全离线（无 jq）下两套都部署成功并共存"
  exit 0
else
  echo "  ✗ 未达预期"
  exit 1
fi
