#!/usr/bin/env bash
# Gets a Let's Encrypt wildcard certificate using Cloudflare DNS-01 challenge.
# Fully automated — no manual DNS records needed.
#
# Usage: ./get-cert.sh <domain> [cloudflare-api-token]
# Example: ./get-cert.sh example.com
#
# The token needs Zone:DNS:Edit permission for the domain.
# Create one at: https://dash.cloudflare.com/profile/api-tokens
set -euo pipefail

DOMAIN="${1:?Usage: $0 <domain> [cloudflare-api-token]}"
CF_TOKEN="${2:-}"
CREDENTIALS_DIR="$(cd "$(dirname "$0")/../credentials" 2>/dev/null && pwd || echo "$(dirname "$0")/../credentials")"

mkdir -p "$CREDENTIALS_DIR"

# Get token if not provided
if [[ -z "$CF_TOKEN" ]]; then
    if [[ -f "${CREDENTIALS_DIR}/cloudflare_token" ]]; then
        CF_TOKEN="$(cat "${CREDENTIALS_DIR}/cloudflare_token")"
        echo "Using saved Cloudflare token."
    else
        echo "============================================="
        echo "Cloudflare API Token required"
        echo "============================================="
        echo ""
        echo "Create a token at: https://dash.cloudflare.com/profile/api-tokens"
        echo "Required permission: Zone > DNS > Edit"
        echo "Zone resource: Include > Specific zone > ${DOMAIN}"
        echo ""
        read -s -p "Cloudflare API Token: " CF_TOKEN
        echo ""

        if [[ -z "$CF_TOKEN" ]]; then
            echo "Error: Token cannot be empty."
            exit 1
        fi

        read -p "Save token for future use? [Y/n] " SAVE
        if [[ "${SAVE,,}" != "n" ]]; then
            echo "$CF_TOKEN" > "${CREDENTIALS_DIR}/cloudflare_token"
            chmod 600 "${CREDENTIALS_DIR}/cloudflare_token"
            echo "Token saved to credentials/cloudflare_token"
        fi
    fi
fi

# Install certbot + cloudflare plugin
if ! command -v certbot &>/dev/null; then
    echo "Installing certbot..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get update && sudo apt-get install -y certbot
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y certbot
    elif command -v brew &>/dev/null; then
        brew install certbot
    else
        echo "Error: Please install certbot manually."
        exit 1
    fi
fi

if ! pip3 show certbot-dns-cloudflare &>/dev/null 2>&1; then
    echo "Installing certbot-dns-cloudflare plugin..."
    pip3 install certbot-dns-cloudflare
fi

# Write cloudflare credentials file (certbot requires a file)
CF_CREDS=$(mktemp)
chmod 600 "$CF_CREDS"
echo "dns_cloudflare_api_token = ${CF_TOKEN}" > "$CF_CREDS"

cleanup() {
    rm -f "$CF_CREDS"
}
trap cleanup EXIT

echo ""
echo "Requesting wildcard certificate for: ${DOMAIN}"
echo ""

CERTBOT_BIN="$(which certbot)"
sudo "$CERTBOT_BIN" certonly \
    --dns-cloudflare \
    --dns-cloudflare-credentials "$CF_CREDS" \
    --dns-cloudflare-propagation-seconds 30 \
    -d "${DOMAIN}" \
    -d "*.${DOMAIN}" \
    --agree-tos \
    --no-eff-email \
    --non-interactive \
    --register-unsafely-without-email

CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"
echo ""
echo "Certificate saved to: ${CERT_DIR}"
echo ""
echo "Push to Iran server:"
echo "  ./scripts/sync-certs.sh ${DOMAIN} localhost <target-ssh-host>"
