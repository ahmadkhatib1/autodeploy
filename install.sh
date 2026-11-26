#!/usr/bin/env bash
# autodeploy installer — run once on a fresh Ubuntu/Debian server as root:
#   sudo bash install.sh
# Safe to re-run: it keeps existing projects, keys and n8n data.
set -Eeuo pipefail

SRC_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
AUTODEPLOY_HOME="${AUTODEPLOY_HOME:-/opt/autodeploy}"
AUTODEPLOY_USER="${AUTODEPLOY_USER:-deploy}"
NODE_MAJOR="${NODE_MAJOR:-22}"
N8N_DIR="$AUTODEPLOY_HOME/n8n"

info() { echo; echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root: sudo bash install.sh"
[[ -f /etc/os-release ]] || die "unsupported OS"
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "ubuntu" || "${ID:-}" == "debian" || "${ID_LIKE:-}" == *debian* ]] || die "this installer supports Ubuntu/Debian only"

# ------------------------------------------------------------------ packages
info "Installing system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y git curl jq ca-certificates openssh-server openssl tar util-linux sudo

if ! command -v docker >/dev/null 2>&1; then
  info "Installing Docker"
  curl -fsSL https://get.docker.com | sh
fi
docker compose version >/dev/null 2>&1 || die "docker compose plugin is missing"

node_major="$(node -v 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/' || true)"
if [[ -z "$node_major" || "$node_major" -lt 18 ]]; then
  info "Installing Node.js $NODE_MAJOR"
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
  apt-get install -y nodejs
fi
corepack enable >/dev/null 2>&1 || true
command -v pm2 >/dev/null 2>&1 || { info "Installing pm2"; npm install -g pm2; }

# ------------------------------------------------------------------ user & files
if ! id "$AUTODEPLOY_USER" >/dev/null 2>&1; then
  info "Creating user '$AUTODEPLOY_USER'"
  useradd -m -s /bin/bash "$AUTODEPLOY_USER"
fi
DEPLOY_HOME="$(getent passwd "$AUTODEPLOY_USER" | cut -d: -f6)"

info "Installing autodeploy to $AUTODEPLOY_HOME"
install -d -m 755 "$AUTODEPLOY_HOME"
for d in bin lib apps logs locks; do install -d -o "$AUTODEPLOY_USER" -g "$AUTODEPLOY_USER" -m 755 "$AUTODEPLOY_HOME/$d"; done
for d in config projects keys; do install -d -o "$AUTODEPLOY_USER" -g "$AUTODEPLOY_USER" -m 700 "$AUTODEPLOY_HOME/$d"; done
install -d -m 700 "$N8N_DIR"

