#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./apply-generated-package.sh \
    --from <dist-path> \
    --platform <bt-panel-nginx|plain-nginx> \
    --snippets-target <path> \
    --vhost-target <path> \
    --error-root <path> \
    [--backup-dir <path>] \
    [--dry-run] \
    [--print-plan] \
    [--execute] \
    [--nginx-test-cmd <cmd>] \
    [--run-nginx-test]

Current stage:
  - Dry-run / print-plan by default
  - Real execute is available but still conservative
  - Do not reload nginx by default
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"

# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/backup.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/apply-plan.sh"

FROM_PATH=""
PLATFORM=""
SNIPPETS_TARGET=""
VHOST_TARGET=""
ERROR_ROOT=""
BACKUP_DIR=""
DRY_RUN="0"
PRINT_PLAN="0"
EXECUTE="0"
RUN_NGINX_TEST="0"
NGINX_TEST_CMD="nginx -t"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)
      FROM_PATH="$2"; shift 2 ;;
    --platform)
      PLATFORM="$2"; shift 2 ;;
    --snippets-target)
      SNIPPETS_TARGET="$2"; shift 2 ;;
    --vhost-target)
      VHOST_TARGET="$2"; shift 2 ;;
    --error-root)
      ERROR_ROOT="$2"; shift 2 ;;
    --backup-dir)
      BACKUP_DIR="$2"; shift 2 ;;
    --dry-run)
      DRY_RUN="1"; shift ;;
    --print-plan)
      PRINT_PLAN="1"; shift ;;
    --execute)
      EXECUTE="1"; shift ;;
    --nginx-test-cmd)
      NGINX_TEST_CMD="$2"; shift 2 ;;
    --run-nginx-test)
      RUN_NGINX_TEST="1"; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "[apply] Unknown argument: $1" >&2
      usage >&2
      exit 1 ;;
  esac
done

if [[ -z "$FROM_PATH" ]]; then
  echo "[apply] Missing required argument: --from <dist-path>" >&2
  exit 1
fi

if [[ ! -d "$FROM_PATH" ]]; then
  echo "[apply] Dist path not found: $FROM_PATH" >&2
  exit 2
fi

if [[ -z "$PLATFORM" || -z "$SNIPPETS_TARGET" || -z "$VHOST_TARGET" || -z "$ERROR_ROOT" ]]; then
  echo "[apply] Missing required platform target arguments." >&2
  usage >&2
  exit 3
fi

if [[ "$EXECUTE" == "1" && "$DRY_RUN" == "1" ]]; then
  echo "[apply] --execute 与 --dry-run 不能同时使用。" >&2
  exit 4
fi

if [[ -z "$BACKUP_DIR" ]]; then
  BACKUP_DIR="$(backup_plan_default_dir)"
fi

case "$PLATFORM" in
  bt-panel-nginx)
    # shellcheck disable=SC1091
    source "$ROOT_DIR/scripts/lib/platforms/bt-panel-nginx.sh"
    PLAN_FN="platform_apply_plan_bt_panel_nginx"
    ;;
  plain-nginx)
    # shellcheck disable=SC1091
    source "$ROOT_DIR/scripts/lib/platforms/plain-nginx.sh"
    PLAN_FN="platform_apply_plan_plain_nginx"
    ;;
  *)
    echo "[apply] Unsupported platform: $PLATFORM" >&2
    exit 5
    ;;
esac

MODE="plan-only"
if [[ "$DRY_RUN" == "1" ]]; then
  MODE="dry-run"
elif [[ "$EXECUTE" == "1" ]]; then
  MODE="execute"
fi

cat <<EOF
[apply] 当前 apply 模式：$MODE
[apply] dist 路径：$FROM_PATH
[apply] 平台：$PLATFORM
[apply] snippets 目标路径：$SNIPPETS_TARGET
[apply] vhost 目标路径：$VHOST_TARGET
[apply] 错误页目标路径：$ERROR_ROOT
[apply] 备份目录：$BACKUP_DIR
[apply] nginx 测试命令：$NGINX_TEST_CMD
EOF

if ! validate_apply_inputs "$FROM_PATH" "$SNIPPETS_TARGET" "$VHOST_TARGET" "$ERROR_ROOT"; then
  echo "[apply] 存在阻断项，停止继续。" >&2
  exit 6
fi

NGINX_SNIPPETS_TARGET_HINT="$SNIPPETS_TARGET"
NGINX_VHOST_TARGET_HINT="$VHOST_TARGET"
export ERROR_ROOT NGINX_SNIPPETS_TARGET_HINT NGINX_VHOST_TARGET_HINT

if [[ "$PRINT_PLAN" == "1" || "$DRY_RUN" == "1" || "$EXECUTE" == "1" ]]; then
  echo
  echo "[apply] 计划摘要："
fi
"$PLAN_FN" "$FROM_PATH"

echo
print_copy_candidates "$FROM_PATH" "$SNIPPETS_TARGET" "$VHOST_TARGET" "$ERROR_ROOT"

echo
if [[ "$EXECUTE" == "1" ]]; then
  local_nginx_test_status="not-run"
  run_backup_real "$BACKUP_DIR" "$SNIPPETS_TARGET" "$VHOST_TARGET" "$ERROR_ROOT"
  echo
  run_apply_copy "$FROM_PATH" "$SNIPPETS_TARGET" "$VHOST_TARGET" "$ERROR_ROOT"
  if [[ "$RUN_NGINX_TEST" == "1" ]]; then
    echo
    echo "[apply] 开始执行 nginx 测试命令：$NGINX_TEST_CMD"
    if bash -lc "$NGINX_TEST_CMD"; then
      local_nginx_test_status="0"
      echo "[apply] nginx 测试通过。"
    else
      local_nginx_test_status="1"
      echo "[apply][warn] nginx 测试失败；当前未自动 reload，也未自动回滚。" >&2
      echo
      print_rollback_guidance "$BACKUP_DIR" "$SNIPPETS_TARGET" "$VHOST_TARGET" "$ERROR_ROOT"
    fi
  fi
  echo
  print_execute_summary "$BACKUP_DIR" "$RUN_NGINX_TEST" "$local_nginx_test_status"
else
  run_backup_stub "$BACKUP_DIR" "$SNIPPETS_TARGET" "$VHOST_TARGET" "$ERROR_ROOT"
  echo "[apply] 当前不会执行真实复制、不会覆盖线上文件、不会 reload nginx"
fi
