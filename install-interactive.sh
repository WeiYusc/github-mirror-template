#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"

# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/ui.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/config.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/apply-plan.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/checks.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/dns.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/tls.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/backup.sh"

usage() {
  cat <<'EOF'
Usage:
  ./install-interactive.sh
  ./install-interactive.sh [options]

Current stage:
  - Collect interactive inputs
  - Generate a deploy config draft
  - Run basic preflight checks
  - Call generate-from-config.sh
  - Offer apply dry-run
  - Support conservative real apply after explicit confirmation

Input modes:
  - Basic mode: use platform-derived default paths
  - Advanced mode: override error_root / log_dir / output_dir / nginx target hints

Options:
  --deployment-name <name>
  --base-domain <domain>
  --domain-mode <flat-siblings|nested>
  --platform <bt-panel-nginx|plain-nginx>
  --tls-cert <path>
  --tls-key <path>
  --input-mode <basic|advanced>
  --error-root <path>
  --log-dir <path>
  --output-dir <path>
  --snippets-target <path>
  --vhost-target <path>
  --run-apply-dry-run
  --execute-apply
  --backup-dir <path>
  --run-nginx-test
  --nginx-test-cmd <cmd>
  --yes
  -h, --help

Examples:
  ./install-interactive.sh \
    --deployment-name github-mirror-prod \
    --base-domain github.example.com \
    --domain-mode flat-siblings \
    --platform bt-panel-nginx \
    --tls-cert /etc/ssl/example/fullchain.pem \
    --tls-key /etc/ssl/example/privkey.pem \
    --input-mode basic \
    --run-apply-dry-run \
    --yes

  ./install-interactive.sh \
    --deployment-name github-mirror-prod \
    --base-domain github.example.com \
    --domain-mode flat-siblings \
    --platform plain-nginx \
    --tls-cert /etc/ssl/example/fullchain.pem \
    --tls-key /etc/ssl/example/privkey.pem \
    --input-mode advanced \
    --error-root /var/www/github-mirror-errors \
    --log-dir /var/log/nginx \
    --output-dir /tmp/github-mirror-prod \
    --snippets-target /etc/nginx/snippets \
    --vhost-target /etc/nginx/conf.d \
    --run-apply-dry-run \
    --execute-apply \
    --backup-dir /tmp/github-mirror-backups/run-01 \
    --run-nginx-test \
    --nginx-test-cmd 'nginx -t' \
    --yes

What it does NOT do yet:
  - It does NOT change DNS
  - It does NOT reload nginx
  - It does NOT auto-rollback when nginx test fails
  - It does NOT take over complex live nginx configs automatically
EOF
}

set_platform_defaults() {
  local platform="$1"
  case "$platform" in
    bt-panel-nginx)
      DEFAULT_ERROR_ROOT="/www/wwwroot/github-mirror-errors"
      DEFAULT_LOG_DIR="/www/wwwlogs"
      DEFAULT_OUTPUT_DIR="./dist/${DEPLOYMENT_NAME}"
      DEFAULT_NGINX_SNIPPETS_TARGET_HINT="/www/server/nginx/snippets"
      DEFAULT_NGINX_VHOST_TARGET_HINT="/www/server/panel/vhost/nginx"
      ;;
    plain-nginx)
      DEFAULT_ERROR_ROOT="/var/www/github-mirror-errors"
      DEFAULT_LOG_DIR="/var/log/nginx"
      DEFAULT_OUTPUT_DIR="./dist/${DEPLOYMENT_NAME}"
      DEFAULT_NGINX_SNIPPETS_TARGET_HINT="/etc/nginx/snippets"
      DEFAULT_NGINX_VHOST_TARGET_HINT="/etc/nginx/conf.d"
      ;;
    *)
      ui_error "不支持的平台：$platform"
      exit 1
      ;;
  esac
}

validate_choice() {
  local value="$1"
  shift
  local allowed
  for allowed in "$@"; do
    if [[ "$value" == "$allowed" ]]; then
      return 0
    fi
  done
  return 1
}

