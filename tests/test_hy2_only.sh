#!/usr/bin/env bash
# 模拟：仓库里只有 Hy2，没有 Xray，验证 sbp.sh 是否正常
set -uo pipefail
src=/mnt/e/mDocument/mWorkSpace/dsh-remote-ws/sbp-lite
T=$(mktemp -d)
mkdir -p "$T/bin" "$T/tests/bin"

# 只复制 Hy2 相关文件
cp -f "$src/sbp.sh" "$src/sbp-hy2.sh" "$T/"
cp -f "$src/bin/hysteria-linux-amd64" "$T/bin/" 2>/dev/null || true
cp -f "$src/tests/bin/jq" "$T/tests/bin/jq" 2>/dev/null || true
chmod +x "$T/tests/bin/jq" 2>/dev/null || true

echo "=== 模拟仓库内容 ==="
ls "$T" | sed 's/^/  /'
echo "  （注意：没有 sbp-xray.sh）"

cd "$T"
export SBP_DIR="$T"
export SBP_TEST_ROOT=1

pass=0; fail=0
ck(){ if [[ "$1" == "$2" ]]; then printf '  OK   %s\n' "$3"; pass=$((pass+1));
      else printf '  FAIL %s (got=%s want=%s)\n' "$3" "$1" "$2"; fail=$((fail+1)); fi; }

echo
echo "=== 1) 语法 ==="
bash -n sbp.sh && ck yes yes "sbp.sh 语法 OK" || ck no yes "sbp.sh 语法 OK"

echo
echo "=== 2) selftest（Xray 缺失不应导致失败）==="
if out="$(bash sbp.sh selftest 2>&1)"; then
  ck yes yes "selftest 通过"
  printf '%s\n' "$out" | grep -E 'hy2|xray|脚本' | sed 's/^/    /'
else
  ck no yes "selftest 通过"
  printf '%s\n' "$out" | head -10 | sed 's/^/    /'
fi

echo
echo "=== 3) status（不崩）==="
set +e
out="$(bash sbp.sh status 2>&1)"; rc=$?
set -e
ck "$rc" "0" "status 返回 0"
printf '%s' "$out" | grep -q 'hy2' && ck yes yes "status 显示 hy2" || ck no yes "status 显示 hy2"

echo
echo "=== 4) links（不崩）==="
set +e
out="$(bash sbp.sh links 2>&1)"; rc=$?
set -e
ck "$rc" "0" "links 返回 0"

echo
echo "=== 5) install xray 应给出明确错误（而不是崩）==="
set +e
out="$(bash sbp.sh install xray 2>&1)"; rc=$?
set -e
echo "  退出码: $rc"
printf '%s' "$out" | grep -qE '缺少.*sbp-xray|只包含 Hy2' && ck yes yes "给出明确提示" || ck no yes "给出明确提示"

echo
echo "=== 6) install all（应跳过 Xray 而非失败）==="
set +e
out="$(HY2_BIN=/nonexistent bash sbp.sh install all 2>&1)"; rc=$?
set -e
echo "  退出码: $rc"
printf '%s' "$out" | grep -qE '没有 sbp-xray|跳过 Xray' && ck yes yes "跳过 Xray 并提示" || ck no yes "跳过 Xray 并提示"

echo
echo "========== pass=$pass fail=$fail =========="
rm -rf "$T"
(( fail == 0 )) && { echo "全部通过"; exit 0; } || { echo "有失败项"; exit 1; }
