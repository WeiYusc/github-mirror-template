#!/usr/bin/env bash
set -euo pipefail

state_now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

state_generate_run_id() {
  local ts rand
  ts="$(date -u +"%Y%m%dT%H%M%SZ")"
  rand="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(4))
PY
)"
  printf '%s-%s\n' "$ts" "$rand"
}

state_init_paths() {
  local runs_root="$1"
  local run_id="$2"

  RUNS_ROOT_DIR="$runs_root"
  RUN_ID="$run_id"
  STATE_DIR="$RUNS_ROOT_DIR/$RUN_ID"
  STATE_JSON_PATH="$STATE_DIR/state.json"
  STATE_JOURNAL_PATH="$STATE_DIR/journal.jsonl"
  STATE_INPUTS_PATH="$STATE_DIR/inputs.env"

  mkdir -p "$STATE_DIR"
}

state_init_run() {
  local runs_root="$1"
  local requested_run_id="${2:-}"

  if [[ -n "$requested_run_id" ]]; then
    state_init_paths "$runs_root" "$requested_run_id"
  else
    state_init_paths "$runs_root" "$(state_generate_run_id)"
  fi
}

state_append_journal() {
  local event="$1"
  local status="$2"
  local message="${3:-}"
  local path_value="${4:-}"

  mkdir -p "$(dirname "$STATE_JOURNAL_PATH")"

  python3 - "$STATE_JOURNAL_PATH" "$RUN_ID" "$event" "$status" "$message" "$path_value" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

journal_path, run_id, event, status, message, path_value = sys.argv[1:]
record = {
    "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "run_id": run_id,
    "event": event,
    "status": status,
}
if message:
    record["message"] = message
if path_value:
    record["path"] = path_value
Path(journal_path).parent.mkdir(parents=True, exist_ok=True)
with Path(journal_path).open("a", encoding="utf-8") as fh:
    fh.write(json.dumps(record, ensure_ascii=False) + "\n")
PY
}

state_write_inputs_env() {
  mkdir -p "$(dirname "$STATE_INPUTS_PATH")"

  cat > "$STATE_INPUTS_PATH" <<EOF
DEPLOYMENT_NAME=$(printf '%q' "${DEPLOYMENT_NAME:-}")
BASE_DOMAIN=$(printf '%q' "${BASE_DOMAIN:-}")
DOMAIN_MODE=$(printf '%q' "${DOMAIN_MODE:-}")
PLATFORM=$(printf '%q' "${PLATFORM:-}")
TLS_CERT=$(printf '%q' "${TLS_CERT:-}")
TLS_KEY=$(printf '%q' "${TLS_KEY:-}")
INPUT_MODE=$(printf '%q' "${INPUT_MODE:-}")
INSTALL_INPUT_MODE=$(printf '%q' "${INSTALL_INPUT_MODE:-}")
ERROR_ROOT=$(printf '%q' "${ERROR_ROOT:-}")
LOG_DIR=$(printf '%q' "${LOG_DIR:-}")
OUTPUT_DIR=$(printf '%q' "${OUTPUT_DIR:-}")
NGINX_SNIPPETS_TARGET_HINT=$(printf '%q' "${NGINX_SNIPPETS_TARGET_HINT:-}")
NGINX_VHOST_TARGET_HINT=$(printf '%q' "${NGINX_VHOST_TARGET_HINT:-}")
RUN_APPLY_DRY_RUN=$(printf '%q' "${RUN_APPLY_DRY_RUN:-0}")
EXECUTE_APPLY=$(printf '%q' "${EXECUTE_APPLY:-0}")
BACKUP_DIR=$(printf '%q' "${BACKUP_DIR:-}")
RUN_NGINX_TEST_AFTER_EXECUTE=$(printf '%q' "${RUN_NGINX_TEST_AFTER_EXECUTE:-0}")
NGINX_TEST_CMD=$(printf '%q' "${NGINX_TEST_CMD:-nginx -t}")
ASSUME_YES=$(printf '%q' "${ASSUME_YES:-0}")
DEFAULT_ERROR_ROOT=$(printf '%q' "${DEFAULT_ERROR_ROOT:-}")
DEFAULT_LOG_DIR=$(printf '%q' "${DEFAULT_LOG_DIR:-}")
DEFAULT_OUTPUT_DIR=$(printf '%q' "${DEFAULT_OUTPUT_DIR:-}")
DEFAULT_NGINX_SNIPPETS_TARGET_HINT=$(printf '%q' "${DEFAULT_NGINX_SNIPPETS_TARGET_HINT:-}")
DEFAULT_NGINX_VHOST_TARGET_HINT=$(printf '%q' "${DEFAULT_NGINX_VHOST_TARGET_HINT:-}")
EOF
}

state_load_inputs_env() {
  local run_id="$1"
  local parsed_assignments=""
  state_init_paths "$RUNS_ROOT_DIR" "$run_id"

  if [[ ! -f "$STATE_INPUTS_PATH" ]]; then
    echo "[state] 未找到输入快照：$STATE_INPUTS_PATH" >&2
    return 1
  fi

  if ! bash -n "$STATE_INPUTS_PATH" >/dev/null 2>&1; then
    echo "[state] 输入快照语法无效：$STATE_INPUTS_PATH" >&2
    return 2
  fi

  if ! parsed_assignments="$(python3 - "$STATE_INPUTS_PATH" <<'PY'
import re
import shlex
import sys
from pathlib import Path

path = Path(sys.argv[1])
allowed = {
    "DEPLOYMENT_NAME",
    "BASE_DOMAIN",
    "DOMAIN_MODE",
    "PLATFORM",
    "TLS_CERT",
    "TLS_KEY",
    "INPUT_MODE",
    "INSTALL_INPUT_MODE",
    "ERROR_ROOT",
    "LOG_DIR",
    "OUTPUT_DIR",
    "NGINX_SNIPPETS_TARGET_HINT",
    "NGINX_VHOST_TARGET_HINT",
    "RUN_APPLY_DRY_RUN",
    "EXECUTE_APPLY",
    "BACKUP_DIR",
    "RUN_NGINX_TEST_AFTER_EXECUTE",
    "NGINX_TEST_CMD",
    "ASSUME_YES",
    "DEFAULT_ERROR_ROOT",
    "DEFAULT_LOG_DIR",
    "DEFAULT_OUTPUT_DIR",
    "DEFAULT_NGINX_SNIPPETS_TARGET_HINT",
    "DEFAULT_NGINX_VHOST_TARGET_HINT",
}
seen = set()
for lineno, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
    line = raw_line.strip()
    if not line:
        continue
    if "=" not in raw_line:
        raise SystemExit(f"line {lineno}: missing assignment operator")
    name, encoded = raw_line.split("=", 1)
    if not re.fullmatch(r"[A-Z0-9_]+", name):
        raise SystemExit(f"line {lineno}: invalid variable name {name!r}")
    if name not in allowed:
        raise SystemExit(f"line {lineno}: unexpected variable {name}")
    if name in seen:
        raise SystemExit(f"line {lineno}: duplicate variable {name}")
    seen.add(name)
    try:
        tokens = shlex.split(encoded, posix=True)
    except ValueError as exc:
        raise SystemExit(f"line {lineno}: {exc}")
    if len(tokens) != 1:
        raise SystemExit(f"line {lineno}: assignment must decode to exactly one token")
    value = tokens[0]
    print(f"{name}={shlex.quote(value)}")
PY
)"; then
    echo "[state] 输入快照不可安全加载：$STATE_INPUTS_PATH" >&2
    return 2
  fi

  eval "$parsed_assignments"
}

