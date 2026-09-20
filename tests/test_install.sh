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
grep -Fq 'healthcheck:' "$local_out/compose.yaml" || fail "container health checks are missing"
[[ ! -e "$local_out/Caddyfile" ]] || fail "Caddyfile must not be rendered without a domain"

domain_out="$tmp_dir/domain"
NEWAPI_TEST_MODE=1 OUTPUT_DIR="$domain_out" DOMAIN=api.example.com bash "$installer" --render-only

[[ -f "$domain_out/Caddyfile" ]] || fail "Caddyfile was not rendered for domain mode"
grep -Fq 'api.example.com {' "$domain_out/Caddyfile" || fail "Caddyfile does not contain the requested domain"
grep -Fq '80:80' "$domain_out/compose.yaml" || fail "HTTP port is missing in domain mode"
grep -Fq '443:443' "$domain_out/compose.yaml" || fail "HTTPS port is missing in domain mode"
grep -Fq 'SESSION_COOKIE_SECURE=true' "$domain_out/compose.yaml" || fail "secure session cookies are not enabled in domain mode"
grep -Fq 'SESSION_COOKIE_TRUSTED_URL=https://api.example.com' "$domain_out/compose.yaml" || fail "trusted HTTPS origin is missing"

if DOMAIN='bad domain' NEWAPI_TEST_MODE=1 OUTPUT_DIR="$tmp_dir/bad" bash "$installer" --render-only >/dev/null 2>&1; then
  fail "invalid domains must be rejected"
fi

echo "PASS: installer rendering and security invariants"
