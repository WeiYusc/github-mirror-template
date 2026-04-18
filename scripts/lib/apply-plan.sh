#!/usr/bin/env bash
set -euo pipefail

print_copy_candidates() {
  local from_path="$1"
  local snippets_target="$2"
  local vhost_target="$3"
  local error_root="$4"

  echo "候选复制计划："

  if [[ -d "$from_path/snippets" ]]; then
    while IFS= read -r -d '' file; do
      local base
      base="$(basename "$file")"
      echo "- snippets: $file -> $snippets_target/$base"
    done < <(find "$from_path/snippets" -maxdepth 1 -type f -print0 | sort -z)
  else
    echo "- snippets: 未发现 $from_path/snippets"
  fi

  if [[ -d "$from_path/conf.d" ]]; then
    while IFS= read -r -d '' file; do
      local base
      base="$(basename "$file")"
      echo "- conf.d: $file -> $vhost_target/$base"
    done < <(find "$from_path/conf.d" -maxdepth 1 -type f -print0 | sort -z)
  else
    echo "- conf.d: 未发现 $from_path/conf.d"
  fi

  if [[ -d "$from_path/html/errors" ]]; then
    while IFS= read -r -d '' file; do
      local base
      base="$(basename "$file")"
      echo "- errors: $file -> $error_root/$base"
    done < <(find "$from_path/html/errors" -maxdepth 1 -type f -print0 | sort -z)
  else
    echo "- errors: 未发现 $from_path/html/errors"
  fi
}

validate_apply_inputs() {
  local from_path="$1"
  local snippets_target="$2"
  local vhost_target="$3"
  local error_root="$4"

  local blockers=0

  if [[ ! -d "$from_path/conf.d" ]]; then
    echo "[apply][block] 缺少部署包目录：$from_path/conf.d" >&2
    blockers=1
  fi
  if [[ ! -d "$from_path/snippets" ]]; then
    echo "[apply][block] 缺少部署包目录：$from_path/snippets" >&2
    blockers=1
  fi
  if [[ ! -d "$from_path/html/errors" ]]; then
    echo "[apply][block] 缺少部署包目录：$from_path/html/errors" >&2
    blockers=1
  fi
  if [[ ! -f "$from_path/DEPLOY-STEPS.md" ]]; then
    echo "[apply][block] 缺少部署包说明：$from_path/DEPLOY-STEPS.md" >&2
    blockers=1
  fi

  if [[ "$snippets_target" != /* ]]; then
    echo "[apply][warn] snippets 目标路径不是绝对路径：$snippets_target" >&2
  fi
  if [[ "$vhost_target" != /* ]]; then
    echo "[apply][warn] vhost 目标路径不是绝对路径：$vhost_target" >&2
  fi
  if [[ "$error_root" != /* ]]; then
    echo "[apply][warn] error_root 目标路径不是绝对路径：$error_root" >&2
  fi

  if [[ $blockers -ne 0 ]]; then
    return 1
  fi
  return 0
}

copy_tree_flat() {
  local source_dir="$1"
  local target_dir="$2"

  mkdir -p "$target_dir"
  find "$source_dir" -maxdepth 1 -type f -print0 | while IFS= read -r -d '' file; do
    cp -a "$file" "$target_dir/$(basename "$file")"
    echo "[apply] 已复制：$file -> $target_dir/$(basename "$file")"
  done
}

run_apply_copy() {
  local from_path="$1"
  local snippets_target="$2"
  local vhost_target="$3"
  local error_root="$4"

  echo "[apply] 开始执行真实复制（仍不 reload）。"
  copy_tree_flat "$from_path/snippets" "$snippets_target"
  copy_tree_flat "$from_path/conf.d" "$vhost_target"
  copy_tree_flat "$from_path/html/errors" "$error_root"
}

print_rollback_guidance() {
  local backup_dir="$1"
  local snippets_target="$2"
  local vhost_target="$3"
  local error_root="$4"

  cat <<EOF
[apply] 回滚提示：
- 本次备份目录：$backup_dir
- 如需回滚 snippets 目标，可参考：cp -a "$backup_dir/$(basename "$snippets_target")/." "$snippets_target/"
- 如需回滚 vhost 目标，可参考：cp -a "$backup_dir/$(basename "$vhost_target")/." "$vhost_target/"
- 如需回滚错误页目标，可参考：cp -a "$backup_dir/$(basename "$error_root")/." "$error_root/"
- 回滚后请重新执行 nginx -t，确认配置恢复正常
EOF
}

print_execute_summary() {
  local backup_dir="$1"
  local run_nginx_test="$2"
  local nginx_test_status="$3"

  echo "[apply] 执行摘要："
  echo "- 已完成真实备份"
  echo "- 已完成真实复制"
  echo "- 备份目录：$backup_dir"
  if [[ "$run_nginx_test" == "1" ]]; then
    if [[ "$nginx_test_status" == "0" ]]; then
      echo "- nginx 测试：通过"
      echo "- reload：未执行（默认保守）"
    else
      echo "- nginx 测试：失败"
      echo "- reload：未执行"
      echo "- 建议：先按回滚提示恢复，再重新执行 nginx -t"
    fi
  else
    echo "- nginx 测试：未执行"
    echo "- reload：未执行（默认保守）"
  fi
}
