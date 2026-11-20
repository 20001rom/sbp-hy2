#!/usr/bin/env bash
# 测试统一入口 sbp.sh
set -uo pipefail
root=/mnt/e/mDocument/mWorkSpace/dsh-remote-ws/sbp-lite
cd "$root"
export SBP_DIR="$root"
export SBP_TEST_ROOT=1

pass=0; fail=0
ck(){ if [[ "$1" == "$2" ]]; then printf '  OK   %s\n' "$3"; pass=$((pass+1));
      else printf '  FAIL %s\n        got =%s\n        want=%s\n' "$3" "$1" "$2"; fail=$((fail+1)); fi; }

echo "=== 1) 语法与自检 ==="
bash -n sbp.sh && ck yes yes "语法通过" || ck no yes "语法通过"
if out="$(bash sbp.sh selftest 2>&1)"; then
  ck yes yes "selftest 通过"
  printf '%s\n' "$out" | grep -E 'OPK|OK|存在|SKIP|主备' | head -8 | sed 's/^/    /'
else
  ck no yes "selftest 通过"
  printf '%s\n' "$out" | head -15 | sed 's/^/    /'
fi

echo
echo "=== 2) status（未部署时）==="
out="$(bash sbp.sh status 2>&1)"
printf '%s\n' "$out" | sed 's/^/  /'
printf '%s' "$out" | grep -qE '组件|hy2|xray' && ck yes yes "status 输出了组件表" || ck no yes "status 输出了组件表"

echo
echo "=== 3) links（未部署时不应崩）==="
set +e
out="$(bash sbp.sh links 2>&1)"; rc=$?
set -e
ck "$rc" "0" "links 返回码 0"
printf '%s\n' "$out" | grep -qE '未部署|没有可用' && ck yes yes "给出未部署提示" || ck no yes "给出未部署提示"

echo
echo "=== 4) switch（无参数）==="
out="$(bash sbp.sh switch 2>&1)"
printf '%s' "$out" | grep -q 当前主力 && ck yes yes "显示当前主力" || ck no yes "显示当前主力"
printf '%s' "$out" | grep -q 用法 && ck yes yes "给出用法" || ck no yes "给出用法"

echo
echo "=== 5) switch hy2 / xray 写标记 ==="
export ROLE_FILE=/tmp/sbp-test-role
rm -f "$ROLE_FILE"
out="$(ROLE_FILE=$ROLE_FILE bash -c "SBP_TEST_ROOT=1 bash sbp.sh switch hy2" 2>&1)" || true
if [[ -f "$ROLE_FILE" ]]; then
  ck "$(cat "$ROLE_FILE")" "hy2" "switch hy2 写入标记"
else
  ck "(无文件)" "hy2" "switch hy2 写入标记"
fi

echo
echo "=== 6) diagnose ==="
out="$(bash sbp.sh diagnose 2>&1)"
printf '%s\n' "$out" | grep -qE '系统|端口|服务|结论' && ck yes yes "diagnose 输出各段" || ck no yes "diagnose 输出各段"
printf '%s' "$out" | grep -qE '443/udp|443/tcp' && ck yes yes "报告了 443 端口状态" || ck no yes "报告了 443 端口状态"

echo
echo "=== 7) usage ==="
out="$(bash sbp.sh --help 2>&1)"
printf '%s' "$out" | grep -qE 'TCP 和 UDP 的 443' && ck yes yes "usage 解释了共存原因" || ck no yes "usage 解释了共存原因"

echo
echo "=== 8) 未知参数 ==="
set +e
bash sbp.sh bogus >/dev/null 2>&1; rc=$?
set -e
ck "$rc" "1" "未知参数返回 1"

echo
echo "=== 9) 组件脚本存在性 ==="
"[[ -f sbp-hy2.sh ]]" 2>/dev/null || true
[[ -f sbp-hy2.sh ]] && ck yes yes "sbp-hy2.sh 存在" || ck no yes "sbp-hy2.sh 存在"
[[ -f sbp-xray.sh ]] && ck yes yes "sbp-xray.sh 存在" || ck no yes "sbp-xray.sh 存在"

echo
rm -f "$ROLE_FILE"
echo "========== pass=$pass fail=$fail =========="
(( fail == 0 )) && { echo "全部通过"; exit 0; } || { echo "有失败项"; exit 1; }
