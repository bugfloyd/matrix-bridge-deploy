#!/usr/bin/env bash
# Sets up the Matrix server for a specific region.
#
# Usage: ./scripts/setup.sh <target>
#   target: "iran", "europe", or a specific host name
#
# Examples:
#   ./scripts/setup.sh iran      # deploy to Iran (with SSH proxy)
#   ./scripts/setup.sh europe    # deploy to Europe (direct internet)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TARGET="${1:?Usage: $0 <target> (iran, europe, or host name)}"
shift || true

# Read proxy port from group_vars
PROXY_PORT="${PROXY_PORT:-$(grep -oP '^\s*apt_proxy_port:\s*\K\d+' "${PROJECT_DIR}/group_vars/all.yml" 2>/dev/null || echo 8080)}"
PROXY_PID=""

# Check if this target needs a proxy by looking at its group_vars
NEEDS_PROXY=false
if [[ -f "${PROJECT_DIR}/group_vars/${TARGET}.yml" ]]; then
    if grep -qP '^\s*use_proxy:\s*true' "${PROJECT_DIR}/group_vars/${TARGET}.yml" 2>/dev/null; then
        NEEDS_PROXY=true
    fi
fi

cleanup() {
    if [[ -n "$PROXY_PID" ]]; then
        kill "$PROXY_PID" 2>/dev/null || true
        wait "$PROXY_PID" 2>/dev/null || true
        echo "[setup] Proxy stopped."
    fi
}
trap cleanup EXIT

# Check dependencies
for cmd in ansible-playbook python3 ssh; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: $cmd is required but not installed."
        exit 1
    fi
done

EXTRA_SSH_ARGS=""

if [[ "$NEEDS_PROXY" == "true" ]]; then
    # Start local HTTP forward proxy for tunneling
    echo "[setup] Starting local HTTP proxy on port ${PROXY_PORT}..."
    python3 "${SCRIPT_DIR}/proxy.py" "$PROXY_PORT" &
    PROXY_PID=$!
    sleep 1

    if ! kill -0 "$PROXY_PID" 2>/dev/null; then
        echo "Error: Failed to start proxy. Is port ${PROXY_PORT} already in use?"
        exit 1
    fi

    echo "[setup] Proxy running (PID: ${PROXY_PID})"
    EXTRA_SSH_ARGS="-R ${PROXY_PORT}:127.0.0.1:${PROXY_PORT}"
fi

echo "[setup] Deploying to: ${TARGET}"

cd "$PROJECT_DIR"
ANSIBLE_SSH_COMMON_ARGS="${EXTRA_SSH_ARGS}" \
    ansible-playbook -i inventory/hosts.yml playbook.yml --limit "${TARGET}" "$@"

echo "[setup] Done!"
