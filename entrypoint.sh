#!/usr/bin/env bash
# =============================================================================
# entrypoint.sh  —  Container startup for xray-docker
#
# Execution order:
#   1. Create /var/log/xray so the log volume mount has a writable directory
#   2. Start cron                (certbot auto-renewal nightly)
#   3. Re-install XRAY binary    (if config exists but binary is gone after
#                                 container recreation — auto-recovers silently)
#   4. Re-start nginx + xray     (if xray.sh was already run previously)
#   5. exec ttyd                 (becomes PID 1; runs xray.sh in the browser)
#
# ttyd is exec'd so Docker SIGTERM/SIGINT are delivered directly to it and
# the container shuts down cleanly.
# =============================================================================
set -euo pipefail

STATE_FILE="/etc/xray-setup/state.env"
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONF="/usr/local/etc/xray/config.json"

# ---------------------------------------------------------------------------
# 1. Ensure log directories exist
#    The volume mount creates /var/log/nginx and /var/log/xray as host dirs,
#    but the container also needs them to be present before nginx starts.
# ---------------------------------------------------------------------------
mkdir -p /var/log/nginx /var/log/xray

# ---------------------------------------------------------------------------
# 2. Cron — certbot renewal job; must be running before services start
# ---------------------------------------------------------------------------
echo "[entrypoint] Starting cron..."
service cron start 2>/dev/null || true

# ---------------------------------------------------------------------------
# 3. Auto-restore the XRAY binary after container recreation
#
# The XRAY binary lives at /usr/local/bin/xray inside the container's
# writable layer. When a container is recreated (docker compose down && up),
# that writable layer is discarded — the binary is gone, but the config and
# state volumes are still mounted and intact.
#
# We detect this state (config present, binary absent) and re-run the
# official XTLS installer to restore just the binary. The installer is
# idempotent, fast (~5 s), and does not touch the config file.
# This means all clients, certs, and settings survive container upgrades.
# ---------------------------------------------------------------------------
if [[ -f "${STATE_FILE}" && -f "${XRAY_CONF}" && ! -x "${XRAY_BIN}" ]]; then
    echo "[entrypoint] State and config found but XRAY binary is missing."
    echo "[entrypoint] This happens after 'docker compose down && up' (container recreation)."
    echo "[entrypoint] Re-installing XRAY binary now — config and clients are preserved..."
    # Download the release zip directly — the official installer requires
    # systemd and will fail in a Docker container.
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
# 4. Re-start nginx and xray if a previous installation exists
#
# This applies to every startup after the initial setup wizard has run.
# On the very first run (no state file), this block is skipped entirely
# and the user runs the wizard from the browser terminal.
# ---------------------------------------------------------------------------
if [[ -f "${STATE_FILE}" ]]; then
    echo "[entrypoint] Existing installation found — starting services..."

    # Test nginx config before starting (xray.sh wrote it; it should be valid)
    if nginx -t 2>/dev/null; then
        nginx
        echo "[entrypoint] nginx started."
    else
        echo "[entrypoint] WARNING: nginx config test failed. Check ./data/nginx/ or open the web terminal to repair." >&2
    fi

    # Start xray only if both the binary and config are present
    if [[ -x "${XRAY_BIN}" && -f "${XRAY_CONF}" ]]; then
        mkdir -p /var/log/xray
        "${XRAY_BIN}" run -config "${XRAY_CONF}" >> /var/log/xray/xray.log 2>&1 &
        echo "[entrypoint] XRAY started (PID $!)."
    else
        echo "[entrypoint] INFO: XRAY binary or config not found." >&2
        echo "[entrypoint] INFO: Open the web terminal to run the setup wizard." >&2
    fi
fi

# ---------------------------------------------------------------------------
# 5. Launch ttyd
#
# ttyd serves xray.sh as a browser-accessible terminal. The user opens
# http://<server>:7681, authenticates, and sees the xray.sh wizard or
# management menu directly. No SSH needed.
#
# When the user exits xray.sh (chooses "Exit" from the menu), ttyd shows
# a "session closed, reconnect?" prompt. The next connection re-runs
# xray.sh from scratch — no container restart needed.
#
# Environment variables (set via .env):
#   TTYD_PORT        Port to listen on              (default: 7681)
#   TTYD_CREDENTIAL  Basic auth as user:password    (default: unset = no auth)
# ---------------------------------------------------------------------------
TTYD_PORT="${TTYD_PORT:-7681}"

ttyd_args=(
    # Allow typing in the terminal (not read-only)
    --writable

    # Listen port
    --port "${TTYD_PORT}"

    # Reject a second browser connection while one session is active.
    # This is an admin tool; concurrent sessions would fight over the same
    # interactive prompts.
    --max-clients 1

    # Browser tab title
    --client-option titleFixed="XRAY Setup"

    # Suppress the "Leave site?" browser dialog — the session is stateless
    # from the browser's perspective (state is in the container volumes).
    --client-option disableLeaveAlert=true

    # Canvas renderer is more compatible than WebGL on headless/remote browsers
    --client-option rendererType=canvas
)

# Basic auth — strongly recommended when the port is internet-facing
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

echo "[entrypoint] Starting ttyd on port ${TTYD_PORT}..."
echo "[entrypoint] Browser terminal: http://<this-server-ip>:${TTYD_PORT}"

# exec replaces this shell process — ttyd becomes PID 1 and receives
# Docker's stop signal (SIGTERM by default) directly.
exec ttyd "${ttyd_args[@]}" bash /opt/xray/xray.sh
