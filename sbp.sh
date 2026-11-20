#!/usr/bin/env bash
# ============================================================
#  SBP —— 统一入口
#  管理两套节点：
#    hy2   官方 Hysteria 2   UDP/443  主力（快，抗丢包）
#    xray  Xray-core         TCP/443  备用（Reality，能穿封 UDP 的网络）
#  两者用不同传输层，443 端口不冲突。
#  Version: v1.0.0
# ============================================================

set -Eeuo pipefail

SBP_VERSION="v1.0.0"
SBP_DIR="${SBP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
HY_SCRIPT="${HY_SCRIPT:-$SBP_DIR/sbp-hy2.sh}"
XR_SCRIPT="${XR_SCRIPT:-$SBP_DIR/sbp-xray.sh}"

HY2_SERVICE="${HY2_SERVICE:-hysteria.service}"
XRAY_SERVICE="${XRAY_SERVICE:-xray.service}"
HY2_ENV="${HY2_ENV:-/etc/hysteria/env.conf}"
XRAY_ENV="${XRAY_ENV:-/usr/local/etc/xray/env.conf}"
HY2_CONF="${HY2_CONF:-/etc/hysteria/config.yaml}"
XRAY_CONF="${XRAY_CONF:-/usr/local/etc/xray/config.json}"

# 主备标记文件：记录哪个是主力
ROLE_FILE="${ROLE_FILE:-/var/lib/sbp-lite/role}"

C_RESET="\033[0m"; C_RED="\033[31m"; C_GREEN="\033[32m"
C_YELLOW="\033[33m"; C_CYAN="\033[36m"; C_BOLD="\033[1m"
info(){ printf "[${C_CYAN}信息${C_RESET}] %s\n" "$*"; }
warn(){ printf "[${C_YELLOW}警告${C_RESET}] %s\n" "$*" >&2; }
die(){  printf "[${C_RED}错误${C_RESET}] %s\n" "$*" >&2; exit 1; }
ok(){   printf "[${C_GREEN}完成${C_RESET}] %s\n" "$*"; }
hr(){   printf "${C_BOLD}%s${C_RESET}\n" "============================================================"; }

have(){ command -v "$1" >/dev/null 2>&1; }
have_systemd(){ [[ -d /run/systemd/system ]] && have systemctl; }

# ===== 组装检查 =====
# 两个组件是可选的：只发布 Hy2 时没有 sbp-xray.sh，
# 不能因此让 sbp.sh 整体不可用。缺哪个就跳过哪个。
have_hy2(){ [[ -f "$HY_SCRIPT" ]]; }
have_xray(){ [[ -f "$XR_SCRIPT" ]]; }

require_component(){
  local which="$1"
  case "$which" in
    hy2)  have_hy2  || die "缺少 $HY_SCRIPT" ;;
    xray) have_xray || die "缺少 $XR_SCRIPT（本仓库可能只包含 Hy2）" ;;
    all)
      have_hy2 || have_xray || die "缺少全部组件脚本"
      ;;
  esac
}

# ===== 服务状态 =====
svc_state(){
  local svc="$1"
  if have_systemd; then
    systemctl is-active "$svc" 2>/dev/null || true
  else
    echo "no-systemd"
  fi
}

# ===== 端口占用 =====
port_used(){
  local p="$1" proto="$2"
  have ss || return 1
  if [[ "$proto" == "udp" ]]; then
    ss -Huln 2>/dev/null | grep -qE "[:.]${p}[[:space:]]"
  else
    ss -Htln 2>/dev/null | grep -qE "[:.]${p}[[:space:]]"
  fi
}

# ===== 主备角色 =====
get_role(){
  if [[ -f "$ROLE_FILE" ]]; then
    tr -d '\n' < "$ROLE_FILE"
  else
    echo "hy2"
  fi
}
set_role(){
  local r="$1"
  case "$r" in
    hy2|xray) ;;
    *) die "角色只能是 hy2 或 xray" ;;
  esac
  mkdir -p "$(dirname "$ROLE_FILE")"
  printf '%s' "$r" > "$ROLE_FILE"
  ok "主力已设为 ${r}"
}

