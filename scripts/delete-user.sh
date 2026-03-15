#!/usr/bin/env bash
# Deactivates and erases a Matrix user from the server.
# Usage: ./delete-user.sh <ssh-host> <username>
set -euo pipefail

MATRIX_DIR="${MATRIX_BASE_DIR:-/opt/matrix}"

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <ssh-host> <username>"
    echo "Examples:"
    echo "  $0 my-server alice"
    echo "  $0 my-server bob"
    exit 1
fi

SSH_HOST="$1"
USERNAME="$2"

# Get server_name from homeserver.yaml on the server
SERVER_NAME=$(ssh "$SSH_HOST" "grep '^server_name:' ${MATRIX_DIR}/synapse/homeserver.yaml | awk '{print \$2}' | tr -d '\"'")
USER_ID="@${USERNAME}:${SERVER_NAME}"
ENCODED_USER_ID=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${USER_ID}', safe=''))")

echo "Deleting user: ${USER_ID}"
read -p "Are you sure? This cannot be undone. [y/N] " CONFIRM
if [[ "${CONFIRM,,}" != "y" ]]; then
    echo "Cancelled."
    exit 0
fi

read -p "Admin username: " ADMIN_USER
read -s -p "Admin password: " ADMIN_PASS
echo

ssh "$SSH_HOST" "cd ${MATRIX_DIR} && docker compose exec -T synapse bash -c '
TOKEN=\$(curl -sf -X POST http://localhost:8008/_matrix/client/r0/login \
  -H \"Content-Type: application/json\" \
  -d \"{\\\"type\\\": \\\"m.login.password\\\", \\\"user\\\": \\\"${ADMIN_USER}\\\", \\\"password\\\": \\\"${ADMIN_PASS}\\\"}\" \
  | python3 -c \"import sys,json; print(json.load(sys.stdin)[\\\"access_token\\\"])\")

curl -sf -X POST http://localhost:8008/_synapse/admin/v1/deactivate/${ENCODED_USER_ID} \
  -H \"Content-Type: application/json\" \
  -H \"Authorization: Bearer \$TOKEN\" \
  -d \"{\\\"erase\\\": true}\"
'"

echo ""
echo "User '${USERNAME}' has been deleted."
