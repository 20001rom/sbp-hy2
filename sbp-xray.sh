#!/usr/bin/env bash
# ============================================================
#  SBP-Xray —— apt-free 版 Xray-core 部署脚本
#  与 SBP-Lite（sing-box）的区别：
#   · 核心换成 Xray-core
#   · 补上 sing-box 没有的能力：XHTTP 传输、FinalMask、TCP 分片
#   · Reality 走 443，其余协议高位端口
#  Version: v1.0.0
# ============================================================

set -Eeuo pipefail

# --- 关键：在给任何变量赋默认值之前，先记录"哪些键来自外部环境" ---
# 否则 ${VAR:-default} 会把外部值也变成"已设置"，导致 load_env 无法区分
# 用户显式指定的和脚本默认的，两种场景都会坏掉。
_SBP_ENV_KEYS=""
for _k in REALITY_SERVER REALITY_SERVER_PORT REALITY_PORT_MODE REALITY_LISTEN_PORT \
          UTLS_FP VERIFY_DEST_STRICT ENABLE_VLESS_REALITY ENABLE_VLESS_XHTTP \
          ENABLE_TROJAN ENABLE_VLESS_TLS ENABLE_HYSTERIA2 HY2_PWD HY2_UDP_IDLE \
          HY2_MASQUERADE_TYPE HY2_MASQUERADE_URL HY2_MASQUERADE_DIR \
          ENABLE_XHTTP XHTTP_MODE XHTTP_PATH XHTTP_PADDING XHTTP_SECURITY \
          ENABLE_FINALMASK FINALMASK_TYPE ENABLE_TCP_FRAGMENT \
          TLS_CERT_MODE TLS_DOMAIN UUID UUID2 TROJAN_PWD REALITY_PRIVATE \
          REALITY_PUBLIC REALITY_SID PORT_VLESSR PORT_VLESS_XHTTP PORT_TROJAN \
          PORT_VLESS_TLS PORT_HY2 \
          XRAY_BIN XRAY_PKG WORK_USER_NAME MY_WORKER_DEPLOY_2026; do
  [[ -n "${!_k+x}" ]] && _SBP_ENV_KEYS="$_SBP_ENV_KEYS $_k"
done
unset _k

SCRIPT_VERSION="v1.0.0"
SBP_HOME="${SBP_HOME:-/var/lib/sbp-lite}"
SBP_BIN_DIR="${SBP_BIN_DIR:-$SBP_HOME/bin}"
XR_DIR="${XR_DIR:-/usr/local/etc/xray}"
CONF_JSON="${CONF_JSON:-$XR_DIR/config.json}"
CERT_DIR="${CERT_DIR:-$XR_DIR/cert}"
BIN_PATH="${BIN_PATH:-/usr/local/bin/xray}"
SYSTEMD_SERVICE="${SYSTEMD_SERVICE:-xray.service}"
SYSTEMD_UNIT_DIR="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
ENV_FILE="${ENV_FILE:-$XR_DIR/env.conf}"
PORTS_FILE="${PORTS_FILE:-$XR_DIR/ports.env}"
SHARE_LINKS_FILE="${SHARE_LINKS_FILE:-$XR_DIR/share-links.txt}"

XRAY_REPO="${XRAY_REPO:-XTLS/Xray-core}"
XRAY_TAG="${XRAY_TAG:-latest}"

# 二进制来源：repo（默认，从本仓库下载已解压的二进制）/ release（官方 zip）
XRAY_SOURCE="${XRAY_SOURCE:-repo}"
SBP_REPO="${SBP_REPO:-20001rom/sbp-hy2}"
SBP_BRANCH="${SBP_BRANCH:-main}"
SBP_RAW_BASE="${SBP_RAW_BASE:-https://raw.githubusercontent.com/${SBP_REPO}/${SBP_BRANCH}}"

LISTEN_PORT_MIN="${LISTEN_PORT_MIN:-10000}"
LISTEN_PORT_MAX="${LISTEN_PORT_MAX:-19999}"

# Reality 端口策略：auto=443（伪装前提），random=高位，fixed=指定
REALITY_PORT_MODE="${REALITY_PORT_MODE:-auto}"
REALITY_LISTEN_PORT="${REALITY_LISTEN_PORT:-443}"
REALITY_SERVER="${REALITY_SERVER:-www.bing.com}"
REALITY_SERVER_PORT="${REALITY_SERVER_PORT:-443}"

# XHTTP（sing-box 没有的传输层）
#   auto：Reality 下自动 stream-one，否则 packet-up
#   packet-up：兼容性最强，适合套 CDN
ENABLE_XHTTP="${ENABLE_XHTTP:-false}"
XHTTP_MODE="${XHTTP_MODE:-auto}"
XHTTP_PATH="${XHTTP_PATH:-}"
XHTTP_PADDING="${XHTTP_PADDING:-100-1000}"
# XHTTP 的安全层：reality（默认，与 Reality 共用伪装目标）/ tls（套 CDN 用）/ none（明文，仅调试）
XHTTP_SECURITY="${XHTTP_SECURITY:-reality}"

# FinalMask / 分片（sing-box 没有）
ENABLE_FINALMASK="${ENABLE_FINALMASK:-false}"
FINALMASK_TYPE="${FINALMASK_TYPE:-header-custom}"
ENABLE_TCP_FRAGMENT="${ENABLE_TCP_FRAGMENT:-false}"

UTLS_FP="${UTLS_FP:-firefox}"

# Reality dest 校验（防主动探测的核心，部署前强制执行）
VERIFY_DEST_STRICT="${VERIFY_DEST_STRICT:-1}"

# Hysteria2（Xray 26.x 支持，需 TLS 证书）
ENABLE_HYSTERIA2="${ENABLE_HYSTERIA2:-false}"
HY2_PWD="${HY2_PWD:-}"
HY2_UDP_IDLE="${HY2_UDP_IDLE:-60}"
# masquerade：未认证的 HTTP/3 请求返回什么
#   string -> 返回固定 HTML（最简单，防探测够用）
#   proxy  -> 反向代理到真实站点（最像真站）
#   file   -> 从本地目录提供静态文件
HY2_MASQUERADE_TYPE="${HY2_MASQUERADE_TYPE:-string}"
HY2_MASQUERADE_CONTENT="${HY2_MASQUERADE_CONTENT:-}"
HY2_MASQUERADE_URL="${HY2_MASQUERADE_URL:-https://www.bing.com}"
HY2_MASQUERADE_DIR="${HY2_MASQUERADE_DIR:-$CERT_DIR/www}"

mkdir -p "$SBP_BIN_DIR" 2>/dev/null || true
export PATH="$SBP_BIN_DIR:$PATH"

C_RESET="\033[0m"; C_RED="\033[31m"; C_GREEN="\033[32m"
C_YELLOW="\033[33m"; C_CYAN="\033[36m"; C_BOLD="\033[1m"
info(){ printf "[${C_CYAN}信息${C_RESET}] %s\n" "$*"; }
warn(){ printf "[${C_YELLOW}警告${C_RESET}] %s\n" "$*" >&2; }
die(){  printf "[${C_RED}错误${C_RESET}] %s\n" "$*" >&2; exit 1; }
ok(){   printf "[${C_GREEN}完成${C_RESET}] %s\n" "$*"; }

have(){ command -v "$1" >/dev/null 2>&1; }

# ===== 下载 =====
_fetch(){
  local url="$1" out="$2"
  if have curl; then
    curl -fsSL --retry 2 --connect-timeout 8 -m 300 -o "$out" "$url"
  elif have wget; then
    wget -qO "$out" --tries=2 --timeout=25 "$url"
  elif have busybox; then
    busybox wget -q -O "$out" "$url"
  else
    cat >&2 <<'NODL'

────────────────────────────────────────────────────────────
  系统没有 curl / wget / busybox，无法下载。
  请在能联网的机器上下载后上传：
     1. 静态 jq     -> /var/lib/sbp-lite/bin/jq
     2. Xray 包     -> 设置 XRAY_PKG=/path/to/Xray-linux-64.zip
  或安装下载器：apt-get install -y curl / apk add curl
────────────────────────────────────────────────────────────

NODL
    return 1
  fi
}
dl(){ local url="$1" out="$2"; shift 2; local u; for u in "$url" "$@"; do
  [[ -n "$u" ]] || continue
  _fetch "$u" "$out" 2>/dev/null && [[ -s "$out" ]] && return 0
  rm -f -- "$out" 2>/dev/null || true
done; return 1; }

dl_gh(){
  local url="$1" out="$2" m=() line
  if [[ "$url" == https://github.com/* || "$url" == https://raw.githubusercontent.com/* ]]; then
    m=("https://ghfast.top/$url" "https://gh-proxy.com/$url")
  fi
  dl "$url" "$out" "${m[@]}"
}

# ===== 架构（Xray 命名与 sing-box 不同）=====
xray_arch(){
  case "$(uname -m)" in
    x86_64|amd64)   echo "64" ;;
    aarch64|arm64)  echo "arm64-v8a" ;;
    armv7l|armv7)   echo "arm32-v7a" ;;
    armv6l)         echo "arm32-v6" ;;
    armv5*)         echo "arm32-v5" ;;
    i386|i686)      echo "32" ;;
    *)              echo "64" ;;
  esac
}
jq_arch(){
  case "$(uname -m)" in
    x86_64|amd64)   echo amd64 ;;
    aarch64|arm64)  echo arm64 ;;
    armv7l|armv7)   echo armhf ;;
    i386|i686)      echo i386 ;;
    *)              echo amd64 ;;
  esac
}

# ===== 静态工具 =====
ensure_jq(){
  have jq && return 0
  local arch out="$SBP_BIN_DIR/jq" url
  arch="$(jq_arch)"
  url="https://github.com/jqlang/jq/releases/latest/download/jq-linux-${arch}"
  info "下载静态 jq (${arch}) ..." >&2
  if dl_gh "$url" "$out" && chmod +x "$out" && "$out" --version >/dev/null 2>&1; then
    ok "jq 就绪：$("$out" --version)" >&2
    return 0
  fi
  warn "jq 获取失败" >&2
  cat >&2 <<GUIDE

────────────────────────────────────────────────────────────
  无法自动获取 jq，请手动上传：
       https://github.com/jqlang/jq/releases/latest/download/jq-linux-${arch}
       scp jq-linux-${arch} root@<服务器IP>:/tmp/jq
       ssh root@<服务器IP> 'install -m755 /tmp/jq ${out}'
  或：apt-get install -y jq / apk add jq / dnf install -y jq
────────────────────────────────────────────────────────────

GUIDE
  return 1
}

