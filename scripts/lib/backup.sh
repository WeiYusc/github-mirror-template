#!/usr/bin/env bash
set -euo pipefail

backup_plan_default_dir() {
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  printf './backups/%s\n' "$ts"
}

print_backup_plan() {
  local backup_dir="$1"
  shift
  local targets=("$@")

  echo "备份计划："
  echo "- 计划备份目录：$backup_dir"
  if [[ ${#targets[@]} -eq 0 ]]; then
    echo "- 当前没有传入备份目标"
    return 0
  fi

  for target in "${targets[@]}"; do
    if [[ -e "$target" ]]; then
      echo "- 将备份现有目标：$target"
    else
      echo "- 目标当前不存在，无需备份：$target"
    fi
  done
}

run_backup_stub() {
  local backup_dir="$1"
  shift
  local targets=("$@")

  echo "[backup] 当前为骨架阶段，仅输出备份计划，不执行真实备份。"
  print_backup_plan "$backup_dir" "${targets[@]}"
}
