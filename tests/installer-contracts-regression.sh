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

materialize_fixtures

# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/state.sh"
RUNS_ROOT_DIR="$WORKDIR/runs"

check_contract_set "fixture-legacy-fallback"
check_contract_set "fixture-resumed-repair-review"
check_contract_set "fixture-post-rollback-inspection"

state_load_resume_context "fixture-legacy-fallback"
assert_equals "$RESUME_SOURCE_REPAIR_RESULT_JSON_PATH" "$WORKDIR/artifacts/fixture-legacy-fallback/REPAIR-RESULT.json" "legacy fallback repair json path"
assert_equals "$RESUME_SOURCE_ROLLBACK_RESULT_JSON_PATH" "$WORKDIR/artifacts/fixture-legacy-fallback/ROLLBACK-RESULT.json" "legacy fallback rollback json path"
assert_equals "$RESUME_SOURCE_REPAIR_FINAL_STATUS" "needs-attention" "legacy fallback repair final status"
assert_equals "$RESUME_SOURCE_ROLLBACK_FINAL_STATUS" "ok" "legacy fallback rollback final status"
assert_equals "$RESUME_SOURCE_APPLY_RESUME_RECOMMENDED" "1" "legacy fallback apply resume recommended"

state_load_resume_context "fixture-resumed-repair-review"
assert_equals "$RESUME_SOURCE_RESUMED_FROM" "fixture-legacy-fallback" "resumed run resumed_from"
assert_equals "$RESUME_SOURCE_REPAIR_RESULT_JSON_PATH" "$WORKDIR/artifacts/fixture-resumed-repair-review/REPAIR-RESULT.json" "resumed run repair json fallback path"
assert_equals "$RESUME_SOURCE_REPAIR_FINAL_STATUS" "needs-attention" "resumed run repair final status"
assert_equals "$RESUME_SOURCE_ROLLBACK_FINAL_STATUS" "ok" "resumed run rollback final status"
assert_equals "$RESUME_SOURCE_ROLLBACK_EXECUTE" "0" "resumed run rollback execute flag"

state_load_resume_context "fixture-post-rollback-inspection"
assert_equals "$RESUME_SOURCE_RESUMED_FROM" "fixture-legacy-fallback" "post rollback run resumed_from"
assert_equals "$RESUME_SOURCE_ROLLBACK_RESULT_JSON_PATH" "$WORKDIR/artifacts/fixture-post-rollback-inspection/ROLLBACK-RESULT.json" "post rollback rollback json path"
assert_equals "$RESUME_SOURCE_ROLLBACK_FINAL_STATUS" "ok" "post rollback final status"
assert_equals "$RESUME_SOURCE_ROLLBACK_EXECUTE" "1" "post rollback execute flag"
assert_equals "$RESUME_SOURCE_REPAIR_FINAL_STATUS" "blocked" "post rollback repair final status"

doctor_legacy_output="$(state_doctor "fixture-legacy-fallback")"
assert_contains "$doctor_legacy_output" "[doctor] repair result json" "legacy doctor prints repair section"
assert_contains "$doctor_legacy_output" "$WORKDIR/artifacts/fixture-legacy-fallback/REPAIR-RESULT.json" "legacy doctor resolves repair fallback path"
assert_contains "$doctor_legacy_output" "[doctor] rollback result json" "legacy doctor prints rollback section"
assert_contains "$doctor_legacy_output" "$WORKDIR/artifacts/fixture-legacy-fallback/ROLLBACK-RESULT.json" "legacy doctor resolves rollback fallback path"

doctor_resumed_output="$(state_doctor "fixture-resumed-repair-review")"
assert_contains "$doctor_resumed_output" "当前 resume 策略：repair-review-first。" "resumed doctor prints resume strategy"
assert_contains "$doctor_resumed_output" "最近的异常祖先节点：fixture-legacy-fallback （repair=needs-attention）。" "resumed doctor prints abnormal ancestor"
assert_contains "$doctor_resumed_output" "$WORKDIR/artifacts/fixture-legacy-fallback/REPAIR-RESULT.json [repair-result]" "resumed doctor points to ancestor repair artifact"
assert_contains "$doctor_resumed_output" "- lineage.source_run_id: fixture-legacy-fallback" "resumed doctor machine summary source run"

doctor_post_rollback_output="$(state_doctor "fixture-post-rollback-inspection")"
assert_contains "$doctor_post_rollback_output" "当前 resume 策略：post-rollback-inspection。" "post rollback doctor prints resume strategy"
assert_contains "$doctor_post_rollback_output" "操作建议：优先核对 rollback 结果与当前落地文件状态，确认是否适合继续后续动作。" "post rollback doctor prints operator guidance"
assert_contains "$doctor_post_rollback_output" "$WORKDIR/artifacts/fixture-legacy-fallback/REPAIR-RESULT.json [repair-result]" "post rollback doctor points to ancestor repair artifact"
assert_contains "$doctor_post_rollback_output" "最近的异常祖先节点：fixture-legacy-fallback （repair=needs-attention）。" "post rollback doctor still highlights abnormal ancestor"

echo "[PASS] installer contract regression"
