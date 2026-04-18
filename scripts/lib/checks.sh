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

check_value_looks_like_yes_no() {
  case "$1" in
    y|Y|yes|YES|Yes|n|N|no|NO|No) return 0 ;;
    *) return 1 ;;
  esac
}

check_warn_if_suspicious_path_value() {
  local label="$1"
  local value="$2"
  if [[ -n "$value" ]] && check_value_looks_like_yes_no "$value"; then
    check_add_warning "$label 看起来像误填的确认回答（$value），不像路径；请确认是否发生了交互输入错位"
  fi
}

check_warn_if_tls_paths_look_swapped() {
  local cert_path="${TLS_CERT:-}"
  local key_path="${TLS_KEY:-}"
  local cert_base="$(basename "$cert_path" 2>/dev/null || printf '%s' "$cert_path")"
  local key_base="$(basename "$key_path" 2>/dev/null || printf '%s' "$key_path")"

  if [[ "$cert_base" =~ (privkey|private|\.key$) ]]; then
    check_add_warning "tls.cert 看起来更像私钥路径：$cert_path；请确认 cert / key 是否填反"
  fi
  if [[ "$key_base" =~ (fullchain|chain|cert|certificate|\.crt$|\.pem$) ]] && [[ ! "$key_base" =~ (privkey|private|\.key$) ]]; then
    check_add_warning "tls.key 看起来更像证书路径：$key_path；请确认 cert / key 是否填反"
  fi
}

