#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./deploy-rendered-to-bt-panel.sh \
    --rendered-dir <path> \
    [--snippets-target <path>] \
    [--vhost-target <path>] \
    [--error-root <path>] \
    [--nginx-conf <path>] \
    [--backup-dir <path>] \
    [--nginx-test-cmd <cmd>] \
    [--nginx-reload-cmd <cmd>] \
    [--allow-bootstrap-vhosts] \
    [--skip-http-include] \
    [--apply] \
    [--reload]

Default mode is dry-run: the script validates the rendered package, derives the six
BaoTa vhost targets from RENDERED-VALUES.env, prints an audit-friendly plan, and exits
without changing any files.

Examples:
  # Review the plan only
  ./deploy-rendered-to-bt-panel.sh --rendered-dir ./rendered/github-mirror

  # Copy files, update nginx.conf if needed, run nginx -t, but do not reload yet
  ./deploy-rendered-to-bt-panel.sh --rendered-dir ./rendered/github-mirror --apply

  # Apply and reload only after nginx -t passes
  ./deploy-rendered-to-bt-panel.sh --rendered-dir ./rendered/github-mirror --apply --reload

Notes:
  - --error-root is only accepted when it matches the rendered package value.
    To change error root, rerender first.
  - --snippets-target must match the nginx.conf sibling snippets directory
    because rendered BaoTa vhost configs include snippets/* relatively.

Defaults:
  --snippets-target  /www/server/nginx/conf/snippets
  --vhost-target     /www/server/panel/vhost/nginx
  --nginx-conf       /www/server/nginx/conf/nginx.conf
  --nginx-test-cmd   nginx -t
  --nginx-reload-cmd nginx -s reload

Safety rules:
  - This script does NOT create BaoTa sites by default.
  - If a target vhost conf is missing, the script fails unless --allow-bootstrap-vhosts is set.
  - Changed files are backed up before overwrite when --apply is used.
  - nginx is reloaded only when both --apply and --reload are set, and nginx -t succeeds.
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

trim_trailing_slash() {
  local value="$1"
  while [[ "$value" != "/" && "$value" == */ ]]; do
    value="${value%/}"
  done
  printf '%s\n' "$value"
}

backup_existing_file() {
  local backup_dir="$1"
  local target_file="$2"

  if [[ ! -e "$target_file" ]]; then
    return 0
  fi

  local rooted dest
  rooted="${target_file#/}"
  dest="$backup_dir/files/$rooted"
  mkdir -p "$(dirname "$dest")"
  cp -a "$target_file" "$dest"
  echo "[backup] $target_file -> $dest"
}

copy_file_if_needed() {
  local source_file="$1"
  local target_file="$2"
  local status="$3"

  case "$status" in
    NEW|REPLACE)
      mkdir -p "$(dirname "$target_file")"
      cp -f "$source_file" "$target_file"
      echo "[copy] $source_file -> $target_file ($status)"
      ;;
    SAME)
      echo "[copy] skip unchanged: $target_file"
      ;;
    *)
      ;;
  esac
}

bt_ssl_marker_present() {
  local target_file="$1"
  python3 - "$target_file" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding='utf-8')
needles = [
    '#SSL-START',
    '#error_page 404/404.html;',
]
print('1' if all(needle in text for needle in needles) else '0')
PY
}

insert_http_include() {
  local nginx_conf="$1"
  local include_path="$2"

  python3 - "$nginx_conf" "$include_path" <<'PY'
from pathlib import Path
import re
import sys

nginx_conf = Path(sys.argv[1])
include_path = sys.argv[2]
text = nginx_conf.read_text(encoding="utf-8")
lines = text.splitlines(keepends=True)
out = []
inserted = False
pending_http = False
for line in lines:
    code = line.split("#", 1)[0]
    out.append(line)
    if inserted:
        continue
    if re.match(r"^\s*http\b[^\n{;]*\{", code):
        out.append(f"    include {include_path};\n")
        inserted = True
        pending_http = False
        continue
    if re.match(r"^\s*http\b[^\n{;]*$", code) and "{" not in code and ";" not in code:
        pending_http = True
        continue
    if pending_http and re.match(r"^\s*\{", code):
        out.append(f"        include {include_path};\n")
        inserted = True
        pending_http = False
        continue
    if code.strip():
        pending_http = False
if not inserted:
    raise SystemExit("could not locate http {} block for include insertion")
nginx_conf.write_text("".join(out), encoding="utf-8")
PY
}

