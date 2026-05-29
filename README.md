# XRAY VLESS HTTPS Proxy with Decoy Website

How about a script that runs in a docker container and can give you a full HTTPS proxy?

Generate your own website, certificate, and tunnel all your traffic through it. 


* * *

![HTTPS hidden proxy repair shop with posters of XRAY https v2ray proxy and security](https://raw.githubusercontent.com/MarcusHoltz/marcusholtz.github.io/refs/heads/main/assets/img/header/header--network--https-xray-proxy-vless-generator.jpg "Hidden Proxy with HTTPS XRAY V2RAY VLESS Proxies")

* * *

## Quick Start

The xray.sh script will work inside of docker or on the host machine itself (Docker recommended).

Requires ports 80 and 443 open, and a DNS A record pointing at the server.

* * *

### Docker

```bash
# Edit .env — and set TTYD_CREDENTIAL=user:password
docker compose up -d
```

Open `https://<your-server-ip>:7681` in a browser (accept the self-signed cert warning). Enter the `TTYD_CREDENTIAL` you used above.

> The xray.sh wizard runs directly in the browser terminal — no SSH required.


* * *

### Standalone (Debian / Ubuntu)

```bash
sudo bash xray.sh
```

Requires root.


* * *

### Which to Pick — Standalone vs Docker

Both modes run the same `xray.sh` script and produce identical configurations; the difference is environment.

- `Standalone` - installs nginx, certbot, and XRAY directly onto the host OS. Suitable for a dedicated VPS.

- `Docker` - wraps everything in a Debian 12 container. [ttyd](https://github.com/tsl0922/ttyd) serves the xray.sh wizard as a browser-accessible terminal on port 7681 secured with basic auth — no SSH needed for setup or ongoing management. All data is written to `./data/` on the host, so the container can be recreated, upgraded, or moved to another server without losing configuration, certificates, or client UUIDs.


* * *

## Your Decoy Homepage

`xray.sh` generates a static HTML tech-company landing page. 

- Six industry presets are available from the branding menu (cloud infrastructure, API gateway, security, analytics, dev tools, CDN). 

- Company name, tagline, and accent color are configurable.


* * *

### Where is my data stored


#### Docker

The docker-compose file keeps everything xray.sh writes stored under `./data/` on the host.

```
./data/
├── xray-setup/           # xray.sh state: domain, ports, WS path, branding, mode
│   ├── state.env
│   ├── proxy_users.json  # HTTP proxy user accounts (if enabled)
│   └── client1.txt       # initial client's vless:// link (convenience copy)
├── letsencrypt/          # TLS certificates (Let's Encrypt)
├── xray-config/          # XRAY config.json — includes all client UUIDs
├── nginx/
│   ├── sites-available/  # nginx site configs written by xray.sh
│   └── sites-enabled/
├── www/                  # Decoy website HTML
└── logs/
    ├── nginx/
    └── xray/
```


* * *

#### Standalone (bare metal / VM)

When run directly on the host, xray.sh writes to `standard system paths`. 

Nothing is bundled under a single directory — files land where their respective services expect them.

```
/etc/xray-setup/
├── state.env             # all install variables (domain, ports, WS path, mode)
├── client1.txt           # first client's vless:// link  (chmod 600)
├── proxy_users.json      # HTTP proxy user accounts, if enabled  (chmod 600)
└── dns_credentials.ini   # DNS-01 provider API key, if used  (chmod 600)

/usr/local/bin/xray                      # XRAY binary
/usr/local/etc/xray/config.json          # XRAY runtime config
/usr/local/share/xray/
├── geoip.dat                            # IP geolocation data
└── geosite.dat                          # domain category data

/etc/systemd/system/xray.service         # systemd unit (bare metal only)

/etc/nginx/sites-available/<domain>      # nginx site config written by xray.sh
/etc/nginx/sites-enabled/<domain>        # symlink to the above

/var/www/<domain>/                       # decoy website HTML root 
                                         # (PAC file also served from here if - HTTP proxy is enabled)

/etc/letsencrypt/live/<domain>/
├── fullchain.pem                        # TLS certificate chain
└── privkey.pem                          # private key

/etc/letsencrypt/renewal-hooks/deploy/
└── xray-reload.sh                       # auto-reload hook: nginx + XRAY
                                         # reload after every cert renewal

/var/log/nginx/                          # nginx access and error logs
/var/log/xray/xray.log                   # XRAY log (non-systemd only;
                                         # on systemd use: journalctl -u xray)
/var/log/letsencrypt/letsencrypt.log     # certbot log
```


* * *

## HTTP CONNECT Browser Proxy

In addition to the VLESS tunnel, xray.sh can enable a browser proxy — no client app required on any device.

When enabled, XRAY adds an HTTP CONNECT inbound and serves a [PAC file](https://developer.mozilla.org/en-US/docs/Web/HTTP/Proxy_servers_and_tunneling/Proxy_Auto-Configuration_PAC_file) at a randomised deep path (e.g. `https://domain.com/something/numbersandsuch/otherthing/proxy.pac`). Browsers load the PAC URL once and route all traffic through the proxy automatically.

- **Multi-user** — each user gets their own username and password; accounts are added or revoked independently.
- **Port 443 only** — browsers always connect over the existing HTTPS port; no extra firewall rules.
- **PAC path rotation** — the hidden PAC URL can be regenerated at any time from the management menu.
- **Mutual exclusion** — the HTTP proxy and VLESS tunnel cannot run simultaneously. Switching between them is a one-step toggle; proxy users are preserved when VLESS is re-enabled.

> HTTP proxy is available in standalone mode only. Reverse proxy mode does not support it.


* * *

## Multi-Client Management

Each device gets its own UUID and its own `vless://` link, or username and password with `HTTP CONNECT PROXY`. Clients are managed from within the script's menu without restarting the proxy.

- **Add** — enter a label (e.g. `phone`, `alice`, `work-laptop`); a UUID is generated automatically - or for HTTP CONNECT PROXY a `username` and `password` is prompted.
- **Remove** — select one or more clients to revoke; access is cut off the moment XRAY restarts. The last remaining client cannot be removed.
- **List** — prints each client's full `vless://` link, or username and password to the terminal one at a time for copying.


* * *

## Docker Ports

| Port | Service | Purpose |
|------|---------|---------|
| 7681 | ttyd | Browser terminal — setup and management UI |
| 80 | nginx | Let's Encrypt ACME challenge + HTTP→HTTPS redirect |
| 443 | nginx / XRAY | HTTPS + VLESS WebSocket proxy endpoint |


* * *

## Environment Variables (.env)

| Variable | Default | Description |
|----------|---------|-------------|
| `TTYD_CREDENTIAL` | unset | Basic auth as `user:password`. **Set this.** An unset value leaves the terminal open to anyone who can reach port 7681. |
| `TTYD_PORT` | `7681` | Port the browser terminal listens on |


* * *

## Stealth Mode (Docker only)

In Docker mode, the management UI (ttyd) runs on a separate port (default 7681). Stealth mode closes that port to outside connections while leaving the proxy on port 443 fully operational.

- **ON** — the ttyd nginx vhost is removed; port 7681 accepts no external connections.
- **OFF** — the ttyd nginx vhost is restored; the browser terminal is accessible again.

Toggle from **Manage → Stealth Mode**. Re-enable to regain access for future configuration.


* * *

## Management Menu Reference

Once installed, re-running `xray.sh` detects the existing setup and opens the management menu. A reinstall option is also available — it replaces all client UUIDs and regenerates the decoy site while keeping the existing TLS certificate.

| Menu item | What it does |
|-----------|-------------|
| Connect a Device | Opens the per-platform client guide |
| Clients | Add, remove, or list client links |
| Path | Rotate the hidden WebSocket path |
| HTTP Proxy | Enable/disable browser proxy; manage users and PAC path |
| Branding | Change company name, tagline, or accent color |
| Status | Show service status, cert expiry, and config paths |
| Renew TLS | Force-renew the Let's Encrypt certificate |
| Stealth Mode | Toggle the admin terminal port (Docker only) |
| Uninstall | Remove XRAY, nginx config, certificates, and state |


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

