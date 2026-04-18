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
    [--print-plan]

Current stage:
  - Dry-run / print-plan only
  - Do not modify live nginx configs
  - Do not reload nginx
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
    exit 4
    ;;
esac

cat <<EOF
[apply] 当前为骨架阶段，仅输出 apply 计划。
[apply] dist 路径：$FROM_PATH
[apply] 平台：$PLATFORM
[apply] snippets 目标提示路径：$SNIPPETS_TARGET
[apply] vhost 目标提示路径：$VHOST_TARGET
[apply] 错误页目标提示路径：$ERROR_ROOT
[apply] 备份目录（计划）：$BACKUP_DIR
[apply] 模式：$([[ "$DRY_RUN" == "1" ]] && echo 'dry-run' || echo 'plan-only')
EOF

if ! validate_apply_inputs "$FROM_PATH" "$SNIPPETS_TARGET" "$VHOST_TARGET" "$ERROR_ROOT"; then
  echo "[apply] 存在阻断项，停止继续输出 apply 计划。" >&2
  exit 5
fi

NGINX_SNIPPETS_TARGET_HINT="$SNIPPETS_TARGET"
NGINX_VHOST_TARGET_HINT="$VHOST_TARGET"
export ERROR_ROOT NGINX_SNIPPETS_TARGET_HINT NGINX_VHOST_TARGET_HINT

if [[ "$PRINT_PLAN" == "1" || "$DRY_RUN" == "1" ]]; then
  echo
  echo "[apply] 计划摘要："
fi
"$PLAN_FN" "$FROM_PATH"

echo
print_copy_candidates "$FROM_PATH" "$SNIPPETS_TARGET" "$VHOST_TARGET" "$ERROR_ROOT"

echo
run_backup_stub "$BACKUP_DIR" "$SNIPPETS_TARGET" "$VHOST_TARGET" "$ERROR_ROOT"

echo "[apply] 当前不会执行真实复制、不会覆盖线上文件、不会 reload nginx"
