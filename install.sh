#!/usr/bin/env bash
set -Eeuo pipefail

readonly APP_DIR="${OUTPUT_DIR:-/opt/newapi}"
readonly DOMAIN="${DOMAIN:-}"
readonly SSH_PORT="${SSH_PORT:-${SSH_CONNECTION:-}}"

log() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

validate_domain() {
  [[ -z "$DOMAIN" ]] && return 0
  [[ "$DOMAIN" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] \
    || die "DOMAIN must be a valid hostname, for example api.example.com"
}

secret_from_or_new() {
  local key="$1" env_file="$2" value=""
  if [[ -f "$env_file" ]]; then
    value="$(sed -n "s/^${key}=//p" "$env_file" | head -n1)"
  fi
  if [[ ! "$value" =~ ^[0-9a-f]{64}$ ]]; then
    value="$(openssl rand -hex 32)"
  fi
  printf '%s' "$value"
}

render_env() {
  local env_file="$APP_DIR/.env"
  local postgres_password redis_password session_secret
  postgres_password="$(secret_from_or_new POSTGRES_PASSWORD "$env_file")"
  redis_password="$(secret_from_or_new REDIS_PASSWORD "$env_file")"
  session_secret="$(secret_from_or_new SESSION_SECRET "$env_file")"

  umask 077
  cat >"$env_file" <<EOF
POSTGRES_PASSWORD=${postgres_password}
REDIS_PASSWORD=${redis_password}
SESSION_SECRET=${session_secret}
TZ=Asia/Shanghai
EOF
  chmod 600 "$env_file"
}

render_compose() {
  local port_block cookie_block caddy_block=""
  if [[ -n "$DOMAIN" ]]; then
    port_block=""
    cookie_block=$(cat <<EOF
      - SESSION_COOKIE_SECURE=true
      - SESSION_COOKIE_TRUSTED_URL=https://${DOMAIN}
EOF
)
    caddy_block=$(cat <<'EOF'

  caddy:
    image: caddy:2-alpine
    container_name: newapi-caddy
    restart: unless-stopped
    depends_on:
      new-api:
        condition: service_healthy
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    networks:
      - newapi
EOF
)
  else
    port_block=$(cat <<'EOF'
    ports:
      - "127.0.0.1:3000:3000"
EOF
)
    cookie_block=$(cat <<'EOF'
      - SESSION_COOKIE_SECURE=false
EOF
)
  fi

  cat >"$APP_DIR/compose.yaml" <<EOF
services:
  new-api:
    image: calciumion/new-api:latest
    container_name: new-api
    restart: unless-stopped
    command: --log-dir /app/logs
${port_block}
    volumes:
      - ./data:/data
      - ./logs:/app/logs
    environment:
      - SQL_DSN=postgresql://newapi:\${POSTGRES_PASSWORD}@postgres:5432/newapi
      - REDIS_CONN_STRING=redis://:\${REDIS_PASSWORD}@redis:6379/0
      - SESSION_SECRET=\${SESSION_SECRET}
      - TZ=\${TZ}
      - ERROR_LOG_ENABLED=true
      - BATCH_UPDATE_ENABLED=true
      - NODE_NAME=newapi-dmit-1
      - TRUSTED_PROXIES=172.28.0.0/24
${cookie_block}
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O - http://localhost:3000/api/status | grep -Eq '\"success\"[[:space:]]*:[[:space:]]*true' || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 10
      start_period: 30s
    networks:
      - newapi

  postgres:
    image: postgres:16-alpine
    container_name: newapi-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: newapi
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
      POSTGRES_DB: newapi
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U newapi -d newapi"]
      interval: 10s
      timeout: 5s
      retries: 10
    networks:
      - newapi

  redis:
    image: redis:7-alpine
    container_name: newapi-redis
    restart: unless-stopped
    command: ["redis-server", "--appendonly", "yes", "--requirepass", "\${REDIS_PASSWORD}"]
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD-SHELL", "redis-cli -a \"\${REDIS_PASSWORD}\" ping 2>/dev/null | grep -q PONG"]
      interval: 10s
      timeout: 5s
      retries: 10
    networks:
      - newapi
${caddy_block}

volumes:
  postgres_data:
  redis_data:
  caddy_data:
  caddy_config:

networks:
  newapi:
    driver: bridge
    ipam:
      config:
        - subnet: 172.28.0.0/24
EOF
}

render_caddyfile() {
  if [[ -z "$DOMAIN" ]]; then
    rm -f "$APP_DIR/Caddyfile"
    return 0
  fi
  cat >"$APP_DIR/Caddyfile" <<EOF
${DOMAIN} {
  encode zstd gzip
  reverse_proxy new-api:3000
  header {
    -Server
    X-Content-Type-Options nosniff
    X-Frame-Options SAMEORIGIN
    Referrer-Policy strict-origin-when-cross-origin
  }
}
EOF
}

