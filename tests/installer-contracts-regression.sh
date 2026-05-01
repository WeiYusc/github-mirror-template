#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_DIR="$ROOT_DIR/tests/fixtures/installer-contracts/template"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

materialize_fixtures() {
  python3 - "$TEMPLATE_DIR" "$WORKDIR" <<'PY'
import shutil
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

assert_equals() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "[FAIL] $label" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    return 1
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "[FAIL] $label" >&2
    echo "  missing substring: $needle" >&2
    return 1
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "[FAIL] $label" >&2
    echo "  unexpected substring: $needle" >&2
    return 1
  fi
}

extract_doctor_next_step_section() {
  python3 -c '
import sys
text = sys.stdin.read()
marker = "[doctor] 下一步建议"
idx = text.find(marker)
if idx == -1:
    sys.stdout.write(text)
else:
    sys.stdout.write(text[idx:])
'
}

bool_01_to_python_bool_text() {
  local value="$1"
  if [[ "$value" == "1" ]]; then
    printf 'True\n'
  else
    printf 'False\n'
  fi
}

assert_contract_file() {
  local path="$1"
  local expected_kind="$2"
  python3 - "$path" "$expected_kind" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
expected_kind = sys.argv[2]
obj = json.loads(path.read_text(encoding="utf-8"))
actual_kind = obj.get("schema_kind")
actual_version = obj.get("schema_version")
if actual_kind != expected_kind:
    raise SystemExit(f"[FAIL] {path}: schema_kind expected {expected_kind!r}, got {actual_kind!r}")
if actual_version != 1:
    raise SystemExit(f"[FAIL] {path}: schema_version expected 1, got {actual_version!r}")
PY
}

assert_json_paths() {
  local path="$1"
  local label="$2"
  shift 2
  python3 - "$path" "$label" "$@" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
label = sys.argv[2]
required_paths = sys.argv[3:]
obj = json.loads(path.read_text(encoding="utf-8"))


def has_path(current, dotted):
    value = current
    for part in dotted.split('.'):
        if not isinstance(value, dict) or part not in value:
            return False
        value = value[part]
    return True

missing = [item for item in required_paths if not has_path(obj, item)]
if missing:
    raise SystemExit(f"[FAIL] {label}: missing paths: {', '.join(missing)}")
PY
}

assert_json_value_in() {
  local path="$1"
  local dotted="$2"
  local label="$3"
  shift 3
  python3 - "$path" "$dotted" "$label" "$@" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
dotted = sys.argv[2]
label = sys.argv[3]
allowed = sys.argv[4:]
obj = json.loads(path.read_text(encoding="utf-8"))
value = obj
for part in dotted.split('.'):
    if not isinstance(value, dict) or part not in value:
        raise SystemExit(f"[FAIL] {label}: missing path {dotted}")
    value = value[part]
value_as_text = str(value)
if value_as_text not in allowed:
    raise SystemExit(
        f"[FAIL] {label}: expected {dotted} in {allowed!r}, got {value_as_text!r}"
    )
PY
}

assert_json_value_type() {
  local path="$1"
  local dotted="$2"
  local expected_type="$3"
  local label="$4"
  python3 - "$path" "$dotted" "$expected_type" "$label" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
dotted = sys.argv[2]
expected_type = sys.argv[3]
label = sys.argv[4]
obj = json.loads(path.read_text(encoding="utf-8"))
value = obj
for part in dotted.split('.'):
    if not isinstance(value, dict) or part not in value:
        raise SystemExit(f"[FAIL] {label}: missing path {dotted}")
    value = value[part]

if expected_type == 'bool' and isinstance(value, bool):
    raise SystemExit(0)
if expected_type == 'int' and isinstance(value, int) and not isinstance(value, bool):
    raise SystemExit(0)
if expected_type == 'string' and isinstance(value, str):
    raise SystemExit(0)
raise SystemExit(
    f"[FAIL] {label}: expected {dotted} type {expected_type}, got {type(value).__name__}"
)
PY
}

assert_json_value_equals() {
  local path="$1"
  local dotted="$2"
  local expected="$3"
  local label="$4"
  python3 - "$path" "$dotted" "$expected" "$label" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
dotted = sys.argv[2]
expected = sys.argv[3]
label = sys.argv[4]
obj = json.loads(path.read_text(encoding="utf-8"))
value = obj
for part in dotted.split('.'):
    if not isinstance(value, dict) or part not in value:
        raise SystemExit(f"[FAIL] {label}: missing path {dotted}")
    value = value[part]
value_as_text = str(value)
if value_as_text != expected:
    raise SystemExit(
        f"[FAIL] {label}: expected {dotted} == {expected!r}, got {value_as_text!r}"
    )
PY
}

assert_json_array_contains() {
  local path="$1"
  local dotted="$2"
  local expected="$3"
  local label="$4"
  python3 - "$path" "$dotted" "$expected" "$label" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
dotted = sys.argv[2]
expected = sys.argv[3]
label = sys.argv[4]
obj = json.loads(path.read_text(encoding="utf-8"))
value = obj
for part in dotted.split('.'):
    if not isinstance(value, dict) or part not in value:
        raise SystemExit(f"[FAIL] {label}: missing path {dotted}")
    value = value[part]
if not isinstance(value, list):
    raise SystemExit(f"[FAIL] {label}: expected {dotted} to be list, got {type(value).__name__}")
if expected not in [str(item) for item in value]:
    raise SystemExit(
        f"[FAIL] {label}: expected {dotted} to contain {expected!r}, got {value!r}"
    )
PY
}

assert_json_value_in_contract() {
  local path="$1"
  local dotted="$2"
  local label="$3"
  local contract_name="$4"
  local var_name
  var_name="$(installer_status_values_var_name "$contract_name")"
  local -n allowed_ref="$var_name"
  assert_json_value_in "$path" "$dotted" "$label" "${allowed_ref[@]}"
}

check_contract_set() {
  local run_id="$1"
  local artifact_root="$WORKDIR/artifacts/$run_id"
  assert_contract_file "$WORKDIR/runs/$run_id/state.json" "installer-state"
  assert_contract_file "$artifact_root/INSTALLER-SUMMARY.json" "installer-summary"
  assert_contract_file "$artifact_root/APPLY-PLAN.json" "apply-plan"
  assert_contract_file "$artifact_root/APPLY-RESULT.json" "apply-result"
  assert_contract_file "$artifact_root/REPAIR-RESULT.json" "repair-result"
  assert_contract_file "$artifact_root/ROLLBACK-RESULT.json" "rollback-result"
}

check_stable_contract_smoke_matrix() {
  local run_id="$1"
  local run_root="$WORKDIR/runs/$run_id"
  local artifact_root="$WORKDIR/artifacts/$run_id"

  assert_json_paths "$run_root/state.json" "$run_id state stable paths" \
    run_id updated_at checkpoint status artifacts inputs flags lineage \
    status.preflight status.generator status.apply_plan status.apply_dry_run status.apply_execute status.repair status.final \
    artifacts.apply_result_json artifacts.summary_output artifacts.state_json artifacts.inputs_env artifacts.journal_jsonl \
    lineage.mode lineage.resume_strategy lineage.resume_strategy_reason

  assert_json_paths "$artifact_root/INSTALLER-SUMMARY.json" "$run_id installer summary stable paths" \
    deployment_name base_domain domain_mode platform input_mode flags status artifacts \
    flags.assume_yes flags.execute_apply flags.run_apply_dry_run \
    status.preflight status.generator status.apply_plan status.final \
    artifacts.apply_plan_json artifacts.apply_result_json artifacts.state_json artifacts.summary_output

  assert_json_paths "$artifact_root/APPLY-PLAN.json" "$run_id apply plan stable paths" \
    mode platform paths summary items \
    paths.from paths.snippets_target paths.vhost_target paths.error_root \
    summary.new summary.replace summary.same summary.conflict summary.target_block summary.missing_source summary.has_blockers

  assert_json_paths "$artifact_root/APPLY-RESULT.json" "$run_id apply result stable paths" \
    mode platform final_status summary recovery next_step execution nginx_test targets items \
    recovery.installer_status recovery.resume_strategy recovery.resume_recommended recovery.operator_action \
    execution.backup_status execution.copy_status execution.reload_performed \
    nginx_test.requested nginx_test.status \
    summary.new summary.replace summary.same summary.conflict summary.target_block summary.missing_source

  assert_json_paths "$artifact_root/REPAIR-RESULT.json" "$run_id repair result stable paths" \
    mode platform final_status source_apply_result source_mode source_final_status source_recovery execution diagnosis next_step source_summary items \
    source_recovery.installer_status source_recovery.resume_strategy source_recovery.resume_recommended source_recovery.operator_action \
    execution.nginx_test_rerun_status execution.nginx_test_rerun_exit_code \
    diagnosis.items_total diagnosis.targets_present diagnosis.targets_missing diagnosis.targets_non_regular diagnosis.replace_backups_present diagnosis.replace_backups_missing

  assert_json_paths "$artifact_root/ROLLBACK-RESULT.json" "$run_id rollback result stable paths" \
    mode platform final_status source_apply_result source_mode source_final_status flags summary next_step source_summary items \
    flags.delete_new flags.execute \
    summary.restore summary.delete summary.skip summary.blocked summary.pending summary.restored summary.deleted
}

check_contract_value_smoke_matrix() {
  local run_id="$1"
  local run_root="$WORKDIR/runs/$run_id"
  local artifact_root="$WORKDIR/artifacts/$run_id"

  assert_json_value_in "$run_root/state.json" "lineage.mode" "$run_id state lineage mode enum" new resume
  assert_json_value_in "$run_root/state.json" "lineage.resume_strategy" "$run_id state resume strategy enum" \
    fresh repair-review-first post-rollback-inspection post-repair-verification inspect-after-apply-attention
  assert_json_value_in_contract "$run_root/state.json" "status.preflight" "$run_id state preflight enum" preflight
  assert_json_value_in_contract "$run_root/state.json" "status.generator" "$run_id state generator enum" generator
  assert_json_value_in_contract "$run_root/state.json" "status.apply_plan" "$run_id state apply plan enum" apply_plan
  assert_json_value_in_contract "$run_root/state.json" "status.apply_dry_run" "$run_id state apply dry run enum" apply_dry_run
  assert_json_value_in_contract "$run_root/state.json" "status.apply_execute" "$run_id state apply execute enum" apply_execute
  assert_json_value_in_contract "$run_root/state.json" "status.repair" "$run_id state repair enum" repair
  assert_json_value_in_contract "$run_root/state.json" "status.final" "$run_id state final enum" final

  assert_json_value_type "$artifact_root/INSTALLER-SUMMARY.json" "flags.assume_yes" bool "$run_id summary assume_yes bool"
  assert_json_value_type "$artifact_root/INSTALLER-SUMMARY.json" "flags.execute_apply" bool "$run_id summary execute_apply bool"
  assert_json_value_type "$artifact_root/INSTALLER-SUMMARY.json" "flags.run_apply_dry_run" bool "$run_id summary run_apply_dry_run bool"
  assert_json_value_type "$artifact_root/INSTALLER-SUMMARY.json" "flags.run_nginx_test_after_execute" bool "$run_id summary run_nginx_test_after_execute bool"
  assert_json_value_in_contract "$artifact_root/INSTALLER-SUMMARY.json" "status.preflight" "$run_id summary preflight enum" preflight
  assert_json_value_in_contract "$artifact_root/INSTALLER-SUMMARY.json" "status.generator" "$run_id summary generator enum" generator
  assert_json_value_in_contract "$artifact_root/INSTALLER-SUMMARY.json" "status.apply_plan" "$run_id summary apply plan enum" apply_plan
  assert_json_value_in_contract "$artifact_root/INSTALLER-SUMMARY.json" "status.apply_execute" "$run_id summary apply execute enum" apply_execute
  assert_json_value_in_contract "$artifact_root/INSTALLER-SUMMARY.json" "status.final" "$run_id summary final enum" final

  assert_json_value_in "$artifact_root/APPLY-RESULT.json" "mode" "$run_id apply result mode enum" dry-run execute
  assert_json_value_in "$artifact_root/APPLY-RESULT.json" "final_status" "$run_id apply result final status enum" ok needs-attention
  assert_json_value_in "$artifact_root/APPLY-RESULT.json" "recovery.installer_status" "$run_id apply result installer status enum" success needs-attention
  assert_json_value_in "$artifact_root/APPLY-RESULT.json" "recovery.resume_strategy" "$run_id apply result resume strategy enum" \
    post-apply-review dry-run-ok repair-review-first manual-recovery-first
  assert_json_value_type "$artifact_root/APPLY-RESULT.json" "recovery.resume_recommended" bool "$run_id apply result resume recommended bool"
  assert_json_value_type "$artifact_root/APPLY-RESULT.json" "execution.reload_performed" bool "$run_id apply result reload_performed bool"
  assert_json_value_type "$artifact_root/APPLY-RESULT.json" "nginx_test.requested" bool "$run_id apply result nginx requested bool"
  assert_json_value_in "$artifact_root/APPLY-RESULT.json" "nginx_test.status" "$run_id apply result nginx status enum" 0 failed not-run

  assert_json_value_in "$artifact_root/REPAIR-RESULT.json" "mode" "$run_id repair result mode enum" dry-run execute
  assert_json_value_in "$artifact_root/REPAIR-RESULT.json" "final_status" "$run_id repair result final status enum" ok needs-attention blocked
  assert_json_value_in "$artifact_root/REPAIR-RESULT.json" "source_final_status" "$run_id repair result source final status enum" ok needs-attention
  assert_json_value_in "$artifact_root/REPAIR-RESULT.json" "source_recovery.resume_strategy" "$run_id repair result source resume strategy enum" \
    "" manual-recovery-first repair-review-first
  assert_json_value_type "$artifact_root/REPAIR-RESULT.json" "source_recovery.resume_recommended" bool "$run_id repair result source resume recommended bool"
  assert_json_value_in "$artifact_root/REPAIR-RESULT.json" "execution.nginx_test_rerun_status" "$run_id repair result nginx rerun status enum" not-run passed
  assert_json_value_in "$artifact_root/REPAIR-RESULT.json" "execution.nginx_test_rerun_exit_code" "$run_id repair result nginx rerun exit code enum" "" 0

  assert_json_value_in "$artifact_root/ROLLBACK-RESULT.json" "mode" "$run_id rollback result mode enum" dry-run execute
  assert_json_value_in "$artifact_root/ROLLBACK-RESULT.json" "final_status" "$run_id rollback result final status enum" ok
  assert_json_value_type "$artifact_root/ROLLBACK-RESULT.json" "flags.execute" bool "$run_id rollback result flags.execute bool"
  assert_json_value_type "$artifact_root/ROLLBACK-RESULT.json" "flags.delete_new" bool "$run_id rollback result flags.delete_new bool"
  assert_json_value_type "$artifact_root/ROLLBACK-RESULT.json" "summary.blocked" int "$run_id rollback result summary.blocked int"
  assert_json_value_type "$artifact_root/ROLLBACK-RESULT.json" "summary.pending" int "$run_id rollback result summary.pending int"
  assert_json_value_type "$artifact_root/ROLLBACK-RESULT.json" "summary.restored" int "$run_id rollback result summary.restored int"
  assert_json_value_type "$artifact_root/ROLLBACK-RESULT.json" "summary.deleted" int "$run_id rollback result summary.deleted int"
}