state_load_resume_context() {
  local run_id="$1"
  local state_json="$RUNS_ROOT_DIR/$run_id/state.json"

  if [[ ! -f "$state_json" ]]; then
    echo "[state] 未找到历史 state.json：$state_json" >&2
    return 1
  fi

  eval "$(python3 - "$state_json" <<'PY'
import json
import shlex
import sys
from pathlib import Path

state_path = Path(sys.argv[1]).resolve()
runs_root = state_path.parent.parent
state = json.loads(state_path.read_text(encoding="utf-8"))
status = state.get("status", {})
artifacts = state.get("artifacts", {})
apply_result_path = artifacts.get("apply_result_json", "")
apply_result = {}
if apply_result_path and Path(apply_result_path).exists():
    try:
        apply_result = json.loads(Path(apply_result_path).read_text(encoding="utf-8"))
    except Exception:
        apply_result = {}
recovery = apply_result.get("recovery") or {}


def load_state_by_run_id(run_id: str):
    if not run_id:
        return None
    path = runs_root / run_id / "state.json"
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def with_companion_fallback(artifacts_map: dict):
    resolved = dict(artifacts_map)
    apply_result_json = resolved.get("apply_result_json") or ""
    apply_result_md = resolved.get("apply_result") or ""
    base_dir = None
    if apply_result_json:
        base_dir = Path(apply_result_json).parent
    elif apply_result_md:
        base_dir = Path(apply_result_md).parent
    if base_dir is not None:
        if not resolved.get("repair_result_json"):
            candidate = base_dir / "REPAIR-RESULT.json"
            if candidate.exists():
                resolved["repair_result_json"] = str(candidate)
        if not resolved.get("repair_result"):
            candidate = base_dir / "REPAIR-RESULT.md"
            if candidate.exists():
                resolved["repair_result"] = str(candidate)
        if not resolved.get("rollback_result_json"):
            candidate = base_dir / "ROLLBACK-RESULT.json"
            if candidate.exists():
                resolved["rollback_result_json"] = str(candidate)
        if not resolved.get("rollback_result"):
            candidate = base_dir / "ROLLBACK-RESULT.md"
            if candidate.exists():
                resolved["rollback_result"] = str(candidate)
    return resolved


def resolve_companion_result(cur_state: dict, kind: str, visited: set[str]):
    run_id = cur_state.get("run_id", "") or ""
    if run_id in visited:
        return None
    visited.add(run_id)

    cur_artifacts = with_companion_fallback(cur_state.get("artifacts") or {})
    json_key = f"{kind}_result_json"
    md_key = f"{kind}_result"
    candidate_json = cur_artifacts.get(json_key) or ""
    candidate_md = cur_artifacts.get(md_key) or ""

    if candidate_json and Path(candidate_json).exists():
        payload = {}
        try:
            payload = json.loads(Path(candidate_json).read_text(encoding="utf-8"))
        except Exception:
            payload = {}
        if not candidate_md:
            candidate_md = str(Path(candidate_json).with_name(f"{kind.upper()}-RESULT.md"))
        return {
            "owner_run_id": run_id,
            "json_path": candidate_json,
            "markdown_path": candidate_md,
            "payload": payload,
        }

    if candidate_md and Path(candidate_md).exists():
        return {
            "owner_run_id": run_id,
            "json_path": candidate_json,
            "markdown_path": candidate_md,
            "payload": {},
        }

    parent_run_id = cur_state.get("resumed_from") or (cur_state.get("lineage") or {}).get("source_run_id") or ""
    if parent_run_id:
        parent_state = load_state_by_run_id(parent_run_id)
        if parent_state is not None:
            resolved = resolve_companion_result(parent_state, kind, visited)
            if resolved is not None:
                return resolved

    if candidate_json or candidate_md:
        return {
            "owner_run_id": run_id,
            "json_path": candidate_json,
            "markdown_path": candidate_md,
            "payload": {},
        }

    return None


repair_resolved = resolve_companion_result(state, "repair", set()) or {}
rollback_resolved = resolve_companion_result(state, "rollback", set()) or {}
repair_result_json_path = repair_resolved.get("json_path", "")
rollback_result_json_path = rollback_resolved.get("json_path", "")
repair_result_path = repair_resolved.get("markdown_path", "")
rollback_result_path = rollback_resolved.get("markdown_path", "")
repair_result = repair_resolved.get("payload") or {}
rollback_result = rollback_resolved.get("payload") or {}
repair_execution = repair_result.get("execution") or {}
rollback_flags = rollback_result.get("flags") or {}

values = {
    "RESUME_SOURCE_RUN_ID": state.get("run_id", ""),
    "RESUME_SOURCE_CHECKPOINT": state.get("checkpoint", ""),
    "RESUME_SOURCE_RESUMED_FROM": state.get("resumed_from", ""),
    "RESUME_SOURCE_PREFLIGHT_STATUS": status.get("preflight", ""),
    "RESUME_SOURCE_GENERATOR_STATUS": status.get("generator", ""),
    "RESUME_SOURCE_APPLY_PLAN_STATUS": status.get("apply_plan", ""),
    "RESUME_SOURCE_DRY_RUN_STATUS": status.get("apply_dry_run", ""),
    "RESUME_SOURCE_EXECUTE_STATUS": status.get("apply_execute", ""),
    "RESUME_SOURCE_FINAL_STATUS": status.get("final", ""),
    "RESUME_SOURCE_REPAIR_STATUS": status.get("repair", ""),
    "RESUME_SOURCE_ROLLBACK_STATUS": status.get("rollback", ""),
    "RESUME_SOURCE_CONFIG_PATH": artifacts.get("config", ""),
    "RESUME_SOURCE_OUTPUT_DIR_ABS": artifacts.get("output_dir_abs", ""),
    "RESUME_SOURCE_PREFLIGHT_REPORT_MD": artifacts.get("preflight_markdown", ""),
    "RESUME_SOURCE_PREFLIGHT_REPORT_JSON": artifacts.get("preflight_json", ""),
    "RESUME_SOURCE_APPLY_PLAN_PATH": artifacts.get("apply_plan_markdown", ""),
    "RESUME_SOURCE_APPLY_PLAN_JSON_PATH": artifacts.get("apply_plan_json", ""),
    "RESUME_SOURCE_APPLY_RESULT_PATH": artifacts.get("apply_result", ""),
    "RESUME_SOURCE_APPLY_RESULT_JSON_PATH": artifacts.get("apply_result_json", ""),
    "RESUME_SOURCE_REPAIR_RESULT_OWNER_RUN_ID": repair_resolved.get("owner_run_id", ""),
    "RESUME_SOURCE_REPAIR_RESULT_PATH": repair_result_path,
    "RESUME_SOURCE_REPAIR_RESULT_JSON_PATH": repair_result_json_path,
    "RESUME_SOURCE_ROLLBACK_RESULT_OWNER_RUN_ID": rollback_resolved.get("owner_run_id", ""),
    "RESUME_SOURCE_ROLLBACK_RESULT_PATH": rollback_result_path,
    "RESUME_SOURCE_ROLLBACK_RESULT_JSON_PATH": rollback_result_json_path,
    "RESUME_SOURCE_APPLY_RECOVERY_STATUS": recovery.get("installer_status", ""),
    "RESUME_SOURCE_APPLY_RESUME_STRATEGY": recovery.get("resume_strategy", ""),
    "RESUME_SOURCE_APPLY_RESUME_RECOMMENDED": "1" if recovery.get("resume_recommended", True) else "0",
    "RESUME_SOURCE_APPLY_OPERATOR_ACTION": recovery.get("operator_action", ""),
    "RESUME_SOURCE_APPLY_NEXT_STEP": apply_result.get("next_step", ""),
    "RESUME_SOURCE_REPAIR_FINAL_STATUS": repair_result.get("final_status", ""),
    "RESUME_SOURCE_REPAIR_MODE": repair_result.get("mode", ""),
    "RESUME_SOURCE_REPAIR_NGINX_TEST_RERUN_STATUS": repair_execution.get("nginx_test_rerun_status", ""),
    "RESUME_SOURCE_REPAIR_NEXT_STEP": repair_result.get("next_step", ""),
    "RESUME_SOURCE_ROLLBACK_FINAL_STATUS": rollback_result.get("final_status", ""),
    "RESUME_SOURCE_ROLLBACK_MODE": rollback_result.get("mode", ""),
    "RESUME_SOURCE_ROLLBACK_EXECUTE": "1" if rollback_flags.get("execute", False) else "0",
    "RESUME_SOURCE_ROLLBACK_NEXT_STEP": rollback_result.get("next_step", ""),
    "RESUME_SOURCE_SUMMARY_JSON_PRIMARY": artifacts.get("summary_generated", ""),
    "RESUME_SOURCE_SUMMARY_JSON_SECONDARY": artifacts.get("summary_output", ""),
    "RESUME_SOURCE_INPUTS_ENV": artifacts.get("inputs_env", ""),
    "RESUME_SOURCE_JOURNAL_JSONL": artifacts.get("journal_jsonl", ""),
}
for key, value in values.items():
    print(f"{key}={shlex.quote(str(value))}")
PY
)"
}