# Xray 发布包是 zip：极简系统往往没有 unzip，用多种方式兜底
#
# 为什么必须自带解压：实测 Debian 极简镜像同时缺 unzip / busybox / python3，
# 只有 perl。而 Xray 只发布 zip，没有 tar.gz —— 不内置解法就直接装不上。
extract_zip(){
  local zip="$1" dest="$2"
  if have unzip; then
    unzip -oq "$zip" -d "$dest"; return $?
  fi
  if have busybox; then
    busybox unzip -o "$zip" -d "$dest"; return $?
  fi
  if have python3; then
    python3 - "$zip" "$dest" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    z.extractall(sys.argv[2])
PY
    return $?
  fi
  # 纯 bash 实现：解析 zip 的 central directory，只提取需要的文件。
  # Xray 的包内文件用 stored 或 deflate，deflate 交给 perl 的 Compress::Raw::Zlib。
  if have perl; then
    _unzip_perl "$zip" "$dest"; return $?
  fi
  return 1
}

# 纯 perl 解压（不依赖 unzip 模块，用 Compress::Raw::Zlib）
_unzip_perl(){
  local zip="$1" dest="$2"
  perl -e '
    use strict; use warnings;
    my ($zip, $dest) = @ARGV;
    open(my $fh, "<:raw", $zip) or die "open: $!";
    # 找 EOCD (0x06054b50)，从尾部向前最多找 64KB
    seek($fh, 0, 2); my $size = tell($fh);
    my $tail = $size > 66000 ? 66000 : $size;
    seek($fh, $size - $tail, 0); read($fh, my $buf, $tail);
    my $eocd = rindex($buf, "PK\x05\x06");
    die "EOCD not found\n" if $eocd < 0;
    my $cd_off = unpack("V", substr($buf, $eocd + 16, 4));
    my $cd_cnt = unpack("v", substr($buf, $eocd + 10, 2));
    seek($fh, $cd_off, 0);
    my $have_zlib = eval { require Compress::Raw::Zlib; 1 };
    for (my $i = 0; $i < $cd_cnt; $i++) {
      read($fh, my $h, 46) == 46 or last;
      my ($sig, $made, $need, $flags, $method) = unpack("Vvvvv", substr($h,0,14));
      last if $sig != 0x02014b50;
      my ($crc, $csize, $usize) = unpack("VVV", substr($h,16,12));
      my ($nlen, $elen, $clen) = unpack("vvv", substr($h,28,6));
      my $lho = unpack("V", substr($h,42,4));
      read($fh, my $name, $nlen); read($fh, my $extra, $elen); read($fh, my $cmt, $clen);
      next if $name =~ m{/$};               # 跳过目录
      # 只提取扁平文件名，防路径穿越
      (my $safe = $name) =~ s{.*/}{};
      next unless $safe =~ /^(xray|geoip\.dat|geosite\.dat|LICENSE|README\.md)$/;
      my $save = tell($fh);
      seek($fh, $lho, 0);
      read($fh, my $lh, 30) == 30 or do { seek($fh,$save,0); next; };
      my $lsig = unpack("V", substr($lh,0,4));
      if ($lsig == 0x04034b50) {
        my ($lnl, $lel) = unpack("vv", substr($lh,26,4));
        seek($fh, $lnl + $lel, 1);
        read($fh, my $data, $csize);
        my $out = $data;
        if ($method == 8) {
          if ($have_zlib) {
            my ($inf, $st) = Compress::Raw::Zlib::Inflate->new(-WindowBits => -MAX_WBITS());
            if ($st == Compress::Raw::Zlib::Z_OK()) {
              my $o = "";
              $inf->inflate($data, $o);
              $out = $o;
            }
          }
        }
        open(my $of, ">:raw", "$dest/$safe") or do { seek($fh,$save,0); next; };
        print $of $out; close $of;
      }
      seek($fh, $save, 0);
    }
    close($fh);
  ' "$zip" "$dest"
}

ensure_unzip(){
  have unzip && return 0
  have busybox && { info "使用 busybox 解压" >&2; return 0; }
  warn "缺少 unzip（Xray 官方包是 zip 格式）"
  cat >&2 <<'GUIDE'

────────────────────────────────────────────────────────────
  Xray 官方发布包是 .zip，需要 unzip 才能解。
  三种办法任选：
   1) 安装：apt-get install -y unzip / apk add unzip
   2) 已有 busybox（多数系统自带）：脚本会自动用它
   3) 手动解压后放好二进制：
        unzip Xray-linux-64.zip -d /tmp/xray
        install -m755 /tmp/xray/xray /usr/local/bin/xray
      然后设 XRAY_PKG="" 重跑，脚本检测到已安装就不再解压
────────────────────────────────────────────────────────────

GUIDE
  return 1
}

sha256_of(){
  if have sha256sum; then sha256sum "$1" | awk '{print $1}'
  elif have openssl; then openssl dgst -sha256 "$1" | sed 's/.*= *//'
  elif have busybox; then busybox sha256sum "$1" | awk '{print $1}'
  else return 1; fi
}