probe_http_include() {
  local nginx_conf="$1"
  local include_path="$2"

  python3 - "$nginx_conf" "$include_path" <<'PY'
from pathlib import Path
import re
import sys

nginx_conf = Path(sys.argv[1])
include_path = sys.argv[2]
basename = Path(include_path).name

if not nginx_conf.is_file():
    print(f"BLOCK\tmain nginx conf not found: {nginx_conf}")
    raise SystemExit(0)

lines = nginx_conf.read_text(encoding="utf-8").splitlines()
stack = []
http_line = None
exact_in_http = []
exact_outside_http = []
other_basename_refs = []
pending_http = False
pending_http_line = None

for idx, line in enumerate(lines, 1):
    code = line.split("#", 1)[0]
    stripped = code.strip()

    leading_closes = 0
    while leading_closes < len(stripped) and stripped[leading_closes] == '}':
        leading_closes += 1
    for _ in range(leading_closes):
        if stack:
            stack.pop()

    if http_line is None and re.match(r"^\s*http\b[^\n{;]*\{", code):
        http_line = idx
        stack.append("http")
    elif re.match(r"^\s*http\b[^\n{;]*$", code) and "{" not in code and ";" not in code:
        pending_http = True
        pending_http_line = idx
    elif pending_http and re.match(r"^\s*\{", code):
        if http_line is None:
            http_line = pending_http_line
        stack.append("http")
        pending_http = False
        pending_http_line = None
    elif "{" in code:
        stack.append("block")
        if stripped:
            pending_http = False
            pending_http_line = None
    elif stripped:
        pending_http = False
        pending_http_line = None

    include_match = re.match(r"^\s*include\s+([^;]+)\s*;", code)
    if include_match:
        include_target = include_match.group(1).strip()
        in_http = "http" in stack
        if include_target == include_path:
            if in_http:
                exact_in_http.append(idx)
            else:
                exact_outside_http.append(idx)
        elif basename in include_target:
            other_basename_refs.append((idx, include_target, in_http))

    trailing_closes = code.count("}") - leading_closes
    for _ in range(max(trailing_closes, 0)):
        if stack:
            stack.pop()

if exact_in_http:
    print(f"SAME\texact include already present in http {{}} at lines {','.join(map(str, exact_in_http))}")
elif exact_outside_http:
    print(f"BLOCK\texact include already present outside http {{}} at lines {','.join(map(str, exact_outside_http))}; review manually")
elif other_basename_refs:
    rendered = ", ".join(
        f"line {line} -> {target} ({'http' if in_http else 'outside-http'})"
        for line, target, in_http in other_basename_refs
    )
    print(f"BLOCK\tnginx.conf already references {basename} via a different include path: {rendered}")
elif http_line is None:
    print("BLOCK\tcould not locate nginx http {} block")
else:
    print(f"REPLACE\twill insert include into nginx.conf after http {{}} line {http_line}")
PY
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATE_SCRIPT="$SCRIPT_DIR/validate-rendered-config.sh"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

RENDERED_DIR=""
SNIPPETS_TARGET="/www/server/nginx/conf/snippets"
VHOST_TARGET="/www/server/panel/vhost/nginx"
NGINX_CONF="/www/server/nginx/conf/nginx.conf"
ERROR_ROOT_OVERRIDE=""
BACKUP_DIR="./backups/bt-panel-deploy-$TIMESTAMP"
NGINX_TEST_CMD="nginx -t"
NGINX_RELOAD_CMD="nginx -s reload"
ALLOW_BOOTSTRAP_VHOSTS="0"
SKIP_HTTP_INCLUDE="0"
APPLY="0"
RELOAD="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rendered-dir)
      RENDERED_DIR="$2"; shift 2 ;;
    --snippets-target)
      SNIPPETS_TARGET="$2"; shift 2 ;;
    --vhost-target)
      VHOST_TARGET="$2"; shift 2 ;;
    --error-root)
      ERROR_ROOT_OVERRIDE="$2"; shift 2 ;;
    --nginx-conf)
      NGINX_CONF="$2"; shift 2 ;;
    --backup-dir)
      BACKUP_DIR="$2"; shift 2 ;;
    --nginx-test-cmd)
      NGINX_TEST_CMD="$2"; shift 2 ;;
    --nginx-reload-cmd)
      NGINX_RELOAD_CMD="$2"; shift 2 ;;
    --allow-bootstrap-vhosts)
      ALLOW_BOOTSTRAP_VHOSTS="1"; shift ;;
    --skip-http-include)
      SKIP_HTTP_INCLUDE="1"; shift ;;
    --apply)
      APPLY="1"; shift ;;
    --reload)
      RELOAD="1"; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1 ;;
  esac