prompt_or_keep() {
  local var_name="$1"
  local prompt="$2"
  local default="${3:-}"
  if [[ -z "${!var_name:-}" ]]; then
    ui_prompt "$var_name" "$prompt" "$default"
  else
    ui_info "使用命令行参数 $var_name=${!var_name}"
  fi
}

prompt_path_or_keep() {
  local var_name="$1"
  local prompt="$2"
  local default="${3:-}"
  if [[ -z "${!var_name:-}" ]]; then
    ui_prompt_path "$var_name" "$prompt" "$default"
  else
    ui_info "使用命令行参数 $var_name=${!var_name}"
  fi
}

choose_or_keep() {
  local var_name="$1"
  local prompt="$2"
  shift 2
  local options=("$@")
  if [[ -z "${!var_name:-}" ]]; then
    ui_choose "$var_name" "$prompt" "${options[@]}"
  else
    if ! validate_choice "${!var_name}" "${options[@]}"; then
      ui_error "$var_name 取值无效：${!var_name}"
      exit 1
    fi
    ui_info "使用命令行参数 $var_name=${!var_name}"
  fi
}

installer_json_bool() {
  if [[ "${1:-0}" == "1" ]]; then
    printf 'true'
  else
    printf 'false'
  fi
}

write_installer_summary_json() {
  local target_path="$1"
  local exit_code="${2:-0}"
  local final_status="${INSTALLER_FINAL_STATUS:-running}"
  local apply_result_exists="false"

  if [[ "$final_status" == "running" ]]; then
    if [[ "$exit_code" == "0" ]]; then
      final_status="success"
    elif [[ "${INSTALLER_PREFLIGHT_STATUS:-pending}" == "blocked" ]]; then
      final_status="blocked"
    else
      final_status="failed"
    fi
  fi

  if [[ -n "${APPLY_RESULT_PATH:-}" && -f "$APPLY_RESULT_PATH" ]]; then
    apply_result_exists="true"
  fi

  mkdir -p "$(dirname "$target_path")"

  {
    echo "{"
    printf '  "deployment_name": %s,\n' "$(apply_plan_json_escape "${DEPLOYMENT_NAME:-}")"
    printf '  "base_domain": %s,\n' "$(apply_plan_json_escape "${BASE_DOMAIN:-}")"
    printf '  "domain_mode": %s,\n' "$(apply_plan_json_escape "${DOMAIN_MODE:-}")"
    printf '  "platform": %s,\n' "$(apply_plan_json_escape "${PLATFORM:-}")"
    printf '  "input_mode": %s,\n' "$(apply_plan_json_escape "${INSTALL_INPUT_MODE:-${INPUT_MODE:-}}")"
    echo '  "flags": {'
    printf '    "assume_yes": %s,\n' "$(installer_json_bool "${ASSUME_YES:-0}")"
    printf '    "run_apply_dry_run": %s,\n' "$(installer_json_bool "${RUN_APPLY_DRY_RUN:-0}")"
    printf '    "execute_apply": %s,\n' "$(installer_json_bool "${EXECUTE_APPLY:-0}")"
    printf '    "run_nginx_test_after_execute": %s\n' "$(installer_json_bool "${RUN_NGINX_TEST_AFTER_EXECUTE:-0}")"
    echo '  },'
    echo '  "status": {'
    printf '    "preflight": %s,\n' "$(apply_plan_json_escape "${INSTALLER_PREFLIGHT_STATUS:-pending}")"
    printf '    "generator": %s,\n' "$(apply_plan_json_escape "${INSTALLER_GENERATOR_STATUS:-pending}")"
    printf '    "apply_plan": %s,\n' "$(apply_plan_json_escape "${INSTALLER_APPLY_PLAN_STATUS:-pending}")"
    printf '    "apply_dry_run": %s,\n' "$(apply_plan_json_escape "${INSTALLER_DRY_RUN_STATUS:-not-requested}")"
    printf '    "apply_execute": %s,\n' "$(apply_plan_json_escape "${INSTALLER_EXECUTE_STATUS:-not-requested}")"
    printf '    "final": %s,\n' "$(apply_plan_json_escape "$final_status")"
    printf '    "exit_code": %s\n' "$exit_code"
    echo '  },'
    echo '  "artifacts": {'
    printf '    "preflight_markdown": %s,\n' "$(apply_plan_json_escape "${PREFLIGHT_REPORT_MD:-}")"
    printf '    "preflight_json": %s,\n' "$(apply_plan_json_escape "${PREFLIGHT_REPORT_JSON:-}")"
    printf '    "config": %s,\n' "$(apply_plan_json_escape "${CONFIG_PATH:-}")"
    printf '    "output_dir": %s,\n' "$(apply_plan_json_escape "${OUTPUT_DIR_ABS:-}")"
    printf '    "apply_plan_markdown": %s,\n' "$(apply_plan_json_escape "${APPLY_PLAN_PATH:-}")"
    printf '    "apply_plan_json": %s,\n' "$(apply_plan_json_escape "${APPLY_PLAN_JSON_PATH:-}")"
    printf '    "apply_result": %s,\n' "$(apply_plan_json_escape "${APPLY_RESULT_PATH:-}")"
    printf '    "summary_generated": %s,\n' "$(apply_plan_json_escape "${SUMMARY_JSON_PRIMARY:-}")"
    printf '    "summary_output": %s,\n' "$(apply_plan_json_escape "${SUMMARY_JSON_SECONDARY:-}")"
    printf '    "apply_result_exists": %s\n' "$apply_result_exists"
    echo '  }'
    echo "}"
  } > "$target_path"
}

