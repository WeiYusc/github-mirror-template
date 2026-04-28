#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATED_DIR="$ROOT_DIR/scripts/generated"
RUNS_ROOT_DIR="$GENERATED_DIR/runs"
SUMMARY_PRIMARY="$GENERATED_DIR/INSTALLER-SUMMARY.generated.json"
TMP_DIR="$(mktemp -d)"
NEW_RUN_DIRS=()

backup_file() {
  local src="$1"
  local key="$2"
  if [[ -f "$src" ]]; then
    cp "$src" "$TMP_DIR/$key.bak"
    printf '1' > "$TMP_DIR/$key.exists"
  else
    printf '0' > "$TMP_DIR/$key.exists"
  fi
}

restore_file() {
  local src="$1"
  local key="$2"
  if [[ -f "$TMP_DIR/$key.exists" && "$(cat "$TMP_DIR/$key.exists")" == "1" ]]; then
    mkdir -p "$(dirname "$src")"
    cp "$TMP_DIR/$key.bak" "$src"
  else
    rm -f "$src"
  fi
}

register_new_run_dir() {
  local dir="$1"
  if [[ -n "$dir" && -d "$dir" ]]; then
    NEW_RUN_DIRS+=("$dir")
  fi
}

cleanup() {
  local dir
  for dir in "${NEW_RUN_DIRS[@]}"; do
    if [[ -d "$dir" ]]; then
      rm -rf "$dir"
    fi
  done
  restore_file "$SUMMARY_PRIMARY" summary_primary
  restore_file "$GENERATED_DIR/deploy.generated.yaml" deploy_generated
  restore_file "$GENERATED_DIR/preflight.generated.json" preflight_json
  restore_file "$GENERATED_DIR/preflight.generated.md" preflight_md
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$GENERATED_DIR" "$RUNS_ROOT_DIR"
backup_file "$SUMMARY_PRIMARY" summary_primary
backup_file "$GENERATED_DIR/deploy.generated.yaml" deploy_generated
backup_file "$GENERATED_DIR/preflight.generated.json" preflight_json
backup_file "$GENERATED_DIR/preflight.generated.md" preflight_md

rm -f "$SUMMARY_PRIMARY"
"$ROOT_DIR/install-interactive.sh" --help >/dev/null 2>/dev/null
if [[ -f "$SUMMARY_PRIMARY" ]]; then
  echo "[FAIL] --help polluted $SUMMARY_PRIMARY" >&2
  exit 1
fi

if "$ROOT_DIR/install-interactive.sh" \
  --deployment-name missing-yes \
  --base-domain smoke.example.com \
  --domain-mode flat-siblings \
  --platform plain-nginx \
  --tls-cert /tmp/fake-cert.pem \
  --tls-key /tmp/fake-key.pem \
  --input-mode basic \
  >/dev/null 2>"$TMP_DIR/missing-yes.stderr"; then
  echo "[FAIL] non-interactive new run without --yes unexpectedly succeeded" >&2
  exit 1
fi
if ! grep -q -- '--yes' "$TMP_DIR/missing-yes.stderr"; then
  echo "[FAIL] missing --yes error message not found" >&2
  cat "$TMP_DIR/missing-yes.stderr" >&2
  exit 1
fi

if "$ROOT_DIR/install-interactive.sh" \
  --deployment-name missing-input-mode \
  --base-domain smoke.example.com \
  --domain-mode flat-siblings \
  --platform plain-nginx \
  --tls-cert /tmp/fake-cert.pem \
  --tls-key /tmp/fake-key.pem \
  --yes \
  >/dev/null 2>"$TMP_DIR/missing-required.stderr"; then
  echo "[FAIL] non-interactive --yes run with missing required args unexpectedly succeeded" >&2
  exit 1
fi
if ! grep -q -- '--input-mode' "$TMP_DIR/missing-required.stderr"; then
  echo "[FAIL] missing required arg error message not found" >&2
  cat "$TMP_DIR/missing-required.stderr" >&2
  exit 1
fi

before_runs="$TMP_DIR/before-runs.txt"
after_runs="$TMP_DIR/after-runs.txt"
find "$RUNS_ROOT_DIR" -mindepth 1 -maxdepth 1 -type d | sort > "$before_runs"

smoke_name="smoke-ci-$(date +%s)-$$"
smoke_workspace="$TMP_DIR/smoke"
mkdir -p "$smoke_workspace/errors" "$smoke_workspace/logs" "$smoke_workspace/output" "$smoke_workspace/snippets" "$smoke_workspace/conf.d"

"$ROOT_DIR/install-interactive.sh" \
  --deployment-name "$smoke_name" \
  --base-domain smoke.example.com \
  --domain-mode flat-siblings \
  --platform plain-nginx \
  --tls-cert /tmp/fake-cert.pem \
  --tls-key /tmp/fake-key.pem \
  --input-mode advanced \
  --error-root "$smoke_workspace/errors" \
  --log-dir "$smoke_workspace/logs" \
  --output-dir "$smoke_workspace/output" \
  --snippets-target "$smoke_workspace/snippets" \
  --vhost-target "$smoke_workspace/conf.d" \
  --yes \
  >/dev/null 2>"$TMP_DIR/smoke.stderr"

find "$RUNS_ROOT_DIR" -mindepth 1 -maxdepth 1 -type d | sort > "$after_runs"
NEW_RUN_DIR="$(comm -13 "$before_runs" "$after_runs" | tail -n 1)"
if [[ -z "$NEW_RUN_DIR" || ! -d "$NEW_RUN_DIR" ]]; then
  echo "[FAIL] smoke run did not create a new run directory" >&2
  exit 1
fi
register_new_run_dir "$NEW_RUN_DIR"

state_json="$NEW_RUN_DIR/state.json"
summary_output="$smoke_workspace/output/INSTALLER-SUMMARY.json"
python3 - "$state_json" "$SUMMARY_PRIMARY" "$summary_output" "$smoke_name" <<'PY'
import json
import sys
from pathlib import Path

state_path = Path(sys.argv[1])
summary_primary_path = Path(sys.argv[2])
summary_output_path = Path(sys.argv[3])
expected_name = sys.argv[4]

if not state_path.exists():
    raise SystemExit(f"missing state.json: {state_path}")
if not summary_primary_path.exists():
    raise SystemExit(f"missing generated summary: {summary_primary_path}")
if not summary_output_path.exists():
    raise SystemExit(f"missing output summary: {summary_output_path}")

state = json.loads(state_path.read_text(encoding="utf-8"))
summary = json.loads(summary_primary_path.read_text(encoding="utf-8"))
output_summary = json.loads(summary_output_path.read_text(encoding="utf-8"))
journal = [json.loads(line) for line in (state_path.parent / "journal.jsonl").read_text(encoding="utf-8").splitlines() if line.strip()]

assert state["checkpoint"] == "completed", state
assert state["status"]["final"] == "success", state
assert state["note"] == f"installer completed status={state['status']['final']}", state
assert any(item["event"] == "run.complete" for item in journal), journal
assert journal[-1]["event"] == "run.exit", journal
assert journal[-1]["status"] == state["status"]["final"], (journal[-1], state)
assert summary["deployment_name"] == expected_name, summary
assert summary["status"]["final"] == state["status"]["final"], (summary, state)
assert summary["status"]["preflight"] == state["status"]["preflight"], (summary, state)
assert summary["status"]["generator"] == state["status"]["generator"], (summary, state)
assert summary["artifacts"]["run_id"] == state["run_id"], (summary, state)
assert summary["artifacts"]["state_json"] == str(state_path.resolve()), (summary, state)
assert output_summary["deployment_name"] == expected_name, output_summary
assert output_summary["status"]["final"] == state["status"]["final"], (output_summary, state)
PY

execute_name="smoke-exec-$(date +%s)-$$"
execute_workspace="$TMP_DIR/execute"
mkdir -p "$execute_workspace/errors-src" "$execute_workspace/logs" "$execute_workspace/output" "$execute_workspace/snippets-target" "$execute_workspace/conf-target" "$execute_workspace/error-target"
printf 'error page\n' > "$execute_workspace/errors-src/50x.html"

before_runs_exec="$TMP_DIR/before-runs-exec.txt"
after_runs_exec="$TMP_DIR/after-runs-exec.txt"
find "$RUNS_ROOT_DIR" -mindepth 1 -maxdepth 1 -type d | sort > "$before_runs_exec"

"$ROOT_DIR/install-interactive.sh" \
  --deployment-name "$execute_name" \
  --base-domain smoke.example.com \
  --domain-mode flat-siblings \
  --platform plain-nginx \
  --tls-cert /tmp/fake-cert.pem \
  --tls-key /tmp/fake-key.pem \
  --input-mode advanced \
  --error-root "$execute_workspace/error-target" \
  --log-dir "$execute_workspace/logs" \
  --output-dir "$execute_workspace/output" \
  --snippets-target "$execute_workspace/snippets-target" \
  --vhost-target "$execute_workspace/conf-target" \
  --execute-apply \
  --run-nginx-test \
  --nginx-test-cmd 'true' \
  --yes \
  >/dev/null 2>"$TMP_DIR/execute.stderr"

find "$RUNS_ROOT_DIR" -mindepth 1 -maxdepth 1 -type d | sort > "$after_runs_exec"
EXEC_RUN_DIR="$(comm -13 "$before_runs_exec" "$after_runs_exec" | tail -n 1)"
if [[ -z "$EXEC_RUN_DIR" || ! -d "$EXEC_RUN_DIR" ]]; then
  echo "[FAIL] execute smoke run did not create a new run directory" >&2
  exit 1
fi
register_new_run_dir "$EXEC_RUN_DIR"

execute_state_json="$EXEC_RUN_DIR/state.json"
execute_summary_output="$execute_workspace/output/INSTALLER-SUMMARY.json"
execute_apply_result_json="$execute_workspace/output/APPLY-RESULT.json"
python3 - "$execute_state_json" "$execute_summary_output" "$execute_apply_result_json" "$execute_workspace" <<'PY'
import json
import sys
from pathlib import Path

state_path = Path(sys.argv[1])
summary_output_path = Path(sys.argv[2])
apply_result_path = Path(sys.argv[3])
workspace = Path(sys.argv[4])

state = json.loads(state_path.read_text(encoding="utf-8"))
summary = json.loads(summary_output_path.read_text(encoding="utf-8"))
apply_result = json.loads(apply_result_path.read_text(encoding="utf-8"))

assert state["status"]["apply_execute"] == "success", state
assert state["status"]["final"] == "success", state
assert summary["status"]["apply_execute"] == "success", summary
assert summary["status"]["final"] == "success", summary
assert apply_result["mode"] == "execute", apply_result
assert apply_result["backup_dir"].startswith("./backups/"), apply_result
assert apply_result["nginx_test"]["requested"] is True, apply_result
assert apply_result["nginx_test"]["status"] == "passed", apply_result
assert apply_result["recovery"]["installer_status"] == "success", apply_result
assert apply_result["recovery"]["resume_strategy"] == "post-apply-review", apply_result
assert (workspace / "snippets-target").is_dir(), workspace
assert (workspace / "conf-target").is_dir(), workspace
assert (workspace / "error-target").is_dir(), workspace
assert any((workspace / "snippets-target").iterdir()), "snippets target empty"
assert any((workspace / "conf-target").iterdir()), "conf target empty"
assert any((workspace / "error-target").iterdir()), "error target empty"
PY

needs_name="smoke-needs-attention-$(date +%s)-$$"
needs_workspace="$TMP_DIR/needs-attention"
mkdir -p "$needs_workspace/logs" "$needs_workspace/output" "$needs_workspace/snippets-target" "$needs_workspace/conf-target" "$needs_workspace/error-target"

before_runs_needs="$TMP_DIR/before-runs-needs.txt"
after_runs_needs="$TMP_DIR/after-runs-needs.txt"
find "$RUNS_ROOT_DIR" -mindepth 1 -maxdepth 1 -type d | sort > "$before_runs_needs"

if ! "$ROOT_DIR/install-interactive.sh" \
  --deployment-name "$needs_name" \
  --base-domain smoke.example.com \
  --domain-mode flat-siblings \
  --platform plain-nginx \
  --tls-cert /tmp/fake-cert.pem \
  --tls-key /tmp/fake-key.pem \
  --input-mode advanced \
  --error-root "$needs_workspace/error-target" \
  --log-dir "$needs_workspace/logs" \
  --output-dir "$needs_workspace/output" \
  --snippets-target "$needs_workspace/snippets-target" \
  --vhost-target "$needs_workspace/conf-target" \
  --execute-apply \
  --run-nginx-test \
  --nginx-test-cmd 'false' \
  --yes \
  >/dev/null 2>"$TMP_DIR/needs.stderr"; then
  echo "[FAIL] needs-attention smoke run unexpectedly exited non-zero" >&2
  cat "$TMP_DIR/needs.stderr" >&2
  exit 1
fi

find "$RUNS_ROOT_DIR" -mindepth 1 -maxdepth 1 -type d | sort > "$after_runs_needs"
NEEDS_RUN_DIR="$(comm -13 "$before_runs_needs" "$after_runs_needs" | tail -n 1)"
if [[ -z "$NEEDS_RUN_DIR" || ! -d "$NEEDS_RUN_DIR" ]]; then
  echo "[FAIL] needs-attention smoke run did not create a new run directory" >&2
  exit 1
fi
register_new_run_dir "$NEEDS_RUN_DIR"

needs_state_json="$NEEDS_RUN_DIR/state.json"
needs_summary_output="$needs_workspace/output/INSTALLER-SUMMARY.json"
needs_apply_result_json="$needs_workspace/output/APPLY-RESULT.json"
python3 - "$needs_state_json" "$SUMMARY_PRIMARY" "$needs_summary_output" "$needs_apply_result_json" <<'PY'
import json
import sys
from pathlib import Path

state_path = Path(sys.argv[1])
summary_primary_path = Path(sys.argv[2])
summary_output_path = Path(sys.argv[3])
apply_result_path = Path(sys.argv[4])

state = json.loads(state_path.read_text(encoding="utf-8"))
summary_primary = json.loads(summary_primary_path.read_text(encoding="utf-8"))
summary_output = json.loads(summary_output_path.read_text(encoding="utf-8"))
apply_result = json.loads(apply_result_path.read_text(encoding="utf-8"))
journal = [json.loads(line) for line in (state_path.parent / "journal.jsonl").read_text(encoding="utf-8").splitlines() if line.strip()]

assert state["checkpoint"] == "completed", state
assert state["status"]["apply_execute"] == "needs-attention", state
assert state["status"]["final"] == "needs-attention", state
assert state["note"] == "installer completed status=needs-attention", state
assert summary_primary["status"]["apply_execute"] == "needs-attention", summary_primary
assert summary_primary["status"]["final"] == "needs-attention", summary_primary
assert summary_primary["status"]["exit_code"] == 0, summary_primary
assert summary_output["status"]["apply_execute"] == "needs-attention", summary_output
assert summary_output["status"]["final"] == "needs-attention", summary_output
assert apply_result["mode"] == "execute", apply_result
assert apply_result["nginx_test"]["requested"] is True, apply_result
assert apply_result["nginx_test"]["status"] == "failed", apply_result
assert apply_result["recovery"]["installer_status"] == "needs-attention", apply_result
assert apply_result["recovery"]["resume_strategy"] == "manual-recovery-first", apply_result
assert apply_result["recovery"]["operator_action"] == "rollback-or-fix", apply_result
assert journal[-2]["event"] == "run.complete", journal
assert journal[-2]["status"] == "needs-attention", journal
assert journal[-1]["event"] == "run.exit", journal
assert journal[-1]["status"] == "needs-attention", journal
assert journal[-1]["message"] == "exit_code=0", journal
PY

before_runs_resume_refusal="$TMP_DIR/before-runs-resume-refusal.txt"
after_runs_resume_refusal="$TMP_DIR/after-runs-resume-refusal.txt"
find "$RUNS_ROOT_DIR" -mindepth 1 -maxdepth 1 -type d | sort > "$before_runs_resume_refusal"

if "$ROOT_DIR/install-interactive.sh" \
  --resume "$(basename "$NEEDS_RUN_DIR")" \
  --execute-apply \
  --yes \
  >/dev/null 2>"$TMP_DIR/resume-refusal.stderr"; then
  echo "[FAIL] inspection-first resume refusal unexpectedly succeeded" >&2
  exit 1
fi

find "$RUNS_ROOT_DIR" -mindepth 1 -maxdepth 1 -type d | sort > "$after_runs_resume_refusal"
if [[ -n "$(comm -13 "$before_runs_resume_refusal" "$after_runs_resume_refusal")" ]]; then
  echo "[FAIL] inspection-first resume refusal unexpectedly created a new run directory" >&2
  exit 1
fi
if ! grep -q '不允许直接执行真实 apply' "$TMP_DIR/resume-refusal.stderr"; then
  echo "[FAIL] inspection-first resume refusal message not found" >&2
  cat "$TMP_DIR/resume-refusal.stderr" >&2
  exit 1
fi
if grep -q -- '--deployment-name' "$TMP_DIR/resume-refusal.stderr"; then
  echo "[FAIL] inspection-first resume refusal regressed to new-run validation error" >&2
  cat "$TMP_DIR/resume-refusal.stderr" >&2
  exit 1
fi

generator_fail_name="smoke-generator-fail-$(date +%s)-$$"
generator_fail_workspace="$TMP_DIR/generator-fail"
mkdir -p "$generator_fail_workspace/logs" "$generator_fail_workspace/output" "$generator_fail_workspace/snippets-target" "$generator_fail_workspace/conf-target" "$generator_fail_workspace/error-target"

before_runs_generator_fail="$TMP_DIR/before-runs-generator-fail.txt"
after_runs_generator_fail="$TMP_DIR/after-runs-generator-fail.txt"
find "$RUNS_ROOT_DIR" -mindepth 1 -maxdepth 1 -type d | sort > "$before_runs_generator_fail"

set +e
"$ROOT_DIR/install-interactive.sh" \
  --deployment-name "$generator_fail_name" \
  --base-domain invalidnodot \
  --domain-mode flat-siblings \
  --platform plain-nginx \
  --tls-cert /tmp/fake-cert.pem \
  --tls-key /tmp/fake-key.pem \
  --input-mode advanced \
  --error-root "$generator_fail_workspace/error-target" \
  --log-dir "$generator_fail_workspace/logs" \
  --output-dir "$generator_fail_workspace/output" \
  --snippets-target "$generator_fail_workspace/snippets-target" \
  --vhost-target "$generator_fail_workspace/conf-target" \
  --yes \
  >/dev/null 2>"$TMP_DIR/generator-fail.stderr"
generator_fail_rc=$?
set -e
if [[ "$generator_fail_rc" == "0" ]]; then
  echo "[FAIL] generator failure smoke run unexpectedly succeeded" >&2
  exit 1
fi
if [[ "$generator_fail_rc" != "1" ]]; then
  echo "[FAIL] generator failure smoke run returned unexpected rc: $generator_fail_rc" >&2
  cat "$TMP_DIR/generator-fail.stderr" >&2
  exit 1
fi

find "$RUNS_ROOT_DIR" -mindepth 1 -maxdepth 1 -type d | sort > "$after_runs_generator_fail"
GENERATOR_FAIL_RUN_DIR="$(comm -13 "$before_runs_generator_fail" "$after_runs_generator_fail" | tail -n 1)"
if [[ -z "$GENERATOR_FAIL_RUN_DIR" || ! -d "$GENERATOR_FAIL_RUN_DIR" ]]; then
  echo "[FAIL] generator failure smoke run did not create a new run directory" >&2
  exit 1
fi
register_new_run_dir "$GENERATOR_FAIL_RUN_DIR"
if ! grep -q 'flat-siblings mode requires BASE_DOMAIN to contain at least one dot' "$TMP_DIR/generator-fail.stderr"; then
  echo "[FAIL] generator failure reason not found in stderr" >&2
  cat "$TMP_DIR/generator-fail.stderr" >&2
  exit 1
fi

generator_fail_state_json="$GENERATOR_FAIL_RUN_DIR/state.json"
python3 - "$generator_fail_state_json" "$SUMMARY_PRIMARY" "$generator_fail_rc" <<'PY'
import json
import sys
from pathlib import Path

state_path = Path(sys.argv[1])
summary_primary_path = Path(sys.argv[2])
expected_rc = int(sys.argv[3])

state = json.loads(state_path.read_text(encoding="utf-8"))
summary_primary = json.loads(summary_primary_path.read_text(encoding="utf-8"))
journal = [json.loads(line) for line in (state_path.parent / "journal.jsonl").read_text(encoding="utf-8").splitlines() if line.strip()]

assert state["status"]["generator"] == "failed", state
assert state["status"]["final"] == "failed", state
assert state["checkpoint"] == "generator-running", state
assert state["note"] == "installer_on_exit", state
assert summary_primary["status"]["generator"] == "failed", summary_primary
assert summary_primary["status"]["final"] == "failed", summary_primary
assert summary_primary["status"]["exit_code"] == expected_rc, summary_primary
assert journal[-1]["event"] == "run.exit", journal
assert journal[-1]["status"] == "failed", journal
assert journal[-1]["message"] == f"exit_code={expected_rc}", journal
PY

resume_source_name="smoke-resume-source-$(date +%s)-$$"
resume_source_workspace="$TMP_DIR/resume-source"
mkdir -p "$resume_source_workspace/logs" "$resume_source_workspace/output" "$resume_source_workspace/snippets-target" "$resume_source_workspace/conf-target" "$resume_source_workspace/error-target"

before_runs_resume_source="$TMP_DIR/before-runs-resume-source.txt"
after_runs_resume_source="$TMP_DIR/after-runs-resume-source.txt"
find "$RUNS_ROOT_DIR" -mindepth 1 -maxdepth 1 -type d | sort > "$before_runs_resume_source"

"$ROOT_DIR/install-interactive.sh" \
  --deployment-name "$resume_source_name" \
  --base-domain smoke.example.com \
  --domain-mode flat-siblings \
  --platform plain-nginx \
  --tls-cert /tmp/fake-cert.pem \
  --tls-key /tmp/fake-key.pem \
  --input-mode advanced \
  --error-root "$resume_source_workspace/error-target" \
  --log-dir "$resume_source_workspace/logs" \
  --output-dir "$resume_source_workspace/output" \
  --snippets-target "$resume_source_workspace/snippets-target" \
  --vhost-target "$resume_source_workspace/conf-target" \
  --run-apply-dry-run \
  --yes \
  >/dev/null 2>"$TMP_DIR/resume-source.stderr"

find "$RUNS_ROOT_DIR" -mindepth 1 -maxdepth 1 -type d | sort > "$after_runs_resume_source"
RESUME_SOURCE_RUN_DIR="$(comm -13 "$before_runs_resume_source" "$after_runs_resume_source" | tail -n 1)"
if [[ -z "$RESUME_SOURCE_RUN_DIR" || ! -d "$RESUME_SOURCE_RUN_DIR" ]]; then
  echo "[FAIL] resume source smoke run did not create a new run directory" >&2
  exit 1
fi
register_new_run_dir "$RESUME_SOURCE_RUN_DIR"

before_runs_resume_positive="$TMP_DIR/before-runs-resume-positive.txt"
after_runs_resume_positive="$TMP_DIR/after-runs-resume-positive.txt"
find "$RUNS_ROOT_DIR" -mindepth 1 -maxdepth 1 -type d | sort > "$before_runs_resume_positive"

"$ROOT_DIR/install-interactive.sh" \
  --resume "$(basename "$RESUME_SOURCE_RUN_DIR")" \
  --run-apply-dry-run \
  --yes \
  >/dev/null 2>"$TMP_DIR/resume-positive.stderr"

find "$RUNS_ROOT_DIR" -mindepth 1 -maxdepth 1 -type d | sort > "$after_runs_resume_positive"
RESUME_POSITIVE_RUN_DIR="$(comm -13 "$before_runs_resume_positive" "$after_runs_resume_positive" | tail -n 1)"
if [[ -z "$RESUME_POSITIVE_RUN_DIR" || ! -d "$RESUME_POSITIVE_RUN_DIR" ]]; then
  echo "[FAIL] positive resume smoke run did not create a new run directory" >&2
  exit 1
fi
register_new_run_dir "$RESUME_POSITIVE_RUN_DIR"
if grep -q -- '--deployment-name' "$TMP_DIR/resume-positive.stderr"; then
  echo "[FAIL] positive resume smoke regressed to new-run validation error" >&2
  cat "$TMP_DIR/resume-positive.stderr" >&2
  exit 1
fi

resume_positive_state_json="$RESUME_POSITIVE_RUN_DIR/state.json"
resume_positive_summary_output="$resume_source_workspace/output/INSTALLER-SUMMARY.json"
resume_positive_apply_result_json="$resume_source_workspace/output/APPLY-RESULT.json"
python3 - "$resume_positive_state_json" "$RESUME_SOURCE_RUN_DIR/state.json" "$SUMMARY_PRIMARY" "$resume_positive_summary_output" "$resume_positive_apply_result_json" <<'PY'
import json
import sys
from pathlib import Path

state_path = Path(sys.argv[1])
source_state_path = Path(sys.argv[2])
summary_primary_path = Path(sys.argv[3])
summary_output_path = Path(sys.argv[4])
apply_result_path = Path(sys.argv[5])

state = json.loads(state_path.read_text(encoding="utf-8"))
source_state = json.loads(source_state_path.read_text(encoding="utf-8"))
summary_primary = json.loads(summary_primary_path.read_text(encoding="utf-8"))
summary_output = json.loads(summary_output_path.read_text(encoding="utf-8"))
apply_result = json.loads(apply_result_path.read_text(encoding="utf-8"))
journal = [json.loads(line) for line in (state_path.parent / "journal.jsonl").read_text(encoding="utf-8").splitlines() if line.strip()]
events = [item["event"] for item in journal]

run_dir = state_path.parent
expected_config = run_dir / "deploy.generated.yaml"
expected_preflight_md = run_dir / "preflight.generated.md"
expected_preflight_json = run_dir / "preflight.generated.json"
expected_summary_generated = run_dir / "INSTALLER-SUMMARY.generated.json"

assert state["lineage"]["mode"] == "resume", state
assert state["status"]["apply_execute"] != "success", state
assert state["status"]["final"] == summary_primary["status"]["final"], (state, summary_primary)
assert state["status"]["final"] == summary_output["status"]["final"], (state, summary_output)
assert Path(state["artifacts"]["config"]) == expected_config, state
assert Path(state["artifacts"]["preflight_markdown"]) == expected_preflight_md, state
assert Path(state["artifacts"]["preflight_json"]) == expected_preflight_json, state
assert Path(state["artifacts"]["summary_generated"]) == expected_summary_generated, state
assert expected_config.exists(), expected_config
assert expected_preflight_md.exists(), expected_preflight_md
assert expected_preflight_json.exists(), expected_preflight_json
assert expected_summary_generated.exists(), expected_summary_generated
assert state["artifacts"]["config"] != source_state["artifacts"]["config"], (state, source_state)
assert state["artifacts"]["preflight_markdown"] != source_state["artifacts"]["preflight_markdown"], (state, source_state)
assert state["artifacts"]["preflight_json"] != source_state["artifacts"]["preflight_json"], (state, source_state)
assert state["artifacts"]["summary_generated"] != source_state["artifacts"]["summary_generated"], (state, source_state)
assert apply_result["mode"] == "dry-run", apply_result
assert summary_primary["status"]["apply_execute"] == state["status"]["apply_execute"], (summary_primary, state)
assert summary_output["status"]["apply_execute"] == state["status"]["apply_execute"], (summary_output, state)
assert "inputs.reused" in events, journal
assert "preflight.reused" in events, journal
assert "generator.reused" in events, journal
assert "apply-plan.reused" in events, journal
preflight_reused = next(item for item in journal if item["event"] == "preflight.reused")
generator_reused = next(item for item in journal if item["event"] == "generator.reused")
apply_plan_reused = next(item for item in journal if item["event"] == "apply-plan.reused")
assert Path(preflight_reused["path"]) == expected_preflight_json, preflight_reused
assert Path(generator_reused["path"]) == expected_config, generator_reused
assert Path(apply_plan_reused["path"]) == expected_summary_generated, apply_plan_reused
assert journal[-2]["event"] == "run.complete", journal
assert journal[-1]["event"] == "run.exit", journal
assert journal[-1]["status"] == state["status"]["final"], (journal[-1], state)
PY

before_runs_inspect_resume="$TMP_DIR/before-runs-inspect-resume.txt"
after_runs_inspect_resume="$TMP_DIR/after-runs-inspect-resume.txt"
find "$RUNS_ROOT_DIR" -mindepth 1 -maxdepth 1 -type d | sort > "$before_runs_inspect_resume"

"$ROOT_DIR/install-interactive.sh" \
  --resume "$(basename "$NEEDS_RUN_DIR")" \
  --run-apply-dry-run \
  --yes \
  >"$TMP_DIR/inspect-resume.stdout" 2>"$TMP_DIR/inspect-resume.stderr"

find "$RUNS_ROOT_DIR" -mindepth 1 -maxdepth 1 -type d | sort > "$after_runs_inspect_resume"
INSPECT_RESUME_RUN_DIR="$(comm -13 "$before_runs_inspect_resume" "$after_runs_inspect_resume" | tail -n 1)"
if [[ -z "$INSPECT_RESUME_RUN_DIR" || ! -d "$INSPECT_RESUME_RUN_DIR" ]]; then
  echo "[FAIL] inspection-first positive resume smoke run did not create a new run directory" >&2
  exit 1
fi
register_new_run_dir "$INSPECT_RESUME_RUN_DIR"
if grep -q -- '--deployment-name' "$TMP_DIR/inspect-resume.stderr"; then
  echo "[FAIL] inspection-first positive resume regressed to new-run validation error" >&2
  cat "$TMP_DIR/inspect-resume.stderr" >&2
  exit 1
fi

inspect_resume_state_json="$INSPECT_RESUME_RUN_DIR/state.json"
inspect_resume_summary_output="$needs_workspace/output/INSTALLER-SUMMARY.json"
inspect_resume_apply_result_json="$needs_workspace/output/APPLY-RESULT.json"
python3 - "$inspect_resume_state_json" "$NEEDS_RUN_DIR/state.json" "$SUMMARY_PRIMARY" "$inspect_resume_summary_output" "$inspect_resume_apply_result_json" "$TMP_DIR/inspect-resume.stdout" "$TMP_DIR/inspect-resume.stderr" <<'PY'
import json
import sys
from pathlib import Path

state_path = Path(sys.argv[1])
source_state_path = Path(sys.argv[2])
summary_primary_path = Path(sys.argv[3])
summary_output_path = Path(sys.argv[4])
apply_result_path = Path(sys.argv[5])
stdout_path = Path(sys.argv[6])
stderr_path = Path(sys.argv[7])

state = json.loads(state_path.read_text(encoding="utf-8"))
source_state = json.loads(source_state_path.read_text(encoding="utf-8"))
summary_primary = json.loads(summary_primary_path.read_text(encoding="utf-8"))
summary_output = json.loads(summary_output_path.read_text(encoding="utf-8"))
apply_result = json.loads(apply_result_path.read_text(encoding="utf-8"))
stdout_text = stdout_path.read_text(encoding="utf-8")
stderr_text = stderr_path.read_text(encoding="utf-8")
journal = [json.loads(line) for line in (state_path.parent / "journal.jsonl").read_text(encoding="utf-8").splitlines() if line.strip()]
events = [item["event"] for item in journal]

run_dir = state_path.parent
expected_config = run_dir / "deploy.generated.yaml"
expected_preflight_md = run_dir / "preflight.generated.md"
expected_preflight_json = run_dir / "preflight.generated.json"
expected_summary_generated = run_dir / "INSTALLER-SUMMARY.generated.json"

assert state["lineage"]["mode"] == "resume", state
assert state["lineage"]["resume_strategy"] == "inspect-after-apply-attention", state
assert "resume as not recommended" in state["lineage"]["resume_strategy_reason"], state
assert state["status"]["apply_execute"] != "success", state
assert state["status"]["final"] == "success", state
assert state["status"]["final"] == summary_primary["status"]["final"], (state, summary_primary)
assert state["status"]["final"] == summary_output["status"]["final"], (state, summary_output)
assert Path(state["artifacts"]["config"]) == expected_config, state
assert Path(state["artifacts"]["preflight_markdown"]) == expected_preflight_md, state
assert Path(state["artifacts"]["preflight_json"]) == expected_preflight_json, state
assert Path(state["artifacts"]["summary_generated"]) == expected_summary_generated, state
assert expected_config.exists(), expected_config
assert expected_preflight_md.exists(), expected_preflight_md
assert expected_preflight_json.exists(), expected_preflight_json
assert expected_summary_generated.exists(), expected_summary_generated
assert state["artifacts"]["config"] != source_state["artifacts"]["config"], (state, source_state)
assert state["artifacts"]["preflight_markdown"] != source_state["artifacts"]["preflight_markdown"], (state, source_state)
assert state["artifacts"]["preflight_json"] != source_state["artifacts"]["preflight_json"], (state, source_state)
assert state["artifacts"]["summary_generated"] != source_state["artifacts"]["summary_generated"], (state, source_state)
assert apply_result["mode"] == "dry-run", apply_result
assert apply_result["recovery"]["resume_strategy"] == "dry-run-ok", apply_result
assert "inputs.reused" in events, journal
assert "preflight.reused" in events, journal
assert "generator.reused" in events, journal
assert "apply-plan.reused" in events, journal
preflight_reused = next(item for item in journal if item["event"] == "preflight.reused")
generator_reused = next(item for item in journal if item["event"] == "generator.reused")
apply_plan_reused = next(item for item in journal if item["event"] == "apply-plan.reused")
assert Path(preflight_reused["path"]) == expected_preflight_json, preflight_reused
assert Path(generator_reused["path"]) == expected_config, generator_reused
assert Path(apply_plan_reused["path"]) == expected_summary_generated, apply_plan_reused
assert journal[-2]["event"] == "run.complete", journal
assert journal[-1]["event"] == "run.exit", journal
assert journal[-1]["status"] == state["status"]["final"], (journal[-1], state)
assert "本次 resume 策略：inspect-after-apply-attention" in stdout_text, stdout_text
assert "inspection-first 续接" in stdout_text, stdout_text
assert "inspect-after-apply-attention / review-first 续接" in stderr_text, stderr_text
assert "默认不会继承上次的真实 apply / nginx test 执行意图" in stderr_text, stderr_text
PY

before_runs_doctor="$TMP_DIR/before-runs-doctor.txt"
after_runs_doctor="$TMP_DIR/after-runs-doctor.txt"
find "$RUNS_ROOT_DIR" -mindepth 1 -maxdepth 1 -type d | sort > "$before_runs_doctor"
rm -f "$SUMMARY_PRIMARY"

"$ROOT_DIR/install-interactive.sh" \
  --doctor "$(basename "$RESUME_SOURCE_RUN_DIR")" \
  >"$TMP_DIR/doctor.stdout" 2>"$TMP_DIR/doctor.stderr"

after_doctor_runs_check="$TMP_DIR/after-runs-doctor.txt"
find "$RUNS_ROOT_DIR" -mindepth 1 -maxdepth 1 -type d | sort > "$after_doctor_runs_check"
if [[ -n "$(comm -13 "$before_runs_doctor" "$after_doctor_runs_check")" ]]; then
  echo "[FAIL] doctor unexpectedly created a new run directory" >&2
  exit 1
fi
if [[ -f "$SUMMARY_PRIMARY" ]]; then
  echo "[FAIL] --doctor polluted $SUMMARY_PRIMARY" >&2
  exit 1
fi
if [[ -s "$TMP_DIR/doctor.stderr" ]]; then
  echo "[FAIL] --doctor unexpectedly wrote to stderr" >&2
  cat "$TMP_DIR/doctor.stderr" >&2
  exit 1
fi
python3 - "$TMP_DIR/doctor.stdout" "$(basename "$RESUME_SOURCE_RUN_DIR")" <<'PY'
import sys
from pathlib import Path

stdout_path = Path(sys.argv[1])
run_id = sys.argv[2]
text = stdout_path.read_text(encoding="utf-8")

assert f"run_id: {run_id}" in text, text
assert "[doctor] apply result json" in text, text
assert "- mode: dry-run" in text, text
assert "- recovery.resume_strategy: dry-run-ok" in text, text
assert "[doctor] journal" in text, text
assert "- last_event: run.exit [success]" in text, text
assert "[doctor] 下一步建议" in text, text
assert "可带 --execute-apply 继续真实 apply" in text, text
assert "inputs.env" in text, text
PY

echo "[PASS] installer smoke regression"