done

[[ -n "$RENDERED_DIR" ]] || fail "--rendered-dir is required"
[[ "$RELOAD" == "0" || "$APPLY" == "1" ]] || fail "--reload requires --apply"
[[ -f "$VALIDATE_SCRIPT" ]] || fail "validator not found: $VALIDATE_SCRIPT"

RENDERED_DIR="$(trim_trailing_slash "$RENDERED_DIR")"
SNIPPETS_TARGET="$(trim_trailing_slash "$SNIPPETS_TARGET")"
VHOST_TARGET="$(trim_trailing_slash "$VHOST_TARGET")"
NGINX_CONF="$(trim_trailing_slash "$NGINX_CONF")"
BACKUP_DIR="$(trim_trailing_slash "$BACKUP_DIR")"

[[ -d "$RENDERED_DIR" ]] || fail "rendered dir not found: $RENDERED_DIR"

info "Validating rendered package first"
bash "$VALIDATE_SCRIPT" --rendered-dir "$RENDERED_DIR"

# shellcheck disable=SC1090
safe_source_rendered_env "$RENDERED_DIR/RENDERED-VALUES.env"

for key in BASE_DOMAIN HUB_DOMAIN RAW_DOMAIN GIST_DOMAIN ASSETS_DOMAIN ARCHIVE_DOMAIN DOWNLOAD_DOMAIN ERROR_ROOT; do
  [[ -n "${!key:-}" ]] || fail "missing required rendered value: $key"
done

validate_hostname_value "BASE_DOMAIN" "$BASE_DOMAIN"
validate_hostname_value "HUB_DOMAIN" "$HUB_DOMAIN"
validate_hostname_value "RAW_DOMAIN" "$RAW_DOMAIN"
validate_hostname_value "GIST_DOMAIN" "$GIST_DOMAIN"
validate_hostname_value "ASSETS_DOMAIN" "$ASSETS_DOMAIN"
validate_hostname_value "ARCHIVE_DOMAIN" "$ARCHIVE_DOMAIN"
validate_hostname_value "DOWNLOAD_DOMAIN" "$DOWNLOAD_DOMAIN"

RENDERED_ERROR_ROOT="$ERROR_ROOT"
ERROR_ROOT="${ERROR_ROOT_OVERRIDE:-$RENDERED_ERROR_ROOT}"
ERROR_ROOT="$(trim_trailing_slash "$ERROR_ROOT")"

if [[ -n "$ERROR_ROOT_OVERRIDE" && "$ERROR_ROOT_OVERRIDE" != "$RENDERED_ERROR_ROOT" ]]; then
  fail "custom --error-root is not supported by this deploy script because rendered vhost configs already reference ERROR_ROOT=$RENDERED_ERROR_ROOT; rerender with the desired error root first"
fi

[[ -d "$VHOST_TARGET" ]] || fail "BaoTa vhost target dir not found: $VHOST_TARGET"
[[ ! -e "$SNIPPETS_TARGET" || -d "$SNIPPETS_TARGET" ]] || fail "snippets target exists but is not a directory: $SNIPPETS_TARGET"
[[ ! -e "$ERROR_ROOT" || -d "$ERROR_ROOT" ]] || fail "error root exists but is not a directory: $ERROR_ROOT"

