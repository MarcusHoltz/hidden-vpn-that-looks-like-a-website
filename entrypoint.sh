#!/usr/bin/env bash
# =============================================================================
# entrypoint.sh  —  Container startup for xray-docker
#
# Execution order:
#   1. Create /var/log/xray so the log volume mount has a writable directory
#   2. Start cron                (certbot auto-renewal nightly)
#   3. Re-install XRAY binary    (if config exists but binary is gone after
#                                 container recreation — auto-recovers silently)
#   4. Generate self-signed TLS cert for ttyd (if not already present)
#   5. Write nginx SSL block for ttyd on TTYD_PORT and reload nginx
#   6. Re-start nginx + xray     (if xray.sh was already run previously)
#   7. exec ttyd                 (becomes PID 1; runs xray.sh in the browser)
#
# ttyd is exec'd so Docker SIGTERM/SIGINT are delivered directly to it and
# the container shuts down cleanly.
#
# TLS architecture for ttyd:
#   browser → https://<IP>:TTYD_PORT (nginx, self-signed cert)
#                   ↓ proxy_pass
#             http://127.0.0.1:TTYD_INTERNAL_PORT (ttyd, loopback only)
#
# ttyd's built-in --ssl flag is not compiled into the static GitHub release
# binaries (MbedTLS build, no SSL). Using nginx as the TLS terminator is the
# only reliable approach. ttyd itself must never be exposed on an external
# port — it binds loopback only.
# =============================================================================
set -euo pipefail

STATE_FILE="/etc/xray-setup/state.env"
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONF="/usr/local/etc/xray/config.json"

# Port nginx listens on externally (TLS, user-facing).
TTYD_PORT="${TTYD_PORT:-7681}"
# Port ttyd listens on internally (plain HTTP, loopback only, never exposed).
TTYD_INTERNAL_PORT="7682"

# Self-signed cert for nginx to serve ttyd over HTTPS.
TTYD_TLS_DIR="/etc/ttyd"
TTYD_CERT="${TTYD_TLS_DIR}/cert.pem"
TTYD_KEY="${TTYD_TLS_DIR}/key.pem"

# ---------------------------------------------------------------------------
# 1. Ensure log directories exist
# ---------------------------------------------------------------------------
mkdir -p /var/log/nginx /var/log/xray

# ---------------------------------------------------------------------------
# 2. Cron — certbot renewal job
# ---------------------------------------------------------------------------
echo "[entrypoint] Starting cron..."
service cron start 2>/dev/null || true

# ---------------------------------------------------------------------------
# 3. Auto-restore the XRAY binary after container recreation
# ---------------------------------------------------------------------------
if [[ -f "${STATE_FILE}" && -f "${XRAY_CONF}" && ! -x "${XRAY_BIN}" ]]; then
    echo "[entrypoint] State and config found but XRAY binary is missing."
    echo "[entrypoint] Re-installing XRAY binary — config and clients are preserved..."
    XRAY_RELEASE_BASE="https://github.com/XTLS/Xray-core/releases/latest/download"
    XRAY_DAT_DIR="/usr/local/share/xray"
    _arch=$(uname -m)
    case "${_arch}" in
        x86_64)        _zip="Xray-linux-64.zip" ;;
        aarch64|arm64) _zip="Xray-linux-arm64-v8a.zip" ;;
        armv7l)        _zip="Xray-linux-arm32-v7a.zip" ;;
        *)             _zip="Xray-linux-64.zip" ;;
    esac
    _tmp_zip=$(mktemp --suffix=.zip)
    _tmp_dir=$(mktemp -d)
    if curl -fsSL --retry 3 -o "${_tmp_zip}" "${XRAY_RELEASE_BASE}/${_zip}"; then
        python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" \
            "${_tmp_zip}" "${_tmp_dir}" \
            && install -m 755 "${_tmp_dir}/xray" "${XRAY_BIN}" \
            && mkdir -p "${XRAY_DAT_DIR}" \
            && for f in geoip.dat geosite.dat; do
                   [[ -f "${_tmp_dir}/${f}" ]] && install -m 644 "${_tmp_dir}/${f}" "${XRAY_DAT_DIR}/${f}" || true
               done \
            && echo "[entrypoint] XRAY binary restored." \
            || echo "[entrypoint] WARNING: XRAY reinstall failed. Open the web terminal to repair."
    else
        echo "[entrypoint] WARNING: Could not download XRAY release. Open the web terminal to repair."
    fi
    rm -f "${_tmp_zip}"; rm -rf "${_tmp_dir}"
fi

# ---------------------------------------------------------------------------
# 4. Generate self-signed TLS certificate for ttyd (idempotent)
#
# Valid for 10 years. The browser shows a one-time "untrusted cert" warning
# which the user accepts once. This cert is only for the admin terminal —
# encryption in transit is the goal, not third-party identity verification.
# ---------------------------------------------------------------------------
echo "[entrypoint] Checking ttyd TLS certificate..."
mkdir -p "${TTYD_TLS_DIR}"
chmod 700 "${TTYD_TLS_DIR}"

if [[ ! -f "${TTYD_CERT}" || ! -f "${TTYD_KEY}" ]]; then
    echo "[entrypoint] Generating self-signed cert for ttyd nginx SSL block..."
    openssl req -x509 \
        -newkey rsa:2048 \
        -keyout "${TTYD_KEY}" \
        -out    "${TTYD_CERT}" \
        -days   3650 \
        -nodes \
        -subj   "/CN=ttyd/O=xray-setup" \
        2>/dev/null
    chmod 600 "${TTYD_KEY}" "${TTYD_CERT}"
    echo "[entrypoint] ttyd TLS cert generated: ${TTYD_CERT}"