# ===== 版本 =====
version_lt(){
  local a="${1#v}" b="${2#v}"
  [[ "$a" == "$b" ]] && return 1
  local a_pre="" b_pre=""
  [[ "$a" == *-* ]] && { a_pre="${a#*-}"; a="${a%%-*}"; }
  [[ "$b" == *-* ]] && { b_pre="${b#*-}"; b="${b%%-*}"; }
  local IFS='.' i x y
  local -a A=($a) B=($b)
  local n=${#A[@]}; (( ${#B[@]} > n )) && n=${#B[@]}
  for ((i=0; i<n; i++)); do
    x="${A[i]:-0}"; y="${B[i]:-0}"
    x="${x%%[!0-9]*}"; y="${y%%[!0-9]*}"
    x="${x:-0}"; y="${y:-0}"
    (( 10#$x < 10#$y )) && return 0
    (( 10#$x > 10#$y )) && return 1
  done
  [[ -n "$a_pre" && -z "$b_pre" ]] && return 0
  return 1
}

xray_version(){
  local v
  v="$("$BIN_PATH" version 2>/dev/null | awk '/^Xray /{print $2; exit}')" || return 1
  [[ -n "$v" ]] || return 1
  printf '%s' "$v"
}

# ===== 随机与凭证 =====
rand_port(){
  local p tries=0
  while (( tries < 200 )); do
    p=$(( (RANDOM % (LISTEN_PORT_MAX - LISTEN_PORT_MIN + 1)) + LISTEN_PORT_MIN ))
    tries=$((tries+1))
    [[ " ${USED_PORTS[*]-} " == *" $p "* ]] && continue
    USED_PORTS+=("$p"); RP="$p"; return 0
  done
  return 1
}
reality_port(){
  case "${REALITY_PORT_MODE:-auto}" in
    auto)  USED_PORTS+=("443"); RP=443; return 0 ;;
    fixed) RP="${REALITY_LISTEN_PORT:-443}"; USED_PORTS+=("$RP"); return 0 ;;
    *)     rand_port ;;
  esac
}
rand_hex(){ openssl rand -hex "${1:-8}"; }
rand_b64(){ openssl rand -base64 "${1:-32}" | tr -d '\n'; }
gen_uuid(){ "$BIN_PATH" uuid; }

# Xray 的 x25519 输出是 "PrivateKey: xxx" 与 "Password (PublicKey): xxx"
gen_reality_keys(){
  local kp
  kp="$("$BIN_PATH" x25519 2>/dev/null)" || return 1
  REALITY_PRIVATE="$(printf '%s\n' "$kp" | grep -i 'PrivateKey' | head -1 | sed 's/.*[:：][[:space:]]*//')"
  REALITY_PUBLIC="$(printf '%s\n' "$kp" | grep -i 'PublicKey' | head -1 | sed 's/.*[:：][[:space:]]*//')"
  [[ -n "$REALITY_PRIVATE" && -n "$REALITY_PUBLIC" ]]
}

# ===== 环境文件 =====
# 两个需求要同时满足：
#   1. 用户 `VERIFY_DEST_STRICT=0 bash ... deploy` 必须生效（不能被旧 env.conf 压回去）
#   2. `links` / `status` 读配置时，env.conf 的值要覆盖脚本的默认值
#
# 做法：脚本开机时先把"来自环境变量"的键记下来（_SBP_ENV_KEYS），
# load_env 只跳过这些键，其余一律采用文件值。

load_env(){
  [[ -f "$ENV_FILE" ]] || return 1
  local line key val
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    key="${line%%=*}"; val="${line#*=}"
    [[ -n "$key" ]] || continue
    # 用户从环境变量显式传入的键，不让文件覆盖
    if [[ " $_SBP_ENV_KEYS " == *" $key "* ]]; then
      continue
    fi
    export "$key=$val"
  done < "$ENV_FILE"
  return 0
}
save_env(){
  mkdir -p "$(dirname "$ENV_FILE")"
  local tmpf
  tmpf="$(mktemp "${ENV_FILE}.tmp.XXXXXX")" || return 1
  cat > "$tmpf" <<EOF
# SBP-Xray 配置（请勿泄露）
REALITY_SERVER=${REALITY_SERVER}
REALITY_SERVER_PORT=${REALITY_SERVER_PORT}
REALITY_PORT_MODE=${REALITY_PORT_MODE}
REALITY_LISTEN_PORT=${REALITY_LISTEN_PORT}
UTLS_FP=${UTLS_FP}
UUID=${UUID}
UUID2=${UUID2}
TROJAN_PWD=${TROJAN_PWD}
REALITY_PRIVATE=${REALITY_PRIVATE}
REALITY_PUBLIC=${REALITY_PUBLIC}
REALITY_SID=${REALITY_SID}
XHTTP_PATH=${XHTTP_PATH}
ENABLE_XHTTP=${ENABLE_XHTTP}
XHTTP_MODE=${XHTTP_MODE}
XHTTP_PADDING=${XHTTP_PADDING}
# 少存这两项会导致 rotate/status 在新进程里回落到默认值，
# 把 deploy 时配置的 tls 安全层静默改回 reality —— 已上线的客户端会全部失联。
XHTTP_SECURITY=${XHTTP_SECURITY}
HY2_MASQUERADE_CONTENT=${HY2_MASQUERADE_CONTENT}
ENABLE_FINALMASK=${ENABLE_FINALMASK}
FINALMASK_TYPE=${FINALMASK_TYPE}
ENABLE_TCP_FRAGMENT=${ENABLE_TCP_FRAGMENT}
ENABLE_VLESS_REALITY=${ENABLE_VLESS_REALITY}
ENABLE_VLESS_XHTTP=${ENABLE_VLESS_XHTTP}
ENABLE_TROJAN=${ENABLE_TROJAN}
ENABLE_VLESS_TLS=${ENABLE_VLESS_TLS}
ENABLE_HYSTERIA2=${ENABLE_HYSTERIA2}
HY2_PWD=${HY2_PWD}
HY2_UDP_IDLE=${HY2_UDP_IDLE}
HY2_MASQUERADE_TYPE=${HY2_MASQUERADE_TYPE}
HY2_MASQUERADE_URL=${HY2_MASQUERADE_URL}
HY2_MASQUERADE_DIR=${HY2_MASQUERADE_DIR}
VERIFY_DEST_STRICT=${VERIFY_DEST_STRICT}
TLS_CERT_MODE=${TLS_CERT_MODE}
TLS_DOMAIN=${TLS_DOMAIN}
EOF
  chmod 600 "$tmpf" || { rm -f "$tmpf"; return 1; }
  mv -f "$tmpf" "$ENV_FILE"
}
load_ports(){ [[ -f "$PORTS_FILE" ]] || return 1; set -a; . "$PORTS_FILE"; set +a; }
save_ports(){
  mkdir -p "$(dirname "$PORTS_FILE")"
  local tmpf v
  tmpf="$(mktemp "${PORTS_FILE}.tmp.XXXXXX")" || return 1
  : > "$tmpf"
  for v in PORT_VLESSR PORT_VLESS_XHTTP PORT_TROJAN PORT_VLESS_TLS PORT_HY2; do
    printf '%s=%s\n' "$v" "${!v:-}" >> "$tmpf"
  done
  chmod 600 "$tmpf" || { rm -f "$tmpf"; return 1; }
  mv -f "$tmpf" "$PORTS_FILE"
}

# ===== Reality dest 校验（防主动探测的核心）=====
# 为什么必须校验：Reality 在认证失败时会把整条连接转发给 dest，
# 探测者看到的就是 dest 的证书。如果 dest 用自签证书，探测者立刻
# 看到 subject==issuer —— 等于自己把证据递过去。
# 另外 dest 不通 / 太慢 / 不支持必要的 TLS 特性，Reality 也工作不了。
verify_dest(){
  local host="${1:-$REALITY_SERVER}" port="${2:-$REALITY_SERVER_PORT}"
  local strict="${VERIFY_DEST_STRICT:-1}"
  local ok_all=1

  # 主机名可能自带端口或已是 IPv6 字面量，先规整
  if [[ "$host" == *:* ]]; then
    if [[ "$host" =~ ^\[.*\]$ ]]; then
      host="${host#[}"; host="${host%]}"
    elif [[ "$host" != *::* ]]; then
      # a.b.c:443 这种，末尾是端口
      port="${host##*:}"; host="${host%:*}"
    fi
  fi
  # IPv6 拼接要加方括号
  local hp="$host"
  [[ "$host" == *:* ]] && hp="[${host}]"

  echo "  校验 Reality 伪装目标：${host}:${port}"

  # 1) 可达性 + TLS 握手
  if ! have openssl; then
    warn "缺少 openssl，跳过 dest 校验（无法验证证书质量）"
    return 0
  fi

  local out
  # 必须显式 -alpn h2，否则服务端不会协商到 h2（openssl 默认不发 ALPN 扩展）
  out="$(timeout 15 openssl s_client -connect "${hp}:${port}" \
         -servername "$host" -tls1_3 -alpn h2 -showcerts </dev/null 2>&1)" || true

  if ! printf '%s' "$out" | grep -q 'BEGIN CERTIFICATE'; then
    warn "✗ dest 不可达或未返回证书（${host}:${port}）"
    echo "    服务器必须能访问 dest，否则 Reality 握手会失败" >&2
    # 不可达是硬伤：Reality 认证失败时会转发到 dest，dest 不通则握手直接失败。
    # 但用户显式设 VERIFY_DEST_STRICT=0 表示"我知道，先跑起来"，要尊重。
    if [[ "$strict" == "0" ]]; then
      warn "VERIFY_DEST_STRICT=0，跳过此错误继续（Reality 很可能不可用）"
      return 0
    fi
    return 1
  fi
  echo "    ✓ 可达且返回证书"

  # 2) 协议版本 TLS 1.3
  if printf '%s' "$out" | grep -qE 'Protocol *: *TLSv1\.3'; then
    echo "    ✓ 支持 TLS 1.3"
  else
    warn "✗ dest 未协商 TLS 1.3（Reality 需要）"
    ok_all=0
  fi

  # 3) ALPN h2
  if printf '%s' "$out" | grep -qiE 'ALPN protocol: h2'; then
    echo "    ✓ ALPN h2"
  else
    warn "✗ dest 未协商 ALPN h2（Reality 需要）"
    ok_all=0
  fi

  # 4) X25519 密钥交换
  # 新版 openssl（3.5+）在 TLS1.3 下不再输出 "Server/Peer Temp Key"，
  # 改打 "Negotiated TLS1.3 group: X25519MLKEM768"，两个模式都要认。
  if printf '%s' "$out" | grep -qiE '(Server|Peer) Temp Key: *X25519|Negotiated TLS1[._]?[0-9]* group: *X25519'; then
    echo "    ✓ X25519（或 X25519MLKEM768）"
  else
    warn "✗ dest 未使用 X25519（Reality 需要）"
    printf '%s\n' "$out" | grep -iE 'Temp Key|Negotiated.*group' | head -2 | sed 's/^/      /' >&2
    ok_all=0
  fi

  # 5) 证书：必须公共 CA 签发（subject != issuer）
  local cert subj issu chain
  cert="$(printf '%s\n' "$out" | sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p')"
  subj="$(printf '%s\n' "$cert" | openssl x509 -noout -subject 2>/dev/null | sed 's/subject=//')"
  issu="$(printf '%s\n' "$cert" | openssl x509 -noout -issuer 2>/dev/null | sed 's/issuer=//')"
  chain="$(printf '%s\n' "$out" | grep -c 'BEGIN CERTIFICATE' || true)"

  if [[ -n "$subj" && -n "$issu" ]]; then
    if [[ "$subj" == "$issu" ]]; then
      warn "✗ dest 使用自签证书（subject == issuer）"
      echo "    Reality 会原样转发它，探测者一眼识别。换个真站！" >&2
      echo "    subject: $subj" >&2
      ok_all=0
    else
      echo "    ✓ 证书由公共 CA 签发"
      echo "      subject: $subj"
      echo "      issuer : $issu"
    fi
  fi

  if (( chain >= 2 )); then
    echo "    ✓ 证书链完整（${chain} 条）"
  else
    warn "⚠ 证书链只有 ${chain} 条，真实站点通常 2-3 条"
  fi

  # 6) 延迟（Reality 要实时转发握手，太慢会露馅）
  # 只用 date +%s%N 差值，避免 /usr/bin/time 输出小数与整数正则不匹配的问题。
  local t_ms="" t0 t1
  t0="$(date +%s%N 2>/dev/null || true)"
  if [[ -n "$t0" ]]; then
    timeout 10 bash -c "exec 3<>/dev/tcp/${hp}/${port}" 2>/dev/null || true
    t1="$(date +%s%N 2>/dev/null || true)"
    if [[ -n "$t1" ]] && (( t1 > t0 )); then
      t_ms=$(( (t1 - t0) / 1000000 ))
    fi
  fi

  if [[ -n "$t_ms" ]]; then
    if (( t_ms < 100 )); then
      echo "    ✓ 握手延迟 ${t_ms}ms"
    else
      warn "⚠ 握手延迟 ${t_ms}ms（>100ms，SNI 与服务器距离可能太远）"
    fi
  fi

  # 7) 已知被烧掉的 SNI
  case "$host" in
    www.apple.com|apple.com|www.microsoft.com|microsoft.com|www.lovelive-anime.jp|lovelive-anime.jp)
      warn "✗ ${host} 是广泛使用的默认值（'烧掉的 SNI'），已被列入启发式规则"
      echo "    请换成一个不常见的、离你服务器近的大站" >&2
      ok_all=0 ;;
  esac

  echo
  if (( ok_all == 0 )); then
    if [[ "$strict" == "1" ]]; then
      warn "dest 校验未通过。设 VERIFY_DEST_STRICT=0 可强行继续（不推荐）"
      return 1
    fi
    warn "dest 校验有警告，继续部署（VERIFY_DEST_STRICT=0）"
  else
    ok "dest 校验通过"
  fi
  return 0
}

# ===== 证书 =====
# 证书用途分三种，不能混：
#   self_signed —— Reality 用不上证书（Reality 借用目标站的），只有 trojan/vless-tls 需要
#   manual      —— 用户自己放好证书（Let's Encrypt 等）
#   acme        —— 不在本脚本范围，用 certbot 之类工具申请后走 manual
ensure_cert(){
  mkdir -p "$CERT_DIR"; chmod 700 "$CERT_DIR" 2>/dev/null || true
  local crt="$CERT_DIR/fullchain.pem" key="$CERT_DIR/key.pem"
  local mode="${TLS_CERT_MODE:-self_signed}"

  # manual：用户提供的证书，只校验存在性
  if [[ "$mode" == "manual" ]]; then
    if [[ -s "$crt" && -s "$key" ]]; then
      ok "使用手动证书：$crt"
      return 0
    fi
    warn "TLS_CERT_MODE=manual 但 $crt 或 $key 不存在"
    return 1
  fi

  [[ "$mode" == "self_signed" ]] || { warn "未知 TLS_CERT_MODE=${mode}，按 self_signed 处理"; }

  # 自签证书的 CN 用哪个域名？
  #   - 有 TLS_DOMAIN（用户有域名）→ 用域名，这样 CDN 回源能过
  #   - 否则用 REALITY_SERVER（仅能靠 allowInsecure 连接，无法套 CDN）
  local cn="${TLS_DOMAIN:-$REALITY_SERVER}"

  if [[ -f "$crt" && -f "$key" ]]; then
    local cur
    cur="$(openssl x509 -in "$crt" -noout -subject 2>/dev/null | sed -n 's/.*CN *= *\([^,]*\).*/\1/p')"
    [[ "$cur" == "$cn" ]] && { ok "证书已存在且 CN=${cn}"; return 0; }
    warn "证书 CN(${cur:-空}) 与期望(${cn}) 不一致，重签"
  fi

  have openssl || { warn "缺少 openssl，跳过证书（只有 Reality 协议可用）"; return 0; }
  info "签发自签证书，CN=${cn}"
  # CA:FALSE + 90 天 + 完整扩展：自签证书默认 CA:TRUE 且 3650 天，被动比对即可识别
  local ext=(
    -addext "subjectAltName=DNS:${cn}"
    -addext "basicConstraints=critical,CA:FALSE"
    -addext "keyUsage=critical,digitalSignature"
    -addext "extendedKeyUsage=serverAuth"
  )
  if ! openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
       -keyout "$key" -out "$crt" -days 90 -nodes \
       -subj "/CN=${cn}" "${ext[@]}" >/dev/null 2>&1; then
    warn "带扩展签发失败，回退最简形式"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -keyout "$key" -out "$crt" -days 90 -nodes \
      -subj "/CN=${cn}" >/dev/null 2>&1 || { warn "证书生成失败"; return 1; }
  fi
  chmod 600 "$key"; chmod 644 "$crt"
  ok "证书就绪：$crt（CN=${cn}）"

  # 自签 + 想套 CDN = 死路，必须明确告知
  if [[ "$mode" == "self_signed" && "${XHTTP_SECURITY:-reality}" == "tls" && -z "${TLS_DOMAIN:-}" ]]; then
    warn "XHTTP 走 TLS 但用的是自签证书 + 无域名：CDN 回源会因证书不受信而失败。"
    warn "  要套 CDN，请设置 TLS_DOMAIN=你的域名，并用真实证书（TLS_CERT_MODE=manual）。"
  fi
}

# ===== 安装 Xray =====
extract_install(){
  local pkg="$1" rc=0 extracted found
  extracted="$(mktemp -d)"
  if ! extract_zip "$pkg" "$extracted"; then
    warn "解压失败（缺少 unzip / busybox）"; rc=1
  fi
  if (( rc == 0 )); then
    found="$(find "$extracted" -maxdepth 2 -type f -name 'xray' 2>/dev/null | head -1)"
    if [[ -z "$found" ]]; then
      warn "包内未找到 xray 可执行文件"; rc=1
    elif ! chmod +x "$found"; then
      warn "无法加执行权限"; rc=1
    elif ! "$found" version >/dev/null 2>&1; then
      warn "二进制无法执行（架构不匹配或损坏）"; rc=1
    else
      mkdir -p "$(dirname "$BIN_PATH")"
      [[ -f "$BIN_PATH" ]] && { cp -f "$BIN_PATH" "${BIN_PATH}.bak" 2>/dev/null || true; }
      if install -m 0755 "$found" "$BIN_PATH"; then
        ok "Xray v$(xray_version) 已安装到 ${BIN_PATH}"
      else
        warn "写入 ${BIN_PATH} 失败"; rc=1
      fi
      # geo 数据文件（路由用，可选）
      local g
      for g in geoip.dat geosite.dat; do
        [[ -f "$extracted/$g" ]] && install -m 0644 "$extracted/$g" "$(dirname "$BIN_PATH")/$g" 2>/dev/null || true
      done
    fi
  fi
  rm -rf -- "$extracted" 2>/dev/null || true
  return "$rc"
}

install_xray(){
  local _tmp arch rel_url meta name url digest tag ver
  _tmp="$(mktemp -d)"
  install_xray_inner "$_tmp"
  local _rc=$?
  rm -rf -- "$_tmp" 2>/dev/null || true
  return "$_rc"
}

# 统一安装流程：校验 → 备份 → 写入 → 自检
_install_binary(){
  local src="$1"
  [[ -f "$src" ]] || { warn "文件不存在：$src"; return 1; }
  chmod +x "$src" 2>/dev/null || true
  if ! "$src" version >/dev/null 2>&1; then
    warn "二进制无法执行（架构不匹配或文件损坏）：$src"
    return 1
  fi
  mkdir -p "$(dirname "$BIN_PATH")"
  [[ -f "$BIN_PATH" ]] && { cp -f "$BIN_PATH" "${BIN_PATH}.bak" 2>/dev/null || true; }
  install -m 0755 "$src" "$BIN_PATH" || { warn "写入 ${BIN_PATH} 失败"; return 1; }
  ok "Xray v$(xray_version) 已安装到 ${BIN_PATH}"
}

# 从本仓库下载已解压的二进制（核心设计：服务器端不需要任何解压工具）
# 仓库结构：bin/xray（33 MB，已解压）、bin/xray.sha256、bin/VERSION
install_from_repo(){
  local arch want_arch raw sha_url ver_url
  arch="$(xray_arch)"

  # 仓库里的二进制只覆盖常见架构，其余架构回退官方 Release
  case "$arch" in
    64|arm64-v8a) ;;
    *) info "架构 ${arch} 不在仓库预置范围，回退官方 Release"; return 1 ;;
  esac

  # ===== 优先用脚本旁边的本地 bin/（离线/同目录部署最常见）=====
  # 这一分支很重要：如果 SBP_REPO 还是占位符，
  # 远程下载必然失败。本地有二进制就不该联网。
  local script_dir local_bin
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for local_bin in "$script_dir/bin/xray-linux-${arch}" "$script_dir/bin/xray"; do
    if [[ -f "$local_bin" && -s "$local_bin" ]]; then
      info "使用本地仓库二进制：$local_bin"
      # 校验和（本地也算一遍，防止文件损坏）
      local sumf="$script_dir/bin/xray.sha256"
      if [[ -f "$sumf" ]]; then
        local want got
        want="$(grep -F "xray-linux-${arch}" "$sumf" 2>/dev/null | awk '{print $1}' | head -1)"
        [[ -z "$want" ]] && want="$(awk '{print $1}' "$sumf" | head -1)"
        got="$(sha256_of "$local_bin")" || got=""
        if [[ -n "$want" && -n "$got" ]]; then
          if [[ "${got,,}" != "${want,,}" ]]; then
            warn "本地二进制 SHA-256 不匹配（期望 ${want}，实际 ${got}），继续尝试远程"
          else
            ok "本地二进制 SHA-256 校验通过"
            _install_binary "$local_bin" && return 0
          fi
        else
          _install_binary "$local_bin" && return 0
        fi
      else
        _install_binary "$local_bin" && return 0
      fi
    fi
  done

  raw="${SBP_RAW_BASE:-https://raw.githubusercontent.com/${SBP_REPO:-20001rom/sbp-hy2}/${SBP_BRANCH:-main}}"
  ver_url="${raw}/bin/VERSION"
  sha_url="${raw}/bin/xray.sha256"
  # 仓库里按架构分文件：bin/xray-linux-64、bin/xray-linux-arm64-v8a
  local bin_url="${raw}/bin/xray-linux-${arch}"

  local tmp; tmp="$(mktemp -d)"
  local rc=1

  info "从本仓库获取已解压的 Xray 二进制（arch=linux-${arch}）..."
  if ! dl_gh "$bin_url" "$tmp/xray" 2>/dev/null; then
    rm -rf -- "$tmp"
    return 1
  fi

  # 版本信息（可选，仅用于展示）
  if dl "$ver_url" "$tmp/VERSION" 2>/dev/null; then
    info "仓库内置版本：$(tr -d '\n' < "$tmp/VERSION")"
  fi

  # 校验和（有就校验，没有则只做可执行性检查）
  if dl "$sha_url" "$tmp/sum" 2>/dev/null && [[ -s "$tmp/sum" ]]; then
    local want got
    want="$(grep -F "xray-linux-${arch}" "$tmp/sum" 2>/dev/null | awk '{print $1}' | head -1)"
    if [[ -z "$want" ]]; then
      want="$(awk '{print $1}' "$tmp/sum" | head -1)"
    fi
    got="$(sha256_of "$tmp/xray")" || got=""
    if [[ -n "$want" && -n "$got" ]]; then
      if [[ "${got,,}" != "${want,,}" ]]; then
        warn "SHA-256 校验失败（期望 ${want}，实际 ${got}）"
        rm -rf -- "$tmp"; return 1
      fi
      ok "SHA-256 校验通过"
    fi
  else
    warn "仓库未提供校验文件，仅做可执行性检查"
  fi

  _install_binary "$tmp/xray" && rc=0
  rm -rf -- "$tmp"
  return "$rc"
}

