#!/usr/bin/env bash
# ============================================================
#  SBP-Hy2 —— 官方 Hysteria 2 部署脚本
#  设计目标：Hy2 做主力，用上官方全部防封能力
#   · gecko / salamander 混淆
#   · 端口跳跃（listen 端口段，官方自动配 nft/iptables）
#   · ACL 分流 + 多 outbounds
#   · masquerade 三种伪装（含 listenHTTP/listenHTTPS 双栈伪装）
#   · 无包管理器依赖
#  Version: v1.0.0
# ============================================================

set -Eeuo pipefail

# 在赋默认值前快照外部环境键，供 load_env 区分"用户显式指定"与"脚本默认"
_SBP_ENV_KEYS=""
for _k in HY2_LISTEN HY2_PORT_START HY2_PORT_END AUTH_PASSWORD \
          OBFS_TYPE OBFS_PASSWORD GECKO_MIN GECKO_MAX \
          MASQ_TYPE MASQ_URL MASQ_DIR MASQ_STATUS \
          ENABLE_LISTEN_HTTP ENABLE_LISTEN_HTTPS FORCE_HTTPS \
          TLS_MODE TLS_DOMAIN TLS_EMAIL TLS_CERT TLS_KEY ACME_CA ACME_TYPE \
          SNI_GUARD CONGESTION_TYPE BBR_PROFILE BW_UP BW_DOWN IGNORE_CLIENT_BW \
          UDP_IDLE DISABLE_UDP ENABLE_ACL ACL_REJECT_CN \
          TRAFFIC_STATS_PORT TRAFFIC_STATS_SECRET VERIFY_DOMAIN_STRICT \
          HY2_BIN HY2_PKG; do
  [[ -n "${!_k+x}" ]] && _SBP_ENV_KEYS="$_SBP_ENV_KEYS $_k"
done
unset _k

SCRIPT_VERSION="v1.0.0"
# SBP_DIR 由 sbp.sh 传入；直接跑本脚本时可能未定义，这里兜底
SBP_DIR="${SBP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
SBP_HOME="${SBP_HOME:-/var/lib/sbp-lite}"
SBP_BIN_DIR="${SBP_BIN_DIR:-$SBP_HOME/bin}"
HY_DIR="${HY_DIR:-/etc/hysteria}"
CONF_YAML="${CONF_YAML:-$HY_DIR/config.yaml}"
ACME_DIR="${ACME_DIR:-$HY_DIR/acme}"
MASQ_DIR_DEFAULT="${MASQ_DIR_DEFAULT:-$HY_DIR/www}"
BIN_PATH="${BIN_PATH:-/usr/local/bin/hysteria}"
SYSTEMD_SERVICE="${SYSTEMD_SERVICE:-hysteria.service}"
SYSTEMD_UNIT_DIR="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
ENV_FILE="${ENV_FILE:-$HY_DIR/env.conf}"

HY_REPO="${HY_REPO:-apernet/hysteria}"
HY_TAG="${HY_TAG:-latest}"
# 二进制来源：repo（本仓库已解压）/ release（官方裸二进制）
HY_SOURCE="${HY_SOURCE:-repo}"
SBP_REPO="${SBP_REPO:-20001rom/sbp-hy2}"
SBP_BRANCH="${SBP_BRANCH:-main}"
SBP_RAW_BASE="${SBP_RAW_BASE:-https://raw.githubusercontent.com/${SBP_REPO}/${SBP_BRANCH}}"

# ===== 监听与端口跳跃 =====
# 端口选择有论文依据，不要随手改成 443：
#
# 1) GFW 的 QUIC 审查只处理「源端口 > 目的端口」的 UDP 包
#    （USENIX Security '25 §3.3）。这条规则覆盖 92.3% 的 QUIC Initial，
#    却只需检查 30% 的 UDP 包。服务端端口 ≥32768 时，客户端临时端口
#    必然更低，该流直接落在 GFW 的解密流程之外。
# 2) 电信 AS4134 等对 UDP/443 有与协议无关的限速：
#    连接建立后 10-30 秒内骤降到 1-5 Mbps。实测改 8443 后回到 20 Mbps。
#
# 所以默认用 35543（≥32768 且高于常见客户端临时端口下限），
# 不是 443。要改回 443 请显式设置 HY2_LISTEN=:443。
HY2_LISTEN="${HY2_LISTEN:-:35543}"
# 端口跳跃（可选）：设 ENABLE_PORT_HOP=true 后用端口段，官方自动配 nft/iptables
ENABLE_PORT_HOP="${ENABLE_PORT_HOP:-false}"
HY2_PORT_START="${HY2_PORT_START:-20000}"
HY2_PORT_END="${HY2_PORT_END:-50000}"

# ===== 认证 =====
AUTH_PASSWORD="${AUTH_PASSWORD:-}"

# ===== 混淆（这是选官方版的主要理由）=====
#   none        —— 不混淆，伪装成标准 HTTP/3。masquerade 有效（推荐默认）
#   salamander  —— 每包 XOR。失去 H3 伪装，masquerade 失效
#   gecko       —— salamander + 握手分片。同样失去 H3 伪装
#
# 关键权衡（audit 实测 + 官方文档双重确认）：
#   开启任何混淆后，服务器不再是合法 HTTP/3 服务端
#   （官方原话：will no longer function as a valid HTTP/3 server）。
#   后果是探测者发标准 H3 握手会得不到回应，masquerade 永远不会被触发。
#   也就是说「混淆」和「masquerade 主动探测防御」互斥，只能选一个。
#
# 默认选 none 的原因：
#   · 保留 H3 伪装 + masquerade，主动探测看到真页面
#   · gecko 在中国 GFW 下没有任何公开实测数据，且 v2.14.0 上有
#     确认的性能缺陷（禁 GSO/batching，issue #1724）
#   · 真要对抗「封 QUIC」的网络，用 gecko；要对抗主动探测，用 none
OBFS_TYPE="${OBFS_TYPE:-none}"
OBFS_PASSWORD="${OBFS_PASSWORD:-}"
GECKO_MIN="${GECKO_MIN:-512}"
GECKO_MAX="${GECKO_MAX:-1200}"