install -m 755 "$SRC_DIR"/bin/* "$AUTODEPLOY_HOME/bin/"
install -m 644 "$SRC_DIR"/lib/* "$AUTODEPLOY_HOME/lib/"
install -m 644 "$SRC_DIR/n8n/workflow.json" "$N8N_DIR/workflow.json"
ln -sfn "$AUTODEPLOY_HOME/bin/autodeploy" /usr/local/bin/autodeploy

info "Enabling pm2 on boot for '$AUTODEPLOY_USER'"
pm2 startup systemd -u "$AUTODEPLOY_USER" --hp "$DEPLOY_HOME" >/dev/null

# ------------------------------------------------------------------ SSH key for n8n
# n8n gets a key that can ONLY run trigger.sh (forced command), only from Docker networks.
KEY="$N8N_DIR/n8n_ssh_key"
if [[ ! -f "$KEY" ]]; then
  info "Creating SSH key for n8n"
  ssh-keygen -q -t ed25519 -N "" -C "n8n-autodeploy" -f "$KEY"
fi
chmod 600 "$KEY"
install -d -o "$AUTODEPLOY_USER" -g "$AUTODEPLOY_USER" -m 700 "$DEPLOY_HOME/.ssh"
AUTH="$DEPLOY_HOME/.ssh/authorized_keys"
touch "$AUTH"
PUB="$(cat "$KEY.pub")"
if ! grep -qF "$PUB" "$AUTH"; then
  echo "restrict,command=\"$AUTODEPLOY_HOME/bin/trigger.sh\",from=\"172.16.0.0/12,10.0.0.0/8,192.168.0.0/16,127.0.0.1,::1\" $PUB" >> "$AUTH"
fi
chown "$AUTODEPLOY_USER:$AUTODEPLOY_USER" "$AUTH"
chmod 600 "$AUTH"
systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1 || true

# ------------------------------------------------------------------ n8n
info "Setting up n8n"
if [[ -f "$N8N_DIR/.env" ]]; then
  # shellcheck disable=SC1091
  N8N_DOMAIN="$(grep -E '^N8N_DOMAIN=' "$N8N_DIR/.env" | cut -d= -f2- || true)"
  echo "Keeping existing n8n settings (domain: ${N8N_DOMAIN:-none})"
else
  N8N_DOMAIN="${N8N_DOMAIN:-}"
  if [[ -z "$N8N_DOMAIN" && -t 0 ]]; then
    echo "A domain gives n8n HTTPS (recommended). Point an A record to this server first,"
    echo "e.g. n8n.example.com. Leave empty to use http://SERVER_IP:5678."
    read -r -p "Domain for n8n: " N8N_DOMAIN
  fi
  N8N_DOMAIN="${N8N_DOMAIN//[[:space:]]/}"
  if [[ -n "$N8N_DOMAIN" ]]; then
    [[ "$N8N_DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die "invalid domain"
    WEBHOOK_URL="https://$N8N_DOMAIN/"
    PROTOCOL=https; HOST="$N8N_DOMAIN"; SECURE_COOKIE=true
  else
    SERVER_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
    WEBHOOK_URL="http://$SERVER_IP:5678/"
    PROTOCOL=http; HOST="$SERVER_IP"; SECURE_COOKIE=false
  fi
  umask 077
  cat > "$N8N_DIR/.env" <<EOF
N8N_DOMAIN=$N8N_DOMAIN
N8N_HOST=$HOST
N8N_PROTOCOL=$PROTOCOL
WEBHOOK_URL=$WEBHOOK_URL
N8N_SECURE_COOKIE=$SECURE_COOKIE
N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)
GENERIC_TIMEZONE=${TZ_NAME:-Asia/Damascus}
TZ=${TZ_NAME:-Asia/Damascus}
EOF
  umask 022
fi

WEBHOOK_URL="$(grep -E '^WEBHOOK_URL=' "$N8N_DIR/.env" | cut -d= -f2-)"

if [[ -n "$N8N_DOMAIN" ]]; then
  cat > "$N8N_DIR/Caddyfile" <<EOF
$N8N_DOMAIN {
  reverse_proxy n8n:5678
}
EOF
  cat > "$N8N_DIR/docker-compose.yml" <<'EOF'
services:
  n8n:
    image: docker.n8n.io/n8nio/n8n:latest
    restart: unless-stopped
    env_file: .env
    environment:
      - N8N_PORT=5678
      - N8N_RUNNERS_ENABLED=true
      - N8N_DIAGNOSTICS_ENABLED=false
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - n8n_data:/home/node/.n8n
  caddy:
    image: caddy:2
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
volumes:
  n8n_data:
  caddy_data:
  caddy_config:
EOF
else
  cat > "$N8N_DIR/docker-compose.yml" <<'EOF'
services:
  n8n:
    image: docker.n8n.io/n8nio/n8n:latest
    restart: unless-stopped
    env_file: .env
    environment:
      - N8N_PORT=5678
      - N8N_RUNNERS_ENABLED=true
      - N8N_DIAGNOSTICS_ENABLED=false
    ports:
      - "5678:5678"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - n8n_data:/home/node/.n8n
volumes:
  n8n_data:
EOF
fi

(cd "$N8N_DIR" && docker compose up -d)

# Base URL that add-project prints for each project's GitLab webhook.
SERVER_ENV="$AUTODEPLOY_HOME/config/server.env"
umask 077
printf "WEBHOOK_BASE='%swebhook/deploy'\n" "$WEBHOOK_URL" > "$SERVER_ENV"
umask 022
chown "$AUTODEPLOY_USER:$AUTODEPLOY_USER" "$SERVER_ENV"

# ------------------------------------------------------------------ notifications
if [[ -t 0 ]]; then
  info "Notifications"
  sudo -u "$AUTODEPLOY_USER" -H env AUTODEPLOY_HOME="$AUTODEPLOY_HOME" "$AUTODEPLOY_HOME/bin/notify-setup.sh" || true
fi

# ------------------------------------------------------------------ done
N8N_URL="${WEBHOOK_URL%/}"
cat <<EOF

==================================================================
 autodeploy is installed.

 Finish n8n (one time, ~3 minutes):

 1) Open $N8N_URL and create your n8n owner account.

 2) Credentials > Add credential > "SSH Private Key":
      Name:        autodeploy server
      Host:        host.docker.internal
      Port:        22
      Username:    $AUTODEPLOY_USER
      Private Key: (paste everything below, including the BEGIN/END lines)

$(cat "$KEY")

 3) Workflows > Import from file: $N8N_DIR/workflow.json
    (or copy it to your computer first). Open the "Run deploy on server"
    node, pick the "autodeploy server" credential, Save, then switch the
    workflow to Active.

 Then add your first project:
      autodeploy add

 Change notification channels later:
      autodeploy notify-setup
==================================================================
EOF
if [[ -z "$N8N_DOMAIN" ]]; then
  echo "NOTE: n8n is on plain HTTP. Open port 5678 in your firewall, and add a domain later for HTTPS."
fi
