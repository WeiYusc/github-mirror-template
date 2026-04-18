#!/usr/bin/env bash
set -euo pipefail

ui_info() {
  echo "[installer] $*"
}

ui_warn() {
  echo "[installer][warn] $*" >&2
}

ui_error() {
  echo "[installer][error] $*" >&2
}

ui_section() {
  echo
  echo "== $* =="
}

ui_confirm() {
  local prompt="${1:-继续？}"
  local default="${2:-N}"
  local answer=""
  if [[ "$default" == "Y" ]]; then
    read -r -p "$prompt [Y/n]: " answer || true
    answer="${answer:-Y}"
  else
    read -r -p "$prompt [y/N]: " answer || true
    answer="${answer:-N}"
  fi
  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

ui_prompt() {
  local var_name="$1"
  local prompt="$2"
  local default="${3:-}"
  local answer=""
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " answer || true
    answer="${answer:-$default}"
  else
    read -r -p "$prompt: " answer || true
  fi
  printf -v "$var_name" '%s' "$answer"
}

ui_choose() {
  local var_name="$1"
  local prompt="$2"
  shift 2
  local options=("$@")
  local i=1
  local choice=""

  echo "$prompt"
  for opt in "${options[@]}"; do
    echo "  $i) $opt"
    i=$((i + 1))
  done

  while true; do
    read -r -p "请选择编号: " choice || true
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
      printf -v "$var_name" '%s' "${options[$((choice - 1))]}"
      return 0
    fi
    ui_warn "无效选择，请重新输入。"
  done
}

ui_print_execute_summary() {
  local output_dir_abs="$1"
  local platform="$2"
  local snippets_target="$3"
  local vhost_target="$4"
  local error_root="$5"
  local will_run_nginx_test="$6"

  ui_section "真实 apply 最终确认摘要"
  echo "- 部署输出目录：$output_dir_abs"
  echo "- 平台：$platform"
  echo "- snippets 目标路径：$snippets_target"
  echo "- vhost 目标路径：$vhost_target"
  echo "- 错误页目标路径：$error_root"
  echo "- 结果摘要文件：$output_dir_abs/APPLY-RESULT.md"
  if [[ "$will_run_nginx_test" == "1" ]]; then
    echo "- apply 后动作：会执行 nginx -t"
  else
    echo "- apply 后动作：不会执行 nginx -t"
  fi
  echo
  echo "风险边界："
  echo "- 会复制 snippets / conf / errors 到目标目录"
  echo "- 默认不会 reload nginx"
  echo "- nginx -t 失败时不会自动回滚"
  echo "- 如需回滚，应按备份目录手工恢复"
}
