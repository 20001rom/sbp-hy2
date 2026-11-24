# SBP-Lite

单台 VPS 的代理节点部署脚本。**全程不调用包管理器**，二进制已在仓库里解压好。

[English](README.en.md)

## 两个脚本

| 脚本 | 协议 | 传输 | 默认端口 | 用途 |
|---|---|---|---|---|
| `sbp-hy2.sh` | Hysteria 2（官方） | UDP | 35543 | 主力，快、抗丢包 |
| `sbp-xray.sh` | Xray-core | TCP | 443 | 备用，Reality 能穿封 UDP 的网络 |

`sbp.sh` 是统一入口，能同时管理两套节点。

两者传输层不同，443 端口不冲突。

## 快速开始

```bash
# Hysteria 2（需域名已解析到本机，80 端口可达）
sudo bash sbp-hy2.sh deploy \
     TLS_DOMAIN=your.domain \
     TLS_EMAIL=you@mail.com

# Xray Reality（无需域名）
sudo bash sbp-xray.sh deploy
```

## 为什么预置二进制

Xray 官方只发布 `.zip`。极简 Debian 镜像同时缺 `unzip` / `busybox` / `python3`，`perl-base` 也不带 `Compress::Raw::Zlib`——实测在那种系统上没有可靠办法解开 Xray 的 zip。

所以把解压这一步提前到打包阶段：

```
仓库里的 bin/xray-linux-64（35 MB，已解压）
        ↓ 服务器只需下载 + chmod
/usr/local/bin/xray
```

代价是仓库里多了几十 MB，换来服务器端零依赖、零解压、一次成功。

---

# SBP-Hy2

