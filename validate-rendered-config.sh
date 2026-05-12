#!/usr/bin/env bash
set -euo pipefail

# validate-rendered-config.sh
# Validate a rendered GitHub mirror config directory before deployment.
# This script is read-only: it does not modify files, deploy configs, or reload nginx.

usage() {
  cat <<'EOF'
Usage:
  validate-rendered-config.sh --rendered-dir <path>

Example:
  validate-rendered-config.sh \
    --rendered-dir ./rendered/github.example.com

Checks performed:
- required directories/files exist
- required conf/snippet/error files exist
- no unreplaced __PLACEHOLDER__ tokens remain
- rendered values env exists and includes core keys
- referenced domains appear in expected conf files

This script does NOT run nginx -t.
EOF
}

RENDERED_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rendered-dir)
      RENDERED_DIR="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1 ;;
  esac
done

if [[ -z "$RENDERED_DIR" ]]; then
  echo "Error: --rendered-dir is required" >&2
  usage >&2
  exit 1
fi

fail() {
  echo "[FAIL] $*" >&2
  exit 1
}

warn() {
  echo "[WARN] $*" >&2
}

pass() {
  echo "[OK] $*"
}

safe_source_rendered_env() {
  local env_file="$1"
  python3 - "$env_file" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
allowed_keys = {
    'BASE_DOMAIN', 'DOMAIN_MODE', 'TLS_MODE', 'LOG_DIR',
    'HUB_DOMAIN', 'RAW_DOMAIN', 'GIST_DOMAIN', 'ASSETS_DOMAIN', 'ARCHIVE_DOMAIN', 'DOWNLOAD_DOMAIN',
    'HUB_URL', 'RAW_URL', 'GIST_URL', 'ASSETS_URL', 'ARCHIVE_URL', 'DOWNLOAD_URL',
    'SSL_CERT', 'SSL_KEY', 'ERROR_ROOT',
}
forbidden = re.compile(r'[`$()<>;&|]')
for lineno, raw in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
    if not raw.strip():
        continue
    if '=' not in raw:
        raise SystemExit(f"unsafe rendered env line {lineno}: missing '='")
    key, value = raw.split('=', 1)
    if key not in allowed_keys:
        raise SystemExit(f"unsafe rendered env line {lineno}: unexpected key {key}")
    if forbidden.search(value):
        raise SystemExit(f"unsafe rendered env line {lineno}: forbidden shell metacharacter in {key}")
PY
  # shellcheck disable=SC1090
  source "$env_file"
}

validate_hostname_value() {
  local label="$1"
  local value="$2"
  [[ "$value" =~ ^[A-Za-z0-9.-]+$ ]] || fail "invalid hostname for $label: $value"
  [[ "$value" == *.* ]] || fail "hostname for $label must contain at least one dot: $value"
  [[ "$value" != .* && "$value" != *..* && "$value" != *. ]] || fail "invalid hostname shape for $label: $value"
}

[[ -d "$RENDERED_DIR" ]] || fail "rendered dir not found: $RENDERED_DIR"
[[ -d "$RENDERED_DIR/conf.d" ]] || fail "missing conf.d directory"
[[ -d "$RENDERED_DIR/snippets" ]] || fail "missing snippets directory"
[[ -d "$RENDERED_DIR/html/errors" ]] || fail "missing html/errors directory"
pass "basic rendered directory structure exists"

required_files=(
  "$RENDERED_DIR/conf.d/hub.example.com.conf"
  "$RENDERED_DIR/conf.d/raw.example.com.conf"
  "$RENDERED_DIR/conf.d/gist.example.com.conf"
  "$RENDERED_DIR/conf.d/assets.example.com.conf"
  "$RENDERED_DIR/conf.d/archive.example.com.conf"
  "$RENDERED_DIR/conf.d/download.example.com.conf"
  "$RENDERED_DIR/snippets/tls-common.conf"
  "$RENDERED_DIR/snippets/proxy-common.conf"
  "$RENDERED_DIR/snippets/mirror-security.conf"
  "$RENDERED_DIR/snippets/mirror-robots-deny.conf"
  "$RENDERED_DIR/snippets/mirror-readonly-methods.conf"
  "$RENDERED_DIR/snippets/mirror-block-sensitive-paths.conf"
  "$RENDERED_DIR/snippets/mirror-subfilter-html.conf"
  "$RENDERED_DIR/snippets/mirror-subfilter-gist-html.conf"
  "$RENDERED_DIR/snippets/mirror-download-common.conf"
  "$RENDERED_DIR/snippets/mirror-cache-static.conf"
  "$RENDERED_DIR/snippets/http-redirect-whitelist-map.conf"
  "$RENDERED_DIR/html/errors/403-readonly.html"
  "$RENDERED_DIR/html/errors/403-login-disabled.html"
  "$RENDERED_DIR/html/errors/404.html"
  "$RENDERED_DIR/RENDERED-VALUES.env"
)