check_per_run_artifact_snapshot_contract() {
  local run_id="$1"
  local run_root="$WORKDIR/runs/$run_id"
  local artifact_root="$WORKDIR/artifacts/$run_id"

  assert_json_value_equals "$run_root/state.json" "artifacts.config" "$artifact_root/deploy.generated.yaml" "$run_id state config points to run-scoped snapshot"
  assert_json_value_equals "$run_root/state.json" "artifacts.preflight_markdown" "$artifact_root/preflight.generated.md" "$run_id state preflight markdown points to run-scoped snapshot"
  assert_json_value_equals "$run_root/state.json" "artifacts.preflight_json" "$artifact_root/preflight.generated.json" "$run_id state preflight json points to run-scoped snapshot"
  assert_json_value_equals "$run_root/state.json" "artifacts.summary_generated" "$artifact_root/INSTALLER-SUMMARY.generated.json" "$run_id state summary_generated points to run-scoped snapshot"

  assert_json_value_equals "$artifact_root/INSTALLER-SUMMARY.json" "artifacts.config" "$artifact_root/deploy.generated.yaml" "$run_id summary config points to run-scoped snapshot"
  assert_json_value_equals "$artifact_root/INSTALLER-SUMMARY.json" "artifacts.preflight_markdown" "$artifact_root/preflight.generated.md" "$run_id summary preflight markdown points to run-scoped snapshot"
  assert_json_value_equals "$artifact_root/INSTALLER-SUMMARY.json" "artifacts.preflight_json" "$artifact_root/preflight.generated.json" "$run_id summary preflight json points to run-scoped snapshot"
  assert_json_value_equals "$artifact_root/INSTALLER-SUMMARY.json" "artifacts.summary_generated" "$artifact_root/INSTALLER-SUMMARY.generated.json" "$run_id summary summary_generated points to run-scoped snapshot"
}

check_tls_plan_artifact_contract() {
  local run_id="$1"
  local tls_mode="$2"
  local run_root="$WORKDIR/runs/$run_id"
  local artifact_root="$WORKDIR/artifacts/$run_id"

  assert_contract_file "$run_root/state.json" "installer-state"
  assert_contract_file "$artifact_root/INSTALLER-SUMMARY.json" "installer-summary"
  assert_json_paths "$run_root/state.json" "$run_id tls plan state paths" \
    inputs.tls_mode artifacts.tls_plan_markdown artifacts.tls_plan_json artifacts.summary_output
  assert_json_paths "$artifact_root/INSTALLER-SUMMARY.json" "$run_id tls plan summary paths" \
    tls_mode artifacts.tls_plan_markdown artifacts.tls_plan_json artifacts.summary_output
  assert_json_value_equals "$run_root/state.json" "inputs.tls_mode" "$tls_mode" "$run_id state records tls mode"
  assert_json_value_equals "$artifact_root/INSTALLER-SUMMARY.json" "tls_mode" "$tls_mode" "$run_id summary records tls mode"
  assert_json_value_equals "$run_root/state.json" "artifacts.tls_plan_markdown" "$artifact_root/TLS-PLAN.generated.md" "$run_id state tls plan markdown snapshot"
  assert_json_value_equals "$run_root/state.json" "artifacts.tls_plan_json" "$artifact_root/TLS-PLAN.generated.json" "$run_id state tls plan json snapshot"
  assert_json_value_equals "$artifact_root/INSTALLER-SUMMARY.json" "artifacts.tls_plan_markdown" "$artifact_root/TLS-PLAN.generated.md" "$run_id summary tls plan markdown snapshot"
  assert_json_value_equals "$artifact_root/INSTALLER-SUMMARY.json" "artifacts.tls_plan_json" "$artifact_root/TLS-PLAN.generated.json" "$run_id summary tls plan json snapshot"
}

check_acme_issue_http01_helper_contract() {
  local run_id="fixture-tls-acme-http01"
  local run_root="$WORKDIR/runs/$run_id"
  local artifact_root="$WORKDIR/artifacts/$run_id"

  bash "$ROOT_DIR/acme-issue-http01.sh" \
    --state-json "$run_root/state.json" \
    --dry-run \
    --challenge-mode standalone \
    --acme-client manual \
    --staging >/dev/null

  assert_contract_file "$artifact_root/ISSUE-RESULT.json" "issue-result"
  assert_json_paths "$artifact_root/ISSUE-RESULT.json" "$run_id issue result stable paths" \
    mode final_status context.run_id context.tls_mode request.challenge_mode request.acme_client request.staging \
    checks.derived_hosts checks.dns_points_to_local_ready checks.port_80_status checks.port_80_ready checks.needs_webroot \
    phase_boundary.issues_certificate phase_boundary.installs_acme_client phase_boundary.modifies_live_nginx phase_boundary.reloads_nginx phase_boundary.writes_tls_files \
    blockers next_step
  assert_json_value_in "$artifact_root/ISSUE-RESULT.json" "mode" "$run_id issue result mode enum" dry-run execute
  assert_json_value_in "$artifact_root/ISSUE-RESULT.json" "final_status" "$run_id issue result final status enum" needs-attention blocked ok
  assert_json_value_equals "$artifact_root/ISSUE-RESULT.json" "context.run_id" "$run_id" "$run_id issue result context run id"
  assert_json_value_equals "$artifact_root/ISSUE-RESULT.json" "context.tls_mode" "acme-http01" "$run_id issue result context tls mode"
  assert_json_value_equals "$artifact_root/ISSUE-RESULT.json" "request.challenge_mode" "standalone" "$run_id issue result challenge mode"
  assert_json_value_equals "$artifact_root/ISSUE-RESULT.json" "request.acme_client" "manual" "$run_id issue result acme client"
  assert_json_value_type "$artifact_root/ISSUE-RESULT.json" "request.staging" bool "$run_id issue result staging bool"
  assert_json_value_type "$artifact_root/ISSUE-RESULT.json" "checks.dns_points_to_local_ready" bool "$run_id issue result dns ready bool"
  assert_json_value_in "$artifact_root/ISSUE-RESULT.json" "checks.port_80_status" "$run_id issue result port 80 status enum" listening not-listening unknown
  assert_json_value_type "$artifact_root/ISSUE-RESULT.json" "checks.port_80_ready" bool "$run_id issue result port 80 ready bool"
  assert_json_value_type "$artifact_root/ISSUE-RESULT.json" "checks.needs_webroot" bool "$run_id issue result needs webroot bool"
  assert_json_value_type "$artifact_root/ISSUE-RESULT.json" "phase_boundary.issues_certificate" bool "$run_id issue result issues_certificate bool"
  assert_json_value_type "$artifact_root/ISSUE-RESULT.json" "phase_boundary.installs_acme_client" bool "$run_id issue result installs_acme_client bool"
  assert_json_value_type "$artifact_root/ISSUE-RESULT.json" "phase_boundary.modifies_live_nginx" bool "$run_id issue result modifies_live_nginx bool"
  assert_json_value_type "$artifact_root/ISSUE-RESULT.json" "phase_boundary.reloads_nginx" bool "$run_id issue result reloads_nginx bool"
  assert_json_value_type "$artifact_root/ISSUE-RESULT.json" "phase_boundary.writes_tls_files" bool "$run_id issue result writes_tls_files bool"

  assert_json_value_equals "$run_root/state.json" "artifacts.issue_result" "$artifact_root/ISSUE-RESULT.md" "$run_id state issue result markdown snapshot"
  assert_json_value_equals "$run_root/state.json" "artifacts.issue_result_json" "$artifact_root/ISSUE-RESULT.json" "$run_id state issue result json snapshot"
  assert_json_value_equals "$artifact_root/INSTALLER-SUMMARY.generated.json" "artifacts.issue_result" "$artifact_root/ISSUE-RESULT.md" "$run_id generated summary issue result markdown snapshot"
  assert_json_value_equals "$artifact_root/INSTALLER-SUMMARY.generated.json" "artifacts.issue_result_json" "$artifact_root/ISSUE-RESULT.json" "$run_id generated summary issue result json snapshot"
  assert_json_value_equals "$artifact_root/INSTALLER-SUMMARY.json" "artifacts.issue_result" "$artifact_root/ISSUE-RESULT.md" "$run_id summary issue result markdown snapshot"
  assert_json_value_equals "$artifact_root/INSTALLER-SUMMARY.json" "artifacts.issue_result_json" "$artifact_root/ISSUE-RESULT.json" "$run_id summary issue result json snapshot"

  assert_journal_event_path_equals_state_artifact "$run_id" "issue.result.recorded" "issue_result_json" "$run_id issue.result.recorded path points to issue_result_json"
}

check_acme_issue_http01_helper_execute_contract() {
  local run_id="fixture-tls-acme-http01"
  local run_root="$WORKDIR/runs/$run_id"
  local artifact_root="$WORKDIR/artifacts/$run_id"
  local execute_blocker="execute path not implemented: 当前 --execute 仅为占位语义，不会真实签发证书"
  local execute_next_step="如需真实签发，请先设计并实现独立 execute 子路径（含 ACME client / challenge fulfillment / 证书落盘 / 可控部署边界），而不是复用当前占位 helper。"

  bash "$ROOT_DIR/acme-issue-http01.sh" \
    --state-json "$run_root/state.json" \
    --execute \
    --challenge-mode standalone \
    --acme-client manual \
    --staging >/dev/null

  assert_contract_file "$artifact_root/ISSUE-RESULT.json" "issue-result"
  assert_json_value_equals "$artifact_root/ISSUE-RESULT.json" "mode" "execute" "$run_id execute issue result mode"
  assert_json_value_equals "$artifact_root/ISSUE-RESULT.json" "final_status" "blocked" "$run_id execute issue result final status"
  assert_json_array_contains "$artifact_root/ISSUE-RESULT.json" "blockers" "$execute_blocker" "$run_id execute issue result blockers carry execute placeholder boundary"
  assert_json_value_equals "$artifact_root/ISSUE-RESULT.json" "next_step" "$execute_next_step" "$run_id execute issue result next step tightened"

  assert_json_value_equals "$run_root/state.json" "artifacts.issue_result" "$artifact_root/ISSUE-RESULT.md" "$run_id execute state issue result markdown snapshot"
  assert_json_value_equals "$run_root/state.json" "artifacts.issue_result_json" "$artifact_root/ISSUE-RESULT.json" "$run_id execute state issue result json snapshot"
  assert_json_value_equals "$artifact_root/INSTALLER-SUMMARY.json" "artifacts.issue_result" "$artifact_root/ISSUE-RESULT.md" "$run_id execute summary issue result markdown snapshot"
  assert_json_value_equals "$artifact_root/INSTALLER-SUMMARY.json" "artifacts.issue_result_json" "$artifact_root/ISSUE-RESULT.json" "$run_id execute summary issue result json snapshot"
  assert_json_value_equals "$run_root/state.json" "artifacts.journal_jsonl" "$run_root/journal.jsonl" "$run_id execute state journal snapshot"
  assert_json_value_equals "$artifact_root/INSTALLER-SUMMARY.json" "artifacts.journal_jsonl" "$run_root/journal.jsonl" "$run_id execute summary journal snapshot"

  assert_journal_event_path_equals_state_artifact "$run_id" "issue.result.recorded" "issue_result_json" "$run_id execute issue.result.recorded path points to issue_result_json"
}

assert_journal_event_path_equals_state_artifact() {
  local run_id="$1"
  local event_name="$2"
  local artifact_key="$3"
  local label="$4"
  local run_root="$WORKDIR/runs/$run_id"

  python3 - "$run_root/state.json" "$run_root/journal.jsonl" "$event_name" "$artifact_key" "$label" <<'PY'
import json
import sys
from pathlib import Path

state_path = Path(sys.argv[1])
journal_path = Path(sys.argv[2])
event_name = sys.argv[3]
artifact_key = sys.argv[4]
label = sys.argv[5]

state = json.loads(state_path.read_text(encoding='utf-8'))
expected = state.get('artifacts', {}).get(artifact_key, '')
if not expected:
    raise SystemExit(f"[FAIL] {label}: state artifacts missing {artifact_key}")

entries = [json.loads(line) for line in journal_path.read_text(encoding='utf-8').splitlines() if line.strip()]
for item in entries:
    if item.get('event') == event_name:
        actual = item.get('path', '')
        if actual != expected:
            raise SystemExit(
                f"[FAIL] {label}: expected event {event_name} path {expected!r}, got {actual!r}"
            )
        raise SystemExit(0)

raise SystemExit(f"[FAIL] {label}: event {event_name} not found in journal")
PY
}

