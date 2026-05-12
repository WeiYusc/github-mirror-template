#!/usr/bin/env bash
set -euo pipefail

tls_plan_json_bool() {
  if [[ "${1:-0}" == "1" ]]; then
    printf 'true'
  else
    printf 'false'
  fi
}

tls_plan_detect_current_port_80_status() {
  if dns_port_is_listening 80; then
    printf 'listening\n'
    return 0
  fi

  local rc=$?
  if [[ "$rc" == "1" ]]; then
    printf 'not-listening\n'
  else
    printf 'unknown\n'
  fi
}

tls_plan_write_markdown() {
  local target_path="$1"
  local status="$2"
  local mode="${TLS_MODE:-existing}"

  mkdir -p "$(dirname "$target_path")"

  {
    echo "# TLS PLAN"
    echo
    echo "## 执行概览"
    echo
    echo "- 状态：$status"
    echo "- tls.mode：$mode"
    echo "- deployment_name：${DEPLOYMENT_NAME:-}"
    echo "- base_domain：${BASE_DOMAIN:-}"
    echo "- domain.mode：${DOMAIN_MODE:-}"
    echo "- deployment.platform：${PLATFORM:-}"
    echo "- paths.output_dir：${OUTPUT_DIR:-}"
    echo
    echo "## 模式说明"
    echo
    case "$mode" in
      existing)
        echo "- 复用现有证书文件；installer 仅做只读校验与摘要输出。"
        echo "- tls.cert：${TLS_CERT:-}"
        echo "- tls.key：${TLS_KEY:-}"
        ;;
      acme-http01)
        echo "- 计划后续使用 ACME HTTP-01 申请证书。"
        echo "- 本阶段不会执行 acme.sh / certbot / nginx 改写 / 证书申请。"
        echo "- 仅生成预检结论与后续操作计划。"
        ;;
      acme-dns-cloudflare)
        echo "- 计划后续使用 ACME DNS-01 + Cloudflare 申请证书。"
        echo "- 本阶段不会调用 Cloudflare API，不会安装 acme.sh，不会申请证书。"
        echo "- 仅生成预检结论与后续操作计划。"
        ;;
      *)
        echo "- 未知 tls.mode：$mode"
        ;;
    esac

    echo
    echo "## 派生域名"
    echo
    local host
    while IFS= read -r host; do
      [[ -n "$host" ]] || continue
      echo "- $host"
    done < <(dns_derive_hosts "${BASE_DOMAIN:-}" "${DOMAIN_MODE:-}")

    echo
    echo "## 当前阶段边界"
    echo
    echo "- 不申请证书"
    echo "- 不安装 acme.sh / certbot"
    echo "- 不改动 Cloudflare DNS"
    echo "- 不接管现网 nginx challenge 配置"
    echo "- 若存在 BLOCK，generator 不会继续"

    echo
    echo "## 后续建议"
    echo
    case "$mode" in
      existing)
        echo "1. 核对 tls.cert / tls.key 文件是否真实存在且可读。"
        echo "2. 核对证书 SAN 是否覆盖全部派生域名。"
        echo "3. 通过 preflight 后，再进入 generator / apply plan 审查。"
        ;;
      acme-http01)
        echo "1. 先确保全部派生域名解析到当前机器。"
        echo "2. 确认 80 端口可被 challenge 使用。"
        echo "3. 后续单独实现显式 ACME issue 步骤，再接入 generator 之后的 apply。"
        ;;
      acme-dns-cloudflare)
        echo "1. 准备 Cloudflare zone / token / 最小权限策略。"
        echo "2. 确认通配符 / 多 SAN 证书需求。"
        echo "3. 后续单独实现显式 DNS-01 issue 步骤，再接入 generator 之后的 apply。"
        ;;
    esac
  } > "$target_path"
}