install_xray_inner(){
  local tmp="$1" arch rel_url meta name url digest tag ver pkg

  # ============================================================
  # 模式 0（默认首选）：从本仓库下载已解压的二进制
  # Xray 官方只发 zip，而极简 Debian 没有 unzip/busybox/python3，
  # perl-base 也不带 Compress::Raw::Zlib —— 在服务器上解 zip 无解。
  # 所以把解压这一步提前到打包阶段：仓库里直接放 bin/xray。
  # 服务器上只需下载一个文件 + chmod，全程不碰解压工具。
  # ============================================================
  if [[ "${XRAY_SOURCE:-repo}" == "repo" && -z "${XRAY_BIN:-}" ]]; then
    if install_from_repo; then
      return 0
    fi
    warn "从本仓库获取二进制失败，尝试回退到官方 Release"
  fi

  # 模式 1：本地已解压的二进制（离线场景）
  if [[ -n "${XRAY_BIN:-}" ]]; then
    [[ -f "$XRAY_BIN" ]] || { warn "XRAY_BIN 不存在：$XRAY_BIN"; return 1; }
    info "使用本地二进制：$XRAY_BIN"
    _install_binary "$XRAY_BIN" || return 1
    return 0
  fi

  # 模式 2：已装好且够新
  if [[ -x "$BIN_PATH" && -z "${XRAY_PKG:-}" && -z "${XRAY_FORCE:-}" ]]; then
    local cur; cur="$(xray_version)" || cur=""
    if [[ -n "$cur" ]]; then
      ok "检测到已安装 v${cur}（用 XRAY_FORCE=1 可强制更新）"
      return 0
    fi
  fi

  # 模式 3：本地 zip 包
  if [[ -n "${XRAY_PKG:-}" ]]; then
    [[ -f "$XRAY_PKG" ]] || { warn "XRAY_PKG 不存在：$XRAY_PKG"; return 1; }
    local pkg_ver=""
    pkg_ver="$(basename "$XRAY_PKG" | sed -n 's/.*Xray-v\{0,1\}\([0-9][0-9.]*\)-.*/\1/p')"
    if [[ -n "$pkg_ver" && -x "$BIN_PATH" ]]; then
      local cur; cur="$(xray_version)" || cur=""
      if [[ -n "$cur" ]] && ! version_lt "$cur" "$pkg_ver"; then
        ok "已安装 v${cur}（本地包 v${pkg_ver}），无需重装"
        return 0
      fi
    fi
    info "使用本地包：$XRAY_PKG"
    pkg="$tmp/$(basename "$XRAY_PKG")"
    cp -f "$XRAY_PKG" "$pkg" || { warn "复制失败"; return 1; }
    if [[ -n "${XRAY_PKG_SHA256:-}" ]]; then
      local got; got="$(sha256_of "$pkg")" || return 1
      [[ "${got,,}" == "${XRAY_PKG_SHA256,,}" ]] || { warn "SHA-256 不匹配"; return 1; }
      ok "本地包 SHA-256 校验通过"
    fi
    extract_install "$pkg" || return 1
    return 0
  fi

  arch="$(xray_arch)"
  info "查询 Xray 最新版本（arch=linux-${arch}）..."

  if [[ "$XRAY_TAG" == "latest" ]]; then
    rel_url="https://api.github.com/repos/${XRAY_REPO}/releases/latest"
  else
    rel_url="https://api.github.com/repos/${XRAY_REPO}/releases/tags/${XRAY_TAG}"
  fi

  dl_gh "$rel_url" "$tmp/rel.json" || { warn "无法获取 Release 元数据"; return 1; }
  meta="$(jq -r --arg n "Xray-linux-${arch}.zip" '
    . as $r | ([.assets[] | select(.name == $n)] | first) as $a
    | select($a != null)
    | [$r.tag_name, $a.name, $a.browser_download_url, ($a.digest // "")] | @tsv
  ' "$tmp/rel.json")" || { warn "Release 中找不到 Xray-linux-${arch}.zip"; return 1; }

  IFS=$'\t' read -r tag name url digest <<< "$meta"
  ver="${tag#v}"
  info "目标版本 v${ver}"

  if [[ -x "$BIN_PATH" ]]; then
    local cur; cur="$(xray_version)" || cur=""
    if [[ -n "$cur" ]] && ! version_lt "$cur" "$ver"; then
      ok "已安装 v${cur}，无需更新"; return 0
    fi
  fi

  ensure_unzip || return 1
  pkg="$tmp/$name"
  dl_gh "$url" "$pkg" || { warn "下载失败：$url"; return 1; }
  if [[ "$digest" == sha256:* ]]; then
    local want got
    want="${digest#sha256:}"
    got="$(sha256_of "$pkg")" || { warn "无法计算 SHA-256"; return 1; }
    [[ "${got,,}" == "${want,,}" ]] || { warn "SHA-256 校验失败"; return 1; }
    ok "SHA-256 校验通过"
  else
    warn "Release 未提供 digest，跳过校验"
  fi

  extract_install "$pkg" || return 1
}

# ===== 协议注册表 =====
proto_enabled(){
  case "$1" in
    vless-reality) [[ "${ENABLE_VLESS_REALITY:-true}"  == true ]] ;;
    vless-xhttp)   [[ "${ENABLE_VLESS_XHTTP:-false}"   == true ]] ;;
    trojan)        [[ "${ENABLE_TROJAN:-false}"        == true ]] ;;
    vless-tls)     [[ "${ENABLE_VLESS_TLS:-false}"     == true ]] ;;
    hy2)           [[ "${ENABLE_HYSTERIA2:-false}"     == true ]] ;;
    *) return 1 ;;
  esac
}
proto_port_var(){
  case "$1" in
    vless-reality) echo PORT_VLESSR ;;
    vless-xhttp)   echo PORT_VLESS_XHTTP ;;
    trojan)        echo PORT_TROJAN ;;
    vless-tls)     echo PORT_VLESS_TLS ;;
    hy2)           echo PORT_HY2 ;;
  esac
}
proto_transport(){
  case "$1" in
    vless-reality) echo tcp ;;
    vless-xhttp)   echo xhttp ;;
    trojan)        echo tcp ;;
    vless-tls)     echo tcp ;;
    hy2)           echo hysteria ;;
  esac
}