installer_write_summary_artifacts() {
  local exit_code="${1:-0}"

  if [[ -n "${SUMMARY_JSON_PRIMARY:-}" ]]; then
    write_installer_summary_json "$SUMMARY_JSON_PRIMARY" "$exit_code"
  fi

  if [[ -n "${SUMMARY_JSON_SECONDARY:-}" ]]; then
    write_installer_summary_json "$SUMMARY_JSON_SECONDARY" "$exit_code"
  fi
}

installer_on_exit() {
  local rc=$?
  trap - EXIT
  installer_write_summary_artifacts "$rc" || true
  exit "$rc"
}

DEPLOYMENT_NAME=""
BASE_DOMAIN=""
DOMAIN_MODE=""
PLATFORM=""
TLS_CERT=""
TLS_KEY=""
INPUT_MODE=""
ERROR_ROOT=""
LOG_DIR=""
OUTPUT_DIR=""
NGINX_SNIPPETS_TARGET_HINT=""
NGINX_VHOST_TARGET_HINT=""
RUN_APPLY_DRY_RUN="0"
EXECUTE_APPLY="0"
BACKUP_DIR=""
RUN_NGINX_TEST_AFTER_EXECUTE="0"
NGINX_TEST_CMD="nginx -t"
ASSUME_YES="0"
SCRIPT_FLAGS_USED="0"

INSTALLER_PREFLIGHT_STATUS="pending"
INSTALLER_GENERATOR_STATUS="pending"
INSTALLER_APPLY_PLAN_STATUS="pending"
INSTALLER_DRY_RUN_STATUS="not-requested"
INSTALLER_EXECUTE_STATUS="not-requested"
INSTALLER_FINAL_STATUS="running"

GENERATED_DIR="$ROOT_DIR/scripts/generated"
PREFLIGHT_REPORT_MD="$GENERATED_DIR/preflight.generated.md"
PREFLIGHT_REPORT_JSON="$GENERATED_DIR/preflight.generated.json"
SUMMARY_JSON_PRIMARY="$GENERATED_DIR/INSTALLER-SUMMARY.generated.json"
SUMMARY_JSON_SECONDARY=""
CONFIG_PATH="$GENERATED_DIR/deploy.generated.yaml"
OUTPUT_DIR_ABS=""
APPLY_PLAN_PATH=""
APPLY_PLAN_JSON_PATH=""
APPLY_RESULT_PATH=""

