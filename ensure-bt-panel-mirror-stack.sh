#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./ensure-bt-panel-mirror-stack.sh \
    --base-domain <domain> \
    [--domain-mode <nested|flat-siblings>] \
    [--rendered-dir <path>] \
    [--output-dir <path>] \
    [--ssl-cert <path>] \
    [--ssl-key <path>] \
    [--error-root <path>] \
    [--log-dir <path>] \
    [--panel <url>] [--entry <path>] [--username <user>] [--password <pass> | --password-env <ENV_NAME>] \
    [--bt-create-script <path>] \
    [--render-script <path>] \
    [--deploy-script <path>] \
    [--nginx-conf <path>] \
    [--nginx-test-cmd <cmd>] \
    [--nginx-reload-cmd <cmd>] \
    [--skip-create] \
    [--skip-deploy] \
    [--allow-bootstrap-vhosts] \
    [--skip-http-include] \
    [--apply] \
    [--reload] \
    [--insecure]

What it does:
  1. Derive the six mirror hostnames from BASE_DOMAIN
  2. Optionally render a deployment package (if --rendered-dir is not supplied)
  3. In dry-run mode, inspect whether BaoTa already recognizes the six sites
  4. In apply mode, create any missing BaoTa sites via bt_create_site.py --if-not-exists
  5. Hand the rendered package to deploy-rendered-to-bt-panel.sh

Defaults:
  - dry-run by default; no BaoTa sites or live nginx files are modified
  - --apply enables create-if-missing + deploy apply
  - --reload only works together with --apply

Examples:
  # Dry-run against an existing flat-siblings deployment
  ./ensure-bt-panel-mirror-stack.sh \
    --base-domain github.weiyusc.top \
    --domain-mode flat-siblings \
    --ssl-cert /www/server/panel/vhost/cert/su.weiyusc.top/fullchain.pem \
    --ssl-key /www/server/panel/vhost/cert/su.weiyusc.top/privkey.pem \
    --error-root /www/wwwroot/github-mirror-errors

  # Create missing BaoTa sites, deploy rendered files, and reload after nginx -t passes
  ./ensure-bt-panel-mirror-stack.sh \
    --base-domain github.weiyusc.top \
    --domain-mode flat-siblings \
    --ssl-cert /www/server/panel/vhost/cert/su.weiyusc.top/fullchain.pem \
    --ssl-key /www/server/panel/vhost/cert/su.weiyusc.top/privkey.pem \
    --error-root /www/wwwroot/github-mirror-errors \
    --panel https://su.weiyusc.top:37913 \
    --entry /b274fe00 \
    --username <panel-user> \
    --password-env BT_PANEL_PASSWORD \
    --apply --reload --insecure
EOF
}

fail() {
  echo "[FAIL] $*" >&2
  exit 1
}

warn() {
  echo "[WARN] $*" >&2
}

info() {
  echo "[INFO] $*"
}

require_value() {
  local flag="$1"
  local value="${2-}"
  [[ -n "$value" ]] || fail "missing value for $flag"
  [[ "$value" != -* ]] || fail "missing value for $flag"
}

trim_trailing_slash() {
  local value="$1"
  while [[ "$value" != "/" && "$value" == */ ]]; do
    value="${value%/}"
  done
  printf '%s\n' "$value"
}

validate_hostname_value() {
  local label="$1"
  local value="$2"
  [[ "$value" =~ ^[A-Za-z0-9.-]+$ ]] || fail "invalid hostname for $label: $value"
  [[ "$value" == *.* ]] || fail "hostname for $label must contain at least one dot: $value"
  [[ "$value" != .* && "$value" != *..* && "$value" != *. ]] || fail "invalid hostname shape for $label: $value"
}

