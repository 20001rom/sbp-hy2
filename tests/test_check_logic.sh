#!/usr/bin/env bash
# 直接验证 check_config 对端口占用日志的处理
set -uo pipefail
cd /mnt/e/mDocument/mWorkSpace/dsh-remote-ws/sbp-lite

# 模拟二进制在端口被占时的真实输出
OCCUPIED_LOG='2026-11-20T18:00:00+08:00	FATAL	failed to load server config	{"error": "invalid config: listen: listen udp :18443: bind: address already in use"}'
PERM_LOG='2026-11-20T18:00:00+08:00	FATAL	failed to load server config	{"error": "invalid config: listen: listen udp :443: bind: permission denied"}'
REAL_ERR='2026-11-20T18:00:00+08:00	FATAL	failed to load server config	{"error": "invalid config: auth: unknown auth type \"bogus\""}'

# 复现脚本里的判定逻辑
judge(){
  local out="$1"
  local fatal
  fatal="$(printf '%s' "$out" | grep -iE 'failed to load server config|invalid config|unknown field|cannot unmarshal|FATAL' \
           | grep -viE 'quic: server closed' \
           | grep -viE 'bind: address already in use|bind: permission denied' || true)"
  if [[ -n "$fatal" ]]; then echo "FAIL"; else echo "PASS"; fi
}

echo "=== 判定逻辑验证 ==="
printf '  %-46s → %s （期望 PASS）\n' "端口被占用" "$(judge "$OCCUPIED_LOG")"
printf '  %-46s → %s （期望 PASS）\n' "无权限绑 443" "$(judge "$PERM_LOG")"
printf '  %-46s → %s （期望 FAIL）\n' "真实配置错误（auth.type 非法）" "$(judge "$REAL_ERR")"
printf '  %-46s → %s （期望 PASS）\n' "正常关闭 quic: server closed" "$(judge 'server stopped {"error": "quic: server closed"}')"

echo
echo "=== 判定 ==="
fail=0
[[ "$(judge "$OCCUPIED_LOG")" == "PASS" ]] || { echo "  ✗ 端口占用被误判"; fail=1; }
[[ "$(judge "$PERM_LOG")" == "PASS" ]] || { echo "  ✗ 无权限被误判"; fail=1; }
[[ "$(judge "$REAL_ERR")" == "FAIL" ]] || { echo "  ✗ 真实错误未识别"; fail=1; }
(( fail == 0 )) && echo "  ✓ 全部正确" || exit 1