# ===== 查看状态 =====
show_status(){
  local role; role="$(get_role)"
  hr
  printf " ${C_BOLD}SBP %s${C_RESET}  主力: ${C_GREEN}%s${C_RESET}\n" "$SBP_VERSION" "$role"
  hr

  local hs xs
  hs="$(svc_state "$HY2_SERVICE")"
  xs="$(svc_state "$XRAY_SERVICE")"

  printf "  %-6s %-16s %-12s %s\n" "组件" "服务" "状态" "端口"
  local hmark=" " xmark=" "
  [[ "$role" == "hy2" ]] && hmark="*"
  [[ "$role" == "xray" ]] && xmark="*"

  local hyport="(未装)" xport="(未装)"
  if [[ -f "$HY2_ENV" ]]; then
    local l; l="$(grep -E '^HY2_LISTEN=' "$HY2_ENV" 2>/dev/null | cut -d= -f2- || true)"
    hyport="${l:-:443} (udp)"
  fi
  if [[ -f "$XRAY_CONF" ]] && have jq; then
    xport="$(jq -r '.inbounds[]?|select(.tag=="vless-reality")|.port' "$XRAY_CONF" 2>/dev/null | head -1 || true)"
    xport="${xport:-?} (tcp)"
  fi

  printf " %s%-6s %-16s %-12s %s\n" "$hmark" "hy2" "$HY2_SERVICE" "$hs" "$hyport"
  printf " %s%-6s %-16s %-12s %s\n" "$xmark" "xray" "$XRAY_SERVICE" "$xs" "$xport"
  hr

  # 端口冲突提醒
  local tcp443=false udp443=false
  port_used 443 udp && udp443=true
  port_used 443 tcp && tcp443=true
  echo "  443 占用: TCP=$([[ "$tcp443" == true ]] && echo 是 || echo 否)  UDP=$([[ "$udp443" == true ]] && echo 是 || echo 否)"
  echo "  （TCP 与 UDP 的 443 可同时使用，互不冲突）"
  echo

  if [[ "$hs" != "active" && "$xs" != "active" ]]; then
    warn "两套都未运行"
  fi
}

# ===== 打印全部链接 =====
show_links(){
  local got=0
  if have_hy2; then
    hr; echo " Hy2 节点"; hr
    if [[ -f "$HY2_ENV" ]]; then
      bash "$HY_SCRIPT" links 2>/dev/null | grep -E '^hysteria2://' && got=1 || echo "  （无）"
    else
      echo "  （未部署）"
    fi
    echo
  fi
  if have_xray; then
    hr; echo " Xray 节点"; hr
    if [[ -f "$XRAY_ENV" ]]; then
      bash "$XR_SCRIPT" links 2>/dev/null | grep -E '^(vless|trojan)://' && got=1 || echo "  （无）"
    else
      echo "  （未部署）"
    fi
    echo
  fi
  (( got == 1 )) || warn "没有可用的节点链接，先部署"
}

# ===== 部署前检查 =====
precheck(){
  local target="$1"
  local problems=0

  if [[ "$target" == "hy2" || "$target" == "all" ]]; then
    # Hy2 需要 UDP 443（或配置的端口）
    if port_used 443 udp && [[ "$(svc_state "$HY2_SERVICE")" != "active" ]]; then
      warn "UDP/443 已被其他进程占用（Hy2 需要它）"
      ss -Hulnp 2>/dev/null | grep -E '[:.]443[[:space:]]' | head -2 | sed 's/^/    /' >&2 || true
      problems=$((problems+1))
    fi
  fi

  if [[ "$target" == "xray" || "$target" == "all" ]]; then
    if port_used 443 tcp && [[ "$(svc_state "$XRAY_SERVICE")" != "active" ]]; then
      warn "TCP/443 已被其他进程占用（Reality 需要它）"
      ss -Htlnp 2>/dev/null | grep -E '[:.]443[[:space:]]' | head -2 | sed 's/^/    /' >&2 || true
      problems=$((problems+1))
    fi
  fi

  (( problems == 0 ))
}

# ===== 安装 =====
install_one(){
  local which="$1"; shift
  case "$which" in
    hy2)
      [[ -f "$HY_SCRIPT" ]] || die "缺少 $HY_SCRIPT"
      info "部署 Hy2（UDP/443，主力）"
      bash "$HY_SCRIPT" deploy "$@"
      ;;
    xray)
      have_xray || die "缺少 $XR_SCRIPT（本仓库可能只包含 Hy2）"
      info "部署 Xray（TCP/443，备用）"
      bash "$XR_SCRIPT" deploy "$@"
      ;;
    *) die "未知组件：$which（可选 hy2 / xray / all）" ;;
  esac
}