trap installer_on_exit EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --deployment-name)
      DEPLOYMENT_NAME="$2"; SCRIPT_FLAGS_USED="1"; shift 2 ;;
    --base-domain)
      BASE_DOMAIN="$2"; SCRIPT_FLAGS_USED="1"; shift 2 ;;
    --domain-mode)
      DOMAIN_MODE="$2"; SCRIPT_FLAGS_USED="1"; shift 2 ;;
    --platform)
      PLATFORM="$2"; SCRIPT_FLAGS_USED="1"; shift 2 ;;
    --tls-cert)
      TLS_CERT="$2"; SCRIPT_FLAGS_USED="1"; shift 2 ;;
    --tls-key)
      TLS_KEY="$2"; SCRIPT_FLAGS_USED="1"; shift 2 ;;
    --input-mode)
      INPUT_MODE="$2"; SCRIPT_FLAGS_USED="1"; shift 2 ;;
    --error-root)
      ERROR_ROOT="$2"; SCRIPT_FLAGS_USED="1"; shift 2 ;;
    --log-dir)
      LOG_DIR="$2"; SCRIPT_FLAGS_USED="1"; shift 2 ;;
    --output-dir)
      OUTPUT_DIR="$2"; SCRIPT_FLAGS_USED="1"; shift 2 ;;
    --snippets-target)
      NGINX_SNIPPETS_TARGET_HINT="$2"; SCRIPT_FLAGS_USED="1"; shift 2 ;;
    --vhost-target)
      NGINX_VHOST_TARGET_HINT="$2"; SCRIPT_FLAGS_USED="1"; shift 2 ;;
    --run-apply-dry-run)
      RUN_APPLY_DRY_RUN="1"; SCRIPT_FLAGS_USED="1"; shift ;;
    --execute-apply)
      EXECUTE_APPLY="1"; SCRIPT_FLAGS_USED="1"; shift ;;
    --backup-dir)
      BACKUP_DIR="$2"; SCRIPT_FLAGS_USED="1"; shift 2 ;;
    --run-nginx-test)
      RUN_NGINX_TEST_AFTER_EXECUTE="1"; SCRIPT_FLAGS_USED="1"; shift ;;
    --nginx-test-cmd)
      NGINX_TEST_CMD="$2"; SCRIPT_FLAGS_USED="1"; shift 2 ;;
    --yes)
      ASSUME_YES="1"; SCRIPT_FLAGS_USED="1"; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      ui_error "未知参数：$1"
      usage >&2
      exit 1 ;;
  esac
done

ui_section "欢迎使用 github-mirror-template v0.3 实验性安装编排骨架"
ui_info "当前阶段已打通：交互输入 → 配置生成 → 调 generator → apply dry-run / 保守式真实 apply"
ui_info "本轮已新增输入分层：默认优先基础模式，仅在需要时进入高级路径配置。"
ui_info "本轮也已补上最小非交互参数入口：可用 flags 直接驱动 generator / dry-run / 受控 apply。"
ui_warn "默认不会直接执行真实 apply；真实 apply 仍需显式确认，且不会自动改 DNS、不会自动 reload、不做失败后自动回滚。"
if [[ "$SCRIPT_FLAGS_USED" == "1" ]]; then
  ui_info "检测到命令行参数输入，将优先使用 flags，再对缺失项回退到交互提问。"
fi

echo
prompt_or_keep DEPLOYMENT_NAME "请输入 deployment_name" "github-mirror-prod"
prompt_or_keep BASE_DOMAIN "请输入基础域名 base_domain" "github.example.com"
choose_or_keep DOMAIN_MODE "请选择域名模型" "flat-siblings" "nested"
choose_or_keep PLATFORM "请选择部署平台" "bt-panel-nginx" "plain-nginx"
prompt_path_or_keep TLS_CERT "请输入 TLS 证书路径 tls.cert" "/etc/ssl/example/fullchain.pem"
prompt_path_or_keep TLS_KEY "请输入 TLS 私钥路径 tls.key" "/etc/ssl/example/privkey.pem"

set_platform_defaults "$PLATFORM"

if [[ -n "$INPUT_MODE" ]] && ! validate_choice "$INPUT_MODE" "basic" "advanced"; then
  ui_error "input-mode 取值无效：$INPUT_MODE（仅支持 basic / advanced）"
  exit 1
