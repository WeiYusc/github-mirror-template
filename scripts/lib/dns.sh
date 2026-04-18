#!/usr/bin/env bash
set -euo pipefail

dns_print_summary() {
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

  cat <<EOF
DNS 摘要：
- Hub: $hub
- Raw: $raw
- Gist: $gist
- Assets: $assets
- Archive: $archive
- Download: $download
- 当前阶段仅输出派生域名摘要，不做真实 DNS 查询
EOF
}
