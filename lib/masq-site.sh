#!/usr/bin/env bash
# 生成静态站文件到指定目录
# 用法：masq_site_gen <目标目录> [站点名]
#
# 设计要点（踩过的坑）：
#   1. CSS 内联，不用 /assets/style.css —— Hysteria 的 masquerade file 模式
#      对子路径的支持不可靠，样式加载失败会让页面裸奔，本身就成特征。
#   2. 页面之间互相链接但不依赖任何外部资源（字体、图标、脚本全无）。
#   3. 不模仿任何知名网站，避免版权与指纹问题。
masq_site_gen(){
  local dir="$1" name="${2:-}"
  [[ -n "$dir" ]] || { warn "未指定目录"; return 1; }
  mkdir -p "$dir" 2>/dev/null || return 1

  # 站点名：优先用域名首段，否则用中性名
  if [[ -z "$name" ]]; then
    if [[ -n "${TLS_DOMAIN:-}" ]]; then
      name="${TLS_DOMAIN%%.*}"
      name="$(printf '%s' "${name:0:1}" | tr '[:lower:]' '[:upper:]')${name:1}"
    else
      name="Northwind"
    fi
  fi

  local year; year="$(date +%Y)"

  # 公共 CSS（内联到每个页面）
  local css
  css='<style>
:root{--bg:#0f1115;--fg:#e6e8ee;--dim:#9aa3b2;--line:#232833;--accent:#7aa2f7}
@media (prefers-color-scheme:light){:root{--bg:#fbfbfd;--fg:#1b1f27;--dim:#5b6472;--line:#e3e6ec;--accent:#2f6feb}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);
font:16px/1.65 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif}
.wrap{max-width:760px;margin:0 auto;padding:0 24px}
header{display:flex;justify-content:space-between;align-items:center;
padding:28px 0 20px;border-bottom:1px solid var(--line);flex-wrap:wrap;gap:12px}
.brand{font-weight:650;letter-spacing:-.01em;color:var(--fg);text-decoration:none;font-size:17px}
nav a{color:var(--dim);text-decoration:none;margin-left:20px;font-size:15px}
nav a:hover{color:var(--accent)}
main{padding:56px 0 72px}
.hero h1{font-size:clamp(28px,4.6vw,40px);line-height:1.2;letter-spacing:-.02em;margin:0 0 18px;font-weight:680}
.lede{font-size:18px;color:var(--dim);margin:0 0 14px;max-width:60ch}
.meta{font-size:14px;color:var(--dim);margin:0;opacity:.85}
.cards{display:grid;gap:18px;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));margin:48px 0}
.cards article{border:1px solid var(--line);border-radius:10px;padding:20px}
.cards h2{font-size:16px;margin:0 0 8px;letter-spacing:-.01em}
.cards p{margin:0;color:var(--dim);font-size:15px}
.note{margin:40px 0 0;padding-top:28px;border-top:1px solid var(--line)}
.note h2{font-size:17px;margin:0 0 10px}
.note p,.note li{color:var(--dim);font-size:15px}
.note ul{margin:0;padding-left:20px}
.note li{margin:6px 0}
a{color:var(--accent)}
footer{padding:22px 0 40px;border-top:1px solid var(--line);color:var(--dim);font-size:14px}
footer p{margin:4px 0}
.fine{font-size:13px;opacity:.75}
</style>'

  # ---- index.html ----
  cat > "$dir/index.html" <<HTMLEOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${name} — Infrastructure &amp; Data Services</title>
<meta name="description" content="${name} builds reliable infrastructure tooling for distributed teams.">
${css}
</head>
<body>
<header class="wrap">
  <a class="brand" href="/">${name}</a>
  <nav>
    <a href="/">Home</a>
    <a href="/about.html">About</a>
    <a href="/contact.html">Contact</a>
  </nav>
</header>

<main class="wrap">
  <section class="hero">
    <h1>Reliable infrastructure for distributed teams</h1>
    <p class="lede">
      We design and operate the plumbing behind always-on services:
      observability pipelines, edge caching, and the boring automation
      that keeps systems predictable at 3&nbsp;a.m.
    </p>
    <p class="meta">Established ${year} &middot; Remote-first &middot; Small by design</p>
  </section>

  <section class="cards">
    <article>
      <h2>Observability</h2>
      <p>Metrics, logs and traces that stay queryable without a dedicated
         platform team. We instrument first, then decide what to keep.</p>
    </article>
    <article>
      <h2>Edge delivery</h2>
      <p>Static and dynamic content served close to users, with sane cache
         rules and a rollout path that does not require a maintenance window.</p>
    </article>
    <article>
      <h2>Automation</h2>
      <p>Deployments, backups and certificate rotation handled by scripts
         that fail loudly instead of quietly.</p>
    </article>
  </section>

  <section class="note">
    <h2>About this site</h2>
    <p>
      This is the public landing page for our internal tooling. Most of what we
      run is not meant to be browsed &mdash; the services behind it are reachable
      over HTTP/3 and speak to registered clients only.
    </p>
  </section>
</main>

<footer class="wrap">
  <p>&copy; ${year} ${name}. All rights reserved.</p>
  <p class="fine">Contact: <a href="mailto:hello@example.com">hello@example.com</a></p>
</footer>
</body>
</html>
HTMLEOF

  # ---- about.html ----
  cat > "$dir/about.html" <<HTMLEOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>About — ${name}</title>
${css}
</head>
<body>
<header class="wrap">
  <a class="brand" href="/">${name}</a>
  <nav>
    <a href="/">Home</a>
    <a href="/about.html">About</a>
    <a href="/contact.html">Contact</a>
  </nav>
</header>

<main class="wrap">
  <section class="hero">
    <h1>About</h1>
    <p class="lede">
      ${name} is a small engineering practice. We take on a handful of
      engagements at a time and stay involved past the handover.
    </p>
  </section>

  <section class="note">
    <h2>How we work</h2>
    <ul>
      <li>Written runbooks before automation, automation before dashboards.</li>
      <li>No shared credentials. Every service authenticates individually.</li>
      <li>If a system needs a person awake to stay up, it is not finished.</li>
    </ul>
  </section>

  <section class="note">
    <h2>Infrastructure</h2>
    <p>
      Our edge endpoints are served over modern transport protocols and are
      provisioned from version-controlled configuration. Certificate rotation
      happens automatically; there is no manual step to forget.
    </p>
  </section>
</main>

<footer class="wrap">
  <p>&copy; ${year} ${name}. All rights reserved.</p>
</footer>
</body>
</html>
HTMLEOF

  # ---- contact.html ----
  cat > "$dir/contact.html" <<HTMLEOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Contact — ${name}</title>
${css}
</head>
<body>
<header class="wrap">
  <a class="brand" href="/">${name}</a>
  <nav>
    <a href="/">Home</a>
    <a href="/about.html">About</a>
    <a href="/contact.html">Contact</a>
  </nav>
</header>

<main class="wrap">
  <section class="hero">
    <h1>Contact</h1>
    <p class="lede">
      For new work, send a short note describing the problem rather than the
      solution. We reply within two business days.
    </p>
  </section>

  <section class="note">
    <h2>Reach us</h2>
    <p>Email: <a href="mailto:hello@example.com">hello@example.com</a></p>
    <p class="fine">
      We do not offer phone support. For incident response on an existing
      engagement, use the pager address provided in your onboarding document.
    </p>
  </section>
</main>

<footer class="wrap">
  <p>&copy; ${year} ${name}. All rights reserved.</p>
</footer>
</body>
</html>
HTMLEOF

  # ---- 404.html ----
  cat > "$dir/404.html" <<HTMLEOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Not Found — ${name}</title>
${css}
</head>
<body>
<header class="wrap">
  <a class="brand" href="/">${name}</a>
</header>
<main class="wrap">
  <section class="hero">
    <h1>404</h1>
    <p class="lede">That page does not exist.</p>
    <p class="meta"><a href="/">Return to the homepage</a></p>
  </section>
</main>
</body>
</html>
HTMLEOF

  # ---- robots.txt ----
  cat > "$dir/robots.txt" <<'ROBOTSEOF'
User-agent: *
Allow: /
ROBOTSEOF

  ok "静态站已生成：${dir}（站点名 ${name}，$(find "$dir" -type f | wc -l) 个文件，CSS 已内联）"
  return 0
}