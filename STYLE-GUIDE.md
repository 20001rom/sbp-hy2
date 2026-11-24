# 代码风格

改这个脚本前先看一遍。新增的段落应该和现有代码读起来像同一个人写的。

## 注释

中文，简体。段落式说明，列要点用 `·` 或 `1) 2)`。

写理由，不写结论：

```
# 端口选择有论文依据，不要随手改成 443：
#
# 1) GFW 的 QUIC 审查只处理「源端口 > 目的端口」的 UDP 包
#    （USENIX Security '25 §3.3）。服务端端口 ≥32768 时，客户端临时端口
#    必然更低，该流直接落在 GFW 的解密流程之外。
```

引用来源就给出处（论文、官方文档、issue 号）。想写"实测"就带上数据，
不然用"实测改 8443 后回到 20 Mbps"这种说法。

用 `——` 做解释性补充。

## 代码

`set -Eeuo pipefail`。变量集中在文件头部，统一 `${VAR:-default}`。
变量名全大写下划线（`HY2_LISTEN`、`ENABLE_PORT_HOP`），函数名小写下划线
（`render_config()`、`open_ports()`、`load_env()`）。

4 空格缩进。错误处理走 `die()` / `warn()` / `ok()` / `info()`。
分段用 `# ===== 名称 =====`。

## 不要出现的措辞

"简单来说"、"换句话说"、"也就是说"、"让我们"、"接下来"、"本质上"、
"显然"、"首先……其次……最后……"、"这个方案很优雅"、"非常强大"、
"注意！！！"、emoji。

也不要在注释里解释"我们为什么这么做"，只解释"这么做的后果是什么"。

## 两处容易踩的地方

### 快照与环境文件

`_SBP_ENV_KEYS` 记的是"用户显式设置过"的键，`load_env()` 会跳过这些键，
不让 env.conf 覆盖命令行参数。

快照必须在所有 `VAR="${VAR:-default}"` **之前**做。放在后面的话，每个键
都已经有了默认值，会被整体误判成"用户指定"，env.conf 就等于失效。

位置参数是 `main()` 里才 export 的，所以那里要**追加**到快照，
不能重做——重做时所有键都已带默认值。

### 端口跳跃的持久化

`open_ports()` 用 `iptables -I INPUT` 放行端口段，但 iptables 规则不会被 ufw
持久化，机器重启就没了。要让端口段在重启后仍可用，得用
`ufw allow 20000:20100/udp`（写进 `/etc/ufw/user.rules`）。

## 改完怎么验

`bash -n sbp-hy2.sh` 查语法，`bash sbp-hy2.sh selftest` 跑自检，
`bash sbp-hy2.sh render` 看生成的 YAML。

生成的配置要能被真实二进制接受才算过：

```
bash sbp-hy2.sh render WARP_ENABLED=true ... > /tmp/c.yaml
hysteria server -c /tmp/c.yaml    # 看到 "server up and running" 即可
```

注意 hysteria 按文件扩展名判断格式（`.yaml`/`.yml`/`.json`），
无后缀的文件会报 `Unsupported Config Type`。
