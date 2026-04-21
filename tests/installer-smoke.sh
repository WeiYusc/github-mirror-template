#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATED_DIR="$ROOT_DIR/scripts/generated"
RUNS_ROOT_DIR="$GENERATED_DIR/runs"
SUMMARY_PRIMARY="$GENERATED_DIR/INSTALLER-SUMMARY.generated.json"
TMP_DIR="$(mktemp -d)"
NEW_RUN_DIR=""

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

cleanup() {
  if [[ -n "$NEW_RUN_DIR" && -d "$NEW_RUN_DIR" ]]; then
    rm -rf "$NEW_RUN_DIR"
  fi
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

echo "[PASS] installer smoke regression"