assign_ports(){
  USED_PORTS=()
  local v

  if proto_enabled vless-reality; then
    reality_port || die "Reality 端口分配失败"
    PORT_VLESSR="$RP"
    if (( PORT_VLESSR == 443 )); then
      ok "VLESS Reality 监听 443（SNI-IP-端口 自洽）"
    else
      warn "Reality 在 ${PORT_VLESSR}（非 443）：真实站点不会在该端口出示 ${REALITY_SERVER} 的证书"
    fi
  else
    PORT_VLESSR=""
  fi

  for v in PORT_VLESS_XHTTP:vless-xhttp PORT_TROJAN:trojan \
           PORT_VLESS_TLS:vless-tls PORT_HY2:hy2; do
    local pv="${v%%:*}" proto="${v##*:}"
    if proto_enabled "$proto"; then
      rand_port || die "${proto} 端口分配失败"
      printf -v "$pv" '%s' "$RP"
    else
      printf -v "$pv" '%s' ""
    fi
  done
}

# ===== 生成 Xray 配置 =====
# Xray 结构与 sing-box 完全不同：
#   inbound: {protocol, settings, streamSettings}
#   而不是 sing-box 的 {type, users, tls, transport}
build_stream_settings(){
  # 参数：<协议> —— 输出 streamSettings JSON
  local proto="$1" transport security extra=""
  transport="$(proto_transport "$proto")"

  case "$proto" in
    vless-reality) security="reality" ;;
    vless-xhttp)
      # XHTTP 必须带安全层，否则是明文流量——防封方案里不可接受。
      # 默认与 Reality 对齐（同一台服务器、同一个伪装目标），
      # 想套 CDN 时手动改 XHTTP_SECURITY=tls。
      security="${XHTTP_SECURITY:-reality}" ;;
    trojan|vless-tls|hy2) security="tls" ;;
    *) security="none" ;;
  esac

  jq -cn \
    --arg transport "$transport" \
    --arg security "$security" \
    --arg proto "$proto" \
    --arg rs "$REALITY_SERVER" \
    --argjson rsp "$REALITY_SERVER_PORT" \
    --arg rpriv "$REALITY_PRIVATE" \
    --arg sid "$REALITY_SID" \
    --arg crt "$CERT_DIR/fullchain.pem" \
    --arg key "$CERT_DIR/key.pem" \
    --arg xpath "$XHTTP_PATH" \
    --arg xmode "$XHTTP_MODE" \
    --arg pad "$XHTTP_PADDING" \
    --argjson fm "$ENABLE_FINALMASK" \
    --arg fmtype "$FINALMASK_TYPE" \
    --argjson frag "$ENABLE_TCP_FRAGMENT" \
    --argjson hyidle "$HY2_UDP_IDLE" \
    --arg masqtype "$HY2_MASQUERADE_TYPE" \
    --arg masqcontent "$HY2_MASQUERADE_CONTENT" \
    --arg masqurl "$HY2_MASQUERADE_URL" \
    --arg masqdir "$HY2_MASQUERADE_DIR" \
    '
    { network: $transport } as $base
    | (if $security == "reality" then
        { security:"reality", realitySettings:{
            dest: ($rs + ":" + ($rsp|tostring)),
            serverNames: [$rs],
            privateKey: $rpriv,
            shortIds: [$sid]
        }}
       elif $security == "tls" then
        # Hysteria2 走 QUIC，ALPN 必须是 h3；其余走 TCP 的用 h2/http1.1
        { security:"tls", tlsSettings:{
            certificates:[{certificateFile:$crt, keyFile:$key}],
            alpn: (if $proto == "hy2" then ["h3"] else ["h2","http/1.1"] end)
        }}
       else {} end) as $sec
    | (if $transport == "xhttp" then
        { xhttpSettings: (
            { mode: $xmode, path: $xpath, xPaddingBytes: $pad,
              xmux: {maxConcurrency:"16-32", cMaxReuseTimes:"64-128",
                     hMaxRequestTimes:"600-900", hMaxReusableSecs:"1800-3000"} }
          ) }
       else {} end) as $xt
    | (if $transport == "hysteria" then
        { hysteriaSettings: (
            { version: 2, udpIdleTimeout: $hyidle,
              masquerade: (
                if $masqtype == "proxy" then {type:"proxy", url:$masqurl, rewriteHost:true}
                elif $masqtype == "file" then {type:"file", dir:$masqdir}
                elif $masqtype == "string" then
                  {type:"string",
                   content: (if $masqcontent == "" then
                     "<!doctype html><html><head><title>Welcome</title></head><body><h1>It works!</h1></body></html>"
                     else $masqcontent end),
                   statusCode: 200}
                else {type:"string",
                   content:"<!doctype html><html><body><h1>It works!</h1></body></html>", statusCode:200}
                end) }
          ) }
       else {} end) as $hy
    | # FinalMask 与 TCP 分片都写在 finalmask.tcp 里，必须合并成一个数组，
      # 否则后赋值的对象会整体覆盖前者（jq 的 + 是浅合并）。
      ( (if $fm then
           (if $fmtype == "header-custom" then
              [ { type:"header-custom",
                  settings: { clients: [ [ {delay:0, rand:16} ] ],
                              servers: [ [ {delay:0, rand:16} ] ] } } ]
            elif $fmtype == "fragment" then
              [ { type:"fragment",
                  settings: { packets:"tlshello",
                              lengths:["5-9","4-9","1-2"],
                              delays:["0"], maxSplit:"3-6" } } ]
            elif ($fmtype == "sudoku" or $fmtype == "filter" or $fmtype == "xmc") then
              [ { type:$fmtype, settings:{} } ]
            else [] end)
         else [] end) as $fm_arr
      | (if $frag then
           [ { type:"fragment",
               settings: { packets:"tlshello",
                           lengths:["5-9","4-9","1-2"],
                           delays:["0"], maxSplit:"3-6" } } ]
         else [] end) as $frg_arr
      | (if (($fm_arr + $frg_arr) | length) > 0 then
           { finalmask: { tcp: ($fm_arr + $frg_arr) } }
         else {} end)
      ) as $fmk
    | $base + $sec + $xt + $hy + $fmk'
}