bt_site_exists_local() {
  local domain="$1"
  python3 - "$domain" <<'PY'
import sqlite3
import sys
from pathlib import Path

domain = sys.argv[1]
db = Path('/www/server/panel/data/db/site.db')
if not db.exists():
    print('0')
    raise SystemExit(0)
conn = sqlite3.connect(str(db))
try:
    row = conn.execute(
        "select 1 from sites s left join domain d on s.id=d.pid where s.name=? or d.name=? limit 1",
        (domain, domain),
    ).fetchone()
    print('1' if row else '0')
finally:
    conn.close()
PY
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DOMAIN=""
DOMAIN_MODE="nested"
RENDERED_DIR=""
OUTPUT_DIR=""
SSL_CERT=""
SSL_KEY=""
ERROR_ROOT=""
LOG_DIR="/www/wwwlogs"
PANEL_URL=""
ENTRY_PATH=""
USERNAME=""
PASSWORD=""
PASSWORD_ENV=""
BT_CREATE_SCRIPT="/usr/local/lib/hermes-agent/scripts/bt_create_site.py"
BT_CREATE_WRAPPER=""
RENDER_SCRIPT="$SCRIPT_DIR/render-from-base-domain.sh"
DEPLOY_SCRIPT="$SCRIPT_DIR/deploy-rendered-to-bt-panel.sh"
NGINX_CONF=""
NGINX_TEST_CMD=""
NGINX_RELOAD_CMD=""
SKIP_CREATE="0"
SKIP_DEPLOY="0"
ALLOW_BOOTSTRAP_VHOSTS="0"
SKIP_HTTP_INCLUDE="0"
APPLY="0"
RELOAD="0"
INSECURE="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-domain)
      require_value "$1" "${2-}"
      BASE_DOMAIN="$2"; shift 2 ;;
    --domain-mode)
      require_value "$1" "${2-}"
      DOMAIN_MODE="$2"; shift 2 ;;
    --rendered-dir)
      require_value "$1" "${2-}"
      RENDERED_DIR="$2"; shift 2 ;;
    --output-dir)
      require_value "$1" "${2-}"
      OUTPUT_DIR="$2"; shift 2 ;;
    --ssl-cert)
      require_value "$1" "${2-}"
      SSL_CERT="$2"; shift 2 ;;
    --ssl-key)
      require_value "$1" "${2-}"
      SSL_KEY="$2"; shift 2 ;;
    --error-root)
      require_value "$1" "${2-}"
      ERROR_ROOT="$2"; shift 2 ;;
    --log-dir)
      require_value "$1" "${2-}"
      LOG_DIR="$2"; shift 2 ;;
    --panel)
      require_value "$1" "${2-}"
      PANEL_URL="$2"; shift 2 ;;
    --entry)
      require_value "$1" "${2-}"
      ENTRY_PATH="$2"; shift 2 ;;
    --username)
      require_value "$1" "${2-}"
      USERNAME="$2"; shift 2 ;;
    --password)
      require_value "$1" "${2-}"
      PASSWORD="$2"; shift 2 ;;
    --password-env)
      require_value "$1" "${2-}"
      PASSWORD_ENV="$2"; shift 2 ;;
    --bt-create-script)
      require_value "$1" "${2-}"
      BT_CREATE_SCRIPT="$2"; shift 2 ;;
    --render-script)
      require_value "$1" "${2-}"
      RENDER_SCRIPT="$2"; shift 2 ;;
    --deploy-script)
      require_value "$1" "${2-}"
      DEPLOY_SCRIPT="$2"; shift 2 ;;
    --nginx-conf)
      require_value "$1" "${2-}"
      NGINX_CONF="$2"; shift 2 ;;
    --nginx-test-cmd)
      require_value "$1" "${2-}"
      NGINX_TEST_CMD="$2"; shift 2 ;;
    --nginx-reload-cmd)
      require_value "$1" "${2-}"
      NGINX_RELOAD_CMD="$2"; shift 2 ;;
    --skip-create)
      SKIP_CREATE="1"; shift ;;
    --skip-deploy)
      SKIP_DEPLOY="1"; shift ;;
    --allow-bootstrap-vhosts)
      ALLOW_BOOTSTRAP_VHOSTS="1"; shift ;;
    --skip-http-include)
      SKIP_HTTP_INCLUDE="1"; shift ;;
    --apply)
      APPLY="1"; shift ;;
    --reload)
      RELOAD="1"; shift ;;
    --insecure)
      INSECURE="1"; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      fail "unknown argument: $1" ;;
  esac
done