# ===== TLS =====
#   acme     —— 自动申请（需域名 + 80/443 可达）
#   manual   —— 自己放证书
TLS_MODE="${TLS_MODE:-acme}"
TLS_DOMAIN="${TLS_DOMAIN:-}"
TLS_EMAIL="${TLS_EMAIL:-}"
TLS_CERT="${TLS_CERT:-$HY_DIR/cert/fullchain.pem}"
TLS_KEY="${TLS_KEY:-$HY_DIR/cert/key.pem}"
ACME_CA="${ACME_CA:-letsencrypt}"
ACME_TYPE="${ACME_TYPE:-http}"
SNI_GUARD="${SNI_GUARD:-dns-san}"

# ===== 拥塞控制 =====
CONGESTION_TYPE="${CONGESTION_TYPE:-bbr}"
BBR_PROFILE="${BBR_PROFILE:-standard}"
# Brutal：填了才会用（比 BBR 抗丢包，但需准确带宽）
BW_UP="${BW_UP:-}"
BW_DOWN="${BW_DOWN:-}"
IGNORE_CLIENT_BW="${IGNORE_CLIENT_BW:-false}"
UDP_IDLE="${UDP_IDLE:-60s}"
DISABLE_UDP="${DISABLE_UDP:-false}"

# ===== masquerade（Hy2 的主动探测防御）=====
# 默认用 file（自带静态站）而不是 proxy：
#   · proxy 反代真站会被看出破绽——bing 对 VPS IP 返回验证页、
#     返回的 HTML 含绝对链接和 Set-Cookie 域，经你的域名访问时行为不一致
#   · proxy 还多一跳延迟，且反代模式 2026-08 才达到生产级
#   · file 完全可控、零延迟、无上游指纹
# 想反代真站仍可设 MASQ_TYPE=proxy。
MASQ_TYPE="${MASQ_TYPE:-file}"
MASQ_URL="${MASQ_URL:-https://www.bing.com}"
MASQ_DIR="${MASQ_DIR:-$MASQ_DIR_DEFAULT}"
MASQ_STATUS="${MASQ_STATUS:-200}"
# 额外监听 TCP 80/443，模拟真实 HTTP/3 站点的双栈行为
ENABLE_LISTEN_HTTP="${ENABLE_LISTEN_HTTP:-false}"
ENABLE_LISTEN_HTTPS="${ENABLE_LISTEN_HTTPS:-false}"
FORCE_HTTPS="${FORCE_HTTPS:-false}"

# ===== ACL =====
ENABLE_ACL="${ENABLE_ACL:-false}"
ACL_REJECT_CN="${ACL_REJECT_CN:-false}"

# ===== 流量统计 API =====
TRAFFIC_STATS_PORT="${TRAFFIC_STATS_PORT:-}"
TRAFFIC_STATS_SECRET="${TRAFFIC_STATS_SECRET:-}"

# ===== 域名校验（ACME 模式必须）=====
VERIFY_DOMAIN_STRICT="${VERIFY_DOMAIN_STRICT:-1}"

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
  请手动上传二进制：
       https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64
       install -m755 hysteria-linux-amd64 /usr/local/bin/hysteria
  或用 HY2_BIN=/path/to/hysteria 指定本地文件。
────────────────────────────────────────────────────────────

NODL
    return 1
  fi
}
dl(){
  local url="$1" out="$2"; shift 2
  local u
  for u in "$url" "$@"; do
    [[ -n "$u" ]] || continue
    _fetch "$u" "$out" 2>/dev/null && [[ -s "$out" ]] && return 0
    rm -f -- "$out" 2>/dev/null || true
  done
  return 1
}
dl_gh(){
  local url="$1" out="$2" m=()
  if [[ "$url" == https://github.com/* ]]; then
    m=("https://ghfast.top/$url" "https://gh-proxy.com/$url")
  fi
  dl "$url" "$out" "${m[@]}"
}

# ===== 架构（官方是裸二进制，命名 hysteria-linux-<arch>）=====
hy_arch(){
  case "$(uname -m)" in
    x86_64|amd64)   echo amd64 ;;
    aarch64|arm64)  echo arm64 ;;
    armv7l|armv7)   echo arm ;;
    armv6l)         echo armv5 ;;
    i386|i686)      echo 386 ;;
    riscv64)        echo riscv64 ;;
    loongarch64)    echo loong64 ;;
    *)              echo amd64 ;;
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
hy_version(){
  local v
  v="$("$BIN_PATH" version 2>/dev/null | awk '/^Version:/{print $2; exit}')" || return 1
  [[ -n "$v" ]] || return 1
  printf '%s' "${v#v}"
}

# ===== 静态 jq =====
ensure_jq(){
  have jq && return 0
  local arch out="$SBP_BIN_DIR/jq"
  arch="$(jq_arch)"
  info "下载静态 jq (${arch}) ..." >&2
  if dl_gh "https://github.com/jqlang/jq/releases/latest/download/jq-linux-${arch}" "$out" \
     && chmod +x "$out" && "$out" --version >/dev/null 2>&1; then
    ok "jq 就绪" >&2; return 0
  fi
  warn "jq 获取失败，请手动上传到 ${out}" >&2
  return 1
}

