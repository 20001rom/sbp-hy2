#!/usr/bin/env bash
# 验证 Hysteria2 入站的完整配置（含 masquerade），确定可用字段
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
XRAY="$HERE/../bin/xray-linux-64"
T=$(mktemp -d)
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout "$T/k.pem" -out "$T/c.pem" -days 90 -nodes -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost" >/dev/null 2>&1

try(){ printf '%s' "$2" > "$T/c.json"; echo -n "  $1: "
  if "$XRAY" run -test -c "$T/c.json" >/dev/null 2>"$T/e"; then echo "OK"
  else echo "FAIL -> $(grep -oE 'Failed[^>]*|invalid[^>]*|unknown[^>]*' "$T/e" | tail -1)"; fi; }

echo "=== Hysteria2 入站配置变体 ==="

try "基础（version+users）" "{
 \"log\":{\"loglevel\":\"none\"},
 \"inbounds\":[{\"protocol\":\"hysteria\",\"port\":20001,
   \"settings\":{\"version\":2,\"users\":[{\"auth\":\"pw\"}]},
   \"streamSettings\":{\"network\":\"hysteria\",\"security\":\"tls\",
     \"tlsSettings\":{\"certificates\":[{\"certificateFile\":\"$T/c.pem\",\"keyFile\":\"$T/k.pem\"}],\"alpn\":[\"h3\"]},
     \"hysteriaSettings\":{\"version\":2}}}],
 \"outbounds\":[{\"protocol\":\"freedom\"}]}"

try "masquerade=string" "{
 \"log\":{\"loglevel\":\"none\"},
 \"inbounds\":[{\"protocol\":\"hysteria\",\"port\":20002,
   \"settings\":{\"version\":2,\"users\":[{\"auth\":\"pw\"}]},
   \"streamSettings\":{\"network\":\"hysteria\",\"security\":\"tls\",
     \"tlsSettings\":{\"certificates\":[{\"certificateFile\":\"$T/c.pem\",\"keyFile\":\"$T/k.pem\"}],\"alpn\":[\"h3\"]},
     \"hysteriaSettings\":{\"version\":2,
       \"masquerade\":{\"type\":\"string\",\"content\":\"<html>hi</html>\",\"statusCode\":200}}}}],
 \"outbounds\":[{\"protocol\":\"freedom\"}]}"

try "masquerade=proxy" "{
 \"log\":{\"loglevel\":\"none\"},
 \"inbounds\":[{\"protocol\":\"hysteria\",\"port\":20003,
   \"settings\":{\"version\":2,\"users\":[{\"auth\":\"pw\"}]},
   \"streamSettings\":{\"network\":\"hysteria\",\"security\":\"tls\",
     \"tlsSettings\":{\"certificates\":[{\"certificateFile\":\"$T/c.pem\",\"keyFile\":\"$T/k.pem\"}],\"alpn\":[\"h3\"]},
     \"hysteriaSettings\":{\"version\":2,
       \"masquerade\":{\"type\":\"proxy\",\"url\":\"https://www.bing.com\",\"rewriteHost\":true}}}}],
 \"outbounds\":[{\"protocol\":\"freedom\"}]}"

try "masquerade=file" "{
 \"log\":{\"loglevel\":\"none\"},
 \"inbounds\":[{\"protocol\":\"hysteria\",\"port\":20004,
   \"settings\":{\"version\":2,\"users\":[{\"auth\":\"pw\"}]},
   \"streamSettings\":{\"network\":\"hysteria\",\"security\":\"tls\",
     \"tlsSettings\":{\"certificates\":[{\"certificateFile\":\"$T/c.pem\",\"keyFile\":\"$T/k.pem\"}],\"alpn\":[\"h3\"]},
     \"hysteriaSettings\":{\"version\":2,
       \"masquerade\":{\"type\":\"file\",\"dir\":\"/tmp\"}}}}],
 \"outbounds\":[{\"protocol\":\"freedom\"}]}"

try "加 udpIdleTimeout" "{
 \"log\":{\"loglevel\":\"none\"},
 \"inbounds\":[{\"protocol\":\"hysteria\",\"port\":20005,
   \"settings\":{\"version\":2,\"users\":[{\"auth\":\"pw\"}]},
   \"streamSettings\":{\"network\":\"hysteria\",\"security\":\"tls\",
     \"tlsSettings\":{\"certificates\":[{\"certificateFile\":\"$T/c.pem\",\"keyFile\":\"$T/k.pem\"}],\"alpn\":[\"h3\"]},
     \"hysteriaSettings\":{\"version\":2,\"udpIdleTimeout\":60}}}],
 \"outbounds\":[{\"protocol\":\"freedom\"}]}"

echo
echo "=== 带 Vision flow 兼容性（Hysteria2 不支持 flow）==="
try "hysteria + flow（应失败）" "{
 \"log\":{\"loglevel\":\"none\"},
 \"inbounds\":[{\"protocol\":\"hysteria\",\"port\":20006,
   \"settings\":{\"version\":2,\"users\":[{\"auth\":\"pw\",\"flow\":\"xtls-rprx-vision\"}]},
   \"streamSettings\":{\"network\":\"hysteria\",\"security\":\"tls\",
     \"tlsSettings\":{\"certificates\":[{\"certificateFile\":\"$T/c.pem\",\"keyFile\":\"$T/k.pem\"}],\"alpn\":[\"h3\"]},
     \"hysteriaSettings\":{\"version\":2}}}],
 \"outbounds\":[{\"protocol\":\"freedom\"}]}"

echo
echo "=== 真实启动 + UDP 监听验证（masquerade=string）==="
cat > "$T/run.json" <<EOJ
{"log":{"loglevel":"warning"},
 "inbounds":[{"protocol":"hysteria","tag":"hy2","port":20010,
   "settings":{"version":2,"users":[{"auth":"testpass"}]},
   "streamSettings":{"network":"hysteria","security":"tls",
     "tlsSettings":{"certificates":[{"certificateFile":"$T/c.pem","keyFile":"$T/k.pem"}],"alpn":["h3"]},
     "hysteriaSettings":{"version":2,
       "masquerade":{"type":"string","content":"<!doctype html><html><body>SBP</body></html>","statusCode":200}}}}],
 "outbounds":[{"protocol":"freedom"}]}
EOJ
"$XRAY" run -c "$T/run.json" > "$T/run.log" 2>&1 &
P=$!
sleep 2
if kill -0 "$P" 2>/dev/null; then
  echo "  进程存活"
  ss -Huln | grep -E ':20010\b' | sed 's/^/    /'
  echo "  --- 探测：用 HTTP/3 请求它，看返回什么 ---"
  # Xray 自身不带 h3 客户端，这里只确认监听
  echo "    (无 h3 客户端，跳过内容验证)"
else
  echo "  进程退出"; head -5 "$T/run.log" | sed 's/^/    /'
fi
kill $P 2>/dev/null

rm -rf "$T"
