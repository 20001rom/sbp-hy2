#!/usr/bin/env bash
# 验证 Xray 的 Hysteria2 是否支持 obfs（salamander / gecko）
set -uo pipefail
XRAY="/mnt/e/mDocument/mWorkSpace/dsh-remote-ws/sbp-lite/bin/xray-linux-64"
T=$(mktemp -d)
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout "$T/k.pem" -out "$T/c.pem" -days 90 -nodes -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost" >/dev/null 2>&1

mk(){ cat > "$T/c.json" <<EOJ
{"log":{"loglevel":"error"},
 "inbounds":[{"protocol":"hysteria","port":20010,
   "settings":{"version":2,"users":[{"auth":"pw"}]},
   "streamSettings":{"network":"hysteria","security":"tls",
     "tlsSettings":{"certificates":[{"certificateFile":"$T/c.pem","keyFile":"$T/k.pem"}],"alpn":["h3"]},
     "hysteriaSettings":$1}}],
 "outbounds":[{"protocol":"freedom"}]}
EOJ
}

try(){ # try <名称> <hysteriaSettings>
  mk "$2"
  echo -n "  $1: "
  if out="$("$XRAY" run -test -c "$T/c.json" 2>&1)"; then
    if printf '%s' "$out" | grep -q 'Configuration OK'; then echo "接受（但可能是静默忽略）"
    else echo "校验未确认"; fi
  else
    echo -n "拒绝 -> "
    printf '%s\n' "$out" | grep -oE 'unknown|Failed[^>]*|invalid[^>]*' | tail -1
  fi
}

echo "=== Xray Hysteria2 的 hysteriaSettings 字段探测 ==="
echo "（用塞错类型的方式判断字段是否真被识别：认识的字段会报 type error，不认识的会被静默忽略）"
echo

echo "--- 基线：只有 version ---"
try "version=2" '{"version":2}'

echo
echo "--- obfs（salamander 风格）---"
try "obfs.type=salamander" '{"version":2,"obfs":{"type":"salamander","password":"x"}}'
try "obfs=字符串" '{"version":2,"obfs":"salamander"}'

echo
echo "--- 已知合法字段：塞错类型看是否识别 ---"
try "udpIdleTimeout=字符串(应报type error)" '{"version":2,"udpIdleTimeout":"abc"}'
try "masquerade=字符串(应报type error)" '{"version":2,"masquerade":"abc"}'
try "version=字符串(应报type error)" '{"version":"abc"}'

echo
echo "--- obfs 塞错类型：若被识别应报 type error ---"
try "obfs=数字(若不报错=字段被忽略)" '{"version":2,"obfs":12345}'

echo
echo "=== 从二进制找 obfs 相关字符串 ==="
strings "$XRAY" 2>/dev/null | grep -iE 'salamander|gecko|obfs' | sort -u | head -10 | sed 's/^/  /'
echo "  （以上为空说明二进制里没有这些概念）"

rm -rf "$T"
