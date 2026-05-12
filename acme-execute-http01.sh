#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./acme-execute-http01.sh \
    --issue-result-json <path> \
    [--result-file <path>]

Current stage:
  - Conservative ACME execute helper cut 1
  - Consumes existing ISSUE-RESULT.json (planning / evidence only)
  - Writes ACME-ISSUANCE-RESULT.{md,json} as a non-placeholder execute companion result
  - Still blocked before ACME client invocation
  - Does NOT issue certificates yet
  - Does NOT install acme client
  - Does NOT modify live nginx
  - Does NOT reload nginx
  - Does NOT write certificate/key files
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"

# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/state.sh"

ISSUE_RESULT_JSON=""
RESULT_FILE=""
RESULT_JSON_OUTPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue-result-json)
      ISSUE_RESULT_JSON="$2"; shift 2 ;;
    --result-file)
      RESULT_FILE="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "[acme-execute] Unknown argument: $1" >&2
      usage >&2
      exit 1 ;;
  esac
done

if [[ -z "$ISSUE_RESULT_JSON" ]]; then
  echo "[acme-execute] Missing required argument: --issue-result-json <path>" >&2
  exit 2
fi

if [[ ! -f "$ISSUE_RESULT_JSON" ]]; then
  echo "[acme-execute] ISSUE-RESULT.json not found: $ISSUE_RESULT_JSON" >&2
  exit 3
fi

if [[ -z "$RESULT_FILE" ]]; then
  RESULT_FILE="$(dirname "$ISSUE_RESULT_JSON")/ACME-ISSUANCE-RESULT.md"
fi
RESULT_JSON_OUTPUT="${RESULT_FILE%.md}.json"
if [[ "$RESULT_JSON_OUTPUT" == "$RESULT_FILE" ]]; then
  RESULT_JSON_OUTPUT="$RESULT_FILE.json"
fi

PARSED_JSON="$(mktemp)"
cleanup() {
  rm -f "$PARSED_JSON"
}
trap cleanup EXIT

python3 - "$ISSUE_RESULT_JSON" "$PARSED_JSON" <<'PY'
import json
import sys
from pathlib import Path

issue_result_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])
obj = json.loads(issue_result_path.read_text(encoding='utf-8'))

payload = {
    'schema_kind': obj.get('schema_kind', ''),
    'contract_scope': obj.get('contract_scope', ''),
    'reserved_execute_schema_kind': ((obj.get('reserved_execute_result') or {}).get('schema_kind', '')),
    'reserved_execute_artifact_json': ((obj.get('reserved_execute_result') or {}).get('artifact_json', '')),
    'reserved_execute_artifact_markdown': ((obj.get('reserved_execute_result') or {}).get('artifact_markdown', '')),
    'run_id': ((obj.get('context') or {}).get('run_id', '')),
    'deployment_name': ((obj.get('context') or {}).get('deployment_name', '')),
    'base_domain': ((obj.get('context') or {}).get('base_domain', '')),
    'domain_mode': ((obj.get('context') or {}).get('domain_mode', '')),
    'platform': ((obj.get('context') or {}).get('platform', '')),
    'tls_mode': ((obj.get('context') or {}).get('tls_mode', '')),
    'challenge_mode': ((obj.get('request') or {}).get('challenge_mode', '')),
    'acme_client': ((obj.get('request') or {}).get('acme_client', '')),
    'account_email': ((obj.get('request') or {}).get('account_email', '')),
    'staging': bool((obj.get('request') or {}).get('staging', False)),
    'derived_hosts': ((obj.get('checks') or {}).get('derived_hosts', []) or []),
}

out_path.write_text(json.dumps(payload, ensure_ascii=False), encoding='utf-8')
PY

read_json_field() {
  python3 - "$PARSED_JSON" "$1" <<'PY'
import json
import sys
from pathlib import Path
obj = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
value = obj
for part in sys.argv[2].split('.'):
    if isinstance(value, dict):
        value = value.get(part, '')
    else:
        value = ''
        break
if value is None:
    value = ''
print(value)
PY
}

