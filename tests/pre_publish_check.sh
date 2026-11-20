#!/usr/bin/env bash
cd /mnt/e/mDocument/mWorkSpace/dsh-remote-ws/sbp-lite || exit 1
echo "=== 语法检查 ==="
for f in sbp.sh sbp-hy2.sh sbp-xray.sh; do
  printf '  %-14s ' "$f"
  if bash -n "$f" 2>/dev/null; then echo "OK"; else echo "FAIL"; fi
done

echo
echo "=== 仓库地址解析 ==="
grep -n 'SBP_REPO=' sbp-hy2.sh sbp-xray.sh | sed 's/^/  /'
echo "  → 实际 raw 地址:"
echo "    Hy2 : https://raw.githubusercontent.com/20001rom/sbp-hy2/main/bin/hysteria-linux-amd64"
echo "    Xray: https://raw.githubusercontent.com/20001rom/sbp-xray/main/bin/xray-linux-64"

echo
echo "=== README 快速开始命令 ==="
grep -A2 'raw.githubusercontent' README-HY2.md 2>/dev/null | head -6 | sed 's/^/  /'
grep 'raw.githubusercontent' README.md 2>/dev/null | head -2 | sed 's/^/  /'

echo
echo "=== 自检 ==="
bash sbp-hy2.sh selftest 2>&1 | tail -4 | sed 's/^/  /'
bash sbp-xray.sh selftest 2>&1 | tail -4 | sed 's/^/  /'
