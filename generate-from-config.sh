#!/usr/bin/env bash
set -euo pipefail

err() {
  echo "[generate-from-config] $*" >&2
}

usage() {
  cat <<'EOF'
Usage:
  ./generate-from-config.sh --config <deploy.yaml> [--output-dir <path>] [--print-derived] [--dry-run]

What it does:
  1. Read a YAML deployment config
  2. Render files via render-from-base-domain.sh
  3. Validate output via validate-rendered-config.sh
  4. Generate Chinese deployment docs into the dist directory

What it does NOT do:
  - It does NOT modify live nginx configs
  - It does NOT reload nginx
  - It does NOT change DNS
  - It does NOT auto-apply anything to production
EOF
}

CONFIG_PATH=""
OUTPUT_DIR_OVERRIDE=""
PRINT_DERIVED="0"
DRY_RUN="0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RENDER_SCRIPT="$SCRIPT_DIR/render-from-base-domain.sh"
VALIDATE_SCRIPT="$SCRIPT_DIR/validate-rendered-config.sh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG_PATH="$2"; shift 2 ;;
    --output-dir)
      OUTPUT_DIR_OVERRIDE="$2"; shift 2 ;;
    --print-derived)
      PRINT_DERIVED="1"; shift ;;
    --dry-run)
      DRY_RUN="1"; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      err "Unknown argument: $1"
      usage >&2
      exit 1 ;;
  esac
done

if [[ -z "$CONFIG_PATH" ]]; then
  err "Missing required argument: --config <deploy.yaml>"
  usage >&2
  exit 1
fi

if [[ ! -f "$CONFIG_PATH" ]]; then
  err "Config file not found: $CONFIG_PATH"
  err "Please check the path and try again."
  exit 1
fi

if [[ ! -x "$RENDER_SCRIPT" ]]; then
  err "Renderer script is missing or not executable: $RENDER_SCRIPT"
  exit 1
fi

if [[ ! -x "$VALIDATE_SCRIPT" ]]; then
  err "Validator script is missing or not executable: $VALIDATE_SCRIPT"
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  err "python3 is required for the v0.2 generator."
  err "Install python3 first, then run this command again."
  exit 1
fi

TMP_ENV="$(mktemp)"
trap 'rm -f "$TMP_ENV"' EXIT

python3 - "$CONFIG_PATH" "$TMP_ENV" <<'PY'
import json
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])

try:
    import yaml
except Exception:
    print("[generate-from-config] Missing Python dependency: PyYAML", file=sys.stderr)
    print("[generate-from-config] Install it first, for example: python3 -m pip install pyyaml", file=sys.stderr)
    sys.exit(2)

with config_path.open('r', encoding='utf-8') as f:
    data = yaml.safe_load(f) or {}

errors = []

def get(path, default=None):
    cur = data
    for key in path.split('.'):
        if not isinstance(cur, dict) or key not in cur:
            return default
        cur = cur[key]
    return cur

values = {
    'DEPLOYMENT_NAME': get('deployment_name', ''),
    'BASE_DOMAIN': get('domain.base_domain', ''),
    'DOMAIN_MODE': get('domain.mode', 'nested'),
    'SSL_CERT': get('tls.cert', ''),
    'SSL_KEY': get('tls.key', ''),
    'ERROR_ROOT': get('paths.error_root', ''),
    'LOG_DIR': get('paths.log_dir', '/www/wwwlogs'),
    'OUTPUT_DIR': get('paths.output_dir', ''),
    'NGINX_SNIPPETS_TARGET_HINT': get('nginx.snippets_target_hint', ''),
    'NGINX_VHOST_TARGET_HINT': get('nginx.vhost_target_hint', ''),
    'PLATFORM': get('deployment.platform', 'plain-nginx'),
    'DOC_LANGUAGE': get('docs.language', 'zh-CN'),
}

for field in ['DEPLOYMENT_NAME', 'BASE_DOMAIN', 'SSL_CERT', 'SSL_KEY', 'ERROR_ROOT', 'OUTPUT_DIR']:
    if not values[field]:
        errors.append(f"Missing required field: {field}")

