#!/usr/bin/env bash
# Install the OpenReply worker on an Ubuntu VM (e.g. Oracle Cloud Always Free)
# as a systemd service. Safe to re-run: it also updates an existing install.
#
#   curl -fsSL https://raw.githubusercontent.com/<owner>/openreply/main/scripts/oracle-worker-setup.sh | sudo REPO_URL=https://github.com/<owner>/openreply.git bash
#
# Only the worker runs here. The web app stays on Vercel, and Postgres and
# Redis are managed services both processes reach over the network. The
# Dockerfile is not used because it runs `next build`, which a 1 GB VM cannot
# afford and the worker does not need.
#
# Secrets live in /etc/openreply-worker.env (mode 600), never in this script.

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/optical3r/openreply.git}"
BRANCH="${BRANCH:-main}"
APP_DIR="${APP_DIR:-/opt/openreply}"
ENV_FILE="/etc/openreply-worker.env"
SERVICE="openreply-worker"
APP_USER="openreply"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

echo "==> Packages"
apt-get update -y
apt-get install -y ca-certificates curl git
if ! command -v node >/dev/null || [ "$(node -p 'process.versions.node.split(".")[0]')" -lt 24 ]; then
  curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
  apt-get install -y nodejs
fi

# npm ci on the 1 GB AMD micro shape runs out of memory without swap.
if ! swapon --show | grep -q /swapfile; then
  echo "==> 2 GB swap"
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

id "$APP_USER" >/dev/null 2>&1 || useradd --system --home "$APP_DIR" --shell /usr/sbin/nologin "$APP_USER"

echo "==> Code"
if [ -d "$APP_DIR/.git" ]; then
  git -C "$APP_DIR" fetch --depth 1 origin "$BRANCH"
  git -C "$APP_DIR" reset --hard "origin/$BRANCH"
else
  git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$APP_DIR"
fi
chown -R "$APP_USER:$APP_USER" "$APP_DIR"

echo "==> Dependencies and Prisma client"
sudo -u "$APP_USER" -H bash -c "cd '$APP_DIR' && npm ci --no-audit --no-fund && npm run db:generate"

if [ ! -f "$ENV_FILE" ]; then
  cat > "$ENV_FILE" <<'EOF'
# Same values as the Vercel project, except DATABASE_URL: use the Supabase
# session pooler (port 5432). The VM is IPv4 and the direct host is IPv6-only.
NEXTAUTH_URL=
NEXTAUTH_SECRET=
ENCRYPTION_KEY=
DATABASE_URL=
REDIS_URL=
EOF
  echo "==> Created $ENV_FILE. Fill it in, then: sudo systemctl restart $SERVICE"
fi
chown root:root "$ENV_FILE"
chmod 600 "$ENV_FILE"

echo "==> systemd service"
cat > "/etc/systemd/system/$SERVICE.service" <<EOF
[Unit]
Description=OpenReply DM worker
After=network-online.target
Wants=network-online.target

[Service]
User=$APP_USER
WorkingDirectory=$APP_DIR
EnvironmentFile=$ENV_FILE
Environment=NODE_ENV=production
ExecStart=/usr/bin/npm run worker
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE"
if grep -qE '^DATABASE_URL=.+' "$ENV_FILE"; then
  systemctl restart "$SERVICE"
  echo "==> Started. Logs: journalctl -u $SERVICE -f"
else
  echo "==> Not started: $ENV_FILE is still empty."
fi