tls_plan_write_json() {
  local target_path="$1"
  local status="$2"
  local dns_ready="$3"
  local port_80_status="$4"

  mkdir -p "$(dirname "$target_path")"

  local hosts_file warnings_file blockers_file
  hosts_file="$(mktemp)"
  warnings_file="$(mktemp)"
  blockers_file="$(mktemp)"

  dns_derive_hosts "${BASE_DOMAIN:-}" "${DOMAIN_MODE:-}" > "$hosts_file"
  printf '%s\n' "${CHECK_WARNINGS[@]}" > "$warnings_file"
  printf '%s\n' "${CHECK_BLOCKERS[@]}" > "$blockers_file"

  python3 - "$target_path" "$status" "$hosts_file" "$warnings_file" "$blockers_file" "$dns_ready" "$port_80_status" <<'PY'
import json
import os
import sys
from pathlib import Path

(
    target_path,
    status,
    hosts_file,
    warnings_file,
    blockers_file,
    dns_ready,
    port_80_status,
) = sys.argv[1:]

def read_lines(path: str):
    p = Path(path)
    if not p.exists():
        return []
    return [line.rstrip("\n") for line in p.read_text(encoding="utf-8").splitlines() if line.rstrip("\n")]

def env(name: str, default: str = ""):
    return os.environ.get(name, default)

payload = {
    "schema_kind": "tls-plan",
    "schema_version": 1,
    "status": status,
    "mode": env("TLS_MODE", "existing"),
    "context": {
        "deployment_name": env("DEPLOYMENT_NAME"),
        "base_domain": env("BASE_DOMAIN"),
        "domain_mode": env("DOMAIN_MODE"),
        "platform": env("PLATFORM"),
        "output_dir": env("OUTPUT_DIR"),
        "tls_cert": env("TLS_CERT"),
        "tls_key": env("TLS_KEY"),
    },
    "derived_hosts": read_lines(hosts_file),
    "checks": {
        "dns_points_to_local_ready": dns_ready == "1",
        "port_80_status": port_80_status,
    },
    "warnings": read_lines(warnings_file),
    "blockers": read_lines(blockers_file),
    "phase_boundary": {
        "issues_certificate": False,
        "installs_acme_client": False,
        "modifies_dns": False,
        "modifies_live_nginx": False,
    },
}

Path(target_path).write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

  rm -f "$hosts_file" "$warnings_file" "$blockers_file"
}

tls_plan_generate_artifacts() {
  local status="$1"
  local markdown_path="$2"
  local json_path="$3"

  local dns_ready="0"
  local port_80_status="unknown"

  if tls_mode_is_acme_http01; then
    local host dns_rc
    dns_ready="1"
    while IFS= read -r host; do
      [[ -n "$host" ]] || continue
      if dns_host_points_to_local_machine "$host"; then
        :
      else
        dns_rc=$?
        dns_ready="0"
        if [[ "$dns_rc" == "2" ]]; then
          check_add_blocker "ACME HTTP-01 需要域名先解析到当前机器，但当前无法解析：$host"
        elif [[ "$dns_rc" == "3" ]]; then
          check_add_warning "无法可靠识别本机公网/全局地址，无法确认 $host 是否已指向当前机器；请人工复核"
        else
          check_add_blocker "ACME HTTP-01 需要域名先解析到当前机器，但当前解析结果未指向本机：$host"
        fi
      fi
    done < <(dns_derive_hosts "${BASE_DOMAIN:-}" "${DOMAIN_MODE:-}")

    port_80_status="$(tls_plan_detect_current_port_80_status)"
    case "$port_80_status" in
      not-listening)
        check_add_warning "当前未检测到 80 端口监听；后续若采用 standalone/webroot HTTP-01，请确认 challenge 路径可达"
        ;;
      unknown)
        check_add_warning "当前无法检测 80 端口监听状态；请人工确认 HTTP-01 challenge 是否可用"
        ;;
    esac
  fi

  tls_plan_write_markdown "$markdown_path" "$status"
  tls_plan_write_json "$json_path" "$status" "$dns_ready" "$port_80_status"
}