fi

PATH_OVERRIDE_COUNT=0
for maybe_path in "$ERROR_ROOT" "$LOG_DIR" "$OUTPUT_DIR" "$NGINX_SNIPPETS_TARGET_HINT" "$NGINX_VHOST_TARGET_HINT"; do
  [[ -n "$maybe_path" ]] && PATH_OVERRIDE_COUNT=$((PATH_OVERRIDE_COUNT + 1))
done

if [[ -z "$INPUT_MODE" && $PATH_OVERRIDE_COUNT -gt 0 ]]; then
  INPUT_MODE="advanced"
  ui_info "检测到路径级覆盖参数，已自动切换为 advanced 模式。"
fi

if [[ -z "$INPUT_MODE" ]]; then
  if ui_confirm "是否进入高级路径配置（修改 error_root / log_dir / output_dir / nginx target hints）？" "N"; then
    INPUT_MODE="advanced"
  else
    INPUT_MODE="basic"
  fi
fi

if [[ "$INPUT_MODE" == "basic" && $PATH_OVERRIDE_COUNT -gt 0 ]]; then
  ui_warn "你传入了路径级覆盖参数，但 input-mode=basic；为避免语义冲突，已自动切换到 advanced 模式。"
  INPUT_MODE="advanced"
fi

if [[ "$PLATFORM" == "bt-panel-nginx" ]]; then
  # shellcheck disable=SC1091
  source "$ROOT_DIR/scripts/lib/platforms/bt-panel-nginx.sh"
  PLATFORM_EXPLAIN_FN="platform_explain_bt_panel_nginx"
  PLATFORM_PLAN_FN="platform_plan_bt_panel_nginx"
else
  # shellcheck disable=SC1091
  source "$ROOT_DIR/scripts/lib/platforms/plain-nginx.sh"
  PLATFORM_EXPLAIN_FN="platform_explain_plain_nginx"
  PLATFORM_PLAN_FN="platform_plan_plain_nginx"
fi

if [[ "$INPUT_MODE" == "advanced" ]]; then
  INSTALL_INPUT_MODE="advanced"
  prompt_path_or_keep ERROR_ROOT "请输入错误页目录 paths.error_root" "$DEFAULT_ERROR_ROOT"
  prompt_path_or_keep LOG_DIR "请输入日志目录 paths.log_dir" "$DEFAULT_LOG_DIR"
  prompt_path_or_keep OUTPUT_DIR "请输入输出目录 paths.output_dir" "$DEFAULT_OUTPUT_DIR"
  prompt_path_or_keep NGINX_SNIPPETS_TARGET_HINT "请输入 snippets 目标提示路径" "$DEFAULT_NGINX_SNIPPETS_TARGET_HINT"
  prompt_path_or_keep NGINX_VHOST_TARGET_HINT "请输入 vhost 目标提示路径" "$DEFAULT_NGINX_VHOST_TARGET_HINT"
else
  INSTALL_INPUT_MODE="basic"
  ERROR_ROOT="$DEFAULT_ERROR_ROOT"
  LOG_DIR="$DEFAULT_LOG_DIR"
  OUTPUT_DIR="$DEFAULT_OUTPUT_DIR"
  NGINX_SNIPPETS_TARGET_HINT="$DEFAULT_NGINX_SNIPPETS_TARGET_HINT"
  NGINX_VHOST_TARGET_HINT="$DEFAULT_NGINX_VHOST_TARGET_HINT"

  ui_section "已采用平台默认路径"
  echo "- 输入模式：基础模式"
  echo "- paths.error_root: $ERROR_ROOT"
  echo "- paths.log_dir: $LOG_DIR"
  echo "- paths.output_dir: $OUTPUT_DIR"
  echo "- nginx.snippets_target_hint: $NGINX_SNIPPETS_TARGET_HINT"
  echo "- nginx.vhost_target_hint: $NGINX_VHOST_TARGET_HINT"
fi

ui_section "平台说明"
"$PLATFORM_EXPLAIN_FN"

ui_section "配置摘要"
print_config_summary

