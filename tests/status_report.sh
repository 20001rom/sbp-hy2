#!/usr/bin/env bash
# Hy2 当前状态汇总
cd /mnt/e/mDocument/mWorkSpace/dsh-remote-ws/sbp-lite || exit 1
mkdir -p tests/bin
[[ -f tests/bin/jq ]] || cp -f "$TEMP/sbp-dl/jq" tests/bin/jq 2>/dev/null || true
chmod +x tests/bin/jq 2>/dev/null || true

echo "============================================================"
echo " SBP-Hy2 状态汇总"
echo "============================================================"

echo
echo "=== 语法检查 ==="
for f in sbp.sh sbp-hy2.sh sbp-xray.sh; do
  printf '  %-14s ' "$f"
  bash -n "$f" && echo "OK" || echo "FAIL"
done

echo
echo "=== 自检 ==="
bash sbp-hy2.sh selftest 2>&1 | tail -10 | sed 's/^/  /'

echo
echo "=== 测试套件 ==="
for t in test_hy2_full test_recon_fixes test_critical_fixes test_check_logic test_unified; do
  printf '  %-24s ' "$t"
  out="$(bash "tests/$t.sh" 2>&1)"
  r="$(printf '%s\n' "$out" | grep -oE 'pass=[0-9]+ fail=[0-9]+' | tail -1)"
  if [[ -n "$r" ]]; then
    echo "$r"
  elif printf '%s\n' "$out" | grep -q '全部通过'; then
    echo "全部通过"
  else
    echo "（需检查）"
  fi
done