assert_journal_event_path_equals_literal() {
  local run_id="$1"
  local event_name="$2"
  local expected_path="$3"
  local label="$4"
  local run_root="$WORKDIR/runs/$run_id"

  python3 - "$run_root/journal.jsonl" "$event_name" "$expected_path" "$label" <<'PY'
import json
import sys
from pathlib import Path

journal_path = Path(sys.argv[1])
event_name = sys.argv[2]
expected_path = sys.argv[3]
label = sys.argv[4]

entries = [json.loads(line) for line in journal_path.read_text(encoding='utf-8').splitlines() if line.strip()]
for item in entries:
    if item.get('event') == event_name:
        actual = item.get('path', '')
        if actual != expected_path:
            raise SystemExit(
                f"[FAIL] {label}: expected event {event_name} path {expected_path!r}, got {actual!r}"
            )
        raise SystemExit(0)

raise SystemExit(f"[FAIL] {label}: event {event_name} not found in journal")
PY
}

assert_state_artifact_equals_literal() {
  local run_id="$1"
  local artifact_key="$2"
  local expected_path="$3"
  local label="$4"
  local run_root="$WORKDIR/runs/$run_id"

  python3 - "$run_root/state.json" "$artifact_key" "$expected_path" "$label" <<'PY'
import json
import sys
from pathlib import Path

state_path = Path(sys.argv[1])
artifact_key = sys.argv[2]
expected_path = sys.argv[3]
label = sys.argv[4]

state = json.loads(state_path.read_text(encoding='utf-8'))
actual = (state.get('artifacts') or {}).get(artifact_key, '')
if actual != expected_path:
    raise SystemExit(
        f"[FAIL] {label}: expected state artifacts[{artifact_key!r}] == {expected_path!r}, got {actual!r}"
    )
PY
}

assert_state_artifact_empty() {
  local run_id="$1"
  local artifact_key="$2"
  local label="$3"
  local run_root="$WORKDIR/runs/$run_id"

  python3 - "$run_root/state.json" "$artifact_key" "$label" <<'PY'
import json
import sys
from pathlib import Path

state_path = Path(sys.argv[1])
artifact_key = sys.argv[2]
label = sys.argv[3]

state = json.loads(state_path.read_text(encoding='utf-8'))
actual = (state.get('artifacts') or {}).get(artifact_key, '')
if actual:
    raise SystemExit(
        f"[FAIL] {label}: expected state artifacts[{artifact_key!r}] to stay empty for compatibility probe, got {actual!r}"
    )
PY
}

check_fixture_journal_path_contract() {
  local run_id="$1"
  local run_root="$WORKDIR/runs/$run_id"

  assert_journal_event_path_equals_literal "$run_id" "run.initialized" "$run_root" "$run_id run.initialized path points to run root"
  assert_journal_event_path_equals_state_artifact "$run_id" "run.complete" "summary_output" "$run_id run.complete path points to summary_output"
}

materialize_fixtures

install_help_output="$(bash "$ROOT_DIR/install-interactive.sh" --help)"
assert_contains "$install_help_output" "inspect-after-apply-attention / repair-review-first / post-repair-verification / post-rollback-inspection" "install help surfaces inspection-first resume strategy set"
assert_contains "$install_help_output" "resume defaults to review-first continuation instead of real apply replay" "install help explains inspection-first resume review-first default"

# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/status-contracts.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/state.sh"
RUNS_ROOT_DIR="$WORKDIR/runs"

plan_resume_runtime_for_run() {
  local run_id="$1"
  SHOULD_SKIP_INPUTS="0"
  SHOULD_SKIP_PREFLIGHT="0"
  SHOULD_SKIP_GENERATOR="0"
  SHOULD_SKIP_APPLY_PLAN="0"
  INSTALLER_REPAIR_STATUS=""
  INSTALLER_ROLLBACK_STATUS=""
  RESUME_STRATEGY="fresh"
  RESUME_STRATEGY_REASON="new-run"
  EXECUTE_APPLY="0"
  RUN_NGINX_TEST_AFTER_EXECUTE="0"

  state_load_resume_context "$run_id"
  state_plan_resume_runtime
}

check_contract_set "fixture-legacy-fallback"
check_contract_set "fixture-resumed-repair-review"
check_contract_set "fixture-current-apply-attention"
check_contract_set "fixture-inspect-after-apply-attention"
check_contract_set "fixture-post-rollback-inspection"
check_contract_set "fixture-post-repair-verification"
# resume-only priority fixtures intentionally skip the full 6-contract bundle; they exist to pin state_load_resume_context lineage walk order.

check_stable_contract_smoke_matrix "fixture-legacy-fallback"
check_stable_contract_smoke_matrix "fixture-resumed-repair-review"
check_stable_contract_smoke_matrix "fixture-current-apply-attention"
check_stable_contract_smoke_matrix "fixture-inspect-after-apply-attention"
check_stable_contract_smoke_matrix "fixture-post-rollback-inspection"
check_stable_contract_smoke_matrix "fixture-post-repair-verification"

check_contract_value_smoke_matrix "fixture-legacy-fallback"
check_contract_value_smoke_matrix "fixture-resumed-repair-review"
check_contract_value_smoke_matrix "fixture-current-apply-attention"
check_contract_value_smoke_matrix "fixture-inspect-after-apply-attention"
check_contract_value_smoke_matrix "fixture-post-rollback-inspection"
check_contract_value_smoke_matrix "fixture-post-repair-verification"

check_per_run_artifact_snapshot_contract "fixture-legacy-fallback"
check_per_run_artifact_snapshot_contract "fixture-resumed-repair-review"
check_per_run_artifact_snapshot_contract "fixture-current-apply-attention"
check_per_run_artifact_snapshot_contract "fixture-inspect-after-apply-attention"
check_per_run_artifact_snapshot_contract "fixture-post-rollback-inspection"
check_per_run_artifact_snapshot_contract "fixture-post-repair-verification"

check_tls_plan_artifact_contract "fixture-tls-acme-http01" "acme-http01"
check_tls_plan_artifact_contract "fixture-tls-acme-dns-cloudflare" "acme-dns-cloudflare"
check_acme_issue_http01_helper_contract
check_acme_issue_http01_helper_execute_contract

check_fixture_journal_path_contract "fixture-legacy-fallback"
check_fixture_journal_path_contract "fixture-resumed-repair-review"
check_fixture_journal_path_contract "fixture-current-apply-attention"
check_fixture_journal_path_contract "fixture-inspect-after-apply-attention"
check_fixture_journal_path_contract "fixture-post-rollback-inspection"
check_fixture_journal_path_contract "fixture-post-repair-verification"
assert_state_artifact_empty "fixture-legacy-fallback" "repair_result_json" "legacy fallback keeps repair_result_json empty to pin old-run compatibility boundary"
assert_state_artifact_empty "fixture-legacy-fallback" "rollback_result_json" "legacy fallback keeps rollback_result_json empty to pin old-run compatibility boundary"
assert_state_artifact_equals_literal "fixture-resumed-repair-review" "repair_result_json" "$WORKDIR/artifacts/fixture-resumed-repair-review/REPAIR-RESULT.json" "resumed repair review records current repair_result_json explicitly"
assert_state_artifact_equals_literal "fixture-resumed-repair-review" "rollback_result_json" "$WORKDIR/artifacts/fixture-resumed-repair-review/ROLLBACK-RESULT.json" "resumed repair review records current rollback_result_json explicitly"
assert_state_artifact_equals_literal "fixture-current-apply-attention" "repair_result_json" "$WORKDIR/artifacts/fixture-current-apply-attention/REPAIR-RESULT.json" "current apply attention records current repair_result_json explicitly"
assert_state_artifact_equals_literal "fixture-current-apply-attention" "rollback_result_json" "$WORKDIR/artifacts/fixture-current-apply-attention/ROLLBACK-RESULT.json" "current apply attention records current rollback_result_json explicitly"
assert_state_artifact_equals_literal "fixture-inspect-after-apply-attention" "repair_result_json" "$WORKDIR/artifacts/fixture-inspect-after-apply-attention/REPAIR-RESULT.json" "inspect-after-apply attention records current repair_result_json explicitly"
assert_state_artifact_equals_literal "fixture-inspect-after-apply-attention" "rollback_result_json" "$WORKDIR/artifacts/fixture-inspect-after-apply-attention/ROLLBACK-RESULT.json" "inspect-after-apply attention records current rollback_result_json explicitly"
assert_state_artifact_equals_literal "fixture-post-rollback-inspection" "repair_result_json" "$WORKDIR/artifacts/fixture-post-rollback-inspection/REPAIR-RESULT.json" "post rollback inspection records current repair_result_json explicitly"
assert_state_artifact_equals_literal "fixture-post-rollback-inspection" "rollback_result_json" "$WORKDIR/artifacts/fixture-post-rollback-inspection/ROLLBACK-RESULT.json" "post rollback inspection records current rollback_result_json explicitly"
assert_state_artifact_equals_literal "fixture-post-repair-verification" "repair_result_json" "$WORKDIR/artifacts/fixture-post-repair-verification/REPAIR-RESULT.json" "post repair verification records current repair_result_json explicitly"
assert_state_artifact_equals_literal "fixture-post-repair-verification" "rollback_result_json" "$WORKDIR/artifacts/fixture-post-repair-verification/ROLLBACK-RESULT.json" "post repair verification records current rollback_result_json explicitly"
assert_journal_event_path_equals_state_artifact "fixture-legacy-fallback" "apply-execute.complete" "apply_result_json" "legacy fallback apply-execute.complete path points to apply_result_json"
assert_journal_event_path_equals_state_artifact "fixture-current-apply-attention" "apply-execute.complete" "apply_result_json" "current apply attention apply-execute.complete path points to apply_result_json"
assert_journal_event_path_equals_state_artifact "fixture-inspect-after-apply-attention" "repair.result.recorded" "repair_result_json" "inspect-after-apply attention repair.result.recorded path points to repair_result_json"
assert_journal_event_path_equals_state_artifact "fixture-post-repair-verification" "repair.result.recorded" "repair_result_json" "post repair verification repair.result.recorded path points to repair_result_json"
assert_journal_event_path_equals_literal "fixture-post-rollback-inspection" "rollback.result.recorded" "$WORKDIR/artifacts/fixture-post-rollback-inspection/ROLLBACK-RESULT.json" "post rollback inspection rollback.result.recorded path points to fallback rollback result json"

state_load_resume_context "fixture-legacy-fallback"
assert_equals "$RESUME_SOURCE_REPAIR_RESULT_OWNER_RUN_ID" "fixture-legacy-fallback" "legacy fallback repair owner run id"
assert_equals "$RESUME_SOURCE_ROLLBACK_RESULT_OWNER_RUN_ID" "fixture-legacy-fallback" "legacy fallback rollback owner run id"
assert_equals "$RESUME_SOURCE_REPAIR_RESULT_JSON_PATH" "$WORKDIR/artifacts/fixture-legacy-fallback/REPAIR-RESULT.json" "legacy fallback repair json path"
assert_equals "$RESUME_SOURCE_ROLLBACK_RESULT_JSON_PATH" "$WORKDIR/artifacts/fixture-legacy-fallback/ROLLBACK-RESULT.json" "legacy fallback rollback json path"
assert_equals "$RESUME_SOURCE_REPAIR_FINAL_STATUS" "needs-attention" "legacy fallback repair final status"
assert_equals "$RESUME_SOURCE_ROLLBACK_FINAL_STATUS" "ok" "legacy fallback rollback final status"
assert_equals "$RESUME_SOURCE_APPLY_RESUME_RECOMMENDED" "1" "legacy fallback apply resume recommended"
LEGACY_REPAIR_FINAL_STATUS="$RESUME_SOURCE_REPAIR_FINAL_STATUS"
LEGACY_APPLY_RESUME_RECOMMENDED_BOOL="$(bool_01_to_python_bool_text "$RESUME_SOURCE_APPLY_RESUME_RECOMMENDED")"

python3 - "$WORKDIR/runs/fixture-legacy-fallback/state.json" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
obj = json.loads(path.read_text(encoding='utf-8'))
obj['status']['repair'] = 'ok'
obj['status']['final'] = 'success'
path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
PY
state_load_resume_context "fixture-legacy-fallback"
assert_equals "$RESUME_SOURCE_REPAIR_STATUS" "ok" "semantic drift legacy state repair status still reflects drifted state"
assert_equals "$RESUME_SOURCE_FINAL_STATUS" "success" "semantic drift legacy state final status still reflects drifted state"
assert_equals "$RESUME_SOURCE_REPAIR_FINAL_STATUS" "needs-attention" "semantic drift legacy repair final still follows repair result truth"
LEGACY_REPAIR_FINAL_STATUS="$RESUME_SOURCE_REPAIR_FINAL_STATUS"

python3 - "$TEMPLATE_DIR/runs/fixture-legacy-fallback/state.json" "$WORKDIR/runs/fixture-legacy-fallback/state.json" "$WORKDIR" <<'PY'
import sys
from pathlib import Path
src = Path(sys.argv[1])
dst = Path(sys.argv[2])
workdir = sys.argv[3]
dst.write_text(src.read_text(encoding='utf-8').replace('__FIXTURE_ROOT__', workdir), encoding='utf-8')
PY
state_load_resume_context "fixture-legacy-fallback"
assert_equals "$RESUME_SOURCE_REPAIR_FINAL_STATUS" "needs-attention" "legacy fallback repair final status restored after semantic drift probe"
LEGACY_REPAIR_FINAL_STATUS="$RESUME_SOURCE_REPAIR_FINAL_STATUS"