build_inbound(){
  local proto="$1" port="$2" stream
  stream="$(build_stream_settings "$proto")" || return 1

  jq -cn \
    --arg proto "$proto" \
    --argjson port "$port" \
    --argjson stream "$stream" \
    --arg uuid "$UUID" \
    --arg pwd "$TROJAN_PWD" \
    --arg hy2pwd "$HY2_PWD" \
    '
    (if $proto == "vless-reality" or $proto == "vless-tls" then
       { protocol:"vless",
         settings:{ clients:[{id:$uuid, flow:"xtls-rprx-vision"}], decryption:"none" } }
     elif $proto == "vless-xhttp" then
       { protocol:"vless",
         settings:{ clients:[{id:$uuid}], decryption:"none" } }
     elif $proto == "trojan" then
       { protocol:"trojan", settings:{ clients:[{password:$pwd}] } }
     elif $proto == "hy2" then
       # Xray 的 hysteria 入站：version 固定 2，users[].auth 是认证密码
       { protocol:"hysteria",
         settings:{ version:2, users:[{auth:$hy2pwd}] } }
     else empty end)
    + { listen:"0.0.0.0", port:$port, tag:$proto, streamSettings:$stream }'
}

render_config(){
  local inbounds="[]" proto pv port one

  for proto in vless-reality vless-xhttp trojan vless-tls hy2; do
    proto_enabled "$proto" || continue
    pv="$(proto_port_var "$proto")"
    port="${!pv:-}"
    [[ -n "$port" ]] || { warn "${proto} 已启用但无端口"; continue; }
    one="$(build_inbound "$proto" "$port")" || { warn "${proto} 入站生成失败"; return 1; }
    inbounds="$(jq -c --argjson a "$inbounds" --argjson b "$one" '$a + [$b]' <<< '{}')"
  done

  jq -n \
    --argjson inbounds "$inbounds" \
    '{
      log: { loglevel: "warning" },
      inbounds: $inbounds,
      outbounds: [
        { protocol:"freedom", tag:"direct" },
        { protocol:"blackhole", tag:"block" }
      ]
    }'
}

write_config(){
  # 注意：Xray 依赖文件扩展名判断格式，临时文件必须以 .json 结尾
  local tmp="${CONF_JSON}.tmp.json"
  mkdir -p "$XR_DIR"
  render_config > "$tmp" || { rm -f "$tmp"; return 1; }

  jq -e . "$tmp" >/dev/null 2>&1 || { warn "生成的 JSON 语法无效"; rm -f "$tmp"; return 1; }

  if [[ -x "$BIN_PATH" ]]; then
    # Xray 用 run -test 校验。注意：它会把 Warning 写到 stderr（例如
    # "Choosing www.apple.com as the target will increase the likelihood..."），
    # 不能以"stderr 非空"判定失败，必须看退出码与 "Configuration OK" 标记。
    local tout
    if tout="$("$BIN_PATH" run -test -c "$tmp" 2>&1)"; then
      if ! printf '%s' "$tout" | grep -q 'Configuration OK'; then
        warn "Xray 未确认配置有效："
        printf '%s\n' "$tout" | grep -E 'Failed|invalid' | head -5 >&2
        rm -f "$tmp"
        return 1
      fi
      # 把 Xray 自己给出的反封建议透传给用户，别吞掉
      printf '%s\n' "$tout" | grep -iE 'REALITY:.*(increase the likelihood|blocked)' \
        | sed 's/^.*REALITY:/[Xray 提示] REALITY:/' >&2 || true
    else
      warn "Xray 配置校验未通过："
      printf '%s\n' "$tout" | grep -E 'Failed|invalid' | head -5 >&2 \
        || printf '%s\n' "$tout" | sed -n '1,10p' >&2
      rm -f "$tmp"
      return 1
    fi
  else
    warn "未安装 Xray，跳过配置校验"
  fi

  mv -f "$tmp" "$CONF_JSON"
  chmod 600 "$CONF_JSON"
  ok "配置已写入 ${CONF_JSON}"
}

# ===== systemd =====
have_systemd(){ [[ -d /run/systemd/system ]] && have systemctl; }

write_unit(){
  mkdir -p "$SYSTEMD_UNIT_DIR"
  cat > "${SYSTEMD_UNIT_DIR}/${SYSTEMD_SERVICE}" <<EOF
[Unit]
Description=Xray (SBP-Xray)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_PATH} run -c ${CONF_JSON}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "${SYSTEMD_UNIT_DIR}/${SYSTEMD_SERVICE}"
}

restart_service(){
  if have_systemd; then
    systemctl daemon-reload
    systemctl enable "${SYSTEMD_SERVICE}" >/dev/null 2>&1 || true
    if systemctl restart "${SYSTEMD_SERVICE}"; then
      sleep 1
      systemctl is-active --quiet "${SYSTEMD_SERVICE}" && { ok "服务已启动"; return 0; }
      warn "服务启动后未保持运行"
      systemctl --no-pager status "${SYSTEMD_SERVICE}" | sed -n '1,12p' >&2 || true
      return 1
    fi
    warn "systemctl restart 失败"; return 1
  fi
  warn "无 systemd，前台试运行 2 秒"
  "$BIN_PATH" run -c "$CONF_JSON" & local pid=$!
  sleep 2
  if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; ok "试运行无异常"; return 0; fi
  warn "试运行立即退出"; return 1
}

# ===== 防火墙 =====
have_iptables(){ have iptables; }
persist_firewall(){
  have_iptables || return 0
  have netfilter-persistent && { netfilter-persistent save >/dev/null 2>&1 && return 0; }
  if have iptables-save && [[ -d /etc/iptables ]]; then
    iptables-save > /etc/iptables/rules.v4 2>/dev/null && return 0
  fi
  warn "防火墙规则未能持久化（重启后需重跑 deploy）"
  return 1
}
open_ports(){
  have_iptables || { warn "无 iptables，跳过放行"; return 0; }
  local proto pv port tcp=0 udp=0 proto_kind
  for proto in vless-reality vless-xhttp trojan vless-tls hy2; do
    proto_enabled "$proto" || continue
    pv="$(proto_port_var "$proto")"; port="${!pv:-}"
    [[ -n "$port" ]] || continue
    # 按协议的真实传输层放行：hy2 走 UDP/QUIC，其余走 TCP
    proto_kind="$(proto_transport "$proto")"
    if [[ "$proto_kind" == "hysteria" ]]; then
      iptables -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null \
        || iptables -I INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || true
      udp=$((udp+1))
    else
      iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null \
        || iptables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
      tcp=$((tcp+1))
    fi
  done
  persist_firewall
  ok "已放行 ${tcp} 个 TCP / ${udp} 个 UDP 端口"
}

