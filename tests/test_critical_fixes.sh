#!/usr/bin/env bash
# 验证 audit 报的 3 个严重问题已修复
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
export HY2_LISTEN=":18443"
export SBP_TEST_ROOT=1
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout "$T/hy/k.pem" -out "$T/hy/c.pem" -days 90 -nodes -subj "/CN=test.local" \
  -addext "subjectAltName=DNS:test.local" >/dev/null 2>&1

pass=0; fail=0
ck(){ if [[ "$1" == "$2" ]]; then printf '  OK   %s\n' "$3"; pass=$((pass+1));
      else printf '  FAIL %s\n        got =%s\n        want=%s\n' "$3" "$1" "$2"; fail=$((fail+1)); fi; }

echo "=== 严重问题1：端口被占用时 check_config 不应误判失败 ==="
# 先占住 18443
"$BIN_PATH" server -c <(cat <<EOF
listen: :18443
tls:
  cert: "$T/hy/c.pem"
  key: "$T/hy/k.pem"
auth:
  type: password
  password: "occupy"
EOF
) > "$T/occupy.log" 2>&1 &
OPID=$!
sleep 2
if ss -Huln | grep -q ':18443'; then
  echo "  已占住 18443（模拟服务正在运行）"
  # 现在跑 check_config
  cat > "$T/test.yaml" <<EOF
listen: :18443
tls:
  cert: "$T/hy/c.pem"
  key: "$T/hy/k.pem"
auth:
  type: password
  password: "newpass"
EOF
  eval "$(sed -n '/^have()/,/^}/p' sbp-hy2.sh)"
  eval "$(sed -n '/^warn()/,/^}/p' sbp-hy2.sh)"
  eval "$(sed -n '/^check_config()/,/^}/p' sbp-hy2.sh)"
  set +e
  check_config "$T/test.yaml" 2>"$T/cc.err"; rc=$?
  set -e
  ck "$rc" "0" "端口占用时 check_config 返回 0（不误判）"
  grep -q '端口绑定失败' "$T/cc.err" && ck yes yes "提示了端口占用" || echo "  （无提示，也可接受）"
else
  echo "  未能占住 18443，跳过"
  kill $OPID 2>/dev/null
fi
kill $OPID 2>/dev/null; wait $OPID 2>/dev/null || true

echo
echo "=== 严重问题2：服务起不来时 deploy 应返回非 0 ==="
# 用一个必然失败的配置：端口越界
export HY2_LISTEN=":999999"
set +e
out="$(bash sbp-hy2.sh deploy 2>&1)"; rc=$?
set -e
echo "  deploy 退出码: $rc"
if (( rc != 0 )); then
  pass=$((pass+1)); echo "  OK   失败时返回非 0"
else
  fail=$((fail+1)); echo "  FAIL 失败仍返回 0"
fi
printf '%s' "$out" | grep -q '未成功启动\|配置生成失败' && ck yes yes "给出失败提示" || ck no yes "给出失败提示"
printf '%s' "$out" | grep -qE '^hysteria2://' && ck no yes "失败时不打印链接" || ck yes yes "失败时不打印链接"

echo
echo "=== 严重问题3：混淆与 masquerade 互斥应有警告 ==="
( export OBFS_TYPE=gecko MASQ_TYPE=file; bash sbp-hy2.sh render ) >/dev/null 2>"$T/w.err" || true
grep -q '会关闭 HTTP/3 伪装' "$T/w.err" && ck yes yes "给出互斥警告" || ck no yes "给出互斥警告"
grep -q 'OBFS_TYPE=none' "$T/w.err" && ck yes yes "给出替代方案提示" || ck no yes "给出替代方案提示"

echo
echo "=== 附加：默认 OBFS_TYPE 已改为 none ==="
export HY2_LISTEN=":18443"
( unset OBFS_TYPE; bash sbp-hy2.sh render ) > "$T/def.yaml" 2>/dev/null
ck "$(grep -c '^obfs:' "$T/def.yaml")" "0" "默认不生成 obfs 段（保留 H3 伪装）"
ck "$(grep '^listen:' "$T/def.yaml")" "listen: :18443" "listen 正确"

echo
echo "========== pass=$pass fail=$fail =========="
rm -rf "$T"
(( fail == 0 )) && { echo "全部通过"; exit 0; } || { echo "有失败项"; exit 1; }