state_load_resume_context "fixture-resumed-repair-review"
assert_equals "$RESUME_SOURCE_RESUMED_FROM" "fixture-legacy-fallback" "resumed run resumed_from"
assert_equals "$RESUME_SOURCE_REPAIR_RESULT_OWNER_RUN_ID" "fixture-resumed-repair-review" "resumed run repair owner stays current"
assert_equals "$RESUME_SOURCE_ROLLBACK_RESULT_OWNER_RUN_ID" "fixture-resumed-repair-review" "resumed run rollback owner stays current"
assert_equals "$RESUME_SOURCE_REPAIR_RESULT_JSON_PATH" "$WORKDIR/artifacts/fixture-resumed-repair-review/REPAIR-RESULT.json" "resumed run repair json fallback path"
assert_equals "$RESUME_SOURCE_REPAIR_FINAL_STATUS" "needs-attention" "resumed run repair final status"
assert_equals "$RESUME_SOURCE_ROLLBACK_FINAL_STATUS" "ok" "resumed run rollback final status"
assert_equals "$RESUME_SOURCE_ROLLBACK_EXECUTE" "0" "resumed run rollback execute flag"
RESUMED_REPAIR_FINAL_STATUS="$RESUME_SOURCE_REPAIR_FINAL_STATUS"
RESUMED_ROLLBACK_EXECUTE_BOOL="$(bool_01_to_python_bool_text "$RESUME_SOURCE_ROLLBACK_EXECUTE")"

state_load_resume_context "fixture-current-apply-attention"
assert_equals "$RESUME_SOURCE_RESUMED_FROM" "" "current apply attention resumed_from stays empty"
assert_equals "$RESUME_SOURCE_REPAIR_RESULT_OWNER_RUN_ID" "fixture-current-apply-attention" "current apply attention repair owner stays current"
assert_equals "$RESUME_SOURCE_ROLLBACK_RESULT_OWNER_RUN_ID" "fixture-current-apply-attention" "current apply attention rollback owner stays current"
assert_equals "$RESUME_SOURCE_REPAIR_RESULT_JSON_PATH" "$WORKDIR/artifacts/fixture-current-apply-attention/REPAIR-RESULT.json" "current apply attention repair json path"
assert_equals "$RESUME_SOURCE_REPAIR_FINAL_STATUS" "ok" "current apply attention repair final status"
assert_equals "$RESUME_SOURCE_ROLLBACK_FINAL_STATUS" "ok" "current apply attention rollback final status"
assert_equals "$RESUME_SOURCE_APPLY_RESUME_STRATEGY" "manual-recovery-first" "current apply attention apply recovery strategy stays current"
assert_equals "$RESUME_SOURCE_APPLY_RESUME_RECOMMENDED" "0" "current apply attention apply resume recommended"
CURRENT_APPLY_RESUME_RECOMMENDED_BOOL="$(bool_01_to_python_bool_text "$RESUME_SOURCE_APPLY_RESUME_RECOMMENDED")"
CURRENT_APPLY_RECOVERY_STATUS="$RESUME_SOURCE_APPLY_RECOVERY_STATUS"

state_load_resume_context "fixture-post-rollback-inspection"
assert_equals "$RESUME_SOURCE_RESUMED_FROM" "fixture-legacy-fallback" "post rollback run resumed_from"
assert_equals "$RESUME_SOURCE_ROLLBACK_RESULT_OWNER_RUN_ID" "fixture-post-rollback-inspection" "post rollback owner stays current"
assert_equals "$RESUME_SOURCE_REPAIR_RESULT_OWNER_RUN_ID" "fixture-post-rollback-inspection" "post rollback repair owner stays current"
assert_equals "$RESUME_SOURCE_ROLLBACK_RESULT_JSON_PATH" "$WORKDIR/artifacts/fixture-post-rollback-inspection/ROLLBACK-RESULT.json" "post rollback rollback json path"
assert_equals "$RESUME_SOURCE_ROLLBACK_FINAL_STATUS" "ok" "post rollback final status"
assert_equals "$RESUME_SOURCE_ROLLBACK_EXECUTE" "1" "post rollback execute flag"
assert_equals "$RESUME_SOURCE_REPAIR_FINAL_STATUS" "blocked" "post rollback repair final status"
POST_ROLLBACK_EXECUTE_BOOL="$(bool_01_to_python_bool_text "$RESUME_SOURCE_ROLLBACK_EXECUTE")"
POST_ROLLBACK_REPAIR_FINAL_STATUS="$RESUME_SOURCE_REPAIR_FINAL_STATUS"

state_load_resume_context "fixture-post-repair-verification"
assert_equals "$RESUME_SOURCE_RESUMED_FROM" "fixture-legacy-fallback" "post repair run resumed_from"
assert_equals "$RESUME_SOURCE_REPAIR_RESULT_OWNER_RUN_ID" "fixture-post-repair-verification" "post repair owner stays current"
assert_equals "$RESUME_SOURCE_ROLLBACK_RESULT_OWNER_RUN_ID" "fixture-post-repair-verification" "post repair rollback owner stays current via local fallback"
assert_equals "$RESUME_SOURCE_REPAIR_RESULT_JSON_PATH" "$WORKDIR/artifacts/fixture-post-repair-verification/REPAIR-RESULT.json" "post repair repair json path"
assert_equals "$RESUME_SOURCE_REPAIR_FINAL_STATUS" "ok" "post repair final status"
assert_equals "$RESUME_SOURCE_REPAIR_NGINX_TEST_RERUN_STATUS" "passed" "post repair nginx rerun status"
assert_equals "$RESUME_SOURCE_ROLLBACK_RESULT_JSON_PATH" "$WORKDIR/artifacts/fixture-post-repair-verification/ROLLBACK-RESULT.json" "post repair rollback fallback path"
assert_equals "$RESUME_SOURCE_ROLLBACK_EXECUTE" "0" "post repair rollback execute flag"
POST_REPAIR_FINAL_STATUS="$RESUME_SOURCE_REPAIR_FINAL_STATUS"
POST_REPAIR_RERUN_STATUS="$RESUME_SOURCE_REPAIR_NGINX_TEST_RERUN_STATUS"

state_load_resume_context "fixture-inspect-after-apply-attention"
assert_equals "$RESUME_SOURCE_RESUMED_FROM" "fixture-legacy-fallback" "inspect-after-apply attention run resumed_from"
assert_equals "$RESUME_SOURCE_REPAIR_RESULT_OWNER_RUN_ID" "fixture-inspect-after-apply-attention" "inspect-after-apply attention repair owner stays current"
assert_equals "$RESUME_SOURCE_ROLLBACK_RESULT_OWNER_RUN_ID" "fixture-inspect-after-apply-attention" "inspect-after-apply attention rollback owner stays current via local fallback"
assert_equals "$RESUME_SOURCE_APPLY_RESULT_JSON_PATH" "$WORKDIR/artifacts/fixture-inspect-after-apply-attention/APPLY-RESULT.json" "inspect-after-apply attention apply result json path"
assert_equals "$RESUME_SOURCE_APPLY_RESUME_STRATEGY" "post-apply-review" "inspect-after-apply attention apply recovery strategy stays current"
assert_equals "$RESUME_SOURCE_APPLY_RESUME_RECOMMENDED" "0" "inspect-after-apply attention apply resume recommended"
assert_equals "$RESUME_SOURCE_APPLY_OPERATOR_ACTION" "manual-review" "inspect-after-apply attention operator action"
assert_equals "$RESUME_SOURCE_REPAIR_FINAL_STATUS" "ok" "inspect-after-apply attention repair final status"
assert_equals "$RESUME_SOURCE_REPAIR_NGINX_TEST_RERUN_STATUS" "not-run" "inspect-after-apply attention repair rerun status"
assert_equals "$RESUME_SOURCE_ROLLBACK_RESULT_JSON_PATH" "$WORKDIR/artifacts/fixture-inspect-after-apply-attention/ROLLBACK-RESULT.json" "inspect-after-apply attention rollback fallback path"
assert_equals "$RESUME_SOURCE_ROLLBACK_EXECUTE" "0" "inspect-after-apply attention rollback execute flag"
INSPECT_AFTER_APPLY_RESUME_RECOMMENDED_BOOL="$(bool_01_to_python_bool_text "$RESUME_SOURCE_APPLY_RESUME_RECOMMENDED")"
INSPECT_AFTER_APPLY_RECOVERY_STATUS="$RESUME_SOURCE_APPLY_RECOVERY_STATUS"

plan_resume_runtime_for_run "fixture-post-repair-verification"
assert_equals "$RESUME_STRATEGY" "post-repair-verification" "resume planner picks post-repair-verification from repair result truth"
assert_equals "$SHOULD_SKIP_INPUTS" "1" "post repair verification forces input reuse from available artifacts"
assert_equals "$SHOULD_SKIP_PREFLIGHT" "1" "post repair verification forces preflight reuse from available artifacts"
assert_equals "$SHOULD_SKIP_GENERATOR" "1" "post repair verification forces generator reuse from available artifacts"
assert_equals "$SHOULD_SKIP_APPLY_PLAN" "1" "post repair verification forces apply plan reuse from available artifacts"
assert_equals "$INSTALLER_REPAIR_STATUS" "ok" "post repair verification effective repair status follows repair result truth"
assert_equals "$INSTALLER_ROLLBACK_STATUS" "ok" "post repair verification effective rollback status follows rollback result truth"

resume_runtime_banner_output="$(bash -c '
  source "$1/scripts/lib/ui.sh"
  source "$1/scripts/lib/config.sh"
  source "$1/scripts/lib/apply-plan.sh"
  source "$1/scripts/lib/checks.sh"
  source "$1/scripts/lib/dns.sh"
  source "$1/scripts/lib/tls.sh"
  source "$1/scripts/lib/backup.sh"
  source "$1/scripts/lib/status-contracts.sh"
  source "$1/scripts/lib/state.sh"
  RUNS_ROOT_DIR="$2/runs"
  GENERATED_DIR="$1/scripts/generated"
  SHOULD_SKIP_INPUTS=0
  SHOULD_SKIP_PREFLIGHT=0
  SHOULD_SKIP_GENERATOR=0
  SHOULD_SKIP_APPLY_PLAN=0
  INSTALLER_REPAIR_STATUS=""
  INSTALLER_ROLLBACK_STATUS=""
  RESUME_RUN_ID="fixture-post-repair-verification"
  RESUME_SOURCE_RUN_ID=""
  RESUME_SOURCE_CHECKPOINT=""
  RESUME_SOURCE_RESUMED_FROM=""
  RESUME_STRATEGY="fresh"
  RESUME_STRATEGY_REASON="new-run"
  RUN_APPLY_DRY_RUN=0
  EXECUTE_APPLY=0
  RUN_NGINX_TEST_AFTER_EXECUTE=0
  CLI_REQUEST_EXECUTE_APPLY=0
  CLI_REQUEST_RUN_NGINX_TEST=0
  CLI_REQUEST_RUN_APPLY_DRY_RUN=0
  INSTALLER_MODE="resume"
  state_load_inputs_env "$RESUME_RUN_ID"
  state_load_resume_context "$RESUME_RUN_ID"
  state_plan_resume_runtime
  if resume_strategy_prefers_review_boundary "$RESUME_STRATEGY"; then
    printf "%s\n" "当前以 resume 模式启动：这轮属于 inspection-first 续接；会优先复查可复用产物，不把继续真实 apply 当默认动作。"
  else
    printf "%s\n" "当前以 resume 模式启动：将复用历史输入并尽量跳过已完成阶段。"
  fi
' _ "$ROOT_DIR" "$WORKDIR")"
assert_contains "$resume_runtime_banner_output" "当前以 resume 模式启动：这轮属于 inspection-first 续接；会优先复查可复用产物，不把继续真实 apply 当默认动作。" "inspection-first runtime banner is explicit about review-first semantics"

plan_resume_runtime_for_run "fixture-inspect-after-apply-attention"
assert_equals "$RESUME_STRATEGY" "inspect-after-apply-attention" "inspect-after-apply planner falls back to apply recovery when companion results do not demand review boundary override"
assert_equals "$SHOULD_SKIP_INPUTS" "1" "inspect-after-apply forces input reuse from available artifacts"
assert_equals "$SHOULD_SKIP_PREFLIGHT" "1" "inspect-after-apply forces preflight reuse from available artifacts"
assert_equals "$SHOULD_SKIP_GENERATOR" "1" "inspect-after-apply forces generator reuse from available artifacts"
assert_equals "$SHOULD_SKIP_APPLY_PLAN" "1" "inspect-after-apply forces apply plan reuse from available artifacts"

python3 - "$WORKDIR/runs/fixture-post-repair-verification/state.json" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
obj = json.loads(path.read_text(encoding='utf-8'))
obj['status']['repair'] = ''
obj['status']['rollback'] = ''
obj['status']['final'] = 'needs-attention'
path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
PY
plan_resume_runtime_for_run "fixture-post-repair-verification"
assert_equals "$RESUME_STRATEGY" "post-repair-verification" "semantic drift post repair planner still follows repair result truth"
assert_equals "$SHOULD_SKIP_INPUTS" "1" "semantic drift post repair still reuses inputs from existing config artifacts"
assert_equals "$SHOULD_SKIP_PREFLIGHT" "1" "semantic drift post repair still reuses preflight from existing config artifacts"
assert_equals "$SHOULD_SKIP_GENERATOR" "1" "semantic drift post repair still reuses generator output"
assert_equals "$SHOULD_SKIP_APPLY_PLAN" "1" "semantic drift post repair still reuses apply plan artifacts"
assert_equals "$INSTALLER_REPAIR_STATUS" "ok" "semantic drift post repair effective repair status comes from repair result final"
assert_equals "$INSTALLER_ROLLBACK_STATUS" "ok" "semantic drift post repair effective rollback status comes from rollback result final"

python3 - "$TEMPLATE_DIR/runs/fixture-post-repair-verification/state.json" "$WORKDIR/runs/fixture-post-repair-verification/state.json" "$WORKDIR" <<'PY'
import sys
from pathlib import Path
src = Path(sys.argv[1])
dst = Path(sys.argv[2])
workdir = sys.argv[3]
dst.write_text(src.read_text(encoding='utf-8').replace('__FIXTURE_ROOT__', workdir), encoding='utf-8')
PY
state_load_resume_context "fixture-post-repair-verification"
POST_REPAIR_FINAL_STATUS="$RESUME_SOURCE_REPAIR_FINAL_STATUS"
POST_REPAIR_RERUN_STATUS="$RESUME_SOURCE_REPAIR_NGINX_TEST_RERUN_STATUS"

