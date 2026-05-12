#!/usr/bin/env bash
set -euo pipefail

dns_derive_hosts() {
  local base_domain="$1"
  local domain_mode="$2"

  local hub raw gist assets archive download
  if [[ "$domain_mode" == "flat-siblings" ]]; then
    local suffix="${base_domain#*.}"
    hub="$base_domain"
    raw="raw.$suffix"
    gist="gist.$suffix"
    assets="assets.$suffix"
    archive="archive.$suffix"
    download="download.$suffix"
  else
    hub="$base_domain"
    raw="raw.$base_domain"
    gist="gist.$base_domain"
    assets="assets.$base_domain"
    archive="archive.$base_domain"
    download="download.$base_domain"
  fi

  printf '%s\n' "$hub" "$raw" "$gist" "$assets" "$archive" "$download"
}

dns_has_command() {
  command -v "$1" >/dev/null 2>&1
}

dns_unique_lines() {
  awk 'NF && !seen[$0]++ {print $0}'
}

dns_lookup_with_getent() {
  local host="$1"
  getent ahosts "$host" 2>/dev/null | awk '!seen[$1]++ {print $1}'
}

dns_lookup_with_dig() {
  local host="$1"
  dig +short A "$host" 2>/dev/null | awk 'NF'
  dig +short AAAA "$host" 2>/dev/null | awk 'NF'
}

dns_lookup_with_nslookup() {
  local host="$1"
  nslookup "$host" 2>/dev/null | awk '/^Address: / {print $2}'
}

dns_lookup_ips() {
  local host="$1"

  if dns_has_command getent; then
    dns_lookup_with_getent "$host"
    return 0
  fi
  if dns_has_command dig; then
    dns_lookup_with_dig "$host"
    return 0
  fi
  if dns_has_command nslookup; then
    dns_lookup_with_nslookup "$host"
    return 0
  fi
  return 1
}

dns_detect_local_ips() {
  {
    if dns_has_command hostname; then
      hostname -I 2>/dev/null | tr ' ' '\n'
    fi
    if dns_has_command ip; then
      ip -o addr show scope global up 2>/dev/null | awk '{split($4, parts, "/"); print parts[1]}'
      ip route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src" && (i + 1) <= NF) print $(i + 1)}'
    fi
  } | grep -E '^[0-9A-Fa-f:.]+$' | dns_unique_lines
}

dns_host_points_to_local_machine() {
  local host="$1"
  local resolved_ip local_ip
  local matched="1"

  mapfile -t resolved_ips < <(dns_lookup_ips "$host" 2>/dev/null | awk 'NF' | dns_unique_lines)
  if [[ ${#resolved_ips[@]} -eq 0 ]]; then
    return 2
  fi

  mapfile -t local_ips < <(dns_detect_local_ips | awk 'NF' | dns_unique_lines)
  if [[ ${#local_ips[@]} -eq 0 ]]; then
    return 3
  fi

  for resolved_ip in "${resolved_ips[@]}"; do
    for local_ip in "${local_ips[@]}"; do
      if [[ "$resolved_ip" == "$local_ip" ]]; then
        matched="0"
        break 2
      fi
    done
  done

  return "$matched"
}

dns_port_is_listening() {
  local port="$1"

  if dns_has_command ss; then
    ss -ltnH 2>/dev/null | awk -v port=":$port" '$4 ~ port"$" {found=1} END {exit(found ? 0 : 1)}'
    return $?
  fi

  if dns_has_command netstat; then
    netstat -ltn 2>/dev/null | awk -v port=":$port" '$4 ~ port"$" {found=1} END {exit(found ? 0 : 1)}'
    return $?
  fi

  return 2
}

dns_print_summary() {
  local base_domain="$1"
  local domain_mode="$2"

  mapfile -t hosts < <(dns_derive_hosts "$base_domain" "$domain_mode")
  local labels=("Hub" "Raw" "Gist" "Assets" "Archive" "Download")

  echo "DNS 摘要："
  local i
  for i in "${!hosts[@]}"; do
    local host="${hosts[$i]}"
    local label="${labels[$i]}"
    echo "- $label: $host"

    local resolved=""
    if resolved="$(dns_lookup_ips "$host")"; then
      resolved="$(printf '%s\n' "$resolved" | awk 'NF' | paste -sd ', ' -)"
      if [[ -n "$resolved" ]]; then
        echo "  - 解析结果: $resolved"
      else
        echo "  - 解析结果: 未查到 A/AAAA 记录"
      fi
    else
      echo "  - 解析结果: 当前环境缺少 getent/dig/nslookup，无法做真实查询"
    fi
  done

  echo "- 当前阶段仅做只读 DNS 查询，不修改任何解析记录"
}
