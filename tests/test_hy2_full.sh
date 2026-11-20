#!/usr/bin/env bash
# SBP-Hy2 测试：配置渲染 + 真实 Hysteria 校验
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCRIPT="$ROOT/sbp-hy2.sh"
HY="$ROOT/bin/hysteria-linux-amd64"
T=$(mktemp -d)
mkdir -p "$T/bin" "$T/hy"
cp -f "$HERE/bin/jq" "$T/bin/jq" 2>/dev/null || { echo "缺少 tests/bin/jq"; exit 1; }
export PATH="$T/bin:$PATH" SBP_BIN_DIR="$T/bin" BIN_PATH="$HY"
export HY_DIR="$T/hy" CONF_YAML="$T/hy/config.yaml" ACME_DIR="$T/hy/acme"
export ENV_FILE="$T/hy/env.conf"
export SBP_TEST_ROOT=1

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout "$T/hy/k.pem" -out "$T/hy/c.pem" -days 90 -nodes -subj "/CN=www.bing.com" \
  -addext "subjectAltName=DNS:www.bing.com" >/dev/null 2>&1
export TLS_CERT="$T/hy/c.pem" TLS_KEY="$T/hy/k.pem"

pass=0; fail=0
ck(){ if [[ "$1" == "$2" ]]; then printf '  OK   %s\n' "$3"; pass=$((pass+1));
      else printf '  FAIL %s\n        got =%s\n        want=%s\n' "$3" "$1" "$2"; fail=$((fail+1)); fi; }
render(){ ( export "$@"; bash "$SCRIPT" render ) 2>/dev/null; }

echo "=== 1) 语法与自检 ==="
bash -n "$SCRIPT" && ck yes yes "语法通过" || ck no yes "语法通过"
if bash "$SCRIPT" selftest > "$T/st.log" 2>&1; then
  ck yes yes "selftest 通过"
  grep -E '^(bash|架构|版本|urlenc|yaml|配置|gecko)' "$T/st.log" | sed 's/^/    /'
else
  ck no yes "selftest 通过"; sed -n '1,15p' "$T/st.log" | sed 's/^/    /'
fi

echo
echo "=== 2) 默认配置（gecko + acme + proxy masquerade）==="
render TLS_MODE=manual HY2_LISTEN=:18443 OBFS_TYPE=gecko MASQ_TYPE=proxy > "$T/c1.yaml"
echo "  --- 生成的 YAML ---"
sed 's/^/    /' "$T/c1.yaml"
echo "  --- 真实 Hysteria 校验 ---"
if out="$(timeout 3 "$HY" server -c "$T/c1.yaml" 2>&1 || true)"; then
  if printf '%s' "$out" | grep -qiE 'failed to load|invalid config|unknown field|FATAL'; then
    echo "    FAIL 配置错误"; printf '%s\n' "$out" | grep -iE 'failed|invalid|FATAL' | head -3 | sed 's/^/      /'
    fail=$((fail+1))
  else
    echo "    OK 无配置错误"; pass=$((pass+1))
  fi
fi

echo
echo "=== 3) 结构断言 ==="
ck "$(grep -c '^obfs:' "$T/c1.yaml")" "1" "obfs 段存在"
ck "$(grep -oE 'type: gecko' "$T/c1.yaml" | head -1)" "type: gecko" "混淆=gecko"
ck "$(grep -c 'minPacketSize' "$T/c1.yaml")" "1" "gecko minPacketSize"
ck "$(grep -c 'maxPacketSize' "$T/c1.yaml")" "1" "gecko maxPacketSize"
ck "$(grep -c '^masquerade:' "$T/c1.yaml")" "1" "masquerade 段存在"
ck "$(grep -c 'rewriteHost: true' "$T/c1.yaml")" "1" "proxy 模式 rewriteHost"
ck "$(grep -c '^auth:' "$T/c1.yaml")" "1" "auth 段存在"

