#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

log()  { echo "[$(date +%H:%M:%S)] $*"; }
warn() { echo "[$(date +%H:%M:%S)] WARN: $*" >&2; }
die()  { echo "[$(date +%H:%M:%S)] FATAL: $*" >&2; exit 1; }

echo ""
echo "=== SMS Server Setup ==="
echo ""

# --- Prerequisites ---
log "Checking prerequisites..."

for cmd in docker cloudflared python3; do
    if ! command -v "$cmd" &>/dev/null; then
        die "$cmd is required but not installed"
    fi
done

COMPOSE_CMD=""
if docker compose version &>/dev/null; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
else
    die "docker compose or docker-compose is required"
fi
log "Using compose command: $COMPOSE_CMD"

if [ ! -e /dev/ttyUSB2 ]; then
    warn "/dev/ttyUSB2 not found — SMS won't work until modem is plugged in"
fi

# --- Cloudflare Tunnel ---
echo ""
echo "--- Cloudflare Tunnel Setup ---"
echo ""

read -rp "Cloudflare domain (e.g. mydomain.com): " DOMAIN
SUBDOMAIN="sms.${DOMAIN}"
log "Will configure: ${SUBDOMAIN}"

if [ ! -f "$HOME/.cloudflared/cert.pem" ]; then
    log "Not logged into Cloudflare. Open this URL on any browser:"
    cloudflared tunnel login || die "cloudflared login failed"
fi

TUNNEL_NAME="sms-tunnel"

# Clean up old tunnel — ignore errors if it doesn't exist
log "Cleaning up any old tunnel named '$TUNNEL_NAME'..."
cloudflared tunnel cleanup "$TUNNEL_NAME" 2>/dev/null || true
cloudflared tunnel delete -f "$TUNNEL_NAME" 2>/dev/null || true

log "Creating tunnel: $TUNNEL_NAME"
TUNNEL_OUTPUT=$(cloudflared tunnel create "$TUNNEL_NAME" 2>&1)
TUNNEL_EXIT=$?
echo "$TUNNEL_OUTPUT"

if [ $TUNNEL_EXIT -ne 0 ]; then
    die "Tunnel creation failed (exit $TUNNEL_EXIT)"
fi

TUNNEL_ID=$(echo "$TUNNEL_OUTPUT" | grep -oP 'with id \K[a-f0-9-]+')
if [ -z "$TUNNEL_ID" ]; then
    die "Could not parse tunnel ID from output above"
fi
log "Tunnel ID: $TUNNEL_ID"

# Delete any existing DNS record for this subdomain first
log "Cleaning up old DNS record for ${SUBDOMAIN}..."
cloudflared tunnel route ip delete "$SUBDOMAIN" 2>/dev/null || true

log "Creating DNS route: ${SUBDOMAIN} -> ${TUNNEL_NAME}"
ROUTE_OUTPUT=$(cloudflared tunnel route dns --overwrite-dns "$TUNNEL_NAME" "$SUBDOMAIN" 2>&1)
ROUTE_EXIT=$?
echo "$ROUTE_OUTPUT"

if [ $ROUTE_EXIT -ne 0 ]; then
    warn "DNS route may have failed. If the tunnel doesn't work, delete the CNAME"
    warn "record for 'sms' in Cloudflare DNS dashboard, then run:"
    warn "  cloudflared tunnel route dns --overwrite-dns $TUNNEL_NAME $SUBDOMAIN"
fi

# Copy credentials into project
mkdir -p cloudflared
CRED_FILE="$HOME/.cloudflared/${TUNNEL_ID}.json"
if [ ! -f "$CRED_FILE" ]; then
    die "Credentials file not found at $CRED_FILE"
fi
cp "$CRED_FILE" cloudflared/credentials.json
chmod 644 cloudflared/credentials.json
log "Credentials copied to cloudflared/credentials.json"

# Generate cloudflared config
cat > cloudflared/config.yml << EOF
tunnel: ${TUNNEL_ID}
credentials-file: /etc/cloudflared/credentials.json

ingress:
  - hostname: ${SUBDOMAIN}
    service: http://ntfy:80
  - service: http_status:404
EOF
log "Generated cloudflared/config.yml"

# --- ntfy Auth ---
echo ""
echo "--- ntfy Auth Setup ---"
echo ""

read -rsp "ntfy admin password (leave empty to keep existing): " NTFY_PASS
echo ""

mkdir -p ntfy-etc ntfy-cache

if [ -n "$NTFY_PASS" ]; then
    cat > ntfy-etc/server.yml << 'SERVEREOF'
auth-file: /etc/ntfy/user.db
auth-default-access: write-only
SERVEREOF
    log "Wrote ntfy-etc/server.yml"

    # Remove any old setup container
    docker rm -f ntfy-setup 2>/dev/null || true

    log "Starting temporary ntfy container to create user..."
    docker run -d --name ntfy-setup \
        -v "$SCRIPT_DIR/ntfy-etc:/etc/ntfy" \
        docker.io/binwiederhier/ntfy serve 2>&1
    sleep 4

    log "Creating admin user..."
    USER_ADD_OUTPUT=$(docker exec ntfy-setup sh -c "echo -e '${NTFY_PASS}\n${NTFY_PASS}' | ntfy user add --role=user admin" 2>&1)
    USER_ADD_EXIT=$?
    echo "$USER_ADD_OUTPUT"

    if [ $USER_ADD_EXIT -ne 0 ]; then
        if echo "$USER_ADD_OUTPUT" | grep -q "already exists"; then
            log "User 'admin' already exists — skipping creation"
        else
            warn "User creation had an error (see above). The user might already exist."
        fi
    fi

    log "Granting admin read-write access..."
    docker exec ntfy-setup ntfy access admin '*' read-write 2>&1 || true

    docker stop ntfy-setup 2>/dev/null || true
    docker rm ntfy-setup 2>/dev/null || true

    # Fix permissions (Docker creates files as root)
    sudo chown "$(whoami):$(whoami)" ntfy-etc/user.db 2>/dev/null || true
    chmod 666 ntfy-etc/user.db 2>/dev/null || true
    log "ntfy auth configured"
else
    if [ ! -f ntfy-etc/user.db ]; then
        die "No existing user.db found. Run again with a password to create one."
    fi
    log "Keeping existing ntfy auth"
fi

# --- Start Services ---
echo ""
echo "--- Starting Services ---"
log "Building and starting containers..."
$COMPOSE_CMD up -d --build 2>&1

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