# ===== 分享链接 =====
public_ip(){
  local ip
  ip="$(curl -fsS --connect-timeout 4 -m 8 https://api.ipify.org 2>/dev/null)" || ip=""
  printf '%s' "${ip:-YOUR_SERVER_IP}"
}
urlenc(){
  local LC_ALL=C
  local s="$1" out="" byte i
  for ((i=0; i<${#s}; i++)); do
    byte="${s:i:1}"
    case "$byte" in
      [a-zA-Z0-9.~_-]) out+="$byte" ;;
      *) out+=$(printf '%%%02X' "'$byte") ;;
    esac
  done
  printf '%s' "$out"
}

print_links(){
  local host; host="$(public_ip)"
  local -a lines=()
  local p=""

  # 所有端口变量用 ${VAR:-} 展开：load_ports 失败时（ports.env 缺失/损坏）
  # 未定义变量在 set -u 下会直接让 links 崩掉，什么也不输出。
  local _pv_vr="${PORT_VLESSR:-}" _pv_xh="${PORT_VLESS_XHTTP:-}"
  local _pv_tj="${PORT_TROJAN:-}" _pv_vt="${PORT_VLESS_TLS:-}"
  local _pv_hy="${PORT_HY2:-}"

  if proto_enabled vless-reality; then
    if [[ -z "$_pv_vr" ]]; then
      warn "PORT_VLESSR 未定义（ports.env 缺失？），跳过 Reality 链接"
    else
      p="$_pv_vr"
      lines+=("vless://${UUID}@${host}:${p}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SERVER}&fp=${UTLS_FP}&pbk=${REALITY_PUBLIC}&sid=${REALITY_SID}&type=tcp#Xray-Reality")
    fi
  fi
  if proto_enabled vless-xhttp; then
    if [[ -z "$_pv_xh" ]]; then
      warn "PORT_VLESS_XHTTP 未定义（ports.env 缺失？），跳过 XHTTP 链接"
    else
    p="$_pv_xh"
    # 链接的安全层必须跟随 XHTTP_SECURITY，否则客户端按错参数连不上
    local xsec="${XHTTP_SECURITY:-reality}" xsec_q x_sni
    if [[ "$xsec" == "reality" ]]; then
      xsec_q="security=reality&sni=${REALITY_SERVER}&fp=${UTLS_FP}&pbk=${REALITY_PUBLIC}&sid=${REALITY_SID}"
    elif [[ "$xsec" == "tls" ]]; then
      x_sni="${TLS_DOMAIN:-$REALITY_SERVER}"
      xsec_q="security=tls&sni=${x_sni}&fp=${UTLS_FP}&allowInsecure=1"
    else
      xsec_q="security=none"
    fi
    lines+=("vless://${UUID}@${host}:${p}?encryption=none&${xsec_q}&type=xhttp&path=$(urlenc "$XHTTP_PATH")&mode=${XHTTP_MODE}#Xray-XHTTP")
    fi
  fi
  if proto_enabled trojan; then
    if [[ -z "$_pv_tj" ]]; then
      warn "PORT_TROJAN 未定义，跳过 Trojan 链接"
    else
      p="$_pv_tj"
      # Trojan 走 TLS（不是 Reality），链接必须与 streamSettings 一致：
      # 服务端 security=tls + 自签证书 → 客户端要 allowInsecure=1
      local tj_sni="${TLS_DOMAIN:-$REALITY_SERVER}"
      lines+=("trojan://$(urlenc "$TROJAN_PWD")@${host}:${p}?security=tls&sni=${tj_sni}&fp=${UTLS_FP}&type=tcp&allowInsecure=1#Xray-Trojan")
    fi
  fi
  if proto_enabled vless-tls; then
    if [[ -z "$_pv_vt" ]]; then
      warn "PORT_VLESS_TLS 未定义，跳过 VLESS-TLS 链接"
    else
      p="$_pv_vt"
      # SNI 必须与证书 CN 一致：有 TLS_DOMAIN 时证书用的是它
      local vm_host="${TLS_DOMAIN:-$REALITY_SERVER}"
      lines+=("vless://${UUID}@${host}:${p}?encryption=none&flow=xtls-rprx-vision&security=tls&sni=${vm_host}&fp=${UTLS_FP}&type=tcp&allowInsecure=1#Xray-VLESS-TLS")
    fi
  fi
  if proto_enabled hy2; then
    if [[ -z "$_pv_hy" ]]; then
      warn "PORT_HY2 未定义，跳过 Hysteria2 链接"
    else
      p="$_pv_hy"
      # Hysteria2 官方 URI 参数只有 obfs/obfs-password/sni/insecure/pinSHA256/ech，
      # alpn 不在规范内（客户端会忽略），不写。
      local hy_sni="${TLS_DOMAIN:-$REALITY_SERVER}"
      lines+=("hysteria2://$(urlenc "$HY2_PWD")@${host}:${p}?sni=${hy_sni}&insecure=1#Xray-Hy2")
    fi
  fi

  local tmpf; tmpf="$(mktemp "${SHARE_LINKS_FILE}.tmp.XXXXXX")" || tmpf=""
  if [[ -n "$tmpf" ]]; then
    printf '%s\n' "${lines[@]}" > "$tmpf"
    chmod 600 "$tmpf" 2>/dev/null || true
    mv -f "$tmpf" "$SHARE_LINKS_FILE" || true
  fi
  chmod 600 "$SHARE_LINKS_FILE" 2>/dev/null || true

  echo
  printf "${C_BOLD}节点分享链接${C_RESET}（已存到 ${SHARE_LINKS_FILE}）\n"
  printf '%s\n' "${lines[@]}"
  echo
}

# 参数合法性校验（render 与 deploy 都要走）
validate_params(){
  # FinalMask 类型白名单：Xray 26.x 的 TCP 掩码只有这几个，
  # 其余（header-dns/header-dtls/header-srtp/header-wechat）是 mKCP 的 UDP
  # header 取值，写进 TCP 会 unknown config id，启动即失败。
  case "${FINALMASK_TYPE:-header-custom}" in
    header-custom|fragment|sudoku|filter|xmc) ;;
    *)
      warn "FINALMASK_TYPE=${FINALMASK_TYPE} 不是合法的 TCP 掩码类型"
      warn "  合法值：header-custom / fragment / sudoku / filter / xmc"
      warn "  已回退为 header-custom"
      FINALMASK_TYPE=header-custom ;;
  esac
  case "${XHTTP_SECURITY:-reality}" in
    reality|tls|none) ;;
    *)
      warn "XHTTP_SECURITY=${XHTTP_SECURITY} 非法，回退为 reality"
      XHTTP_SECURITY=reality ;;
  esac
  case "${HY2_MASQUERADE_TYPE:-string}" in
    string|proxy|file) ;;
    *)
      warn "HY2_MASQUERADE_TYPE=${HY2_MASQUERADE_TYPE} 非法，回退为 string"
      HY2_MASQUERADE_TYPE=string ;;
  esac
  case "${XHTTP_MODE:-auto}" in
    auto|packet-up|stream-up|stream-one) ;;
    *)
      warn "XHTTP_MODE=${XHTTP_MODE} 非法，回退为 auto"
      XHTTP_MODE=auto ;;
  esac
}

# ===== 部署 =====
ensure_creds(){
  ENABLE_VLESS_REALITY="${ENABLE_VLESS_REALITY:-true}"
  ENABLE_VLESS_XHTTP="${ENABLE_VLESS_XHTTP:-false}"
  ENABLE_TROJAN="${ENABLE_TROJAN:-false}"
  ENABLE_VLESS_TLS="${ENABLE_VLESS_TLS:-false}"
  ENABLE_HYSTERIA2="${ENABLE_HYSTERIA2:-false}"
  TLS_CERT_MODE="${TLS_CERT_MODE:-self_signed}"
  TLS_DOMAIN="${TLS_DOMAIN:-}"

  UUID="${UUID:-$(gen_uuid)}"
  UUID2="${UUID2:-$(gen_uuid)}"
  TROJAN_PWD="${TROJAN_PWD:-$(rand_b64 24)}"
  HY2_PWD="${HY2_PWD:-$(rand_b64 24)}"
  REALITY_SID="${REALITY_SID:-$(rand_hex 8)}"
  XHTTP_PATH="${XHTTP_PATH:-/$(rand_hex 6)}"

  validate_params
  if [[ -z "${REALITY_PRIVATE:-}" || -z "${REALITY_PUBLIC:-}" ]]; then
    gen_reality_keys || die "生成 Reality 密钥失败"
  fi
}

# 端口占用探测：xray run -test 只装配配置不 bind，443 被 nginx 占用时
# 它照样报 Configuration OK，直到 systemd 启动才失败，那时配置已落盘。
port_in_use(){
  local p="$1" proto="${2:-tcp}"
  have ss || return 1
  if [[ "$proto" == "udp" ]]; then
    ss -Huln 2>/dev/null | grep -qE "[:.]${p}[[:space:]]"
  else
    ss -Htln 2>/dev/null | grep -qE "[:.]${p}[[:space:]]"
  fi
}

# 检查所有将要监听的端口
check_port_conflicts(){
  local proto pv port kind bad=0
  for proto in vless-reality vless-xhttp trojan vless-tls hy2; do
    proto_enabled "$proto" || continue
    pv="$(proto_port_var "$proto")"; port="${!pv:-}"
    [[ -n "$port" ]] || continue
    kind="$(proto_transport "$proto")"
    [[ "$kind" == "hysteria" ]] && kind=udp || kind=tcp
    if port_in_use "$port" "$kind"; then
      # 如果占用者正是本服务自己（重启场景），不算冲突
      if have_systemd && systemctl is-active --quiet "$SYSTEMD_SERVICE" 2>/dev/null; then
        info "端口 ${port}/${kind} 已被本服务占用（正常重启）"
      else
        warn "端口 ${port}/${kind} 已被其他进程占用（${proto}）"
        ss -Htlnp 2>/dev/null | grep -E "[:.]${port}[[:space:]]" | head -1 | sed 's/^/    /' >&2 || true
        ss -Hulnp 2>/dev/null | grep -E "[:.]${port}[[:space:]]" | head -1 | sed 's/^/    /' >&2 || true
        bad=$((bad+1))
      fi
    fi
  done
  if (( bad > 0 )); then
    warn "有 ${bad} 个端口被占用，配置会写成功但服务起不来"
    return 1
  fi
  return 0
}

deploy(){
  [[ "$EUID" -eq 0 || -n "${SBP_TEST_ROOT:-}" ]] || die "请以 root 运行（或 sudo）"

  echo "============================================================"
  printf " ${C_BOLD}SBP-Xray %s 部署${C_RESET}（Xray-core，无包管理器依赖）\n" "$SCRIPT_VERSION"
  echo "============================================================"

  info "第 1/6 步：准备静态工具"
  ensure_jq || die "jq 不可用"
  # 只有走官方 Release（zip）时才需要解压工具；
  # 默认 XRAY_SOURCE=repo 下载的是已解压二进制，不需要 unzip
  if [[ "${XRAY_SOURCE:-repo}" == "release" || -n "${XRAY_PKG:-}" ]]; then
    have unzip || have busybox || ensure_unzip || warn "无解压工具，官方 zip 无法解包"
  fi

  info "第 2/6 步：安装 Xray 核心"
  install_xray || die "Xray 安装失败"

  info "第 3/6 步：生成凭证"
  load_env || true
  ensure_creds

  # Reality 的主动探测防御完全取决于 dest 的证书质量，
  # 所以启用 Reality 时必须先校验 dest，不合格就停下。
  if proto_enabled vless-reality; then
    echo "  校验 Reality dest（防主动探测的关键）"
    if ! verify_dest "$REALITY_SERVER" "$REALITY_SERVER_PORT"; then
      die "Reality dest 校验失败，已中止部署。换一个合格的 SNI 后重试（或设 VERIFY_DEST_STRICT=0 强行继续）"
    fi
  fi

  info "第 4/6 步：分配端口"
  USED_PORTS=()
  assign_ports

  info "第 5/6 步：准备证书"
  # 任何需要 TLS 证书的协议启用时都必须先签证书，否则生成的是不可用配置
  if proto_enabled vless-tls || proto_enabled trojan || proto_enabled hy2; then
    ensure_cert || die "已启用需要证书的协议（trojan/vless-tls/hy2），但证书生成失败"
    # Hysteria2 的 masquerade=file 需要一个目录
    if proto_enabled hy2 && [[ "${HY2_MASQUERADE_TYPE:-string}" == "file" ]]; then
      mkdir -p "${HY2_MASQUERADE_DIR:-$CERT_DIR/www}" 2>/dev/null || true
      if [[ ! -f "${HY2_MASQUERADE_DIR}/index.html" ]]; then
        cat > "${HY2_MASQUERADE_DIR}/index.html" 2>/dev/null <<'HTML'
<!doctype html><html><head><meta charset="utf-8"><title>Welcome</title></head>
<body><h1>It works!</h1></body></html>
HTML
      fi
    fi
  else
    ensure_cert || warn "证书流程未完成"
  fi

  info "第 6/6 步：生成并校验配置"
  save_env; save_ports
  # 写配置前先查端口占用：xray run -test 不 bind，查不出 443 被 nginx 占用
  check_port_conflicts || die "端口冲突，已中止（避免写出起不来的配置）"
  write_config || die "配置生成失败"
  write_unit
  open_ports || true
  restart_service || warn "服务未成功启动"

  print_links
}

