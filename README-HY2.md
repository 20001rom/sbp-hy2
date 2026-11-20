# SBP-Hy2

官方 [Hysteria 2](https://github.com/apernet/hysteria) 的部署脚本，**Hy2 做主力节点**。无包管理器依赖。

## 为什么用官方版而不是 Xray 内置的 Hy2

Xray 26.x 也有 Hysteria2 传输，但只有基础功能。官方版才有：

| 能力 | 官方 Hysteria 2 | Xray 的 Hy2 |
|---|---|---|
| **gecko 混淆** | ✅ | ❌ |
| **salamander 混淆** | ✅ | ❌ |
| **端口跳跃**（自动配 nft/iptables） | ✅ | ❌ 要手写 |
| **ACL 分流** | ✅ | ❌ |
| **HTTP/command 认证** | ✅ | ❌ |
| **mimic（假 TCP）** | ✅ | ❌ |
| **ECH** | ✅ | ❌ |
| **sniGuard**（防域名冒用） | ✅ | ❌ |
| **Brutal 精细调参** | ✅ | ⚠️ 粗粒度 |
| **流量统计 API** | ✅ | ❌ |

**主力节点必须用官方版**——没有混淆，Hy2 只能伪装成 HTTP/3，一旦被针对性识别就没有退路。

## 核心特点

```
UDP/35543 → Hysteria 2
            ├── 无混淆（默认，保留 HTTP/3 伪装）
            ├── masquerade=file（主动探测返回静态页）
            └── BBR 拥塞控制
```

**为什么默认端口是 35543 而不是 443**（有论文依据）：

1. GFW 的 QUIC 审查只处理「**源端口 > 目的端口**」的 UDP 包（[USENIX Security '25 §3.3](https://gfw.report/publications/usenixsecurity25/en/)）。这条规则覆盖 92.3% 的 QUIC Initial，却只需检查 30% 的 UDP 包。服务端端口 ≥32768 时，客户端临时端口必然更低，该流直接落在 GFW 的解密流程之外。
2. 电信 AS4134 等对 UDP/443 有**与协议无关的限速**：连接建立后 10–30 秒内骤降到 1–5 Mbps。实测改 8443 后回到 20 Mbps。

要改回 443：`HY2_LISTEN=:443`。

## 混淆 vs masquerade：必须二选一

这是本方案**最重要的一个权衡**，官方文档和实测都确认：

> 启用任何混淆后，服务器不再是合法的 HTTP/3 服务端（官方原话：*will no longer function as a valid HTTP/3 server*）。

后果：探测者发标准 HTTP/3 握手时**得不到回应**，masquerade 永远不会被触发。

| 你的目标 | 该选 |
|---|---|
| 防**主动探测**（探测者看到真页面） | `OBFS_TYPE=none` + `MASQ_TYPE=file`（**默认**） |
| 对抗**封 QUIC** 的网络 | `OBFS_TYPE=gecko`，接受 masquerade 失效 |
| 两者都要 | 做不到，这是协议层互斥 |

**默认选 `none` 的理由**：
- 保留 H3 伪装 + masquerade，主动探测看到的是正常网页
- gecko 在**中国 GFW 下没有任何公开实测数据**，且 v2.14.0 上有确认的性能缺陷（[issue #1724](https://github.com/apernet/hysteria/issues/1724)：混淆包装器不实现 `OOBCapablePacketConn`，丢失 GSO/batching，550 vs 690 Mbit/s）
- 中国环境下，Geo 封锁的触发点主要是**流量体量**，而非握手特征（见下）

脚本会在你同时开混淆和 masquerade 时**明确警告**。

## 为什么默认用 BBR 而不是 Brutal

反直觉但重要：[FOCI 2025](https://www.petsymposium.org/foci/2025/foci-2025-0001.pdf) 用 10,080 条流测试，两阶段阈值分类器对 **Brutal 的识别是 1257/1260 全中**，而 BBR 误报仅 16 条。

判据是「丢包后是否退让」和「中途削带宽后是否继续超发」——**Brutal 的加速优势建立在可被被动识别的行为上**。

所以用 BBR 不是"放弃核心优势"，而是规避了目前唯一有公开 PoC 的 Hy2 专用检测手段。

代价：30% 丢包下 Brutal 单流 98 Mbps vs BBR 31 Mbps（约 3.2 倍）。只有确认链路丢包 >10% 且不经过 GFW 判定点时，才值得开 Brutal（`BW_UP`/`BW_DOWN`）。

## 快速开始

### 方式一：ACME 自动证书（推荐，需域名）

```bash
sudo bash sbp-hy2.sh deploy \
     TLS_MODE=acme \
     TLS_DOMAIN=your.domain \
     TLS_EMAIL=you@mail.com
```

前提：域名已解析到本机，且 80 端口可达（HTTP-01 验证）。

### 方式二：自备证书

```bash
sudo bash sbp-hy2.sh deploy \
     TLS_MODE=manual \
     TLS_CERT=/etc/letsencrypt/live/your.domain/fullchain.pem \
     TLS_KEY=/etc/letsencrypt/live/your.domain/privkey.pem
```

### 方式三：完全离线（小硬盘 VPS）

二进制已在仓库里，不需要解压：

```bash
sudo HY2_BIN=/tmp/hysteria bash sbp-hy2.sh deploy ...
```

## 常用命令

```bash
sudo bash sbp-hy2.sh deploy      # 部署
sudo bash sbp-hy2.sh status      # 状态
sudo bash sbp-hy2.sh links       # 节点链接
sudo bash sbp-hy2.sh rotate      # 换端口
bash sbp-hy2.sh render           # 只输出 YAML（免 root）
bash sbp-hy2.sh selftest         # 自检（免 root）
sudo bash sbp-hy2.sh uninstall   # 卸载
```

## 关键变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `TLS_MODE` | `acme` | `acme` / `manual` |
| `TLS_DOMAIN` | — | **ACME 模式必填** |
| `TLS_EMAIL` | — | ACME 邮箱，建议填 |
| `HY2_LISTEN` | `:35543` | 监听地址（UDP）。**不是 443**，理由见上 |
| `OBFS_TYPE` | **`none`** | `none`（保留 H3 伪装）/ `salamander` / `gecko` |
| `OBFS_PASSWORD` | 自动生成 | 混淆密码 |
| `GECKO_MIN` / `GECKO_MAX` | `512` / `1200` | 握手分片大小（字节） |
| `ENABLE_PORT_HOP` | `false` | 端口跳跃 |
| `HY2_PORT_START/END` | `20000`/`50000` | 跳跃端口段 |
| `MASQ_TYPE` | **`file`** | `file`（默认，可控）/ `proxy` / `string` / `none` |
| `MASQ_URL` | `https://www.bing.com` | proxy 模式回源 |
| `ENABLE_LISTEN_HTTP` | `false` | 额外监听 TCP 80 |
| `ENABLE_LISTEN_HTTPS` | `false` | 额外监听 TCP 443 |
| `CONGESTION_TYPE` | `bbr` | `bbr` / `reno` |
| `BBR_PROFILE` | `standard` | `standard`/`conservative`/`aggressive` |
| `BW_UP` / `BW_DOWN` | — | 填了就用 Brutal，如 `100 mbps` |
| `ENABLE_ACL` | `false` | ACL 分流 |
| `ACL_REJECT_CN` | `false` | 拒绝 geoip:cn |
| `TRAFFIC_STATS_PORT` | — | 流量统计 API 端口 |

## 混淆：gecko vs salamander

| | salamander | gecko |
|---|---|---|
| 机制 | 每包 XOR 成随机字节 | XOR + **QUIC 握手包分片填充** |
| 防的是 | 载荷指纹 | 载荷 + **长度指纹** |
| 成熟度 | 稳定 | 实验性 |
| 客户端要求 | 全部支持 | Hysteria ≥2.9.2 或 sing-box ≥1.14 |

**gecko 是 salamander 的严格超集**，不牺牲任何防护。默认选它。

`minPacketSize` 512 / `maxPacketSize` 1200 是官方默认值——1200 正好是 QUIC Initial 的标准大小，超过会触发分片反而留特征。

**代价**：启用混淆后不再兼容标准 QUIC，失去 HTTP/3 伪装。这是取舍：从"看起来像正常 H3"变成"看起来像随机 UDP"。

| 你的网络 | 建议 |
|---|---|
| 封 QUIC/HTTP3，但允许其他 UDP | **开混淆** |
| 不封 UDP，但会识别 Hy2 指纹 | **开混淆** |
| UDP 通畅、没被针对性识别 | `OBFS_TYPE=none`（保留 H3 伪装） |
| 封所有 UDP | 都不行，只能走 TCP（Reality） |

## 端口跳跃

```bash
sudo ENABLE_PORT_HOP=true HY2_PORT_START=20000 HY2_PORT_END=50000 bash sbp-hy2.sh deploy
```

官方 `listen: :20000-50000` 会**自动配置 nftables/iptables** 把其他端口重定向到第一个，进程退出时自动清理。

**要求**：Linux + `nft` 或 `iptables` + root（或 `CAP_NET_ADMIN`）。脚本的 systemd unit 已授予 `CAP_NET_ADMIN`。

链接会写成 `host:20000,20000-50000` 并带 `mport`。

## masquerade：Hy2 的主动探测防御

Hy2 必须带 TLS。如果证书不被信任，探测者一问就知。

**masquerade 就是它的防御**：认证失败的 HTTP/3 请求不返回错误，而是返回伪装内容。

| 类型 | 效果 |
|---|---|
| `proxy` | **反代到真站**（推荐） |
| `file` | 本地静态目录 |
| `string` | 固定 HTML |

### 双栈伪装（可选加固）

真实支持 HTTP/3 的网站通常**同时**提供 TCP 80/443。只开 QUIC 不开 TCP，本身就是特征。

```bash
sudo ENABLE_LISTEN_HTTP=true ENABLE_LISTEN_HTTPS=true FORCE_HTTPS=true bash sbp-hy2.sh deploy
```

官方说这是"go the extra mile"的选项——没有证据表明防火墙在用"缺少 TCP HTTP"来识别 Hy2，但确实能补齐这个破绽。

## 拥塞控制

默认 BBR（自适应，不需要知道带宽）。

**Brutal** 抗丢包强 2-5 倍，但必须填**准确的**带宽：

```bash
sudo BW_UP="100 mbps" BW_DOWN="100 mbps" bash sbp-hy2.sh deploy
```

**注意**：Brutal 会强行按设定速率发送。填高于实际带宽会导致连接又慢又不稳，还浪费流量。

## 仓库结构

```
sbp-hy2.sh                  主脚本
bin/hysteria-linux-amd64    已下载的二进制（24 MB，裸二进制不需解压）
bin/hysteria.sha256         校验和
bin/HY_VERSION              版本号
tests/                      测试脚本
```

### 更新二进制

```bash
curl -LO https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64
cp hysteria-linux-amd64 bin/
(cd bin && sha256sum hysteria-linux-amd64 > hysteria.sha256)
rm -f bin/hysteria-linux-amd64
```

## 测试

```bash
bash tests/test_hy2_full.sh      # 9 组 33 项断言
sudo bash tests/root_hy2_official.sh   # 真实 root 部署
```

需要 `tests/bin/jq`。

## 已知限制

- **Hysteria 靠文件扩展名识别配置**，临时文件必须 `.yaml` 结尾
- **没有 `check` 子命令**，只能短暂启动观察日志；判据要排除 `quic: server closed`（那是正常 kill 的结果）
- **端口跳跃需 root + nft/iptables**
- **ACME 需域名 + 80 端口可达**
- **只支持 UDP**，全封 UDP 的网络就用不了

## License

MIT
