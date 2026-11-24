# SBP-Lite

Proxy node deployment scripts for a single VPS. **No package manager involved** — binaries ship pre-extracted in the repository.

[中文](README.md)

## The two scripts

| Script | Protocol | Transport | Default port | Role |
|---|---|---|---|---|
| `sbp-hy2.sh` | Hysteria 2 (official) | UDP | 35543 | Primary — fast, loss-tolerant |
| `sbp-xray.sh` | Xray-core | TCP | 443 | Fallback — Reality works where UDP is blocked |

`sbp.sh` is the combined entry point for managing both.

They use different transports, so port 443 does not conflict.

## Quick start

```bash
# Hysteria 2 (domain must resolve to this host, port 80 reachable)
sudo bash sbp-hy2.sh deploy \
     TLS_DOMAIN=your.domain \
     TLS_EMAIL=you@mail.com

# Xray Reality (no domain needed)
sudo bash sbp-xray.sh deploy
```

## Why binaries are pre-extracted

Xray only publishes `.zip`. Minimal Debian images lack `unzip`, `busybox` and `python3`, and `perl-base` ships without `Compress::Raw::Zlib` — there is no reliable way to unpack Xray's zip on such a system.

So the unpacking happens at packaging time:

```
bin/xray-linux-64 in the repo (35 MB, already extracted)
        ↓ server only downloads + chmod
/usr/local/bin/xray
```

The cost is a few dozen MB in the repository; the benefit is zero dependencies and zero extraction on the server.

---

# SBP-Hy2

