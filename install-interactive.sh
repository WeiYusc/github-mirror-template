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
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/status-contracts.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/state.sh"

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
  --resume <run_id>
  --doctor <run_id>
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

Recovery helpers (first iteration):
  - --resume <run_id> : reload a previous run's captured inputs and re-enter from a safe boundary; when lineage/recovery indicates inspection-first (including inspect-after-apply-attention / repair-review-first / post-repair-verification / post-rollback-inspection), resume defaults to review-first continuation instead of real apply replay
  - --doctor <run_id> : inspect one run's state/journal/artifacts and print next-step hints
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

require_nonempty_arg() {
  local value="$1"
  local flag_name="$2"
  if [[ -z "$value" ]]; then
    ui_error "缺少必填参数：$flag_name"
    exit 2
  fi
}

validate_noninteractive_requirements() {
  local mode="$1"
  if [[ "$mode" == "resume" || -n "${DOCTOR_RUN_ID:-}" ]]; then
    return 0
  fi

  if [[ ! -t 0 && "${ASSUME_YES:-0}" != "1" ]]; then
    ui_error "检测到非交互输入（stdin 非 TTY）；新 run 必须显式提供 --yes，避免在无输入情况下默认继续。"
    exit 2
  fi

  if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    require_nonempty_arg "${DEPLOYMENT_NAME:-}" "--deployment-name"
    require_nonempty_arg "${BASE_DOMAIN:-}" "--base-domain"
    require_nonempty_arg "${DOMAIN_MODE:-}" "--domain-mode"
    require_nonempty_arg "${PLATFORM:-}" "--platform"
    require_nonempty_arg "${TLS_CERT:-}" "--tls-cert"
    require_nonempty_arg "${TLS_KEY:-}" "--tls-key"
    require_nonempty_arg "${INPUT_MODE:-}" "--input-mode"
  fi
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

resume_strategy_allows_execute() {
  case "${1:-}" in
    post-rollback-inspection|post-repair-verification|repair-review-first|inspect-after-apply-attention)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

installer_prepare_backup_dir() {
  if [[ -n "${BACKUP_DIR:-}" ]]; then
    return 0
  fi

  if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    BACKUP_DIR="$(backup_plan_default_dir)"
    ui_info "未显式提供 --backup-dir，已在非交互模式下使用默认备份目录：$BACKUP_DIR"
  else
    local backup_dir_default
    backup_dir_default="$(backup_plan_default_dir)"
    ui_prompt_path BACKUP_DIR "请输入本次 apply 的备份目录" "$backup_dir_default"
  fi
}

installer_build_apply_dry_run_cmd() {
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
}

installer_build_apply_execute_cmd() {
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

  if [[ "${RUN_NGINX_TEST_AFTER_EXECUTE:-0}" == "1" ]]; then
    EXECUTE_APPLY_CMD+=("--run-nginx-test" "--nginx-test-cmd" "$NGINX_TEST_CMD")
  fi
}

installer_prompt_execute_nginx_test_option() {
  local default_cmd="${1:-nginx -t}"
  local prompt_text="${2:-是否在真实 apply 后立即执行 nginx -t？}"

  if ui_confirm "$prompt_text" "N"; then
    RUN_NGINX_TEST_AFTER_EXECUTE="1"
    ui_prompt NGINX_TEST_CMD "请输入 nginx 测试命令" "$default_cmd"
  else
    RUN_NGINX_TEST_AFTER_EXECUTE="0"
    NGINX_TEST_CMD="$default_cmd"
  fi
}

installer_confirm_and_run_execute_apply() {
  if ui_confirm "是否确认执行以上真实 apply？" "N"; then
    ui_section "执行真实 apply（默认不 reload）"
    printf '%q ' "${EXECUTE_APPLY_CMD[@]}"
    printf '\n'
    if ! installer_run_apply_execute "$APPLY_RESULT_JSON_PATH" "${EXECUTE_APPLY_CMD[@]}"; then
      rc=$?
      exit "$rc"
    fi
  else
    INSTALLER_EXECUTE_STATUS="cancelled"
    ui_info "已在最终确认阶段取消真实 apply。"
  fi
}

installer_load_platform_helpers() {
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
}

installer_prepare_output_artifact_paths() {
  if [[ -z "$OUTPUT_DIR_ABS" ]]; then
    OUTPUT_DIR_ABS="$OUTPUT_DIR"
    if [[ "$OUTPUT_DIR_ABS" != /* ]]; then
      OUTPUT_DIR_ABS="$ROOT_DIR/${OUTPUT_DIR_ABS#./}"
    fi
  fi

  APPLY_PLAN_PATH="$OUTPUT_DIR_ABS/APPLY-PLAN.md"
  APPLY_PLAN_JSON_PATH="$OUTPUT_DIR_ABS/APPLY-PLAN.json"
  APPLY_RESULT_PATH="$OUTPUT_DIR_ABS/APPLY-RESULT.md"
  APPLY_RESULT_JSON_PATH="$OUTPUT_DIR_ABS/APPLY-RESULT.json"
  SUMMARY_JSON_SECONDARY="$OUTPUT_DIR_ABS/INSTALLER-SUMMARY.json"
  RENDERED_VALUES_PATH="$OUTPUT_DIR_ABS/RENDERED-VALUES.env"
}

installer_run_or_reuse_preflight() {
  if [[ "$SHOULD_SKIP_PREFLIGHT" == "1" ]]; then
    INSTALLER_PREFLIGHT_STATUS="$RESUME_SOURCE_PREFLIGHT_STATUS"
    if [[ -n "$RESUME_SOURCE_PREFLIGHT_REPORT_MD" ]]; then
      PREFLIGHT_REPORT_MD="$RESUME_SOURCE_PREFLIGHT_REPORT_MD"
    fi
    if [[ -n "$RESUME_SOURCE_PREFLIGHT_REPORT_JSON" ]]; then
      PREFLIGHT_REPORT_JSON="$RESUME_SOURCE_PREFLIGHT_REPORT_JSON"
    fi
    if [[ -n "$RESUME_SOURCE_CONFIG_PATH" ]]; then
      CONFIG_PATH="$RESUME_SOURCE_CONFIG_PATH"
    fi
    state_mark_checkpoint "preflight-reused" "resume reused preflight artifacts"
    state_append_journal "preflight.reused" "ok" "resume reused preflight artifacts" "$PREFLIGHT_REPORT_JSON"
    ui_section "基础 preflight"
    ui_info "已复用历史 preflight 结果，跳过重新检查。"
    ui_info "$PREFLIGHT_REPORT_MD"
    ui_info "$PREFLIGHT_REPORT_JSON"
    ui_info "$SUMMARY_JSON_PRIMARY"
    return 0
  fi

  run_basic_checks
  INSTALLER_PREFLIGHT_STATUS="$(check_preflight_status)"
  state_mark_checkpoint "preflight-complete" "preflight status=$INSTALLER_PREFLIGHT_STATUS"
  ui_section "基础 preflight"
  print_check_report

  mkdir -p "$GENERATED_DIR"
  write_preflight_report_markdown "$PREFLIGHT_REPORT_MD"
  write_preflight_report_json "$PREFLIGHT_REPORT_JSON"
  state_append_journal "preflight.complete" "$INSTALLER_PREFLIGHT_STATUS" "preflight finished" "$PREFLIGHT_REPORT_JSON"

  ui_section "已写出 preflight 报告"
  ui_info "$PREFLIGHT_REPORT_MD"
  ui_info "$PREFLIGHT_REPORT_JSON"
  ui_info "$SUMMARY_JSON_PRIMARY"
}

installer_run_or_reuse_generator() {
  if [[ "$SHOULD_SKIP_GENERATOR" == "1" ]]; then
    INSTALLER_GENERATOR_STATUS="success"
    if [[ -n "$RESUME_SOURCE_OUTPUT_DIR_ABS" ]]; then
      OUTPUT_DIR_ABS="$RESUME_SOURCE_OUTPUT_DIR_ABS"
    fi
    state_mark_checkpoint "generator-reused" "resume reused generated output"
    state_append_journal "generator.reused" "success" "resume reused previous generator output" "$OUTPUT_DIR_ABS"
    ui_section "开始调用 generator"
    ui_info "已复用历史 generator 输出，跳过重新调用 generate-from-config.sh。"
    return 0
  fi

  write_deploy_config "$CONFIG_PATH"
  state_mark_checkpoint "config-written" "deploy config written"
  state_append_journal "config.written" "ok" "deploy config generated" "$CONFIG_PATH"

  ui_section "已生成配置文件"
  ui_info "$CONFIG_PATH"

  ui_section "开始调用 generator"
  INSTALLER_GENERATOR_STATUS="running"
  state_mark_checkpoint "generator-running" "calling generate-from-config.sh"
  state_append_journal "generator.start" "running" "calling generator" "$CONFIG_PATH"
  if "$ROOT_DIR/generate-from-config.sh" --config "$CONFIG_PATH"; then
    INSTALLER_GENERATOR_STATUS="success"
    state_mark_checkpoint "generator-success" "generator completed"
  else
    local rc=$?
    INSTALLER_GENERATOR_STATUS="failed"
    return "$rc"
  fi
}

installer_run_or_reuse_apply_plan() {
  installer_prepare_output_artifact_paths

  if [[ "$SHOULD_SKIP_APPLY_PLAN" == "1" ]]; then
    INSTALLER_APPLY_PLAN_STATUS="generated"
    if [[ -n "$RESUME_SOURCE_APPLY_PLAN_PATH" ]]; then
      APPLY_PLAN_PATH="$RESUME_SOURCE_APPLY_PLAN_PATH"
    fi
    if [[ -n "$RESUME_SOURCE_APPLY_PLAN_JSON_PATH" ]]; then
      APPLY_PLAN_JSON_PATH="$RESUME_SOURCE_APPLY_PLAN_JSON_PATH"
    fi
    if [[ -n "$RESUME_SOURCE_APPLY_RESULT_PATH" ]]; then
      APPLY_RESULT_PATH="$RESUME_SOURCE_APPLY_RESULT_PATH"
    fi
    if [[ -n "$RESUME_SOURCE_APPLY_RESULT_JSON_PATH" ]]; then
      APPLY_RESULT_JSON_PATH="$RESUME_SOURCE_APPLY_RESULT_JSON_PATH"
    fi
    if [[ -n "$RESUME_SOURCE_SUMMARY_JSON_SECONDARY" ]]; then
      SUMMARY_JSON_SECONDARY="$RESUME_SOURCE_SUMMARY_JSON_SECONDARY"
    fi
    state_mark_checkpoint "apply-plan-reused" "resume reused apply plan artifacts"
    state_append_journal "apply-plan.reused" "generated" "resume reused apply plan artifacts" "$APPLY_PLAN_JSON_PATH"
    return 0
  fi

  mkdir -p "$OUTPUT_DIR_ABS"
  write_apply_plan_markdown "$APPLY_PLAN_PATH" "$RENDERED_VALUES_PATH" "$CONFIG_PATH" "$OUTPUT_DIR_ABS"
  build_apply_plan "$OUTPUT_DIR_ABS" "$NGINX_SNIPPETS_TARGET_HINT" "$NGINX_VHOST_TARGET_HINT" "$ERROR_ROOT"
  write_apply_plan_json "$APPLY_PLAN_JSON_PATH" "plan-only" "$PLATFORM" "$OUTPUT_DIR_ABS" "$NGINX_SNIPPETS_TARGET_HINT" "$NGINX_VHOST_TARGET_HINT" "$ERROR_ROOT"
  INSTALLER_APPLY_PLAN_STATUS="generated"
  state_mark_checkpoint "apply-plan-generated" "apply plan artifacts ready"
  state_append_journal "apply-plan.complete" "generated" "apply plan generated" "$APPLY_PLAN_JSON_PATH"
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
RESUME_RUN_ID=""
DOCTOR_RUN_ID=""
INSTALLER_MODE="new"
INSTALLER_CHECKPOINT="initialized"
RESUME_STRATEGY="fresh"
RESUME_STRATEGY_REASON="new-run"
RESUME_SOURCE_RUN_ID=""
RESUME_SOURCE_CHECKPOINT=""
RESUME_SOURCE_PREFLIGHT_STATUS=""
RESUME_SOURCE_GENERATOR_STATUS=""
RESUME_SOURCE_APPLY_PLAN_STATUS=""
RESUME_SOURCE_DRY_RUN_STATUS=""
RESUME_SOURCE_EXECUTE_STATUS=""
RESUME_SOURCE_FINAL_STATUS=""
RESUME_SOURCE_CONFIG_PATH=""
RESUME_SOURCE_OUTPUT_DIR_ABS=""
RESUME_SOURCE_PREFLIGHT_REPORT_MD=""
RESUME_SOURCE_PREFLIGHT_REPORT_JSON=""
RESUME_SOURCE_APPLY_PLAN_PATH=""
RESUME_SOURCE_APPLY_PLAN_JSON_PATH=""
RESUME_SOURCE_APPLY_RESULT_PATH=""
RESUME_SOURCE_APPLY_RESULT_JSON_PATH=""
RESUME_SOURCE_REPAIR_RESULT_PATH=""
RESUME_SOURCE_REPAIR_RESULT_JSON_PATH=""
RESUME_SOURCE_ROLLBACK_RESULT_PATH=""
RESUME_SOURCE_ROLLBACK_RESULT_JSON_PATH=""
RESUME_SOURCE_APPLY_RECOVERY_STATUS=""
RESUME_SOURCE_APPLY_RESUME_STRATEGY=""
RESUME_SOURCE_APPLY_RESUME_RECOMMENDED="1"
RESUME_SOURCE_APPLY_OPERATOR_ACTION=""
RESUME_SOURCE_APPLY_NEXT_STEP=""
RESUME_SOURCE_REPAIR_STATUS=""
RESUME_SOURCE_REPAIR_FINAL_STATUS=""
RESUME_SOURCE_REPAIR_MODE=""
RESUME_SOURCE_REPAIR_NGINX_TEST_RERUN_STATUS=""
RESUME_SOURCE_REPAIR_NEXT_STEP=""
RESUME_SOURCE_ROLLBACK_STATUS=""
RESUME_SOURCE_ROLLBACK_FINAL_STATUS=""
RESUME_SOURCE_ROLLBACK_MODE=""
RESUME_SOURCE_ROLLBACK_EXECUTE="0"
RESUME_SOURCE_ROLLBACK_NEXT_STEP=""
RESUME_SOURCE_SUMMARY_JSON_PRIMARY=""
RESUME_SOURCE_SUMMARY_JSON_SECONDARY=""
RESUME_SOURCE_INPUTS_ENV=""
RESUME_SOURCE_JOURNAL_JSONL=""
SHOULD_SKIP_INPUTS="0"
SHOULD_SKIP_PREFLIGHT="0"
SHOULD_SKIP_GENERATOR="0"
SHOULD_SKIP_APPLY_PLAN="0"
INSTALLER_REPAIR_STATUS=""
INSTALLER_ROLLBACK_STATUS=""

INSTALLER_PREFLIGHT_STATUS="pending"
INSTALLER_GENERATOR_STATUS="pending"
INSTALLER_APPLY_PLAN_STATUS="pending"
INSTALLER_DRY_RUN_STATUS="not-requested"
INSTALLER_EXECUTE_STATUS="not-requested"
INSTALLER_FINAL_STATUS="running"
INSTALLER_RUNTIME_READY="0"
INSTALLER_FINALIZED="0"

GENERATED_DIR="$ROOT_DIR/scripts/generated"
RUNS_ROOT_DIR="$GENERATED_DIR/runs"
RUN_ID=""
STATE_DIR=""
STATE_JSON_PATH=""
STATE_JOURNAL_PATH=""
STATE_INPUTS_PATH=""
PREFLIGHT_REPORT_MD="$GENERATED_DIR/preflight.generated.md"
PREFLIGHT_REPORT_JSON="$GENERATED_DIR/preflight.generated.json"
SUMMARY_JSON_PRIMARY="$GENERATED_DIR/INSTALLER-SUMMARY.generated.json"
SUMMARY_JSON_SECONDARY=""
CONFIG_PATH="$GENERATED_DIR/deploy.generated.yaml"
OUTPUT_DIR_ABS=""
APPLY_PLAN_PATH=""
APPLY_PLAN_JSON_PATH=""
APPLY_RESULT_PATH=""
APPLY_RESULT_JSON_PATH=""
CLI_REQUEST_RUN_APPLY_DRY_RUN="0"
CLI_REQUEST_EXECUTE_APPLY="0"
CLI_REQUEST_RUN_NGINX_TEST="0"

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
    --resume)
      RESUME_RUN_ID="$2"; SCRIPT_FLAGS_USED="1"; shift 2 ;;
    --doctor)
      DOCTOR_RUN_ID="$2"; SCRIPT_FLAGS_USED="1"; shift 2 ;;
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

CLI_REQUEST_RUN_APPLY_DRY_RUN="$RUN_APPLY_DRY_RUN"
CLI_REQUEST_EXECUTE_APPLY="$EXECUTE_APPLY"
CLI_REQUEST_RUN_NGINX_TEST="$RUN_NGINX_TEST_AFTER_EXECUTE"

if [[ -n "$DOCTOR_RUN_ID" && -n "$RESUME_RUN_ID" ]]; then
  ui_error "--doctor 与 --resume 不能同时使用"
  exit 1
fi

if [[ -n "$DOCTOR_RUN_ID" ]]; then
  INSTALLER_MODE="doctor"
elif [[ -n "$RESUME_RUN_ID" ]]; then
  INSTALLER_MODE="resume"
fi

validate_noninteractive_requirements "$INSTALLER_MODE"

mkdir -p "$GENERATED_DIR" "$RUNS_ROOT_DIR"

if [[ -n "$DOCTOR_RUN_ID" ]]; then
  state_doctor "$DOCTOR_RUN_ID"
  exit 0
fi

if [[ -n "$RESUME_RUN_ID" ]]; then
  state_load_inputs_env "$RESUME_RUN_ID"
  state_load_resume_context "$RESUME_RUN_ID"
  ui_info "已读取历史运行输入：$RESUME_RUN_ID"

  RUN_APPLY_DRY_RUN="$CLI_REQUEST_RUN_APPLY_DRY_RUN"
  EXECUTE_APPLY="$CLI_REQUEST_EXECUTE_APPLY"
  RUN_NGINX_TEST_AFTER_EXECUTE="$CLI_REQUEST_RUN_NGINX_TEST"

  state_plan_resume_runtime

  if [[ "$RESUME_SOURCE_ROLLBACK_MODE" == "execute" && "$RESUME_SOURCE_ROLLBACK_FINAL_STATUS" == "ok" ]]; then
    EXECUTE_APPLY="0"
    RUN_NGINX_TEST_AFTER_EXECUTE="0"
  elif [[ "$RESUME_SOURCE_REPAIR_NGINX_TEST_RERUN_STATUS" == "passed" ]]; then
    EXECUTE_APPLY="0"
    RUN_NGINX_TEST_AFTER_EXECUTE="0"
  fi

  if ! resume_strategy_allows_execute "$RESUME_STRATEGY"; then
    if [[ "$CLI_REQUEST_EXECUTE_APPLY" == "1" ]]; then
      ui_error "当前 resume 策略 $RESUME_STRATEGY 不允许直接执行真实 apply；这类 inspection-first 续接（包括 inspect-after-apply-attention / repair-review-first / post-repair-verification / post-rollback-inspection）必须先按 doctor / repair / rollback 结论完成复查。"
      exit 2
    fi
    EXECUTE_APPLY="0"
    RUN_NGINX_TEST_AFTER_EXECUTE="0"
  fi

  state_init_run "$RUNS_ROOT_DIR"
  ASSUME_YES="1"
else
  state_init_run "$RUNS_ROOT_DIR"
fi

state_prepare_run "$INSTALLER_MODE"
INSTALLER_RUNTIME_READY="1"
export RUNS_ROOT_DIR RUN_ID STATE_DIR STATE_JSON_PATH STATE_JOURNAL_PATH STATE_INPUTS_PATH
export INSTALLER_MODE INSTALLER_CHECKPOINT RESUME_RUN_ID RESUME_STRATEGY RESUME_STRATEGY_REASON

ui_section "欢迎使用 github-mirror-template v0.3/v0.4 实验性安装编排骨架"
ui_info "当前运行 ID：$RUN_ID"
ui_info "运行状态目录：$STATE_DIR"
if [[ "$INSTALLER_MODE" == "resume" ]]; then
  if resume_strategy_prefers_review_boundary "$RESUME_STRATEGY"; then
    ui_info "当前以 resume 模式启动：这轮属于 inspection-first 续接；会优先复查可复用产物，不把继续真实 apply 当默认动作。"
  else
    ui_info "当前以 resume 模式启动：将复用历史输入并尽量跳过已完成阶段。"
  fi
  ui_info "本次 resume 策略：$RESUME_STRATEGY（源运行：${RESUME_SOURCE_RUN_ID:-$RESUME_RUN_ID}，源 checkpoint：${RESUME_SOURCE_CHECKPOINT:-unknown}）"
  ui_info "策略原因：$RESUME_STRATEGY_REASON"
  if [[ "$RESUME_SOURCE_ROLLBACK_MODE" == "execute" && "$RESUME_SOURCE_ROLLBACK_FINAL_STATUS" == "ok" ]]; then
    ui_warn "源运行已执行 selective rollback；当前默认只做复查/续接，不会继承真实 apply 意图。"
    if [[ -n "$RESUME_SOURCE_ROLLBACK_NEXT_STEP" ]]; then
      ui_warn "rollback 建议：$RESUME_SOURCE_ROLLBACK_NEXT_STEP"
    fi
  elif [[ "$RESUME_SOURCE_REPAIR_NGINX_TEST_RERUN_STATUS" == "passed" ]]; then
    ui_warn "源运行已存在 repair 结果，且 nginx -t 重跑通过；当前默认先复查，不直接重放 apply。"
    if [[ -n "$RESUME_SOURCE_REPAIR_NEXT_STEP" ]]; then
      ui_warn "repair 建议：$RESUME_SOURCE_REPAIR_NEXT_STEP"
    fi
  elif [[ "$RESUME_SOURCE_REPAIR_FINAL_STATUS" == "needs-attention" || "$RESUME_SOURCE_REPAIR_FINAL_STATUS" == "blocked" ]]; then
    ui_warn "源运行已存在 repair 结果；当前应先按 repair 结论处理，再决定是否继续。"
    if [[ -n "$RESUME_SOURCE_REPAIR_NEXT_STEP" ]]; then
      ui_warn "repair 建议：$RESUME_SOURCE_REPAIR_NEXT_STEP"
    fi
  elif [[ "$RESUME_SOURCE_APPLY_RESUME_RECOMMENDED" != "1" ]]; then
    ui_warn "源运行的 apply 结果标记为需人工处理；当前会进入 inspect-after-apply-attention / review-first 续接，默认不会继承上次的真实 apply / nginx test 执行意图。"
    if [[ -n "$RESUME_SOURCE_APPLY_NEXT_STEP" ]]; then
      ui_warn "源运行建议：$RESUME_SOURCE_APPLY_NEXT_STEP"
    fi
  fi
fi
ui_info "当前阶段已打通：交互输入 → 配置生成 → 调 generator → apply dry-run / 保守式真实 apply"
ui_info "本轮已新增输入分层：默认优先基础模式，仅在需要时进入高级路径配置。"
ui_info "本轮也已补上最小非交互参数入口：可用 flags 直接驱动 generator / dry-run / 受控 apply。"
ui_warn "默认不会直接执行真实 apply；真实 apply 仍需显式确认，且不会自动改 DNS、不会自动 reload、不做失败后自动回滚。"
if [[ "$SCRIPT_FLAGS_USED" == "1" ]]; then
  ui_info "检测到命令行参数输入，将优先使用 flags，再对缺失项回退到交互提问。"
fi

echo
if [[ "$SHOULD_SKIP_INPUTS" == "1" ]]; then
  state_mark_checkpoint "inputs-reused" "resume reuse previous inputs"
  state_append_journal "inputs.reused" "ok" "resume reused previous inputs" "$STATE_INPUTS_PATH"
  ui_section "恢复输入摘要"
  ui_info "已复用历史输入与已生成配置，跳过交互输入阶段。"
  print_config_summary
else
  state_mark_checkpoint "collect-inputs" "enter-input-collection"
  state_append_journal "inputs.start" "running" "collecting installer inputs" "$STATE_INPUTS_PATH"
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
  state_mark_checkpoint "inputs-confirmed" "input summary ready"
  state_append_journal "inputs.confirmed" "ok" "input summary ready" "$STATE_INPUTS_PATH"

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
fi

installer_load_platform_helpers

installer_run_or_reuse_preflight

if has_blockers; then
  INSTALLER_FINAL_STATUS="blocked"
  ui_error "存在 BLOCK 项，当前停止，不继续调用 generator。请先修复后重新运行 installer。"
  exit 2
fi

if ! installer_run_or_reuse_generator; then
  rc=$?
  exit "$rc"
fi

installer_run_or_reuse_apply_plan

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
installer_build_apply_dry_run_cmd
printf '%q ' "${APPLY_CMD[@]}"
printf '\n'

if [[ "$RUN_APPLY_DRY_RUN" == "1" ]]; then
  ui_section "执行 apply dry-run 预演"
  if ! installer_run_apply_dry_run "$APPLY_PLAN_JSON_PATH" "${APPLY_CMD[@]}"; then
    rc=$?
    exit "$rc"
  fi
elif [[ "$ASSUME_YES" == "1" ]]; then
  INSTALLER_DRY_RUN_STATUS="skipped"
  ui_info "未指定 --run-apply-dry-run，已在非交互模式下跳过 apply dry-run。"
else
  if ui_confirm "是否立即执行一次 apply dry-run 预演？" "N"; then
    ui_section "执行 apply dry-run 预演"
    if ! installer_run_apply_dry_run "$APPLY_PLAN_JSON_PATH" "${APPLY_CMD[@]}"; then
      rc=$?
      exit "$rc"
    fi
  else
    INSTALLER_DRY_RUN_STATUS="skipped"
    ui_info "已跳过 apply dry-run 预演。"
  fi
fi

if [[ "$EXECUTE_APPLY" == "1" ]]; then
  installer_prepare_backup_dir

  if [[ "$RUN_NGINX_TEST_AFTER_EXECUTE" != "1" && "$ASSUME_YES" != "1" ]]; then
    installer_prompt_execute_nginx_test_option "nginx -t" "是否在真实 apply 后立即执行 nginx -t？"
  fi

  installer_build_apply_execute_cmd

  ui_print_execute_summary \
    "$OUTPUT_DIR_ABS" \
    "$PLATFORM" \
    "$NGINX_SNIPPETS_TARGET_HINT" \
    "$NGINX_VHOST_TARGET_HINT" \
    "$ERROR_ROOT" \
    "$BACKUP_DIR" \
    "$RUN_NGINX_TEST_AFTER_EXECUTE" \
    "$NGINX_TEST_CMD"

  if [[ "$ASSUME_YES" == "1" ]]; then
    ui_section "执行真实 apply（默认不 reload）"
    printf '%q ' "${EXECUTE_APPLY_CMD[@]}"
    printf '\n'
    if ! installer_run_apply_execute "$APPLY_RESULT_JSON_PATH" "${EXECUTE_APPLY_CMD[@]}"; then
      rc=$?
      exit "$rc"
    fi
  else
    installer_confirm_and_run_execute_apply
  fi
elif [[ "$ASSUME_YES" == "1" ]]; then
  INSTALLER_EXECUTE_STATUS="skipped"
  ui_info "未指定 --execute-apply，已在非交互模式下跳过真实 apply。"
else
  if ui_confirm "是否继续执行一次真实 apply（默认仍不 reload）？" "N"; then
    RUN_NGINX_TEST_AFTER_EXECUTE="0"
    NGINX_TEST_CMD="nginx -t"
    installer_prepare_backup_dir
    installer_prompt_execute_nginx_test_option "nginx -t" "是否在真实 apply 后立即执行 nginx -t？"
    installer_build_apply_execute_cmd

    ui_print_execute_summary \
      "$OUTPUT_DIR_ABS" \
      "$PLATFORM" \
      "$NGINX_SNIPPETS_TARGET_HINT" \
      "$NGINX_VHOST_TARGET_HINT" \
      "$ERROR_ROOT" \
      "$BACKUP_DIR" \
      "$RUN_NGINX_TEST_AFTER_EXECUTE" \
      "$NGINX_TEST_CMD"

    installer_confirm_and_run_execute_apply
  else
    INSTALLER_EXECUTE_STATUS="skipped"
    ui_info "已跳过真实 apply。"
  fi
fi

installer_finalize_completed_run
ui_info "骨架阶段完成：已打通交互输入、配置生成、generator 调用，以及 apply dry-run / 保守式真实 apply 流程。"