show_status(){
  echo "--- SBP-Xray 状态 ---"
  if [[ -x "$BIN_PATH" ]]; then echo "核心版本: v$(xray_version 2>/dev/null || echo 未知)"
  else echo "核心版本: 未安装"; fi
  # systemctl is-active 对未激活单元返回 4，配合 pipefail 会触发 errexit，
  # 让 status 在打印这一行后直接退出。必须 || true。
  if have_systemd; then
    local sstate
    sstate="$(systemctl is-active "$SYSTEMD_SERVICE" 2>/dev/null || true)"
    echo "服务状态: ${sstate:-unknown}"
  fi
  load_ports 2>/dev/null || true
  load_env 2>/dev/null || true
  echo "SNI: ${REALITY_SERVER:-未设置}  指纹: ${UTLS_FP:-未设置}"
  echo "Reality 端口模式: ${REALITY_PORT_MODE:-auto}"
  local v
  for v in PORT_VLESSR PORT_VLESS_XHTTP PORT_TROJAN PORT_VLESS_TLS PORT_HY2; do
    [[ -n "${!v:-}" ]] && printf '  %-16s %s\n' "${v#PORT_}" "${!v}"
  done
  echo "XHTTP: $( [[ "${ENABLE_VLESS_XHTTP:-false}" == true ]] && echo "启用 path=${XHTTP_PATH:-} sec=${XHTTP_SECURITY:-reality}" || echo 未启用)"
  echo "FinalMask: ${ENABLE_FINALMASK:-false}   TCP分片: ${ENABLE_TCP_FRAGMENT:-false}"
  echo "Hysteria2: $( [[ "${ENABLE_HYSTERIA2:-false}" == true ]] && echo "启用 port=${PORT_HY2:-} masquerade=${HY2_MASQUERADE_TYPE:-string}" || echo 未启用)"
}

rotate_ports(){
  load_env || die "未找到 ${ENV_FILE}，先部署"
  load_ports || true
  USED_PORTS=(); assign_ports; save_ports
  write_config || die "配置生成失败"
  open_ports || true
  restart_service || warn "重启失败"
  ok "端口已更换"
  print_links
}

uninstall_all(){
  [[ "$EUID" -eq 0 ]] || die "请以 root 运行"
  warn "将删除 ${XR_DIR}、${BIN_PATH} 与 systemd 单元"
  read -rp "确认？输入 yes: " a
  [[ "$a" == "yes" ]] || { info "已取消"; return 0; }
  have_systemd && { systemctl stop "$SYSTEMD_SERVICE" 2>/dev/null || true
                    systemctl disable "$SYSTEMD_SERVICE" 2>/dev/null || true; }
  rm -f "${SYSTEMD_UNIT_DIR}/${SYSTEMD_SERVICE}"
  have_systemd && systemctl daemon-reload 2>/dev/null || true
  rm -rf -- "$XR_DIR"
  rm -f -- "$BIN_PATH" "${BIN_PATH}.bak"
  ok "已卸载"
}

selftest(){
  local fail=0
  echo "=== SBP-Xray 自检 ==="
  echo -n "bash 语法: "; bash -n "$0" && echo OK || { echo FAIL; fail=1; }
  echo -n "架构探测: "; echo "$(xray_arch)"
  echo -n "版本比较: "
  if version_lt 26.10.0 26.11.9 && ! version_lt 26.11.9 26.11.9; then echo OK
  else echo FAIL; fail=1; fi
  echo -n "端口去重: "
  USED_PORTS=(); local i bad=0
  for i in $(seq 1 50); do
    rand_port || { bad=1; break; }
    (( RP >= LISTEN_PORT_MIN && RP <= LISTEN_PORT_MAX )) || bad=1
  done
  local u t; t=${#USED_PORTS[@]}
  u=$(printf '%s\n' "${USED_PORTS[@]}" | sort -u | wc -l)
  (( u == t )) || bad=1
  (( bad == 0 )) && echo "OK（${t} 个无重复）" || { echo FAIL; fail=1; }
  echo -n "Reality=443 策略: "
  local save="$REALITY_PORT_MODE"; REALITY_PORT_MODE=auto; USED_PORTS=(); reality_port
  [[ "$RP" == "443" ]] && echo OK || { echo "FAIL($RP)"; fail=1; }
  REALITY_PORT_MODE="$save"
  echo -n "urlenc: "
  [[ "$(urlenc 'a b/c+d=')" == "a%20b%2Fc%2Bd%3D" ]] && echo OK || { echo FAIL; fail=1; }
  echo -n "配置渲染: "
  if have jq; then
    UUID="${UUID:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo 00000000-0000-4000-8000-000000000000)}"
    UUID2="${UUID2:-$UUID}"
    TROJAN_PWD="${TROJAN_PWD:-placeholder}"
    REALITY_PRIVATE="${REALITY_PRIVATE:-placeholder}"
    REALITY_PUBLIC="${REALITY_PUBLIC:-placeholder}"
    REALITY_SID="${REALITY_SID:-0011223344556677}"
    XHTTP_PATH="${XHTTP_PATH:-/selftest}"
    ENABLE_VLESS_REALITY="${ENABLE_VLESS_REALITY:-true}"
    [[ -z "${PORT_VLESSR:-}" ]] && { USED_PORTS=(); assign_ports >/dev/null 2>&1 || true; }
    if render_config 2>/dev/null | jq -e '.inbounds | length > 0' >/dev/null; then echo OK
    else echo FAIL; fail=1; fi
  else echo "SKIP（无 jq）"; fi
  echo
  (( fail == 0 )) && { ok "全部通过"; return 0; } || { warn "有失败项"; return 1; }
}

usage(){
  cat <<EOF
SBP-Xray ${SCRIPT_VERSION} —— Xray-core 部署（无包管理器依赖）

用法：
  sudo bash sbp-xray.sh               交互菜单
  sudo bash sbp-xray.sh deploy        一键部署
  sudo bash sbp-xray.sh status        查看状态
  sudo bash sbp-xray.sh links         打印分享链接
  sudo bash sbp-xray.sh rotate        更换端口
  sudo bash sbp-xray.sh uninstall     彻底卸载
  bash sbp-xray.sh render             仅输出配置 JSON（免 root）
  bash sbp-xray.sh selftest           自检（免 root）

环境变量：
  REALITY_SERVER         Reality 目标，默认 ${REALITY_SERVER}
  REALITY_PORT_MODE      auto(443)/random/fixed
  UTLS_FP                uTLS 指纹，默认 ${UTLS_FP}
  ENABLE_XHTTP           true 启用 XHTTP 入站（sing-box 无此能力）
  XHTTP_MODE             auto/packet-up/stream-up/stream-one
  XHTTP_PATH             请求路径，默认随机
  ENABLE_FINALMASK       true 启用 FinalMask
  FINALMASK_TYPE         header-custom/fragment/sudoku/filter/xmc
  ENABLE_TCP_FRAGMENT    true 启用 ClientHello 分片
  ENABLE_TROJAN          true 启用 Trojan Reality
  ENABLE_VLESS_TLS       true 启用 VLESS over TLS（自签）
  XRAY_PKG               本地 zip 包路径（离线安装）
  XRAY_TAG               指定版本，默认 latest
EOF
}

menu(){
  while :; do
    echo
    echo "============================================================"
    printf " ${C_BOLD}SBP-Xray %s${C_RESET}\n" "$SCRIPT_VERSION"
    echo "============================================================"
    echo "  1) 一键部署"
    echo "  2) 查看状态"
    echo "  3) 查看分享链接"
    echo "  4) 重启服务"
    echo "  5) 更换端口"
    echo "  6) 自检"
    echo "  7) 彻底卸载"
    echo "  0) 退出"
    read -rp "选择: " op || exit 0
    case "${op:-}" in
      1) deploy ;;
      2) show_status ;;
      3) load_env 2>/dev/null || die "尚未部署"; load_ports 2>/dev/null || true; print_links ;;
      4) restart_service ;;
      5) rotate_ports ;;
      6) selftest ;;
      7) uninstall_all ;;
      0|q|Q) exit 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

main(){
  case "${1:-}" in
    "") menu ;;
    deploy) deploy ;;
    status) show_status ;;
    links) load_env 2>/dev/null || die "尚未部署"; load_ports 2>/dev/null || true; print_links ;;
    rotate) rotate_ports ;;
    uninstall) uninstall_all ;;
    render)
      load_env 2>/dev/null || true
      validate_params
      ensure_creds 2>/dev/null || {
        UUID="${UUID:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo 00000000-0000-4000-8000-000000000000)}"
        UUID2="${UUID2:-$UUID}"; TROJAN_PWD="${TROJAN_PWD:-placeholder}"
        REALITY_PRIVATE="${REALITY_PRIVATE:-placeholder}"; REALITY_PUBLIC="${REALITY_PUBLIC:-placeholder}"
        REALITY_SID="${REALITY_SID:-0011223344556677}"; XHTTP_PATH="${XHTTP_PATH:-/placeholder}"
        ENABLE_VLESS_REALITY="${ENABLE_VLESS_REALITY:-true}"
      }
      [[ -z "${PORT_VLESSR:-}" ]] && { USED_PORTS=(); assign_ports >/dev/null 2>&1 || true; }
      render_config ;;
    selftest) selftest ;;
    -h|--help|help) usage ;;
    *) echo "未知参数：$1" >&2; usage >&2; return 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