expected_snippets_target="$(dirname "$NGINX_CONF")/snippets"
expected_snippets_target="$(trim_trailing_slash "$expected_snippets_target")"
if [[ "$SNIPPETS_TARGET" != "$expected_snippets_target" ]]; then
  fail "custom --snippets-target is not supported by this deploy script because rendered vhost configs include snippets/* relative to nginx.conf; expected: $expected_snippets_target"
fi

PLAN_ROWS=()
COUNT_NEW=0
COUNT_REPLACE=0
COUNT_SAME=0
COUNT_BLOCK=0

add_plan_row() {
  local category="$1"
  local source_path="$2"
  local target_path="$3"
  local status="$4"
  local note="$5"
  PLAN_ROWS+=("$category"$'\t'"$source_path"$'\t'"$target_path"$'\t'"$status"$'\t'"$note")
  case "$status" in
    NEW) COUNT_NEW=$((COUNT_NEW + 1)) ;;
    REPLACE) COUNT_REPLACE=$((COUNT_REPLACE + 1)) ;;
    SAME) COUNT_SAME=$((COUNT_SAME + 1)) ;;
    BLOCK) COUNT_BLOCK=$((COUNT_BLOCK + 1)) ;;
  esac
}

classify_plan_item() {
  local category="$1"
  local source_path="$2"
  local target_path="$3"
  local allow_missing="$4"

  if [[ ! -f "$source_path" ]]; then
    add_plan_row "$category" "$source_path" "$target_path" "BLOCK" "rendered source file missing"
    return 0
  fi

  if [[ -e "$target_path" && ! -f "$target_path" ]]; then
    add_plan_row "$category" "$source_path" "$target_path" "BLOCK" "target path exists but is not a regular file"
    return 0
  fi

  if [[ ! -e "$target_path" ]]; then
    if [[ "$allow_missing" == "0" ]]; then
      add_plan_row "$category" "$source_path" "$target_path" "BLOCK" "target vhost conf missing; create the BaoTa site first or rerun with --allow-bootstrap-vhosts"
    else
      add_plan_row "$category" "$source_path" "$target_path" "NEW" "target file does not exist and will be created"
    fi
    return 0
  fi

  if [[ "$category" == vhost:* ]]; then
    marker_flag="$(bt_ssl_marker_present "$source_path")"
    if [[ "$marker_flag" != "1" ]]; then
      add_plan_row "$category" "$source_path" "$target_path" "BLOCK" "rendered BaoTa vhost is missing required SSL marker anchors (#SSL-START / #error_page 404/404.html;)"
      return 0
    fi
  fi

  if cmp -s "$source_path" "$target_path"; then
    add_plan_row "$category" "$source_path" "$target_path" "SAME" "target file already matches rendered source"
  else
    add_plan_row "$category" "$source_path" "$target_path" "REPLACE" "target file differs and will be backed up before overwrite"
  fi
}

classify_flat_dir() {
  local category="$1"
  local source_dir="$2"
  local target_dir="$3"

  if [[ ! -d "$source_dir" ]]; then
    add_plan_row "$category" "$source_dir" "$target_dir" "BLOCK" "rendered source directory missing"
    return 0
  fi

  if [[ -e "$target_dir" && ! -d "$target_dir" ]]; then
    add_plan_row "$category" "$source_dir" "$target_dir" "BLOCK" "target directory path exists but is not a directory"
    return 0
  fi

  while IFS= read -r -d '' source_file; do
    local base_name target_file
    base_name="$(basename "$source_file")"
    target_file="$target_dir/$base_name"
    classify_plan_item "$category" "$source_file" "$target_file" "1"
  done < <(find "$source_dir" -maxdepth 1 -type f -print0 | sort -z)
}

