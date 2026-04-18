#!/usr/bin/env bash
set -euo pipefail

tls_print_summary() {
  local cert_path="$1"
  local key_path="$2"

  echo "TLS 摘要："
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

  echo "- 当前阶段仅做本地路径检查，不解析证书内容"
}
