#!/usr/bin/env bash
# Creates a new Matrix user on the server.
# Usage: ./create-user.sh <ssh-host> <username> [--admin]
set -euo pipefail

MATRIX_DIR="${MATRIX_BASE_DIR:-/opt/matrix}"

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <ssh-host> <username> [--admin]"
    echo "Examples:"
    echo "  $0 my-server admin --admin"
    echo "  $0 my-server alice"
    exit 1
fi

SSH_HOST="$1"
USERNAME="$2"
ADMIN_FLAG=""

if [[ "${3:-}" == "--admin" ]]; then
    ADMIN_FLAG="--admin"
fi

read -s -p "Password for ${USERNAME}: " PASSWORD
echo

ssh "$SSH_HOST" "cd ${MATRIX_DIR} && docker compose exec -T synapse \
    register_new_matrix_user \
    -u '${USERNAME}' \
    -p '${PASSWORD}' \
    ${ADMIN_FLAG} \
    -c /data/homeserver.yaml \
    http://localhost:8008"

echo "User '${USERNAME}' created successfully."