# ===== 变量校验 =====
validate_params(){
  case "${OBFS_TYPE:-none}" in
    none|salamander|gecko) ;;
    *) warn "OBFS_TYPE=${OBFS_TYPE} 非法，回退 none"; OBFS_TYPE=none ;;
  esac
  # 混淆与 masquerade 互斥，显式提示（这是最容易踩的坑）
  if [[ "${OBFS_TYPE}" != "none" && "${MASQ_TYPE:-file}" != "none" ]]; then
    warn "OBFS_TYPE=${OBFS_TYPE} 会关闭 HTTP/3 伪装，masquerade 将不可达"
    warn "  探测者看到的是「不回包的 UDP 端口」而不是伪装页面"
    warn "  若你要的是主动探测防御，请设 OBFS_TYPE=none"
    warn "  若你要对抗「封 QUIC」的网络，保持混淆并接受 masquerade 失效"
  fi
  case "${MASQ_TYPE:-file}" in
    file|proxy|string|none) ;;
    *) warn "MASQ_TYPE=${MASQ_TYPE} 非法，回退 file"; MASQ_TYPE=file ;;
  esac
  case "${TLS_MODE:-acme}" in
    acme|manual) ;;
    *) warn "TLS_MODE=${TLS_MODE} 非法，回退 acme"; TLS_MODE=acme ;;
  esac
  case "${CONGESTION_TYPE:-bbr}" in
    bbr|reno) ;;
    *) warn "CONGESTION_TYPE=${CONGESTION_TYPE} 非法，回退 bbr"; CONGESTION_TYPE=bbr ;;
  esac
  case "${BBR_PROFILE:-standard}" in
    standard|conservative|aggressive) ;;
    *) warn "BBR_PROFILE=${BBR_PROFILE} 非法，回退 standard"; BBR_PROFILE=standard ;;
  esac
  case "${SNI_GUARD:-dns-san}" in
    strict|disable|dns-san) ;;
    *) warn "SNI_GUARD=${SNI_GUARD} 非法，回退 dns-san"; SNI_GUARD=dns-san ;;
  esac
  # gecko 包大小约束
  # 顺序很重要：先截断上限，再校验 min<=max。
  # 原实现先对调再截断，GECKO_MIN=3000/GECKO_MAX=5000 会生成
  # min=3000 max=2048，二进制直接 FATAL invalid min/max packet size。
  if [[ -n "$GECKO_MIN" && -n "$GECKO_MAX" ]]; then
    if (( GECKO_MAX > 2048 )); then
      warn "GECKO_MAX 上限 2048，已限制"
      GECKO_MAX=2048
    fi
    if (( GECKO_MIN < 1 )); then
      warn "GECKO_MIN 无效，回退 512"
      GECKO_MIN=512
    fi
    if (( GECKO_MIN > GECKO_MAX )); then
      warn "GECKO_MIN(${GECKO_MIN}) > GECKO_MAX(${GECKO_MAX})，对调"
      local t="$GECKO_MIN"; GECKO_MIN="$GECKO_MAX"; GECKO_MAX="$t"
    fi
    # 对调后仍要复核上限
    if (( GECKO_MAX > 2048 )); then
      GECKO_MAX=2048
    fi
  fi
}

# ===== 环境文件 =====
load_env(){
  [[ -f "$ENV_FILE" ]] || return 1
  local line key val
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    key="${line%%=*}"
    [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
    val="${line#*=}"
    [[ " $_SBP_ENV_KEYS " == *" $key "* ]] && continue
    export "$key=$val"
  done < "$ENV_FILE"
  return 0
}
save_env(){
  mkdir -p "$(dirname "$ENV_FILE")"
  local tmpf
  tmpf="$(mktemp "${ENV_FILE}.tmp.XXXXXX")" || return 1
  {
    echo "# SBP-Hy2 配置（含密钥，请勿泄露）"
    for k in HY2_LISTEN ENABLE_PORT_HOP HY2_PORT_START HY2_PORT_END \
             AUTH_PASSWORD OBFS_TYPE OBFS_PASSWORD GECKO_MIN GECKO_MAX \
             TLS_MODE TLS_DOMAIN TLS_EMAIL TLS_CERT TLS_KEY ACME_CA ACME_TYPE SNI_GUARD \
             CONGESTION_TYPE BBR_PROFILE BW_UP BW_DOWN IGNORE_CLIENT_BW \
             UDP_IDLE DISABLE_UDP \
             MASQ_TYPE MASQ_URL MASQ_DIR MASQ_STATUS \
             ENABLE_LISTEN_HTTP ENABLE_LISTEN_HTTPS FORCE_HTTPS \
             ENABLE_ACL ACL_REJECT_CN \
             TRAFFIC_STATS_PORT TRAFFIC_STATS_SECRET VERIFY_DOMAIN_STRICT; do
      printf '%s=%s\n' "$k" "${!k:-}"
    done
  } > "$tmpf"
  chmod 600 "$tmpf" || { rm -f "$tmpf"; return 1; }
  mv -f "$tmpf" "$ENV_FILE"
}

# ===== 凭证 =====
ensure_creds(){
  AUTH_PASSWORD="${AUTH_PASSWORD:-$(openssl rand -base64 24 | tr -d '\n')}"
  if [[ "${OBFS_TYPE}" != "none" ]]; then
    OBFS_PASSWORD="${OBFS_PASSWORD:-$(openssl rand -base64 24 | tr -d '\n')}"
  fi
  if [[ "${ENABLE_ACL}" == "true" && -n "${TRAFFIC_STATS_PORT}" ]]; then
    TRAFFIC_STATS_SECRET="${TRAFFIC_STATS_SECRET:-$(openssl rand -hex 16)}"
  fi
}

# ===== 域名校验（ACME 模式必需）=====
# ACME 要签发域名证书，域名必须：① 解析到本机 ② 80/443 可达
verify_domain(){
  local dom="${1:-$TLS_DOMAIN}" strict="${VERIFY_DOMAIN_STRICT:-1}"
  [[ -n "$dom" ]] || { warn "TLS_MODE=acme 但未设置 TLS_DOMAIN"; return 1; }

  echo "  校验 ACME 域名：${dom}"

  if ! have getent && ! have nslookup && ! have host; then
    warn "缺少 DNS 查询工具，跳过域名校验"
    return 0
  fi

  # 解析
  local ip_local ip_pub
  if have getent; then
    ip_local="$(getent hosts "$dom" 2>/dev/null | awk '{print $1}' | head -1)"
  fi
  ip_pub="$(curl -fsS --connect-timeout 4 -m 8 https://api.ipify.org 2>/dev/null || true)"

  if [[ -n "$ip_local" ]]; then
    echo "    ✓ 域名解析到 ${ip_local}"
    if [[ -n "$ip_pub" ]]; then
      if [[ "$ip_local" == "$ip_pub" ]]; then
        echo "    ✓ 与本机公网 IP(${ip_pub}) 一致"
      else
        warn "✗ 域名解析(${ip_local}) 与本机公网 IP(${ip_pub}) 不一致"
        warn "  ACME HTTP-01 验证会失败"
        [[ "$strict" == "1" ]] && return 1
      fi
    fi
  else
    warn "✗ 域名 ${dom} 无法解析"
    [[ "$strict" == "1" ]] && return 1
  fi

  # 443 能否被外部访问（ACME TLS-ALPN 需要）
  if [[ "$ACME_TYPE" == "tls" ]]; then
    echo "    提示：ACME_TYPE=tls 需要 443 端口对外可达且未被占用"
  fi
  return 0
}

# ===== 安装 Hysteria =====
_install_binary(){
  local src="$1"
  [[ -f "$src" ]] || { warn "文件不存在：$src"; return 1; }
  chmod +x "$src" 2>/dev/null || true
  if ! "$src" version >/dev/null 2>&1; then
    warn "二进制无法执行（架构不匹配或损坏）：$src"
    return 1
  fi
  mkdir -p "$(dirname "$BIN_PATH")"
  [[ -f "$BIN_PATH" ]] && { cp -f "$BIN_PATH" "${BIN_PATH}.bak" 2>/dev/null || true; }
  install -m 0755 "$src" "$BIN_PATH" || { warn "写入 ${BIN_PATH} 失败"; return 1; }
  ok "Hysteria v$(hy_version) 已安装到 ${BIN_PATH}"
}

# 从本仓库下载已解压的二进制（官方本来就是裸二进制，不需要解压）
install_from_repo(){
  local arch raw url tmp rc=1
  arch="$(hy_arch)"
  case "$arch" in
    amd64|arm64) ;;
    *) info "架构 ${arch} 不在仓库预置范围，回退官方 Release"; return 1 ;;
  esac
  raw="${SBP_RAW_BASE}"
  url="${raw}/bin/hysteria-linux-${arch}"
  tmp="$(mktemp -d)"

  info "从本仓库获取 Hysteria 二进制（linux-${arch}）..."
  if ! dl_gh "$url" "$tmp/hysteria"; then
    rm -rf -- "$tmp"; return 1
  fi

  # 可选校验和
  if dl "$raw/bin/hysteria.sha256" "$tmp/sum" 2>/dev/null && [[ -s "$tmp/sum" ]]; then
    local want got
    want="$(grep -F "hysteria-linux-${arch}" "$tmp/sum" 2>/dev/null | awk '{print $1}' | head -1)"
    [[ -z "$want" ]] && want="$(awk '{print $1}' "$tmp/sum" | head -1)"
    got="$(sha256_of "$tmp/hysteria")" || got=""
    if [[ -n "$want" && -n "$got" ]]; then
      if [[ "${got,,}" != "${want,,}" ]]; then
        warn "SHA-256 校验失败"; rm -rf -- "$tmp"; return 1
      fi
      ok "SHA-256 校验通过"
    fi
  fi

  _install_binary "$tmp/hysteria" && rc=0
  rm -rf -- "$tmp"
  return "$rc"
}