cmd_install(){
  local target="${1:-all}"; shift || true
  [[ "$EUID" -eq 0 || -n "${SBP_TEST_ROOT:-}" ]] || die "请以 root 运行（或 sudo）"

  hr
  printf " ${C_BOLD}SBP %s 安装${C_RESET}  目标: ${target}\n" "$SBP_VERSION"
  hr

  case "$target" in
    hy2|xray|all) ;;
    *) die "用法: install [hy2|xray|all]" ;;
  esac

  precheck "$target" || warn "存在端口占用，继续尝试（可能失败）"

  if [[ "$target" == "all" ]]; then
    echo
    if have_hy2; then
      info "=== 1/2 Hy2（主力）==="
      # Hy2 失败不阻断 Xray：两者独立
      if ! install_one hy2 "$@"; then
        warn "Hy2 部署失败，继续"
      fi
    else
      warn "本仓库没有 sbp-hy2.sh，跳过 Hy2"
    fi
    echo
    if have_xray; then
      info "=== 2/2 Xray（备用）==="
      if ! install_one xray "$@"; then
        warn "Xray 部署失败"
      fi
    else
      warn "本仓库没有 sbp-xray.sh，跳过 Xray（只装了 Hy2 的话这是正常的）"
    fi
    set_role hy2   # 默认 Hy2 主力
  else
    require_component "$target"
    install_one "$target" "$@"
    set_role "$target"
  fi

  echo
  show_status
  echo
  show_links
}

# ===== 启动/停止/重启 =====
svc_action(){
  local action="$1" target="${2:-all}"
  [[ "$EUID" -eq 0 || -n "${SBP_TEST_ROOT:-}" ]] || die "请以 root 运行"
  have_systemd || die "无 systemd，无法管理服务"

  local svcs=()
  case "$target" in
    hy2)  svcs=("$HY2_SERVICE") ;;
    xray) svcs=("$XRAY_SERVICE") ;;
    all)  svcs=("$HY2_SERVICE" "$XRAY_SERVICE") ;;
    *) die "用法: $action [hy2|xray|all]" ;;
  esac

  local s
  for s in "${svcs[@]}"; do
    if ! systemctl list-unit-files 2>/dev/null | grep -q "^${s}"; then
      warn "${s} 未安装，跳过"
      continue
    fi
    case "$action" in
      start)   systemctl start   "$s" && ok "${s} 已启动" || warn "${s} 启动失败" ;;
      stop)    systemctl stop    "$s" && ok "${s} 已停止" || warn "${s} 停止失败" ;;
      restart) systemctl restart "$s" && ok "${s} 已重启" || warn "${s} 重启失败" ;;
      enable)  systemctl enable --now "$s" && ok "${s} 已启用" || warn "${s} 启用失败" ;;
      disable) systemctl disable "$s" 2>/dev/null; ok "${s} 已禁用开机启动" ;;
    esac
  done
}

# ===== 切换主备 =====
cmd_switch(){
  local target="${1:-}"
  local role; role="$(get_role)"

  if [[ -z "$target" ]]; then
    # 无参数：显示当前并提示用法
    echo "当前主力: ${role}"
    echo "用法: switch [hy2|xray]"
    echo
    echo "主备的含义："
    echo "  · 两套可以同时运行，客户端按需选择"
    echo "  · 标记为'主力'的只是提示你优先用哪个"
    echo "  · 真正切换时，客户端要换节点链接"
    return 0
  fi

  case "$target" in
    hy2)
      set_role hy2
      info "现在建议优先使用 Hy2（UDP/443，快、抗丢包）"
      info "Xray 仍在运行，可作为备用"
      ;;
    xray)
      set_role xray
      info "现在建议优先使用 Xray（TCP/443，Reality 伪装）"
      info "Hy2 仍在运行，可作为备用"
      ;;
    *) die "用法: switch [hy2|xray]" ;;
  esac

  echo
  show_links
}

# ===== 一键换端口 =====
cmd_rotate(){
  local target="${1:-all}"
  [[ "$EUID" -eq 0 || -n "${SBP_TEST_ROOT:-}" ]] || die "请以 root 运行"
  case "$target" in
    hy2)  bash "$HY_SCRIPT" rotate ;;
    xray) have_xray || die "缺少 $XR_SCRIPT"; bash "$XR_SCRIPT" rotate ;;
    all)
      info "=== Hy2 换端口 ==="; bash "$HY_SCRIPT" rotate || warn "Hy2 换端口失败"
      echo
      if have_xray; then info "=== Xray 换端口 ==="; bash "$XR_SCRIPT" rotate || warn "Xray 换端口失败"; else warn "本仓库没有 Xray，跳过"; fi
      ;;
    *) die "用法: rotate [hy2|xray|all]" ;;
  esac
}

