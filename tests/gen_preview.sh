#!/usr/bin/env bash
set -uo pipefail
SRC=/mnt/e/mDocument/mWorkSpace/dsh-remote-ws/sbp-lite
rm -rf /tmp/site-preview
mkdir -p /tmp/site-preview
cd /tmp
source "$SRC/lib/masq-site.sh"
warn(){ echo "[警告] $*" >&2; }
ok(){ echo "[完成] $*"; }
TLS_DOMAIN=acme-lab.com
masq_site_gen /tmp/site-preview
echo
echo "=== 文件清单 ==="
find /tmp/site-preview -type f | sort | sed 's|/tmp/site-preview/||' | sed 's/^/  /'
echo
echo "=== index.html 是否含内联 CSS ==="
grep -c '<style>' /tmp/site-preview/index.html
echo "=== 是否还引用外部 CSS ==="
grep -c 'style.css' /tmp/site-preview/index.html || echo "0（正确，无外部引用）"
echo
echo "=== 复制到 Windows ==="
cp -r /tmp/site-preview/* /mnt/e/mDocument/mWorkSpace/dsh-remote-ws/sbp-lite/tests/preview/ 2>/dev/null
ls /mnt/e/mDocument/mWorkSpace/dsh-remote-ws/sbp-lite/tests/preview/
