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

ui_value_looks_like_yes_no() {
  case "$1" in
    y|Y|yes|YES|Yes|n|N|no|NO|No) return 0 ;;
    *) return 1 ;;
  esac
}

ui_value_looks_like_path() {
  local value="$1"
  [[ "$value" == /* || "$value" == ./* || "$value" == ../* || "$value" == '~/'* || "$value" == *"/"* || "$value" == "." || "$value" == ".." ]]
}

ui_prompt_path() {
  local var_name="$1"
  local prompt="$2"
  local default="${3:-}"
  local answer=""

  while true; do
    if [[ -n "$default" ]]; then
      read -r -p "$prompt [$default]: " answer || true
      answer="${answer:-$default}"
    else
      read -r -p "$prompt: " answer || true
    fi

    if ui_value_looks_like_yes_no "$answer" && ! ui_value_looks_like_path "$answer"; then
      ui_warn "你输入的是 \"$answer\"，看起来像确认回答，不像路径。"
      if ui_confirm "仍然使用这个值作为路径吗？" "N"; then
        printf -v "$var_name" '%s' "$answer"
        return 0
      fi
      continue
    fi

    printf -v "$var_name" '%s' "$answer"
    return 0
  done
}

ui_choose() {
  local var_name="$1"
  local prompt="$2"
  shift 2
  local options=("$@")
  local i=1
  local choice=""
  local default_index=1

  echo "$prompt"
  for opt in "${options[@]}"; do
    if (( i == default_index )); then
      echo "  $i) $opt (default)"
    else
      echo "  $i) $opt"
    fi
    i=$((i + 1))
  done

  while true; do
    read -r -p "请选择编号 [$default_index]: " choice || true
    choice="${choice:-$default_index}"
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
  local backup_dir="$6"
  local will_run_nginx_test="$7"
  local nginx_test_cmd="$8"

  ui_section "真实 apply 最终确认摘要"
  echo "- 部署输出目录：$output_dir_abs"
  echo "- 平台：$platform"
  echo "- snippets 目标路径：$snippets_target"
  echo "- vhost 目标路径：$vhost_target"
  echo "- 错误页目标路径：$error_root"
  echo "- 备份目录：$backup_dir"
  echo "- 结果摘要文件：$output_dir_abs/APPLY-RESULT.md"
  if [[ "$will_run_nginx_test" == "1" ]]; then
    echo "- apply 后动作：会执行 nginx 测试"
    echo "- nginx 测试命令：$nginx_test_cmd"
  else
    echo "- apply 后动作：不会执行 nginx -t"
  fi
  echo
  echo "风险边界："
  echo "- 会复制 snippets / conf / errors 到目标目录"
  echo "- 默认不会 reload nginx"
  echo "- nginx 测试失败时不会自动回滚"
  echo "- 如需回滚，应按备份目录手工恢复"
}

ui_print_bt_panel_quick_check_hint() {
  local base_domain="$1"
  local domain_mode="$2"

  if [[ -z "$base_domain" ]]; then
    return 0
  fi

  echo
  ui_section "BaoTa quick-check 建议"
  echo "- 建议在 BaoTa / 宝塔环境的 apply / repair 之后，优先运行："
  if [[ -n "$domain_mode" ]]; then
    echo "  ./scripts/check-bt-panel-nginx-quick.sh --base-domain $base_domain --domain-mode $domain_mode"
  else
    echo "  ./scripts/check-bt-panel-nginx-quick.sh --base-domain $base_domain"
  fi
  if [[ "$domain_mode" == "nested" ]]; then
    echo "- 当前域名模型为 nested，建议显式补：--domain-mode nested"
  elif [[ "$domain_mode" == "flat-siblings" ]]; then
    echo "- 当前域名模型为 flat-siblings；这里已显式带上 --domain-mode flat-siblings 以避免 auto 误判"
  else
    echo "- 如你的部署不是 flat-siblings，而是 nested hosts，请显式补：--domain-mode nested"
  fi
  echo "- 如需更完整的线上验收，再运行："
  echo "  ./scripts/check-live-mirror.sh --base-domain $base_domain${domain_mode:+ --domain-mode $domain_mode}"
}