# ===== 自检 =====
cmd_selftest(){
  hr; printf " ${C_BOLD}SBP %s 自检${C_RESET}\n" "$SBP_VERSION"; hr
  local fail=0

  echo -n "bash 语法: "; bash -n "$0" && echo OK || { echo FAIL; fail=1; }
  echo -n "hy2 脚本: ";  [[ -f "$HY_SCRIPT" ]] && echo "存在" || { echo "缺失"; fail=1; }
  echo -n "xray 脚本: "; [[ -f "$XR_SCRIPT" ]] && echo "存在" || echo "缺失（只发布 Hy2 时正常）"

  echo -n "hy2 自检: "
  if [[ -f "$HY_SCRIPT" ]]; then
    if bash "$HY_SCRIPT" selftest >/dev/null 2>&1; then echo OK; else echo FAIL; fail=1; fi
  else echo SKIP; fi

  echo -n "xray 自检: "
  if [[ -f "$XR_SCRIPT" ]]; then
    if bash "$XR_SCRIPT" selftest >/dev/null 2>&1; then echo OK; else echo FAIL; fail=1; fi
  else echo SKIP; fi

  echo -n "端口不冲突（TCP vs UDP）: "
  echo "OK（不同传输层，443 可共存）"

  echo -n "主备记录: "
  if [[ -f "$ROLE_FILE" ]]; then echo "$(get_role)"; else echo "未设置（默认 hy2）"; fi

  echo
  if (( fail == 0 )); then ok "全部通过"; return 0; else warn "有失败项"; return 1; fi
}

# ===== 卸载 =====
cmd_uninstall(){
  local target="${1:-}"
  [[ "$EUID" -eq 0 ]] || die "请以 root 运行"
  case "$target" in
    hy2)  bash "$HY_SCRIPT" uninstall ;;
    xray) have_xray || die "缺少 $XR_SCRIPT"; bash "$XR_SCRIPT" uninstall ;;
    all)
      warn "将卸载 Hy2 和 Xray 两套"
      read -rp "确认？输入 yes: " a
      [[ "$a" == "yes" ]] || { info "已取消"; return 0; }
      bash "$HY_SCRIPT" uninstall <<< "yes" || true
      have_xray && bash "$XR_SCRIPT" uninstall <<< "yes" || true
      rm -f "$ROLE_FILE"
      ok "已全部卸载"
      ;;
    *) die "用法: uninstall [hy2|xray|all]" ;;
  esac
}

# ===== 诊断 =====
cmd_diagnose(){
  hr; printf " ${C_BOLD}SBP %s 诊断${C_RESET}\n" "$SBP_VERSION"; hr

  echo "=== 系统 ==="
  (. /etc/os-release 2>/dev/null && echo "  发行版: $PRETTY_NAME") || true
  echo "  内核: $(uname -r)"
  echo "  systemd: $(have_systemd && echo 可用 || echo 不可用)"
  echo "  iptables: $(have iptables && echo 有 || echo 无)"
  echo "  nft: $(have nft && echo 有 || echo 无)"

  echo
  echo "=== 端口 ==="
  for pp in "443 udp" "443 tcp" "80 tcp"; do
    set -- $pp
    if port_used "$1" "$2"; then
      echo "  $1/$2: 已占用"
    else
      echo "  $1/$2: 空闲"
    fi
  done

  echo
  echo "=== 服务 ==="
  for s in "$HY2_SERVICE" "$XRAY_SERVICE"; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${s}"; then
      printf '  %-18s %s\n' "$s" "$(svc_state "$s")"
    else
      printf '  %-18s 未安装\n' "$s"
    fi
  done

  echo
  echo "=== 最近日志 ==="
  for s in "$HY2_SERVICE" "$XRAY_SERVICE"; do
    if [[ "$(svc_state "$s")" == "active" ]]; then
      echo "  --- $s ---"
      journalctl -u "$s" --no-pager -n 3 2>/dev/null | sed 's/^/    /' || true
    fi
  done

  echo
  echo "=== 结论 ==="
  local hs xs
  hs="$(svc_state "$HY2_SERVICE")"; xs="$(svc_state "$XRAY_SERVICE")"
  if [[ "$hs" == "active" || "$xs" == "active" ]]; then
    ok "至少一套在运行"
  else
    warn "没有任何一套在运行"
  fi
}

