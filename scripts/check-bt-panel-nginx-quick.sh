#!/usr/bin/env bash
set -euo pipefail

BASE_DOMAIN="github.example.com"
DOMAIN_MODE="auto"
NGINX_BIN="/www/server/nginx/sbin/nginx"
NGINX_CONF="/www/server/nginx/conf/nginx.conf"
SNIPPETS_DIR="/www/server/nginx/conf/snippets"
ERROR_LOG="/www/server/nginx/logs/error.log"
TIMEOUT=20

usage() {
  cat <<'EOF'
Usage:
  ./scripts/check-bt-panel-nginx-quick.sh [--base-domain github.example.com] [--domain-mode auto|flat-siblings|nested]

What it checks (BaoTa quick post-upgrade profile):
  - nginx version + nginx -t
  - required snippets presence under /www/server/nginx/conf/snippets
  - http include for http-redirect-whitelist-map.conf
  - nginx process / 80+443 listeners
  - 5 key live URLs (hub/archive/assets/raw/download)
  - recent nginx error log signatures for missing snippets / missing gh_redirect_* maps

Notes:
  - Default domain derivation is auto-detect for backward compatibility.
  - If your deployment uses nested hosts like raw.github.example.com, pass:
    --domain-mode nested

Exit codes:
  0 = no hard failures
  1 = one or more hard failures
  2 = bad usage
EOF
}

trim_trailing_slash() {
  local value="$1"
  while [[ "$value" != "/" && "$value" == */ ]]; do
    value="${value%/}"
  done
  printf '%s\n' "$value"
}

require_value() {
  local flag="$1"
  local value="${2-}"
  [[ -n "$value" ]] || { echo "missing value for $flag" >&2; exit 2; }
  [[ "$value" != -* ]] || { echo "missing value for $flag" >&2; exit 2; }
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-domain)
      require_value "$1" "${2-}"
      BASE_DOMAIN="$2"
      shift 2
      ;;
    --domain-mode)
      require_value "$1" "${2-}"
      DOMAIN_MODE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

BASE_DOMAIN="$(trim_trailing_slash "$BASE_DOMAIN")"
[[ "$BASE_DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "--base-domain contains invalid characters" >&2; exit 2; }
[[ "$BASE_DOMAIN" == *.* ]] || { echo "--base-domain must be a hostname like github.example.com" >&2; exit 2; }
[[ "$BASE_DOMAIN" != .* && "$BASE_DOMAIN" != *..* && "$BASE_DOMAIN" != *. ]] || { echo "--base-domain has invalid hostname shape" >&2; exit 2; }

case "$DOMAIN_MODE" in
  auto|flat-siblings|nested) ;;
  *) echo "--domain-mode must be auto, flat-siblings, or nested" >&2; exit 2 ;;
esac

root_suffix="${BASE_DOMAIN#*.}"
if [[ "$DOMAIN_MODE" == "flat-siblings" ]]; then
  HUB_DOMAIN="$BASE_DOMAIN"
  RAW_DOMAIN="raw.${root_suffix}"
  ASSETS_DOMAIN="assets.${root_suffix}"
  ARCHIVE_DOMAIN="archive.${root_suffix}"
  DOWNLOAD_DOMAIN="download.${root_suffix}"
elif [[ "$DOMAIN_MODE" == "nested" ]]; then
  HUB_DOMAIN="$BASE_DOMAIN"
  RAW_DOMAIN="raw.${BASE_DOMAIN}"
  ASSETS_DOMAIN="assets.${BASE_DOMAIN}"
  ARCHIVE_DOMAIN="archive.${BASE_DOMAIN}"
  DOWNLOAD_DOMAIN="download.${BASE_DOMAIN}"
elif [[ "$BASE_DOMAIN" == *.*.* ]]; then
  HUB_DOMAIN="$BASE_DOMAIN"
  RAW_DOMAIN="raw.${root_suffix}"
  ASSETS_DOMAIN="assets.${root_suffix}"
  ARCHIVE_DOMAIN="archive.${root_suffix}"
  DOWNLOAD_DOMAIN="download.${root_suffix}"
else
  HUB_DOMAIN="$BASE_DOMAIN"
  RAW_DOMAIN="raw.${BASE_DOMAIN}"
  ASSETS_DOMAIN="assets.${BASE_DOMAIN}"
  ARCHIVE_DOMAIN="archive.${BASE_DOMAIN}"
  DOWNLOAD_DOMAIN="download.${BASE_DOMAIN}"
fi

FAILURES=0
WARNINGS=0

fail() {
  echo "[FAIL] $*"
  FAILURES=$((FAILURES + 1))
}

warn() {
  echo "[WARN] $*"
  WARNINGS=$((WARNINGS + 1))
}

pass() {
  echo "[PASS] $*"
}

fetch_status_local() {
  local host="$1"
  local path="$2"
  local status
  status="$(curl -k -I -s --resolve "${host}:443:127.0.0.1" --max-time "$TIMEOUT" -o /dev/null -w '%{http_code}' "https://${host}${path}" || true)"
  printf '%s\n' "$status"
}

check_status_200_local() {
  local label="$1"
  local host="$2"
  local path="$3"
  local status
  status="$(fetch_status_local "$host" "$path")"
  if [[ "$status" == "200" ]]; then
    pass "$label -> $status"
  else
    fail "$label -> expected 200, got ${status:-<empty>} (https://${host}${path})"
  fi
}

