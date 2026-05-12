#!/usr/bin/env bash
set -euo pipefail

BASE_DOMAIN="github.weiyusc.top"
NGINX_CONF="/www/server/nginx/conf/nginx.conf"
TLS_SNIPPET="/www/server/nginx/conf/snippets/tls-common.conf"
LOG_LINES=120
TIMEOUT=20

usage() {
  cat <<'EOF'
Usage:
  ./scripts/check-live-mirror.sh [--base-domain github.example.com] [--log-lines 120]

What it checks:
  - 6 live mirror URLs (hub/raw/gist/gist-raw/archive/download/assets)
  - nginx http include for http-redirect-whitelist-map.conf
  - TLS snippet certificate path + expiry + SANs
  - recent site error logs for high-signal keywords

Exit codes:
  0 = all hard checks passed (warnings may still exist)
  1 = one or more hard failures
EOF
}

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

require_value() {
  local flag="$1"
  local value="${2-}"
  [[ -n "$value" ]] || { echo "missing value for $flag" >&2; exit 2; }
  [[ "$value" != -* ]] || { echo "missing value for $flag" >&2; exit 2; }
}

trim_trailing_slash() {
  local value="$1"
  while [[ "$value" != "/" && "$value" == */ ]]; do
    value="${value%/}"
  done
  printf '%s\n' "$value"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-domain)
      require_value "$1" "${2-}"
      BASE_DOMAIN="$2"
      shift 2
      ;;
    --log-lines)
      require_value "$1" "${2-}"
      LOG_LINES="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

BASE_DOMAIN="$(trim_trailing_slash "$BASE_DOMAIN")"
[[ "$BASE_DOMAIN" == *.* ]] || { echo "--base-domain must be a hostname like github.example.com" >&2; exit 2; }

root_suffix="${BASE_DOMAIN#*.}"
if [[ "$root_suffix" == "$BASE_DOMAIN" || -z "$root_suffix" ]]; then
  echo "--base-domain must contain at least one dot" >&2
  exit 2
fi

HUB_DOMAIN="$BASE_DOMAIN"
RAW_DOMAIN="raw.${root_suffix}"
GIST_DOMAIN="gist.${root_suffix}"
ASSETS_DOMAIN="assets.${root_suffix}"
ARCHIVE_DOMAIN="archive.${root_suffix}"
DOWNLOAD_DOMAIN="download.${root_suffix}"

FAILURES=0
WARNINGS=0

fetch_status() {
  local url="$1"
  local status
  status="$(curl -I -s -L --max-time "$TIMEOUT" -o /dev/null -w '%{http_code}' "$url" || true)"
  printf '%s\n' "$status"
}

check_status_200() {
  local label="$1"
  local url="$2"
  local status
  status="$(fetch_status "$url")"
  if [[ "$status" == "200" ]]; then
    pass "$label -> $status"
  else
    fail "$label -> expected 200, got ${status:-<empty>} ($url)"
  fi
}

check_nginx_include() {
  local needle='include /www/server/nginx/conf/snippets/http-redirect-whitelist-map.conf;'
  if [[ ! -f "$NGINX_CONF" ]]; then
    fail "nginx.conf missing: $NGINX_CONF"
    return
  fi
  if grep -Fq "$needle" "$NGINX_CONF"; then
    pass "nginx.conf contains redirect whitelist include"
  else
    fail "nginx.conf missing redirect whitelist include"
  fi
}

extract_cert_path() {
  local line
  line="$(grep -E '^ssl_certificate\s+' "$TLS_SNIPPET" | head -n 1 || true)"
  line="${line#ssl_certificate}"
  line="${line//;/}"
  echo "$line" | xargs
}

