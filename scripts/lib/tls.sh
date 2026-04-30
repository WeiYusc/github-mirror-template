#!/usr/bin/env bash
set -euo pipefail

tls_has_command() {
  command -v "$1" >/dev/null 2>&1
}

tls_read_cert_enddate() {
  local cert_path="$1"
  openssl x509 -in "$cert_path" -noout -enddate 2>/dev/null | sed 's/^notAfter=//'
}

tls_read_cert_subject() {
  local cert_path="$1"
  openssl x509 -in "$cert_path" -noout -subject 2>/dev/null | sed 's/^subject=//'
}

tls_read_cert_san() {
  local cert_path="$1"
  openssl x509 -in "$cert_path" -noout -ext subjectAltName 2>/dev/null | awk '
    /DNS:/ {
      gsub(/DNS:/, "", $0)
      gsub(/, /, "\n", $0)
      print
    }
  '
}

tls_pubkey_sha256_from_cert() {
  local cert_path="$1"
  openssl x509 -in "$cert_path" -pubkey -noout 2>/dev/null \
    | openssl pkey -pubin -outform pem 2>/dev/null \
    | sha256sum 2>/dev/null | awk '{print $1}'
}

tls_pubkey_sha256_from_key() {
  local key_path="$1"
  openssl pkey -in "$key_path" -pubout -outform pem 2>/dev/null \
    | sha256sum 2>/dev/null | awk '{print $1}'
}

tls_days_until_expiry() {
  local cert_path="$1"
  python3 - "$cert_path" <<'PY'
import subprocess
import sys
from datetime import datetime, timezone

cert = sys.argv[1]
proc = subprocess.run(
    ["openssl", "x509", "-in", cert, "-noout", "-enddate"],
    capture_output=True,
    text=True,
)
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
}

tls_mode_is_existing() {
  [[ "${TLS_MODE:-existing}" == "existing" ]]
}

tls_mode_is_acme_http01() {
  [[ "${TLS_MODE:-existing}" == "acme-http01" ]]
}

tls_mode_is_acme_dns_cloudflare() {
  [[ "${TLS_MODE:-existing}" == "acme-dns-cloudflare" ]]
}

tls_describe_mode() {
  case "${1:-existing}" in
    existing)
      printf '使用现有证书文件（tls.cert / tls.key）\n'
      ;;
    acme-http01)
      printf '计划使用 ACME HTTP-01（本阶段只生成预检/计划，不实际申请证书）\n'
      ;;
    acme-dns-cloudflare)
      printf '计划使用 ACME DNS-01 + Cloudflare（本阶段只生成预检/计划，不实际申请证书）\n'
      ;;
    *)
      printf '未知 TLS 模式：%s\n' "$1"
      ;;
  esac
}

tls_print_summary() {
  local mode="${1:-${TLS_MODE:-existing}}"
  local cert_path="${2:-${TLS_CERT:-}}"
  local key_path="${3:-${TLS_KEY:-}}"

  echo "TLS 摘要："
  echo "- tls.mode: $mode"
  echo "- 模式说明: $(tls_describe_mode "$mode")"

  case "$mode" in
    existing)
      if [[ -f "$cert_path" ]]; then
        echo "- 证书文件存在：$cert_path"
      else
        echo "- 证书文件当前不存在：$cert_path"
      fi

      if [[ -f "$key_path" ]]; then
        echo "- 私钥文件存在：$key_path"
      else
        echo "- 私钥文件当前不存在：$key_path"
      fi

      if ! tls_has_command openssl; then
        echo "- 当前环境缺少 openssl，无法解析证书内容"
        echo "- 当前阶段仅做只读检查，不修改任何证书或密钥文件"
        return 0
      fi

      if [[ -f "$cert_path" ]]; then
        local subject=""
        subject="$(tls_read_cert_subject "$cert_path" || true)"
        if [[ -n "$subject" ]]; then
          echo "- 证书 Subject: $subject"
        else
          echo "- 证书 Subject: 读取失败"
        fi

        local enddate=""
        enddate="$(tls_read_cert_enddate "$cert_path" || true)"
        if [[ -n "$enddate" ]]; then
          echo "- 到期时间: $enddate"
        else
          echo "- 到期时间: 读取失败"
        fi

        local days_left=""
        days_left="$(tls_days_until_expiry "$cert_path" 2>/dev/null || true)"
        if [[ -n "$days_left" ]]; then
          echo "- 剩余天数: $days_left"
        fi

        mapfile -t san_list < <(tls_read_cert_san "$cert_path" | awk 'NF')
        if [[ ${#san_list[@]} -gt 0 ]]; then
          echo "- SAN 列表:"
          local san
          for san in "${san_list[@]}"; do
            echo "  - $san"
          done
        else
          echo "- SAN 列表: 未读取到或证书未声明 SAN"
        fi
      fi

      if [[ -f "$cert_path" && -f "$key_path" ]]; then
        local cert_fp=""
        local key_fp=""
        cert_fp="$(tls_pubkey_sha256_from_cert "$cert_path" || true)"
        key_fp="$(tls_pubkey_sha256_from_key "$key_path" || true)"
        if [[ -n "$cert_fp" && -n "$key_fp" ]]; then
          if [[ "$cert_fp" == "$key_fp" ]]; then
            echo "- cert/key 匹配性: 公钥指纹一致"
          else
            echo "- cert/key 匹配性: 公钥指纹不一致，请确认是否配错"
          fi
        else
          echo "- cert/key 匹配性: 无法判断（解析失败）"
        fi
      fi
      ;;
    acme-http01)
      echo "- 目标证书获取方式：ACME HTTP-01"
      echo "- 关键前提：所有派生域名需已解析到当前机器；80 端口需可用于 ACME challenge"
      echo "- 本阶段不会自动安装 acme.sh / certbot，不会申请证书，不会改 nginx"
      ;;
    acme-dns-cloudflare)
      echo "- 目标证书获取方式：ACME DNS-01 + Cloudflare"
      echo "- 关键前提：Cloudflare 区域 / API 凭据 / DNS 权限需后续显式配置"
      echo "- 本阶段不会自动安装 acme.sh / certbot，不会调用 Cloudflare API，不会申请证书"
      ;;
    *)
      echo "- 未知 tls.mode：$mode"
      ;;
  esac

  echo "- 当前阶段仅做只读检查，不修改任何证书或密钥文件"
}