ISSUE_SCHEMA_KIND="$(read_json_field schema_kind)"
ISSUE_CONTRACT_SCOPE="$(read_json_field contract_scope)"
RESERVED_EXECUTE_SCHEMA_KIND="$(read_json_field reserved_execute_schema_kind)"
RESERVED_EXECUTE_ARTIFACT_JSON="$(read_json_field reserved_execute_artifact_json)"
RESERVED_EXECUTE_ARTIFACT_MARKDOWN="$(read_json_field reserved_execute_artifact_markdown)"
RUN_ID="$(read_json_field run_id)"
DEPLOYMENT_NAME="$(read_json_field deployment_name)"
BASE_DOMAIN="$(read_json_field base_domain)"
DOMAIN_MODE="$(read_json_field domain_mode)"
PLATFORM="$(read_json_field platform)"
TLS_MODE="$(read_json_field tls_mode)"
CHALLENGE_MODE="$(read_json_field challenge_mode)"
ACME_CLIENT="$(read_json_field acme_client)"
ACCOUNT_EMAIL="$(read_json_field account_email)"
USE_STAGING_RAW="$(read_json_field staging)"

case "$ISSUE_SCHEMA_KIND" in
  issue-result) ;;
  *)
    echo "[acme-execute] 输入文件 schema_kind 非 issue-result：$ISSUE_SCHEMA_KIND" >&2
    exit 4
    ;;
esac

if [[ "$ISSUE_CONTRACT_SCOPE" != "planning-evidence-only" ]]; then
  echo "[acme-execute] ISSUE-RESULT.json contract_scope 必须是 planning-evidence-only：$ISSUE_CONTRACT_SCOPE" >&2
  exit 5
fi

if [[ -n "$RESERVED_EXECUTE_SCHEMA_KIND" && "$RESERVED_EXECUTE_SCHEMA_KIND" != "acme-issuance-result" ]]; then
  echo "[acme-execute] reserved_execute_result.schema_kind 非 acme-issuance-result：$RESERVED_EXECUTE_SCHEMA_KIND" >&2
  exit 6
fi

if [[ -n "$RESERVED_EXECUTE_ARTIFACT_JSON" && "$RESERVED_EXECUTE_ARTIFACT_JSON" != "ACME-ISSUANCE-RESULT.json" ]]; then
  echo "[acme-execute] reserved_execute_result.artifact_json 非 ACME-ISSUANCE-RESULT.json：$RESERVED_EXECUTE_ARTIFACT_JSON" >&2
  exit 7
fi

if [[ -n "$RESERVED_EXECUTE_ARTIFACT_MARKDOWN" && "$RESERVED_EXECUTE_ARTIFACT_MARKDOWN" != "ACME-ISSUANCE-RESULT.md" ]]; then
  echo "[acme-execute] reserved_execute_result.artifact_markdown 非 ACME-ISSUANCE-RESULT.md：$RESERVED_EXECUTE_ARTIFACT_MARKDOWN" >&2
  exit 8
fi

if [[ "$TLS_MODE" != "acme-http01" ]]; then
  echo "[acme-execute] 当前 issue result 的 tls_mode=$TLS_MODE，不适用于 HTTP-01 execute helper。" >&2
  exit 9
fi

if [[ -z "$CHALLENGE_MODE" ]]; then
  CHALLENGE_MODE="standalone"
fi

if [[ -z "$ACME_CLIENT" ]]; then
  ACME_CLIENT="manual"
fi

USE_STAGING="0"
case "$USE_STAGING_RAW" in
  True|true|1)
    USE_STAGING="1"
    ;;
  *)
    USE_STAGING="0"
    ;;
esac

MODE_LABEL="execute"
FINAL_STATUS="blocked"
PLACEHOLDER_KIND="future-real-execute"
PLACEHOLDER_SOURCE_OF_TRUTH="independent-pre-client-blocked-helper"
FULFILLED_CHALLENGE_STRATEGY="pre-client-blocked"
BLOCKER_SUMMARY="pre-client blocked: 独立 execute helper 当前只落 non-placeholder companion contract，还不会调用 ACME client 或真实签发证书"
NEXT_STEP="当前 cut 1 只把 execute 语义独立落成 non-placeholder companion result；后续若要真实签发，仍需补 ACME client invocation / challenge fulfillment / certificate artifact write / deployment boundary control。"
ISSUE_RESULT_PATH="$(dirname "$ISSUE_RESULT_JSON")/$(basename "${ISSUE_RESULT_JSON%.json}.md")"