if values['DOMAIN_MODE'] not in ('nested', 'flat-siblings'):
    errors.append("domain.mode must be one of: nested, flat-siblings")

if values['PLATFORM'] not in ('bt-panel-nginx', 'plain-nginx'):
    errors.append("deployment.platform must be one of: bt-panel-nginx, plain-nginx")

if errors:
    for err in errors:
        print(f"[generate-from-config] {err}", file=sys.stderr)
    print("[generate-from-config] Please update your deploy.yaml and run the generator again.", file=sys.stderr)
    sys.exit(3)

with out_path.open('w', encoding='utf-8') as f:
    for k, v in values.items():
        escaped = str(v).replace('\\', '\\\\').replace('"', '\\"')
        f.write(f'{k}="{escaped}"\n')
PY

# shellcheck disable=SC1090
source "$TMP_ENV"

if [[ -n "$OUTPUT_DIR_OVERRIDE" ]]; then
  OUTPUT_DIR="$OUTPUT_DIR_OVERRIDE"
fi

CONFIG_ABS="$(cd "$(dirname "$CONFIG_PATH")" && pwd)/$(basename "$CONFIG_PATH")"
OUTPUT_DIR_DISPLAY="$OUTPUT_DIR"
if [[ "$OUTPUT_DIR" != /* ]]; then
  OUTPUT_DIR="$SCRIPT_DIR/${OUTPUT_DIR#./}"
fi
OUTPUT_DIR_CANONICAL="$(cd "$OUTPUT_DIR" 2>/dev/null && pwd || true)"
if [[ -z "$OUTPUT_DIR_CANONICAL" ]]; then
  OUTPUT_DIR_CANONICAL="$(dirname "$OUTPUT_DIR")/$(basename "$OUTPUT_DIR")"
fi

if [[ "$PRINT_DERIVED" == "1" || "$DRY_RUN" == "1" ]]; then
  if [[ "$DOMAIN_MODE" == "nested" ]]; then
    RAW_DOMAIN="raw.$BASE_DOMAIN"
    GIST_DOMAIN="gist.$BASE_DOMAIN"
    ASSETS_DOMAIN="assets.$BASE_DOMAIN"
    ARCHIVE_DOMAIN="archive.$BASE_DOMAIN"
    DOWNLOAD_DOMAIN="download.$BASE_DOMAIN"
  else
    BASE_SUFFIX="${BASE_DOMAIN#*.}"
    if [[ "$BASE_SUFFIX" == "$BASE_DOMAIN" || -z "$BASE_SUFFIX" ]]; then
      err "flat-siblings mode requires base_domain to contain at least one dot: $BASE_DOMAIN"
      exit 4
    fi
    RAW_DOMAIN="raw.$BASE_SUFFIX"
    GIST_DOMAIN="gist.$BASE_SUFFIX"
    ASSETS_DOMAIN="assets.$BASE_SUFFIX"
    ARCHIVE_DOMAIN="archive.$BASE_SUFFIX"
    DOWNLOAD_DOMAIN="download.$BASE_SUFFIX"
  fi

  WARNINGS=()
  NOTES=()

  if [[ "$DEPLOYMENT_NAME" =~ [[:space:]] ]]; then
    WARNINGS+=("deployment_name contains whitespace; prefer a simple directory-safe name: $DEPLOYMENT_NAME")
  fi

  if [[ ! "$DEPLOYMENT_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
    WARNINGS+=("deployment_name contains characters outside [A-Za-z0-9._-]; review whether it is safe for directory naming: $DEPLOYMENT_NAME")
  fi

  if [[ "$BASE_DOMAIN" != *.* ]]; then
    WARNINGS+=("base_domain does not look like a fully qualified domain name: $BASE_DOMAIN")
  fi

  if [[ "$BASE_DOMAIN" =~ [A-Z] ]]; then
    WARNINGS+=("base_domain contains uppercase letters; prefer lowercase hostnames: $BASE_DOMAIN")
  fi

  if [[ "$BASE_DOMAIN" == .* || "$BASE_DOMAIN" == *. || "$BASE_DOMAIN" == *..* ]]; then
    WARNINGS+=("base_domain looks malformed; review leading/trailing/consecutive dots: $BASE_DOMAIN")
  fi

  BASE_DOMAIN_LOWER="${BASE_DOMAIN,,}"
  IFS='.' read -r -a DOMAIN_LABELS <<< "$BASE_DOMAIN_LOWER"
  HAS_INVALID_DOMAIN_CHARS="0"
  HAS_EDGE_HYPHEN_LABEL="0"
  for label in "${DOMAIN_LABELS[@]}"; do
    if [[ -z "$label" ]]; then
      continue
    fi
    if [[ ! "$label" =~ ^[a-z0-9-]+$ ]]; then
      HAS_INVALID_DOMAIN_CHARS="1"
    fi
    if [[ "$label" == -* || "$label" == *- ]]; then
      HAS_EDGE_HYPHEN_LABEL="1"
    fi
  done
  if [[ "$HAS_INVALID_DOMAIN_CHARS" == "1" ]]; then
    WARNINGS+=("base_domain contains a label with characters outside [a-z0-9-]: $BASE_DOMAIN")
  fi
  if [[ "$HAS_EDGE_HYPHEN_LABEL" == "1" ]]; then
    WARNINGS+=("base_domain contains a label starting or ending with '-': $BASE_DOMAIN")
  fi

  SSL_CERT_BASENAME="$(basename "$SSL_CERT")"
  SSL_KEY_BASENAME="$(basename "$SSL_KEY")"
  SSL_CERT_EXT="${SSL_CERT_BASENAME##*.}"
  SSL_KEY_EXT="${SSL_KEY_BASENAME##*.}"
  SSL_CERT_LOWER="${SSL_CERT,,}"
  SSL_KEY_LOWER="${SSL_KEY,,}"

  if [[ "$SSL_CERT" != /* ]]; then
    WARNINGS+=("SSL_CERT is not an absolute path: $SSL_CERT")
  fi

  if [[ "$SSL_KEY" != /* ]]; then
    WARNINGS+=("SSL_KEY is not an absolute path: $SSL_KEY")
  fi

  case "$SSL_CERT_LOWER" in
    *.pem|*.crt|*.cer) ;;
    *) WARNINGS+=("SSL_CERT does not look like a typical certificate file path (.pem/.crt/.cer): $SSL_CERT") ;;
  esac

  case "$SSL_KEY_LOWER" in
    *.pem|*.key) ;;
    *) WARNINGS+=("SSL_KEY does not look like a typical private key file path (.pem/.key): $SSL_KEY") ;;
  esac

  if [[ "$SSL_CERT_LOWER" == *key* ]]; then
    WARNINGS+=("SSL_CERT path contains 'key'; review whether cert/key paths may be swapped: $SSL_CERT")
  fi

  if [[ "$SSL_KEY_LOWER" == *cert* || "$SSL_KEY_LOWER" == *chain* || "$SSL_KEY_LOWER" == *fullchain* ]]; then
    WARNINGS+=("SSL_KEY path looks certificate-like; review whether cert/key paths may be swapped: $SSL_KEY")
  fi

  if [[ "$ERROR_ROOT" != /* ]]; then
    WARNINGS+=("ERROR_ROOT is not an absolute path: $ERROR_ROOT")
  fi

  if [[ "$LOG_DIR" != /* ]]; then
    WARNINGS+=("LOG_DIR is not an absolute path: $LOG_DIR")
  fi

  case "$OUTPUT_DIR_DISPLAY" in
    ""|"."|"./"|".."|"../")
      WARNINGS+=("output_dir is too broad or ambiguous; prefer a dedicated deployment subdirectory: $OUTPUT_DIR_DISPLAY")
      ;;
  esac

  if [[ "$OUTPUT_DIR_DISPLAY" == /* ]]; then
    WARNINGS+=("output_dir is an absolute path; review carefully before writing outside the repository: $OUTPUT_DIR_DISPLAY")
  fi

  case "$OUTPUT_DIR_DISPLAY" in
    /etc/*|/usr/*|/var/*|/www/server/*|/www/wwwroot/*)
      WARNINGS+=("output_dir looks like a live system path; prefer generating into a reviewable workspace path first: $OUTPUT_DIR_DISPLAY")
      ;;
  esac

  if [[ "$OUTPUT_DIR_DISPLAY" == "$SCRIPT_DIR" || "$OUTPUT_DIR_DISPLAY" == "$SCRIPT_DIR/" ]]; then
    WARNINGS+=("output_dir points at the repository root; prefer a dedicated subdirectory such as ./dist/<deployment-name>")
  fi

  if [[ "$OUTPUT_DIR" == "$SCRIPT_DIR" || "$OUTPUT_DIR" == "$SCRIPT_DIR/" ]]; then
    WARNINGS+=("effective output path resolves to the repository root; this is risky for generated files")
  fi

  if [[ "$OUTPUT_DIR_CANONICAL" == "$SCRIPT_DIR" ]]; then
    WARNINGS+=("output_dir resolves to the repository root after path normalization; prefer a dedicated deployment subdirectory")
  fi

  if [[ -d "$OUTPUT_DIR" ]]; then
    if find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 | read -r _; then
      WARNINGS+=("effective output path already exists and is not empty; review overwrite/mixing risk before generating: $OUTPUT_DIR")
    else
      NOTES+=("Output dir hint: effective output path already exists and is currently empty: $OUTPUT_DIR")
    fi
  else
    OUTPUT_PARENT="$(dirname "$OUTPUT_DIR")"
    if [[ ! -d "$OUTPUT_PARENT" ]]; then
      NOTES+=("Output dir hint: parent directory does not exist yet; generation will create it: $OUTPUT_PARENT")
    else
      NOTES+=("Output dir hint: effective output path does not exist yet; generation will create it: $OUTPUT_DIR")
    fi
  fi

  DEPLOYMENT_NAME_LOWER="${DEPLOYMENT_NAME,,}"
  OUTPUT_DIR_DISPLAY_LOWER="${OUTPUT_DIR_DISPLAY,,}"
  NGINX_SNIPPETS_TARGET_HINT_VALUE="${NGINX_SNIPPETS_TARGET_HINT:-}"
  NGINX_VHOST_TARGET_HINT_VALUE="${NGINX_VHOST_TARGET_HINT:-}"
  SNIPPETS_HINT_LOWER="${NGINX_SNIPPETS_TARGET_HINT_VALUE,,}"
  VHOST_HINT_LOWER="${NGINX_VHOST_TARGET_HINT_VALUE,,}"

  if [[ "$OUTPUT_DIR_DISPLAY_LOWER" != *"$DEPLOYMENT_NAME_LOWER"* ]]; then
    NOTES+=("Consistency hint: output_dir does not include deployment_name; confirm this is intentional: deployment_name=$DEPLOYMENT_NAME, output_dir=$OUTPUT_DIR_DISPLAY")
  fi

  if [[ "$PLATFORM" == "bt-panel-nginx" ]]; then
    if [[ -n "$NGINX_SNIPPETS_TARGET_HINT_VALUE" && "$SNIPPETS_HINT_LOWER" != *"/www/server/"* ]]; then
      WARNINGS+=("nginx.snippets_target_hint does not look like a 宝塔-style path for bt-panel-nginx: $NGINX_SNIPPETS_TARGET_HINT_VALUE")
    fi
    if [[ -n "$NGINX_VHOST_TARGET_HINT_VALUE" && "$VHOST_HINT_LOWER" != *"/www/server/panel/vhost/nginx"* ]]; then
      WARNINGS+=("nginx.vhost_target_hint does not look like a 宝塔 vhost path for bt-panel-nginx: $NGINX_VHOST_TARGET_HINT_VALUE")
    fi
  else
    if [[ -n "$NGINX_SNIPPETS_TARGET_HINT_VALUE" && "$SNIPPETS_HINT_LOWER" == *"/www/server/"* ]]; then
      NOTES+=("Consistency hint: nginx.snippets_target_hint looks 宝塔-specific while platform is plain-nginx: $NGINX_SNIPPETS_TARGET_HINT_VALUE")
    fi
    if [[ -n "$NGINX_VHOST_TARGET_HINT_VALUE" && "$VHOST_HINT_LOWER" == *"/www/server/panel/vhost/nginx"* ]]; then
      NOTES+=("Consistency hint: nginx.vhost_target_hint looks 宝塔-specific while platform is plain-nginx: $NGINX_VHOST_TARGET_HINT_VALUE")
    fi
  fi

  if [[ "$DOMAIN_MODE" == "flat-siblings" ]]; then
    NOTES+=("Domain hint: flat-siblings will keep HUB_DOMAIN as $BASE_DOMAIN and derive sibling domains from ${BASE_DOMAIN#*.}.")
  else
    NOTES+=("Domain hint: nested mode will derive raw/gist/assets/archive/download as subdomains under $BASE_DOMAIN.")
  fi

  if [[ "$PLATFORM" == "bt-panel-nginx" ]]; then
    NOTES+=("Platform hint: bt-panel-nginx mode assumes you will attach generated conf/snippets into 宝塔-managed vhost locations manually.")
  else
    NOTES+=("Platform hint: plain-nginx mode assumes you will connect generated conf/snippets into your own nginx include layout manually.")
  fi

  NOTES+=("Safety reminder: the generator does not apply nginx changes, does not reload nginx, and does not modify DNS.")

  if [[ "$PRINT_DERIVED" == "1" ]]; then
    cat <<EOF
派生结果预览：

- deployment_name: $DEPLOYMENT_NAME
- source_config: $CONFIG_ABS
- platform: $PLATFORM
- domain_mode: $DOMAIN_MODE
- output_dir: $OUTPUT_DIR_DISPLAY

域名：
- HUB_DOMAIN=$BASE_DOMAIN
- RAW_DOMAIN=$RAW_DOMAIN
- GIST_DOMAIN=$GIST_DOMAIN
- ASSETS_DOMAIN=$ASSETS_DOMAIN
- ARCHIVE_DOMAIN=$ARCHIVE_DOMAIN
- DOWNLOAD_DOMAIN=$DOWNLOAD_DOMAIN

路径：
- SSL_CERT=$SSL_CERT
- SSL_KEY=$SSL_KEY
- ERROR_ROOT=$ERROR_ROOT
- LOG_DIR=$LOG_DIR
EOF
    exit 0
  fi

  cat <<EOF
Dry run complete. No files were written.

- deployment_name: $DEPLOYMENT_NAME
- source_config: $CONFIG_ABS
- platform: $PLATFORM
- domain_mode: $DOMAIN_MODE
- output_dir: $OUTPUT_DIR_DISPLAY
- effective_output_path: $OUTPUT_DIR

Derived domains:
- HUB_DOMAIN=$BASE_DOMAIN
- RAW_DOMAIN=$RAW_DOMAIN
- GIST_DOMAIN=$GIST_DOMAIN
- ASSETS_DOMAIN=$ASSETS_DOMAIN
- ARCHIVE_DOMAIN=$ARCHIVE_DOMAIN
- DOWNLOAD_DOMAIN=$DOWNLOAD_DOMAIN

Input paths:
- SSL_CERT=$SSL_CERT
- SSL_KEY=$SSL_KEY
- ERROR_ROOT=$ERROR_ROOT
- LOG_DIR=$LOG_DIR

Planned generation steps:
1. Create output directory structure under $OUTPUT_DIR_DISPLAY
2. Render conf.d/, snippets/, html/errors/
3. Write RENDERED-VALUES.env and deploy.resolved.yaml
4. Run validate-rendered-config.sh against the rendered directory
5. Generate DEPLOY-STEPS.md, DNS-CHECKLIST.md, RISK-NOTES.md, SUMMARY.md

Checks passed for dry-run entry:
- config parsed successfully
- required fields are present
- domain.mode is valid
- deployment.platform is valid
- derived domains computed successfully
EOF

  if (( ${#WARNINGS[@]} > 0 )); then
    echo
    echo "Warnings:"
    for item in "${WARNINGS[@]}"; do
      echo "- $item"
    done
  fi

  if (( ${#NOTES[@]} > 0 )); then
    echo
    echo "Notes:"
    for item in "${NOTES[@]}"; do
      echo "- $item"
    done
  fi

  cat <<EOF

Next step:
- remove --dry-run to generate the deployment package for real
EOF
  exit 0
fi

if [[ "$PLATFORM" == "bt-panel-nginx" ]]; then
  PLATFORM_STEP_4="4. 将 errors 文件放到 $ERROR_ROOT，并准备按宝塔站点布局接入配置"
  PLATFORM_STEP_5="5. 将 snippets 与 conf 按宝塔/Nginx 目录手工接入；优先使用宝塔已生成的 vhost 作为落地点"
  PLATFORM_STEP_6="6. 在目标机器上手工执行 nginx -t，确认宝塔现有站点未被误伤"
else
  PLATFORM_STEP_4="4. 将 errors 文件放到 $ERROR_ROOT，并按你的 Nginx 目录规划准备落地"
  PLATFORM_STEP_5="5. 将 snippets 与 conf 按 plain Nginx 目录手工接入；确认 include 路径与主配置一致"
  PLATFORM_STEP_6="6. 在目标机器上手工执行 nginx -t，确认主配置与 include 关系正确"
fi

mkdir -p "$OUTPUT_DIR"

"$RENDER_SCRIPT" \
  --base-domain "$BASE_DOMAIN" \
  --domain-mode "$DOMAIN_MODE" \
  --ssl-cert "$SSL_CERT" \
  --ssl-key "$SSL_KEY" \
  --error-root "$ERROR_ROOT" \
  --log-dir "$LOG_DIR" \
  --output-dir "$OUTPUT_DIR"

"$VALIDATE_SCRIPT" --rendered-dir "$OUTPUT_DIR"

cat > "$OUTPUT_DIR/deploy.resolved.yaml" <<EOF
source_config: $CONFIG_ABS
deployment_name: $DEPLOYMENT_NAME

domain:
  base_domain: $BASE_DOMAIN
  mode: $DOMAIN_MODE

tls:
  cert: $SSL_CERT
  key: $SSL_KEY

paths:
  error_root: $ERROR_ROOT
  log_dir: $LOG_DIR
  output_dir: $OUTPUT_DIR_DISPLAY

deployment:
  platform: $PLATFORM

docs:
  language: $DOC_LANGUAGE
EOF

cat > "$OUTPUT_DIR/DEPLOY-STEPS.md" <<EOF
# 部署步骤（自动生成）

## 本次部署摘要

- 部署名称：$DEPLOYMENT_NAME
- 基础域名：$BASE_DOMAIN
- 域名模式：$DOMAIN_MODE
- 平台：$PLATFORM
- 输出目录：$OUTPUT_DIR_DISPLAY

## 本次派生域名

- Hub：$BASE_DOMAIN
- Raw：$(grep '^RAW_DOMAIN=' "$OUTPUT_DIR/RENDERED-VALUES.env" | cut -d= -f2-)
- Gist：$(grep '^GIST_DOMAIN=' "$OUTPUT_DIR/RENDERED-VALUES.env" | cut -d= -f2-)
- Assets：$(grep '^ASSETS_DOMAIN=' "$OUTPUT_DIR/RENDERED-VALUES.env" | cut -d= -f2-)
- Archive：$(grep '^ARCHIVE_DOMAIN=' "$OUTPUT_DIR/RENDERED-VALUES.env" | cut -d= -f2-)
- Download：$(grep '^DOWNLOAD_DOMAIN=' "$OUTPUT_DIR/RENDERED-VALUES.env" | cut -d= -f2-)

## 建议执行顺序

1. 检查 RENDERED-VALUES.env
2. 检查 conf.d/、snippets/、html/errors/ 是否符合预期
3. 按 DNS-CHECKLIST.md 完成 DNS 核对
$PLATFORM_STEP_4
$PLATFORM_STEP_5
$PLATFORM_STEP_6
7. 通过后再决定是否 reload

## 重要说明

- 本部署包是“生成结果”，不是自动安装器
- 不会自动修改线上 Nginx
- 不会自动 reload
- 不会自动改 DNS
EOF

cat > "$OUTPUT_DIR/DNS-CHECKLIST.md" <<EOF
# DNS 检查清单（自动生成）

请确认以下域名已正确解析到目标服务器：

- Hub：$BASE_DOMAIN
- Raw：$(grep '^RAW_DOMAIN=' "$OUTPUT_DIR/RENDERED-VALUES.env" | cut -d= -f2-)
- Gist：$(grep '^GIST_DOMAIN=' "$OUTPUT_DIR/RENDERED-VALUES.env" | cut -d= -f2-)
- Assets：$(grep '^ASSETS_DOMAIN=' "$OUTPUT_DIR/RENDERED-VALUES.env" | cut -d= -f2-)
- Archive：$(grep '^ARCHIVE_DOMAIN=' "$OUTPUT_DIR/RENDERED-VALUES.env" | cut -d= -f2-)
- Download：$(grep '^DOWNLOAD_DOMAIN=' "$OUTPUT_DIR/RENDERED-VALUES.env" | cut -d= -f2-)

建议在正式接入前逐项验证解析结果。
EOF

cat > "$OUTPUT_DIR/RISK-NOTES.md" <<EOF
# 风险说明（自动生成）

## 这是什么

这是一个 GitHub 公共只读镜像部署包。

## 这不是什么

- 不是 GitHub 完整替代站
- 不是登录代理
- 不是私有仓库网关
- 不是自动上线工具

## 当前安全边界

- 仍需人工审查后再部署
- 仍需人工执行 nginx -t
- 仍需人工决定是否 reload
- 不应把生成结果直接视为“已上线”
EOF

cat > "$OUTPUT_DIR/SUMMARY.md" <<EOF
# 部署包摘要（自动生成）

- 部署名称：$DEPLOYMENT_NAME
- 基础域名：$BASE_DOMAIN
- 域名模式：$DOMAIN_MODE
- 平台：$PLATFORM
- 输出目录：$OUTPUT_DIR_DISPLAY

## 派生域名

- Hub：$BASE_DOMAIN
- Raw：$(grep '^RAW_DOMAIN=' "$OUTPUT_DIR/RENDERED-VALUES.env" | cut -d= -f2-)
- Gist：$(grep '^GIST_DOMAIN=' "$OUTPUT_DIR/RENDERED-VALUES.env" | cut -d= -f2-)
- Assets：$(grep '^ASSETS_DOMAIN=' "$OUTPUT_DIR/RENDERED-VALUES.env" | cut -d= -f2-)
- Archive：$(grep '^ARCHIVE_DOMAIN=' "$OUTPUT_DIR/RENDERED-VALUES.env" | cut -d= -f2-)
- Download：$(grep '^DOWNLOAD_DOMAIN=' "$OUTPUT_DIR/RENDERED-VALUES.env" | cut -d= -f2-)

已生成：

- conf.d/
- snippets/
- html/errors/
- RENDERED-VALUES.env
- deploy.resolved.yaml
- DEPLOY-STEPS.md
- DNS-CHECKLIST.md
- RISK-NOTES.md
- SUMMARY.md
EOF

cat <<EOF
生成完成。

部署名称：$DEPLOYMENT_NAME
输出目录（配置值）：$OUTPUT_DIR_DISPLAY
输出目录（实际路径）：$OUTPUT_DIR

下一步建议：
1. 先检查 $OUTPUT_DIR_DISPLAY/RENDERED-VALUES.env
2. 再检查 $OUTPUT_DIR_DISPLAY/DEPLOY-STEPS.md
3. 完成人工审查后再决定是否用于真实环境
EOF
