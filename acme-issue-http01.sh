#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./acme-issue-http01.sh \
    --state-json <path> \
    [--dry-run] \
    [--execute] \
    [--result-file <path>] \
    [--challenge-mode <standalone|webroot|file-plan>] \
    [--webroot <path>] \
    [--acme-client <acme.sh|certbot|manual>] \
    [--account-email <email>] \
    [--staging]

Current stage:
  - Default is dry-run
  - Conservative Phase 2 first cut for ACME HTTP-01 issue planning
  - ISSUE-RESULT.{md,json} is reserved for planning / evidence only
  - Future real execute result must use ACME-ISSUANCE-RESULT.{md,json}
  - Does NOT issue certificates yet
  - Does NOT install acme client
  - Does NOT modify live nginx
  - Does NOT reload nginx
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"

# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/dns.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/apply-plan.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/state.sh"

STATE_JSON=""
DRY_RUN="0"
EXECUTE="0"
RESULT_FILE=""
RESULT_JSON_OUTPUT=""
CHALLENGE_MODE="standalone"
WEBROOT_PATH=""
ACME_CLIENT="manual"
ACCOUNT_EMAIL=""
USE_STAGING="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --state-json)
      STATE_JSON="$2"; shift 2 ;;
    --dry-run)
      DRY_RUN="1"; shift ;;
    --execute)
      EXECUTE="1"; shift ;;
    --result-file)
      RESULT_FILE="$2"; shift 2 ;;
    --challenge-mode)
      CHALLENGE_MODE="$2"; shift 2 ;;
    --webroot)
      WEBROOT_PATH="$2"; shift 2 ;;
    --acme-client)
      ACME_CLIENT="$2"; shift 2 ;;
    --account-email)
      ACCOUNT_EMAIL="$2"; shift 2 ;;
    --staging)
      USE_STAGING="1"; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "[issue-http01] Unknown argument: $1" >&2
      usage >&2
      exit 1 ;;
  esac
done

if [[ -z "$STATE_JSON" ]]; then
  echo "[issue-http01] Missing required argument: --state-json <path>" >&2
  exit 2
fi

if [[ ! -f "$STATE_JSON" ]]; then
  echo "[issue-http01] state.json not found: $STATE_JSON" >&2
  exit 3
fi

if [[ "$DRY_RUN" == "1" && "$EXECUTE" == "1" ]]; then
  echo "[issue-http01] --dry-run 与 --execute 不能同时使用。" >&2
  exit 4
fi

if [[ "$DRY_RUN" != "1" && "$EXECUTE" != "1" ]]; then
  DRY_RUN="1"
fi

case "$CHALLENGE_MODE" in
  standalone|webroot|file-plan) ;;
  *)
    echo "[issue-http01] 不支持的 challenge mode: $CHALLENGE_MODE" >&2
    exit 5
    ;;
esac

case "$ACME_CLIENT" in
  acme.sh|certbot|manual) ;;
  *)
    echo "[issue-http01] 不支持的 acme client: $ACME_CLIENT" >&2
    exit 6
    ;;
esac

RUN_ROOT="$(dirname "$STATE_JSON")"
STATE_JSON_PATH="$STATE_JSON"
STATE_JOURNAL_PATH="$RUN_ROOT/journal.jsonl"
STATE_DIR="$RUN_ROOT"
RUN_ID="$(basename "$RUN_ROOT")"

PARSED_JSON="$(mktemp)"
cleanup() {
  rm -f "$PARSED_JSON"
}
trap cleanup EXIT

python3 - "$STATE_JSON" "$PARSED_JSON" <<'PY'
import json
import sys
from pathlib import Path

state_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])
state = json.loads(state_path.read_text(encoding='utf-8'))
inputs = state.get('inputs') or {}
artifacts = state.get('artifacts') or {}
payload = {
    'run_id': state.get('run_id', ''),
    'deployment_name': inputs.get('deployment_name', ''),
    'base_domain': inputs.get('base_domain', ''),
    'domain_mode': inputs.get('domain_mode', ''),
    'platform': inputs.get('platform', ''),
    'tls_mode': inputs.get('tls_mode', ''),
    'output_dir_abs': artifacts.get('output_dir_abs', ''),
    'summary_output': artifacts.get('summary_output', ''),
}
out_path.write_text(json.dumps(payload, ensure_ascii=False), encoding='utf-8')
PY