state_json_bool() {
  if [[ "${1:-0}" == "1" ]]; then
    printf 'true'
  else
    printf 'false'
  fi
}

installer_determine_final_status() {
  if [[ "${INSTALLER_PREFLIGHT_STATUS:-pending}" == "blocked" ]]; then
    printf 'blocked'
  elif [[ "${INSTALLER_GENERATOR_STATUS:-pending}" == "failed" ]]; then
    printf 'failed'
  elif [[ "${INSTALLER_DRY_RUN_STATUS:-not-requested}" == "failed" ]]; then
    printf 'failed'
  elif [[ "${INSTALLER_EXECUTE_STATUS:-not-requested}" == "failed" ]]; then
    printf 'failed'
  elif [[ "${INSTALLER_EXECUTE_STATUS:-not-requested}" == "needs-attention" ]]; then
    printf 'needs-attention'
  elif [[ "${INSTALLER_EXECUTE_STATUS:-not-requested}" == "cancelled" ]]; then
    printf 'cancelled'
  elif [[ "${INSTALLER_FINAL_STATUS:-running}" == "cancelled" ]]; then
    printf 'cancelled'
  elif [[ "${INSTALLER_CHECKPOINT:-initialized}" != "completed" ]]; then
    printf 'failed'
  else
    printf 'success'
  fi
}

write_installer_summary_json() {
  local target_path="$1"
  local exit_code="${2:-0}"
  local final_status="${INSTALLER_FINAL_STATUS:-running}"
  local apply_result_exists="false"
  local apply_result_json_exists="false"

  if [[ "$final_status" == "running" ]]; then
    if [[ "$exit_code" == "0" ]]; then
      final_status="$(installer_determine_final_status)"
    elif [[ "${INSTALLER_PREFLIGHT_STATUS:-pending}" == "blocked" ]]; then
      final_status="blocked"
    else
      final_status="failed"
    fi
  fi

  if [[ -n "${APPLY_RESULT_PATH:-}" && -f "$APPLY_RESULT_PATH" ]]; then
    apply_result_exists="true"
  fi
  if [[ -n "${APPLY_RESULT_JSON_PATH:-}" && -f "$APPLY_RESULT_JSON_PATH" ]]; then
    apply_result_json_exists="true"
  fi

  mkdir -p "$(dirname "$target_path")"

  python3 - "$target_path" "$exit_code" "$final_status" "$apply_result_exists" "$apply_result_json_exists" <<'PY'
import json
import os
import sys
from pathlib import Path

(target_path, exit_code, final_status, apply_result_exists, apply_result_json_exists) = sys.argv[1:]

def env(name: str, default: str = ""):
    return os.environ.get(name, default)

payload = {
    "schema_kind": "installer-summary",
    "schema_version": 1,
    "deployment_name": env("DEPLOYMENT_NAME"),
    "base_domain": env("BASE_DOMAIN"),
    "domain_mode": env("DOMAIN_MODE"),
    "platform": env("PLATFORM"),
    "input_mode": env("INSTALL_INPUT_MODE") or env("INPUT_MODE"),
    "flags": {
        "assume_yes": env("ASSUME_YES", "0") == "1",
        "run_apply_dry_run": env("RUN_APPLY_DRY_RUN", "0") == "1",
        "execute_apply": env("EXECUTE_APPLY", "0") == "1",
        "run_nginx_test_after_execute": env("RUN_NGINX_TEST_AFTER_EXECUTE", "0") == "1",
    },
    "status": {
        "preflight": env("INSTALLER_PREFLIGHT_STATUS", "pending"),
        "generator": env("INSTALLER_GENERATOR_STATUS", "pending"),
        "apply_plan": env("INSTALLER_APPLY_PLAN_STATUS", "pending"),
        "apply_dry_run": env("INSTALLER_DRY_RUN_STATUS", "not-requested"),
        "apply_execute": env("INSTALLER_EXECUTE_STATUS", "not-requested"),
        "final": final_status,
        "exit_code": int(exit_code),
    },
    "artifacts": {
        "preflight_markdown": env("PREFLIGHT_REPORT_MD"),
        "preflight_json": env("PREFLIGHT_REPORT_JSON"),
        "config": env("CONFIG_PATH"),
        "output_dir": env("OUTPUT_DIR_ABS"),
        "apply_plan_markdown": env("APPLY_PLAN_PATH"),
        "apply_plan_json": env("APPLY_PLAN_JSON_PATH"),
        "apply_result": env("APPLY_RESULT_PATH"),
        "apply_result_json": env("APPLY_RESULT_JSON_PATH"),
        "summary_generated": env("SUMMARY_JSON_PRIMARY"),
        "summary_output": env("SUMMARY_JSON_SECONDARY"),
        "state_dir": env("STATE_DIR"),
        "state_json": env("STATE_JSON_PATH"),
        "journal_jsonl": env("STATE_JOURNAL_PATH"),
        "run_id": env("RUN_ID"),
        "apply_result_exists": apply_result_exists == "true",
        "apply_result_json_exists": apply_result_json_exists == "true",
    },
}

Path(target_path).write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
}

installer_write_summary_artifacts() {
  local exit_code="${1:-0}"

  if [[ "${INSTALLER_RUNTIME_READY:-0}" != "1" ]]; then
    return 0
  fi

  if [[ -n "${SUMMARY_JSON_PRIMARY:-}" ]]; then
    write_installer_summary_json "$SUMMARY_JSON_PRIMARY" "$exit_code"
  fi

  if [[ -n "${SUMMARY_JSON_SECONDARY:-}" ]]; then
    write_installer_summary_json "$SUMMARY_JSON_SECONDARY" "$exit_code"
  fi

  if [[ "${INSTALLER_FINALIZED:-0}" != "1" && -n "${STATE_JSON_PATH:-}" ]]; then
    state_write_json "${INSTALLER_CHECKPOINT:-${INSTALLER_FINAL_STATUS:-running}}" "installer_on_exit"
  fi
}

installer_finalize_completed_run() {
  local final_status="${1:-}"

  if [[ "${INSTALLER_CHECKPOINT:-initialized}" != "completed" ]]; then
    INSTALLER_CHECKPOINT="completed"
  fi

  if [[ -z "$final_status" || "$final_status" == "running" ]]; then
    final_status="$(installer_determine_final_status)"
  fi

  INSTALLER_FINAL_STATUS="$final_status"
  local note="installer completed status=$INSTALLER_FINAL_STATUS"
  state_mark_checkpoint "completed" "$note"
  state_append_journal "run.complete" "$INSTALLER_FINAL_STATUS" "$note" "${SUMMARY_JSON_SECONDARY:-${SUMMARY_JSON_PRIMARY:-}}"
  INSTALLER_FINALIZED="1"
}

