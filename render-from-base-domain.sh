#!/usr/bin/env bash
set -euo pipefail

# render-from-base-domain.sh
# Safe renderer for the GitHub mirror template.
# It only renders a deployment copy from templates.
# It does NOT modify nginx configs, does NOT reload services,
# and does NOT touch existing sites.

usage() {
  cat <<'EOF'
Usage:
  render-from-base-domain.sh \
    --base-domain <domain> \
    --ssl-cert <path> \
    --ssl-key <path> \
    --error-root <path> \
    [--tls-mode <existing|acme-http01|acme-dns-cloudflare>] \
    [--domain-mode <nested|flat-siblings>] \
    [--log-dir <path>] \
    [--template-dir <path>] \
    [--output-dir <path>]

Example (nested mode, default):
  render-from-base-domain.sh \
    --base-domain github.example.com \
    --ssl-cert /www/server/panel/vhost/cert/github.example.com/fullchain.pem \
    --ssl-key /www/server/panel/vhost/cert/github.example.com/privkey.pem \
    --error-root /www/wwwroot/github-mirror-errors \
    --output-dir ./rendered/github-mirror

Example (flat sibling mode, for wildcard certificate reuse):
  render-from-base-domain.sh \
    --base-domain github.example.com \
    --domain-mode flat-siblings \
    --ssl-cert /etc/ssl/example/fullchain.pem \
    --ssl-key /etc/ssl/example/privkey.pem \
    --error-root /www/wwwroot/github-mirror-errors \
    --log-dir /www/wwwlogs \
    --output-dir ./rendered/github-mirror

Notes:
- This script only renders files into an output directory.
- It does NOT deploy, does NOT test nginx, does NOT reload nginx.
- You should review output before using it.
EOF
}

BASE_DOMAIN=""
SSL_CERT=""
SSL_KEY=""
ERROR_ROOT=""
DOMAIN_MODE="nested"
TLS_MODE="existing"
LOG_DIR="/www/wwwlogs"
TEMPLATE_DIR=""
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-domain)
      BASE_DOMAIN="$2"; shift 2 ;;
    --ssl-cert)
      SSL_CERT="$2"; shift 2 ;;
    --ssl-key)
      SSL_KEY="$2"; shift 2 ;;
    --error-root)
      ERROR_ROOT="$2"; shift 2 ;;
    --template-dir)
      TEMPLATE_DIR="$2"; shift 2 ;;
    --domain-mode)
      DOMAIN_MODE="$2"; shift 2 ;;
    --tls-mode)
      TLS_MODE="$2"; shift 2 ;;
    --log-dir)
      LOG_DIR="$2"; shift 2 ;;
    --output-dir)
      OUTPUT_DIR="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1 ;;
  esac
done

if [[ -z "$BASE_DOMAIN" || -z "$SSL_CERT" || -z "$SSL_KEY" || -z "$ERROR_ROOT" ]]; then
  echo "Error: --base-domain, --ssl-cert, --ssl-key, --error-root are required." >&2
  usage >&2
  exit 1
fi

if [[ "$DOMAIN_MODE" != "nested" && "$DOMAIN_MODE" != "flat-siblings" ]]; then
  echo "Error: --domain-mode must be one of: nested, flat-siblings" >&2
  exit 1
fi

if [[ "$TLS_MODE" != "existing" && "$TLS_MODE" != "acme-http01" && "$TLS_MODE" != "acme-dns-cloudflare" ]]; then
  echo "Error: --tls-mode must be one of: existing, acme-http01, acme-dns-cloudflare" >&2
  exit 1
fi