echo
echo "=== 4) 三种混淆模式 ==="
for o in none salamander gecko; do
  render TLS_MODE=manual HY2_LISTEN=:18443 OBFS_TYPE=$o > "$T/o.yaml"
  ck "$(grep -c '^obfs:' "$T/o.yaml")" "$([[ "$o" == "none" ]] && echo 0 || echo 1)" "OBFS_TYPE=$o"
  if out="$(timeout 3 "$HY" server -c "$T/o.yaml" 2>&1 || true)"; then
    if printf '%s' "$out" | grep -qiE 'failed to load|invalid config|FATAL'; then
      fail=$((fail+1)); echo "      FAIL $o 配置错误"
    else pass=$((pass+1)); fi
  fi
done

echo
echo "=== 5) 三种 masquerade ==="
for m in proxy file string; do
  render TLS_MODE=manual HY2_LISTEN=:18443 MASQ_TYPE=$m > "$T/m.yaml"
  ck "$(grep -oE "type: $m" "$T/m.yaml" | head -1)" "type: $m" "MASQ_TYPE=$m"
  if out="$(timeout 3 "$HY" server -c "$T/m.yaml" 2>&1 || true)"; then
    if printf '%s' "$out" | grep -qiE 'failed to load|invalid config|FATAL'; then
      fail=$((fail+1)); echo "      FAIL $m"
    else pass=$((pass+1)); fi
  fi
done

echo
echo "=== 6) ACME 模式 ==="
render TLS_MODE=acme HY2_LISTEN=:18443 TLS_DOMAIN=test.example.com TLS_EMAIL=a@b.com > "$T/a.yaml"
ck "$(grep -c '^acme:' "$T/a.yaml")" "1" "acme 段存在"
ck "$(grep -c 'domains:' "$T/a.yaml")" "1" "domains 字段"
ck "$(grep -c 'sniGuard' "$T/a.yaml")" "0" "acme 模式不写 sniGuard（互斥）"

echo
echo "=== 7) 端口跳跃 ==="
render TLS_MODE=manual HY2_LISTEN=:18443 ENABLE_PORT_HOP=true HY2_PORT_START=20000 HY2_PORT_END=50000 > "$T/h.yaml"
ck "$(grep '^listen:' "$T/h.yaml")" "listen: :20000-50000" "listen 端口段"
echo "  （非 root 下 nft 会失败，属预期）"

echo
echo "=== 8) ACL + Brutal ==="
render TLS_MODE=manual HY2_LISTEN=:18443 ENABLE_ACL=true ACL_REJECT_CN=true BW_UP="100 mbps" BW_DOWN="100 mbps" > "$T/acl.yaml"
ck "$(grep -c '^acl:' "$T/acl.yaml")" "1" "acl 段"
ck "$(grep -c 'reject(geoip:cn)' "$T/acl.yaml")" "1" "reject geoip:cn"
ck "$(grep -c '^bandwidth:' "$T/acl.yaml")" "1" "bandwidth 段（Brutal）"
if out="$(timeout 3 "$HY" server -c "$T/acl.yaml" 2>&1 || true)"; then
  if printf '%s' "$out" | grep -qiE 'failed to load|invalid config|FATAL'; then
    echo "    FAIL ACL 配置错误"; printf '%s\n' "$out" | grep -iE 'failed|invalid|FATAL' | head -3 | sed 's/^/      /'
    fail=$((fail+1))
  else echo "    OK ACL 配置有效"; pass=$((pass+1)); fi
fi

echo
echo "=== 9) 双栈伪装（listenHTTP/HTTPS）==="
render TLS_MODE=manual HY2_LISTEN=:18443 ENABLE_LISTEN_HTTP=true ENABLE_LISTEN_HTTPS=true FORCE_HTTPS=true > "$T/d.yaml"
ck "$(grep -c 'listenHTTP: :80' "$T/d.yaml")" "1" "listenHTTP :80"
ck "$(grep -c 'listenHTTPS: :443' "$T/d.yaml")" "1" "listenHTTPS :443"
ck "$(grep -c 'forceHTTPS: true' "$T/d.yaml")" "1" "forceHTTPS"

echo
echo "========== pass=$pass fail=$fail =========="
rm -rf "$T"
(( fail == 0 )) && { echo "全部通过"; exit 0; } || { echo "有失败项"; exit 1; }