for f in "${required_files[@]}"; do
  [[ -f "$f" ]] || fail "missing required file: $f"
done
pass "all required files exist"

if grep -R -n '__[A-Z0-9_][A-Z0-9_]*__' "$RENDERED_DIR/conf.d" "$RENDERED_DIR/snippets" "$RENDERED_DIR/html/errors" >/tmp/github-mirror-unreplaced.txt 2>/dev/null; then
  echo "Unreplaced placeholders detected:" >&2
  cat /tmp/github-mirror-unreplaced.txt >&2
  rm -f /tmp/github-mirror-unreplaced.txt
  fail "rendered output still contains template placeholders"
else
  rm -f /tmp/github-mirror-unreplaced.txt
  pass "no unreplaced template placeholders found"
fi

# shellcheck disable=SC1090
safe_source_rendered_env "$RENDERED_DIR/RENDERED-VALUES.env"

required_env_keys=(
  BASE_DOMAIN
  DOMAIN_MODE
  TLS_MODE
  HUB_DOMAIN
  RAW_DOMAIN
  GIST_DOMAIN
  ASSETS_DOMAIN
  ARCHIVE_DOMAIN
  DOWNLOAD_DOMAIN
  HUB_URL
  RAW_URL
  GIST_URL
  ASSETS_URL
  ARCHIVE_URL
  DOWNLOAD_URL
  SSL_CERT
  SSL_KEY
  ERROR_ROOT
)

for key in "${required_env_keys[@]}"; do
  [[ -n "${!key:-}" ]] || fail "missing or empty key in RENDERED-VALUES.env: $key"
done
pass "RENDERED-VALUES.env contains all required keys"

validate_hostname_value "BASE_DOMAIN" "$BASE_DOMAIN"
validate_hostname_value "HUB_DOMAIN" "$HUB_DOMAIN"
validate_hostname_value "RAW_DOMAIN" "$RAW_DOMAIN"
validate_hostname_value "GIST_DOMAIN" "$GIST_DOMAIN"
validate_hostname_value "ASSETS_DOMAIN" "$ASSETS_DOMAIN"
validate_hostname_value "ARCHIVE_DOMAIN" "$ARCHIVE_DOMAIN"
validate_hostname_value "DOWNLOAD_DOMAIN" "$DOWNLOAD_DOMAIN"
pass "rendered hostname values look structurally safe"

check_contains() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  grep -qF "$pattern" "$file" || fail "$label not found in $file: $pattern"
}

check_contains "$RENDERED_DIR/conf.d/hub.example.com.conf" "$HUB_DOMAIN" "hub domain"
check_contains "$RENDERED_DIR/conf.d/hub.example.com.conf" "$RAW_DOMAIN" "raw domain reference in hub"
check_contains "$RENDERED_DIR/conf.d/hub.example.com.conf" "$GIST_DOMAIN" "gist domain reference in hub"
check_contains "$RENDERED_DIR/conf.d/hub.example.com.conf" "$ASSETS_DOMAIN" "assets domain reference in hub"
check_contains "$RENDERED_DIR/conf.d/hub.example.com.conf" "$ARCHIVE_DOMAIN" "archive domain reference in hub"
check_contains "$RENDERED_DIR/conf.d/hub.example.com.conf" "$DOWNLOAD_DOMAIN" "download domain reference in hub"
check_contains "$RENDERED_DIR/conf.d/raw.example.com.conf" "$RAW_DOMAIN" "raw domain"
check_contains "$RENDERED_DIR/conf.d/gist.example.com.conf" "$GIST_DOMAIN" "gist domain"
check_contains "$RENDERED_DIR/conf.d/assets.example.com.conf" "$ASSETS_DOMAIN" "assets domain"
check_contains "$RENDERED_DIR/conf.d/archive.example.com.conf" "$ARCHIVE_DOMAIN" "archive domain"
check_contains "$RENDERED_DIR/conf.d/download.example.com.conf" "$DOWNLOAD_DOMAIN" "download domain"
pass "expected domains appear in rendered conf files"

if grep -R -n 'TODO:' "$RENDERED_DIR/conf.d" "$RENDERED_DIR/snippets" >/tmp/github-mirror-todos.txt 2>/dev/null; then
  warn "TODO markers still exist in rendered config (review before production):"
  cat /tmp/github-mirror-todos.txt >&2
  rm -f /tmp/github-mirror-todos.txt
else
  rm -f /tmp/github-mirror-todos.txt
  pass "no TODO markers found in rendered config"
fi

cat <<EOF

Validation complete.

Rendered directory looks structurally valid:
  $RENDERED_DIR

Important next manual steps:
  1. review redirect whitelist integration for archive/download
  2. confirm certificate paths are correct on target server
  3. confirm include paths match target nginx layout
  4. run nginx -t manually on the target server before reload
EOF