installer_run_apply_dry_run() {
  local result_ref_path="${1:-${APPLY_PLAN_JSON_PATH:-}}"
  shift || true
  local cmd=("$@")

  INSTALLER_DRY_RUN_STATUS="running"
  state_mark_checkpoint "apply-dry-run-running" "apply dry-run start"
  state_append_journal "apply-dry-run.start" "running" "apply dry-run start" "$result_ref_path"

  if "${cmd[@]}"; then
    INSTALLER_DRY_RUN_STATUS="success"
    state_mark_checkpoint "apply-dry-run-success" "apply dry-run success"
    state_append_journal "apply-dry-run.complete" "success" "apply dry-run success" "${APPLY_RESULT_JSON_PATH:-$result_ref_path}"
  else
    local rc=$?
    INSTALLER_DRY_RUN_STATUS="failed"
    return "$rc"
  fi
}

installer_read_apply_execute_recovery_status() {
  local result_json_path="$1"

  python3 - "$result_json_path" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
if not p.exists():
    print("success")
else:
    data = json.loads(p.read_text(encoding="utf-8"))
    print((data.get("recovery") or {}).get("installer_status", "success"))
PY
}

installer_run_apply_execute() {
  local result_ref_path="${1:-${APPLY_RESULT_JSON_PATH:-}}"
  shift || true
  local cmd=("$@")

  INSTALLER_EXECUTE_STATUS="running"
  state_mark_checkpoint "apply-execute-running" "real apply start"
  state_append_journal "apply-execute.start" "running" "real apply start" "$result_ref_path"

  if "${cmd[@]}"; then
    local execute_recovery_status
    execute_recovery_status="$(installer_read_apply_execute_recovery_status "$result_ref_path")"
    INSTALLER_EXECUTE_STATUS="$execute_recovery_status"
    state_mark_checkpoint "apply-execute-success" "real apply status=$execute_recovery_status"
    state_append_journal "apply-execute.complete" "$execute_recovery_status" "real apply status=$execute_recovery_status" "$result_ref_path"
  else
    local rc=$?
    INSTALLER_EXECUTE_STATUS="failed"
    return "$rc"
  fi
}

installer_on_exit() {
  local rc=$?
  trap - EXIT
  if [[ "${INSTALLER_RUNTIME_READY:-0}" == "1" && -n "${STATE_JOURNAL_PATH:-}" ]]; then
    state_append_journal "run.exit" "${INSTALLER_FINAL_STATUS:-unknown}" "exit_code=$rc" "${STATE_JSON_PATH:-}"
  fi
  installer_write_summary_artifacts "$rc" || true
  exit "$rc"
}

state_write_json() {
  local checkpoint="${1:-${INSTALLER_CHECKPOINT:-initialized}}"
  local note="${2:-}"
  local resumed_from="${RESUME_RUN_ID:-}"
  local resume_source_run_id="${RESUME_SOURCE_RUN_ID:-}"
  local resume_source_checkpoint="${RESUME_SOURCE_CHECKPOINT:-}"
  local resume_source_resumed_from="${RESUME_SOURCE_RESUMED_FROM:-}"
  local resume_strategy="${RESUME_STRATEGY:-fresh}"
  local resume_strategy_reason="${RESUME_STRATEGY_REASON:-new-run}"

  mkdir -p "$(dirname "$STATE_JSON_PATH")"

  python3 - "$STATE_JSON_PATH" "$checkpoint" "$note" "$resumed_from" "$resume_source_run_id" "$resume_source_checkpoint" "$resume_source_resumed_from" "$resume_strategy" "$resume_strategy_reason" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

state_path, checkpoint, note, resumed_from, resume_source_run_id, resume_source_checkpoint, resume_source_resumed_from, resume_strategy, resume_strategy_reason = sys.argv[1:]

def env(name: str, default: str = ""):
    return os.environ.get(name, default)

payload = {
    "schema_kind": "installer-state",
    "schema_version": 1,
    "run_id": env("RUN_ID"),
    "state_dir": env("STATE_DIR"),
    "updated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "checkpoint": checkpoint,
    "note": note,
    "resumed_from": resumed_from,
    "lineage": {
        "mode": env("INSTALLER_MODE", "new"),
        "source_run_id": resume_source_run_id,
        "source_checkpoint": resume_source_checkpoint,
        "source_resumed_from": resume_source_resumed_from,
        "resume_strategy": resume_strategy,
        "resume_strategy_reason": resume_strategy_reason,
        "is_resumed_run": bool(resumed_from),
    },
    "status": {
        "preflight": env("INSTALLER_PREFLIGHT_STATUS", "pending"),
        "generator": env("INSTALLER_GENERATOR_STATUS", "pending"),
        "apply_plan": env("INSTALLER_APPLY_PLAN_STATUS", "pending"),
        "apply_dry_run": env("INSTALLER_DRY_RUN_STATUS", "not-requested"),
        "apply_execute": env("INSTALLER_EXECUTE_STATUS", "not-requested"),
        "repair": env("INSTALLER_REPAIR_STATUS"),
        "rollback": env("INSTALLER_ROLLBACK_STATUS"),
        "final": env("INSTALLER_FINAL_STATUS", "running"),
    },
    "inputs": {
        "deployment_name": env("DEPLOYMENT_NAME"),
        "base_domain": env("BASE_DOMAIN"),
        "domain_mode": env("DOMAIN_MODE"),
        "platform": env("PLATFORM"),
        "input_mode": env("INSTALL_INPUT_MODE") or env("INPUT_MODE"),
        "tls_cert": env("TLS_CERT"),
        "tls_key": env("TLS_KEY"),
        "error_root": env("ERROR_ROOT"),
        "log_dir": env("LOG_DIR"),
        "output_dir": env("OUTPUT_DIR"),
        "snippets_target": env("NGINX_SNIPPETS_TARGET_HINT"),
        "vhost_target": env("NGINX_VHOST_TARGET_HINT"),
    },
    "flags": {
        "assume_yes": env("ASSUME_YES", "0") == "1",
        "run_apply_dry_run": env("RUN_APPLY_DRY_RUN", "0") == "1",
        "execute_apply": env("EXECUTE_APPLY", "0") == "1",
        "run_nginx_test_after_execute": env("RUN_NGINX_TEST_AFTER_EXECUTE", "0") == "1",
    },
    "artifacts": {
        "config": env("CONFIG_PATH"),
        "output_dir_abs": env("OUTPUT_DIR_ABS"),
        "preflight_markdown": env("PREFLIGHT_REPORT_MD"),
        "preflight_json": env("PREFLIGHT_REPORT_JSON"),
        "apply_plan_markdown": env("APPLY_PLAN_PATH"),
        "apply_plan_json": env("APPLY_PLAN_JSON_PATH"),
        "apply_result": env("APPLY_RESULT_PATH"),
        "apply_result_json": env("APPLY_RESULT_JSON_PATH"),
        "repair_result": env("REPAIR_RESULT_PATH"),
        "repair_result_json": env("REPAIR_RESULT_JSON_PATH"),
        "rollback_result": env("ROLLBACK_RESULT_PATH"),
        "rollback_result_json": env("ROLLBACK_RESULT_JSON_PATH"),
        "summary_generated": env("SUMMARY_JSON_PRIMARY"),
        "summary_output": env("SUMMARY_JSON_SECONDARY"),
        "state_json": env("STATE_JSON_PATH"),
        "inputs_env": env("STATE_INPUTS_PATH"),
        "journal_jsonl": env("STATE_JOURNAL_PATH"),
    },
}

Path(state_path).write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
}