[[ -n "$BASE_DOMAIN" ]] || fail "--base-domain is required"
[[ "$DOMAIN_MODE" == "nested" || "$DOMAIN_MODE" == "flat-siblings" ]] || fail "--domain-mode must be nested or flat-siblings"
[[ "$RELOAD" == "0" || "$APPLY" == "1" ]] || fail "--reload requires --apply"
[[ -n "$PASSWORD" && -n "$PASSWORD_ENV" ]] && fail "use either --password or --password-env, not both"
if [[ -n "$PASSWORD_ENV" ]]; then
  [[ "$PASSWORD_ENV" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fail "invalid --password-env name: $PASSWORD_ENV"
  PASSWORD="${!PASSWORD_ENV:-}"
  [[ -n "$PASSWORD" ]] || fail "password env var is empty or unset: $PASSWORD_ENV"
fi

BASE_DOMAIN="$(trim_trailing_slash "$BASE_DOMAIN")"
validate_hostname_value "BASE_DOMAIN" "$BASE_DOMAIN"

if [[ "$DOMAIN_MODE" == "nested" ]]; then
  HUB_DOMAIN="$BASE_DOMAIN"
  RAW_DOMAIN="raw.$BASE_DOMAIN"
  GIST_DOMAIN="gist.$BASE_DOMAIN"
  ASSETS_DOMAIN="assets.$BASE_DOMAIN"
  ARCHIVE_DOMAIN="archive.$BASE_DOMAIN"
  DOWNLOAD_DOMAIN="download.$BASE_DOMAIN"
else
  HUB_DOMAIN="$BASE_DOMAIN"
  if [[ "$BASE_DOMAIN" != *.*.* ]]; then
    fail "flat-siblings mode requires --base-domain to contain at least three labels, e.g. github.example.com"
  fi
  BASE_SUFFIX="${BASE_DOMAIN#*.}"
  [[ "$BASE_SUFFIX" != "$BASE_DOMAIN" && -n "$BASE_SUFFIX" ]] || fail "flat-siblings mode requires base domain with at least one dot"
  RAW_DOMAIN="raw.$BASE_SUFFIX"
  GIST_DOMAIN="gist.$BASE_SUFFIX"
  ASSETS_DOMAIN="assets.$BASE_SUFFIX"
  ARCHIVE_DOMAIN="archive.$BASE_SUFFIX"
  DOWNLOAD_DOMAIN="download.$BASE_SUFFIX"
fi

for item in "$HUB_DOMAIN" "$RAW_DOMAIN" "$GIST_DOMAIN" "$ASSETS_DOMAIN" "$ARCHIVE_DOMAIN" "$DOWNLOAD_DOMAIN"; do
  validate_hostname_value "derived domain" "$item"
done

DERIVED_DOMAINS=(
  "$HUB_DOMAIN"
  "$RAW_DOMAIN"
  "$GIST_DOMAIN"
  "$ASSETS_DOMAIN"
  "$ARCHIVE_DOMAIN"
  "$DOWNLOAD_DOMAIN"
)

if [[ -z "$RENDERED_DIR" ]]; then
  [[ -f "$RENDER_SCRIPT" ]] || fail "render script not found: $RENDER_SCRIPT"
  [[ -n "$SSL_CERT" ]] || fail "--ssl-cert is required when --rendered-dir is not supplied"
  [[ -n "$SSL_KEY" ]] || fail "--ssl-key is required when --rendered-dir is not supplied"
  [[ -n "$ERROR_ROOT" ]] || fail "--error-root is required when --rendered-dir is not supplied"
  render_cmd=(
    bash "$RENDER_SCRIPT"
    --base-domain "$BASE_DOMAIN"
    --domain-mode "$DOMAIN_MODE"
    --ssl-cert "$SSL_CERT"
    --ssl-key "$SSL_KEY"
    --error-root "$ERROR_ROOT"
    --log-dir "$LOG_DIR"
  )
  if [[ -n "$OUTPUT_DIR" ]]; then
    render_cmd+=(--output-dir "$OUTPUT_DIR")
  fi
  info "Rendering deployment package"
  "${render_cmd[@]}"
  if [[ -n "$OUTPUT_DIR" ]]; then
    RENDERED_DIR="$OUTPUT_DIR"
  else
    render_script_dir="$(cd "$(dirname "$RENDER_SCRIPT")" && pwd)"
    RENDERED_DIR="$render_script_dir/rendered/$BASE_DOMAIN"
  fi
else
  [[ -d "$RENDERED_DIR" ]] || fail "rendered dir not found: $RENDERED_DIR"
  rendered_values="$RENDERED_DIR/RENDERED-VALUES.env"
  [[ -f "$rendered_values" ]] || fail "rendered values file not found: $rendered_values"
  rendered_base_domain="$(python3 - <<'PY' "$rendered_values"
from pathlib import Path
import sys
for line in Path(sys.argv[1]).read_text(encoding='utf-8').splitlines():
    if line.startswith('BASE_DOMAIN='):
        print(line.split('=', 1)[1])
        break
PY
)"
  rendered_domain_mode="$(python3 - <<'PY' "$rendered_values"
from pathlib import Path
import sys
for line in Path(sys.argv[1]).read_text(encoding='utf-8').splitlines():
    if line.startswith('DOMAIN_MODE='):
        print(line.split('=', 1)[1])
        break
PY
)"
  [[ "$rendered_base_domain" == "$BASE_DOMAIN" ]] || fail "rendered dir base domain mismatch: env has $rendered_base_domain, CLI requested $BASE_DOMAIN"
  [[ -z "$rendered_domain_mode" || "$rendered_domain_mode" == "$DOMAIN_MODE" ]] || fail "rendered dir domain mode mismatch: env has $rendered_domain_mode, CLI requested $DOMAIN_MODE"
fi