check_tls_cert() {
  if [[ ! -f "$TLS_SNIPPET" ]]; then
    fail "TLS snippet missing: $TLS_SNIPPET"
    return
  fi
  local cert_path
  cert_path="$(extract_cert_path)"
  if [[ -z "$cert_path" || ! -f "$cert_path" ]]; then
    fail "TLS snippet certificate path missing or unreadable: ${cert_path:-<empty>}"
    return
  fi

  local cert_json
  cert_json="$(python3 - "$cert_path" <<'PY'
import json, subprocess, sys, datetime
cert_path = sys.argv[1]
subject = subprocess.check_output(['openssl','x509','-in',cert_path,'-noout','-subject'], text=True).strip()
issuer = subprocess.check_output(['openssl','x509','-in',cert_path,'-noout','-issuer'], text=True).strip()
enddate = subprocess.check_output(['openssl','x509','-in',cert_path,'-noout','-enddate'], text=True).strip().split('=',1)[1]
san = subprocess.check_output(['openssl','x509','-in',cert_path,'-noout','-ext','subjectAltName'], text=True).strip()
expiry = datetime.datetime.strptime(enddate, '%b %d %H:%M:%S %Y %Z')
now = datetime.datetime.utcnow()
days_left = int((expiry - now).total_seconds() // 86400)
print(json.dumps({'subject': subject, 'issuer': issuer, 'enddate': enddate, 'days_left': days_left, 'san': san}, ensure_ascii=False))
PY
)"
  local days_left
  days_left="$(python3 - <<'PY' "$cert_json"
import json,sys
print(json.loads(sys.argv[1])['days_left'])
PY
)"
  if (( days_left < 0 )); then
    fail "TLS certificate expired: $cert_path"
  elif (( days_left < 30 )); then
    warn "TLS certificate expires soon (${days_left}d): $cert_path"
  else
    pass "TLS certificate present with ${days_left}d remaining: $cert_path"
  fi
  python3 - <<'PY' "$cert_json"
import json,sys
payload=json.loads(sys.argv[1])
print('  ' + payload['subject'])
print('  ' + payload['issuer'])
print('  notAfter=' + payload['enddate'])
for line in payload['san'].splitlines():
    if line.strip():
        print('  ' + line.strip())
PY
}

check_recent_log_keywords() {
  local site="$1"
  local file="/www/wwwlogs/${site}.error.log"
  if [[ ! -f "$file" ]]; then
    warn "error log missing: $file"
    return
  fi
  local recent
  recent="$(tail -n "$LOG_LINES" "$file" || true)"
  local filtered
  filtered="$(printf '%s\n' "$recent" | grep -Ev '/www/server/btwaf/|_G write guard|writing a global Lua variable' || true)"
  if grep -Eq 'upstream SSL certificate does not match|Network is unreachable' <<<"$filtered"; then
    warn "recent high-signal upstream errors still present in $file"
  else
    pass "no recent TLS/IPv6 upstream signature in $file (last $LOG_LINES lines, btwaf noise filtered)"
  fi
  if grep -Eq 'upstream timed out| 502 ' <<<"$filtered"; then
    warn "recent timeout/502-like signals present in $file"
  fi
}

echo "== GitHub Mirror Live Check =="
echo "base_domain=$BASE_DOMAIN"
echo "raw=$RAW_DOMAIN gist=$GIST_DOMAIN assets=$ASSETS_DOMAIN archive=$ARCHIVE_DOMAIN download=$DOWNLOAD_DOMAIN"
echo

check_nginx_include
check_tls_cert

echo
check_status_200 "hub home" "https://${HUB_DOMAIN}/"
check_status_200 "hub repo" "https://${HUB_DOMAIN}/torvalds/linux"
check_status_200 "raw readme" "https://${RAW_DOMAIN}/torvalds/linux/master/README"
check_status_200 "gist home" "https://${GIST_DOMAIN}/"
check_status_200 "gist raw" "https://${GIST_DOMAIN}/gist-githubusercontent/octocat/9257657/raw/"
check_status_200 "archive tarball" "https://${ARCHIVE_DOMAIN}/torvalds/linux/archive/refs/heads/master.tar.gz"
check_status_200 "download release asset" "https://${DOWNLOAD_DOMAIN}/cli/cli/releases/download/v2.92.0/gh_2.92.0_linux_amd64.tar.gz"
check_status_200 "assets css" "https://${ASSETS_DOMAIN}/assets/light-2ff56e1b36116ee2.css"

echo
for site in "$HUB_DOMAIN" "$RAW_DOMAIN" "$GIST_DOMAIN" "$ASSETS_DOMAIN" "$ARCHIVE_DOMAIN" "$DOWNLOAD_DOMAIN"; do
  check_recent_log_keywords "$site"
done

echo
echo "summary: failures=$FAILURES warnings=$WARNINGS"
if (( FAILURES > 0 )); then
  exit 1
fi
exit 0
