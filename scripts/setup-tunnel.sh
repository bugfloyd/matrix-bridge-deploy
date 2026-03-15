#!/usr/bin/env bash
# Setup the federation SSH tunnel between Iran and EU servers.
#
# Usage: ./scripts/setup-tunnel.sh
#
# This runs tunnel.yml which:
#   1. Generates an SSH key pair on the Iran server
#   2. Deploys the matrix-tunnel systemd service on Iran
#   3. Authorizes the public key on the EU server
#
# Prerequisites:
#   - A SOCKS proxy running on Iran server at 127.0.0.1:2080
#   - Both servers deployed via ./scripts/setup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

# Read proxy port from group_vars
PROXY_PORT="${PROXY_PORT:-$(grep -oP '^\s*apt_proxy_port:\s*\K\d+' group_vars/all.yml 2>/dev/null || echo 8185)}"
PROXY_PID=""

# Check if Iran needs a proxy
NEEDS_PROXY=false
if [[ -f "group_vars/iran.yml" ]]; then
    if grep -qP '^\s*use_proxy:\s*true' group_vars/iran.yml 2>/dev/null; then
        NEEDS_PROXY=true
    fi
fi

cleanup() {
    if [[ -n "$PROXY_PID" ]]; then
        kill "$PROXY_PID" 2>/dev/null || true
        wait "$PROXY_PID" 2>/dev/null || true
        echo "[tunnel] Proxy stopped."
    fi
}
trap cleanup EXIT

EXTRA_SSH_ARGS=""

if [[ "$NEEDS_PROXY" == "true" ]]; then
    echo "[tunnel] Starting local HTTP proxy on port ${PROXY_PORT}..."
    python3 "${SCRIPT_DIR}/proxy.py" "$PROXY_PORT" &
    PROXY_PID=$!
    sleep 1

    if ! kill -0 "$PROXY_PID" 2>/dev/null; then
        echo "Error: Failed to start proxy. Is port ${PROXY_PORT} already in use?"
        exit 1
    fi

    echo "[tunnel] Proxy running (PID: ${PROXY_PID})"
    EXTRA_SSH_ARGS="-R ${PROXY_PORT}:127.0.0.1:${PROXY_PORT}"
fi

echo "==> Setting up federation SSH tunnel..."
ANSIBLE_SSH_COMMON_ARGS="${EXTRA_SSH_ARGS}" \
    ansible-playbook -i inventory/hosts.yml tunnel.yml "$@"
echo "==> Done. Check tunnel status: ssh iran-host 'systemctl status matrix-tunnel'"
