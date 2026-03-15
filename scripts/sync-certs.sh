#!/usr/bin/env bash
# Copies TLS certificates to the Iran server.
#
# Source can be "localhost" (certs on this machine) or a remote SSH host.
#
# Usage: ./sync-certs.sh <domain> <source> <target-ssh-host>
# Examples:
#   ./sync-certs.sh example.com localhost my-server     # certs are local
#   ./sync-certs.sh example.com eu-server my-server     # certs on remote server
set -euo pipefail

DOMAIN="${1:?Usage: $0 <domain> <source> <target-ssh-host>}"
SOURCE="${2:?Usage: $0 <domain> <source> <target-ssh-host>}"
IR_HOST="${3:?Usage: $0 <domain> <source> <target-ssh-host>}"
CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"
TMP_DIR=$(mktemp -d)

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if [[ "$SOURCE" == "localhost" || "$SOURCE" == "local" ]]; then
    echo "Copying local certs from ${CERT_DIR}..."
    sudo cp "${CERT_DIR}/fullchain.pem" "${TMP_DIR}/"
    sudo cp "${CERT_DIR}/privkey.pem" "${TMP_DIR}/"
    sudo chown "$(id -u):$(id -g)" "${TMP_DIR}"/*
else
    echo "Fetching certs from ${SOURCE}..."
    scp "${SOURCE}:${CERT_DIR}/fullchain.pem" "${TMP_DIR}/"
    scp "${SOURCE}:${CERT_DIR}/privkey.pem" "${TMP_DIR}/"
fi

echo "Pushing certs to ${IR_HOST}..."
ssh "$IR_HOST" "sudo mkdir -p ${CERT_DIR}"
scp "${TMP_DIR}/fullchain.pem" "${IR_HOST}:/tmp/_fullchain.pem"
scp "${TMP_DIR}/privkey.pem" "${IR_HOST}:/tmp/_privkey.pem"
ssh "$IR_HOST" "sudo mv /tmp/_fullchain.pem ${CERT_DIR}/fullchain.pem && sudo mv /tmp/_privkey.pem ${CERT_DIR}/privkey.pem && sudo chmod 644 ${CERT_DIR}/fullchain.pem && sudo chmod 600 ${CERT_DIR}/privkey.pem"

echo "Reloading nginx..."
ssh "$IR_HOST" "cd /opt/matrix && sudo docker compose exec nginx nginx -s reload" || \
    echo "Warning: Could not reload nginx. You may need to restart the stack."

echo "Certificates synced successfully."
