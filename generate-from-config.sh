#!/usr/bin/env bash
set -euo pipefail

err() {
  echo "[generate-from-config] $*" >&2
}

usage() {
  cat <<'EOF'
Usage:
  ./generate-from-config.sh --config <deploy.yaml> [--output-dir <path>]

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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RENDER_SCRIPT="$SCRIPT_DIR/render-from-base-domain.sh"
VALIDATE_SCRIPT="$SCRIPT_DIR/validate-rendered-config.sh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG_PATH="$2"; shift 2 ;;
    --output-dir)
      OUTPUT_DIR_OVERRIDE="$2"; shift 2 ;;
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