read_json_field() {
  python3 - "$PARSED_JSON" "$1" <<'PY'
import json, sys
from pathlib import Path
obj = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
value = obj
for part in sys.argv[2].split('.'):
    if isinstance(value, dict):
        value = value.get(part, '')
    else:
        value = ''
        break
print(value if value is not None else '')
PY
}

DEPLOYMENT_NAME="$(read_json_field deployment_name)"
BASE_DOMAIN="$(read_json_field base_domain)"
DOMAIN_MODE="$(read_json_field domain_mode)"
PLATFORM="$(read_json_field platform)"
TLS_MODE="$(read_json_field tls_mode)"
OUTPUT_DIR_ABS="$(read_json_field output_dir_abs)"
SUMMARY_JSON_SECONDARY="$(read_json_field summary_output)"

if [[ "$TLS_MODE" != "acme-http01" ]]; then
  echo "[issue-http01] 当前 run 的 tls_mode=$TLS_MODE，不适用于 HTTP-01 issue helper。" >&2
  exit 7
fi

if [[ -z "$RESULT_FILE" ]]; then
  if [[ -n "$OUTPUT_DIR_ABS" ]]; then
    RESULT_FILE="$OUTPUT_DIR_ABS/ISSUE-RESULT.md"
  else
    RESULT_FILE="$(dirname "$STATE_JSON")/ISSUE-RESULT.md"
  fi
fi
RESULT_JSON_OUTPUT="${RESULT_FILE%.md}.json"
if [[ "$RESULT_JSON_OUTPUT" == "$RESULT_FILE" ]]; then
  RESULT_JSON_OUTPUT="$RESULT_FILE.json"
fi
ISSUE_RESULT_PATH="$RESULT_FILE"
ISSUE_RESULT_JSON_PATH="$RESULT_JSON_OUTPUT"
ACME_ISSUANCE_RESULT_FILE="$(dirname "$RESULT_FILE")/ACME-ISSUANCE-RESULT.md"
ACME_ISSUANCE_RESULT_JSON_PATH="$(dirname "$RESULT_FILE")/ACME-ISSUANCE-RESULT.json"

mapfile -t DERIVED_HOSTS < <(dns_derive_hosts "$BASE_DOMAIN" "$DOMAIN_MODE")
MODE_LABEL="dry-run"
if [[ "$EXECUTE" == "1" ]]; then
  MODE_LABEL="execute"
fi

DNS_READY="true"
DNS_BLOCKERS=()
PORT_80_STATUS="unknown"
PORT_80_READY="false"

for host in "${DERIVED_HOSTS[@]}"; do
  [[ -n "$host" ]] || continue
  if dns_host_points_to_local_machine "$host"; then
    :
  else
    rc=$?
    DNS_READY="false"
    if [[ "$rc" == "2" ]]; then
      DNS_BLOCKERS+=("域名当前无法解析到 A/AAAA：$host")
    elif [[ "$rc" == "3" ]]; then
      DNS_BLOCKERS+=("无法可靠识别本机全局 IP，需人工确认解析是否指向当前机器：$host")
    else
      DNS_BLOCKERS+=("域名解析当前未指向本机：$host")
    fi
  fi
done

if dns_port_is_listening 80; then
  PORT_80_STATUS="listening"
  PORT_80_READY="true"
else
  rc=$?
  if [[ "$rc" == "1" ]]; then
    PORT_80_STATUS="not-listening"
  else
    PORT_80_STATUS="unknown"
  fi
fi

NEEDS_WEBROOT="false"
WEBROOT_READY=""
WEBROOT_NOTE=""
if [[ "$CHALLENGE_MODE" == "webroot" ]]; then
  NEEDS_WEBROOT="true"
  if [[ -n "$WEBROOT_PATH" && -d "$WEBROOT_PATH" ]]; then
    WEBROOT_READY="true"
  else
    WEBROOT_READY="false"
    WEBROOT_NOTE="challenge_mode=webroot 但 webroot 路径当前不存在或未提供"
  fi
