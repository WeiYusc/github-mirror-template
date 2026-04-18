#!/usr/bin/env bash
set -euo pipefail

CHECK_WARNINGS=()
CHECK_BLOCKERS=()

check_add_warning() {
  CHECK_WARNINGS+=("$1")
}

check_add_blocker() {
  CHECK_BLOCKERS+=("$1")
}

run_basic_checks() {
  command -v bash >/dev/null 2>&1 || check_add_blocker "bash 不可用"
  command -v python3 >/dev/null 2>&1 || check_add_blocker "python3 不可用"
  command -v nginx >/dev/null 2>&1 || check_add_warning "nginx 当前不在 PATH 中；若仅生成部署包可继续，若后续 apply 可能需要手工处理"

  python3 - <<'PY' >/dev/null 2>&1 || exit_code=$?
import importlib
import sys
try:
    importlib.import_module('yaml')
except Exception:
    sys.exit(1)
sys.exit(0)
PY
  if [[ "${exit_code:-0}" != "0" ]]; then
    check_add_blocker "缺少 Python 依赖 PyYAML"
  fi

  [[ -n "${DEPLOYMENT_NAME:-}" ]] || check_add_blocker "deployment_name 不能为空"
  [[ -n "${BASE_DOMAIN:-}" ]] || check_add_blocker "domain.base_domain 不能为空"
  [[ -n "${TLS_CERT:-}" ]] || check_add_blocker "tls.cert 不能为空"
  [[ -n "${TLS_KEY:-}" ]] || check_add_blocker "tls.key 不能为空"
  [[ -n "${ERROR_ROOT:-}" ]] || check_add_blocker "paths.error_root 不能为空"
  [[ -n "${OUTPUT_DIR:-}" ]] || check_add_blocker "paths.output_dir 不能为空"

  [[ -f "${TLS_CERT:-}" ]] || check_add_warning "证书文件当前不存在：${TLS_CERT:-}"
  [[ -f "${TLS_KEY:-}" ]] || check_add_warning "私钥文件当前不存在：${TLS_KEY:-}"

  case "${PLATFORM:-}" in
    plain-nginx|bt-panel-nginx) ;;
    *) check_add_blocker "deployment.platform 仅支持 plain-nginx / bt-panel-nginx" ;;
  esac

  case "${DOMAIN_MODE:-}" in
    nested|flat-siblings) ;;
    *) check_add_blocker "domain.mode 仅支持 nested / flat-siblings" ;;
  esac
}

print_check_report() {
  echo "Preflight 结果："
  if [[ ${#CHECK_BLOCKERS[@]} -eq 0 && ${#CHECK_WARNINGS[@]} -eq 0 ]]; then
    echo "- PASS: 未发现阻断项或警告"
    return 0
  fi

  for item in "${CHECK_WARNINGS[@]}"; do
    echo "- WARN: $item"
  done
  for item in "${CHECK_BLOCKERS[@]}"; do
    echo "- BLOCK: $item"
  done
}

has_blockers() {
  [[ ${#CHECK_BLOCKERS[@]} -gt 0 ]]
}