usage(){
  cat <<EOF
SBP ${SBP_VERSION} —— 统一入口（Hy2 主力 + Xray 备用）

用法：
  sudo bash sbp.sh install [hy2|xray|all]   部署（默认 all）
  sudo bash sbp.sh status                   查看两套状态
  sudo bash sbp.sh links                    打印全部节点链接
  sudo bash sbp.sh switch [hy2|xray]        标记主力
  sudo bash sbp.sh start   [hy2|xray|all]   启动
  sudo bash sbp.sh stop    [hy2|xray|all]   停止
  sudo bash sbp.sh restart [hy2|xray|all]   重启
  sudo bash sbp.sh rotate  [hy2|xray|all]   换端口
  sudo bash sbp.sh diagnose                 诊断
  bash sbp.sh selftest                      自检（免 root）
  sudo bash sbp.sh uninstall [hy2|xray|all] 卸载

组件：
  hy2   官方 Hysteria 2   UDP/443  gecko 混淆，快、抗丢包
  xray  Xray-core         TCP/443  VLESS Reality，伪装强

为什么能共存：
  TCP 和 UDP 的 443 是两个独立的端口空间，互不冲突。
  客户端按需选：UDP 通就用 Hy2，UDP 被封就切 Reality。

透传给子脚本的环境变量：
  Hy2:  TLS_DOMAIN TLS_EMAIL OBFS_TYPE MASQ_TYPE ENABLE_PORT_HOP ...
  Xray: REALITY_SERVER ENABLE_VLESS_XHTTP ENABLE_HYSTERIA2 ...

示例：
  # 两套都装，Hy2 自动证书，Xray 自定义 SNI
  sudo TLS_DOMAIN=my.domain TLS_EMAIL=a@b.com REALITY_SERVER=www.samsung.com \\
       bash sbp.sh install all

  # 只装 Hy2
  sudo TLS_DOMAIN=my.domain bash sbp.sh install hy2

  # 查看所有链接
  bash sbp.sh links
EOF
}

menu(){
  while :; do
    echo
    hr
    printf " ${C_BOLD}SBP %s${C_RESET}  主力: ${C_GREEN}%s${C_RESET}\n" "$SBP_VERSION" "$(get_role)"
    hr
    echo "  1) 部署两套（Hy2 + Xray）"
    echo "  2) 只部署 Hy2（UDP/443 主力）"
    echo "  3) 只部署 Xray（TCP/443 备用）"
    echo "  --------------------------------------------"
    echo "  4) 查看状态"
    echo "  5) 查看节点链接"
    echo "  6) 切换主力"
    echo "  7) 重启两套"
    echo "  --------------------------------------------"
    echo "  8) 诊断"
    echo "  9) 自检"
    echo " 10) 换端口"
    echo " 11) 卸载"
    echo "  0) 退出"
    hr
    read -rp "选择: " op || exit 0
    case "${op:-}" in
      1) cmd_install all ;;
      2) cmd_install hy2 ;;
      3) cmd_install xray ;;
      4) show_status ;;
      5) show_links ;;
      6) cmd_switch ;;
      7) svc_action restart all ;;
      8) cmd_diagnose ;;
      9) cmd_selftest ;;
      10) cmd_rotate all ;;
      11) cmd_uninstall ;;
      0|q|Q) exit 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

main(){
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    "")            menu ;;
    install|deploy) cmd_install "${1:-all}" "${@:2}" ;;
    status)        show_status ;;
    links)         show_links ;;
    switch)        cmd_switch "${1:-}" ;;
    start)         svc_action start   "${1:-all}" ;;
    stop)          svc_action stop    "${1:-all}" ;;
    restart)       svc_action restart "${1:-all}" ;;
    enable)        svc_action enable  "${1:-all}" ;;
    disable)       svc_action disable "${1:-all}" ;;
    rotate)        cmd_rotate "${1:-all}" ;;
    diagnose|diag) cmd_diagnose ;;
    selftest)      cmd_selftest ;;
    uninstall)     cmd_uninstall "${1:-}" ;;
    -h|--help|help) usage ;;
    *) echo "未知参数：$cmd" >&2; usage >&2; return 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
