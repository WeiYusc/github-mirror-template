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
      echo "- 将检查目标：$target"
    else
      echo "- 目标当前不存在，无需目录级预检查：$target"
    fi
  done
}

backup_existing_file_to_rooted_path() {
  local backup_dir="$1"
  local target_file="$2"

  if [[ ! -e "$target_file" ]]; then
    echo "[backup] 跳过不存在文件：$target_file"
    return 0
  fi

  local rooted="${target_file#/}"
  local dest="$backup_dir/files/$rooted"
  mkdir -p "$(dirname "$dest")"
  cp -a "$target_file" "$dest"
  echo "[backup] 已备份文件：$target_file -> $dest"
}

run_backup_stub() {
  local backup_dir="$1"
  shift
  local targets=("$@")

  echo "[backup] 当前为非执行模式，仅输出备份计划，不执行真实备份。"
  print_backup_plan "$backup_dir" "${targets[@]}"
  if declare -p APPLY_PLAN_ROWS >/dev/null 2>&1; then
    local row category source dest status note
    for row in "${APPLY_PLAN_ROWS[@]}"; do
      IFS=$'\t' read -r category source dest status note <<< "$row"
      case "$status" in
        REPLACE)
          echo "[backup] [plan] 将做文件级备份：$dest"
          ;;
      esac
    done
  fi
}

run_backup_real() {
  local backup_dir="$1"
  shift
  local targets=("$@")

  echo "[backup] 开始执行真实备份。"
  print_backup_plan "$backup_dir" "${targets[@]}"
  mkdir -p "$backup_dir"

  if ! declare -p APPLY_PLAN_ROWS >/dev/null 2>&1; then
    echo "[backup][warn] 未检测到 APPLY_PLAN_ROWS，跳过文件级备份。" >&2
    return 0
  fi

  local row category source dest status note
  local backed_up_any="0"
  for row in "${APPLY_PLAN_ROWS[@]}"; do
    IFS=$'\t' read -r category source dest status note <<< "$row"
    case "$status" in
      REPLACE)
        backup_existing_file_to_rooted_path "$backup_dir" "$dest"
        backed_up_any="1"
        ;;
    esac
  done

  if [[ "$backed_up_any" != "1" ]]; then
    echo "[backup] 当前没有 REPLACE 类文件；已创建备份目录，但无需实际备份文件。"
  fi
}