if [[ -z "$TEMPLATE_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  TEMPLATE_DIR="$SCRIPT_DIR"
fi

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$TEMPLATE_DIR/rendered/$BASE_DOMAIN"
fi

if [[ ! -d "$TEMPLATE_DIR/conf.d" || ! -d "$TEMPLATE_DIR/snippets" || ! -d "$TEMPLATE_DIR/html/errors" ]]; then
  echo "Error: template dir does not look valid: $TEMPLATE_DIR" >&2
  exit 1
fi

HUB_DOMAIN="$BASE_DOMAIN"
if [[ "$DOMAIN_MODE" == "nested" ]]; then
  RAW_DOMAIN="raw.$BASE_DOMAIN"
  GIST_DOMAIN="gist.$BASE_DOMAIN"
  ASSETS_DOMAIN="assets.$BASE_DOMAIN"
  ARCHIVE_DOMAIN="archive.$BASE_DOMAIN"
  DOWNLOAD_DOMAIN="download.$BASE_DOMAIN"
else
  BASE_SUFFIX="${BASE_DOMAIN#*.}"
  if [[ "$BASE_SUFFIX" == "$BASE_DOMAIN" || -z "$BASE_SUFFIX" ]]; then
    echo "Error: flat-siblings mode requires BASE_DOMAIN to contain at least one dot, got: $BASE_DOMAIN" >&2
    exit 1
  fi
  RAW_DOMAIN="raw.$BASE_SUFFIX"
  GIST_DOMAIN="gist.$BASE_SUFFIX"
  ASSETS_DOMAIN="assets.$BASE_SUFFIX"
  ARCHIVE_DOMAIN="archive.$BASE_SUFFIX"
  DOWNLOAD_DOMAIN="download.$BASE_SUFFIX"
fi

HUB_URL="https://$HUB_DOMAIN"
RAW_URL="https://$RAW_DOMAIN"
GIST_URL="https://$GIST_DOMAIN"
ASSETS_URL="https://$ASSETS_DOMAIN"
ARCHIVE_URL="https://$ARCHIVE_DOMAIN"
DOWNLOAD_URL="https://$DOWNLOAD_DOMAIN"

mkdir -p "$OUTPUT_DIR/conf.d" "$OUTPUT_DIR/snippets" "$OUTPUT_DIR/html/errors"

render_file() {
  local src="$1"
  local dst="$2"

  sed \
    -e "s|__HUB_DOMAIN__|$HUB_DOMAIN|g" \
    -e "s|__RAW_DOMAIN__|$RAW_DOMAIN|g" \
    -e "s|__GIST_DOMAIN__|$GIST_DOMAIN|g" \
    -e "s|__ASSETS_DOMAIN__|$ASSETS_DOMAIN|g" \
    -e "s|__ARCHIVE_DOMAIN__|$ARCHIVE_DOMAIN|g" \
    -e "s|__DOWNLOAD_DOMAIN__|$DOWNLOAD_DOMAIN|g" \
    -e "s|__HUB_URL__|$HUB_URL|g" \
    -e "s|__RAW_URL__|$RAW_URL|g" \
    -e "s|__GIST_URL__|$GIST_URL|g" \
    -e "s|__ASSETS_URL__|$ASSETS_URL|g" \
    -e "s|__ARCHIVE_URL__|$ARCHIVE_URL|g" \
    -e "s|__DOWNLOAD_URL__|$DOWNLOAD_URL|g" \
    -e "s|__SSL_CERT__|$SSL_CERT|g" \
    -e "s|__SSL_KEY__|$SSL_KEY|g" \
    -e "s|__ERROR_ROOT__|$ERROR_ROOT|g" \
    -e "s|__LOG_DIR__|$LOG_DIR|g" \
    "$src" > "$dst"
}

while IFS= read -r -d '' f; do
  rel="${f#$TEMPLATE_DIR/}"
  case "$rel" in
    conf.d/*|snippets/*|html/errors/*)
      mkdir -p "$(dirname "$OUTPUT_DIR/$rel")"
      render_file "$f" "$OUTPUT_DIR/$rel"
      ;;
    *)
      ;;
  esac
done < <(find "$TEMPLATE_DIR" -type f -print0)

cat > "$OUTPUT_DIR/RENDERED-VALUES.env" <<EOF
BASE_DOMAIN=$(printf '%q' "$BASE_DOMAIN")
DOMAIN_MODE=$(printf '%q' "$DOMAIN_MODE")
TLS_MODE=$(printf '%q' "$TLS_MODE")
LOG_DIR=$(printf '%q' "$LOG_DIR")
HUB_DOMAIN=$(printf '%q' "$HUB_DOMAIN")
RAW_DOMAIN=$(printf '%q' "$RAW_DOMAIN")
GIST_DOMAIN=$(printf '%q' "$GIST_DOMAIN")
ASSETS_DOMAIN=$(printf '%q' "$ASSETS_DOMAIN")
ARCHIVE_DOMAIN=$(printf '%q' "$ARCHIVE_DOMAIN")
DOWNLOAD_DOMAIN=$(printf '%q' "$DOWNLOAD_DOMAIN")
HUB_URL=$(printf '%q' "$HUB_URL")
RAW_URL=$(printf '%q' "$RAW_URL")
GIST_URL=$(printf '%q' "$GIST_URL")
ASSETS_URL=$(printf '%q' "$ASSETS_URL")
ARCHIVE_URL=$(printf '%q' "$ARCHIVE_URL")
DOWNLOAD_URL=$(printf '%q' "$DOWNLOAD_URL")
SSL_CERT=$(printf '%q' "$SSL_CERT")
SSL_KEY=$(printf '%q' "$SSL_KEY")
ERROR_ROOT=$(printf '%q' "$ERROR_ROOT")
EOF

cat <<EOF
Render complete.

Template dir:
  $TEMPLATE_DIR

Output dir:
  $OUTPUT_DIR

Derived domains:
  MODE     = $DOMAIN_MODE
  HUB      = $HUB_DOMAIN
  RAW      = $RAW_DOMAIN
  GIST     = $GIST_DOMAIN
  ASSETS   = $ASSETS_DOMAIN
  ARCHIVE  = $ARCHIVE_DOMAIN
  DOWNLOAD = $DOWNLOAD_DOMAIN

Next steps:
  1. Review rendered files in: $OUTPUT_DIR
  2. Create DNS records for the derived domains
  3. Place snippets/errors into your deployment directories
  4. Add redirect whitelist maps in nginx http {}
  5. Run nginx -t manually before reload
EOF
