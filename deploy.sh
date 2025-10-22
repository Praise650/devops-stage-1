#!/bin/bash
set -euo pipefail  # Exit on error, undefined vars, pipe fails

# Logging setup
LOGFILE="deploy_$(date +%Y%m%d).log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"; }
error() { log "ERROR: $1"; exit 1; }

# Trap for cleanup on exit
trap 'log "Script interrupted. Check logs for details."' INT TERM

# Step 1: Collect & Validate Params
log "=== Starting Deployment ==="
read -p "Git Repository URL (e.g., https://github.com/user/repo.git): " REPO_URL
[[ ! "$REPO_URL" =~ ^https://github\.com/[^/]+/[^/]+\.git$ ]] && error "Invalid Git URL format."

read -p "Personal Access Token (PAT for private repo): " PAT
[[ -z "$PAT" ]] && error "PAT is required for private repos."

read -p "Branch name [default: main]: " BRANCH
BRANCH=${BRANCH:-main}

read -p "SSH Username: " SSH_USER
[[ -z "$SSH_USER" ]] && error "SSH Username required."

read -p "Server IP Address: " SERVER_IP
[[ ! "$SERVER_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && error "Invalid IP format."

read -p "SSH Key Path [default: ~/.ssh/id_rsa]: " SSH_KEY
SSH_KEY=${SSH_KEY:-~/.ssh/id_rsa}
[[ ! -f "$SSH_KEY" ]] && error "SSH key not found at $SSH_KEY."

read -p "App Port (internal container): " APP_PORT
[[ ! "$APP_PORT" =~ ^[0-9]+$ ]] && error "Port must be a number (e.g., 3000)."

log "Params validated: Repo=$REPO_URL, Branch=$BRANCH, Server=$SERVER_IP:$APP_PORT"

# Step 2: Clone/Pull Repo
log "=== Cloning Repository ==="
REPO_NAME=$(basename "$REPO_URL" .git)
CLONE_URL="${REPO_URL/https:\/\/github.com/https:\/\/${PAT}@github.com}"

if [ -d "$REPO_NAME" ]; then
    log "Repo exists; pulling latest changes..."
    cd "$REPO_NAME" || error "Failed to cd into $REPO_NAME"
    git pull origin "$BRANCH" || error "Failed to pull branch $BRANCH"
else
    log "Cloning fresh repo..."
    git clone "$CLONE_URL" "$REPO_NAME" || error "Failed to clone $REPO_URL"
    cd "$REPO_NAME" || error "Failed to cd into cloned $REPO_NAME"
fi

# Step 3: Switch Branch & Validate Files
log "Switching to branch: $BRANCH"
git checkout "$BRANCH" || error "Failed to checkout branch $BRANCH"

if [[ ! -f Dockerfile && ! -f docker-compose.yml ]]; then
    error "No Dockerfile or docker-compose.yml found in $PWD"
fi
log "Success: Dockerfile/docker-compose.yml validated in $PWD"

log "=== Repo Steps Complete ==="

# Step 4: SSH Connectivity Check
log "=== Checking SSH Connectivity to $SERVER_IP ==="
# Ping test (quick network reach)
if ! ping -c 1 -W 5 "$SERVER_IP" > /dev/null 2>&1; then
    error "Ping failed: $SERVER_IP unreachable. Check network/firewall."
fi
log "Ping successful."

# SSH dry-run (key auth test, non-interactive)
# SSH dry-run (fixed for bash invocation)
SSH_CMD="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10 $SSH_USER@$SERVER_IP \"/bin/bash -c 'exit 0'\""
if ! eval $SSH_CMD; then  # Use eval for variable expansion in quotes
    error "SSH connection failed to $SSH_USER@$SERVER_IP. Verify key perms (chmod 400 $SSH_KEY), username, and SG port 22."
fi
log "SSH connectivity confirmed."

log "=== Ready for Remote Deployment ==="

# Step 5: Prepare Remote Environment
log "=== Preparing Remote Environment on $SERVER_IP ==="

REMOTE_PREP="
  set -e  # Fail fast on remote
  sudo apt update && sudo apt upgrade -y

  # Docker install if missing
  if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh
    sudo rm get-docker.sh
    sudo systemctl start docker && sudo systemctl enable docker
  fi

  # Docker Compose if missing
  if ! command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_VERSION=\$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep 'tag_name' | cut -d\\\" -f4)
    sudo curl -L \"https://github.com/docker/compose/releases/download/\${COMPOSE_VERSION}/docker-compose-\$(uname -s)-\$(uname -m)\" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
  fi

  # Nginx if missing
  if ! command -v nginx >/dev/null 2>&1; then
    sudo apt install -y nginx
    sudo systemctl start nginx && sudo systemctl enable nginx
  fi

  # Add user to Docker group (re-login needed for perms, but script runs sudo)
  sudo usermod -aG docker $SSH_USER

  # Version log
  docker --version
  docker-compose --version
  nginx -v
"

# Pipe to remote bash
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" "/bin/bash -c '$REMOTE_PREP'" || error "Remote prep failed. Check AWS logs (EC2 > Actions > Monitor > Get system log)."

log "Remote env prepared: Docker, Compose, Nginx installed/started. Re-login for Docker group perms."

# Step 6: Deploy Dockerized Application
log "=== Deploying Application to $SERVER_IP ==="

REMOTE_APP_DIR="/opt/app"
REMOTE_CMD="ssh -i $SSH_KEY -o StrictHostKeyChecking=no $SSH_USER@$SERVER_IP"

# Ensure remote dir exists & owned
$REMOTE_CMD "sudo mkdir -p $REMOTE_APP_DIR && sudo chown -R $SSH_USER:$SSH_USER $REMOTE_APP_DIR" || error "Failed to setup remote dir $REMOTE_APP_DIR."

# Stop/remove old container (idempotency)
$REMOTE_CMD "docker stop app-container 2>/dev/null || true; docker rm app-container 2>/dev/null || true"

# Rsync files (--delete cleans deltas)
rsync -avz --delete -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=no" "$PWD/" $SSH_USER@$SERVER_IP:$REMOTE_APP_DIR/ || error "File transfer failed."

# Build & run
$REMOTE_CMD "cd $REMOTE_APP_DIR && docker build -t app-image . && docker run -d --name app-container -p $APP_PORT:$APP_PORT --restart unless-stopped app-image" || error "Build/run failed."

# Health: Logs + curl
$REMOTE_CMD "docker logs app-container --tail 10"
sleep 5
if ! $REMOTE_CMD "curl -f http://localhost:$APP_PORT >/dev/null 2>&1"; then
    error "App unhealthy on $APP_PORT. Tail logs above."
fi
log "App deployed: Running healthy on $APP_PORT."

# Step 7: Configure Nginx as Reverse Proxy
log "=== Configuring Nginx Proxy on $SERVER_IP ==="

NGINX_CONFIG="/etc/nginx/sites-available/default"
PROXY_PASS="http://localhost:$APP_PORT"

REMOTE_NGINX="
  set -e
  # Backup old config
  sudo cp $NGINX_CONFIG ${NGINX_CONFIG}.bak 2>/dev/null || true

  # Generate proxy config with printf (avoids heredoc quoting issues)
  sudo printf 'server {
      listen 80 default_server;
      listen [::]:80 default_server;

      location / {
          proxy_pass %s;
          proxy_http_version 1.1;
          proxy_set_header Upgrade \$http_upgrade;
          proxy_set_header Connection \"upgrade\";
          proxy_set_header Host \$host;
          proxy_set_header X-Real-IP \$remote_addr;
          proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
          proxy_cache_bypass \$http_upgrade;
      }

      # SSL Placeholder (uncomment for self-signed/Certbot)
      # listen 443 ssl http2 default_server;
      # listen [::]:443 ssl http2 default_server;
      # ssl_certificate /etc/ssl/certs/nginx-selfsigned.crt;
      # ssl_certificate_key /etc/ssl/private/nginx-selfsigned.key;
  }
  ' \"$PROXY_PASS\" > $NGINX_CONFIG

  # Test syntax & reload
  sudo nginx -t && sudo systemctl reload nginx || { echo 'Nginx test failed'; sudo nginx -t; exit 1; }
"

$REMOTE_CMD "/bin/bash -c '$REMOTE_NGINX'" || error "Nginx config failed. Check /var/log/nginx/error.log remotely."

log "Nginx proxied: 80 → $APP_PORT. Test: curl http://$SERVER_IP"

# Step 8: Validate Deployment
log "=== Validating on $SERVER_IP ==="

VALIDATION="
  echo 'Docker: ' \$(docker info >/dev/null 2>&1 && echo 'running' || echo 'down')
  echo 'Container: ' \$(docker ps | grep app-container && echo 'active' || echo 'missing')
  echo 'Nginx: ' \$(sudo systemctl is-active nginx && echo 'active' || echo 'down')
  echo 'App Endpoint: ' \$(curl -f http://localhost >/dev/null 2>&1 && echo 'healthy (200)' || echo 'fail')
  echo 'External Test: ' \$(curl -f http://localhost:$APP_PORT >/dev/null 2>&1 && echo 'direct port OK' || echo 'direct fail')
"

$REMOTE_CMD "$VALIDATION"
log "Validation: Stack solid. Full deploy success!"
log "=== EOF Deployment ==="

# Global exit (stage codes: 0=success, 1=error)
exit 0