fi

RESULT_BLOCKERS=()
if [[ ${#DNS_BLOCKERS[@]} -gt 0 ]]; then
  RESULT_BLOCKERS=("${DNS_BLOCKERS[@]}")
fi
if [[ -n "$WEBROOT_NOTE" ]]; then
  RESULT_BLOCKERS+=("$WEBROOT_NOTE")
fi

EXECUTE_PLACEHOLDER_BLOCKER=""
if [[ "$EXECUTE" == "1" ]]; then
  EXECUTE_PLACEHOLDER_BLOCKER="execute path not implemented: 当前 --execute 仅为占位语义，不会真实签发证书"
  RESULT_BLOCKERS+=("$EXECUTE_PLACEHOLDER_BLOCKER")
  FINAL_STATUS="blocked"
  NEXT_STEP="如需真实签发，请先设计并实现独立 execute 子路径（落成 ACME-ISSUANCE-RESULT.{md,json} companion contract，含 ACME client / challenge fulfillment / 证书落盘 / 可控部署边界），而不是复用当前占位 helper。"
  FULFILLED_CHALLENGE_STRATEGY="not-executed"
else
  FINAL_STATUS="needs-attention"
  NEXT_STEP="当前 helper 只输出保守式 issue 计划与契约；请先确认 challenge 路径、acme client 选择与证书落盘/接管边界，并把未来真实签发结果独立收敛到 ACME-ISSUANCE-RESULT.{md,json}，再决定是否实现真实 execute。"
  FULFILLED_CHALLENGE_STRATEGY=""
  if [[ "$DNS_READY" == "true" && "$PORT_80_READY" == "true" ]]; then
    NEXT_STEP="DNS 与 80 端口基础条件看起来已具备；下一步建议把真实签发执行收敛成显式 execute 子路径，并把执行结果独立落成 ACME-ISSUANCE-RESULT.{md,json}，继续保持不默认 reload nginx。"
  fi
fi

write_issue_result_json() {
  local target_json="$1"
  mkdir -p "$(dirname "$target_json")"

  python3 - "$target_json" <<'PY'
import json
import os
import sys
from pathlib import Path


def env(name, default=''):
    return os.environ.get(name, default)

payload = {
    'schema_kind': 'issue-result',
    'schema_version': 1,
    'contract_scope': 'planning-evidence-only',
    'reserved_execute_result': {
        'schema_kind': 'acme-issuance-result',
        'artifact_json': 'ACME-ISSUANCE-RESULT.json',
        'artifact_markdown': 'ACME-ISSUANCE-RESULT.md',
        'status': 'reserved-not-implemented',
    },
    'mode': env('MODE_LABEL'),
    'final_status': env('FINAL_STATUS'),
    'context': {
        'run_id': env('RUN_ID'),
        'deployment_name': env('DEPLOYMENT_NAME'),
        'base_domain': env('BASE_DOMAIN'),
        'domain_mode': env('DOMAIN_MODE'),
        'platform': env('PLATFORM'),
        'tls_mode': env('TLS_MODE'),
    },
    'request': {
        'challenge_mode': env('CHALLENGE_MODE'),
        'webroot': env('WEBROOT_PATH'),
        'acme_client': env('ACME_CLIENT'),
        'account_email': env('ACCOUNT_EMAIL'),
        'staging': env('USE_STAGING') == '1',
    },
    'checks': {
        'derived_hosts': [h for h in env('DERIVED_HOSTS_NL').split('\n') if h],
        'dns_points_to_local_ready': env('DNS_READY') == 'true',
        'port_80_status': env('PORT_80_STATUS'),
        'port_80_ready': env('PORT_80_READY') == 'true',
        'needs_webroot': env('NEEDS_WEBROOT') == 'true',
        'webroot_ready': None if env('WEBROOT_READY') == '' else (env('WEBROOT_READY') == 'true'),
    },
    'phase_boundary': {
        'issues_certificate': False,
        'installs_acme_client': False,
        'modifies_live_nginx': False,
        'reloads_nginx': False,
        'writes_tls_files': False,
    },
    'blockers': [item for item in env('RESULT_BLOCKERS_NL').split('\n') if item],
    'next_step': env('NEXT_STEP'),
}

Path(sys.argv[1]).write_text(json.dumps(payload, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
PY
}

write_issue_result_markdown() {
  local target_file="$1"
  mkdir -p "$(dirname "$target_file")"
  {
    echo '# ISSUE RESULT'
    echo
    echo '## 执行概览'
    echo
    echo "- 模式：$MODE_LABEL"
    echo "- 状态：$FINAL_STATUS"
    echo "- run_id：$RUN_ID"
    echo "- deployment_name：$DEPLOYMENT_NAME"
    echo "- tls_mode：$TLS_MODE"
    echo "- challenge_mode：$CHALLENGE_MODE"
    echo "- acme_client：$ACME_CLIENT"
    echo "- staging：$(if [[ "$USE_STAGING" == "1" ]]; then echo yes; else echo no; fi)"
    echo
    echo '## 基础检查'
    echo
    echo "- DNS 指向本机就绪：$DNS_READY"
    echo "- 80 端口状态：$PORT_80_STATUS"
    if [[ "$NEEDS_WEBROOT" == "true" ]]; then
      echo "- webroot 就绪：$WEBROOT_READY"
      echo "- webroot 路径：$WEBROOT_PATH"
    fi
    echo
    echo '## 派生域名'
    echo
    local host
    for host in "${DERIVED_HOSTS[@]}"; do
      echo "- $host"
    done
    echo
    echo '## 当前阶段边界'
    echo
    echo '- ISSUE-RESULT.{md,json} 永远只承载 planning / evidence 语义'
    echo '- 未来真实签发结果应独立落在 ACME-ISSUANCE-RESULT.{md,json}'
    echo '- 不真正申请证书'
    echo '- 不安装 acme client'
    echo '- 不改动 live nginx'
    echo '- 不 reload nginx'
    echo '- 不写入证书/私钥文件'
    echo
    echo '## Blockers'
    echo
    if [[ ${#RESULT_BLOCKERS[@]} -eq 0 ]]; then
      echo '- 无硬阻断，但当前仍停留在保守式计划阶段'
    else
      local item
      for item in "${RESULT_BLOCKERS[@]}"; do
        echo "- $item"
      done
    fi
    echo
    echo '## 下一步建议'
    echo
    echo "- $NEXT_STEP"
  } > "$target_file"
}

write_acme_issuance_result_json() {
  local target_json="$1"
  mkdir -p "$(dirname "$target_json")"

  python3 - "$target_json" <<'PY'
import json
import os
import sys
from pathlib import Path


def env(name, default=''):
    return os.environ.get(name, default)

payload = {
    'schema_kind': 'acme-issuance-result',
    'schema_version': 1,
    'mode': 'execute',
    'final_status': env('FINAL_STATUS'),
    'context': {
        'run_id': env('RUN_ID'),
        'deployment_name': env('DEPLOYMENT_NAME'),
        'base_domain': env('BASE_DOMAIN'),
        'domain_mode': env('DOMAIN_MODE'),
        'platform': env('PLATFORM'),
        'tls_mode': env('TLS_MODE'),
    },
    'request': {
        'challenge_mode': env('CHALLENGE_MODE'),
        'acme_client': env('ACME_CLIENT'),
        'account_email': env('ACCOUNT_EMAIL'),
        'staging': env('USE_STAGING') == '1',
    },
    'execution': {
        'attempted_hosts': [h for h in env('DERIVED_HOSTS_NL').split('\n') if h],
        'fulfilled_challenge_strategy': env('FULFILLED_CHALLENGE_STRATEGY'),
        'client_invoked': False,
        'issued_certificate': False,
    },
    'artifacts': {
        'cert_path': '',
        'key_path': '',
        'fullchain_path': '',
    },
    'deployment_boundary': {
        'writes_live_tls_paths': False,
        'modifies_live_nginx': False,
        'reloads_nginx': False,
    },
    'recovery': {
        'recoverable': True,
        'blocker_summary': env('EXECUTE_PLACEHOLDER_BLOCKER'),
    },
    'next_step': env('NEXT_STEP'),
}

Path(sys.argv[1]).write_text(json.dumps(payload, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
PY
}

write_acme_issuance_result_markdown() {
  local target_file="$1"
  mkdir -p "$(dirname "$target_file")"
  {
    echo '# ACME ISSUANCE RESULT'
    echo
    echo '## 执行概览'
    echo
    echo '- 当前文件为 execute placeholder result，不代表已真实签发'
    echo '- schema_kind：acme-issuance-result'
    echo '- mode：execute'
    echo "- final_status：$FINAL_STATUS"
    echo "- run_id：$RUN_ID"
    echo "- challenge_mode：$CHALLENGE_MODE"
    echo "- acme_client：$ACME_CLIENT"
    echo
    echo '## 真实执行边界'
    echo
    echo '- client_invoked：false'
    echo '- issued_certificate：false'
    echo '- writes_live_tls_paths：false'
    echo '- modifies_live_nginx：false'
    echo '- reloads_nginx：false'
    echo
    echo '## Placeholder blocker'
    echo
    echo "- $EXECUTE_PLACEHOLDER_BLOCKER"
    echo
    echo '## 下一步建议'
    echo
    echo "- $NEXT_STEP"
  } > "$target_file"
}

export MODE_LABEL FINAL_STATUS RUN_ID DEPLOYMENT_NAME BASE_DOMAIN DOMAIN_MODE PLATFORM TLS_MODE CHALLENGE_MODE WEBROOT_PATH ACME_CLIENT ACCOUNT_EMAIL USE_STAGING DNS_READY PORT_80_STATUS PORT_80_READY NEEDS_WEBROOT WEBROOT_READY WEBROOT_NOTE NEXT_STEP EXECUTE_PLACEHOLDER_BLOCKER FULFILLED_CHALLENGE_STRATEGY
DERIVED_HOSTS_NL="$(printf '%s\n' "${DERIVED_HOSTS[@]}")"
RESULT_BLOCKERS_NL="$(printf '%s\n' "${RESULT_BLOCKERS[@]:-}")"
export DERIVED_HOSTS_NL RESULT_BLOCKERS_NL

write_issue_result_markdown "$RESULT_FILE"
write_issue_result_json "$RESULT_JSON_OUTPUT"
if [[ "$EXECUTE" == "1" ]]; then
  write_acme_issuance_result_markdown "$ACME_ISSUANCE_RESULT_FILE"
  write_acme_issuance_result_json "$ACME_ISSUANCE_RESULT_JSON_PATH"
  state_record_companion_result "acme_issuance" "$ACME_ISSUANCE_RESULT_FILE" "$ACME_ISSUANCE_RESULT_JSON_PATH" "$FINAL_STATUS" "acme issuance execute placeholder recorded" "acme_issuance"
fi
state_record_companion_result "issue" "$RESULT_FILE" "$RESULT_JSON_OUTPUT" "$FINAL_STATUS" "issue result recorded"

cat <<EOF
[issue-http01] 当前模式：$MODE_LABEL
[issue-http01] 来源 state.json：$STATE_JSON
[issue-http01] 结果摘要文件：$RESULT_FILE
[issue-http01] 结果 JSON 文件：$RESULT_JSON_OUTPUT
$(if [[ "$EXECUTE" == "1" ]]; then printf '%s\n%s\n' "[issue-http01] execute placeholder：$ACME_ISSUANCE_RESULT_FILE" "[issue-http01] execute placeholder JSON：$ACME_ISSUANCE_RESULT_JSON_PATH"; fi)[issue-http01] DNS ready：$DNS_READY
[issue-http01] port 80 status：$PORT_80_STATUS
[issue-http01] 最终状态：$FINAL_STATUS
[issue-http01] 下一步：$NEXT_STEP
EOF