ui_section "DNS 摘要"
dns_print_summary "$BASE_DOMAIN" "$DOMAIN_MODE"

ui_section "TLS 摘要"
tls_print_summary "$TLS_CERT" "$TLS_KEY"

if [[ "$ASSUME_YES" == "1" ]]; then
  ui_info "已使用 --yes，自动确认配置摘要并继续。"
else
  if ! ui_confirm "是否确认以上输入摘要并继续 preflight / generator？" "Y"; then
    INSTALLER_FINAL_STATUS="cancelled"
    ui_info "已在摘要确认阶段取消；请重新运行 installer 并修正输入。"
    exit 0
  fi
fi

run_basic_checks
INSTALLER_PREFLIGHT_STATUS="$(check_preflight_status)"
ui_section "基础 preflight"
print_check_report

mkdir -p "$GENERATED_DIR"
write_preflight_report_markdown "$PREFLIGHT_REPORT_MD"
write_preflight_report_json "$PREFLIGHT_REPORT_JSON"

ui_section "已写出 preflight 报告"
ui_info "$PREFLIGHT_REPORT_MD"
ui_info "$PREFLIGHT_REPORT_JSON"
ui_info "$SUMMARY_JSON_PRIMARY"

if has_blockers; then
  INSTALLER_FINAL_STATUS="blocked"
  ui_error "存在 BLOCK 项，当前停止，不继续调用 generator。请先修复后重新运行 installer。"
  exit 2
fi

write_deploy_config "$CONFIG_PATH"

ui_section "已生成配置文件"
ui_info "$CONFIG_PATH"

ui_section "开始调用 generator"
INSTALLER_GENERATOR_STATUS="running"
if "$ROOT_DIR/generate-from-config.sh" --config "$CONFIG_PATH"; then
  INSTALLER_GENERATOR_STATUS="success"
else
  rc=$?
  INSTALLER_GENERATOR_STATUS="failed"
  exit "$rc"
fi

