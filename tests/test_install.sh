#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
installer="$repo_dir/install.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$installer" ]] || fail "install.sh is missing"
bash -n "$installer" || fail "install.sh has invalid Bash syntax"

local_out="$tmp_dir/local"
NEWAPI_TEST_MODE=1 OUTPUT_DIR="$local_out" bash "$installer" --render-only

[[ -f "$local_out/compose.yaml" ]] || fail "local compose.yaml was not rendered"
[[ -f "$local_out/.env" ]] || fail "local .env was not rendered"
[[ "$(stat -c '%a' "$local_out/.env")" == "600" ]] || fail ".env permissions are not 600"
grep -Fq '127.0.0.1:3000:3000' "$local_out/compose.yaml" || fail "NewAPI is not loopback-only without a domain"
! grep -Eq '(^|[[:space:]-])(5432|6379):' "$local_out/compose.yaml" || fail "database or Redis is exposed on the host"
grep -Eq '^POSTGRES_PASSWORD=[0-9a-f]{64}$' "$local_out/.env" || fail "PostgreSQL secret is not a 64-character hex value"
grep -Eq '^REDIS_PASSWORD=[0-9a-f]{64}$' "$local_out/.env" || fail "Redis secret is not a 64-character hex value"
grep -Eq '^SESSION_SECRET=[0-9a-f]{64}$' "$local_out/.env" || fail "session secret is not a 64-character hex value"
grep -Fq 'pg_isready -U newapi -d newapi' "$local_out/compose.yaml" || fail "PostgreSQL health check is missing"
grep -Fq 'redis-cli -a' "$local_out/compose.yaml" || fail "Redis health check is missing"
grep -Fq '\"success\"[[:space:]]*:[[:space:]]*true' "$local_out/compose.yaml" || fail "NewAPI health check does not require success=true"
[[ ! -e "$local_out/Caddyfile" ]] || fail "Caddyfile must not be rendered without a domain"
[[ -x "$local_out/newapi-backup" ]] || fail "backup script was not rendered executable"

domain_out="$tmp_dir/domain"
NEWAPI_TEST_MODE=1 OUTPUT_DIR="$domain_out" DOMAIN=api.example.com bash "$installer" --render-only

[[ -f "$domain_out/Caddyfile" ]] || fail "Caddyfile was not rendered for domain mode"
grep -Fq 'api.example.com {' "$domain_out/Caddyfile" || fail "Caddyfile does not contain the requested domain"
grep -Fq '80:80' "$domain_out/compose.yaml" || fail "HTTP port is missing in domain mode"
grep -Fq '443:443' "$domain_out/compose.yaml" || fail "HTTPS port is missing in domain mode"
grep -Fq 'SESSION_COOKIE_SECURE=true' "$domain_out/compose.yaml" || fail "secure session cookies are not enabled in domain mode"
grep -Fq 'SESSION_COOKIE_TRUSTED_URL=https://api.example.com' "$domain_out/compose.yaml" || fail "trusted HTTPS origin is missing"

OUTPUT_DIR="$domain_out" bash "$installer" --render-only
[[ ! -e "$domain_out/Caddyfile" ]] || fail "Caddyfile was not removed when returning to local mode"

if DOMAIN='bad domain' NEWAPI_TEST_MODE=1 OUTPUT_DIR="$tmp_dir/bad" bash "$installer" --render-only >/dev/null 2>&1; then
  fail "invalid domains must be rejected"
fi

backup_app="$tmp_dir/backup-app"
mkdir -p "$backup_app/data" "$backup_app/logs" "$backup_app/backups" "$tmp_dir/bin"
printf 'asset\n' >"$backup_app/data/asset.txt"
printf 'log\n' >"$backup_app/logs/newapi.log"
cat >"$tmp_dir/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  compose)
    printf 'partial sql\n'
    exit "${FAKE_DOCKER_DUMP_EXIT:-0}"
    ;;
  pause)
    printf 'pause\n' >>"${FAKE_DOCKER_LOG:?}"
    ;;
  unpause)
    printf 'unpause\n' >>"${FAKE_DOCKER_LOG:?}"
    ;;
esac
EOF
chmod +x "$tmp_dir/bin/docker"

if PATH="$tmp_dir/bin:$PATH" NEWAPI_APP_DIR="$backup_app" FAKE_DOCKER_LOG="$tmp_dir/docker.log" FAKE_DOCKER_DUMP_EXIT=1 "$local_out/newapi-backup" >/dev/null 2>&1; then
  fail "backup must fail when pg_dump fails"
fi
if find "$backup_app/backups" -type f | grep -q .; then
  fail "failed backup published a partial artifact"
fi

PATH="$tmp_dir/bin:$PATH" NEWAPI_APP_DIR="$backup_app" FAKE_DOCKER_LOG="$tmp_dir/docker.log" "$local_out/newapi-backup"
find "$backup_app/backups" -name 'postgres-*.sql.gz' -type f | grep -q . || fail "successful database backup is missing"
find "$backup_app/backups" -name 'files-*.tar.gz' -type f | grep -q . || fail "successful file backup is missing"
grep -Fxq pause "$tmp_dir/docker.log" || fail "NewAPI was not paused for a consistent file backup"
grep -Fxq unpause "$tmp_dir/docker.log" || fail "NewAPI was not unpaused after file backup"

echo "PASS: installer rendering and security invariants"