export MODE_LABEL FINAL_STATUS RUN_ID DEPLOYMENT_NAME BASE_DOMAIN DOMAIN_MODE PLATFORM TLS_MODE CHALLENGE_MODE ACME_CLIENT ACCOUNT_EMAIL USE_STAGING PLACEHOLDER_KIND PLACEHOLDER_SOURCE_OF_TRUTH FULFILLED_CHALLENGE_STRATEGY BLOCKER_SUMMARY NEXT_STEP ISSUE_RESULT_JSON ISSUE_RESULT_PATH RESULT_FILE RESULT_JSON_OUTPUT
DERIVED_HOSTS_NL="$(python3 - "$PARSED_JSON" <<'PY'
import json
import sys
from pathlib import Path
obj = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
for item in obj.get('derived_hosts', []) or []:
    if item:
        print(item)
PY
)"
HOSTS_JOINED="$(python3 - "$PARSED_JSON" <<'PY'
import json
import sys
from pathlib import Path
obj = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
hosts = [item for item in (obj.get('derived_hosts', []) or []) if item]
print(' '.join(hosts))
PY
)"
export DERIVED_HOSTS_NL HOSTS_JOINED

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
    'mode': env('MODE_LABEL'),
    'final_status': env('FINAL_STATUS'),
    'placeholder': {
        'is_placeholder': False,
        'placeholder_kind': env('PLACEHOLDER_KIND'),
        'review_required': False,
        'source_of_truth': env('PLACEHOLDER_SOURCE_OF_TRUTH'),
    },
    'planning_reference': {
        'issue_result_json': Path(env('ISSUE_RESULT_JSON')).name,
        'issue_result_markdown': Path(env('ISSUE_RESULT_PATH')).name,
        'contract_scope': 'planning-evidence-only',
    },
    'intent': {
        'result_role': 'real-execute-attempt',
        'requested_operation': 'issue-certificate',
        'requested_mode': 'execute',
        'real_execution_performed': False,
    },
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
    'pending_execution_plan': {
        'planned_target_hosts': [h for h in env('DERIVED_HOSTS_NL').split('\n') if h],
        'planned_challenge_mode': env('CHALLENGE_MODE'),
        'planned_challenge_fulfillment': env('CHALLENGE_MODE'),
        'planned_acme_client': env('ACME_CLIENT'),
        'planned_acme_directory': 'staging' if env('USE_STAGING') == '1' else 'production',
        'planned_artifact_write': 'deferred-until-real-execute',
        'planned_deployment_handoff': 'separate-after-issuance',
    },
    'execution': {
        'attempted_hosts': [h for h in env('DERIVED_HOSTS_NL').split('\n') if h],
        'challenge_strategy': env('CHALLENGE_MODE'),
        'client_adapter': env('ACME_CLIENT'),
        'materialization': 'deferred-until-real-execute',
        'fulfilled_challenge_strategy': env('FULFILLED_CHALLENGE_STRATEGY'),
        'client_invoked': False,
        'issued_certificate': False,
    },
    'artifacts': {
        'materialization': 'not-materialized',
        'cert_path': '',
        'key_path': '',
        'fullchain_path': '',
    },
    'deployment_boundary': {
        'writes_live_tls_paths': False,
        'modifies_live_nginx': False,
        'reloads_nginx': False,
    },
    'operator_prerequisites': {
        'review_issue_result_before_execute': True,
        'implement_real_execute_path': True,
        'confirm_challenge_fulfillment_path': True,
        'confirm_certificate_write_target': True,
        'confirm_deployment_boundary': True,
    },
    'recovery': {
        'recoverable': True,
        'blocker_summary': env('BLOCKER_SUMMARY'),
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
    echo '- 当前文件为独立 execute helper 的 non-placeholder pre-client blocked result；仍不代表真实签发已接通'
    echo '- placeholder.is_placeholder：false'
    echo "- placeholder.placeholder_kind：$PLACEHOLDER_KIND"
    echo '- placeholder.review_required：false'
    echo "- placeholder.source_of_truth：$PLACEHOLDER_SOURCE_OF_TRUTH"
    echo '- schema_kind：acme-issuance-result'
    echo '- mode：execute'
    echo "- final_status：$FINAL_STATUS"
    echo "- run_id：$RUN_ID"
    echo "- challenge_mode：$CHALLENGE_MODE"
    echo "- acme_client：$ACME_CLIENT"
    echo
    echo '## Intent 语义'
    echo
    echo '- result_role：real-execute-attempt'
    echo '- requested_operation：issue-certificate'
    echo '- requested_mode：execute'
    echo '- real_execution_performed：false'
    echo '- planning_reference：ISSUE-RESULT.{md,json}（planning-evidence-only）'
    echo
    echo '## Pending execution plan'
    echo
    echo "- planned_target_hosts：$HOSTS_JOINED"
    echo "- planned_challenge_mode：$CHALLENGE_MODE"
    echo "- planned_challenge_fulfillment：$CHALLENGE_MODE"
    echo "- planned_acme_client：$ACME_CLIENT"
    echo "- planned_acme_directory：$(if [[ "$USE_STAGING" == "1" ]]; then echo staging; else echo production; fi)"
    echo '- planned_artifact_write：deferred-until-real-execute'
    echo '- planned_deployment_handoff：separate-after-issuance'
    echo
    echo '## 真实执行边界'
    echo
    echo "- challenge_strategy：$CHALLENGE_MODE"
    echo "- client_adapter：$ACME_CLIENT"
    echo '- materialization：deferred-until-real-execute'
    echo '- client_invoked：false'
    echo '- issued_certificate：false'
    echo '- writes_live_tls_paths：false'
    echo '- modifies_live_nginx：false'
    echo '- reloads_nginx：false'
    echo
    echo '## Operator prerequisites'
    echo
    echo '- review_issue_result_before_execute：true'
    echo '- implement_real_execute_path：true'
    echo '- confirm_challenge_fulfillment_path：true'
    echo '- confirm_certificate_write_target：true'
    echo '- confirm_deployment_boundary：true'
    echo
    echo '## Pre-client blocker'
    echo
    echo "- $BLOCKER_SUMMARY"
    echo
    echo '## 下一步建议'
    echo
    echo "- $NEXT_STEP"
  } > "$target_file"
}