install_hy2(){
  # 模式 0：本地二进制
  if [[ -n "${HY2_BIN:-}" ]]; then
    info "使用本地二进制：$HY2_BIN"
    _install_binary "$HY2_BIN"; return $?
  fi
  # 模式 1：已装好
  if [[ -x "$BIN_PATH" && -z "${HY2_PKG:-}" && -z "${HY_FORCE:-}" ]]; then
    local cur; cur="$(hy_version)" || cur=""
    if [[ -n "$cur" ]]; then
      ok "检测到已安装 v${cur}（HY_FORCE=1 可强制更新）"; return 0
    fi
  fi
  # 模式 2：本仓库
  if [[ "${HY_SOURCE:-repo}" == "repo" ]]; then
    install_from_repo && return 0
    warn "本仓库获取失败，回退官方 Release"
  fi
  # 模式 3：官方 Release（裸二进制，无需解压）
  local arch rel_url meta name url digest tag ver tmp
  arch="$(hy_arch)"
  info "查询 Hysteria 最新版本（linux-${arch}）..."
  if [[ "$HY_TAG" == "latest" ]]; then
    rel_url="https://api.github.com/repos/${HY_REPO}/releases/latest"
  else
    rel_url="https://api.github.com/repos/${HY_REPO}/releases/tags/${HY_TAG}"
  fi
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' RETURN 2>/dev/null || true
  dl_gh "$rel_url" "$tmp/rel.json" || { warn "无法获取 Release 元数据"; rm -rf "$tmp"; return 1; }
  meta="$(jq -r --arg n "hysteria-linux-${arch}" '
    . as $r | ([.assets[] | select(.name == $n)] | first) as $a
    | select($a != null)
    | [$r.tag_name, $a.name, $a.browser_download_url, ($a.digest // "")] | @tsv
  ' "$tmp/rel.json")" || { warn "Release 中找不到 hysteria-linux-${arch}"; rm -rf "$tmp"; return 1; }
  IFS=$'\t' read -r tag name url digest <<< "$meta"
  ver="${tag#app/v}"; ver="${ver#v}"
  info "目标版本 v${ver}"
  if [[ -x "$BIN_PATH" ]]; then
    local cur; cur="$(hy_version)" || cur=""
    if [[ -n "$cur" ]] && ! version_lt "$cur" "$ver"; then
      ok "已安装 v${cur}，无需更新"; rm -rf "$tmp"; return 0
    fi
  fi
  dl_gh "$url" "$tmp/hysteria" || { warn "下载失败：$url"; rm -rf "$tmp"; return 1; }
  if [[ "$digest" == sha256:* ]]; then
    local want got
    want="${digest#sha256:}"
    got="$(sha256_of "$tmp/hysteria")" || { warn "无法计算 SHA-256"; rm -rf "$tmp"; return 1; }
    [[ "${got,,}" == "${want,,}" ]] || { warn "SHA-256 校验失败"; rm -rf "$tmp"; return 1; }
    ok "SHA-256 校验通过"
  fi
  _install_binary "$tmp/hysteria"; local rc=$?
  rm -rf "$tmp"
  return $rc
}

# ===== 生成 YAML =====
yaml_escape(){
  # 简单转义：双引号包起来，内部 " 和 \ 转义
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

render_config(){
  local listen="$HY2_LISTEN"
  if [[ "${ENABLE_PORT_HOP}" == "true" ]]; then
    listen=":${HY2_PORT_START}-${HY2_PORT_END}"
  fi

  cat <<EOF
# SBP-Hy2 生成  $(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo '')
listen: $listen
EOF

  # TLS
  if [[ "${TLS_MODE}" == "acme" ]]; then
    cat <<EOF
acme:
  domains:
    - $(yaml_escape "$TLS_DOMAIN")
  email: $(yaml_escape "$TLS_EMAIL")
  ca: ${ACME_CA}
  type: ${ACME_TYPE}
  dir: $(yaml_escape "$ACME_DIR")
EOF
  else
    cat <<EOF
tls:
  cert: $(yaml_escape "$TLS_CERT")
  key: $(yaml_escape "$TLS_KEY")
  sniGuard: ${SNI_GUARD}
EOF
  fi

  # 混淆
  if [[ "${OBFS_TYPE}" != "none" ]]; then
    echo "obfs:"
    echo "  type: ${OBFS_TYPE}"
    echo "  ${OBFS_TYPE}:"
    echo "    password: $(yaml_escape "$OBFS_PASSWORD")"
    if [[ "${OBFS_TYPE}" == "gecko" ]]; then
      echo "    minPacketSize: ${GECKO_MIN}"
      echo "    maxPacketSize: ${GECKO_MAX}"
    fi
  fi

  # 认证
  cat <<EOF
auth:
  type: password
  password: $(yaml_escape "$AUTH_PASSWORD")
EOF

  # 拥塞控制
  echo "congestion:"
  echo "  type: ${CONGESTION_TYPE}"
  [[ "${CONGESTION_TYPE}" == "bbr" ]] && echo "  bbrProfile: ${BBR_PROFILE}"

  # ignoreClientBandwidth 是**顶层**字段，不在 bandwidth 段下。
  # 二进制对未知字段非严格 unmarshal，写错层级会静默失效。
  [[ "${IGNORE_CLIENT_BW}" == "true" ]] && echo "ignoreClientBandwidth: true"

  if [[ -n "${BW_UP}" || -n "${BW_DOWN}" ]]; then
    echo "bandwidth:"
    [[ -n "$BW_UP" ]] && echo "  up: ${BW_UP}"
    [[ -n "$BW_DOWN" ]] && echo "  down: ${BW_DOWN}"
  fi

  echo "udpIdleTimeout: ${UDP_IDLE}"
  [[ "${DISABLE_UDP}" == "true" ]] && echo "disableUDP: true"

  # masquerade
  if [[ "${MASQ_TYPE}" != "none" ]]; then
    echo "masquerade:"
    echo "  type: ${MASQ_TYPE}"
    case "${MASQ_TYPE}" in
      proxy)
        echo "  proxy:"
        echo "    url: $(yaml_escape "$MASQ_URL")"
        echo "    rewriteHost: true"
        ;;
      file)
        echo "  file:"
        echo "    dir: $(yaml_escape "$MASQ_DIR")"
        ;;
      string)
        echo "  string:"
        echo "    content: $(yaml_escape '<!doctype html><html><head><title>Welcome</title></head><body><h1>It works!</h1></body></html>')"
        echo "    statusCode: ${MASQ_STATUS}"
        ;;
    esac
    [[ "${ENABLE_LISTEN_HTTP}" == "true" ]] && echo "  listenHTTP: :80"
    [[ "${ENABLE_LISTEN_HTTPS}" == "true" ]] && echo "  listenHTTPS: :443"
    [[ "${FORCE_HTTPS}" == "true" ]] && echo "  forceHTTPS: true"
  fi

  # ACL
  # 只有至少一条规则时才输出 acl 段；否则会生成空的 `inline:`，
  # 虽能通过校验但是无效配置。
  if [[ "${ENABLE_ACL}" == "true" ]]; then
    local acl_rules=()
    [[ "${ACL_REJECT_CN}" == "true" ]] && acl_rules+=("reject(geoip:cn)")
    if (( ${#acl_rules[@]} > 0 )); then
      echo "acl:"
      echo "  inline:"
      local r
      for r in "${acl_rules[@]}"; do
        echo "    - ${r}"
      done
    else
      warn "ENABLE_ACL=true 但没有任何 ACL 规则（ACL_REJECT_CN=false），跳过 acl 段"
    fi
  fi

  # outbounds
  echo "outbounds:"
  echo "  - name: default"
  echo "    type: direct"
  if [[ "${ENABLE_ACL}" == "true" && -n "${TRAFFIC_STATS_PORT}" ]]; then
    cat <<EOF
trafficStats:
  listen: ":${TRAFFIC_STATS_PORT}"
  secret: $(yaml_escape "$TRAFFIC_STATS_SECRET")
EOF
  fi
}

# ===== 配置校验 =====
# 官方没有 `check` 子命令，只能短暂启动观察日志。判据要小心：
#   · "server up and running" → 成功
#   · "failed to load server config" / "invalid config" / FATAL → 失败
#   · "server stopped {"error": "quic: server closed"}" → 这是我们自己 kill 掉的结果，
#     绝不能当作配置错误（否则任何正常配置都会被判失败）
check_config(){
  local tmp="$1" out rc=0
  [[ -x "$BIN_PATH" ]] || { warn "未安装 Hysteria，跳过配置校验"; return 0; }

  if have timeout; then
    out="$(timeout 3 "$BIN_PATH" server -c "$tmp" 2>&1 || true)"
  else
    local p
    "$BIN_PATH" server -c "$tmp" > /tmp/.sbp-hy-check.$$ 2>&1 &
    p=$!
    sleep 2
    kill "$p" 2>/dev/null || true
    wait "$p" 2>/dev/null || true
    out="$(cat /tmp/.sbp-hy-check.$$ 2>/dev/null || true)"
    rm -f "/tmp/.sbp-hy-check.$$"
  fi

  # 明确的致命错误（排除我们自己 kill 造成的 quic: server closed）
  # 注意：端口被占用（服务正在运行）不是配置错误，必须先排除，
  # 否则「运行中重新部署」永远失败。
  local fatal
  fatal="$(printf '%s' "$out" | grep -iE 'failed to load server config|invalid config|unknown field|cannot unmarshal|FATAL' \
           | grep -viE 'quic: server closed' \
           | grep -viE 'bind: address already in use|bind: permission denied' || true)"
  if [[ -n "$fatal" ]]; then
    warn "配置校验失败："
    printf '%s\n' "$fatal" | head -5 >&2
    return 1
  fi

  # 能看到 "server up" 最好；没有也不能直接判失败（可能 timeout 太短）
  if printf '%s' "$out" | grep -q 'server up and running'; then
    return 0
  fi
  # 端口绑定失败是环境问题，不等于配置错误，但要指出
  if printf '%s' "$out" | grep -qiE 'bind: permission denied|address already in use'; then
    warn "配置语法有效，但端口绑定失败（需要用 root 或换端口）"
    return 0
  fi
  return 0
}

write_config(){
  # Hysteria 靠扩展名判断配置格式，临时文件必须以 .yaml 结尾，
  # 否则报 `Unsupported Config Type "tmp"`。
  local tmp="${CONF_YAML}.tmp.yaml"
  mkdir -p "$HY_DIR"

  # 临时文件含明文密码，创建即收紧权限（audit 发现原来是 644）
  ( umask 077; render_config > "$tmp" ) || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true

  # 校验前先停服务：否则 check 启动的第二实例会撞端口，
  # 导致「运行中重新部署」永远失败。顺带避免 ACME 重复申请证书
  # （每次 check 都真实发起 order，反复 deploy 会吃 Let's Encrypt 速率限制）。
  local was_active=false
  if have_systemd && systemctl is-active --quiet "$SYSTEMD_SERVICE" 2>/dev/null; then
    was_active=true
    systemctl stop "$SYSTEMD_SERVICE" 2>/dev/null || true
  fi

  if ! check_config "$tmp"; then
    rm -f "$tmp"
    # 校验失败要把服务恢复回去，别让它停在停止状态
    [[ "$was_active" == "true" ]] && systemctl start "$SYSTEMD_SERVICE" 2>/dev/null || true
    return 1
  fi

  mv -f "$tmp" "$CONF_YAML"
  chmod 600 "$CONF_YAML"
  ok "配置已写入 ${CONF_YAML}"
}

# ===== systemd =====
have_systemd(){ [[ -d /run/systemd/system ]] && have systemctl; }
write_unit(){
  mkdir -p "$SYSTEMD_UNIT_DIR"
  cat > "${SYSTEMD_UNIT_DIR}/${SYSTEMD_SERVICE}" <<EOF
[Unit]
Description=Hysteria 2 (SBP-Hy2)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_PATH} server -c ${CONF_YAML}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
NoNewPrivileges=true

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
      sleep 1.5
      systemctl is-active --quiet "${SYSTEMD_SERVICE}" && { ok "服务已启动"; return 0; }
      warn "服务启动后未保持运行"
      journalctl -u "${SYSTEMD_SERVICE}" --no-pager -n 12 2>/dev/null | sed 's/^/    /' >&2 || true
      return 1
    fi
    warn "systemctl restart 失败"; return 1
  fi
  warn "无 systemd，前台试运行 3 秒"
  "$BIN_PATH" server -c "$CONF_YAML" & local pid=$!
  sleep 3
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
  return 1
}
open_ports(){
  have_iptables || { warn "无 iptables，跳过放行"; return 0; }
  local ports=()
  if [[ "${ENABLE_PORT_HOP}" == "true" ]]; then
    # 端口段：官方自己会配 nft/iptables REDIRECT，这里只确保 INPUT 放行
    ports+=("${HY2_PORT_START}:${HY2_PORT_END}/udp")
  else
    local p="${HY2_LISTEN##*:}"
    ports+=("${p}/udp")
  fi
  [[ "${ENABLE_LISTEN_HTTP}" == "true" ]] && ports+=("80/tcp")
  [[ "${ENABLE_LISTEN_HTTPS}" == "true" ]] && ports+=("443/tcp")
  [[ -n "${TRAFFIC_STATS_PORT}" ]] && ports+=("${TRAFFIC_STATS_PORT}/tcp")

  local r proto port
  for r in "${ports[@]}"; do
    port="${r%/*}"; proto="${r#*/}"
    iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null \
      || iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
  done
  persist_firewall || warn "防火墙规则未持久化"
  ok "已放行 ${#ports[@]} 条规则（${ports[*]}）"
}

# ===== 分享链接 =====
public_ip(){
  local ip
  ip="$(curl -fsS --connect-timeout 4 -m 8 https://api.ipify.org 2>/dev/null || true)"
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
  local port="$HY2_LISTEN"
  local use_hop=false
  if [[ "${ENABLE_PORT_HOP}" == "true" ]]; then
    # 端口跳跃：authority 写 host:主端口,范围，带 mport
    port="${HY2_PORT_START},${HY2_PORT_START}-${HY2_PORT_END}"
    use_hop=true
  else
    port="${HY2_LISTEN##*:}"
  fi

  local sni="${TLS_DOMAIN:-$host}"
  local q=""
  q="sni=$(urlenc "$sni")"
  # 证书是 ACME 签的真证书 → 不需要 insecure
  if [[ "${TLS_MODE}" == "manual" ]]; then
    q="${q}&insecure=1"
  fi
  if [[ "${OBFS_TYPE}" != "none" ]]; then
    q="${q}&obfs=${OBFS_TYPE}&obfs-password=$(urlenc "$OBFS_PASSWORD")"
  fi
  [[ "$use_hop" == "true" ]] && q="${q}&mport=${HY2_PORT_START}"

  local link="hysteria2://$(urlenc "$AUTH_PASSWORD")@${host}:${port}?${q}#SBP-Hy2"

  echo
  printf "${C_BOLD}节点链接${C_RESET}\n"
  printf '%s\n' "$link"
  echo
  echo "  混淆: ${OBFS_TYPE}$([[ "$OBFS_TYPE" == "gecko" ]] && echo " (${GECKO_MIN}-${GECKO_MAX} 字节分片)")"
  echo "  端口: ${HY2_LISTEN}$([[ "$ENABLE_PORT_HOP" == "true" ]] && echo " → 跳跃 ${HY2_PORT_START}-${HY2_PORT_END}")"
  echo "  TLS : ${TLS_MODE}$([[ "$TLS_MODE" == "acme" ]] && echo " (${TLS_DOMAIN})")"
  echo "  伪装: masquerade=${MASQ_TYPE}${MASQ_URL:+ → $MASQ_URL}"
  echo
}

# ===== 部署 =====
deploy(){
  [[ "$EUID" -eq 0 || -n "${SBP_TEST_ROOT:-}" ]] || die "请以 root 运行（或 sudo）"

  echo "============================================================"
  printf " ${C_BOLD}SBP-Hy2 %s 部署${C_RESET}（官方 Hysteria 2，Hy2 做主力）\n" "$SCRIPT_VERSION"
  echo "============================================================"

  info "第 1/6 步：准备静态工具"
  # jq 只用于「从官方 Release 解析 JSON」。如果二进制已在本地
  # （HY2_BIN 或仓库内置），完全不需要 jq —— 不该因为缺它而阻断部署。
  local _need_jq=false
  if [[ -z "${HY2_BIN:-}" ]] && ! { [[ -x "$BIN_PATH" ]] && [[ -n "$(hy_version 2>/dev/null || true)" ]]; }; then
    if [[ "${HY_SOURCE:-repo}" != "repo" ]]; then
      _need_jq=true
    elif [[ ! -f "$SBP_DIR/bin/hysteria-linux-$(hy_arch)" && ! -f "$SBP_DIR/bin/hysteria" ]]; then
      _need_jq=true
    fi
  fi
  if [[ "$_need_jq" == "true" ]]; then
    ensure_jq || die "从官方 Release 安装需要 jq（或用 HY2_BIN 指定本地二进制）"
  else
    info "使用本地二进制，无需 jq"
  fi
  validate_params

  info "第 2/6 步：安装 Hysteria 核心"
  install_hy2 || die "Hysteria 安装失败"

  info "第 3/6 步：生成凭证"
  load_env || true
  validate_params
  ensure_creds

  info "第 4/6 步：TLS 准备"
  if [[ "${TLS_MODE}" == "acme" ]]; then
    verify_domain || die "ACME 域名校验失败（VERIFY_DOMAIN_STRICT=0 可跳过）"
    mkdir -p "$ACME_DIR"
  else
    [[ -s "$TLS_CERT" && -s "$TLS_KEY" ]] || die "TLS_MODE=manual 但证书不存在：$TLS_CERT / $TLS_KEY"
    info "使用手动证书：$TLS_CERT"
  fi

  info "第 5/6 步：生成并校验配置"
  save_env
  if [[ "${MASQ_TYPE}" == "file" ]]; then
    mkdir -p "$MASQ_DIR"
    if [[ -f "$MASQ_DIR/index.html" ]]; then
      info "静态站已存在，保留不覆盖：$MASQ_DIR"
    else
      # 简陋的 "It works!" 页面本身就是特征——真实网站不会这么空。
      # 生成一个像样的静态站（多页 + CSS + robots.txt + 404）。
      if [[ -f "${SBP_DIR}/lib/masq-site.sh" ]]; then
        # shellcheck disable=SC1091
        . "${SBP_DIR}/lib/masq-site.sh"
        masq_site_gen "$MASQ_DIR" || warn "静态站生成失败，退回最简页面"
      fi
      if [[ ! -f "$MASQ_DIR/index.html" ]]; then
        # 兜底：库缺失时至少给一个结构完整的页面
        cat > "$MASQ_DIR/index.html" <<'HTML'
<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Welcome</title>
<style>body{font:16px/1.6 -apple-system,Segoe UI,Roboto,sans-serif;
max-width:640px;margin:80px auto;padding:0 24px;color:#222}
h1{font-weight:600;letter-spacing:-.01em}p{color:#666}</style>
</head><body>
<h1>Welcome</h1>
<p>This site is under construction. Please check back later.</p>
</body></html>
HTML
        warn "使用兜底页面（lib/masq-site.sh 缺失）"
      fi
    fi
  fi
  write_config || die "配置生成失败"

  info "第 6/6 步：启动服务"
  write_unit
  open_ports || true
  if ! restart_service; then
    if [[ "${ENABLE_PORT_HOP}" == "true" ]]; then
      warn "端口跳跃需要 CAP_NET_ADMIN 与 nft/iptables，启动失败常见于此"
    fi
    # 服务没起来就不要打印"可用"的链接、也不要返回 0 ——
    # 那会让调用方（含 sbp.sh install all）以为成功了。
    warn "服务未成功启动，配置已写入但未生效"
    warn "排查：journalctl -u ${SYSTEMD_SERVICE} -n 30"
    return 1
  fi

  print_links
}

show_status(){
  echo "--- SBP-Hy2 状态 ---"
  if [[ -x "$BIN_PATH" ]]; then echo "核心版本: v$(hy_version 2>/dev/null || echo 未知)"
  else echo "核心版本: 未安装"; fi
  if have_systemd; then
    local st
    st="$(systemctl is-active "$SYSTEMD_SERVICE" 2>/dev/null || true)"
    echo "服务状态: ${st:-unknown}"
  fi
  load_env 2>/dev/null || true
  echo "监听: ${HY2_LISTEN}  端口跳跃: ${ENABLE_PORT_HOP}"
  echo "混淆: ${OBFS_TYPE}$([[ "$OBFS_TYPE" == "gecko" ]] && echo " (${GECKO_MIN}-${GECKO_MAX})")"
  echo "TLS : ${TLS_MODE}${TLS_DOMAIN:+ ($TLS_DOMAIN)}"
  echo "拥塞: ${CONGESTION_TYPE}$([[ "$CONGESTION_TYPE" == "bbr" ]] && echo "/${BBR_PROFILE}")"
  echo "伪装: ${MASQ_TYPE}${MASQ_URL:+ → $MASQ_URL}"
  echo "ACL : ${ENABLE_ACL}$([[ "$ACL_REJECT_CN" == "true" ]] && echo " (reject geoip:cn)")"
  echo "UDP 空闲: ${UDP_IDLE}"
}

rotate_ports(){
  load_env || die "未部署"
  if [[ "${ENABLE_PORT_HOP}" != "true" ]]; then
    warn "未启用端口跳跃，rotate 只重新生成配置"
  else
    # 保留原端口段宽度，只平移 —— 原来把 30000-30100 改成 31000-61000，
    # 段宽从 100 变成 30000，远超必要范围。
    local width=$(( HY2_PORT_END - HY2_PORT_START ))
    (( width < 100 )) && width=100
    local old_start="$HY2_PORT_START" old_end="$HY2_PORT_END"

    HY2_PORT_START=$(( HY2_PORT_START + 1000 ))
    (( HY2_PORT_START + width > 65000 )) && HY2_PORT_START=20000
    HY2_PORT_END=$(( HY2_PORT_START + width ))
    ok "端口段 ${old_start}-${old_end} → ${HY2_PORT_START}-${HY2_PORT_END}（宽度 ${width}）"

    # 清掉旧端口段的 INPUT 规则，否则旧规则永久残留
    if have_iptables; then
      iptables -D INPUT -p udp --dport "${old_start}:${old_end}" -j ACCEPT 2>/dev/null || true
      iptables -D INPUT -p tcp --dport "${old_start}:${old_end}" -j ACCEPT 2>/dev/null || true
    fi
  fi
  save_env
  write_config || die "配置生成失败"
  # rotate 后必须重新放行新端口（原来漏了这步，新段实际不通）
  open_ports || true
  if ! restart_service; then
    warn "重启失败"
    return 1
  fi
  print_links
}

uninstall_all(){
  [[ "$EUID" -eq 0 ]] || die "请以 root 运行"
  warn "将删除 ${HY_DIR}、${BIN_PATH} 与 systemd 单元"
  read -rp "确认？输入 yes: " a
  [[ "$a" == "yes" ]] || { info "已取消"; return 0; }
  have_systemd && { systemctl stop "$SYSTEMD_SERVICE" 2>/dev/null || true
                    systemctl disable "$SYSTEMD_SERVICE" 2>/dev/null || true; }
  rm -f "${SYSTEMD_UNIT_DIR}/${SYSTEMD_SERVICE}"
  have_systemd && systemctl daemon-reload 2>/dev/null || true
  rm -rf -- "$HY_DIR"
  rm -f -- "$BIN_PATH" "${BIN_PATH}.bak"
  ok "已卸载"
}

selftest(){
  local fail=0
  echo "=== SBP-Hy2 自检 ==="
  echo -n "bash 语法: "; bash -n "$0" && echo OK || { echo FAIL; fail=1; }
  echo -n "架构探测: "; echo "$(hy_arch)"
  echo -n "版本比较: "
  if version_lt 2.13.0 2.14.0 && ! version_lt 2.14.0 2.14.0; then echo OK
  else echo FAIL; fail=1; fi
  echo -n "urlenc: "
  [[ "$(urlenc 'a b/c+d=')" == "a%20b%2Fc%2Bd%3D" ]] && echo OK || { echo FAIL; fail=1; }
  echo -n "yaml 转义: "
  [[ "$(yaml_escape 'a"b')" == '"a\"b"' ]] && echo OK || { echo "FAIL($(yaml_escape 'a"b'))"; fail=1; }
  echo -n "配置渲染: "
  if have jq; then
    AUTH_PASSWORD="${AUTH_PASSWORD:-selftest}"
    OBFS_PASSWORD="${OBFS_PASSWORD:-selftest}"
    TLS_DOMAIN="${TLS_DOMAIN:-example.com}"
    TLS_EMAIL="${TLS_EMAIL:-a@b.com}"
    local out
    out="$(render_config 2>/dev/null)"
    if printf '%s' "$out" | grep -q '^listen:' && printf '%s' "$out" | grep -q '^auth:'; then
      echo OK
    else echo FAIL; fail=1; fi
  else echo "SKIP（无 jq）"; fi
  echo -n "gecko 参数边界: "
  local sm="$GECKO_MIN" sx="$GECKO_MAX"
  GECKO_MIN=2000; GECKO_MAX=5000; validate_params 2>/dev/null
  if (( GECKO_MAX <= 2048 )); then echo OK; else echo FAIL; fail=1; fi
  GECKO_MIN="$sm"; GECKO_MAX="$sx"
  echo
  (( fail == 0 )) && { ok "全部通过"; return 0; } || { warn "有失败项"; return 1; }
}

usage(){
  cat <<EOF
SBP-Hy2 ${SCRIPT_VERSION} —— 官方 Hysteria 2 部署（Hy2 做主力）

用法：
  sudo bash sbp-hy2.sh               交互菜单
  sudo bash sbp-hy2.sh deploy        一键部署
  sudo bash sbp-hy2.sh status        查看状态
  sudo bash sbp-hy2.sh links         打印节点链接
  sudo bash sbp-hy2.sh rotate        换端口
  sudo bash sbp-hy2.sh render        仅输出 YAML（免 root）
  sudo bash sbp-hy2.sh selftest      自检（免 root）
  sudo bash sbp-hy2.sh uninstall     彻底卸载

关键变量：
  TLS_MODE          acme（自动证书，需域名）/ manual（自备证书）默认 acme
  TLS_DOMAIN        ACME 域名，TLS_MODE=acme 时必填
  TLS_EMAIL         ACME 邮箱（建议填）
  OBFS_TYPE         gecko（默认）/ salamander / none
  OBFS_PASSWORD     混淆密码，留空自动生成
  HY2_LISTEN       监听地址，默认 :443（UDP）
  ENABLE_PORT_HOP   true 启用端口段跳跃（需 root + nft/iptables）
  HY2_PORT_START/END  跳跃端口段，默认 20000-50000
  MASQ_TYPE         proxy（默认）/ file / string
  MASQ_URL          proxy 模式回源地址
  ENABLE_LISTEN_HTTP/HTTPS  额外监听 TCP 80/443 模拟真站点双栈
  CONGESTION_TYPE   bbr（默认）/ reno；填 BW_UP/BW_DOWN 则用 Brutal
  BW_UP / BW_DOWN   Brutal 带宽，如 "100 mbps"
  ENABLE_ACL        true 启用 ACL 分流
  ACL_REJECT_CN     true 拒绝 geoip:cn
  TRAFFIC_STATS_PORT/SECRET  流量统计 API
  HY2_BIN           本地已解压二进制路径
  HY_SOURCE         repo（本仓库，默认）/ release（官方）
EOF
}

menu(){
  while :; do
    echo
    echo "============================================================"
    printf " ${C_BOLD}SBP-Hy2 %s${C_RESET}\n" "$SCRIPT_VERSION"
    echo "============================================================"
    echo "  1) 一键部署"
    echo "  2) 查看状态"
    echo "  3) 查看节点链接"
    echo "  4) 重启服务"
    echo "  5) 换端口"
    echo "  6) 自检"
    echo "  7) 彻底卸载"
    echo "  0) 退出"
    read -rp "选择: " op || exit 0
    case "${op:-}" in
      1) deploy ;;
      2) show_status ;;
      3) load_env 2>/dev/null || die "尚未部署"; print_links ;;
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
  local cmd="${1:-}"; shift || true

  # 支持 `bash sbp-hy2.sh deploy TLS_DOMAIN=xxx TLS_EMAIL=yyy` 这种写法。
  # 原来是直接丢弃位置参数，导致文档里的用法静默失效（audit 发现）。
  local kv
  for kv in "$@"; do
    if [[ "$kv" =~ ^[A-Z_][A-Z0-9_]*= ]]; then
      export "$kv"
    else
      warn "忽略无法识别的参数：$kv（应为 VAR=VALUE 形式）"
    fi
  done

  case "$cmd" in
    "") menu ;;
    deploy) deploy ;;
    status) show_status ;;
    links) load_env 2>/dev/null || die "尚未部署"; print_links ;;
    rotate) rotate_ports ;;
    uninstall) uninstall_all ;;
    render)
      load_env 2>/dev/null || true
      validate_params
      AUTH_PASSWORD="${AUTH_PASSWORD:-placeholder}"
      OBFS_PASSWORD="${OBFS_PASSWORD:-placeholder}"
      TLS_DOMAIN="${TLS_DOMAIN:-example.com}"
      TLS_EMAIL="${TLS_EMAIL:-admin@example.com}"
      render_config ;;
    selftest) selftest ;;
    -h|--help|help) usage ;;
    *) echo "未知参数：$cmd" >&2; usage >&2; return 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
