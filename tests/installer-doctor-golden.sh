#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_DIR="$ROOT_DIR/tests/fixtures/installer-contracts/template"
GOLDEN_DIR="$ROOT_DIR/tests/fixtures/installer-contracts/doctor-golden"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

RUN_IDS=(
  fixture-legacy-fallback
  fixture-resumed-repair-review
  fixture-current-apply-attention
  fixture-post-repair-verification
  fixture-post-rollback-inspection
  fixture-inspect-after-apply-attention
  fixture-missing-source-state
  fixture-tls-acme-http01
)

materialize_fixtures() {
  python3 - "$TEMPLATE_DIR" "$WORKDIR" <<'PY'
import sys
from pathlib import Path

template_dir = Path(sys.argv[1])
workdir = Path(sys.argv[2])
placeholder = "__FIXTURE_ROOT__"

for src in template_dir.rglob("*"):
    rel = src.relative_to(template_dir)
    dest = workdir / rel
    if src.is_dir():
        dest.mkdir(parents=True, exist_ok=True)
        continue
    text = src.read_text(encoding="utf-8")
    text = text.replace(placeholder, str(workdir))
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(text, encoding="utf-8")
PY
}

normalize_doctor_output() {
  DOCTOR_OUTPUT="$1" python3 - "$WORKDIR" <<'PY'
import os
import sys

workdir = sys.argv[1]
text = os.environ.get("DOCTOR_OUTPUT", "").replace(workdir, "__FIXTURE_ROOT__")

keep_headers = {
    "[doctor] 运行摘要",
    "[doctor] lineage 摘要",
    "[doctor] lineage chain",
    "[doctor] 当前 run 异常摘要",
    "[doctor] 状态",
    "[doctor] apply result json",
    "[doctor] acme issuance result json",
    "[doctor] repair result json",
    "[doctor] rollback result json",
    "[doctor] journal",
    "[doctor] 下一步建议",
}

keep_prefixes = (
    "- run_id:",
    "- checkpoint:",
    "- resumed_from:",
    "- current_run_alerts:",
    "- current_run_priority_artifact:",
    "- current_run_priority_note:",
    "- lineage.mode:",
    "- lineage.is_resumed_run:",
    "- lineage.source_run_id:",
    "- lineage.source_checkpoint:",
    "- lineage.source_resumed_from:",
    "- lineage.resume_strategy:",
    "- lineage.resume_strategy_reason:",
    "- apply_execute:",
    "- repair:",
    "- rollback:",
    "- final:",
    "- path:",
    "- mode:",
    "- final_status:",
    "- nginx_test.requested:",
    "- nginx_test.status:",
    "- recovery.installer_status:",
    "- recovery.resume_strategy:",
    "- recovery.resume_recommended:",
    "- recovery.operator_action:",
    "- intent.result_role:",
    "- intent.real_execution_performed:",
    "- request.challenge_mode:",
    "- request.acme_client:",
    "- request.staging:",
    "- pending_execution_plan.planned_target_hosts:",
    "- pending_execution_plan.planned_challenge_mode:",
    "- pending_execution_plan.planned_challenge_fulfillment:",
    "- pending_execution_plan.planned_acme_client:",
    "- pending_execution_plan.planned_acme_directory:",
    "- execution.client_invoked:",
    "- execution.issued_certificate:",
    "- deployment_boundary.writes_live_tls_paths:",
    "- deployment_boundary.modifies_live_nginx:",
    "- deployment_boundary.reloads_nginx:",
    "- operator_prerequisites.pending:",
    "- source_recovery.installer_status:",
    "- source_recovery.resume_strategy:",
    "- source_recovery.resume_recommended:",
    "- source_recovery.operator_action:",
    "- execution.nginx_test_rerun_status:",
    "- flags.execute:",
    "- next_step:",
    "- entries:",
    "- last_event:",
    "- last_message:",
    "- 当前 resume 策略：",
    "- 触发原因：",
    "- 当前已解析到 ",
    "- 操作建议：",
    "- 当前策略优先产物：",
    "- 说明：",
    "- 最近的异常祖先节点：",
    "- 祖先参考产物：",
    "- depth:",
    "- 1. [current]",
    "- 2. [ancestor-1]",
    "- 3. [ancestor-2]",
    "- 当前 run 存在异常状态：",
    "- 优先查看产物：",
    "- 这是一轮 resumed run：",
    "- 这不是 resumed run；",
    "- 源运行本身不是已记录的 resumed run，当前链路到此为止。",
    "- 输入快照可用于 resume：",
)

selected = []
in_next_step_section = False
for raw_line in text.splitlines():
    line = raw_line.rstrip()
    if line == "[doctor] 下一步建议":
        selected.append(line)
        in_next_step_section = True
        continue
    if line.startswith("[doctor]"):
        in_next_step_section = False
        if line in keep_headers:
            selected.append(line)
        continue
    if not line:
        continue
    if in_next_step_section and line.startswith("- "):
        selected.append(line)
        continue
    if line in keep_headers or any(line.startswith(prefix) for prefix in keep_prefixes):
        selected.append(line)

sys.stdout.write("\n".join(selected) + "\n")
PY
}

assert_golden() {
  local run_id="$1"
  local output="$2"
  local golden_path="$GOLDEN_DIR/$run_id.golden.txt"

  if [[ "${UPDATE_GOLDEN:-0}" == "1" ]]; then
    mkdir -p "$GOLDEN_DIR"
    printf '%s' "$output" > "$golden_path"
    return 0
  fi

  if [[ ! -f "$golden_path" ]]; then
    echo "[FAIL] missing doctor golden: $golden_path" >&2
    echo "       hint: UPDATE_GOLDEN=1 bash tests/installer-doctor-golden.sh" >&2
    return 1
  fi

  if ! diff -u "$golden_path" <(printf '%s' "$output"); then
    echo "[FAIL] doctor golden mismatch: $run_id" >&2
    return 1
  fi
}

materialize_fixtures

bash "$ROOT_DIR/acme-issue-http01.sh" \
  --state-json "$WORKDIR/runs/fixture-tls-acme-http01/state.json" \
  --execute \
  --challenge-mode standalone \
  --acme-client manual \
  --staging >/dev/null

source "$ROOT_DIR/scripts/lib/status-contracts.sh"
source "$ROOT_DIR/scripts/lib/state.sh"
RUNS_ROOT_DIR="$WORKDIR/runs"

for run_id in "${RUN_IDS[@]}"; do
  doctor_output="$(state_doctor "$run_id")"
  normalized_output="$(normalize_doctor_output "$doctor_output")"
  assert_golden "$run_id" "$normalized_output"
done

echo "[PASS] installer doctor golden"
