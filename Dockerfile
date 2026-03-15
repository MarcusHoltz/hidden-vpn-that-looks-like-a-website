# =============================================================================
# xray-docker  —  XRAY VLESS+WS+TLS  |  Web-terminal configuration interface
#
# What this image contains:
#   - All runtime dependencies for xray.sh (nginx, certbot, jq, etc.)
#   - ttyd: serves a browser-accessible terminal at port 7681
#   - cron: runs certbot auto-renewal nightly
#   - xray.sh: copied to /opt/xray/xray.sh and run by ttyd
#
# Ports:
#   7681  — ttyd web terminal  (admin configuration UI)
#   80    — nginx              (Let's Encrypt ACME challenge + HTTP redirect)
#   443   — nginx / XRAY       (HTTPS + VLESS-over-WebSocket endpoint)
#
# The XRAY binary itself is NOT baked in. xray.sh downloads and installs it
# at runtime via the official XTLS installer, ensuring you always get a
# verified release and can reinstall/upgrade without rebuilding the image.
# =============================================================================

FROM debian:12-slim

# Avoid apt prompts during build
ENV DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# System packages
# certbot is intentionally NOT installed here — see the pip step below.
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        # xray.sh runtime deps
        nginx \
        curl \
        uuid-runtime \
        python3 \
        python3-pip \
        jq \
        qrencode \
        psmisc \
        # process utilities
        procps \
        # for certbot auto-renewal
        cron \
        # for ttyd download
        wget \
        # misc utilities used by scripts
        ca-certificates \
        openssl \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# certbot — installed via pip, NOT apt.
#
# Debian 12's apt-packaged certbot is version 2.1.0, which crashes with:
#   AttributeError: can't set attribute
# on Python 3.11+ whenever any ACME server error occurs (rate limit,
# transient 404, etc.). The real error is swallowed by a secondary bug in
# certbot's exception display code. Fixed in certbot ≥2.3.0.
# Debian 12 stable will not receive a backport, so pip is required.
#
# --break-system-packages is required on Debian 12 to install into the
# system Python without a virtualenv; this is safe here because the
# container is single-purpose and we control all packages.
# ---------------------------------------------------------------------------
RUN pip3 install --break-system-packages --quiet certbot \
    && certbot --version

# ---------------------------------------------------------------------------
# ttyd — web terminal server
# Official binary release from https://github.com/tsl0922/ttyd
# Supports amd64 and arm64 (Raspberry Pi, Apple M1/M2 via Docker).
# ---------------------------------------------------------------------------
ARG TTYD_VERSION=1.7.3
RUN set -eux; \
    ARCH="$(dpkg --print-architecture)"; \
    case "${ARCH}" in \
        amd64)  TTYD_ARCH="x86_64"  ;; \
        arm64)  TTYD_ARCH="aarch64" ;; \
        armhf)  TTYD_ARCH="armv7l"  ;; \
        *) echo "Unsupported architecture: ${ARCH}" >&2; exit 1 ;; \
    esac; \
    wget -q -O /usr/local/bin/ttyd \
        "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.${TTYD_ARCH}"; \
    chmod +x /usr/local/bin/ttyd; \
    ttyd --version

# ---------------------------------------------------------------------------
# Certbot renewal via cron
# Runs daily at 03:17 (staggered to avoid load spikes on Let's Encrypt).
# The deploy-hook reloads nginx so the new cert is served immediately.
# ---------------------------------------------------------------------------
RUN echo "17 3 * * * root certbot renew --quiet --deploy-hook 'nginx -s reload'" \
        > /etc/cron.d/certbot-renew \
    && chmod 0644 /etc/cron.d/certbot-renew

# ---------------------------------------------------------------------------
# xray.sh — copied into image; run by ttyd as the configuration interface
# ---------------------------------------------------------------------------
RUN mkdir -p /opt/xray
COPY xray.sh /opt/xray/xray.sh
RUN chmod +x /opt/xray/xray.sh

# ---------------------------------------------------------------------------
# Entrypoint — starts cron + background services + ttyd
# ---------------------------------------------------------------------------
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# ---------------------------------------------------------------------------
# Nginx default site cleanup
# The default Debian nginx config occupies port 80; xray.sh creates its own
# site config, so we remove the default to avoid conflicts.
# ---------------------------------------------------------------------------
RUN rm -f /etc/nginx/sites-enabled/default

# Expose all user-facing ports
EXPOSE 7681 80 443

ENTRYPOINT ["/entrypoint.sh"]
