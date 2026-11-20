#!/usr/bin/env bash
# 验证部署时静态站被正确生成并接入 masquerade
set -uo pipefail
SRC=/mnt/e/mDocument/mWorkSpace/dsh-remote-ws/sbp-lite
T=$(mktemp -d)
mkdir -p "$T/bin" "$T/hy"

cp -f "$SRC/tests/bin/jq" "$T/jq" 2>/dev/null && chmod +x "$T/jq" 2>/dev/null
export PATH="$T:$PATH"
export HY2_BIN="$SRC/bin/hysteria-linux-amd64"
export BIN_PATH="$T/bin/hysteria"
export HY_DIR="$T/hy" CONF_YAML="$T/hy/config.yaml"
export ENV_FILE="$T/hy/env.conf" ACME_DIR="$T/hy/acme"
export MASQ_DIR="$T/hy/www"
export TLS_MODE=manual TLS_CERT="$T/hy/c.pem" TLS_KEY="$T/hy/k.pem"
export HY2_LISTEN=":18443"
export TLS_DOMAIN="acme-lab.com"
export SBP_TEST_ROOT=1
export SBP_DIR="$SRC"

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout "$T/hy/k.pem" -out "$T/hy/c.pem" -days 90 -nodes \
  -subj "/CN=acme-lab.com" -addext "subjectAltName=DNS:acme-lab.com" >/dev/null 2>&1

PASS=0; FAIL=0
ck(){ if [[ "$1" == "$2" ]]; then printf '  OK   %s\n' "$3"; PASS=$((PASS+1));
      else printf '  FAIL %s (got=%s want=%s)\n' "$3" "$1" "$2"; FAIL=$((FAIL+1)); fi; }

echo "=== 部署（非 root，跳过 systemd）==="
set +e
out="$(bash "$SRC/sbp-hy2.sh" deploy 2>&1)"; rc=$?
set -e
echo "  退出码: $rc（1 是预期的，非 root 写不了 systemd）"

echo
echo "=== 1) 静态站是否生成 ==="
if [[ -d "$MASQ_DIR" ]]; then
  ck yes yes "MASQ_DIR 存在"
  echo "  文件清单:"
  find "$MASQ_DIR" -type f 2>/dev/null | sed "s|$MASQ_DIR/||" | sort | sed 's/^/    /'
else
  ck no yes "MASQ_DIR 存在"
fi

echo
echo "=== 2) 页面数量与关键文件 ==="
for f in index.html about.html contact.html 404.html robots.txt; do
  [[ -f "$MASQ_DIR/$f" ]] && ck yes yes "$f" || ck no yes "$f"
done
# CSS 必须内联，不应有 assets/ 子目录
if [[ -d "$MASQ_DIR/assets" ]]; then
  ck yes no "无 assets 子目录（CSS 应内联）"
else
  ck yes yes "无 assets 子目录（CSS 已内联）"
fi

echo
echo "=== 3) 不是简陋占位页 ==="
if grep -q 'It works' "$MASQ_DIR/index.html" 2>/dev/null; then
  ck no yes "不含 'It works!'"
else
  ck yes yes "不含 'It works!'"
fi
LINES=$(wc -l < "$MASQ_DIR/index.html" 2>/dev/null || echo 0)
echo "  index.html 行数: $LINES"
[[ "$LINES" -gt 40 ]] && ck yes yes "页面内容充实（>40 行）" || ck no yes "页面内容充实"

echo
echo "=== 4) 站点名取自域名 ==="
n=$(grep -c 'Acme-lab' "$MASQ_DIR/index.html" 2>/dev/null || echo 0)
[[ "$n" -ge 1 ]] && ck yes yes "站点名 Acme-lab（出现 ${n} 次）" || ck no yes "站点名取自域名"

echo
echo "=== 5) 配置指向正确目录 ==="
if [[ -f "$CONF_YAML" ]]; then
  echo "  masquerade 段:"
  grep -A4 '^masquerade:' "$CONF_YAML" | sed 's/^/    /'
  n=$(grep -cF "$MASQ_DIR" "$CONF_YAML")
  [[ "$n" -ge 1 ]] && ck yes yes "配置里 dir 指向 MASQ_DIR" || ck no yes "配置里 dir 指向 MASQ_DIR"
fi

echo
echo "=== 6) 已存在时不覆盖 ==="
echo "MY-CUSTOM-SITE" > "$MASQ_DIR/index.html"
bash "$SRC/sbp-hy2.sh" deploy >/dev/null 2>&1 || true
ck "$(cat "$MASQ_DIR/index.html")" "MY-CUSTOM-SITE" "自定义页面未被覆盖"

echo
echo "========== pass=$PASS fail=$FAIL =========="
rm -rf "$T"
(( FAIL == 0 )) && { echo "✅ 静态站接入正常"; exit 0; } || { echo "❌ 有失败项"; exit 1; }