create_statuses=()
missing_domains=()
for domain in "${DERIVED_DOMAINS[@]}"; do
  exists_flag="$(bt_site_exists_local "$domain")"
  if [[ "$exists_flag" == "1" ]]; then
    create_statuses+=("$domain|exists")
  else
    create_statuses+=("$domain|missing")
    missing_domains+=("$domain")
  fi
done

cat <<EOF

BT mirror stack plan
- mode: $(if [[ "$APPLY" == "1" ]]; then echo apply; else echo dry-run; fi)
- base domain: $BASE_DOMAIN
- domain mode: $DOMAIN_MODE
- rendered dir: $RENDERED_DIR
- skip create: $SKIP_CREATE
- skip deploy: $SKIP_DEPLOY
- reload requested: $RELOAD

Derived domains
EOF
for row in "${create_statuses[@]}"; do
  IFS='|' read -r domain status <<< "$row"
  echo "- $domain -> $status"
done

echo
if [[ "$APPLY" != "1" ]]; then
  info "Dry-run only. No BaoTa sites were created and no files were deployed."
else
  if [[ "$SKIP_CREATE" != "1" && ${#missing_domains[@]} -gt 0 ]]; then
    [[ -n "$PANEL_URL" ]] || fail "--panel is required for apply create phase"
    [[ -n "$ENTRY_PATH" ]] || fail "--entry is required for apply create phase"
    [[ -n "$USERNAME" ]] || fail "--username is required for apply create phase"
    [[ -n "$PASSWORD" ]] || fail "--password or --password-env is required for apply create phase"
    BT_CREATE_WRAPPER="$(mktemp)"
    cat > "$BT_CREATE_WRAPPER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
script_path="$1"
panel_url="$2"
entry_path="$3"
username="$4"
domain="$5"
shift 5
exec python3 "$script_path" --panel "$panel_url" --entry "$entry_path" --username "$username" --password "$BT_PANEL_PASSWORD" --domain "$domain" --if-not-exists "$@"
EOF
    chmod 700 "$BT_CREATE_WRAPPER"
    trap '[[ -n "${BT_CREATE_WRAPPER:-}" && -f "$BT_CREATE_WRAPPER" ]] && rm -f "$BT_CREATE_WRAPPER"' EXIT
    for domain in "${missing_domains[@]}"; do
      info "Creating missing BaoTa site: $domain"
      create_cmd=(
        "$BT_CREATE_WRAPPER"
        "$BT_CREATE_SCRIPT"
        "$PANEL_URL"
        "$ENTRY_PATH"
        "$USERNAME"
        "$domain"
      )
      if [[ "$INSECURE" == "1" ]]; then
        create_cmd+=(--insecure)
      fi
      BT_PANEL_PASSWORD="$PASSWORD" "${create_cmd[@]}"
    done
  elif [[ "$SKIP_CREATE" == "1" ]]; then
    info "Skipping BaoTa site creation by operator request"
  else
    info "All derived BaoTa sites already exist; no create calls needed"
  fi
fi

if [[ "$SKIP_DEPLOY" == "1" ]]; then
  info "Skipping deploy phase by operator request"
  exit 0
fi

if [[ "$APPLY" != "1" && ${#missing_domains[@]} -gt 0 && "$ALLOW_BOOTSTRAP_VHOSTS" != "1" ]]; then
  warn "Derived BaoTa sites are missing, so deploy dry-run would block on absent vhost confs."
  warn "Rerun with --apply to create sites first, or add --allow-bootstrap-vhosts for a bootstrap deploy preview."
  exit 0
fi

[[ -f "$DEPLOY_SCRIPT" ]] || fail "deploy script not found: $DEPLOY_SCRIPT"

deploy_cmd=(
  bash "$DEPLOY_SCRIPT"
  --rendered-dir "$RENDERED_DIR"
)
if [[ -n "$NGINX_CONF" ]]; then
  deploy_cmd+=(--nginx-conf "$NGINX_CONF")
fi
if [[ -n "$NGINX_TEST_CMD" ]]; then
  deploy_cmd+=(--nginx-test-cmd "$NGINX_TEST_CMD")
fi
if [[ -n "$NGINX_RELOAD_CMD" ]]; then
  deploy_cmd+=(--nginx-reload-cmd "$NGINX_RELOAD_CMD")
fi
if [[ "$ALLOW_BOOTSTRAP_VHOSTS" == "1" ]]; then
  deploy_cmd+=(--allow-bootstrap-vhosts)
fi
if [[ "$SKIP_HTTP_INCLUDE" == "1" ]]; then
  deploy_cmd+=(--skip-http-include)
fi
if [[ "$APPLY" == "1" ]]; then
  deploy_cmd+=(--apply)
  if [[ "$RELOAD" == "1" ]]; then
    deploy_cmd+=(--reload)
  fi
fi

info "Handing off to deploy script"
"${deploy_cmd[@]}"