state_record_companion_result() {
  local kind="$1"
  local markdown_path="$2"
  local json_path="$3"
  local final_status="${4:-ok}"
  local note="${5:-}"

  if [[ -z "${STATE_JSON_PATH:-}" || ! -f "$STATE_JSON_PATH" ]]; then
    return 0
  fi

  if [[ "$kind" != "repair" && "$kind" != "rollback" ]]; then
    echo "[state] 不支持的 companion result 类型：$kind" >&2
    return 1
  fi

  local recorded_run_id=""
  recorded_run_id="$(python3 - "$STATE_JSON_PATH" "$kind" "$markdown_path" "$json_path" "$final_status" "$note" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

state_path, kind, markdown_path, json_path, final_status, note = sys.argv[1:]
path = Path(state_path)
state = json.loads(path.read_text(encoding="utf-8"))
artifacts = state.setdefault("artifacts", {})
status = state.setdefault("status", {})
artifacts[f"{kind}_result"] = markdown_path
artifacts[f"{kind}_result_json"] = json_path
state["updated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
status[f"{kind}"] = final_status
if note:
    state["note"] = note
path.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(state.get("run_id", ""))
PY
)"

  if [[ -n "${STATE_JOURNAL_PATH:-}" && -f "${STATE_JOURNAL_PATH:-}" && -n "$recorded_run_id" ]]; then
    RUN_ID="$recorded_run_id" state_append_journal "${kind}.result.recorded" "$final_status" "${note:-recorded $kind result}" "$json_path"
  fi
}

state_mark_checkpoint() {
  local checkpoint="$1"
  local note="${2:-}"
  INSTALLER_CHECKPOINT="$checkpoint"

  export RUNS_ROOT_DIR RUN_ID STATE_DIR STATE_JSON_PATH STATE_JOURNAL_PATH STATE_INPUTS_PATH
  export RESUME_RUN_ID RESUME_SOURCE_RUN_ID RESUME_SOURCE_CHECKPOINT RESUME_SOURCE_RESUMED_FROM INSTALLER_CHECKPOINT INSTALLER_MODE RESUME_STRATEGY RESUME_STRATEGY_REASON
  export DEPLOYMENT_NAME BASE_DOMAIN DOMAIN_MODE PLATFORM TLS_CERT TLS_KEY INPUT_MODE INSTALL_INPUT_MODE
  export ERROR_ROOT LOG_DIR OUTPUT_DIR NGINX_SNIPPETS_TARGET_HINT NGINX_VHOST_TARGET_HINT
  export RUN_APPLY_DRY_RUN EXECUTE_APPLY BACKUP_DIR RUN_NGINX_TEST_AFTER_EXECUTE NGINX_TEST_CMD ASSUME_YES
  export DEFAULT_ERROR_ROOT DEFAULT_LOG_DIR DEFAULT_OUTPUT_DIR DEFAULT_NGINX_SNIPPETS_TARGET_HINT DEFAULT_NGINX_VHOST_TARGET_HINT
  export INSTALLER_PREFLIGHT_STATUS INSTALLER_GENERATOR_STATUS INSTALLER_APPLY_PLAN_STATUS INSTALLER_DRY_RUN_STATUS INSTALLER_EXECUTE_STATUS INSTALLER_REPAIR_STATUS INSTALLER_ROLLBACK_STATUS INSTALLER_FINAL_STATUS
  export GENERATED_DIR PREFLIGHT_REPORT_MD PREFLIGHT_REPORT_JSON SUMMARY_JSON_PRIMARY SUMMARY_JSON_SECONDARY CONFIG_PATH OUTPUT_DIR_ABS APPLY_PLAN_PATH APPLY_PLAN_JSON_PATH APPLY_RESULT_PATH APPLY_RESULT_JSON_PATH REPAIR_RESULT_PATH REPAIR_RESULT_JSON_PATH ROLLBACK_RESULT_PATH ROLLBACK_RESULT_JSON_PATH

  state_write_inputs_env
  state_write_json "$checkpoint" "$note"
}

state_prepare_run() {
  local mode="${1:-new}"
  state_write_inputs_env
  state_mark_checkpoint "initialized" "mode=$mode"
  state_append_journal "run.initialized" "ok" "mode=$mode" "$STATE_DIR"
}