SOURCE_CONF_NAMES=(
  "hub.example.com.conf"
  "raw.example.com.conf"
  "gist.example.com.conf"
  "assets.example.com.conf"
  "archive.example.com.conf"
  "download.example.com.conf"
)
TARGET_DOMAINS=(
  "$HUB_DOMAIN"
  "$RAW_DOMAIN"
  "$GIST_DOMAIN"
  "$ASSETS_DOMAIN"
  "$ARCHIVE_DOMAIN"
  "$DOWNLOAD_DOMAIN"
)
TARGET_LABELS=(
  "hub"
  "raw"
  "gist"
  "assets"
  "archive"
  "download"
)

for idx in "${!SOURCE_CONF_NAMES[@]}"; do
  source_conf="$RENDERED_DIR/conf.d/${SOURCE_CONF_NAMES[$idx]}"
  target_conf="$VHOST_TARGET/${TARGET_DOMAINS[$idx]}.conf"
  classify_plan_item "vhost:${TARGET_LABELS[$idx]}" "$source_conf" "$target_conf" "$ALLOW_BOOTSTRAP_VHOSTS"
done

classify_flat_dir "snippets" "$RENDERED_DIR/snippets" "$SNIPPETS_TARGET"
classify_flat_dir "errors" "$RENDERED_DIR/html/errors" "$ERROR_ROOT"

WHITELIST_SNIPPET="$SNIPPETS_TARGET/http-redirect-whitelist-map.conf"
HTTP_INCLUDE_STATUS="SAME"
HTTP_INCLUDE_NOTE="http include management skipped"
if [[ "$SKIP_HTTP_INCLUDE" == "1" ]]; then
  HTTP_INCLUDE_STATUS="SAME"
  HTTP_INCLUDE_NOTE="skipped by operator request (--skip-http-include)"
else
  http_probe="$(probe_http_include "$NGINX_CONF" "$WHITELIST_SNIPPET")"
  HTTP_INCLUDE_STATUS="${http_probe%%$'\t'*}"
  if [[ "$http_probe" == *$'\t'* ]]; then
    HTTP_INCLUDE_NOTE="${http_probe#*$'\t'}"
  else
    HTTP_INCLUDE_NOTE=""
  fi
  add_plan_row "nginx:http-include" "$WHITELIST_SNIPPET" "$NGINX_CONF" "$HTTP_INCLUDE_STATUS" "$HTTP_INCLUDE_NOTE"
fi

cat <<EOF

BaoTa deployment plan for rendered package
- mode: $(if [[ "$APPLY" == "1" ]]; then echo apply; else echo dry-run; fi)
- rendered dir: $RENDERED_DIR
- base domain: $BASE_DOMAIN
- domain mode: ${DOMAIN_MODE:-unknown}
- snippets target: $SNIPPETS_TARGET
- error root: $ERROR_ROOT
- vhost target: $VHOST_TARGET
- nginx conf: $NGINX_CONF
- backup dir: $BACKUP_DIR
- allow bootstrap vhosts: $ALLOW_BOOTSTRAP_VHOSTS
- manage http include: $(if [[ "$SKIP_HTTP_INCLUDE" == "1" ]]; then echo no; else echo yes; fi)

Derived vhost targets
- hub      -> $VHOST_TARGET/$HUB_DOMAIN.conf
- raw      -> $VHOST_TARGET/$RAW_DOMAIN.conf
- gist     -> $VHOST_TARGET/$GIST_DOMAIN.conf
- assets   -> $VHOST_TARGET/$ASSETS_DOMAIN.conf
- archive  -> $VHOST_TARGET/$ARCHIVE_DOMAIN.conf
- download -> $VHOST_TARGET/$DOWNLOAD_DOMAIN.conf

Plan summary
- NEW: $COUNT_NEW
- REPLACE: $COUNT_REPLACE
- SAME: $COUNT_SAME
- BLOCK: $COUNT_BLOCK
EOF

echo
for row in "${PLAN_ROWS[@]}"; do
  IFS=$'\t' read -r category source_path target_path status note <<< "$row"
  echo "- [$status] $category"
  echo "  - source: $source_path"
  echo "  - target: $target_path"
  [[ -n "$note" ]] && echo "  - note: $note"
done

echo
if [[ "$COUNT_BLOCK" -gt 0 ]]; then
  fail "plan contains blocker(s); no changes were made"