state_load_resume_context "fixture-source-priority-over-ancestor"
assert_equals "$RESUME_SOURCE_RESUMED_FROM" "fixture-post-rollback-inspection" "source-priority fixture resumed_from"
assert_equals "$RESUME_SOURCE_ROLLBACK_RESULT_OWNER_RUN_ID" "fixture-post-rollback-inspection" "source-priority fixture prefers direct source rollback owner"
assert_equals "$RESUME_SOURCE_ROLLBACK_RESULT_JSON_PATH" "$WORKDIR/artifacts/fixture-post-rollback-inspection/ROLLBACK-RESULT.json" "source-priority fixture reuses direct source rollback json"
assert_equals "$RESUME_SOURCE_ROLLBACK_EXECUTE" "1" "source-priority fixture keeps direct source rollback execute flag"
assert_equals "$RESUME_SOURCE_REPAIR_RESULT_OWNER_RUN_ID" "fixture-post-rollback-inspection" "source-priority fixture repair also resolves from direct source first"
assert_equals "$RESUME_SOURCE_REPAIR_FINAL_STATUS" "blocked" "source-priority fixture keeps direct source repair status"

state_load_resume_context "fixture-ancestor-fallback-after-source-gap"
assert_equals "$RESUME_SOURCE_RESUMED_FROM" "fixture-source-priority-over-ancestor" "ancestor fallback fixture resumed_from"
assert_equals "$RESUME_SOURCE_ROLLBACK_RESULT_OWNER_RUN_ID" "fixture-post-rollback-inspection" "ancestor fallback fixture walks past direct source gap to nearest ancestor rollback owner"
assert_equals "$RESUME_SOURCE_ROLLBACK_RESULT_JSON_PATH" "$WORKDIR/artifacts/fixture-post-rollback-inspection/ROLLBACK-RESULT.json" "ancestor fallback fixture walks past source gap to ancestor rollback json"
assert_equals "$RESUME_SOURCE_ROLLBACK_EXECUTE" "1" "ancestor fallback fixture keeps nearest ancestor rollback execute flag"
assert_equals "$RESUME_SOURCE_REPAIR_RESULT_OWNER_RUN_ID" "fixture-post-rollback-inspection" "ancestor fallback fixture walks to nearest ancestor repair owner"
assert_equals "$RESUME_SOURCE_REPAIR_FINAL_STATUS" "blocked" "ancestor fallback fixture keeps nearest ancestor repair status"

state_load_resume_context "fixture-missing-source-state"
assert_equals "$RESUME_SOURCE_RESUMED_FROM" "fixture-missing-source-parent" "missing source fixture resumed_from is preserved"
assert_equals "$RESUME_SOURCE_REPAIR_RESULT_OWNER_RUN_ID" "" "missing source fixture does not invent repair owner"
assert_equals "$RESUME_SOURCE_REPAIR_RESULT_JSON_PATH" "" "missing source fixture does not invent repair json path"
assert_equals "$RESUME_SOURCE_ROLLBACK_RESULT_OWNER_RUN_ID" "" "missing source fixture does not invent rollback owner"
assert_equals "$RESUME_SOURCE_ROLLBACK_RESULT_JSON_PATH" "" "missing source fixture does not invent rollback json path"

state_load_resume_context "fixture-lineage-cycle-a"
assert_equals "$RESUME_SOURCE_RESUMED_FROM" "fixture-lineage-cycle-b" "lineage cycle fixture resumed_from is preserved"
assert_equals "$RESUME_SOURCE_REPAIR_RESULT_OWNER_RUN_ID" "" "lineage cycle fixture does not invent repair owner"
assert_equals "$RESUME_SOURCE_REPAIR_RESULT_JSON_PATH" "" "lineage cycle fixture does not invent repair json path"
assert_equals "$RESUME_SOURCE_ROLLBACK_RESULT_OWNER_RUN_ID" "" "lineage cycle fixture does not invent rollback owner"
assert_equals "$RESUME_SOURCE_ROLLBACK_RESULT_JSON_PATH" "" "lineage cycle fixture does not invent rollback json path"

doctor_legacy_output="$(state_doctor "fixture-legacy-fallback")"
assert_contains "$doctor_legacy_output" "[doctor] 运行摘要" "legacy doctor prints run summary section"
assert_contains "$doctor_legacy_output" "- run_id: fixture-legacy-fallback" "legacy doctor prints run id"
assert_contains "$doctor_legacy_output" "- checkpoint: completed" "legacy doctor prints checkpoint"
assert_contains "$doctor_legacy_output" "[doctor] 输入" "legacy doctor prints inputs section"
assert_contains "$doctor_legacy_output" "- deployment_name: fixture-legacy-fallback" "legacy doctor prints deployment name"
assert_contains "$doctor_legacy_output" "- output_dir: ./dist/fixture-legacy-fallback" "legacy doctor prints output_dir input"
assert_contains "$doctor_legacy_output" "[doctor] 状态" "legacy doctor prints status section"
assert_contains "$doctor_legacy_output" "- repair: needs-attention" "legacy doctor prints repair status"
assert_contains "$doctor_legacy_output" "- rollback: ok" "legacy doctor prints rollback status"
assert_contains "$doctor_legacy_output" "[doctor] 产物" "legacy doctor prints artifacts section"
assert_contains "$doctor_legacy_output" "- inputs_env: $WORKDIR/runs/fixture-legacy-fallback/inputs.env (exists)" "legacy doctor prints inputs_env artifact existence"
assert_contains "$doctor_legacy_output" "[doctor] repair result json" "legacy doctor prints repair section"
assert_contains "$doctor_legacy_output" "$WORKDIR/artifacts/fixture-legacy-fallback/REPAIR-RESULT.json" "legacy doctor resolves repair fallback path"
assert_contains "$doctor_legacy_output" "[doctor] rollback result json" "legacy doctor prints rollback section"
assert_contains "$doctor_legacy_output" "$WORKDIR/artifacts/fixture-legacy-fallback/ROLLBACK-RESULT.json" "legacy doctor resolves rollback fallback path"
assert_contains "$doctor_legacy_output" "- final_status: $LEGACY_REPAIR_FINAL_STATUS" "legacy doctor repair final status stays consistent with resume context"
assert_contains "$doctor_legacy_output" "- recovery.resume_recommended: $LEGACY_APPLY_RESUME_RECOMMENDED_BOOL" "legacy doctor apply resume_recommended stays consistent with resume context"
assert_contains "$doctor_legacy_output" "[doctor] journal" "legacy doctor prints journal section"
assert_contains "$doctor_legacy_output" "- entries: 3" "legacy doctor prints journal entry count"
assert_contains "$doctor_legacy_output" "- last_event: run.complete [success]" "legacy doctor prints journal last event"
assert_contains "$doctor_legacy_output" "- last_message: installer completed" "legacy doctor prints journal last message"

doctor_resumed_output="$(state_doctor "fixture-resumed-repair-review")"
assert_contains "$doctor_resumed_output" "- resumed_from: fixture-legacy-fallback" "resumed doctor prints resumed_from in run summary"
assert_contains "$doctor_resumed_output" "[doctor] lineage 摘要" "resumed doctor prints lineage summary section"
assert_contains "$doctor_resumed_output" "- 当前已解析到 2 段 lineage 链。" "resumed doctor prints lineage depth summary"
assert_contains "$doctor_resumed_output" "[doctor] lineage chain" "resumed doctor prints lineage chain section"
assert_contains "$doctor_resumed_output" "- 1. [current] fixture-resumed-repair-review (checkpoint=completed, final=success; strategy=repair-review-first; reason=source repair result still needs operator review; alerts=repair=needs-attention)" "resumed doctor prints current lineage chain entry"
assert_contains "$doctor_resumed_output" "- platform: plain-nginx" "resumed doctor prints input platform"
assert_contains "$doctor_resumed_output" "- apply_execute: skipped" "resumed doctor prints apply_execute status"
assert_contains "$doctor_resumed_output" "- journal_jsonl: $WORKDIR/runs/fixture-resumed-repair-review/journal.jsonl (exists)" "resumed doctor prints journal artifact existence"
assert_contains "$doctor_resumed_output" "当前 resume 策略：repair-review-first。" "resumed doctor prints resume strategy"
assert_contains "$doctor_resumed_output" "最近的异常祖先节点：fixture-legacy-fallback （repair=needs-attention）。" "resumed doctor prints abnormal ancestor"
assert_contains "$doctor_resumed_output" "$WORKDIR/artifacts/fixture-legacy-fallback/REPAIR-RESULT.json [repair-result]" "resumed doctor points to ancestor repair artifact"
assert_contains "$doctor_resumed_output" "- lineage.source_run_id: fixture-legacy-fallback" "resumed doctor machine summary source run"
assert_contains "$doctor_resumed_output" "- final_status: $RESUMED_REPAIR_FINAL_STATUS" "resumed doctor repair final status stays consistent with resume context"
assert_contains "$doctor_resumed_output" "- flags.execute: $RESUMED_ROLLBACK_EXECUTE_BOOL" "resumed doctor rollback execute flag stays consistent with resume context"
assert_contains "$doctor_resumed_output" "[doctor] journal" "resumed doctor prints journal section"
assert_contains "$doctor_resumed_output" "- entries: 2" "resumed doctor prints journal entry count"
assert_contains "$doctor_resumed_output" "- last_event: run.complete [success]" "resumed doctor prints journal last event"
assert_contains "$doctor_resumed_output" "- last_message: installer completed" "resumed doctor prints journal last message"

doctor_current_apply_attention_output="$(state_doctor "fixture-current-apply-attention")"
assert_contains "$doctor_current_apply_attention_output" "- run_id: fixture-current-apply-attention" "current apply attention doctor prints run id"
assert_contains "$doctor_current_apply_attention_output" "- resumed_from: 无" "current apply attention doctor prints resumed_from none"
assert_contains "$doctor_current_apply_attention_output" "- current_run_priority_artifact: $WORKDIR/artifacts/fixture-current-apply-attention/APPLY-RESULT.json [apply-result]" "current apply attention doctor prints machine summary priority artifact"
assert_contains "$doctor_current_apply_attention_output" "- current_run_priority_note: 最近异常出在 apply 阶段，建议先看 apply 结果/计划文件。" "current apply attention doctor prints machine summary priority note"
assert_contains "$doctor_current_apply_attention_output" "[doctor] 输入" "current apply attention doctor prints inputs section"
assert_contains "$doctor_current_apply_attention_output" "- apply_execute: needs-attention" "current apply attention doctor prints apply execute status"
assert_contains "$doctor_current_apply_attention_output" "- final: needs-attention" "current apply attention doctor prints final status"
assert_contains "$doctor_current_apply_attention_output" "- apply_result_json: $WORKDIR/artifacts/fixture-current-apply-attention/APPLY-RESULT.json (exists)" "current apply attention doctor prints apply_result_json artifact existence"
assert_contains "$doctor_current_apply_attention_output" "[doctor] 当前 run 异常摘要" "current apply attention doctor prints current run abnormal summary"
assert_contains "$doctor_current_apply_attention_output" "- 当前 run 存在异常状态：apply_execute=needs-attention, final=needs-attention" "current apply attention doctor prints current run alerts"
assert_contains "$doctor_current_apply_attention_output" "$WORKDIR/artifacts/fixture-current-apply-attention/APPLY-RESULT.json [apply-result]" "current apply attention doctor points to current apply result artifact"
assert_contains "$doctor_current_apply_attention_output" "最近异常出在 apply 阶段，建议先看 apply 结果/计划文件。" "current apply attention doctor explains priority artifact"
assert_contains "$doctor_current_apply_attention_output" "- recovery.installer_status: $CURRENT_APPLY_RECOVERY_STATUS" "current apply attention doctor recovery status stays consistent with resume context"
assert_contains "$doctor_current_apply_attention_output" "- recovery.resume_strategy: manual-recovery-first" "current apply attention doctor prints apply recovery strategy"
assert_contains "$doctor_current_apply_attention_output" "- recovery.resume_recommended: $CURRENT_APPLY_RESUME_RECOMMENDED_BOOL" "current apply attention doctor resume_recommended stays consistent with resume context"
assert_contains "$doctor_current_apply_attention_output" "[doctor] journal" "current apply attention doctor prints journal section"
assert_contains "$doctor_current_apply_attention_output" "- entries: 3" "current apply attention doctor prints journal entry count"
assert_contains "$doctor_current_apply_attention_output" "- last_event: run.complete [needs-attention]" "current apply attention doctor prints journal last event"
assert_contains "$doctor_current_apply_attention_output" "- last_message: installer completed with attention required" "current apply attention doctor prints journal last message"
assert_contains "$doctor_current_apply_attention_output" "真实 apply 已落盘，但 nginx 测试失败；建议先运行 ./repair-applied-package.sh --result-json $WORKDIR/artifacts/fixture-current-apply-attention/APPLY-RESULT.json --dry-run 做保守诊断，再决定 selective rollback 还是人工修复。 当前不建议把 resume 当作默认下一步。" "current apply attention doctor prints repair dry-run suggestion"