write_acme_issuance_result_markdown "$RESULT_FILE"
write_acme_issuance_result_json "$RESULT_JSON_OUTPUT"

STATE_JSON_HINT="$(python3 - "$(dirname "$ISSUE_RESULT_JSON")/INSTALLER-SUMMARY.json" <<'PY'
import json
import sys
from pathlib import Path

summary_path = Path(sys.argv[1])
if not summary_path.exists():
    print("")
    raise SystemExit(0)

data = json.loads(summary_path.read_text(encoding="utf-8"))
artifacts = data.get("artifacts") or {}
print(artifacts.get("state_json", ""))
PY
)"
if [[ -n "$STATE_JSON_HINT" && -f "$STATE_JSON_HINT" ]]; then
  STATE_JSON_PATH="$STATE_JSON_HINT"
  STATE_JOURNAL_PATH="$(dirname "$STATE_JSON_HINT")/journal.jsonl"
  state_record_companion_result "acme_issuance" "$RESULT_FILE" "$RESULT_JSON_OUTPUT" "$FINAL_STATUS" "acme issuance result recorded"
fi

cat <<EOF
[acme-execute] 来源 ISSUE-RESULT.json：$ISSUE_RESULT_JSON
[acme-execute] 结果摘要文件：$RESULT_FILE
[acme-execute] 结果 JSON 文件：$RESULT_JSON_OUTPUT
[acme-execute] 结果角色：real-execute-attempt
[acme-execute] ACME client invoked：false
[acme-execute] 最终状态：$FINAL_STATUS
[acme-execute] 下一步：$NEXT_STEP
EOF
