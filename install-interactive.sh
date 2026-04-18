#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"

# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/ui.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/config.sh"
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

Current stage:
  - Collect interactive inputs
  - Generate a deploy config draft
  - Run basic preflight checks
  - Call generate-from-config.sh
  - Print an apply plan only

What it does NOT do yet:
  - It does NOT perform real apply
  - It does NOT modify live nginx configs
  - It does NOT reload nginx
  - It does NOT change DNS
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

ui_section "欢迎使用 github-mirror-template v0.3 实验性安装编排骨架"
ui_info "当前阶段只打通：交互输入 → 配置生成 → 调 generator → 输出 apply plan"
ui_warn "当前不会执行真实 apply，不会修改线上 nginx，不会 reload，不会改 DNS。"

echo
ui_prompt DEPLOYMENT_NAME "请输入 deployment_name" "github-mirror-prod"
ui_prompt BASE_DOMAIN "请输入基础域名 base_domain" "github.example.com"
ui_choose DOMAIN_MODE "请选择域名模型" "flat-siblings" "nested"
ui_choose PLATFORM "请选择部署平台" "bt-panel-nginx" "plain-nginx"
ui_prompt TLS_CERT "请输入 TLS 证书路径 tls.cert" "/etc/ssl/example/fullchain.pem"
ui_prompt TLS_KEY "请输入 TLS 私钥路径 tls.key" "/etc/ssl/example/privkey.pem"
ui_prompt ERROR_ROOT "请输入错误页目录 paths.error_root" "/www/wwwroot/github-mirror-errors"
ui_prompt LOG_DIR "请输入日志目录 paths.log_dir" "/www/wwwlogs"
ui_prompt OUTPUT_DIR "请输入输出目录 paths.output_dir" "./dist/${DEPLOYMENT_NAME}"

if [[ "$PLATFORM" == "bt-panel-nginx" ]]; then
  ui_prompt NGINX_SNIPPETS_TARGET_HINT "请输入 snippets 目标提示路径" "/www/server/nginx/snippets"
  ui_prompt NGINX_VHOST_TARGET_HINT "请输入 vhost 目标提示路径" "/www/server/panel/vhost/nginx"
  # shellcheck disable=SC1091
  source "$ROOT_DIR/scripts/lib/platforms/bt-panel-nginx.sh"
  PLATFORM_EXPLAIN_FN="platform_explain_bt_panel_nginx"
  PLATFORM_PLAN_FN="platform_plan_bt_panel_nginx"
else
  ui_prompt NGINX_SNIPPETS_TARGET_HINT "请输入 snippets 目标提示路径" "/etc/nginx/snippets"
  ui_prompt NGINX_VHOST_TARGET_HINT "请输入 vhost 目标提示路径" "/etc/nginx/conf.d"
  # shellcheck disable=SC1091
  source "$ROOT_DIR/scripts/lib/platforms/plain-nginx.sh"
  PLATFORM_EXPLAIN_FN="platform_explain_plain_nginx"
  PLATFORM_PLAN_FN="platform_plan_plain_nginx"
fi

ui_section "平台说明"
"$PLATFORM_EXPLAIN_FN"

ui_section "配置摘要"
print_config_summary

ui_section "DNS 摘要"
dns_print_summary "$BASE_DOMAIN" "$DOMAIN_MODE"

ui_section "TLS 摘要"
tls_print_summary "$TLS_CERT" "$TLS_KEY"

run_basic_checks
ui_section "基础 preflight"
print_check_report

if has_blockers; then
  ui_error "存在 BLOCK 项，当前停止，不继续调用 generator。"
  exit 2
fi

GENERATED_DIR="$ROOT_DIR/scripts/generated"
mkdir -p "$GENERATED_DIR"
CONFIG_PATH="$GENERATED_DIR/deploy.generated.yaml"
write_deploy_config "$CONFIG_PATH"

ui_section "已生成配置文件"
ui_info "$CONFIG_PATH"

ui_section "开始调用 generator"
"$ROOT_DIR/generate-from-config.sh" --config "$CONFIG_PATH"

OUTPUT_DIR_ABS="$OUTPUT_DIR"
if [[ "$OUTPUT_DIR_ABS" != /* ]]; then
  OUTPUT_DIR_ABS="$ROOT_DIR/${OUTPUT_DIR_ABS#./}"
fi
APPLY_PLAN_PATH="$OUTPUT_DIR_ABS/APPLY-PLAN.md"
RENDERED_VALUES_PATH="$OUTPUT_DIR_ABS/RENDERED-VALUES.env"
mkdir -p "$OUTPUT_DIR_ABS"
write_apply_plan_markdown "$APPLY_PLAN_PATH" "$RENDERED_VALUES_PATH" "$CONFIG_PATH" "$OUTPUT_DIR_ABS"

ui_section "Apply Plan（仅计划，不执行）"
echo "- 将使用生成配置：$CONFIG_PATH"
echo "- 将读取部署输出目录：$OUTPUT_DIR"
echo "- 已写出 apply 计划文档：$APPLY_PLAN_PATH"
echo "- 将由后续 apply 脚本处理 conf/snippets/errors 的落地"
echo "- 当前阶段不会真实写入 nginx / 宝塔目录"
echo "- 当前阶段不会执行 nginx -t / reload"
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

if ui_confirm "是否立即执行一次 apply dry-run 预演？" "N"; then
  ui_section "执行 apply dry-run 预演"
  "${APPLY_CMD[@]}"
else
  ui_info "已跳过 apply dry-run 预演。"
fi

if ui_confirm "是否继续执行一次真实 apply（默认仍不 reload）？" "N"; then
  WILL_RUN_NGINX_TEST="0"
  NGINX_TEST_CMD="nginx -t"
  BACKUP_DIR_DEFAULT="$(backup_plan_default_dir)"
  ui_prompt BACKUP_DIR "请输入本次 apply 的备份目录" "$BACKUP_DIR_DEFAULT"

  EXECUTE_APPLY_CMD=(
    "./apply-generated-package.sh"
    "--from" "$OUTPUT_DIR_ABS"
    "--platform" "$PLATFORM"
    "--snippets-target" "$NGINX_SNIPPETS_TARGET_HINT"
    "--vhost-target" "$NGINX_VHOST_TARGET_HINT"
    "--error-root" "$ERROR_ROOT"
    "--backup-dir" "$BACKUP_DIR"
    "--execute"
    "--result-file" "$OUTPUT_DIR_ABS/APPLY-RESULT.md"
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
    "${EXECUTE_APPLY_CMD[@]}"
  else
    ui_info "已在最终确认阶段取消真实 apply。"
  fi
else
  ui_info "已跳过真实 apply。"
fi

ui_info "骨架阶段完成：已打通交互输入、配置生成、generator 调用与 apply plan 输出。"