doctor_post_rollback_output="$(state_doctor "fixture-post-rollback-inspection")"
assert_contains "$doctor_post_rollback_output" "- final_status: $POST_ROLLBACK_REPAIR_FINAL_STATUS" "post rollback doctor repair final status stays consistent with resume context"
assert_contains "$doctor_post_rollback_output" "- flags.execute: $POST_ROLLBACK_EXECUTE_BOOL" "post rollback doctor rollback execute flag stays consistent with resume context"
assert_contains "$doctor_post_rollback_output" "当前 resume 策略：post-rollback-inspection。" "post rollback doctor prints resume strategy"
assert_contains "$doctor_post_rollback_output" "操作建议：优先核对 rollback 结果与当前落地文件状态，确认是否适合继续后续动作。" "post rollback doctor prints operator guidance"
assert_contains "$doctor_post_rollback_output" "- 当前策略优先产物：$WORKDIR/artifacts/fixture-post-rollback-inspection/ROLLBACK-RESULT.json [rollback-result]" "post rollback doctor prefers current rollback artifact in lineage summary"
assert_contains "$doctor_post_rollback_output" "- 说明：当前 run 已产出 rollback 结果；在 post-rollback-inspection 下应先看这一份。" "post rollback doctor explains current rollback priority"
assert_contains "$doctor_post_rollback_output" "- 祖先参考产物：$WORKDIR/artifacts/fixture-legacy-fallback/REPAIR-RESULT.json [repair-result]" "post rollback doctor keeps ancestor artifact as reference"
assert_contains "$doctor_post_rollback_output" "最近的异常祖先节点：fixture-legacy-fallback （repair=needs-attention）。" "post rollback doctor still highlights abnormal ancestor"

python3 - "$WORKDIR/runs/fixture-post-rollback-inspection/state.json" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
obj = json.loads(path.read_text(encoding='utf-8'))
obj['status']['rollback'] = ''
obj['status']['final'] = 'needs-attention'
path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
PY
doctor_post_rollback_semantic_drift_output="$(state_doctor "fixture-post-rollback-inspection")"
assert_contains "$doctor_post_rollback_semantic_drift_output" "- current_run_alerts: final=needs-attention" "post rollback semantic drift still shows current final alert"
assert_contains "$doctor_post_rollback_semantic_drift_output" "- current_run_priority_artifact: $WORKDIR/artifacts/fixture-post-rollback-inspection/ROLLBACK-RESULT.json [rollback-result]" "post rollback semantic drift still prefers rollback artifact for current run summary"
assert_contains "$doctor_post_rollback_semantic_drift_output" "- current_run_priority_note: 当前 run 已产出 rollback 结果；在 post-rollback-inspection 下应先看这一份。" "post rollback semantic drift current summary inherits strategy-specific note"
assert_not_contains "$doctor_post_rollback_semantic_drift_output" "$WORKDIR/artifacts/fixture-post-rollback-inspection/REPAIR-RESULT.json [generic-artifact]" "post rollback semantic drift no longer lets generic repair artifact steal current priority"

python3 - "$WORKDIR/artifacts/fixture-post-rollback-inspection/REPAIR-RESULT.json" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
obj = json.loads(path.read_text(encoding='utf-8'))
obj['final_status'] = 'blocked'
obj['next_step'] = '【DRIFT-REPAIR】repair companion 抢到了建议位。'
path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
PY
doctor_post_rollback_suggestion_drift_output="$(state_doctor "fixture-post-rollback-inspection")"
doctor_post_rollback_suggestion_drift_next_step="$(printf '%s' "$doctor_post_rollback_suggestion_drift_output" | extract_doctor_next_step_section)"
assert_contains "$doctor_post_rollback_suggestion_drift_next_step" "已执行 selective rollback；建议先做现场复查，再决定是否重新 dry-run / apply。" "post rollback suggestion drift still keeps rollback-first next step"
assert_not_contains "$doctor_post_rollback_suggestion_drift_next_step" "【DRIFT-REPAIR】repair companion 抢到了建议位。" "post rollback suggestion drift no longer lets repair companion steal next step"

python3 - "$TEMPLATE_DIR/artifacts/fixture-post-rollback-inspection/REPAIR-RESULT.json" "$WORKDIR/artifacts/fixture-post-rollback-inspection/REPAIR-RESULT.json" "$WORKDIR" <<'PY'
import sys
from pathlib import Path
src = Path(sys.argv[1])
dst = Path(sys.argv[2])
workdir = sys.argv[3]
dst.write_text(src.read_text(encoding='utf-8').replace('__FIXTURE_ROOT__', workdir), encoding='utf-8')
PY

doctor_post_repair_output="$(state_doctor "fixture-post-repair-verification")"
assert_contains "$doctor_post_repair_output" "- final_status: $POST_REPAIR_FINAL_STATUS" "post repair doctor repair final status stays consistent with resume context"
assert_contains "$doctor_post_repair_output" "- execution.nginx_test_rerun_status: $POST_REPAIR_RERUN_STATUS" "post repair doctor rerun status stays consistent with resume context"
assert_contains "$doctor_post_repair_output" "当前 resume 策略：post-repair-verification。" "post repair doctor prints resume strategy"
assert_contains "$doctor_post_repair_output" "操作建议：优先查看 repair 结果与 nginx test 相关输出，确认是否还需要人工处理。" "post repair doctor prints operator guidance"
assert_contains "$doctor_post_repair_output" "- 当前策略优先产物：$WORKDIR/artifacts/fixture-post-repair-verification/REPAIR-RESULT.json [repair-result]" "post repair doctor prefers current repair artifact in lineage summary"
assert_contains "$doctor_post_repair_output" "- 说明：当前 run 已产出 repair 复查结果；在 post-repair-verification 下应先看这一份。" "post repair doctor explains current repair priority"
assert_contains "$doctor_post_repair_output" "- 祖先参考产物：$WORKDIR/artifacts/fixture-legacy-fallback/REPAIR-RESULT.json [repair-result]" "post repair doctor keeps ancestor artifact as reference"
assert_contains "$doctor_post_repair_output" "- execution.nginx_test_rerun_status: passed" "post repair doctor prints rerun status"
assert_contains "$doctor_post_repair_output" "已完成 repair 复查且 nginx -t 通过；建议人工确认现场后，再决定是否继续后续操作。" "post repair doctor prints repair next step"
assert_contains "$doctor_post_repair_output" "[doctor] 下一步建议" "post repair doctor prints next step section"

python3 - "$WORKDIR/runs/fixture-post-repair-verification/state.json" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
obj = json.loads(path.read_text(encoding='utf-8'))
obj['status']['repair'] = ''
obj['status']['final'] = 'needs-attention'
path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
PY
doctor_post_repair_semantic_drift_output="$(state_doctor "fixture-post-repair-verification")"
assert_contains "$doctor_post_repair_semantic_drift_output" "- current_run_alerts: final=needs-attention" "post repair semantic drift still shows current final alert"
assert_contains "$doctor_post_repair_semantic_drift_output" "- current_run_priority_artifact: $WORKDIR/artifacts/fixture-post-repair-verification/REPAIR-RESULT.json [repair-result]" "post repair semantic drift still prefers repair artifact for current run summary"
assert_contains "$doctor_post_repair_semantic_drift_output" "- current_run_priority_note: 当前 run 已产出 repair 复查结果；在 post-repair-verification 下应先看这一份。" "post repair semantic drift current summary inherits strategy-specific note"
assert_not_contains "$doctor_post_repair_semantic_drift_output" "$WORKDIR/artifacts/fixture-post-repair-verification/APPLY-RESULT.json [generic-artifact]" "post repair semantic drift no longer lets generic apply artifact steal current priority"

python3 - "$WORKDIR/artifacts/fixture-post-repair-verification/ROLLBACK-RESULT.json" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
obj = json.loads(path.read_text(encoding='utf-8'))
obj['final_status'] = 'blocked'
obj['next_step'] = '【DRIFT-ROLLBACK】rollback companion 抢到了建议位。'
path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
PY
doctor_post_repair_suggestion_drift_output="$(state_doctor "fixture-post-repair-verification")"
doctor_post_repair_suggestion_drift_next_step="$(printf '%s' "$doctor_post_repair_suggestion_drift_output" | extract_doctor_next_step_section)"
assert_contains "$doctor_post_repair_suggestion_drift_next_step" "已完成 repair 复查且 nginx -t 通过；建议人工确认现场后，再决定是否继续后续操作。" "post repair suggestion drift still keeps repair-first next step"
assert_not_contains "$doctor_post_repair_suggestion_drift_next_step" "【DRIFT-ROLLBACK】rollback companion 抢到了建议位。" "post repair suggestion drift no longer lets rollback companion steal next step"

python3 - "$TEMPLATE_DIR/artifacts/fixture-post-repair-verification/ROLLBACK-RESULT.json" "$WORKDIR/artifacts/fixture-post-repair-verification/ROLLBACK-RESULT.json" "$WORKDIR" <<'PY'
import sys
from pathlib import Path
src = Path(sys.argv[1])
dst = Path(sys.argv[2])
workdir = sys.argv[3]
dst.write_text(src.read_text(encoding='utf-8').replace('__FIXTURE_ROOT__', workdir), encoding='utf-8')
PY

python3 - "$TEMPLATE_DIR/runs/fixture-post-repair-verification/state.json" "$WORKDIR/runs/fixture-post-repair-verification/state.json" "$WORKDIR" <<'PY'
import sys
from pathlib import Path
src = Path(sys.argv[1])
dst = Path(sys.argv[2])
workdir = sys.argv[3]
dst.write_text(src.read_text(encoding='utf-8').replace('__FIXTURE_ROOT__', workdir), encoding='utf-8')
PY
state_load_resume_context "fixture-post-repair-verification"
POST_REPAIR_FINAL_STATUS="$RESUME_SOURCE_REPAIR_FINAL_STATUS"
POST_REPAIR_RERUN_STATUS="$RESUME_SOURCE_REPAIR_NGINX_TEST_RERUN_STATUS"

doctor_inspect_after_apply_output="$(state_doctor "fixture-inspect-after-apply-attention")"
assert_contains "$doctor_inspect_after_apply_output" "- resumed_from: fixture-legacy-fallback" "inspect-after-apply attention doctor prints resumed_from"
assert_contains "$doctor_inspect_after_apply_output" "当前 resume 策略：inspect-after-apply-attention。" "inspect-after-apply attention doctor prints resume strategy"
assert_contains "$doctor_inspect_after_apply_output" "操作建议：优先查看 apply result / recovery 建议，先理解为什么该 run 不推荐直接继续 apply。" "inspect-after-apply attention doctor prints operator guidance"
assert_contains "$doctor_inspect_after_apply_output" "- 当前策略优先产物：$WORKDIR/artifacts/fixture-inspect-after-apply-attention/APPLY-RESULT.json [apply-result]" "inspect-after-apply attention doctor prefers current apply artifact in lineage summary"
assert_contains "$doctor_inspect_after_apply_output" "- 说明：当前 run 已明确进入 inspect-after-apply-attention；应先看 apply result / recovery 字段，再决定后续动作。" "inspect-after-apply attention doctor explains current apply priority"
assert_contains "$doctor_inspect_after_apply_output" "- 祖先参考产物：$WORKDIR/artifacts/fixture-legacy-fallback/REPAIR-RESULT.json [repair-result]" "inspect-after-apply attention doctor keeps ancestor artifact as reference"
assert_contains "$doctor_inspect_after_apply_output" "- recovery.installer_status: $INSPECT_AFTER_APPLY_RECOVERY_STATUS" "inspect-after-apply attention doctor recovery status stays consistent with resume context"
assert_contains "$doctor_inspect_after_apply_output" "- recovery.resume_strategy: post-apply-review" "inspect-after-apply attention doctor prints apply recovery strategy"
assert_contains "$doctor_inspect_after_apply_output" "- recovery.resume_recommended: $INSPECT_AFTER_APPLY_RESUME_RECOMMENDED_BOOL" "inspect-after-apply attention doctor resume_recommended stays consistent with resume context"
assert_contains "$doctor_inspect_after_apply_output" "- recovery.operator_action: manual-review" "inspect-after-apply attention doctor prints operator action"
assert_contains "$doctor_inspect_after_apply_output" "- path: $WORKDIR/artifacts/fixture-inspect-after-apply-attention/REPAIR-RESULT.json" "inspect-after-apply attention doctor still prints repair result path"
assert_contains "$doctor_inspect_after_apply_output" "apply 已明确要求先人工复核；建议先检查当前 run 的 apply result 与 recovery 字段，再决定是否只做 dry-run 或人工处理。 当前不建议把 resume 当作默认下一步。" "inspect-after-apply attention doctor now prefers apply-result next step over conservative fallback"

python3 - "$WORKDIR/runs/fixture-inspect-after-apply-attention/state.json" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
obj = json.loads(path.read_text(encoding='utf-8'))
obj['status']['apply_execute'] = ''
obj['status']['final'] = 'needs-attention'
path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
PY
doctor_inspect_after_apply_semantic_drift_output="$(state_doctor "fixture-inspect-after-apply-attention")"
assert_contains "$doctor_inspect_after_apply_semantic_drift_output" "- current_run_alerts: final=needs-attention" "inspect-after-apply semantic drift still shows current final alert"
assert_contains "$doctor_inspect_after_apply_semantic_drift_output" "- current_run_priority_artifact: $WORKDIR/artifacts/fixture-inspect-after-apply-attention/APPLY-RESULT.json [apply-result]" "inspect-after-apply semantic drift still prefers apply artifact for current run summary"
assert_contains "$doctor_inspect_after_apply_semantic_drift_output" "- current_run_priority_note: 当前 run 已明确进入 inspect-after-apply-attention；应先看 apply result / recovery 字段，再决定后续动作。" "inspect-after-apply semantic drift current summary inherits strategy-specific note"
assert_not_contains "$doctor_inspect_after_apply_semantic_drift_output" "$WORKDIR/artifacts/fixture-inspect-after-apply-attention/REPAIR-RESULT.json [generic-artifact]" "inspect-after-apply semantic drift no longer lets generic repair artifact steal current priority"