OUTPUT_DIR_ABS="$OUTPUT_DIR"
if [[ "$OUTPUT_DIR_ABS" != /* ]]; then
  OUTPUT_DIR_ABS="$ROOT_DIR/${OUTPUT_DIR_ABS#./}"
fi
APPLY_PLAN_PATH="$OUTPUT_DIR_ABS/APPLY-PLAN.md"
APPLY_PLAN_JSON_PATH="$OUTPUT_DIR_ABS/APPLY-PLAN.json"
APPLY_RESULT_PATH="$OUTPUT_DIR_ABS/APPLY-RESULT.md"
SUMMARY_JSON_SECONDARY="$OUTPUT_DIR_ABS/INSTALLER-SUMMARY.json"
RENDERED_VALUES_PATH="$OUTPUT_DIR_ABS/RENDERED-VALUES.env"
mkdir -p "$OUTPUT_DIR_ABS"
write_apply_plan_markdown "$APPLY_PLAN_PATH" "$RENDERED_VALUES_PATH" "$CONFIG_PATH" "$OUTPUT_DIR_ABS"
build_apply_plan "$OUTPUT_DIR_ABS" "$NGINX_SNIPPETS_TARGET_HINT" "$NGINX_VHOST_TARGET_HINT" "$ERROR_ROOT"
write_apply_plan_json "$APPLY_PLAN_JSON_PATH" "plan-only" "$PLATFORM" "$OUTPUT_DIR_ABS" "$NGINX_SNIPPETS_TARGET_HINT" "$NGINX_VHOST_TARGET_HINT" "$ERROR_ROOT"
INSTALLER_APPLY_PLAN_STATUS="generated"

ui_section "Apply Plan（当前步骤仅输出计划）"
echo "- 将使用生成配置：$CONFIG_PATH"
echo "- 将读取部署输出目录：$OUTPUT_DIR"
echo "- 已写出 apply 计划文档：$APPLY_PLAN_PATH"
echo "- 已写出 apply 计划 JSON：$APPLY_PLAN_JSON_PATH"
echo "- 已写出 installer 统一摘要：$SUMMARY_JSON_SECONDARY"
echo "- 将由后续 apply 脚本处理 conf/snippets/errors 的落地"
echo "- 当前步骤不会直接改写目标目录"
echo "- 如需继续，可先执行 apply dry-run，再在显式确认后进入真实 apply"
echo "- 默认不会执行 nginx reload"
"$PLATFORM_PLAN_FN"

ui_section "后续命令参考"
APPLY_CMD=(
  "./apply-generated-package.sh"
  "--from" "$OUTPUT_DIR_ABS"
  "--platform" "$PLATFORM"
  "--snippets-target" "$NGINX_SNIPPETS_TARGET_HINT"
  "--vhost-target" "$NGINX_VHOST_TARGET_HINT"
  "--error-root" "$ERROR_ROOT"
  "--dry-run"
  "--print-plan"
)
printf '%q ' "${APPLY_CMD[@]}"
printf '\n'

if [[ "$RUN_APPLY_DRY_RUN" == "1" ]]; then
  ui_section "执行 apply dry-run 预演"
  INSTALLER_DRY_RUN_STATUS="running"
  if "${APPLY_CMD[@]}"; then
    INSTALLER_DRY_RUN_STATUS="success"
  else
    rc=$?
    INSTALLER_DRY_RUN_STATUS="failed"
    exit "$rc"
  fi
elif [[ "$ASSUME_YES" == "1" ]]; then
  INSTALLER_DRY_RUN_STATUS="skipped"
  ui_info "未指定 --run-apply-dry-run，已在非交互模式下跳过 apply dry-run。"
else
  if ui_confirm "是否立即执行一次 apply dry-run 预演？" "N"; then
    ui_section "执行 apply dry-run 预演"
    INSTALLER_DRY_RUN_STATUS="running"
    if "${APPLY_CMD[@]}"; then
      INSTALLER_DRY_RUN_STATUS="success"
    else
      rc=$?
      INSTALLER_DRY_RUN_STATUS="failed"
      exit "$rc"
    fi
  else
    INSTALLER_DRY_RUN_STATUS="skipped"
    ui_info "已跳过 apply dry-run 预演。"
  fi
fi

if [[ "$EXECUTE_APPLY" == "1" ]]; then
  if [[ -z "$BACKUP_DIR" ]]; then
    if [[ "$ASSUME_YES" == "1" ]]; then
      BACKUP_DIR="$(backup_plan_default_dir)"
      ui_info "未显式提供 --backup-dir，已在非交互模式下使用默认备份目录：$BACKUP_DIR"
    else
      BACKUP_DIR_DEFAULT="$(backup_plan_default_dir)"
      ui_prompt_path BACKUP_DIR "请输入本次 apply 的备份目录" "$BACKUP_DIR_DEFAULT"
    fi
  fi

  EXECUTE_APPLY_CMD=(
    "./apply-generated-package.sh"
    "--from" "$OUTPUT_DIR_ABS"
    "--platform" "$PLATFORM"
    "--snippets-target" "$NGINX_SNIPPETS_TARGET_HINT"
    "--vhost-target" "$NGINX_VHOST_TARGET_HINT"
    "--error-root" "$ERROR_ROOT"
    "--backup-dir" "$BACKUP_DIR"
    "--execute"
    "--result-file" "$APPLY_RESULT_PATH"
  )

  if [[ "$RUN_NGINX_TEST_AFTER_EXECUTE" == "1" ]]; then
    EXECUTE_APPLY_CMD+=("--run-nginx-test" "--nginx-test-cmd" "$NGINX_TEST_CMD")
  elif [[ "$ASSUME_YES" != "1" ]]; then
    if ui_confirm "是否在真实 apply 后立即执行 nginx -t？" "N"; then
      RUN_NGINX_TEST_AFTER_EXECUTE="1"
      ui_prompt NGINX_TEST_CMD "请输入 nginx 测试命令" "nginx -t"
      EXECUTE_APPLY_CMD+=("--run-nginx-test" "--nginx-test-cmd" "$NGINX_TEST_CMD")
    fi
  fi

  ui_print_execute_summary \
    "$OUTPUT_DIR_ABS" \
    "$PLATFORM" \
    "$NGINX_SNIPPETS_TARGET_HINT" \
    "$NGINX_VHOST_TARGET_HINT" \
    "$ERROR_ROOT" \
    "$BACKUP_DIR" \
    "$RUN_NGINX_TEST_AFTER_EXECUTE" \
    "$NGINX_TEST_CMD"

  if [[ "$ASSUME_YES" == "1" ]] || ui_confirm "是否确认执行以上真实 apply？" "N"; then
    ui_section "执行真实 apply（默认不 reload）"
    printf '%q ' "${EXECUTE_APPLY_CMD[@]}"
    printf '\n'
    INSTALLER_EXECUTE_STATUS="running"
    if "${EXECUTE_APPLY_CMD[@]}"; then
      INSTALLER_EXECUTE_STATUS="success"
    else
      rc=$?
      INSTALLER_EXECUTE_STATUS="failed"
      exit "$rc"
    fi
  else
    INSTALLER_EXECUTE_STATUS="cancelled"
    ui_info "已在最终确认阶段取消真实 apply。"
  fi
elif [[ "$ASSUME_YES" == "1" ]]; then
  INSTALLER_EXECUTE_STATUS="skipped"
  ui_info "未指定 --execute-apply，已在非交互模式下跳过真实 apply。"
else
  if ui_confirm "是否继续执行一次真实 apply（默认仍不 reload）？" "N"; then
    WILL_RUN_NGINX_TEST="0"
    NGINX_TEST_CMD="nginx -t"
    BACKUP_DIR_DEFAULT="$(backup_plan_default_dir)"
    ui_prompt_path BACKUP_DIR "请输入本次 apply 的备份目录" "$BACKUP_DIR_DEFAULT"

    EXECUTE_APPLY_CMD=(
      "./apply-generated-package.sh"
      "--from" "$OUTPUT_DIR_ABS"
      "--platform" "$PLATFORM"
      "--snippets-target" "$NGINX_SNIPPETS_TARGET_HINT"
      "--vhost-target" "$NGINX_VHOST_TARGET_HINT"
      "--error-root" "$ERROR_ROOT"
      "--backup-dir" "$BACKUP_DIR"
      "--execute"
      "--result-file" "$APPLY_RESULT_PATH"
    )

    if ui_confirm "是否在真实 apply 后立即执行 nginx -t？" "N"; then
      WILL_RUN_NGINX_TEST="1"
      ui_prompt NGINX_TEST_CMD "请输入 nginx 测试命令" "nginx -t"
      EXECUTE_APPLY_CMD+=("--run-nginx-test" "--nginx-test-cmd" "$NGINX_TEST_CMD")
    fi

    ui_print_execute_summary \
      "$OUTPUT_DIR_ABS" \
      "$PLATFORM" \
      "$NGINX_SNIPPETS_TARGET_HINT" \
      "$NGINX_VHOST_TARGET_HINT" \
      "$ERROR_ROOT" \
      "$BACKUP_DIR" \
      "$WILL_RUN_NGINX_TEST" \
      "$NGINX_TEST_CMD"

    if ui_confirm "是否确认执行以上真实 apply？" "N"; then
      ui_section "执行真实 apply（默认不 reload）"
      printf '%q ' "${EXECUTE_APPLY_CMD[@]}"
      printf '\n'
      INSTALLER_EXECUTE_STATUS="running"
      if "${EXECUTE_APPLY_CMD[@]}"; then
        INSTALLER_EXECUTE_STATUS="success"
      else
        rc=$?
        INSTALLER_EXECUTE_STATUS="failed"
        exit "$rc"
      fi
    else
      INSTALLER_EXECUTE_STATUS="cancelled"
      ui_info "已在最终确认阶段取消真实 apply。"
    fi
  else
    INSTALLER_EXECUTE_STATUS="skipped"
    ui_info "已跳过真实 apply。"
  fi
fi

INSTALLER_FINAL_STATUS="success"
ui_info "骨架阶段完成：已打通交互输入、配置生成、generator 调用，以及 apply dry-run / 保守式真实 apply 流程。"
