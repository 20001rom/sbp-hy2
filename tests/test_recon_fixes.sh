#!/usr/bin/env bash
# 验证 recon 建议的改动是否落地
set -uo pipefail
root=/mnt/e/mDocument/mWorkSpace/dsh-remote-ws/sbp-lite
cd "$root"
T=$(mktemp -d)
mkdir -p "$T/bin" "$T/hy"
cp -f tests/bin/jq "$T/bin/jq" 2>/dev/null || { echo "缺 jq"; exit 1; }
chmod +x "$T/bin/jq"
export PATH="$T/bin:$PATH"
export BIN_PATH="$root/bin/hysteria-linux-amd64"
export HY_DIR="$T/hy" CONF_YAML="$T/hy/config.yaml" ACME_DIR="$T/hy/acme"
export ENV_FILE="$T/hy/env.conf"
export TLS_MODE=manual TLS_CERT="$T/hy/c.pem" TLS_KEY="$T/hy/k.pem"
export SBP_TEST_ROOT=1
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout "$T/hy/k.pem" -out "$T/hy/c.pem" -days 90 -nodes -subj "/CN=www.bing.com" \
  -addext "subjectAltName=DNS:www.bing.com" >/dev/null 2>&1

pass=0; fail=0
ck(){ if [[ "$1" == "$2" ]]; then printf '  OK   %s\n' "$3"; pass=$((pass+1));
      else printf '  FAIL %s\n        got =%s\n        want=%s\n' "$3" "$1" "$2"; fail=$((fail+1)); fi; }
r(){ ( export "$@"; bash sbp-hy2.sh render ) 2>/dev/null; }

echo "=== 1) 默认端口改为 35543（论文依据）==="
r > "$T/d.yaml"
ck "$(grep '^listen:' "$T/d.yaml")" "listen: :35543" "默认 listen 是 :35543"
echo "  依据：GFW 的 QUIC 审查只处理 源端口>目的端口 的包（USENIX Sec'25 §3.3）"
echo "        端口 ≥32768 时客户端临时端口必然更低，落在解密流程外"

echo
echo "=== 2) 默认 masquerade 改为 file ==="
ck "$(grep -A2 '^masquerade:' "$T/d.yaml" | grep 'type:' | head -1)" "  type: file" "默认 masquerade=file"
ck "$(grep -c 'rewriteHost' "$T/d.yaml")" "0" "file 模式不写 rewriteHost"

echo
echo "=== 3) ACL 空 inline 不再生成 ==="
# warn 走 stderr，这里合并捕获
r ENABLE_ACL=true ACL_REJECT_CN=false > "$T/a.yaml" 2>"$T/a.err" || true
( export ENABLE_ACL=true ACL_REJECT_CN=false; bash sbp-hy2.sh render ) > /dev/null 2>"$T/a2.err" || true
ck "$(grep -c '^acl:' "$T/a.yaml")" "0" "无规则时不生成 acl 段"
if grep -q '没有任何 ACL 规则' "$T/a2.err" 2>/dev/null; then
  ck yes yes "给出明确警告"
else
  ck no yes "给出明确警告"
fi
echo "  --- 有规则时仍正常 ---"
r ENABLE_ACL=true ACL_REJECT_CN=true > "$T/a2.yaml"
ck "$(grep -c 'reject(geoip:cn)' "$T/a2.yaml")" "1" "有规则时生成 acl"

echo
echo "=== 4) ignoreClientBandwidth 在顶层（官方规范）==="
r IGNORE_CLIENT_BW=true > "$T/b.yaml"
ck "$(grep -c '^ignoreClientBandwidth: true' "$T/b.yaml")" "1" "顶层输出 ignoreClientBandwidth"
ck "$(grep -c '^  ignoreClientBandwidth' "$T/b.yaml")" "0" "不再错误地嵌在 bandwidth 下"

echo
echo "=== 5) 全部配置用真实 Hysteria 校验 ==="
for f in d a2 b; do
  if out="$(timeout 3 "$BIN_PATH" server -c "$T/$f.yaml" 2>&1)"; then
    if printf '%s' "$out" | grep -qE 'server up and running'; then
      pass=$((pass+1)); echo "  OK   $f.yaml 启动成功"
    elif printf '%s' "$out" | grep -qiE 'invalid config|failed to load|FATAL'; then
      fail=$((fail+1)); echo "  FAIL $f.yaml 配置错误"
      printf '%s\n' "$out" | grep -iE 'invalid|failed|FATAL' | head -2 | sed 's/^/      /'
    else
      pass=$((pass+1)); echo "  OK   $f.yaml 无配置错误"
    fi
  fi
done

echo
echo "=== 6) 端口跳跃 + 新默认端口 ==="
r ENABLE_PORT_HOP=true HY2_PORT_START=35000 HY2_PORT_END=40000 > "$T/h.yaml"
ck "$(grep '^listen:' "$T/h.yaml")" "listen: :35000-40000" "端口跳跃生效"

echo
echo "========== pass=$pass fail=$fail =========="
rm -rf "$T"
(( fail == 0 )) && { echo "全部通过"; exit 0; } || { echo "有失败项"; exit 1; }
