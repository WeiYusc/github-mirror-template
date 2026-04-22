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
    fresh repair-review-first post-rollback-inspection post-repair-verification
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
    post-apply-review dry-run-ok repair-review-first
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

materialize_fixtures

# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/status-contracts.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/state.sh"
RUNS_ROOT_DIR="$WORKDIR/runs"

check_contract_set "fixture-legacy-fallback"
check_contract_set "fixture-resumed-repair-review"
check_contract_set "fixture-current-apply-attention"
check_contract_set "fixture-post-rollback-inspection"
check_contract_set "fixture-post-repair-verification"
# resume-only priority fixtures intentionally skip the full 6-contract bundle; they exist to pin state_load_resume_context lineage walk order.

check_stable_contract_smoke_matrix "fixture-legacy-fallback"
check_stable_contract_smoke_matrix "fixture-resumed-repair-review"
check_stable_contract_smoke_matrix "fixture-current-apply-attention"
check_stable_contract_smoke_matrix "fixture-post-rollback-inspection"
check_stable_contract_smoke_matrix "fixture-post-repair-verification"

check_contract_value_smoke_matrix "fixture-legacy-fallback"
check_contract_value_smoke_matrix "fixture-resumed-repair-review"
check_contract_value_smoke_matrix "fixture-current-apply-attention"
check_contract_value_smoke_matrix "fixture-post-rollback-inspection"
check_contract_value_smoke_matrix "fixture-post-repair-verification"

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

echo "[PASS] installer contract regression"
