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
