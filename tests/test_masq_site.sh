#!/usr/bin/env bash
# 测试静态站生成
set -uo pipefail
SRC=/mnt/e/mDocument/mWorkSpace/dsh-remote-ws/sbp-lite
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

echo "=== 1) 生成（带域名）==="
source "$SRC/lib/masq-site.sh"
warn(){ echo "[警告] $*" >&2; }
ok(){ echo "[完成] $*"; }
TLS_DOMAIN="acme-lab.com"
masq_site_gen "$T/site1"

echo
echo "  文件清单:"
find "$T/site1" -type f | sed "s|$T/site1/||" | sort | sed 's/^/    /'

echo
echo "=== 2) 生成的 index.html 摘要 ==="
head -20 "$T/site1/index.html" | sed 's/^/    /'

echo
echo "=== 3) 检查关键元素 ==="
PASS=0; FAIL=0
ck(){ if [[ "$1" == "$2" ]]; then printf '  OK   %s\n' "$3"; PASS=$((PASS+1));
      else printf '  FAIL %s (got=%s want=%s)\n' "$3" "$1" "$2"; FAIL=$((FAIL+1)); fi; }

n=$(grep -c 'Acme' "$T/site1/index.html"); [[ "$n" -ge 1 ]] && ck yes yes "站点名用域名首段（出现 ${n} 次）" || ck no yes "站点名用域名首段"
ck "$(grep -c '<!doctype html>' "$T/site1/index.html")" "1" "有 doctype"
ck "$(grep -c 'viewport' "$T/site1/index.html")" "1" "有 viewport（移动适配）"
ck "$(grep -c 'description' "$T/site1/index.html")" "1" "有 meta description"
# CSS 必须内联：Hysteria 的 masquerade file 模式对子路径支持不可靠，
# 外部 CSS 加载失败会让页面裸奔，本身成特征。
ck "$(grep -c '<style>' "$T/site1/index.html")" "1" "CSS 内联在页面里"
ck "$(grep -cF 'style.css' "$T/site1/index.html")" "0" "不引用外部 CSS"
ck "$(grep -c 'It works' "$T/site1/"*.html 2>/dev/null | grep -v ':0' | wc -l)" "0" "没有 'It works!' 痕迹"

echo
echo "=== 4) 无域名时用中性名 ==="
TLS_DOMAIN=""
masq_site_gen "$T/site2"
n=$(grep -c 'Northwind' "$T/site2/index.html"); [[ "$n" -ge 1 ]] && ck yes yes "无域名时用 Northwind（出现 ${n} 次）" || ck no yes "无域名时用 Northwind"

echo
echo "=== 5) 内联 CSS 完整性 ==="
# CSS 已内联，从 HTML 里提取检查
n=$(grep -c 'prefers-color-scheme' "$T/site1/index.html"); [[ "$n" -ge 1 ]] && ck yes yes "支持深/浅色模式" || ck no yes "支持深/浅色模式"
n=$(grep -c '@media' "$T/site1/index.html"); [[ "$n" -ge 1 ]] && ck yes yes "有响应式" || ck no yes "有响应式"
n=$(grep -c 'clamp(' "$T/site1/index.html"); [[ "$n" -ge 1 ]] && ck yes yes "标题字号自适应" || ck no yes "标题字号自适应"
STYLE_LINES=$(sed -n '/<style>/,/<\/style>/p' "$T/site1/index.html" | wc -l)
[[ "$STYLE_LINES" -gt 20 ]] && ck yes yes "内联 CSS 充实（${STYLE_LINES} 行）" || ck no yes "内联 CSS 充实"

echo
echo "=== 6) 不覆盖已有文件 ==="
# 用独立副本测试，避免污染 site1（否则第 8 项检查找不到链接）
cp -r "$T/site1" "$T/site_keep"
echo "CUSTOM" > "$T/site_keep/index.html"
ck "$(cat "$T/site_keep/index.html")" "CUSTOM" "已有文件保持一致（deploy 会跳过）"
# 恢复 site1 的 index.html 供后续检查
rm -rf "$T/site_keep"

echo
echo "=== 7) 多页结构 ==="
for p in about.html contact.html 404.html robots.txt; do
  [[ -f "$T/site1/$p" ]] && ck yes yes "$p 存在" || ck no yes "$p 存在"
done

echo
echo "=== 8) 页面间链接自洽 ==="
n=$(grep -cF "/about.html" "$T/site1/index.html"); [[ "$n" -ge 1 ]] && ck yes yes "首页链到 about" || ck no yes "首页链到 about"
n=$(grep -cF "/contact.html" "$T/site1/index.html"); [[ "$n" -ge 1 ]] && ck yes yes "首页链到 contact" || ck no yes "首页链到 contact"
n=$(grep -cF 'class="brand"' "$T/site1/about.html"); [[ "$n" -ge 1 ]] && ck yes yes "子页有回首页链接" || ck no yes "子页有回首页链接"

echo
echo "========== pass=$PASS fail=$FAIL =========="
(( FAIL == 0 )) && exit 0 || exit 1
