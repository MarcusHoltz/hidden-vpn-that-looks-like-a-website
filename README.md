# XRAY VLESS HTTPS Proxy with Decoy Website

How about a script that runs in a docker container and can give you a full HTTPS tunnel through your own website.

Generate your own website, certificate, and tunnel all your traffic through it. All the DPI can see is the SNI domain - not the path.

![HTTPS hidden proxy repair shop with posters of XRAY https v2ray proxy and security](https://raw.githubusercontent.com/MarcusHoltz/marcusholtz.github.io/refs/heads/main/assets/img/header/header--network--https-xray-proxy-vless-generator.jpg "Hidden Proxy with HTTPS XRAY V2RAY VLESS Proxies")


* * *

## Quick Start

The xray.sh script will work on a host machine or inside of docker.


* * *

### Standalone (Debian / Ubuntu)

```bash
sudo bash xray.sh
```

Requires root, ports 80 and 443 open, and a DNS A record pointing at the server.


* * *

### Docker

```bash
cp .env.example .env
# Edit .env — and set TTYD_CREDENTIAL=user:password
docker compose up -d
```

Open `http://<your-server-ip>:7681` in a browser. Enter the `TTYD_CREDENTIAL` you used above.

> The xray.sh wizard runs directly in the browser terminal — no SSH required.


* * *

## Which to Pick — Standalone vs Docker

Both modes run the same `xray.sh` script and produce identical configurations. The difference is environment and lifecycle management.

- **Standalone** installs nginx, certbot, and XRAY directly onto the host OS. Suitable for a dedicated VPS.

- **Docker** wraps everything in a Debian 12 container. [ttyd](https://github.com/tsl0922/ttyd) serves the xray.sh wizard as a browser-accessible terminal on port 7681 — no SSH needed for setup or ongoing management. All state is written to `./data/` on the host, so the container can be recreated, upgraded, or moved to another server without losing configuration, certificates, or client UUIDs.


* * *

## Decoy Website

`xray.sh` generates a static HTML tech-company landing page. 

- Six industry presets are available from the branding menu (cloud infrastructure, API gateway, security, analytics, dev tools, CDN). 

- Company name, tagline, and accent color are configurable.


* * * 

## The Concept and How it Works

Here is an overview of what we're doing:

```
Client (VLESS+WS+TLS)
      |
   port 443
      |
   Nginx  ──>  /          decoy tech-company website
          ──>  /<ws-path>  XRAY WebSocket endpoint (127.0.0.1 only)
                    |
                  XRAY
                    |
                internet
```

> The ISP sees: TLS to a real domain on port 443. The WS path and all traffic content are encrypted. A plain browser visit shows a convincing company landing page.


* * *

## Where is my website

Everything xray.sh writes is stored under `./data/` on the host.

The container can be stopped, upgraded, or moved without losing your configuration.

```
./data/
├── xray-setup/           # xray.sh state: domain, ports, WS path, client UUIDs
│   ├── state.env
│   └── client1.txt
├── letsencrypt/          # TLS certificates (Let's Encrypt)
├── xray-config/          # XRAY config.json
├── nginx/
│   ├── sites-available/  # nginx site configs written by xray.sh
│   └── sites-enabled/
├── www/                  # Decoy website HTML
└── logs/
    ├── nginx/
    └── xray/
```


* * *

## Docker Ports

| Port | Service | Purpose |
|------|---------|---------|
| 7681 | ttyd | Browser terminal — setup and management UI |
| 80 | nginx | Let's Encrypt ACME challenge + HTTP→HTTPS redirect |
| 443 | nginx / XRAY | HTTPS + VLESS WebSocket proxy endpoint |


* * *

## Environment Variables (`.env`)

| Variable | Default | Description |
|----------|---------|-------------|
| `TTYD_CREDENTIAL` | unset | Basic auth as `user:password`. **Set this.** An unset value leaves the terminal open to anyone who can reach port 7681. |
| `TTYD_PORT` | `7681` | Port the browser terminal listens on |


* * *

## Alternatives

| Project | Type | UI | Protocols | Best for |
|---------|------|----|-----------|----------|
| **This Repo** | setup script | terminal / browser (Docker) | VLESS + WS + TLS | Single server, clean setup, full client guide, reverse proxy support |
| [Reality-EZPZ](https://github.com/aleskxyz/reality-ezpz) | setup script | terminal (whiptail) | tcp, http, grpc, ws, tuic, hysteria2, shadowtls | **Recommended for English users** wanting protocol flexibility; includes WARP, Telegram bot, backup/restore, and two swappable cores (xray, sing-box) |
| [Hiddify-Manager](https://github.com/hiddify/Hiddify-Manager) | full platform | browser + dedicated app | 20+ protocols including Reality and Telegram proxy | **Most polished English option for larger deployments.** CDN routing, domain fronting, smart proxy modes, multi-admin, automatic Cloudflare CDN IP, dedicated client app |
| [tx-ui](https://github.com/AghayeCoder/tx-ui) | web panel | browser | All Xray protocols (VLESS, VMess, Trojan, Shadowsocks, REALITY, WireGuard) | Browser-based management with per-user traffic quotas, expiry dates, REST API, and fail2ban IP limiting — most actively maintained x-ui fork |
| [xray-ui](https://github.com/qist/xray-ui) | web panel | browser | All Xray protocols | Lightweight x-ui fork; primarily Chinese documentation, lightly maintained |


* * *

### tl;dr Choosing

- One server, real site, real domain, real cert, managed by script → **xray.sh**

- Need protocol flexibility with English-friendly terminal tooling → **Reality-EZPZ**

- Running infrastructure for many users, need CDN resilience and a dedicated client app → **Hiddify-Manager**

- Need browser-based panel with per-user quotas and a REST API → **tx-ui**