render_backup_script() {
  cat >"$APP_DIR/newapi-backup" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

app_dir="${NEWAPI_APP_DIR:-/opt/newapi}"
backup_dir="$app_dir/backups"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
sql_tmp=""
files_tmp=""
paused=0

cleanup() {
  [[ -z "$sql_tmp" ]] || rm -f "$sql_tmp"
  [[ -z "$files_tmp" ]] || rm -f "$files_tmp"
  if (( paused )); then
    docker unpause new-api >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

mkdir -p "$backup_dir"
cd "$app_dir"
sql_tmp="$(mktemp "$backup_dir/.postgres-${stamp}.XXXXXX")"
files_tmp="$(mktemp "$backup_dir/.files-${stamp}.XXXXXX")"

docker compose exec -T postgres pg_dump -U newapi -d newapi | gzip -9 >"$sql_tmp"
gzip -t "$sql_tmp"
mv "$sql_tmp" "$backup_dir/postgres-${stamp}.sql.gz"
sql_tmp=""

docker pause new-api >/dev/null
paused=1
tar -czf "$files_tmp" data logs
tar -tzf "$files_tmp" >/dev/null
docker unpause new-api >/dev/null
paused=0
mv "$files_tmp" "$backup_dir/files-${stamp}.tar.gz"
files_tmp=""

find "$backup_dir" -type f -mtime +6 -delete
EOF
  chmod 750 "$APP_DIR/newapi-backup"
}

render_files() {
  validate_domain
  install -d -m 0750 "$APP_DIR" "$APP_DIR/data" "$APP_DIR/logs" "$APP_DIR/backups"
  render_env
  render_compose
  render_caddyfile
  render_backup_script
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log "Docker Compose is already installed"
    return
  fi

  log "Installing Docker Engine from Docker's official repository"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  . /etc/os-release
  cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}

configure_host_security() {
  local ssh_port="$SSH_PORT"
  [[ "$ssh_port" == *" "* ]] && ssh_port="${ssh_port##* }"
  [[ "$ssh_port" =~ ^[0-9]{1,5}$ ]] || ssh_port=22
  (( ssh_port >= 1 && ssh_port <= 65535 )) || die "SSH_PORT is outside the valid range"

  log "Configuring firewall and fail2ban"
  DEBIAN_FRONTEND=noninteractive apt-get install -y ufw fail2ban openssl
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "${ssh_port}/tcp" comment SSH
  if [[ -n "$DOMAIN" ]]; then
    ufw allow 80/tcp comment HTTP
    ufw allow 443/tcp comment HTTPS
  fi
  ufw --force enable
  systemctl enable --now fail2ban
}

install_backup_timer() {
  install -m 0750 "$APP_DIR/newapi-backup" /usr/local/sbin/newapi-backup

  cat >/etc/systemd/system/newapi-backup.service <<'EOF'
[Unit]
Description=Back up NewAPI data
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/newapi-backup
EOF

  cat >/etc/systemd/system/newapi-backup.timer <<'EOF'
[Unit]
Description=Nightly NewAPI backup

[Timer]
OnCalendar=*-*-* 03:20:00
RandomizedDelaySec=15m
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now newapi-backup.timer
}

main() {
  if [[ "${1:-}" == "--render-only" ]]; then
    command -v openssl >/dev/null 2>&1 || die "openssl is required"
    render_files
    return
  fi

  [[ "${EUID}" -eq 0 ]] || die "Run this installer as root"
  [[ -z "${OUTPUT_DIR:-}" || "$APP_DIR" == "/opt/newapi" ]] || die "OUTPUT_DIR is supported only with --render-only"
  [[ -r /etc/os-release ]] || die "Cannot identify this operating system"
  . /etc/os-release
  [[ "$ID" == "ubuntu" ]] || die "This installer supports Ubuntu only"
  [[ "$VERSION_ID" == "24.04" ]] || die "Ubuntu 24.04 LTS is required"

  install_docker
  configure_host_security
  render_files

  log "Validating the Docker Compose configuration"
  (cd "$APP_DIR" && docker compose config --quiet)
  log "Starting NewAPI, PostgreSQL, Redis, and optional Caddy"
  (cd "$APP_DIR" && docker compose pull && docker compose up -d --remove-orphans)
  install_backup_timer

  log "Deployment started"
  if [[ -n "$DOMAIN" ]]; then
    echo "Open: https://${DOMAIN}"
  else
    echo "NewAPI is bound to 127.0.0.1:3000 only."
    echo "From your iPad or Mac, create an SSH tunnel: ssh -L 3000:127.0.0.1:3000 root@SERVER_IP"
    echo "Then open: http://127.0.0.1:3000"
  fi
  echo "Check status: cd ${APP_DIR} && docker compose ps"
  echo "Secrets are stored only in ${APP_DIR}/.env with mode 600."
}

main "$@"