python3 - "$WORKDIR/artifacts/fixture-inspect-after-apply-attention/REPAIR-RESULT.json" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
obj = json.loads(path.read_text(encoding='utf-8'))
obj['final_status'] = 'needs-attention'
obj['next_step'] = '【DRIFT-REPAIR】repair companion 抢到了建议位。'
path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
PY
doctor_inspect_after_apply_suggestion_drift_output="$(state_doctor "fixture-inspect-after-apply-attention")"
doctor_inspect_after_apply_suggestion_drift_next_step="$(printf '%s' "$doctor_inspect_after_apply_suggestion_drift_output" | extract_doctor_next_step_section)"
assert_contains "$doctor_inspect_after_apply_suggestion_drift_output" "当前 resume 策略：repair-review-first。" "inspect-after-apply suggestion drift upgrades strategy to repair review when companion result truth demands it"
assert_contains "$doctor_inspect_after_apply_suggestion_drift_output" "- 当前策略优先产物：$WORKDIR/artifacts/fixture-inspect-after-apply-attention/REPAIR-RESULT.json [repair-result]" "inspect-after-apply suggestion drift upgrades priority artifact to repair result"
assert_contains "$doctor_inspect_after_apply_suggestion_drift_next_step" "【DRIFT-REPAIR】repair companion 抢到了建议位。" "inspect-after-apply suggestion drift now follows repair-first truth when repair companion requires operator review"
assert_not_contains "$doctor_inspect_after_apply_suggestion_drift_next_step" "apply 已明确要求先人工复核；建议先检查当前 run 的 apply result 与 recovery 字段，再决定是否只做 dry-run 或人工处理。 当前不建议把 resume 当作默认下一步。" "inspect-after-apply suggestion drift no longer pins apply-first guidance against stronger repair review truth"

python3 - "$TEMPLATE_DIR/artifacts/fixture-inspect-after-apply-attention/REPAIR-RESULT.json" "$WORKDIR/artifacts/fixture-inspect-after-apply-attention/REPAIR-RESULT.json" "$WORKDIR" <<'PY'
import sys
from pathlib import Path
src = Path(sys.argv[1])
dst = Path(sys.argv[2])
workdir = sys.argv[3]
dst.write_text(src.read_text(encoding='utf-8').replace('__FIXTURE_ROOT__', workdir), encoding='utf-8')
PY

python3 - "$TEMPLATE_DIR/runs/fixture-inspect-after-apply-attention/state.json" "$WORKDIR/runs/fixture-inspect-after-apply-attention/state.json" "$WORKDIR" <<'PY'
import sys
from pathlib import Path
src = Path(sys.argv[1])
dst = Path(sys.argv[2])
workdir = sys.argv[3]
dst.write_text(src.read_text(encoding='utf-8').replace('__FIXTURE_ROOT__', workdir), encoding='utf-8')
PY
state_load_resume_context "fixture-inspect-after-apply-attention"
INSPECT_AFTER_APPLY_RESUME_RECOMMENDED_BOOL="$(bool_01_to_python_bool_text "$RESUME_SOURCE_APPLY_RESUME_RECOMMENDED")"
INSPECT_AFTER_APPLY_RECOVERY_STATUS="$RESUME_SOURCE_APPLY_RECOVERY_STATUS"

mv "$ROOT_DIR/scripts/generated/runs" "$ROOT_DIR/scripts/generated/runs.test-backup"
cp -a "$WORKDIR/runs" "$ROOT_DIR/scripts/generated/runs"
trap 'rm -rf "$ROOT_DIR/scripts/generated/runs"; mv "$ROOT_DIR/scripts/generated/runs.test-backup" "$ROOT_DIR/scripts/generated/runs"; rm -rf "$WORKDIR"' EXIT
set +e
inspect_after_apply_execute_output="$(bash "$ROOT_DIR/install-interactive.sh" --resume fixture-inspect-after-apply-attention --execute-apply --yes 2>&1)"
inspect_after_apply_execute_rc=$?
set -e
assert_equals "$inspect_after_apply_execute_rc" "2" "inspect-after-apply attention resume rejects explicit execute apply"
assert_contains "$inspect_after_apply_execute_output" "当前 resume 策略 inspect-after-apply-attention 不允许直接执行真实 apply" "inspect-after-apply attention execute refusal prints strategy-specific block"
assert_contains "$inspect_after_apply_execute_output" "这类 inspection-first 续接（包括 inspect-after-apply-attention / repair-review-first / post-repair-verification / post-rollback-inspection）必须先按 doctor / repair / rollback 结论完成复查。" "inspect-after-apply attention execute refusal explains inspection-first strategy family"
rm -rf "$ROOT_DIR/scripts/generated/runs"
mv "$ROOT_DIR/scripts/generated/runs.test-backup" "$ROOT_DIR/scripts/generated/runs"
trap 'rm -rf "$WORKDIR"' EXIT

doctor_missing_source_output="$(state_doctor "fixture-missing-source-state")"
assert_contains "$doctor_missing_source_output" "当前已解析到 2 段 lineage 链。" "missing source doctor prints lineage depth with sentinel"
assert_contains "$doctor_missing_source_output" "最近的异常祖先节点：fixture-missing-source-parent （state=missing）。" "missing source doctor highlights missing ancestor state"
assert_contains "$doctor_missing_source_output" "lineage 指向的 source run state.json 缺失或不可读；已停止继续向上解析。" "missing source doctor explains missing-state stop"
assert_contains "$doctor_missing_source_output" "- 2. [ancestor-1] fixture-missing-source-parent (checkpoint=缺失, final=missing-state; alerts=state=missing)" "missing source doctor prints missing-state lineage sentinel"

doctor_lineage_cycle_output="$(state_doctor "fixture-lineage-cycle-a")"
assert_contains "$doctor_lineage_cycle_output" "当前已解析到 3 段 lineage 链。" "lineage cycle doctor prints lineage depth with cycle sentinel"
assert_contains "$doctor_lineage_cycle_output" "最近的异常祖先节点：fixture-lineage-cycle-a [cycle] （state=lineage-cycle）。" "lineage cycle doctor highlights cycle sentinel"
assert_contains "$doctor_lineage_cycle_output" "检测到 lineage 循环引用；已停止继续向上解析。" "lineage cycle doctor explains cycle stop"
assert_contains "$doctor_lineage_cycle_output" "- 3. [ancestor-2] fixture-lineage-cycle-a [cycle] (checkpoint=循环, final=lineage-cycle; alerts=state=lineage-cycle)" "lineage cycle doctor prints cycle sentinel in lineage chain"

python3 - "$WORKDIR/runs/fixture-post-rollback-inspection/state.json" <<'PY'
import sys
from pathlib import Path
Path(sys.argv[1]).write_text('{broken json\n', encoding='utf-8')
PY
state_load_resume_context "fixture-source-priority-over-ancestor"
assert_equals "$RESUME_SOURCE_RESUMED_FROM" "fixture-post-rollback-inspection" "bad source state fixture keeps resumed_from clue"
assert_equals "$RESUME_SOURCE_REPAIR_RESULT_OWNER_RUN_ID" "" "bad source state fixture does not invent repair owner"
assert_equals "$RESUME_SOURCE_REPAIR_RESULT_JSON_PATH" "" "bad source state fixture does not invent repair json path"
assert_equals "$RESUME_SOURCE_ROLLBACK_RESULT_OWNER_RUN_ID" "" "bad source state fixture does not invent rollback owner"
assert_equals "$RESUME_SOURCE_ROLLBACK_RESULT_JSON_PATH" "" "bad source state fixture does not invent rollback json path"

python3 - "$WORKDIR/artifacts/fixture-post-repair-verification/REPAIR-RESULT.json" <<'PY'
import sys
from pathlib import Path
Path(sys.argv[1]).write_text('{bad repair json\n', encoding='utf-8')
PY
doctor_bad_repair_output="$(state_doctor "fixture-post-repair-verification")"
assert_contains "$doctor_bad_repair_output" "[doctor] repair result json" "bad repair json doctor still prints repair section header"
assert_contains "$doctor_bad_repair_output" "读取失败: $WORKDIR/artifacts/fixture-post-repair-verification/REPAIR-RESULT.json" "bad repair json doctor surfaces parse failure"
assert_contains "$doctor_bad_repair_output" "[doctor] apply result json" "bad repair json doctor continues to apply result section"
assert_contains "$doctor_bad_repair_output" "[doctor] rollback result json" "bad repair json doctor continues to rollback result section"
assert_contains "$doctor_bad_repair_output" "[doctor] 下一步建议" "bad repair json doctor still prints next step section"

python3 - "$WORKDIR/runs/fixture-legacy-fallback/inputs.env" <<'PY'
import sys
from pathlib import Path
Path(sys.argv[1]).write_text("DEPLOYMENT_NAME=fixture-legacy-fallback\nBASE_DOMAIN=github.example.com\nDOMAIN_MODE=flat-siblings\nPLATFORM=plain-nginx\nTLS_MODE=existing\nTLS_CERT=/tmp/cert.pem\nTLS_KEY=/tmp/key.pem\nINPUT_MODE=advanced\nINSTALL_INPUT_MODE=advanced\nERROR_ROOT=/tmp/errors\nLOG_DIR=/tmp/logs\nOUTPUT_DIR=./dist/fixture-legacy-fallback\nNGINX_SNIPPETS_TARGET_HINT=/tmp/snippets\nNGINX_VHOST_TARGET_HINT=/tmp/conf.d\nRUN_APPLY_DRY_RUN=0\nEXECUTE_APPLY=0\nBACKUP_DIR=''\nRUN_NGINX_TEST_AFTER_EXECUTE=0\nNGINX_TEST_CMD=nginx\\ -t\nASSUME_YES=0\nDEFAULT_ERROR_ROOT=/tmp/errors\nDEFAULT_LOG_DIR=/tmp/logs\nDEFAULT_OUTPUT_DIR=./dist/fixture-legacy-fallback\nDEFAULT_NGINX_SNIPPETS_TARGET_HINT=/tmp/snippets\nDEFAULT_NGINX_VHOST_TARGET_HINT=/tmp/conf.d\n", encoding='utf-8')
PY
state_load_inputs_env "fixture-legacy-fallback"
assert_equals "$DEPLOYMENT_NAME" "fixture-legacy-fallback" "valid inputs env still loads deployment name"
assert_equals "$TLS_MODE" "existing" "valid inputs env still loads tls mode"
assert_equals "$NGINX_TEST_CMD" "nginx -t" "valid inputs env still decodes escaped command string"

python3 - "$WORKDIR/runs/fixture-legacy-fallback/inputs.env" "$WORKDIR/inputs-loader-marker" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
marker = Path(sys.argv[2])
path.write_text(
    "DEPLOYMENT_NAME=fixture-legacy-fallback\n"
    f"MALICIOUS=$(touch {marker})\n",
    encoding='utf-8',
)
PY
set +e
state_load_inputs_env "fixture-legacy-fallback" >"$WORKDIR/state-load-inputs-unsafe.out" 2>"$WORKDIR/state-load-inputs-unsafe.err"
state_load_inputs_unsafe_rc=$?
set -e
assert_equals "$state_load_inputs_unsafe_rc" "2" "unexpected inputs env variable returns controlled error"
assert_contains "$(cat "$WORKDIR/state-load-inputs-unsafe.err")" "[state] 输入快照不可安全加载：$WORKDIR/runs/fixture-legacy-fallback/inputs.env" "unsafe inputs env prints controlled error"
if [[ -e "$WORKDIR/inputs-loader-marker" ]]; then
  echo "[FAIL] unsafe inputs env must not execute command substitution" >&2
  exit 1
fi

python3 - "$WORKDIR/runs/fixture-legacy-fallback/inputs.env" <<'PY'
import sys
from pathlib import Path
Path(sys.argv[1]).write_text("not a shell assignment\nBROKEN='unterminated\n", encoding='utf-8')
PY
set +e
state_load_inputs_env "fixture-legacy-fallback" >"$WORKDIR/state-load-inputs-bad.out" 2>"$WORKDIR/state-load-inputs-bad.err"
state_load_inputs_bad_rc=$?
set -e
assert_equals "$state_load_inputs_bad_rc" "2" "bad inputs env returns controlled error"
assert_contains "$(cat "$WORKDIR/state-load-inputs-bad.err")" "[state] 输入快照语法无效：$WORKDIR/runs/fixture-legacy-fallback/inputs.env" "bad inputs env prints syntax error"

python3 - "$WORKDIR/runs/fixture-legacy-fallback/journal.jsonl" <<'PY'
import sys
from pathlib import Path
Path(sys.argv[1]).write_text('{bad json line}\n{"ts":"2026-04-21T00:00:00Z","run_id":"fixture-legacy-fallback","event":"run.complete","status":"success","message":"ok"}\n', encoding='utf-8')
PY
doctor_bad_journal_output="$(state_doctor "fixture-legacy-fallback")"
assert_contains "$doctor_bad_journal_output" "[doctor] journal" "bad journal doctor still prints journal section"
assert_contains "$doctor_bad_journal_output" "- entries: 2" "bad journal doctor still counts non-empty lines"
assert_contains "$doctor_bad_journal_output" "- last_event: run.complete [success]" "bad journal doctor keeps last valid event"
assert_contains "$doctor_bad_journal_output" "- last_message: ok" "bad journal doctor keeps last valid event message"