else
    echo "[entrypoint] ttyd TLS cert exists: ${TTYD_CERT}"
fi

# ---------------------------------------------------------------------------
# 5. Write nginx SSL server block for ttyd and reload nginx
#
# Written to /etc/nginx/conf.d/ which is included by the nginx Docker image.
# SSL only on TTYD_PORT — no plain HTTP block on this port. A plain HTTP
# listener on the same port as SSL causes nginx to serve plain HTTP and
# ignore the SSL block entirely, producing TLS errors in the browser.
#
# ttyd itself runs on 127.0.0.1:TTYD_INTERNAL_PORT (plain HTTP, loopback).
# This block is the only way to reach it externally, and only over HTTPS.
# ---------------------------------------------------------------------------
TTYD_NGINX_CONF="/etc/nginx/conf.d/xray-ttyd.conf"
echo "[entrypoint] Writing nginx SSL block for ttyd on port ${TTYD_PORT}..."
cat > "${TTYD_NGINX_CONF}" <<NGINXEOF
# ttyd web terminal — managed by entrypoint.sh. Do not edit by hand.
# SSL only on port ${TTYD_PORT}. Plain HTTP has no listener on this port.
server {
    listen      ${TTYD_PORT} ssl;
    listen      [::]:${TTYD_PORT} ssl;

    ssl_certificate     ${TTYD_CERT};
    ssl_certificate_key ${TTYD_KEY};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    location / {
        proxy_pass         http://127.0.0.1:${TTYD_INTERNAL_PORT};
        proxy_http_version 1.1;
        proxy_set_header   Upgrade    \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host       \$host;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
NGINXEOF
echo "[entrypoint] nginx ttyd SSL block written: ${TTYD_NGINX_CONF}"

# ---------------------------------------------------------------------------
# 6. Re-start nginx and xray if a previous installation exists
# ---------------------------------------------------------------------------
if [[ -f "${STATE_FILE}" ]]; then
    echo "[entrypoint] Existing installation found — starting services..."

    if nginx -t 2>/dev/null; then
        nginx
        echo "[entrypoint] nginx started (port ${TTYD_PORT} SSL for ttyd, 443 for xray)."
    else
        echo "[entrypoint] WARNING: nginx config test failed:" >&2
        nginx -t 2>&1 >&2 || true
        echo "[entrypoint] Open the web terminal to repair nginx config." >&2
    fi

    if [[ -x "${XRAY_BIN}" && -f "${XRAY_CONF}" ]]; then
        mkdir -p /var/log/xray
        "${XRAY_BIN}" run -config "${XRAY_CONF}" >> /var/log/xray/xray.log 2>&1 &
        echo "[entrypoint] XRAY started (PID $!)."
    else
        echo "[entrypoint] INFO: XRAY binary or config not found — run setup wizard." >&2
    fi
else
    # First run — no state file yet. nginx hasn't been configured by xray.sh.
    # Start nginx anyway so the ttyd SSL block on TTYD_PORT is active.
    # xray.sh will configure the main 443 block during the setup wizard.
    if nginx -t 2>/dev/null; then
        nginx
        echo "[entrypoint] nginx started (ttyd SSL only — xray not yet configured)."
    else
        echo "[entrypoint] WARNING: nginx config test failed on first run:" >&2
        nginx -t 2>&1 >&2 || true
    fi
fi

# ---------------------------------------------------------------------------
# 7. Launch ttyd
#
# ttyd binds to 127.0.0.1:TTYD_INTERNAL_PORT (loopback, plain HTTP only).
# nginx terminates TLS externally on TTYD_PORT and proxies here.
# ttyd must NEVER bind to 0.0.0.0 — that would expose plain HTTP to the
# internet with no TLS.
#
# Note: --writable is not supported in ttyd 1.7.3 (libwebsockets 4.3.2).
# The flag was added in a later release. Do not add it back without first
# verifying the ttyd version supports it.
# ---------------------------------------------------------------------------
TTYD_PORT="${TTYD_PORT:-7681}"

ttyd_args=(
    # Bind to loopback only — nginx handles external TLS on TTYD_PORT.
    --interface 127.0.0.1

    # Internal port (not exposed externally — nginx proxies TTYD_PORT here).
    --port "${TTYD_INTERNAL_PORT}"

    # Browser tab title
    --client-option titleFixed="XRAY Setup"

    # Suppress the "Leave site?" browser dialog.
    --client-option disableLeaveAlert=true

    # Canvas renderer for headless/remote browser compatibility.
    --client-option rendererType=canvas
)

if [[ -n "${TTYD_CREDENTIAL:-}" ]]; then
    ttyd_args+=(--credential "${TTYD_CREDENTIAL}")
    echo "[entrypoint] ttyd basic auth enabled (user: ${TTYD_CREDENTIAL%%:*})"
else
    echo "[entrypoint] ============================================================" >&2
    echo "[entrypoint] WARNING: TTYD_CREDENTIAL is not set in .env"                   >&2
    echo "[entrypoint] The terminal has NO password — anyone who can reach"           >&2
    echo "[entrypoint] port ${TTYD_PORT} can control this server."                    >&2
    echo "[entrypoint] Set TTYD_CREDENTIAL=user:password in your .env and restart."  >&2
    echo "[entrypoint] ============================================================" >&2
fi

echo "[entrypoint] Starting ttyd on 127.0.0.1:${TTYD_INTERNAL_PORT} (loopback only)..."
echo "[entrypoint] Browser terminal: https://<this-server-ip>:${TTYD_PORT}"

exec ttyd "${ttyd_args[@]}" bash /opt/xray/xray.sh