state_doctor() {
  local run_id="$1"
  local state_dir="$RUNS_ROOT_DIR/$run_id"
  local state_json="$state_dir/state.json"
  local journal_jsonl="$state_dir/journal.jsonl"
  local inputs_env="$state_dir/inputs.env"

  if [[ ! -f "$state_json" ]]; then
    echo "[doctor] 未找到 state.json：$state_json" >&2
    return 1
  fi

  python3 - "$state_json" "$journal_jsonl" "$inputs_env" <<'PY'
import json
import sys
from pathlib import Path

state_path, journal_path, inputs_path = sys.argv[1:]
state = json.loads(Path(state_path).read_text(encoding="utf-8"))
last_event = None
journal_entries = 0
jp = Path(journal_path)
if jp.exists():
    for line in jp.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        journal_entries += 1
        try:
            last_event = json.loads(line)
        except Exception:
            pass


def load_json_if_exists(path_str: str, label: str):
    if not path_str:
        return None
    path = Path(path_str)
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        print(f"[doctor] {label}")
        print(f"- 读取失败: {path} ({exc})")
        print()
        return None


def load_state_by_run_id(run_id: str, runs_root: Path):
    if not run_id:
        return None
    path = runs_root / run_id / "state.json"
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def with_companion_fallback(artifacts_map: dict):
    resolved = dict(artifacts_map)
    apply_result_json = resolved.get("apply_result_json") or ""
    apply_result = resolved.get("apply_result") or ""
    base_dir = None
    if apply_result_json:
        base_dir = Path(apply_result_json).parent
    elif apply_result:
        base_dir = Path(apply_result).parent
    if base_dir is not None:
        repair_json = base_dir / "REPAIR-RESULT.json"
        repair_md = base_dir / "REPAIR-RESULT.md"
        rollback_json = base_dir / "ROLLBACK-RESULT.json"
        rollback_md = base_dir / "ROLLBACK-RESULT.md"
        if not resolved.get("repair_result_json") and repair_json.exists():
            resolved["repair_result_json"] = str(repair_json)
        if not resolved.get("repair_result") and repair_md.exists():
            resolved["repair_result"] = str(repair_md)
        if not resolved.get("rollback_result_json") and rollback_json.exists():
            resolved["rollback_result_json"] = str(rollback_json)
        if not resolved.get("rollback_result") and rollback_md.exists():
            resolved["rollback_result"] = str(rollback_md)
    return resolved


def first_existing_artifact(artifacts: dict, *keys: str):
    for key in keys:
        value = artifacts.get(key) or ""
        if value:
            return value
    return ""


def summarize_artifact_priority(item: dict):
    alerts = item.get("alerts") or []
    artifacts = with_companion_fallback(item.get("artifacts") or {})

    if any(alert.startswith("repair=") for alert in alerts):
        path = first_existing_artifact(artifacts, "repair_result_json", "repair_result", "apply_result_json")
        if path:
            return ("repair-result", path, "最近异常更偏向 repair 结论，建议先看这个结果文件。")
    if any(alert.startswith("rollback=") for alert in alerts):
        path = first_existing_artifact(artifacts, "rollback_result_json", "rollback_result", "apply_result_json")
        if path:
            return ("rollback-result", path, "最近异常涉及 rollback，建议先看 rollback 结果文件。")
    if any(alert.startswith("apply_execute=") or alert.startswith("apply_dry_run=") for alert in alerts):
        path = first_existing_artifact(artifacts, "apply_result_json", "apply_result", "apply_plan_json", "apply_plan_markdown")
        if path:
            return ("apply-result", path, "最近异常出在 apply 阶段，建议先看 apply 结果/计划文件。")
    if any(alert.startswith("apply_plan=") for alert in alerts):
        path = first_existing_artifact(artifacts, "apply_plan_json", "apply_plan_markdown")
        if path:
            return ("apply-plan", path, "最近异常出在 apply plan 阶段，建议先看 apply plan。")
    if any(alert.startswith("preflight=") for alert in alerts):
        path = first_existing_artifact(artifacts, "preflight_json", "preflight_markdown")
        if path:
            return ("preflight", path, "最近异常更像 preflight 阻断，建议先看 preflight 报告。")
    if any(alert.startswith("generator=") for alert in alerts):
        path = first_existing_artifact(artifacts, "config", "summary_output", "summary_generated")
        if path:
            return ("generator-context", path, "最近异常更像 generator 阶段问题，建议先看配置或 summary 产物。")
    path = first_existing_artifact(
        artifacts,
        "repair_result_json",
        "rollback_result_json",
        "apply_result_json",
        "apply_plan_json",
        "preflight_json",
        "summary_output",
        "summary_generated",
    )
    if path:
        return ("generic-artifact", path, "已为最近异常祖先选出一个最相关的现有产物。")
    return None


def print_priority_artifact_hint(prefix: str, priority_artifact, missing_hint: str = ""):
    if priority_artifact is not None:
        kind, path, note = priority_artifact
        print(f"- {prefix}：{path} [{kind}]")
        print(f"- 说明：{note}")
    elif missing_hint:
        print(f"- {missing_hint}")


def collect_abnormal_status_alerts(status: dict):
    alerts = []
    abnormal_statuses = {"needs-attention", "blocked", "failed"}
    for key in ["preflight", "generator", "apply_plan", "apply_dry_run", "apply_execute", "repair", "rollback", "final"]:
        value = status.get(key, "")
        if value in abnormal_statuses:
            alerts.append(f"{key}={value}")
    return alerts


def find_nearest_abnormal_ancestor(lineage_chain):
    return next((item for item in lineage_chain[1:] if item.get("alerts")), None)


def choose_resume_strategy_priority_artifact(state: dict, lineage: dict):
    resume_strategy = lineage.get("resume_strategy", "") or ""
    artifacts = with_companion_fallback(state.get("artifacts") or {})

    if resume_strategy == "post-repair-verification":
        path = first_existing_artifact(artifacts, "repair_result_json", "repair_result", "apply_result_json")
        if path:
            return ("repair-result", path, "当前 run 已产出 repair 复查结果；在 post-repair-verification 下应先看这一份。")

    if resume_strategy == "post-rollback-inspection":
        path = first_existing_artifact(artifacts, "rollback_result_json", "rollback_result", "apply_result_json")
        if path:
            return ("rollback-result", path, "当前 run 已产出 rollback 结果；在 post-rollback-inspection 下应先看这一份。")

    return None


def print_nearest_abnormal_ancestor_summary(lineage_chain, preferred_priority_artifact=None):
    nearest_abnormal_ancestor = find_nearest_abnormal_ancestor(lineage_chain)
    if nearest_abnormal_ancestor is not None:
        print(
            "- 最近的异常祖先节点："
            f"{nearest_abnormal_ancestor['run_id']} "
            f"（{', '.join(nearest_abnormal_ancestor.get('alerts') or [])}）。"
        )
        priority_artifact = summarize_artifact_priority(nearest_abnormal_ancestor)
        label = "祖先参考产物" if preferred_priority_artifact is not None else "优先查看产物"
        print_priority_artifact_hint(label, priority_artifact)
        alerts = set(nearest_abnormal_ancestor.get("alerts") or [])
        if "state=missing" in alerts:
            print("- 说明：lineage 指向的 source run state.json 缺失或不可读；已停止继续向上解析。")
        elif "state=lineage-cycle" in alerts:
            print("- 说明：检测到 lineage 循环引用；已停止继续向上解析。")
    else:
        print("- 已解析的祖先链中未发现 `needs-attention` / `blocked` / `failed` 异常状态。")


def print_lineage_chain(lineage_chain, include_resume_metadata: bool):
    print("[doctor] lineage chain")
    print(f"- depth: {len(lineage_chain)}")
    for idx, item in enumerate(lineage_chain, start=1):
        role = "current"
        if idx > 1:
            role = f"ancestor-{idx-1}"
        extra = []
        if include_resume_metadata:
            if item.get("resume_strategy"):
                extra.append(f"strategy={item['resume_strategy']}")
            if item.get("resume_strategy_reason"):
                extra.append(f"reason={item['resume_strategy_reason']}")
        if item.get("alerts"):
            extra.append(f"alerts={','.join(item['alerts'])}")
        extra_text = f"; {'; '.join(extra)}" if extra else ""
        print(
            f"- {idx}. [{role}] {item['run_id']} "
            f"(checkpoint={item['checkpoint']}, final={item['final']}{extra_text})"
        )


def print_resume_lineage_summary(state: dict, lineage: dict, lineage_chain):
    source_run_id = lineage.get("source_run_id", "") or state.get("resumed_from", "") or "未知"
    source_checkpoint = lineage.get("source_checkpoint", "") or "未知"
    source_resumed_from = lineage.get("source_resumed_from", "") or "无"
    resume_strategy = lineage.get("resume_strategy", "") or "未记录"
    resume_strategy_reason = lineage.get("resume_strategy_reason", "") or "未记录"
    print(f"- 这是一轮 resumed run：当前运行继承自 {source_run_id}（source checkpoint: {source_checkpoint}）。")
    if source_resumed_from != "无":
        print(f"- 源运行自身也来自更早的一轮：{source_resumed_from}。")
    else:
        print("- 源运行本身不是已记录的 resumed run，当前链路到此为止。")
    print(f"- 当前 resume 策略：{resume_strategy}。")
    print(f"- 触发原因：{resume_strategy_reason}。")
    if len(lineage_chain) > 1:
        print(f"- 当前已解析到 {len(lineage_chain)} 段 lineage 链。")

    operator_hint = "先结合 state / result artifacts 做常规复核。"
    if resume_strategy in {"repair-review-first", "post-repair-verification"}:
        operator_hint = "优先查看 repair 结果与 nginx test 相关输出，确认是否还需要人工处理。"
    elif resume_strategy == "post-rollback-inspection":
        operator_hint = "优先核对 rollback 结果与当前落地文件状态，确认是否适合继续后续动作。"
    elif resume_strategy == "inspect-after-apply-attention":
        operator_hint = "优先查看 apply result / recovery 建议，先理解为什么该 run 不推荐直接继续 apply。"
    elif resume_strategy in {"reuse-apply-plan", "reuse-generated-output", "reuse-preflight"}:
        operator_hint = "当前更像是复用既有产物继续推进；先确认复用产物仍然有效，再决定是否进入下一阶段。"
    elif resume_strategy == "re-enter-from-inputs":
        operator_hint = "当前只能从已保存输入重新进入；先确认输入仍然适用，再继续跑后续阶段。"
    print(f"- 操作建议：{operator_hint}")

    preferred_priority_artifact = choose_resume_strategy_priority_artifact(state, lineage)
    if preferred_priority_artifact is not None:
        print_priority_artifact_hint("当前策略优先产物", preferred_priority_artifact)

    return preferred_priority_artifact


def print_current_run_machine_summary(current_run_alerts, current_run_priority):
    if not current_run_alerts:
        return
    print(f"- current_run_alerts: {', '.join(current_run_alerts)}")
    if current_run_priority is not None:
        kind, path, note = current_run_priority
        print(f"- current_run_priority_artifact: {path} [{kind}]")
        print(f"- current_run_priority_note: {note}")


def print_lineage_machine_summary(lineage: dict):
    print(f"- lineage.mode: {lineage.get('mode', '')}")
    print(f"- lineage.is_resumed_run: {lineage.get('is_resumed_run', False)}")
    print(f"- lineage.source_run_id: {lineage.get('source_run_id', '') or '无'}")
    print(f"- lineage.source_checkpoint: {lineage.get('source_checkpoint', '') or '无'}")
    print(f"- lineage.source_resumed_from: {lineage.get('source_resumed_from', '') or '无'}")
    print(f"- lineage.resume_strategy: {lineage.get('resume_strategy', '')}")
    print(f"- lineage.resume_strategy_reason: {lineage.get('resume_strategy_reason', '')}")


def print_status_summary(status: dict):
    print("[doctor] 状态")
    for key in ["preflight", "generator", "apply_plan", "apply_dry_run", "apply_execute", "repair", "rollback", "final"]:
        print(f"- {key}: {status.get(key, '')}")
    print()


def print_inputs_summary(inputs: dict):
    print("[doctor] 输入")
    for key in [
        "deployment_name",
        "base_domain",
        "domain_mode",
        "platform",
        "input_mode",
        "tls_cert",
        "tls_key",
        "error_root",
        "log_dir",
        "output_dir",
        "snippets_target",
        "vhost_target",
    ]:
        print(f"- {key}: {inputs.get(key, '')}")
    print()


def print_artifacts_summary(artifacts: dict):
    print("[doctor] 产物")
    for key, value in artifacts.items():
        if value:
            exists = "exists" if Path(value).exists() else "missing"
            print(f"- {key}: {value} ({exists})")
    print()


def print_apply_result_summary(apply_result: dict, apply_result_json_path: str):
    print("[doctor] apply result json")
    print(f"- path: {apply_result_json_path}")
    print(f"- mode: {apply_result.get('mode', '')}")
    print(f"- final_status: {apply_result.get('final_status', '')}")
    nginx_test = apply_result.get("nginx_test", {})
    print(f"- nginx_test.requested: {nginx_test.get('requested', False)}")
    print(f"- nginx_test.status: {nginx_test.get('status', '')}")
    execution = apply_result.get("execution", {})
    if execution:
        print(f"- execution.backup_status: {execution.get('backup_status', '')}")
        print(f"- execution.copy_status: {execution.get('copy_status', '')}")
        print(f"- execution.reload_performed: {execution.get('reload_performed', False)}")
    recovery = apply_result.get("recovery", {})
    if recovery:
        print(f"- recovery.installer_status: {recovery.get('installer_status', '')}")
        print(f"- recovery.resume_strategy: {recovery.get('resume_strategy', '')}")
        print(f"- recovery.resume_recommended: {recovery.get('resume_recommended', False)}")
        print(f"- recovery.operator_action: {recovery.get('operator_action', '')}")
    summary = apply_result.get("summary", {})
    for key in ["new", "replace", "same", "conflict", "target_block", "missing_source"]:
        if key in summary:
            print(f"- summary.{key}: {summary.get(key)}")
    next_step = apply_result.get("next_step")
    if next_step:
        print(f"- next_step: {next_step}")
    print()


def print_repair_result_summary(repair_result: dict, repair_result_json_path: str):
    print("[doctor] repair result json")
    print(f"- path: {repair_result_json_path}")
    print(f"- mode: {repair_result.get('mode', '')}")
    print(f"- final_status: {repair_result.get('final_status', '')}")
    source_recovery = repair_result.get("source_recovery", {})
    if source_recovery:
        print(f"- source_recovery.installer_status: {source_recovery.get('installer_status', '')}")
        print(f"- source_recovery.resume_recommended: {source_recovery.get('resume_recommended', False)}")
        print(f"- source_recovery.operator_action: {source_recovery.get('operator_action', '')}")
    execution = repair_result.get("execution", {})
    if execution:
        print(f"- execution.nginx_test_rerun_status: {execution.get('nginx_test_rerun_status', '')}")
        print(f"- execution.nginx_test_rerun_exit_code: {execution.get('nginx_test_rerun_exit_code', '')}")
    diagnosis = repair_result.get("diagnosis", {})
    for key in ["items_total", "targets_present", "targets_missing", "targets_non_regular", "replace_backups_present", "replace_backups_missing"]:
        if key in diagnosis:
            print(f"- diagnosis.{key}: {diagnosis.get(key)}")
    next_step = repair_result.get("next_step")
    if next_step:
        print(f"- next_step: {next_step}")
    print()


def print_rollback_result_summary(rollback_result: dict, rollback_result_json_path: str):
    print("[doctor] rollback result json")
    print(f"- path: {rollback_result_json_path}")
    print(f"- mode: {rollback_result.get('mode', '')}")
    print(f"- final_status: {rollback_result.get('final_status', '')}")
    flags = rollback_result.get("flags", {})
    if flags:
        print(f"- flags.delete_new: {flags.get('delete_new', False)}")
        print(f"- flags.execute: {flags.get('execute', False)}")
    summary = rollback_result.get("summary", {})
    for key in ["restore", "delete", "skip", "blocked", "pending", "restored", "deleted"]:
        if key in summary:
            print(f"- summary.{key}: {summary.get(key)}")
    next_step = rollback_result.get("next_step")
    if next_step:
        print(f"- next_step: {next_step}")
    print()


def print_journal_summary(journal_entries: int, last_event: dict | None):
    print("[doctor] journal")
    print(f"- entries: {journal_entries}")
    if last_event:
        print(f"- last_event: {last_event.get('event', '')} [{last_event.get('status', '')}]")
        if last_event.get("message"):
            print(f"- last_message: {last_event.get('message')}")
    print()


def print_suggestion_summary(suggestion: str, inputs_path: str):
    print("[doctor] 下一步建议")
    print(f"- {suggestion}")
    if Path(inputs_path).exists():
        print(f"- 输入快照可用于 resume：{inputs_path}")


def resolve_followup_result_json_paths(artifacts: dict, apply_result_json_path: str):
    repair_result_json_path = artifacts.get("repair_result_json") or ""
    rollback_result_json_path = artifacts.get("rollback_result_json") or ""
    if apply_result_json_path:
        apply_result_dir = Path(apply_result_json_path).parent
        if not repair_result_json_path:
            repair_result_json_path = str(apply_result_dir / "REPAIR-RESULT.json")
        if not rollback_result_json_path:
            rollback_result_json_path = str(apply_result_dir / "ROLLBACK-RESULT.json")
    return repair_result_json_path, rollback_result_json_path


def build_lineage_chain(current_state: dict, runs_root: Path):
    chain = []
    seen = set()
    cur = current_state

    while cur:
        run_id = cur.get("run_id", "")
        if not run_id or run_id in seen:
            break
        seen.add(run_id)
        status = cur.get("status") or {}
        lineage = cur.get("lineage") or {}
        alerts = collect_abnormal_status_alerts(status)
        chain.append({
            "run_id": run_id,
            "checkpoint": cur.get("checkpoint", "") or "未知",
            "final": status.get("final", "") or "未知",
            "resume_strategy": lineage.get("resume_strategy", "") or "",
            "resume_strategy_reason": lineage.get("resume_strategy_reason", "") or "",
            "is_resumed_run": bool(lineage.get("is_resumed_run")) or bool(cur.get("resumed_from")),
            "alerts": alerts,
            "artifacts": cur.get("artifacts") or {},
        })
        parent_run_id = cur.get("resumed_from") or lineage.get("source_run_id") or ""
        if not parent_run_id:
            break
        if parent_run_id in seen:
            chain.append({
                "run_id": f"{parent_run_id} [cycle]",
                "checkpoint": "循环",
                "final": "lineage-cycle",
                "resume_strategy": "",
                "resume_strategy_reason": "",
                "is_resumed_run": False,
                "alerts": ["state=lineage-cycle"],
                "artifacts": {},
            })
            break
        parent = load_state_by_run_id(parent_run_id, runs_root)
        if parent is None:
            chain.append({
                "run_id": parent_run_id,
                "checkpoint": "缺失",
                "final": "missing-state",
                "resume_strategy": "",
                "resume_strategy_reason": "",
                "is_resumed_run": False,
                "alerts": ["state=missing"],
                "artifacts": {},
            })
            break
        cur = parent

    return chain


print("[doctor] 运行摘要")
print(f"- run_id: {state.get('run_id', '')}")
print(f"- state_dir: {state.get('state_dir', '')}")
print(f"- updated_at: {state.get('updated_at', '')}")
print(f"- checkpoint: {state.get('checkpoint', '')}")
print(f"- resumed_from: {state.get('resumed_from', '') or '无'}")
runs_root = Path(state_path).resolve().parent.parent
lineage_chain = build_lineage_chain(state, runs_root)
current_run_status = state.get("status") or {}
current_run_alerts = collect_abnormal_status_alerts(current_run_status)
current_run_priority = summarize_artifact_priority({
    "alerts": current_run_alerts,
    "artifacts": state.get("artifacts") or {},
})
print_current_run_machine_summary(current_run_alerts, current_run_priority)
lineage = state.get("lineage") or {}
if lineage:
    print_lineage_machine_summary(lineage)
    print()
    print("[doctor] lineage 摘要")
    if lineage.get("is_resumed_run"):
        preferred_lineage_priority = print_resume_lineage_summary(state, lineage, lineage_chain)
    else:
        preferred_lineage_priority = None
        print("- 这不是 resumed run；当前运行没有接续历史 run 的 lineage。")

    if len(lineage_chain) > 1:
        print_nearest_abnormal_ancestor_summary(lineage_chain, preferred_priority_artifact=preferred_lineage_priority)

        print()
        print_lineage_chain(lineage_chain, include_resume_metadata=True)
else:
    if len(lineage_chain) > 1:
        print_nearest_abnormal_ancestor_summary(lineage_chain)
        print()
        print_lineage_chain(lineage_chain, include_resume_metadata=False)
print()
if current_run_alerts:
    print("[doctor] 当前 run 异常摘要")
    print(f"- 当前 run 存在异常状态：{', '.join(current_run_alerts)}")
    print_priority_artifact_hint(
        "优先查看产物",
        current_run_priority,
        "当前 run 虽有异常状态，但暂未解析到匹配的优先产物路径。",
    )
    print()
inputs = state.get("inputs", {})
print_inputs_summary(inputs)
status = state.get("status", {})
print_status_summary(status)
artifacts = state.get("artifacts", {})
print_artifacts_summary(artifacts)

apply_result_json_path = artifacts.get("apply_result_json") or ""
apply_result = load_json_if_exists(apply_result_json_path, "apply result json")

repair_result_json_path, rollback_result_json_path = resolve_followup_result_json_paths(
    artifacts,
    apply_result_json_path,
)

repair_result = load_json_if_exists(repair_result_json_path, "repair result json")
rollback_result = load_json_if_exists(rollback_result_json_path, "rollback result json")

if apply_result:
    print_apply_result_summary(apply_result, apply_result_json_path)

if repair_result:
    print_repair_result_summary(repair_result, repair_result_json_path)

if rollback_result:
    print_rollback_result_summary(rollback_result, rollback_result_json_path)

print_journal_summary(journal_entries, last_event)

final_status = status.get("final", "")
checkpoint = state.get("checkpoint", "")
suggestion = None
if apply_result:
    apply_final = apply_result.get("final_status", "")
    summary = apply_result.get("summary") or {}
    recovery = apply_result.get("recovery") or {}
    operator_action = recovery.get("operator_action", "")
    resume_recommended = recovery.get("resume_recommended")
    if apply_final == "blocked":
        if (summary.get("conflict") or 0) > 0:
            suggestion = "apply 结果显示存在冲突项；建议先处理目标文件冲突，再重新执行 apply / resume。"
        elif (summary.get("missing_source") or 0) > 0:
            suggestion = "apply 结果显示存在缺失源文件；建议先检查 generator 输出目录是否完整，再重新执行。"
        else:
            suggestion = apply_result.get("next_step") or "apply 阶段被阻断；建议先处理阻断项后再 resume。"
    elif operator_action == "rollback-or-fix":
        if apply_result_json_path:
            suggestion = (
                "真实 apply 已落盘，但 nginx 测试失败；建议先运行 "
                f"./repair-applied-package.sh --result-json {apply_result_json_path} --dry-run "
                "做保守诊断，再决定 selective rollback 还是人工修复。"
            )
        else:
            suggestion = "真实 apply 已落盘，但 nginx 测试失败；当前更适合先人工回滚或修复，再决定是否重跑，而不是直接 resume。"
    elif operator_action == "manual-nginx-test":
        if apply_result_json_path:
            suggestion = (
                "真实 apply 已落盘，但尚未执行 nginx -t；建议先手工执行 nginx -t，"
                f"必要时用 ./repair-applied-package.sh --result-json {apply_result_json_path} --dry-run 做诊断，再决定是否继续。"
            )
        else:
            suggestion = "真实 apply 已落盘，但尚未执行 nginx -t；建议先手工执行 nginx -t，再决定是否继续。"
    elif status.get("apply_execute") == "success":
        suggestion = apply_result.get("next_step") or "真实 apply 已完成；建议人工确认后再决定是否 reload nginx。"
    elif status.get("apply_dry_run") == "success":
        suggestion = "dry-run 已成功；若人工审核计划无误，可带 --execute-apply 继续真实 apply。"

    if suggestion and resume_recommended is False:
        suggestion += " 当前不建议把 resume 当作默认下一步。"

if repair_result:
    repair_final = repair_result.get("final_status", "")
    repair_execution = repair_result.get("execution") or {}
    rerun_status = repair_execution.get("nginx_test_rerun_status", "")
    if rerun_status == "passed":
        suggestion = repair_result.get("next_step") or "已存在 repair 结果且 nginx -t 重跑已通过；建议人工确认后，再决定是否继续后续操作。"
    elif rerun_status == "failed":
        suggestion = repair_result.get("next_step") or "已存在 repair 结果且 nginx -t 重跑仍失败；建议优先查看 REPAIR-RESULT，再决定 selective rollback 还是人工修复。"
    elif repair_final in {"blocked", "needs-attention"}:
        suggestion = repair_result.get("next_step") or "已有 repair 结果；建议先按 repair 结论决定 rollback 还是人工修复。"

if rollback_result:
    rollback_final = rollback_result.get("final_status", "")
    rollback_mode = rollback_result.get("mode", "")
    rollback_flags = rollback_result.get("flags") or {}
    if rollback_mode == "execute" and rollback_final == "ok":
        suggestion = rollback_result.get("next_step") or "selective rollback 已执行完成；请先手工运行 nginx -t，再决定是否 reload。"
    elif rollback_final in {"blocked", "needs-attention"}:
        suggestion = rollback_result.get("next_step") or "已存在 rollback 结果；建议先处理 rollback 结果里提示的阻断项或待确认项。"
    elif rollback_flags.get("execute"):
        suggestion = rollback_result.get("next_step") or "已存在 rollback 执行结果；建议先按 rollback 结果复核当前系统状态。"

if suggestion is None:
    if final_status in {"success", "cancelled"}:
        suggestion = "本轮已到稳定停点；若需继续，请基于现有产物开始下一轮迭代。"
    elif status.get("generator") == "failed":
        suggestion = "建议先检查 generator 配置与输出目录，再用 --resume 重新推进。"
    elif status.get("preflight") == "blocked":
        suggestion = "建议先修复 preflight BLOCK 项，再用 --resume 重新推进。"
    elif checkpoint:
        suggestion = f"可尝试执行 ./install-interactive.sh --resume {state.get('run_id', '')} 继续；当前版本会复用已完成阶段，并从较安全的边界继续推进。"
    else:
        suggestion = "建议先检查运行目录与 inputs/state 文件是否完整。"

print_suggestion_summary(suggestion, inputs_path)
PY
}
