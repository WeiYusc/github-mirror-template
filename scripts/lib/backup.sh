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

backup_existing_target() {
  local backup_dir="$1"
  local target="$2"

  if [[ ! -e "$target" ]]; then
    echo "[backup] 跳过不存在目标：$target"
    return 0
  fi

  mkdir -p "$backup_dir"
  local base
  base="$(basename "$target")"
  local dest="$backup_dir/$base"

  if [[ -d "$target" ]]; then
    cp -a "$target" "$dest"
  else
    cp -a "$target" "$dest"
  fi
  echo "[backup] 已备份：$target -> $dest"
}

run_backup_stub() {
  local backup_dir="$1"
  shift
  local targets=("$@")

  echo "[backup] 当前为骨架阶段，仅输出备份计划，不执行真实备份。"
  print_backup_plan "$backup_dir" "${targets[@]}"
}

run_backup_real() {
  local backup_dir="$1"
  shift
  local targets=("$@")

  echo "[backup] 开始执行真实备份。"
  print_backup_plan "$backup_dir" "${targets[@]}"
  for target in "${targets[@]}"; do
    backup_existing_target "$backup_dir" "$target"
  done
}
