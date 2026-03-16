#!/usr/bin/env bash
# Sets up the xray federation tunnel between Iran and EU servers.
#
# Usage: ./scripts/setup-tunnel.sh
#
# This runs tunnel.yml which:
#   1. Downloads xray binary and generates VLESS UUID
#   2. Installs xray on both servers
#   3. Configures Iran as bridge (through SOCKS proxy) and EU as portal
#   4. Starts xray services on both servers
#
# Prerequisites:
#   - A SOCKS proxy running on Iran server (e.g. mihomo on port 2080)
#   - Both servers deployed via ./scripts/setup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

echo "==> Setting up xray federation tunnel..."
ansible-playbook -i inventory/hosts.yml tunnel.yml "$@"
echo "==> Done."
echo ""
echo "Check tunnel status:"
echo "  Iran:  ssh ir-host 'systemctl status xray-federation'"
echo "  EU:    ssh eu-host 'systemctl status xray'"
echo ""
echo "Test federation:"
echo "  Iran→EU: ssh ir-host 'curl -sf -m 4 https://127.0.0.1:<eu-fed-port>/_matrix/federation/v1/version -k'"
echo "  EU→Iran: ssh eu-host 'curl -sf -m 4 https://127.0.0.1:<ir-fed-port>/_matrix/federation/v1/version -k'"