python3 - "$TEMPLATE_DIR/artifacts/fixture-post-repair-verification/REPAIR-RESULT.json" "$WORKDIR/artifacts/fixture-post-repair-verification/REPAIR-RESULT.json" "$WORKDIR" <<'PY'
import sys
from pathlib import Path
src = Path(sys.argv[1])
dst = Path(sys.argv[2])
workdir = sys.argv[3]
dst.write_text(src.read_text(encoding='utf-8').replace('__FIXTURE_ROOT__', workdir), encoding='utf-8')
PY
python3 - "$WORKDIR/runs/fixture-post-repair-verification/state.json" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
obj = json.loads(path.read_text(encoding='utf-8'))
obj['lineage'].pop('resume_strategy', None)
obj['lineage'].pop('resume_strategy_reason', None)
obj['artifacts'].pop('apply_result_json', None)
path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
PY
state_load_resume_context "fixture-post-repair-verification"
assert_equals "${RESUME_SOURCE_APPLY_RESULT_JSON_PATH-}" "" "missing apply_result_json keeps resume apply result json empty"
assert_equals "$RESUME_SOURCE_REPAIR_RESULT_OWNER_RUN_ID" "fixture-post-repair-verification" "missing apply_result_json still keeps current repair owner"
doctor_missing_lineage_fields_output="$(state_doctor "fixture-post-repair-verification")"
assert_contains "$doctor_missing_lineage_fields_output" "- 当前 resume 策略：post-repair-verification。" "missing resume strategy doctor re-derives post repair strategy from companion result truth"
assert_contains "$doctor_missing_lineage_fields_output" "- 触发原因：source repair rerun nginx test already passed。" "missing resume strategy reason doctor re-derives post repair reason from companion result truth"
assert_contains "$doctor_missing_lineage_fields_output" "[doctor] repair result json" "missing apply_result_json doctor still prints repair result section"
assert_contains "$doctor_missing_lineage_fields_output" "- path: $WORKDIR/artifacts/fixture-post-repair-verification/REPAIR-RESULT.json" "missing apply_result_json doctor still resolves repair result path"
assert_contains "$doctor_missing_lineage_fields_output" "- 当前策略优先产物：$WORKDIR/artifacts/fixture-post-repair-verification/REPAIR-RESULT.json [repair-result]" "missing resume strategy doctor still keeps repair-first priority artifact"
assert_contains "$doctor_missing_lineage_fields_output" "[doctor] 下一步建议" "missing apply_result_json doctor still prints next step section"

python3 - "$WORKDIR/runs/fixture-post-repair-verification/state.json" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
obj = json.loads(path.read_text(encoding='utf-8'))
obj['lineage']['is_resumed_run'] = 'false'
path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
PY
doctor_lineage_string_false_output="$(state_doctor "fixture-post-repair-verification")"
assert_contains "$doctor_lineage_string_false_output" "- lineage.is_resumed_run: True" "string false resumed flag still resolves to effective resumed run"
assert_contains "$doctor_lineage_string_false_output" "- 这是一轮 resumed run：当前运行继承自 fixture-legacy-fallback（source checkpoint: completed）。" "string false resumed flag still prints resumed lineage summary"
assert_contains "$doctor_lineage_string_false_output" "- 当前 resume 策略：post-repair-verification。" "string false resumed flag still keeps effective post repair strategy text"

python3 - "$WORKDIR/runs/fixture-legacy-fallback/state.json" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
obj = json.loads(path.read_text(encoding='utf-8'))
obj['status'].pop('repair', None)
obj['status'].pop('final', None)
path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
PY
state_load_resume_context "fixture-legacy-fallback"
assert_equals "${RESUME_SOURCE_REPAIR_STATUS-}" "" "missing repair status keeps resume repair status empty"
assert_equals "${RESUME_SOURCE_FINAL_STATUS-}" "" "missing final status keeps resume final status empty"
assert_equals "$RESUME_SOURCE_REPAIR_RESULT_OWNER_RUN_ID" "fixture-legacy-fallback" "missing status keys still keep repair owner via companion result"
doctor_missing_status_fields_output="$(state_doctor "fixture-legacy-fallback")"
assert_contains "$doctor_missing_status_fields_output" "- repair: " "missing repair status doctor renders empty repair field"
assert_contains "$doctor_missing_status_fields_output" "- final: " "missing final status doctor renders empty final field"
assert_contains "$doctor_missing_status_fields_output" "[doctor] repair result json" "missing status keys doctor still prints repair result section"
assert_contains "$doctor_missing_status_fields_output" "当前处于 needs-attention；建议先复核诊断项，再决定是 rollback 还是人工修复后重跑 nginx -t。" "missing status keys doctor still derives suggestion from repair result"

python3 - "$TEMPLATE_DIR/runs/fixture-post-repair-verification/state.json" "$WORKDIR/runs/fixture-post-repair-verification/state.json" "$WORKDIR" <<'PY'
import sys
from pathlib import Path
src = Path(sys.argv[1])
dst = Path(sys.argv[2])
workdir = sys.argv[3]
dst.write_text(src.read_text(encoding='utf-8').replace('__FIXTURE_ROOT__', workdir), encoding='utf-8')
PY
python3 - "$TEMPLATE_DIR/artifacts/fixture-post-repair-verification/APPLY-RESULT.json" "$WORKDIR/artifacts/fixture-post-repair-verification/APPLY-RESULT.json" "$WORKDIR" <<'PY'
import sys
from pathlib import Path
src = Path(sys.argv[1])
dst = Path(sys.argv[2])
workdir = sys.argv[3]
dst.write_text(src.read_text(encoding='utf-8').replace('__FIXTURE_ROOT__', workdir), encoding='utf-8')
PY
python3 - "$TEMPLATE_DIR/artifacts/fixture-post-repair-verification/REPAIR-RESULT.json" "$WORKDIR/artifacts/fixture-post-repair-verification/REPAIR-RESULT.json" "$WORKDIR" <<'PY'
import sys
from pathlib import Path
src = Path(sys.argv[1])
dst = Path(sys.argv[2])
workdir = sys.argv[3]
dst.write_text(src.read_text(encoding='utf-8').replace('__FIXTURE_ROOT__', workdir), encoding='utf-8')
PY
python3 - "$TEMPLATE_DIR/artifacts/fixture-post-repair-verification/ROLLBACK-RESULT.json" "$WORKDIR/artifacts/fixture-post-repair-verification/ROLLBACK-RESULT.json" "$WORKDIR" <<'PY'
import sys
from pathlib import Path
src = Path(sys.argv[1])
dst = Path(sys.argv[2])
workdir = sys.argv[3]
dst.write_text(src.read_text(encoding='utf-8').replace('__FIXTURE_ROOT__', workdir), encoding='utf-8')
PY
python3 - "$WORKDIR/runs/fixture-post-repair-verification/state.json" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
obj = json.loads(path.read_text(encoding='utf-8'))
obj['status'] = 'broken-status'
obj['artifacts'] = 'broken-artifacts'
path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
PY
doctor_type_drift_top_level_output="$(state_doctor "fixture-post-repair-verification")"
assert_contains "$doctor_type_drift_top_level_output" "[doctor] 运行摘要" "top-level type drift doctor still prints run summary"
assert_contains "$doctor_type_drift_top_level_output" "[doctor] 状态" "top-level type drift doctor still prints status section"
assert_contains "$doctor_type_drift_top_level_output" "[doctor] 产物" "top-level type drift doctor still prints artifacts section"
assert_contains "$doctor_type_drift_top_level_output" "[doctor] 下一步建议" "top-level type drift doctor still prints next step section"
assert_contains "$doctor_type_drift_top_level_output" "当前处于 post-repair-verification；建议先跑 ./install-interactive.sh --doctor fixture-post-repair-verification 复核当前 run 与 companion result，再决定是否只做 dry-run、repair、rollback 或人工处理。" "top-level type drift doctor falls back to inspection-first suggestion instead of generic resume"
assert_contains "$doctor_type_drift_top_level_output" "- 当前 resume 策略：post-repair-verification。" "top-level type drift doctor still re-derives effective post repair strategy from companion result truth"

python3 - "$WORKDIR/runs/fixture-post-repair-verification/state.json" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
obj = json.loads(path.read_text(encoding='utf-8'))
obj['lineage'] = 'broken-lineage'
path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
PY
doctor_lineage_string_false_output="$(state_doctor "fixture-post-repair-verification")"
assert_contains "$doctor_lineage_string_false_output" "[doctor] 运行摘要" "lineage string false doctor still prints run summary"
assert_contains "$doctor_lineage_string_false_output" "[doctor] 状态" "lineage string false doctor still prints status section"
assert_contains "$doctor_lineage_string_false_output" "[doctor] 下一步建议" "lineage string false doctor still prints next step section"
assert_contains "$doctor_lineage_string_false_output" "可尝试执行 ./install-interactive.sh --resume fixture-post-repair-verification 继续；当前版本会复用已完成阶段，并从较安全的边界继续推进。" "lineage string false doctor falls back to generic resume suggestion when strategy is unavailable"

python3 - "$WORKDIR/runs/fixture-legacy-fallback/state.json" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
obj = json.loads(path.read_text(encoding='utf-8'))
obj['lineage'] = 'broken-lineage'
path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
PY
doctor_lineage_string_output="$(state_doctor "fixture-legacy-fallback")"
assert_contains "$doctor_lineage_string_output" "[doctor] 状态" "lineage string doctor still prints status section"
assert_contains "$doctor_lineage_string_output" "[doctor] apply result json" "lineage string doctor still prints apply result section"
assert_contains "$doctor_lineage_string_output" "[doctor] 下一步建议" "lineage string doctor still prints next step section"

python3 - "$WORKDIR/artifacts/fixture-current-apply-attention/APPLY-RESULT.json" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
obj = json.loads(path.read_text(encoding='utf-8'))
obj['recovery']['resume_recommended'] = 'false'
path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
PY
state_load_resume_context "fixture-current-apply-attention"
assert_equals "$RESUME_SOURCE_APPLY_RESUME_RECOMMENDED" "0" "string false resume recommended stays false in resume context"
doctor_value_drift_bool_output="$(state_doctor "fixture-current-apply-attention")"
assert_contains "$doctor_value_drift_bool_output" "- recovery.resume_recommended: false" "string false resume recommended still prints raw visible value"
assert_contains "$doctor_value_drift_bool_output" "当前不建议把 resume 当作默认下一步。" "string false resume recommended still disables resume default suggestion"

python3 - "$WORKDIR/artifacts/fixture-current-apply-attention/APPLY-RESULT.json" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
obj = json.loads(path.read_text(encoding='utf-8'))
obj['final_status'] = 'blocked'
obj['summary']['conflict'] = '2'
path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
PY
doctor_value_drift_conflict_output="$(state_doctor "fixture-current-apply-attention")"
assert_contains "$doctor_value_drift_conflict_output" "- summary.conflict: 2" "string numeric conflict still renders raw summary value"
assert_contains "$doctor_value_drift_conflict_output" "apply 结果显示存在冲突项；建议先处理目标文件冲突，再重新执行 apply / resume。" "string numeric conflict still triggers blocked-conflict suggestion"

python3 - "$WORKDIR/runs/fixture-legacy-fallback/state.json" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
obj = json.loads(path.read_text(encoding='utf-8'))
obj['status']['final'] = 'SUCCESS'
path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
PY
doctor_value_drift_enum_output="$(state_doctor "fixture-legacy-fallback")"
assert_contains "$doctor_value_drift_enum_output" "- final: SUCCESS" "unknown final enum still renders raw final value"
assert_contains "$doctor_value_drift_enum_output" "[doctor] repair result json" "unknown final enum doctor still prints repair result section"
assert_contains "$doctor_value_drift_enum_output" "当前处于 needs-attention；建议先复核诊断项，再决定是 rollback 还是人工修复后重跑 nginx -t。" "unknown final enum still prefers repair result suggestion over fake stable stop"

python3 - "$WORKDIR/runs/fixture-current-apply-attention/state.json" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
obj = json.loads(path.read_text(encoding='utf-8'))
obj['artifacts']['apply_result_json'] = str(Path(path).parents[1] / 'artifacts' / 'fixture-current-apply-attention' / 'MISSING-APPLY-RESULT.json')
path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
PY
state_load_resume_context "fixture-current-apply-attention"
assert_equals "$RESUME_SOURCE_REPAIR_RESULT_OWNER_RUN_ID" "fixture-current-apply-attention" "wrong apply result path still keeps current repair owner via companion fallback"
assert_equals "$RESUME_SOURCE_REPAIR_RESULT_JSON_PATH" "$WORKDIR/artifacts/fixture-current-apply-attention/REPAIR-RESULT.json" "wrong apply result path still resolves repair companion json"
doctor_artifact_drift_apply_path_output="$(state_doctor "fixture-current-apply-attention")"
assert_contains "$doctor_artifact_drift_apply_path_output" "- current_run_priority_artifact: $WORKDIR/artifacts/fixture-current-apply-attention/APPLY-RESULT.md [apply-result]" "wrong apply result path still prefers existing apply markdown artifact"
assert_not_contains "$doctor_artifact_drift_apply_path_output" "MISSING-APPLY-RESULT.json [apply-result]" "wrong apply result path no longer points priority hint at missing apply json"
assert_contains "$doctor_artifact_drift_apply_path_output" "[doctor] repair result json" "wrong apply result path doctor still prints repair result section"
assert_contains "$doctor_artifact_drift_apply_path_output" "- path: $WORKDIR/artifacts/fixture-current-apply-attention/REPAIR-RESULT.json" "wrong apply result path doctor still resolves repair result path"

python3 - "$TEMPLATE_DIR/runs/fixture-post-repair-verification/state.json" "$WORKDIR/runs/fixture-post-repair-verification/state.json" "$WORKDIR" <<'PY'
import sys
from pathlib import Path
src = Path(sys.argv[1])
dst = Path(sys.argv[2])
workdir = sys.argv[3]
dst.write_text(src.read_text(encoding='utf-8').replace('__FIXTURE_ROOT__', workdir), encoding='utf-8')
PY
rm -f "$WORKDIR/artifacts/fixture-post-repair-verification/REPAIR-RESULT.json"
doctor_artifact_drift_repair_missing_output="$(state_doctor "fixture-post-repair-verification")"
assert_contains "$doctor_artifact_drift_repair_missing_output" "- 当前策略优先产物：$WORKDIR/artifacts/fixture-post-repair-verification/REPAIR-RESULT.md [repair-result]" "missing repair json still prefers existing repair markdown artifact"
assert_contains "$doctor_artifact_drift_repair_missing_output" "当前处于 post-repair-verification，但结构化 repair 结果缺失或不可读；建议先查看当前 run 的 repair 结果文件，再确认 nginx -t 复查结论。" "missing repair json keeps post-repair verification suggestion conservative"
assert_not_contains "$doctor_artifact_drift_repair_missing_output" "./repair-applied-package.sh --result-json $WORKDIR/artifacts/fixture-post-repair-verification/APPLY-RESULT.json --dry-run" "missing repair json no longer falls back to apply-result-driven repair helper suggestion"

echo "[PASS] installer contract regression"
