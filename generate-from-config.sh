#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./generate-from-config.sh --config <deploy.yaml>

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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RENDER_SCRIPT="$SCRIPT_DIR/render-from-base-domain.sh"
VALIDATE_SCRIPT="$SCRIPT_DIR/validate-rendered-config.sh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG_PATH="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1 ;;
  esac
done

if [[ -z "$CONFIG_PATH" ]]; then
  echo "Error: --config is required." >&2
  usage >&2
  exit 1
fi

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "Error: config file not found: $CONFIG_PATH" >&2
  exit 1
fi

if [[ ! -x "$RENDER_SCRIPT" ]]; then
  echo "Error: renderer not found or not executable: $RENDER_SCRIPT" >&2
  exit 1
fi

if [[ ! -x "$VALIDATE_SCRIPT" ]]; then
  echo "Error: validator not found or not executable: $VALIDATE_SCRIPT" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 is required." >&2
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
    print("ERROR: Missing Python dependency: PyYAML", file=sys.stderr)
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
        print(f"ERROR: {err}", file=sys.stderr)
    sys.exit(3)

with out_path.open('w', encoding='utf-8') as f:
    for k, v in values.items():
        escaped = str(v).replace('\\', '\\\\').replace('"', '\\"')
        f.write(f'{k}="{escaped}"\n')
PY

# shellcheck disable=SC1090
source "$TMP_ENV"

CONFIG_ABS="$(cd "$(dirname "$CONFIG_PATH")" && pwd)/$(basename "$CONFIG_PATH")"
if [[ "$OUTPUT_DIR" != /* ]]; then
  OUTPUT_DIR="$SCRIPT_DIR/${OUTPUT_DIR#./}"
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
  output_dir: $OUTPUT_DIR

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
- 输出目录：$OUTPUT_DIR

## 建议执行顺序

1. 检查 RENDERED-VALUES.env
2. 检查 conf.d/、snippets/、html/errors/ 是否符合预期
3. 按 DNS-CHECKLIST.md 完成 DNS 核对
4. 将 errors 文件放到 $ERROR_ROOT
5. 将 snippets 与 conf 按目标环境手工接入
6. 手工执行 nginx -t
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

- Hub：请查看 RENDERED-VALUES.env 中的 HUB_DOMAIN
- Raw：请查看 RENDERED-VALUES.env 中的 RAW_DOMAIN
- Gist：请查看 RENDERED-VALUES.env 中的 GIST_DOMAIN
- Assets：请查看 RENDERED-VALUES.env 中的 ASSETS_DOMAIN
- Archive：请查看 RENDERED-VALUES.env 中的 ARCHIVE_DOMAIN
- Download：请查看 RENDERED-VALUES.env 中的 DOWNLOAD_DOMAIN

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
- 输出目录：$OUTPUT_DIR

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
输出目录：$OUTPUT_DIR

下一步建议：
1. 先检查 $OUTPUT_DIR/RENDERED-VALUES.env
2. 再检查 $OUTPUT_DIR/DEPLOY-STEPS.md
3. 完成人工审查后再决定是否用于真实环境
EOF