echo "== BaoTa Nginx Quick Check =="
echo "base_domain=$BASE_DOMAIN"
echo "hub=$HUB_DOMAIN raw=$RAW_DOMAIN assets=$ASSETS_DOMAIN archive=$ARCHIVE_DOMAIN download=$DOWNLOAD_DOMAIN"
echo

echo "== 1. nginx version =="
if [[ -x "$NGINX_BIN" ]]; then
  ver_out="$($NGINX_BIN -v 2>&1)"
  echo "$ver_out"
  case "$ver_out" in
    *"nginx/1.30.1"*|*"nginx/1.31."*|*"nginx/1.32."*|*"nginx/1.33."*)
      pass "nginx version is at or above known fixed versions"
      ;;
    *)
      warn "nginx version is not one of the known fixed signatures; verify manually"
      ;;
  esac
else
  fail "nginx binary missing: $NGINX_BIN"
fi

echo
echo "== 2. nginx -t =="
syntax_out="$($NGINX_BIN -t -c "$NGINX_CONF" 2>&1 || true)"
echo "$syntax_out"
if grep -Eq 'syntax is ok|test is successful' <<<"$syntax_out"; then
  pass "nginx -t passed"
else
  fail "nginx -t failed"
fi

echo
echo "== 3. required snippets =="
required_snippets=(
  "mirror-security.conf"
  "mirror-readonly-methods.conf"
  "mirror-block-sensitive-paths.conf"
  "proxy-common.conf"
  "http-redirect-whitelist-map.conf"
)
if [[ -d "$SNIPPETS_DIR" ]]; then
  for name in "${required_snippets[@]}"; do
    if [[ -f "$SNIPPETS_DIR/$name" ]]; then
      pass "snippets/$name present"
    else
      fail "snippets/$name missing"
    fi
  done
else
  fail "snippets dir missing: $SNIPPETS_DIR"
fi

echo
echo "== 4. http include =="
if grep -Fq 'include /www/server/nginx/conf/snippets/http-redirect-whitelist-map.conf;' "$NGINX_CONF"; then
  pass "nginx.conf contains redirect whitelist include"
else
  fail "nginx.conf missing redirect whitelist include"
fi

echo
echo "== 5. process + listeners =="
status_out="$(/etc/init.d/nginx status 2>&1 || true)"
echo "$status_out"
if echo "$status_out" | grep -Eqi 'already running|is running|active \(running\)'; then
  pass "service status indicates nginx is running"
else
  warn "service status does not explicitly confirm nginx is running"
fi

if ps -ef | grep '[n]ginx' >/dev/null 2>&1; then
  pass "nginx process detected"
else
  fail "nginx process not found"
fi

if command -v ss >/dev/null 2>&1; then
  port_lines="$(ss -ltnp | grep -E ':(80|443)\\b' || true)"
  echo "$port_lines"
  if grep -q ':80' <<<"$port_lines" && grep -q ':443' <<<"$port_lines"; then
    pass "80/443 listeners detected"
  else
    warn "80/443 listeners not both visible"
  fi
else
  warn "ss not found; skipped listener check"
fi

echo
echo "== 6. key URL probes =="
check_status_200_local "hub home" "$HUB_DOMAIN" "/"
check_status_200_local "archive zip" "$ARCHIVE_DOMAIN" "/torvalds/linux/archive/refs/heads/master.zip"
check_status_200_local "assets css" "$ASSETS_DOMAIN" "/assets/light-2ff56e1b36116ee2.css"
check_status_200_local "raw readme" "$RAW_DOMAIN" "/torvalds/linux/master/README"
check_status_200_local "download asset" "$DOWNLOAD_DOMAIN" "/cli/cli/releases/download/v2.92.0/gh_2.92.0_linux_amd64.tar.gz"

echo
echo "== 7. recent nginx error log signatures =="
if [[ -f "$ERROR_LOG" ]]; then
  recent="$(tail -n 80 "$ERROR_LOG")"
  echo "$recent"
  last_notice_epoch="$(grep -E '\[notice\].*signal process started' "$ERROR_LOG" | tail -n 1 | sed -E 's#^([0-9]{4}/[0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}).*#\1#' | xargs -r -I{} date -d '{}' +%s 2>/dev/null || true)"
  last_key_epoch="$(grep -E 'open\(\) ".*snippets/.*failed|unknown "gh_redirect_https_ok" variable|unknown "gh_redirect_allowed" variable' "$ERROR_LOG" | tail -n 1 | sed -E 's#^([0-9]{4}/[0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}).*#\1#' | xargs -r -I{} date -d '{}' +%s 2>/dev/null || true)"
  if [[ -n "$last_key_epoch" && -n "$last_notice_epoch" && "$last_notice_epoch" -ge "$last_key_epoch" ]]; then
    pass "snippets/map error signatures look historical (a later reload notice exists)"
  elif grep -Eq 'open\(\) ".*snippets/.*failed|unknown "gh_redirect_https_ok" variable|unknown "gh_redirect_allowed" variable' <<<"$recent"; then
    warn "recent nginx error log still contains snippets/map signatures; verify timestamps"
  else
    pass "no snippets/map error signatures in recent nginx error log"
  fi
else
  warn "nginx error log missing: $ERROR_LOG"
fi

echo
echo "summary: failures=$FAILURES warnings=$WARNINGS"
if (( FAILURES > 0 )); then
  exit 1
fi
exit 0