fi

if [[ "$APPLY" != "1" ]]; then
  info "Dry-run only. Review the plan above, then rerun with --apply when ready."
  exit 0
fi

if [[ -e "$BACKUP_DIR" ]]; then
  if [[ ! -d "$BACKUP_DIR" ]]; then
    fail "backup path exists but is not a directory: $BACKUP_DIR"
  fi
  if find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 | read -r _; then
    fail "backup dir already exists and is not empty: $BACKUP_DIR"
  fi
fi

mkdir -p "$BACKUP_DIR"
mkdir -p "$SNIPPETS_TARGET" "$ERROR_ROOT"
cp -f "$RENDERED_DIR/RENDERED-VALUES.env" "$BACKUP_DIR/RENDERED-VALUES.env"

MANIFEST_FILE="$BACKUP_DIR/DEPLOY-MANIFEST.txt"
{
  echo "timestamp=$TIMESTAMP"
  echo "rendered_dir=$RENDERED_DIR"
  echo "base_domain=$BASE_DOMAIN"
  echo "domain_mode=${DOMAIN_MODE:-}"
  echo "snippets_target=$SNIPPETS_TARGET"
  echo "error_root=$ERROR_ROOT"
  echo "vhost_target=$VHOST_TARGET"
  echo "nginx_conf=$NGINX_CONF"
  echo "backup_dir=$BACKUP_DIR"
  echo "nginx_test_cmd=$NGINX_TEST_CMD"
  echo "nginx_reload_cmd=$NGINX_RELOAD_CMD"
  echo "reload_requested=$RELOAD"
  echo "allow_bootstrap_vhosts=$ALLOW_BOOTSTRAP_VHOSTS"
  echo "skip_http_include=$SKIP_HTTP_INCLUDE"
  echo
  echo "[plan]"
  for row in "${PLAN_ROWS[@]}"; do
    IFS=$'\t' read -r category source_path target_path status note <<< "$row"
    printf '%s\t%s\t%s\t%s\t%s\n' "$category" "$source_path" "$target_path" "$status" "$note"
  done
} > "$MANIFEST_FILE"

for row in "${PLAN_ROWS[@]}"; do
  IFS=$'\t' read -r category source_path target_path status note <<< "$row"
  if [[ "$status" == "REPLACE" ]]; then
    backup_existing_file "$BACKUP_DIR" "$target_path"
  fi
done

for row in "${PLAN_ROWS[@]}"; do
  IFS=$'\t' read -r category source_path target_path status note <<< "$row"
  case "$category" in
    vhost:*|snippets|errors)
      copy_file_if_needed "$source_path" "$target_path" "$status"
      ;;
    nginx:http-include)
      if [[ "$status" == "REPLACE" ]]; then
        insert_http_include "$target_path" "$source_path"
        echo "[nginx] inserted http include into $target_path"
      else
        echo "[nginx] include status: $status ($note)"
      fi
      ;;
  esac
done

if [[ "$SKIP_HTTP_INCLUDE" != "1" ]]; then
  post_probe="$(probe_http_include "$NGINX_CONF" "$WHITELIST_SNIPPET")"
  post_status="${post_probe%%$'\t'*}"
  if [[ "$post_status" != "SAME" ]]; then
    fail "http include verification failed after apply: $post_probe"
  fi
fi

echo
info "Running nginx syntax test: $NGINX_TEST_CMD"
if bash -lc "$NGINX_TEST_CMD"; then
  info "nginx -t succeeded"
else
  echo >&2
  echo "[WARN] nginx syntax test failed after file changes." >&2
  echo "[WARN] Review backups in: $BACKUP_DIR" >&2
  echo "[WARN] No automatic rollback was performed." >&2
  exit 2
fi

if [[ "$RELOAD" == "1" ]]; then
  info "Reloading nginx: $NGINX_RELOAD_CMD"
  bash -lc "$NGINX_RELOAD_CMD"
  info "Reload command completed"
else
  info "Apply completed without reload. Reload later after manual review if desired."
fi

info "Apply completed successfully. Backups and manifest stored in: $BACKUP_DIR"
