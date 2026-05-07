#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== SMS Server Setup ==="
echo ""

# --- Prerequisites ---
for cmd in docker cloudflared python3; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: $cmd is required but not installed"
        exit 1
    fi
done

COMPOSE_CMD=""
if docker compose version &>/dev/null; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
else
    echo "ERROR: docker compose or docker-compose is required"
    exit 1
fi

if [ ! -e /dev/ttyUSB2 ]; then
    echo "WARNING: /dev/ttyUSB2 not found. GSM modem may not be connected."
    echo "         The server will start but won't receive SMS until the modem is plugged in."
    echo ""
fi

# --- Cloudflare Tunnel ---
echo "--- Cloudflare Tunnel Setup ---"
echo ""
echo "You need a domain managed by Cloudflare. What domain will you use?"
echo "Example: mydomain.com"
read -rp "Domain: " DOMAIN

SUBDOMAIN="sms.${DOMAIN}"
echo "This will create a tunnel for: ${SUBDOMAIN}"
echo ""

if [ ! -f "$HOME/.cloudflared/cert.pem" ]; then
    echo "Logging into Cloudflare (browser will open)..."
    cloudflared tunnel login
fi

TUNNEL_NAME="sms-tunnel"
TUNNEL_ID=$(cloudflared tunnel list -o json 2>/dev/null | python3 -c "
import json, sys
tunnels = json.load(sys.stdin)
for t in tunnels:
    if t['name'] == '$TUNNEL_NAME':
        print(t['id'])
        break
" 2>/dev/null || true)

if [ -z "$TUNNEL_ID" ]; then
    echo "Creating tunnel: $TUNNEL_NAME"
    TUNNEL_ID=$(cloudflared tunnel create "$TUNNEL_NAME" 2>&1 | grep -oP 'with id \K[a-f0-9-]+')
    echo "Tunnel created: $TUNNEL_ID"
else
    echo "Using existing tunnel: $TUNNEL_ID"
fi

echo "Setting up DNS route: ${SUBDOMAIN} -> tunnel"
cloudflared tunnel route dns --overwrite-dns "$TUNNEL_NAME" "$SUBDOMAIN" 2>/dev/null || \
    cloudflared tunnel route dns "$TUNNEL_NAME" "$SUBDOMAIN"

# Copy credentials into project
mkdir -p cloudflared
CRED_FILE="$HOME/.cloudflared/${TUNNEL_ID}.json"
if [ -f "$CRED_FILE" ]; then
    cp "$CRED_FILE" cloudflared/credentials.json
    chmod 644 cloudflared/credentials.json
else
    echo "ERROR: Credentials file not found at $CRED_FILE"
    exit 1
fi

# Generate cloudflared config
cat > cloudflared/config.yml << EOF
tunnel: ${TUNNEL_ID}
credentials-file: /etc/cloudflared/credentials.json

ingress:
  - hostname: ${SUBDOMAIN}
    service: http://ntfy:80
  - service: http_status:404
EOF

echo "Cloudflare tunnel configured for ${SUBDOMAIN}"
echo ""

# --- ntfy auth ---
echo "--- ntfy Auth Setup ---"
echo ""
read -rsp "ntfy admin password (leave empty to keep existing): " NTFY_PASS
echo ""

mkdir -p ntfy-etc ntfy-cache

if [ -n "$NTFY_PASS" ]; then
    cat > ntfy-etc/server.yml << EOF
auth-file: /etc/ntfy/user.db
auth-default-access: write-only
EOF

    # Start ntfy temporarily to create the database
    docker rm -f ntfy-setup 2>/dev/null || true
    docker run -d --name ntfy-setup \
        -v "$SCRIPT_DIR/ntfy-etc:/etc/ntfy" \
        binwiederhier/ntfy serve
    sleep 3

    docker exec ntfy-setup sh -c "echo -e '${NTFY_PASS}\n${NTFY_PASS}' | ntfy user add --role=user admin"
    docker exec ntfy-setup ntfy access admin '*' read-write

    docker stop ntfy-setup && docker rm ntfy-setup
    chmod 666 ntfy-etc/user.db
    echo "ntfy user 'admin' created"
else
    echo "Keeping existing ntfy auth (make sure ntfy-etc/user.db exists)"
fi

echo ""

# --- Docker Compose ---
echo "--- Starting Services ---"
echo ""
$COMPOSE_CMD up -d --build

echo ""
echo "=== Setup Complete ==="
echo ""
echo "ntfy URL:  https://${SUBDOMAIN}"
echo "Username:  admin"
echo "Topic:     sms-forward"
echo ""
echo "On your phone: install ntfy app, set server to https://${SUBDOMAIN}"
echo "Login with admin / your password, subscribe to 'sms-forward'"
echo ""
echo "Commands:"
echo "  $COMPOSE_CMD logs -f sms-server   # watch SMS activity"
echo "  $COMPOSE_CMD down                 # stop everything"
echo "  $COMPOSE_CMD up -d                # start everything"