官方 [Hysteria 2](https://github.com/apernet/hysteria) 部署脚本。

## 为什么用官方版

Xray 26.x 内置的 Hysteria2 只有传输层，官方版才有混淆、端口跳跃、ACL 分流、masquerade 等能力。没有混淆，Hy2 只能伪装成标准 HTTP/3。

| 能力 | 官方 | Xray |
|---|---|---|
| gecko / salamander 混淆 | ✅ | ❌ |
| 端口跳跃（自动配 nft/iptables） | ✅ | ❌ |
| ACL 分流 | ✅ | ❌ |
| masquerade 伪装 | ✅ | ❌ |
| sniGuard | ✅ | ❌ |
| Brutal 精细调参 | ✅ | ⚠️ 粗粒度 |
| 流量统计 API | ✅ | ❌ |

## 关键取舍

### 混淆与 masquerade 互斥

官方文档：启用混淆后服务器不再是合法的 HTTP/3 服务端（*will no longer function as a valid HTTP/3 server*）。探测者发 H3 握手得不到回应，masquerade 不触发。

| 目标 | 配置 |
|---|---|
| 防主动探测 | `OBFS_TYPE=none` + `MASQ_TYPE=file`（默认） |
| 对抗封 QUIC | `OBFS_TYPE=gecko`，接受 masquerade 失效 |

默认 `none`：保留 H3 伪装，且 gecko 在 GFW 环境下没有公开实测数据，v2.14.0 上另有 GSO 丢失的性能缺陷（[issue #1724](https://github.com/apernet/hysteria/issues/1724)）。

脚本在同时开混淆和 masquerade 时会警告。

### 端口默认 35543 而非 443

1. GFW 的 QUIC 审查只处理「源端口 > 目的端口」的 UDP 包（[USENIX Security '25 §3.3](https://gfw.report/publications/usenixsecurity25/en/)）。服务端端口 ≥32768 时，客户端临时端口必然更低，该流落在审查之外。
2. 电信 AS4134 对 UDP/443 有与协议无关的限速：连接建立后 10–30 秒内降到 1–5 Mbps。

改回 443：`HY2_LISTEN=:443`。

### BBR 而非 Brutal

[FOCI 2025](https://www.petsymposium.org/foci/2025/foci-2025-0001.pdf) 用 10,080 条流测试，两阶段阈值分类器识别 Brutal 1257/1260，BBR 误报仅 16 条。判据是「丢包后是否退让」。

Brutal 的加速优势建立在可被被动识别的行为上。代价是 30% 丢包下单流 98 Mbps vs BBR 31 Mbps。仅在确认链路丢包 >10% 且不经过 GFW 判定点时才开（`BW_UP`/`BW_DOWN`）。

## 部署

```bash
# ACME 自动证书
sudo bash sbp-hy2.sh deploy \
     TLS_DOMAIN=your.domain \
     TLS_EMAIL=you@mail.com

# 自备证书
sudo bash sbp-hy2.sh deploy \
     TLS_MODE=manual \
     TLS_CERT=/etc/letsencrypt/live/your.domain/fullchain.pem \
     TLS_KEY=/etc/letsencrypt/live/your.domain/privkey.pem

# 离线（二进制已在仓库内）
sudo HY2_BIN=/tmp/hysteria bash sbp-hy2.sh deploy ...
```

## 命令

```bash
sudo bash sbp-hy2.sh deploy      # 部署
sudo bash sbp-hy2.sh status      # 状态
sudo bash sbp-hy2.sh links       # 节点链接
sudo bash sbp-hy2.sh rotate      # 换端口
bash sbp-hy2.sh render           # 只输出 YAML（免 root）
bash sbp-hy2.sh selftest         # 自检（免 root）
sudo bash sbp-hy2.sh uninstall   # 卸载
```

## 变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `TLS_MODE` | `acme` | `acme` / `manual` |
| `TLS_DOMAIN` | — | ACME 模式必填 |
| `TLS_EMAIL` | — | ACME 邮箱 |
| `HY2_LISTEN` | `:35543` | 监听地址（UDP） |
| `OBFS_TYPE` | `none` | `none` / `salamander` / `gecko` |
| `OBFS_PASSWORD` | 自动生成 | 混淆密码 |
| `GECKO_MIN` / `GECKO_MAX` | `512` / `1200` | 握手分片大小（字节） |
| `ENABLE_PORT_HOP` | `false` | 端口跳跃 |
| `HY2_PORT_START` / `HY2_PORT_END` | `20000` / `50000` | 跳跃端口段 |
| `MASQ_TYPE` | `file` | `file` / `proxy` / `string` / `none` |
| `MASQ_URL` | `https://www.bing.com` | proxy 模式回源 |
| `ENABLE_LISTEN_HTTP` / `ENABLE_LISTEN_HTTPS` | `false` | 额外监听 TCP 80 / 443 |
| `CONGESTION_TYPE` | `bbr` | `bbr` / `reno` |
| `BBR_PROFILE` | `standard` | `standard` / `conservative` / `aggressive` |
| `BW_UP` / `BW_DOWN` | — | 填了启用 Brutal，如 `100 mbps` |
| `ENABLE_ACL` | `false` | ACL 分流 |
| `ACL_REJECT_CN` | `false` | 拒绝 geoip:cn |
| `WARP_ENABLED` | `false` | 第二个账号走本地 SOCKS5 |
| `WARP_SOCKS_ADDR` | `127.0.0.1:40000` | WARP 出口地址 |
| `WARP_AUTH_USER` | `warp` | WARP 账号名 |
| `WARP_AUTH_PASS` | 自动生成 | WARP 账号密码 |
| `TRAFFIC_STATS_PORT` | — | 流量统计 API 端口 |

## WARP 分流

`WARP_ENABLED=true` 时生成 `userpass` 双账号，服务端按 `auth.id` 分流：

```
main 账号 → direct 直连
warp 账号 → socks5 → 127.0.0.1:40000（通常是 sing-box 的 WARP 出口）
```

`listen` 是单值字段，一个实例只能监听一个端口。双账号共用同一端口，客户端切节点即可换出口。

前置条件是本机有 SOCKS5 出口指向 WARP，例如 sing-box：

```json
{
  "inbounds": [{ "type": "mixed", "listen": "127.0.0.1", "listen_port": 40000 }],
  "endpoints": [{
    "type": "wireguard",
    "tag": "warp",
    "address": ["172.16.0.2/32"],
    "private_key": "<私钥>",
    "peers": [{
      "address": "engage.cloudflareclient.com",
      "port": 2408,
      "public_key": "<公钥>",
      "allowed_ips": ["0.0.0.0/0"],
      "persistent_keepalive_interval": 25
    }]
  }],
  "outbounds": [{ "type": "direct", "tag": "direct" }],
  "route": { "final": "warp" }
}
```

## 端口跳跃

```bash
sudo ENABLE_PORT_HOP=true HY2_PORT_START=20000 HY2_PORT_END=20100 bash sbp-hy2.sh deploy
```

官方 `listen: :20000-20100` 自动配置 nftables/iptables 把其余端口重定向到第一个，进程退出时清理。

需要 root（或 `CAP_NET_ADMIN`）与 nft/iptables。链接写成 `host:20000,20000-20100` 并带 `mport`。

**端口段的放行要写进 ufw 持久化规则**，否则机器重启后规则丢失：

```bash
sudo ufw allow 20000:20100/udp
```

## masquerade

Hy2 必须带 TLS。认证失败的 HTTP/3 请求不返回错误，而是返回伪装内容——这就是主动探测防御。

| 类型 | 效果 |
|---|---|
| `proxy` | 反代到真站 |
| `file` | 本地静态目录 |
| `string` | 固定 HTML |

### 双栈伪装

真实支持 HTTP/3 的网站通常同时提供 TCP 80/443。只开 QUIC 不开 TCP 本身就是特征。

```bash
sudo ENABLE_LISTEN_HTTP=true ENABLE_LISTEN_HTTPS=true FORCE_HTTPS=true bash sbp-hy2.sh deploy
```

### 默认静态站

`MASQ_TYPE=file` 生成一套完整静态站（index/about/contact/404 + CSS），不是一行 `<h1>It works!</h1>`。站点名取域名首段，无域名时用 `Northwind`。已有 `index.html` 不覆盖。

---

# SBP-Xray

Xray-core 一键部署脚本。

## 核心约束

443 端口独占。两个 Reality 入站不能都绑 443——`run -test` 静态校验查不出来（只看语法），真正启动才报 `bind: address already in use`。

推荐形态：

```
443      → VLESS Reality + Vision   （直连主力）
高位端口  → VLESS XHTTP + TLS        （CDN 回源兜底）
```

## 协议

| 协议 | 默认 | 传输 | 安全层 | 端口 |
|---|---|---|---|---|
| `vless-reality` | 开启 | tcp | reality | 443 |
| `hy2` | 关闭 | hysteria | tls | 高位 UDP |
| `vless-xhttp` | 关闭 | xhttp | 跟随 `XHTTP_SECURITY` | 高位 |
| `trojan` | 关闭 | tcp | tls | 高位 |
| `vless-tls` | 关闭 | tcp | tls | 高位 |

Xray 没有 TUIC v5、AnyTLS（那些是 sing-box 的）。

## Reality dest 校验

**Reality 在认证失败时会把整条连接转发给 dest，探测者看到的就是 dest 的证书。** 所以 dest 的证书质量 = 你的安全性。

部署前强制执行 `verify_dest`，检查 7 项：

| 检查 | 不通过会怎样 |
|---|---|
| dest 可达 | Reality 握手直接失败 |
| TLS 1.3 | Reality 无法工作 |
| ALPN h2 | 无法镜像握手（需显式 `-alpn h2`） |
| X25519 | 密钥交换失败 |
| 证书 `subject != issuer` | 自签证书会被探测者一眼识别 |
| 证书链 ≥ 2 条 | 单证书不像真站 |
| 握手延迟 < 100ms | 太慢会露馅 |

外加拒绝「烧掉的 SNI」（`www.apple.com` / `www.microsoft.com` / `www.lovelive-anime.jp`）。

校验不通过就中止部署。强行继续：`sudo VERIFY_DEST_STRICT=0 bash sbp-xray.sh deploy`。

在服务器上手动验证候选 dest：

```bash
SNI=你的候选域名
openssl s_client -connect "$SNI:443" -servername "$SNI" -tls1_3 </dev/null 2>&1 \
  | grep -E "Protocol|Server Temp Key|ALPN"
curl -s -o /dev/null -w "握手 %{time_connect}s\n" "https://$SNI"
```

最理想的 dest 是与服务器同子网或同 ASN 的站。

## XHTTP

| 模式 | 上行 | 下行 | 适用 |
|---|---|---|---|
| `packet-up` | N 个独立 POST（带序号） | 一条长 GET | 兼容性最强，任何 CDN 都过 |
| `stream-up` | 一条长 POST | 另一条长 GET | 需 H2/H3 |
| `stream-one` | 单个 POST 双向 | 同一条 | 最快，仅 Nginx `grpc_pass`/CF gRPC |

三个坑：

1. **与 Mux 硬冲突**：XHTTP 服务端拒绝启用 Mux 的客户端
2. **CF 掐断空闲下行**：100 秒无数据就断，需 `ClientAliveInterval 30`
3. **维护负担最高**：Xray 频繁破坏性变更

走 CDN 必须真域名 + 真证书，自签证书会让 CDN 回源因证书不受信而失败。

## Xray 变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `REALITY_SERVER` | `www.bing.com` | Reality 伪装目标，**必须自己换** |
| `REALITY_PORT_MODE` | `auto` | `auto`=443 / `random` / `fixed` |
| `UTLS_FP` | `firefox` | uTLS 指纹 |
| `ENABLE_VLESS_REALITY` | `true` | 主协议 |
| `ENABLE_VLESS_XHTTP` | `false` | XHTTP 入站 |
| `XHTTP_SECURITY` | `reality` | `reality` / `tls`（套 CDN）/ `none` |
| `XHTTP_MODE` | `auto` | `auto`/`packet-up`/`stream-up`/`stream-one` |
| `XHTTP_PATH` | 随机 | 请求路径 |
| `XHTTP_PADDING` | `100-1000` | 每次请求随机 padding |
| `ENABLE_FINALMASK` | `false` | FinalMask |
| `FINALMASK_TYPE` | `header-custom` | `header-custom`/`header-dns`/`header-dtls`/`header-srtp`/`header-utp`/`header-wechat`/`header-wireguard` |
| `ENABLE_TCP_FRAGMENT` | `false` | ClientHello 三段分片 |
| `ENABLE_TROJAN` | `false` | Trojan Reality |
| `ENABLE_VLESS_TLS` | `false` | VLESS over TLS（需证书） |
| `ENABLE_HYSTERIA2` | `false` | Xray 内置 Hy2 |
| `HY2_PWD` | 自动生成 | Hy2 认证密码 |
| `HY2_MASQUERADE_TYPE` | `string` | `string` / `proxy` / `file` |
| `TLS_DOMAIN` | — | 证书 CN |
| `TLS_CERT_MODE` | `self_signed` | `self_signed` / `manual` |
| `XRAY_SOURCE` | `repo` | `repo`（本仓库二进制）/ `release`（官方 zip） |
| `XRAY_BIN` | — | 直接用本地已解压二进制 |

---

## 仓库结构

```
sbp-hy2.sh                  Hysteria 2 主脚本
sbp-xray.sh                Xray 主脚本
sbp.sh                     统一入口
lib/masq-site.sh           静态站生成
bin/hysteria-linux-amd64    Hysteria 二进制（24 MB）
bin/xray-linux-64          Xray 二进制（35 MB，已解压）
bin/*.sha256                校验和
tests/                      测试脚本
```

### 更新二进制

```bash
# Hysteria
curl -LO https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64
cp hysteria-linux-amd64 bin/
(cd bin && sha256sum hysteria-linux-amd64 > hysteria.sha256)

# Xray
curl -LO https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
unzip -o Xray-linux-64.zip -d /tmp/xray
cp /tmp/xray/xray bin/xray-linux-64
(cd bin && sha256sum xray-linux-64 > xray.sha256)
/tmp/xray/xray version | head -1 | awk '{print $2}' > bin/VERSION
```

### 多架构

脚本按架构找 `bin/xray-linux-<arch>`。`x86_64` → `64`，`aarch64` → `arm64-v8a`，`armv7` → `arm32-v7a`。只有某个架构的二进制时，脚本对其他架构回退官方 Release（那时才需要 unzip）。

## 已知限制

- **Hysteria 按文件扩展名识别配置**，临时文件必须 `.yaml` 结尾
- **Xray 同理**，临时文件必须 `.json` 结尾
- **没有 `check` 子命令**（Hysteria），只能短暂启动观察日志
- **`run -test` 不检查端口冲突**，只看语法
- **端口跳跃需 root + nft/iptables**
- **ACME 需域名 + 80 端口可达**
- **Hysteria 只支持 UDP**
- **Reality 必须 443**，高位端口的 Reality 是自伤的
- **XHTTP 套 CDN 需真域名 + 真证书**

## License

MIT