Deployment script for official [Hysteria 2](https://github.com/apernet/hysteria).

## Why the official build

Xray 26.x ships Hysteria2 as a transport only. The official build adds obfuscation, port hopping, ACL routing, masquerade and other capabilities. Without obfuscation, Hy2 can only look like plain HTTP/3.

| Capability | Official | Xray |
|---|---|---|
| gecko / salamander obfuscation | ✅ | ❌ |
| Port hopping (auto-configures nft/iptables) | ✅ | ❌ |
| ACL routing | ✅ | ❌ |
| masquerade | ✅ | ❌ |
| sniGuard | ✅ | ❌ |
| Fine-grained Brutal tuning | ✅ | ⚠️ coarse |
| Traffic stats API | ✅ | ❌ |

## Key trade-offs

### Obfuscation and masquerade are mutually exclusive

Official docs: once obfuscation is enabled the server is no longer a valid HTTP/3 server (*will no longer function as a valid HTTP/3 server*). A probe sending an H3 handshake gets no reply, so masquerade never triggers.

| Goal | Configuration |
|---|---|
| Resist active probing | `OBFS_TYPE=none` + `MASQ_TYPE=file` (default) |
| Survive QUIC blocking | `OBFS_TYPE=gecko`, accepting that masquerade stops working |

`none` is the default: it keeps the H3 disguise. gecko also has no public field data from GFW networks and v2.14.0 carries a confirmed GSO regression ([issue #1724](https://github.com/apernet/hysteria/issues/1724)).

The script warns when obfuscation and masquerade are enabled together.

### Default port is 35543, not 443

1. GFW's QUIC inspection only handles UDP packets where source port > destination port ([USENIX Security '25 §3.3](https://gfw.report/publications/usenixsecurity25/en/)). With a server port ≥32768 the client's ephemeral port is always lower, so the flow stays outside that path.
2. China Telecom AS4134 throttles UDP/443 independently of protocol: 10–30 seconds after connect it drops to 1–5 Mbps.

To go back to 443: `HY2_LISTEN=:443`.

### BBR over Brutal

[FOCI 2025](https://www.petsymposium.org/foci/2025/foci-2025-0001.pdf) tested 10,080 flows; a two-stage threshold classifier identified Brutal 1257/1260 times while BBR produced 16 false positives. The signal is whether the sender backs off after loss.

Brutal's advantage rests on behaviour that can be detected passively. The cost: at 30% loss Brutal reaches 98 Mbps single-stream against BBR's 31 Mbps. Enable it (`BW_UP`/`BW_DOWN`) only when loss exceeds 10% and the path avoids GFW inspection points.

## Deploy

```bash
# ACME certificate
sudo bash sbp-hy2.sh deploy \
     TLS_DOMAIN=your.domain \
     TLS_EMAIL=you@mail.com

# Bring your own certificate
sudo bash sbp-hy2.sh deploy \
     TLS_MODE=manual \
     TLS_CERT=/etc/letsencrypt/live/your.domain/fullchain.pem \
     TLS_KEY=/etc/letsencrypt/live/your.domain/privkey.pem

# Offline (binary already in the repository)
sudo HY2_BIN=/tmp/hysteria bash sbp-hy2.sh deploy ...
```

## Commands

```bash
sudo bash sbp-hy2.sh deploy      # deploy
sudo bash sbp-hy2.sh status      # status
sudo bash sbp-hy2.sh links       # share links
sudo bash sbp-hy2.sh rotate      # change ports
bash sbp-hy2.sh render           # print YAML only (no root)
bash sbp-hy2.sh selftest         # self-test (no root)
sudo bash sbp-hy2.sh uninstall   # remove
```

## Variables

| Variable | Default | Description |
|---|---|---|
| `TLS_MODE` | `acme` | `acme` / `manual` |
| `TLS_DOMAIN` | — | required for ACME |
| `TLS_EMAIL` | — | ACME contact |
| `HY2_LISTEN` | `:35543` | listen address (UDP) |
| `OBFS_TYPE` | `none` | `none` / `salamander` / `gecko` |
| `OBFS_PASSWORD` | generated | obfuscation password |
| `GECKO_MIN` / `GECKO_MAX` | `512` / `1200` | handshake fragment size (bytes) |
| `ENABLE_PORT_HOP` | `false` | port hopping |
| `HY2_PORT_START` / `HY2_PORT_END` | `20000` / `50000` | hopping port range |
| `MASQ_TYPE` | `file` | `file` / `proxy` / `string` / `none` |
| `MASQ_URL` | `https://www.bing.com` | upstream for proxy mode |
| `ENABLE_LISTEN_HTTP` / `ENABLE_LISTEN_HTTPS` | `false` | also listen on TCP 80 / 443 |
| `CONGESTION_TYPE` | `bbr` | `bbr` / `reno` |
| `BBR_PROFILE` | `standard` | `standard` / `conservative` / `aggressive` |
| `BW_UP` / `BW_DOWN` | — | enables Brutal when set, e.g. `100 mbps` |
| `ENABLE_ACL` | `false` | ACL routing |
| `ACL_REJECT_CN` | `false` | reject geoip:cn |
| `WARP_ENABLED` | `false` | second account routed to a local SOCKS5 proxy |
| `WARP_SOCKS_ADDR` | `127.0.0.1:40000` | WARP egress address |
| `WARP_AUTH_USER` | `warp` | WARP account name |
| `WARP_AUTH_PASS` | generated | WARP account password |
| `TRAFFIC_STATS_PORT` | — | traffic stats API port |

## WARP routing

With `WARP_ENABLED=true` the config uses `userpass` with two accounts, and the server routes by `auth.id`:

```
main account → direct
warp account → socks5 → 127.0.0.1:40000 (typically a sing-box WARP egress)
```

`listen` takes a single value, so one instance can only bind one port. Both accounts share that port and the client switches egress by switching node.

Requires a local SOCKS5 egress pointing at WARP, for example sing-box:

```json
{
  "inbounds": [{ "type": "mixed", "listen": "127.0.0.1", "listen_port": 40000 }],
  "endpoints": [{
    "type": "wireguard",
    "tag": "warp",
    "address": ["172.16.0.2/32"],
    "private_key": "<private key>",
    "peers": [{
      "address": "engage.cloudflareclient.com",
      "port": 2408,
      "public_key": "<public key>",
      "allowed_ips": ["0.0.0.0/0"],
      "persistent_keepalive_interval": 25
    }]
  }],
  "outbounds": [{ "type": "direct", "tag": "direct" }],
  "route": { "final": "warp" }
}
```

## Port hopping

```bash
sudo ENABLE_PORT_HOP=true HY2_PORT_START=20000 HY2_PORT_END=20100 bash sbp-hy2.sh deploy
```

Official `listen: :20000-20100` configures nftables/iptables to redirect the rest of the range to the first port and cleans up on exit.

Requires root (or `CAP_NET_ADMIN`) plus nft/iptables. Links are written as `host:20000,20000-20100` with `mport`.

**The range must also be allowed through ufw's persistent rules**, otherwise the rules are gone after a reboot:

```bash
sudo ufw allow 20000:20100/udp
```

## Masquerade

Hy2 always carries TLS. Unauthenticated HTTP/3 requests get the masquerade content instead of an error — that is the active-probe defence.

| Type | Effect |
|---|---|
| `proxy` | reverse proxy to a real site |
| `file` | local static directory |
| `string` | fixed HTML |

### Dual-stack

Sites that genuinely support HTTP/3 usually serve TCP 80/443 as well. QUIC-only is itself a signal.

```bash
sudo ENABLE_LISTEN_HTTP=true ENABLE_LISTEN_HTTPS=true FORCE_HTTPS=true bash sbp-hy2.sh deploy
```

### Generated static site

`MASQ_TYPE=file` generates a complete static site (index/about/contact/404 plus CSS) rather than a single `<h1>It works!</h1>`. The site name comes from the first label of the domain, or `Northwind` when there is none. An existing `index.html` is left alone.

---

# SBP-Xray

Deployment script for Xray-core.

## Core constraint

Port 443 is exclusive. Two Reality inbounds cannot both bind 443 — `run -test` does not catch this (syntax only), the bind error appears at startup.

Recommended shape:

```
443      → VLESS Reality + Vision   (direct, primary)
high port → VLESS XHTTP + TLS       (CDN fallback)
```

## Protocols

| Protocol | Default | Transport | Security | Port |
|---|---|---|---|---|
| `vless-reality` | on | tcp | reality | 443 |
| `hy2` | off | hysteria | tls | high UDP |
| `vless-xhttp` | off | xhttp | follows `XHTTP_SECURITY` | high |
| `trojan` | off | tcp | tls | high |
| `vless-tls` | off | tcp | tls | high |

Xray has no TUIC v5 or AnyTLS (those are sing-box's).

## Reality dest verification

**On failed authentication Reality forwards the whole connection to dest, so a prober sees dest's certificate.** Dest certificate quality is your security.

The script runs `verify_dest` before deploying and checks seven items:

| Check | Consequence of failure |
|---|---|
| dest reachable | Reality handshake fails outright |
| TLS 1.3 | Reality cannot work |
| ALPN h2 | Cannot mirror the handshake (needs explicit `-alpn h2`) |
| X25519 | Key exchange fails |
| Certificate `subject != issuer` | Self-signed certs are obvious to probers |
| Certificate chain ≥ 2 | A single cert does not look like a real site |
| Handshake latency < 100ms | Too slow gives it away |

It also rejects burned SNIs (`www.apple.com` / `www.microsoft.com` / `www.lovelive-anime.jp`).

Deployment aborts if verification fails. To force it: `sudo VERIFY_DEST_STRICT=0 bash sbp-xray.sh deploy`.

Verify a candidate dest by hand on the server:

```bash
SNI=your-candidate
openssl s_client -connect "$SNI:443" -servername "$SNI" -tls1_3 </dev/null 2>&1 \
  | grep -E "Protocol|Server Temp Key|ALPN"
curl -s -o /dev/null -w "handshake %{time_connect}s\n" "https://$SNI"
```

The ideal dest sits in the same subnet or ASN as your server.

## XHTTP

| Mode | Upstream | Downstream | Use |
|---|---|---|---|
| `packet-up` | N separate POSTs (numbered) | one long GET | Widest compatibility, passes any CDN |
| `stream-up` | one long POST | another long GET | Requires H2/H3 |
| `stream-one` | single bidirectional POST | same | Fastest, Nginx `grpc_pass`/CF gRPC only |

Three gotchas:

1. **Hard conflict with Mux** — XHTTP server rejects clients with Mux enabled
2. **CF cuts idle downlinks** after 100 seconds; use `ClientAliveInterval 30`
3. **Highest maintenance burden** — Xray makes breaking changes often

Running through a CDN requires a real domain and a real certificate; a self-signed one fails the origin check.

## Xray variables

| Variable | Default | Description |
|---|---|---|
| `REALITY_SERVER` | `www.bing.com` | Reality disguise target, **change this** |
| `REALITY_PORT_MODE` | `auto` | `auto`=443 / `random` / `fixed` |
| `UTLS_FP` | `firefox` | uTLS fingerprint |
| `ENABLE_VLESS_REALITY` | `true` | primary protocol |
| `ENABLE_VLESS_XHTTP` | `false` | XHTTP inbound |
| `XHTTP_SECURITY` | `reality` | `reality` / `tls` (CDN) / `none` |
| `XHTTP_MODE` | `auto` | `auto`/`packet-up`/`stream-up`/`stream-one` |
| `XHTTP_PATH` | random | request path |
| `XHTTP_PADDING` | `100-1000` | random padding per request |
| `ENABLE_FINALMASK` | `false` | FinalMask |
| `FINALMASK_TYPE` | `header-custom` | `header-custom`/`header-dns`/`header-dtls`/`header-srtp`/`header-utp`/`header-wechat`/`header-wireguard` |
| `ENABLE_TCP_FRAGMENT` | `false` | ClientHello split into three segments |
| `ENABLE_TROJAN` | `false` | Trojan Reality |
| `ENABLE_VLESS_TLS` | `false` | VLESS over TLS (needs certificate) |
| `ENABLE_HYSTERIA2` | `false` | Xray's built-in Hy2 |
| `HY2_PWD` | generated | Hy2 auth password |
| `HY2_MASQUERADE_TYPE` | `string` | `string` / `proxy` / `file` |
| `TLS_DOMAIN` | — | certificate CN |
| `TLS_CERT_MODE` | `self_signed` | `self_signed` / `manual` |
| `XRAY_SOURCE` | `repo` | `repo` (repo binary) / `release` (official zip) |
| `XRAY_BIN` | — | use a local pre-extracted binary |

---

## Repository layout

```
sbp-hy2.sh                  Hysteria 2 script
sbp-xray.sh                Xray script
sbp.sh                     combined entry point
lib/masq-site.sh           static site generator
bin/hysteria-linux-amd64    Hysteria binary (24 MB)
bin/xray-linux-64          Xray binary (35 MB, extracted)
bin/*.sha256                checksums
tests/                      test scripts
```

### Updating binaries

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

### Multiple architectures

The script looks for `bin/xray-linux-<arch>`. `x86_64` → `64`, `aarch64` → `arm64-v8a`, `armv7` → `arm32-v7a`. With binaries for one architecture only, others fall back to the official Release (which then needs unzip).

## Known limitations

- **Hysteria detects config format by file extension**; temporary files must end in `.yaml`
- **Same for Xray**; temporary files must end in `.json`
- **No `check` subcommand** (Hysteria) — start briefly and read the log
- **`run -test` does not check port conflicts**, syntax only
- **Port hopping needs root plus nft/iptables**
- **ACME needs a domain and reachable port 80**
- **Hysteria is UDP only**
- **Reality must be on 443** — Reality on a high port hurts you (SNI-IP-port mismatch)
- **XHTTP through a CDN needs a real domain and certificate**

## License

MIT