check_block_if_output_dir_hits_live_targets() {
  local output_dir="${OUTPUT_DIR:-}"
  local snippets_target="${NGINX_SNIPPETS_TARGET_HINT:-}"
  local vhost_target="${NGINX_VHOST_TARGET_HINT:-}"
  local error_root="${ERROR_ROOT:-}"

  if [[ -n "$output_dir" && -n "$snippets_target" && "$output_dir" == "$snippets_target" ]]; then
    check_add_blocker "paths.output_dir 不应与 nginx.snippets_target_hint 相同；请避免把生成包直接写进 live snippets 目录"
  fi
  if [[ -n "$output_dir" && -n "$vhost_target" && "$output_dir" == "$vhost_target" ]]; then
    check_add_blocker "paths.output_dir 不应与 nginx.vhost_target_hint 相同；请避免把生成包直接写进 live vhost 目录"
  fi
  if [[ -n "$output_dir" && -n "$error_root" && "$output_dir" == "$error_root" ]]; then
    check_add_blocker "paths.output_dir 不应与 paths.error_root 相同；请避免把生成包直接写进 live 错误页目录"
  fi

  case "$output_dir" in
    /etc/nginx|/etc/nginx/*|/www/server/nginx/snippets|/www/server/nginx/snippets/*|/www/server/panel/vhost/nginx|/www/server/panel/vhost/nginx/*)
      check_add_blocker "paths.output_dir 看起来像 live nginx 目录：$output_dir；请改用 dist/ 下的审查输出目录"
      ;;
  esac
}

check_warn_if_dns_tools_missing() {
  if ! command -v getent >/dev/null 2>&1 && ! command -v dig >/dev/null 2>&1 && ! command -v nslookup >/dev/null 2>&1; then
    check_add_warning "当前环境缺少 getent/dig/nslookup，DNS 摘要将无法做真实解析查询"
  fi
}

check_warn_if_derived_domains_unresolved() {
  if ! command -v getent >/dev/null 2>&1 && ! command -v dig >/dev/null 2>&1 && ! command -v nslookup >/dev/null 2>&1; then
    return 0
  fi

  local host
  while IFS= read -r host; do
    [[ -n "$host" ]] || continue
    local resolved=""
    resolved="$(dns_lookup_ips "$host" 2>/dev/null | awk 'NF' || true)"
    if [[ -z "$resolved" ]]; then
      check_add_warning "派生域名当前未解析到 A/AAAA 记录：$host"
    fi
  done < <(dns_derive_hosts "${BASE_DOMAIN:-}" "${DOMAIN_MODE:-}")
}

check_domain_matches_pattern() {
  local domain="$1"
  local pattern="$2"
  if [[ "$pattern" == \*.* ]]; then
    local suffix="${pattern#*.}"
    [[ "$domain" == *.$suffix ]]
  else
    [[ "$domain" == "$pattern" ]]
  fi
}

check_warn_if_cert_does_not_cover_domains() {
  if ! command -v openssl >/dev/null 2>&1; then
    return 0
  fi
  if [[ ! -f "${TLS_CERT:-}" ]]; then
    return 0
  fi

  mapfile -t san_list < <(tls_read_cert_san "${TLS_CERT}" | awk 'NF')
  if [[ ${#san_list[@]} -eq 0 ]]; then
    return 0
  fi

  local host
  while IFS= read -r host; do
    [[ -n "$host" ]] || continue
    local covered="0"
    local san
    for san in "${san_list[@]}"; do
      if check_domain_matches_pattern "$host" "$san"; then
        covered="1"
        break
      fi
    done
    if [[ "$covered" != "1" ]]; then
      check_add_warning "tls.cert 的 SAN 当前未覆盖派生域名：$host"
    fi
  done < <(dns_derive_hosts "${BASE_DOMAIN:-}" "${DOMAIN_MODE:-}")
}

check_tls_integrity() {
  if ! command -v openssl >/dev/null 2>&1; then
    check_add_warning "当前环境缺少 openssl，无法判断证书内容、到期时间和 cert/key 是否匹配"
    return 0
  fi

  if [[ -f "${TLS_CERT:-}" ]]; then
    if ! openssl x509 -in "${TLS_CERT}" -noout >/dev/null 2>&1; then
      check_add_warning "tls.cert 文件存在，但 openssl 无法解析为有效证书：${TLS_CERT}"
    fi
  fi

  if [[ -f "${TLS_KEY:-}" ]]; then
    if ! openssl pkey -in "${TLS_KEY}" -pubout >/dev/null 2>&1; then
      check_add_warning "tls.key 文件存在，但 openssl 无法解析为有效私钥：${TLS_KEY}"
    fi
  fi

  if [[ -f "${TLS_CERT:-}" && -f "${TLS_KEY:-}" ]]; then
    local cert_fp=""
    local key_fp=""
    cert_fp="$(openssl x509 -in "${TLS_CERT}" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform pem 2>/dev/null | sha256sum 2>/dev/null | awk '{print $1}' || true)"
    key_fp="$(openssl pkey -in "${TLS_KEY}" -pubout -outform pem 2>/dev/null | sha256sum 2>/dev/null | awk '{print $1}' || true)"

    if [[ -n "$cert_fp" && -n "$key_fp" && "$cert_fp" != "$key_fp" ]]; then
      check_add_warning "tls.cert 与 tls.key 的公钥指纹不一致；请确认是否使用了错误的证书/私钥组合"
    fi

    local days_left=""
    days_left="$(python3 - "${TLS_CERT}" <<'PY'
import subprocess
import sys
from datetime import datetime, timezone

cert = sys.argv[1]
proc = subprocess.run(["openssl", "x509", "-in", cert, "-noout", "-enddate"], capture_output=True, text=True)
if proc.returncode != 0:
    sys.exit(1)
line = proc.stdout.strip()
if not line.startswith("notAfter="):
    sys.exit(1)
value = line.split("=", 1)[1].strip()
for fmt in ("%b %d %H:%M:%S %Y %Z", "%b  %d %H:%M:%S %Y %Z"):
    try:
        dt = datetime.strptime(value, fmt)
        break
    except ValueError:
        dt = None
if dt is None:
    sys.exit(1)
dt = dt.replace(tzinfo=timezone.utc)
now = datetime.now(timezone.utc)
print((dt - now).days)
PY
2>/dev/null || true)"
    if [[ -n "$days_left" ]]; then
      if (( days_left < 0 )); then
        check_add_warning "tls.cert 已过期（剩余天数：$days_left）"
      elif (( days_left < 30 )); then
        check_add_warning "tls.cert 距离过期已不足 30 天（剩余天数：$days_left）"
      fi
    fi
  fi
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

  check_warn_if_suspicious_path_value "tls.cert" "${TLS_CERT:-}"
  check_warn_if_suspicious_path_value "tls.key" "${TLS_KEY:-}"
  check_warn_if_suspicious_path_value "paths.error_root" "${ERROR_ROOT:-}"
  check_warn_if_suspicious_path_value "paths.log_dir" "${LOG_DIR:-}"
  check_warn_if_suspicious_path_value "paths.output_dir" "${OUTPUT_DIR:-}"
  check_warn_if_suspicious_path_value "nginx.snippets_target_hint" "${NGINX_SNIPPETS_TARGET_HINT:-}"
  check_warn_if_suspicious_path_value "nginx.vhost_target_hint" "${NGINX_VHOST_TARGET_HINT:-}"
  check_warn_if_tls_paths_look_swapped
  check_block_if_output_dir_hits_live_targets
  check_warn_if_dns_tools_missing
  check_warn_if_derived_domains_unresolved
  check_tls_integrity
  check_warn_if_cert_does_not_cover_domains

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
  local warning_count="${#CHECK_WARNINGS[@]}"
  local blocker_count="${#CHECK_BLOCKERS[@]}"

  echo "Preflight checklist："
  echo "- BLOCK: $blocker_count"
  echo "- WARN: $warning_count"

  if [[ $blocker_count -eq 0 && $warning_count -eq 0 ]]; then
    echo "- PASS: 未发现阻断项或警告"
    echo
    echo "结论：当前可以继续进入 generator / apply 下一步。"
    return 0
  fi

  if [[ $warning_count -gt 0 ]]; then
    echo
    echo "Warnings:"
    for item in "${CHECK_WARNINGS[@]}"; do
      echo "- [WARN] $item"
    done
  fi

  if [[ $blocker_count -gt 0 ]]; then
    echo
    echo "Blockers:"
    for item in "${CHECK_BLOCKERS[@]}"; do
      echo "- [BLOCK] $item"
    done
    echo
    echo "结论：存在 BLOCK 项；请先处理后再继续。"
  else
    echo
    echo "结论：当前可继续，但建议先人工确认 WARN 项。"
  fi
}

has_blockers() {
  [[ ${#CHECK_BLOCKERS[@]} -gt 0 ]]
}
