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
TLS_MODE=$(printf '%q' "${TLS_MODE:-existing}")
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
    "TLS_MODE",
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
    if len(tokens) == 0:
        if encoded.strip() != "":
            raise SystemExit(f"line {lineno}: assignment must decode to exactly one token")
        value = ""
    elif len(tokens) == 1:
        value = tokens[0]
    else:
        raise SystemExit(f"line {lineno}: assignment must decode to exactly one token")
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


def ensure_dict(value):
    return value if isinstance(value, dict) else {}


def jsonish_bool(value):
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.strip().lower() in {"1", "true", "yes", "on"}
    if isinstance(value, (int, float)):
        return value != 0
    return bool(value)


def safe_int(value, default=0):
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value)
    if isinstance(value, str):
        text = value.strip()
        if not text:
            return default
        try:
            return int(text)
        except ValueError:
            return default
    return default

state_path = Path(sys.argv[1]).resolve()
runs_root = state_path.parent.parent
state = ensure_dict(json.loads(state_path.read_text(encoding="utf-8")))
status = ensure_dict(state.get("status"))
artifacts = ensure_dict(state.get("artifacts"))
apply_result_path = artifacts.get("apply_result_json", "")
apply_result = {}
if apply_result_path and Path(apply_result_path).exists():
    try:
        apply_result = ensure_dict(json.loads(Path(apply_result_path).read_text(encoding="utf-8")))
    except Exception:
        apply_result = {}
recovery = ensure_dict(apply_result.get("recovery"))


def load_state_by_run_id(run_id: str):
    if not run_id:
        return None
    path = runs_root / run_id / "state.json"
    if not path.exists():
        return None
    try:
        return ensure_dict(json.loads(path.read_text(encoding="utf-8")))
    except Exception:
        return None


def resolve_artifact_base_dir(artifacts_map: dict):
    resolved = ensure_dict(artifacts_map)
    candidates = [
        resolved.get("apply_result_json") or "",
        resolved.get("apply_result") or "",
        resolved.get("repair_result_json") or "",
        resolved.get("repair_result") or "",
        resolved.get("rollback_result_json") or "",
        resolved.get("rollback_result") or "",
        resolved.get("issue_result_json") or "",
        resolved.get("issue_result") or "",
        resolved.get("acme_issuance_result_json") or "",
        resolved.get("acme_issuance_result") or "",
        resolved.get("output_dir_abs") or "",
    ]
    for value in candidates:
        if value and Path(value).exists():
            return Path(value) if Path(value).is_dir() else Path(value).parent
    for value in candidates:
        if value:
            candidate = Path(value)
            return candidate if candidate.suffix == "" else candidate.parent
    return None


def with_companion_fallback(artifacts_map: dict):
    resolved = dict(ensure_dict(artifacts_map))
    base_dir = resolve_artifact_base_dir(resolved)
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
        if not resolved.get("issue_result_json"):
            candidate = base_dir / "ISSUE-RESULT.json"
            if candidate.exists():
                resolved["issue_result_json"] = str(candidate)
        if not resolved.get("issue_result"):
            candidate = base_dir / "ISSUE-RESULT.md"
            if candidate.exists():
                resolved["issue_result"] = str(candidate)
        if not resolved.get("acme_issuance_result_json"):
            candidate = base_dir / "ACME-ISSUANCE-RESULT.json"
            if candidate.exists():
                resolved["acme_issuance_result_json"] = str(candidate)
        if not resolved.get("acme_issuance_result"):
            candidate = base_dir / "ACME-ISSUANCE-RESULT.md"
            if candidate.exists():
                resolved["acme_issuance_result"] = str(candidate)
    return resolved


def resolve_companion_result(cur_state: dict, kind: str, visited: set[str]):
    cur_state = ensure_dict(cur_state)
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
            payload = ensure_dict(json.loads(Path(candidate_json).read_text(encoding="utf-8")))
        except Exception:
            payload = {}
        if not candidate_md:
            candidate_md = str(Path(candidate_json).with_name(f"{kind.replace('_', '-').upper()}-RESULT.md"))
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

    parent_run_id = cur_state.get("resumed_from") or ensure_dict(cur_state.get("lineage")).get("source_run_id") or ""
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
acme_issuance_resolved = resolve_companion_result(state, "acme_issuance", set()) or {}
repair_result_json_path = repair_resolved.get("json_path", "")
rollback_result_json_path = rollback_resolved.get("json_path", "")
acme_issuance_result_json_path = acme_issuance_resolved.get("json_path", "")
repair_result_path = repair_resolved.get("markdown_path", "")
rollback_result_path = rollback_resolved.get("markdown_path", "")
acme_issuance_result_path = acme_issuance_resolved.get("markdown_path", "")
repair_result = ensure_dict(repair_resolved.get("payload"))
rollback_result = ensure_dict(rollback_resolved.get("payload"))
acme_issuance_result = ensure_dict(acme_issuance_resolved.get("payload"))
repair_execution = ensure_dict(repair_result.get("execution"))
rollback_flags = ensure_dict(rollback_result.get("flags"))
acme_intent = ensure_dict(acme_issuance_result.get("intent"))
acme_execution = ensure_dict(acme_issuance_result.get("execution"))


def acme_placeholder_requires_review(result: dict, intent: dict, execution: dict) -> bool:
    return bool(result) and (
        intent.get("result_role", "") == "execute-placeholder"
        or not jsonish_bool(intent.get("real_execution_performed", True))
        or result.get("final_status", "") == "blocked"
        or not jsonish_bool(execution.get("client_invoked", True))
    )


acme_review_required = acme_placeholder_requires_review(acme_issuance_result, acme_intent, acme_execution)

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
    "RESUME_SOURCE_TLS_PLAN_MD": artifacts.get("tls_plan_markdown", ""),
    "RESUME_SOURCE_TLS_PLAN_JSON": artifacts.get("tls_plan_json", ""),
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
    "RESUME_SOURCE_ACME_ISSUANCE_RESULT_OWNER_RUN_ID": acme_issuance_resolved.get("owner_run_id", ""),
    "RESUME_SOURCE_ACME_ISSUANCE_RESULT_PATH": acme_issuance_result_path,
    "RESUME_SOURCE_ACME_ISSUANCE_RESULT_JSON_PATH": acme_issuance_result_json_path,
    "RESUME_SOURCE_APPLY_RECOVERY_STATUS": recovery.get("installer_status", ""),
    "RESUME_SOURCE_APPLY_RESUME_STRATEGY": recovery.get("resume_strategy", ""),
    "RESUME_SOURCE_APPLY_RESUME_RECOMMENDED": "1" if jsonish_bool(recovery.get("resume_recommended", True)) else "0",
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
    "RESUME_SOURCE_ACME_ISSUANCE_FINAL_STATUS": acme_issuance_result.get("final_status", ""),
    "RESUME_SOURCE_ACME_ISSUANCE_MODE": acme_issuance_result.get("mode", ""),
    "RESUME_SOURCE_ACME_INTENT_RESULT_ROLE": acme_intent.get("result_role", ""),
    "RESUME_SOURCE_ACME_REAL_EXECUTION_PERFORMED": "1" if jsonish_bool(acme_intent.get("real_execution_performed", False)) else "0",
    "RESUME_SOURCE_ACME_EXECUTION_CLIENT_INVOKED": "1" if jsonish_bool(acme_execution.get("client_invoked", False)) else "0",
    "RESUME_SOURCE_ACME_REVIEW_REQUIRED": "1" if acme_review_required else "0",
    "RESUME_SOURCE_ACME_NEXT_STEP": acme_issuance_result.get("next_step", ""),
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

resume_strategy_prefers_review_boundary() {
  case "${1:-}" in
    post-rollback-inspection|post-repair-verification|repair-review-first|inspect-after-apply-attention|inspect-after-acme-placeholder)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

resume_source_effective_repair_status() {
  if [[ -n "${RESUME_SOURCE_REPAIR_FINAL_STATUS:-}" ]]; then
    printf '%s\n' "$RESUME_SOURCE_REPAIR_FINAL_STATUS"
  else
    printf '%s\n' "${RESUME_SOURCE_REPAIR_STATUS:-}"
  fi
}

resume_source_effective_rollback_status() {
  if [[ -n "${RESUME_SOURCE_ROLLBACK_FINAL_STATUS:-}" ]]; then
    printf '%s\n' "$RESUME_SOURCE_ROLLBACK_FINAL_STATUS"
  else
    printf '%s\n' "${RESUME_SOURCE_ROLLBACK_STATUS:-}"
  fi
}

resume_force_reuse_from_available_artifacts() {
  if [[ -n "${RESUME_SOURCE_CONFIG_PATH:-}" && -f "$RESUME_SOURCE_CONFIG_PATH" ]]; then
    SHOULD_SKIP_INPUTS="1"
    SHOULD_SKIP_PREFLIGHT="1"
  fi

  if [[ -n "${RESUME_SOURCE_OUTPUT_DIR_ABS:-}" && -d "$RESUME_SOURCE_OUTPUT_DIR_ABS" ]]; then
    SHOULD_SKIP_GENERATOR="1"
  fi

  if [[ -n "${RESUME_SOURCE_APPLY_PLAN_JSON_PATH:-}" && -f "$RESUME_SOURCE_APPLY_PLAN_JSON_PATH" ]]; then
    SHOULD_SKIP_APPLY_PLAN="1"
  fi
}

state_plan_resume_runtime() {
  if [[ "$RESUME_SOURCE_PREFLIGHT_STATUS" != "blocked" && -n "$RESUME_SOURCE_CONFIG_PATH" && -f "$RESUME_SOURCE_CONFIG_PATH" ]]; then
    SHOULD_SKIP_INPUTS="1"
    SHOULD_SKIP_PREFLIGHT="1"
  fi

  if [[ "$RESUME_SOURCE_GENERATOR_STATUS" == "success" && -n "$RESUME_SOURCE_OUTPUT_DIR_ABS" && -d "$RESUME_SOURCE_OUTPUT_DIR_ABS" ]]; then
    SHOULD_SKIP_GENERATOR="1"
  fi

  if [[ "$RESUME_SOURCE_APPLY_PLAN_STATUS" == "generated" && -n "$RESUME_SOURCE_APPLY_PLAN_JSON_PATH" && -f "$RESUME_SOURCE_APPLY_PLAN_JSON_PATH" ]]; then
    SHOULD_SKIP_APPLY_PLAN="1"
  fi

  if [[ -n "$RESUME_SOURCE_REPAIR_STATUS" || -n "$RESUME_SOURCE_REPAIR_FINAL_STATUS" ]]; then
    INSTALLER_REPAIR_STATUS="$(resume_source_effective_repair_status)"
  fi
  if [[ -n "$RESUME_SOURCE_ROLLBACK_STATUS" || -n "$RESUME_SOURCE_ROLLBACK_FINAL_STATUS" ]]; then
    INSTALLER_ROLLBACK_STATUS="$(resume_source_effective_rollback_status)"
  fi

  if [[ "$RESUME_SOURCE_ROLLBACK_MODE" == "execute" && "$RESUME_SOURCE_ROLLBACK_FINAL_STATUS" == "ok" ]]; then
    RESUME_STRATEGY="post-rollback-inspection"
    RESUME_STRATEGY_REASON="source rollback already executed successfully"
  elif [[ "$RESUME_SOURCE_REPAIR_NGINX_TEST_RERUN_STATUS" == "passed" ]]; then
    RESUME_STRATEGY="post-repair-verification"
    RESUME_STRATEGY_REASON="source repair rerun nginx test already passed"
  elif [[ "$RESUME_SOURCE_REPAIR_FINAL_STATUS" == "needs-attention" || "$RESUME_SOURCE_REPAIR_FINAL_STATUS" == "blocked" ]]; then
    RESUME_STRATEGY="repair-review-first"
    RESUME_STRATEGY_REASON="source repair result still needs operator review"
  elif [[ "$RESUME_SOURCE_APPLY_RESUME_RECOMMENDED" != "1" ]]; then
    RESUME_STRATEGY="inspect-after-apply-attention"
    RESUME_STRATEGY_REASON="source apply recovery marked resume as not recommended"
  elif [[ "${RESUME_SOURCE_ACME_REVIEW_REQUIRED:-0}" == "1" ]]; then
    RESUME_STRATEGY="inspect-after-acme-placeholder"
    RESUME_STRATEGY_REASON="source ACME execute result is still a conservative placeholder"
  elif [[ "$SHOULD_SKIP_APPLY_PLAN" == "1" ]]; then
    RESUME_STRATEGY="reuse-apply-plan"
    RESUME_STRATEGY_REASON="source apply plan artifact is reusable"
  elif [[ "$SHOULD_SKIP_GENERATOR" == "1" ]]; then
    RESUME_STRATEGY="reuse-generated-output"
    RESUME_STRATEGY_REASON="source generated output directory is reusable"
  elif [[ "$SHOULD_SKIP_PREFLIGHT" == "1" ]]; then
    RESUME_STRATEGY="reuse-preflight"
    RESUME_STRATEGY_REASON="source preflight/config artifacts are reusable"
  else
    RESUME_STRATEGY="re-enter-from-inputs"
    RESUME_STRATEGY_REASON="resume can only continue from stored inputs"
  fi

  if resume_strategy_prefers_review_boundary "$RESUME_STRATEGY"; then
    resume_force_reuse_from_available_artifacts
  fi
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
    "tls_mode": env("TLS_MODE", "existing"),
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
        "preflight_markdown": env("PREFLIGHT_REPORT_MD_RUN_COPY") or env("PREFLIGHT_REPORT_MD"),
        "preflight_json": env("PREFLIGHT_REPORT_JSON_RUN_COPY") or env("PREFLIGHT_REPORT_JSON"),
        "tls_plan_markdown": env("TLS_PLAN_MD_RUN_COPY") or env("TLS_PLAN_MD"),
        "tls_plan_json": env("TLS_PLAN_JSON_RUN_COPY") or env("TLS_PLAN_JSON"),
        "config": env("CONFIG_PATH_RUN_COPY") or env("CONFIG_PATH"),
        "output_dir": env("OUTPUT_DIR_ABS"),
        "apply_plan_markdown": env("APPLY_PLAN_PATH"),
        "apply_plan_json": env("APPLY_PLAN_JSON_PATH"),
        "apply_result": env("APPLY_RESULT_PATH"),
        "apply_result_json": env("APPLY_RESULT_JSON_PATH"),
        "issue_result": env("ISSUE_RESULT_PATH"),
        "issue_result_json": env("ISSUE_RESULT_JSON_PATH"),
        "acme_issuance_result": env("ACME_ISSUANCE_RESULT_PATH"),
        "acme_issuance_result_json": env("ACME_ISSUANCE_RESULT_JSON_PATH"),
        "summary_generated": env("SUMMARY_JSON_RUN_COPY") or env("SUMMARY_JSON_PRIMARY"),
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

  if [[ -n "${SUMMARY_JSON_RUN_COPY:-}" ]]; then
    write_installer_summary_json "$SUMMARY_JSON_RUN_COPY" "$exit_code"
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

  if [[ "${INSTALLER_RUNTIME_READY:-0}" == "1" && "${INSTALLER_FINALIZED:-0}" != "1" ]]; then
    if [[ "${INSTALLER_FINAL_STATUS:-running}" == "running" ]]; then
      if [[ "$rc" == "0" ]]; then
        INSTALLER_FINAL_STATUS="$(installer_determine_final_status)"
      elif [[ "${INSTALLER_PREFLIGHT_STATUS:-pending}" == "blocked" ]]; then
        INSTALLER_FINAL_STATUS="blocked"
      else
        INSTALLER_FINAL_STATUS="failed"
      fi
    fi
  fi

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
        "tls_mode": env("TLS_MODE", "existing"),
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
        "config": env("CONFIG_PATH_RUN_COPY") or env("CONFIG_PATH"),
        "output_dir_abs": env("OUTPUT_DIR_ABS"),
        "preflight_markdown": env("PREFLIGHT_REPORT_MD_RUN_COPY") or env("PREFLIGHT_REPORT_MD"),
        "preflight_json": env("PREFLIGHT_REPORT_JSON_RUN_COPY") or env("PREFLIGHT_REPORT_JSON"),
        "tls_plan_markdown": env("TLS_PLAN_MD_RUN_COPY") or env("TLS_PLAN_MD"),
        "tls_plan_json": env("TLS_PLAN_JSON_RUN_COPY") or env("TLS_PLAN_JSON"),
        "apply_plan_markdown": env("APPLY_PLAN_PATH"),
        "apply_plan_json": env("APPLY_PLAN_JSON_PATH"),
        "apply_result": env("APPLY_RESULT_PATH"),
        "apply_result_json": env("APPLY_RESULT_JSON_PATH"),
        "issue_result": env("ISSUE_RESULT_PATH"),
        "issue_result_json": env("ISSUE_RESULT_JSON_PATH"),
        "acme_issuance_result": env("ACME_ISSUANCE_RESULT_PATH"),
        "acme_issuance_result_json": env("ACME_ISSUANCE_RESULT_JSON_PATH"),
        "repair_result": env("REPAIR_RESULT_PATH"),
        "repair_result_json": env("REPAIR_RESULT_JSON_PATH"),
        "rollback_result": env("ROLLBACK_RESULT_PATH"),
        "rollback_result_json": env("ROLLBACK_RESULT_JSON_PATH"),
        "summary_generated": env("SUMMARY_JSON_RUN_COPY") or env("SUMMARY_JSON_PRIMARY"),
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
  local journal_event_base="${6:-$kind}"

  if [[ -z "${STATE_JSON_PATH:-}" || ! -f "$STATE_JSON_PATH" ]]; then
    return 0
  fi

  if [[ "$kind" != "repair" && "$kind" != "rollback" && "$kind" != "issue" && "$kind" != "acme_issuance" ]]; then
    echo "[state] 不支持的 companion result 类型：$kind" >&2
    return 1
  fi

  local recorded_run_id=""
  local summary_generated_path=""
  local summary_output_path=""
  IFS=$'\t' read -r recorded_run_id summary_generated_path summary_output_path < <(
    python3 - "$STATE_JSON_PATH" "$kind" "$markdown_path" "$json_path" "$final_status" "$note" <<'PY'
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
if kind in {"repair", "rollback"}:
    status[kind] = final_status
if note:
    state["note"] = note
path.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(state.get("run_id", ""), artifacts.get("summary_generated", ""), artifacts.get("summary_output", ""), sep="\t")
PY
  )

  local summary_path
  for summary_path in "$summary_generated_path" "$summary_output_path"; do
    if [[ -z "$summary_path" || ! -f "$summary_path" ]]; then
      continue
    fi
    python3 - "$summary_path" "$kind" "$markdown_path" "$json_path" <<'PY'
import json
import sys
from pathlib import Path

summary_path, kind, markdown_path, json_path = sys.argv[1:]
path = Path(summary_path)
data = json.loads(path.read_text(encoding="utf-8"))
artifacts = data.setdefault("artifacts", {})
artifacts[f"{kind}_result"] = markdown_path
artifacts[f"{kind}_result_json"] = json_path
path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
  done

  if [[ -n "${STATE_JOURNAL_PATH:-}" && -f "${STATE_JOURNAL_PATH:-}" && -n "$recorded_run_id" ]]; then
    RUN_ID="$recorded_run_id" state_append_journal "${journal_event_base}.result.recorded" "$final_status" "${note:-recorded $kind result}" "$json_path"
  fi
}

state_mark_checkpoint() {
  local checkpoint="$1"
  local note="${2:-}"
  INSTALLER_CHECKPOINT="$checkpoint"

  export RUNS_ROOT_DIR RUN_ID STATE_DIR STATE_JSON_PATH STATE_JOURNAL_PATH STATE_INPUTS_PATH
  export RESUME_RUN_ID RESUME_SOURCE_RUN_ID RESUME_SOURCE_CHECKPOINT RESUME_SOURCE_RESUMED_FROM INSTALLER_CHECKPOINT INSTALLER_MODE RESUME_STRATEGY RESUME_STRATEGY_REASON
  export DEPLOYMENT_NAME BASE_DOMAIN DOMAIN_MODE PLATFORM TLS_MODE TLS_CERT TLS_KEY INPUT_MODE INSTALL_INPUT_MODE
  export ERROR_ROOT LOG_DIR OUTPUT_DIR NGINX_SNIPPETS_TARGET_HINT NGINX_VHOST_TARGET_HINT
  export RUN_APPLY_DRY_RUN EXECUTE_APPLY BACKUP_DIR RUN_NGINX_TEST_AFTER_EXECUTE NGINX_TEST_CMD ASSUME_YES
  export DEFAULT_ERROR_ROOT DEFAULT_LOG_DIR DEFAULT_OUTPUT_DIR DEFAULT_NGINX_SNIPPETS_TARGET_HINT DEFAULT_NGINX_VHOST_TARGET_HINT
  export INSTALLER_PREFLIGHT_STATUS INSTALLER_GENERATOR_STATUS INSTALLER_APPLY_PLAN_STATUS INSTALLER_DRY_RUN_STATUS INSTALLER_EXECUTE_STATUS INSTALLER_REPAIR_STATUS INSTALLER_ROLLBACK_STATUS INSTALLER_FINAL_STATUS
  export GENERATED_DIR PREFLIGHT_REPORT_MD PREFLIGHT_REPORT_JSON PREFLIGHT_REPORT_MD_RUN_COPY PREFLIGHT_REPORT_JSON_RUN_COPY TLS_PLAN_MD TLS_PLAN_JSON TLS_PLAN_MD_RUN_COPY TLS_PLAN_JSON_RUN_COPY SUMMARY_JSON_PRIMARY SUMMARY_JSON_RUN_COPY SUMMARY_JSON_SECONDARY CONFIG_PATH CONFIG_PATH_RUN_COPY OUTPUT_DIR_ABS APPLY_PLAN_PATH APPLY_PLAN_JSON_PATH APPLY_RESULT_PATH APPLY_RESULT_JSON_PATH ISSUE_RESULT_PATH ISSUE_RESULT_JSON_PATH ACME_ISSUANCE_RESULT_PATH ACME_ISSUANCE_RESULT_JSON_PATH REPAIR_RESULT_PATH REPAIR_RESULT_JSON_PATH ROLLBACK_RESULT_PATH ROLLBACK_RESULT_JSON_PATH

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


def ensure_dict(value):
    return value if isinstance(value, dict) else {}


def jsonish_bool(value):
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.strip().lower() in {"1", "true", "yes", "on"}
    if isinstance(value, (int, float)):
        return value != 0
    return bool(value)


def safe_int(value, default=0):
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value)
    if isinstance(value, str):
        text = value.strip()
        if not text:
            return default
        try:
            return int(text)
        except ValueError:
            return default
    return default


def is_effectively_resumed_run(state: dict, lineage: dict):
    state = ensure_dict(state)
    lineage = ensure_dict(lineage)
    return (
        jsonish_bool(lineage.get("is_resumed_run", False))
        or bool(state.get("resumed_from"))
        or bool(lineage.get("source_run_id"))
    )

state_path, journal_path, inputs_path = sys.argv[1:]
state = ensure_dict(json.loads(Path(state_path).read_text(encoding="utf-8")))
last_event = None
journal_entries = 0
jp = Path(journal_path)
if jp.exists():
    for line in jp.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        journal_entries += 1
        try:
            parsed = json.loads(line)
            if isinstance(parsed, dict):
                last_event = parsed
        except Exception:
            pass


def load_json_if_exists_quiet(path_str: str):
    if not path_str:
        return None
    path = Path(path_str)
    if not path.exists():
        return None
    try:
        return ensure_dict(json.loads(path.read_text(encoding="utf-8")))
    except Exception:
        return None


def load_json_if_exists(path_str: str, label: str):
    if not path_str:
        return None
    path = Path(path_str)
    if not path.exists():
        return None
    try:
        return ensure_dict(json.loads(path.read_text(encoding="utf-8")))
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
        return ensure_dict(json.loads(path.read_text(encoding="utf-8")))
    except Exception:
        return None


def resolve_artifact_base_dir(artifacts_map: dict):
    resolved = ensure_dict(artifacts_map)
    candidates = [
        resolved.get("apply_result_json") or "",
        resolved.get("apply_result") or "",
        resolved.get("repair_result_json") or "",
        resolved.get("repair_result") or "",
        resolved.get("rollback_result_json") or "",
        resolved.get("rollback_result") or "",
    ]
    for value in candidates:
        if value and Path(value).exists():
            return Path(value).parent
    for value in candidates:
        if value:
            return Path(value).parent
    return None


def with_companion_fallback(artifacts_map: dict):
    resolved = dict(ensure_dict(artifacts_map))
    base_dir = resolve_artifact_base_dir(resolved)
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
    artifacts = ensure_dict(artifacts)
    first_nonempty = ""
    for key in keys:
        value = artifacts.get(key) or ""
        if not value:
            continue
        if not first_nonempty:
            first_nonempty = value
        if Path(value).exists():
            return value
    return ""


def summarize_artifact_priority(item: dict):
    item = ensure_dict(item)
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
    status = ensure_dict(status)
    alerts = []
    abnormal_statuses = {"needs-attention", "blocked", "failed"}
    for key in ["preflight", "generator", "apply_plan", "apply_dry_run", "apply_execute", "repair", "rollback", "final"]:
        value = status.get(key, "")
        if value in abnormal_statuses:
            alerts.append(f"{key}={value}")
    return alerts


def find_nearest_abnormal_ancestor(lineage_chain):
    return next((item for item in lineage_chain[1:] if item.get("alerts")), None)


def acme_placeholder_requires_review(result: dict, intent: dict, execution: dict) -> bool:
    result = ensure_dict(result)
    intent = ensure_dict(intent)
    execution = ensure_dict(execution)
    return bool(result) and (
        intent.get("result_role", "") == "execute-placeholder"
        or not jsonish_bool(intent.get("real_execution_performed", True))
        or result.get("final_status", "") == "blocked"
        or not jsonish_bool(execution.get("client_invoked", True))
    )


def derive_effective_resume_strategy(lineage: dict, apply_result: dict | None, repair_result: dict | None, rollback_result: dict | None, acme_issuance_result: dict | None = None):
    lineage = ensure_dict(lineage)
    apply_result = ensure_dict(apply_result)
    repair_result = ensure_dict(repair_result)
    rollback_result = ensure_dict(rollback_result)
    acme_issuance_result = ensure_dict(acme_issuance_result)
    recovery = ensure_dict(apply_result.get("recovery"))
    repair_execution = ensure_dict(repair_result.get("execution"))
    acme_intent = ensure_dict(acme_issuance_result.get("intent"))
    acme_execution = ensure_dict(acme_issuance_result.get("execution"))

    def strategy_phase(strategy: str) -> int:
        if strategy == "inspect-after-apply-attention":
            return 1
        if strategy == "inspect-after-acme-placeholder":
            return 1
        if strategy in {"repair-review-first", "post-repair-verification"}:
            return 2
        if strategy == "post-rollback-inspection":
            return 3
        return 0

    direct_strategy = ""
    direct_reason = ""
    if rollback_result.get("mode", "") == "execute" and rollback_result.get("final_status", "") == "ok":
        direct_strategy = "post-rollback-inspection"
        direct_reason = "source rollback already executed successfully"
    elif repair_execution.get("nginx_test_rerun_status", "") == "passed":
        direct_strategy = "post-repair-verification"
        direct_reason = "source repair rerun nginx test already passed"
    elif repair_result.get("final_status", "") in {"needs-attention", "blocked"}:
        direct_strategy = "repair-review-first"
        direct_reason = "source repair result still needs operator review"
    elif apply_result and not jsonish_bool(recovery.get("resume_recommended", True)):
        direct_strategy = "inspect-after-apply-attention"
        direct_reason = "source apply recovery marked resume as not recommended"
    elif acme_placeholder_requires_review(acme_issuance_result, acme_intent, acme_execution):
        direct_strategy = "inspect-after-acme-placeholder"
        direct_reason = "source ACME execute result is still a conservative placeholder"

    lineage_strategy = lineage.get("resume_strategy", "") or ""
    lineage_reason = lineage.get("resume_strategy_reason", "") or ""

    if not direct_strategy:
        return (lineage_strategy, lineage_reason)
    if not lineage_strategy:
        return (direct_strategy, direct_reason)

    if strategy_phase(direct_strategy) >= strategy_phase(lineage_strategy):
        return (direct_strategy, direct_reason)
    return (lineage_strategy, lineage_reason)



def with_effective_resume_strategy(lineage: dict, apply_result: dict | None, repair_result: dict | None, rollback_result: dict | None, acme_issuance_result: dict | None = None):
    effective = dict(ensure_dict(lineage))
    strategy, reason = derive_effective_resume_strategy(lineage, apply_result, repair_result, rollback_result, acme_issuance_result)
    if strategy:
        effective["resume_strategy"] = strategy
    if reason:
        effective["resume_strategy_reason"] = reason
    return effective



def choose_resume_strategy_priority_artifact(state: dict, lineage: dict):
    state = ensure_dict(state)
    lineage = ensure_dict(lineage)
    resume_strategy = lineage.get("resume_strategy", "") or ""
    artifacts = with_companion_fallback(state.get("artifacts") or {})

    if resume_strategy == "inspect-after-apply-attention":
        path = first_existing_artifact(artifacts, "apply_result_json", "apply_result", "repair_result_json", "repair_result")
        if path:
            return ("apply-result", path, "当前 run 已明确进入 inspect-after-apply-attention；应先看 apply result / recovery 字段，再决定后续动作。")

    if resume_strategy == "inspect-after-acme-placeholder":
        path = first_existing_artifact(artifacts, "acme_issuance_result_json", "acme_issuance_result", "issue_result_json", "issue_result")
        if path:
            return ("acme-issuance-result", path, "当前 run 的 ACME execute 结果仍是保守占位边界；应先看 ACME companion result / issue result，再决定是否设计真实 execute 子路径。")

    if resume_strategy == "repair-review-first":
        path = first_existing_artifact(artifacts, "repair_result_json", "repair_result", "apply_result_json")
        if path:
            return ("repair-result", path, "当前 run 的 repair 结果仍需 operator review；应先看这一份，再决定 rollback 还是人工修复。")

    if resume_strategy == "post-repair-verification":
        path = first_existing_artifact(artifacts, "repair_result_json", "repair_result", "apply_result_json")
        if path:
            return ("repair-result", path, "当前 run 已产出 repair 复查结果；在 post-repair-verification 下应先看这一份。")

    if resume_strategy == "post-rollback-inspection":
        path = first_existing_artifact(artifacts, "rollback_result_json", "rollback_result", "apply_result_json")
        if path:
            return ("rollback-result", path, "当前 run 已产出 rollback 结果；在 post-rollback-inspection 下应先看这一份。")

    return None


def choose_resume_strategy_suggestion_focus(lineage: dict):
    lineage = ensure_dict(lineage)
    resume_strategy = lineage.get("resume_strategy", "") or ""

    if resume_strategy == "inspect-after-apply-attention":
        return "apply"
    if resume_strategy == "inspect-after-acme-placeholder":
        return "acme"
    if resume_strategy in {"repair-review-first", "post-repair-verification"}:
        return "repair"
    if resume_strategy == "post-rollback-inspection":
        return "rollback"
    return ""


def maybe_prefer_strategy_priority_for_current_run(state: dict, lineage: dict, current_run_alerts, current_run_priority):
    state = ensure_dict(state)
    lineage = ensure_dict(lineage)
    current_run_alerts = list(current_run_alerts or [])
    if not is_effectively_resumed_run(state, lineage):
        return current_run_priority

    preferred_priority = choose_resume_strategy_priority_artifact(state, lineage)
    if preferred_priority is None:
        return current_run_priority

    explicit_alert_prefixes = (
        "preflight=",
        "generator=",
        "apply_plan=",
        "apply_dry_run=",
        "apply_execute=",
        "repair=",
        "rollback=",
    )
    if any(alert.startswith(explicit_alert_prefixes) for alert in current_run_alerts):
        return current_run_priority

    if current_run_priority is None:
        return preferred_priority

    kind, _path, _note = current_run_priority
    if kind == "generic-artifact":
        return preferred_priority

    return current_run_priority


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
    state = ensure_dict(state)
    lineage = ensure_dict(lineage)
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
    if resume_strategy == "repair-review-first":
        operator_hint = "优先查看 repair 结果与诊断摘要，确认应该 rollback 还是继续人工修复。"
    elif resume_strategy == "post-repair-verification":
        operator_hint = "优先查看 repair 结果与 nginx test 相关输出，确认是否还需要人工处理。"
    elif resume_strategy == "post-rollback-inspection":
        operator_hint = "优先核对 rollback 结果与当前落地文件状态，确认是否适合继续后续动作。"
    elif resume_strategy == "inspect-after-apply-attention":
        operator_hint = "优先查看 apply result / recovery 建议，先理解为什么该 run 不推荐直接继续 apply。"
    elif resume_strategy == "inspect-after-acme-placeholder":
        operator_hint = "优先核对 ACME companion result / issue result，确认当前仍停在 execute-placeholder 保守边界，而不是把 resume 当成真实签发入口。"
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


def print_lineage_machine_summary(state: dict, lineage: dict):
    state = ensure_dict(state)
    lineage = ensure_dict(lineage)
    print(f"- lineage.mode: {lineage.get('mode', '')}")
    print(f"- lineage.is_resumed_run: {is_effectively_resumed_run(state, lineage)}")
    print(f"- lineage.source_run_id: {lineage.get('source_run_id', '') or '无'}")
    print(f"- lineage.source_checkpoint: {lineage.get('source_checkpoint', '') or '无'}")
    print(f"- lineage.source_resumed_from: {lineage.get('source_resumed_from', '') or '无'}")
    print(f"- lineage.resume_strategy: {lineage.get('resume_strategy', '')}")
    print(f"- lineage.resume_strategy_reason: {lineage.get('resume_strategy_reason', '')}")


def print_status_summary(status: dict):
    status = ensure_dict(status)
    print("[doctor] 状态")
    for key in ["preflight", "generator", "apply_plan", "apply_dry_run", "apply_execute", "repair", "rollback", "final"]:
        print(f"- {key}: {status.get(key, '')}")
    print()


def print_inputs_summary(inputs: dict):
    inputs = ensure_dict(inputs)
    print("[doctor] 输入")
    for key in [
        "deployment_name",
        "base_domain",
        "domain_mode",
        "platform",
        "input_mode",
        "tls_mode",
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
    artifacts = ensure_dict(artifacts)
    print("[doctor] 产物")
    for key, value in artifacts.items():
        if value:
            exists = "exists" if Path(value).exists() else "missing"
            print(f"- {key}: {value} ({exists})")
    print()


def print_apply_result_summary(apply_result: dict, apply_result_json_path: str):
    apply_result = ensure_dict(apply_result)
    print("[doctor] apply result json")
    print(f"- path: {apply_result_json_path}")
    print(f"- mode: {apply_result.get('mode', '')}")
    print(f"- final_status: {apply_result.get('final_status', '')}")
    nginx_test = ensure_dict(apply_result.get("nginx_test"))
    print(f"- nginx_test.requested: {nginx_test.get('requested', False)}")
    print(f"- nginx_test.status: {nginx_test.get('status', '')}")
    execution = ensure_dict(apply_result.get("execution"))
    if execution:
        print(f"- execution.backup_status: {execution.get('backup_status', '')}")
        print(f"- execution.copy_status: {execution.get('copy_status', '')}")
        print(f"- execution.reload_performed: {execution.get('reload_performed', False)}")
    recovery = ensure_dict(apply_result.get("recovery"))
    if recovery:
        print(f"- recovery.installer_status: {recovery.get('installer_status', '')}")
        print(f"- recovery.resume_strategy: {recovery.get('resume_strategy', '')}")
        print(f"- recovery.resume_recommended: {recovery.get('resume_recommended', False)}")
        print(f"- recovery.operator_action: {recovery.get('operator_action', '')}")
    summary = ensure_dict(apply_result.get("summary"))
    for key in ["new", "replace", "same", "conflict", "target_block", "missing_source"]:
        if key in summary:
            print(f"- summary.{key}: {summary.get(key)}")
    next_step = apply_result.get("next_step")
    if next_step:
        print(f"- next_step: {next_step}")
    print()


def print_repair_result_summary(repair_result: dict, repair_result_json_path: str):
    repair_result = ensure_dict(repair_result)
    print("[doctor] repair result json")
    print(f"- path: {repair_result_json_path}")
    print(f"- mode: {repair_result.get('mode', '')}")
    print(f"- final_status: {repair_result.get('final_status', '')}")
    source_recovery = ensure_dict(repair_result.get("source_recovery"))
    if source_recovery:
        print(f"- source_recovery.installer_status: {source_recovery.get('installer_status', '')}")
        print(f"- source_recovery.resume_recommended: {source_recovery.get('resume_recommended', False)}")
        print(f"- source_recovery.operator_action: {source_recovery.get('operator_action', '')}")
    execution = ensure_dict(repair_result.get("execution"))
    if execution:
        print(f"- execution.nginx_test_rerun_status: {execution.get('nginx_test_rerun_status', '')}")
        print(f"- execution.nginx_test_rerun_exit_code: {execution.get('nginx_test_rerun_exit_code', '')}")
    diagnosis = ensure_dict(repair_result.get("diagnosis"))
    for key in ["items_total", "targets_present", "targets_missing", "targets_non_regular", "replace_backups_present", "replace_backups_missing"]:
        if key in diagnosis:
            print(f"- diagnosis.{key}: {diagnosis.get(key)}")
    next_step = repair_result.get("next_step")
    if next_step:
        print(f"- next_step: {next_step}")
    print()


def print_rollback_result_summary(rollback_result: dict, rollback_result_json_path: str):
    rollback_result = ensure_dict(rollback_result)
    print("[doctor] rollback result json")
    print(f"- path: {rollback_result_json_path}")
    print(f"- mode: {rollback_result.get('mode', '')}")
    print(f"- final_status: {rollback_result.get('final_status', '')}")
    flags = ensure_dict(rollback_result.get("flags"))
    if flags:
        print(f"- flags.delete_new: {flags.get('delete_new', False)}")
        print(f"- flags.execute: {flags.get('execute', False)}")
    summary = ensure_dict(rollback_result.get("summary"))
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


def resolve_tls_issue_result_json_paths(artifacts: dict):
    artifacts = ensure_dict(artifacts)
    issue_result_json_path = artifacts.get("issue_result_json") or ""
    acme_issuance_result_json_path = artifacts.get("acme_issuance_result_json") or ""

    base_dir = None
    candidates = [
        issue_result_json_path,
        artifacts.get("issue_result") or "",
        acme_issuance_result_json_path,
        artifacts.get("acme_issuance_result") or "",
        artifacts.get("output_dir_abs") or "",
    ]
    for value in candidates:
        if not value:
            continue
        candidate_path = Path(value)
        if candidate_path.exists():
            base_dir = candidate_path if candidate_path.is_dir() else candidate_path.parent
            break
    if base_dir is None:
        for value in candidates:
            if not value:
                continue
            candidate_path = Path(value)
            base_dir = candidate_path if candidate_path.suffix == "" else candidate_path.parent
            break

    if base_dir is not None:
        if not issue_result_json_path:
            candidate = base_dir / "ISSUE-RESULT.json"
            if candidate.exists():
                issue_result_json_path = str(candidate)
        if not acme_issuance_result_json_path:
            candidate = base_dir / "ACME-ISSUANCE-RESULT.json"
            if candidate.exists():
                acme_issuance_result_json_path = str(candidate)

    return issue_result_json_path, acme_issuance_result_json_path


def print_acme_issuance_result_summary(acme_issuance_result: dict, acme_issuance_result_json_path: str):
    acme_issuance_result = ensure_dict(acme_issuance_result)
    print("[doctor] acme issuance result json")
    print(f"- path: {acme_issuance_result_json_path}")
    print(f"- mode: {acme_issuance_result.get('mode', '')}")
    print(f"- final_status: {acme_issuance_result.get('final_status', '')}")
    intent = ensure_dict(acme_issuance_result.get("intent"))
    if intent:
        print(f"- intent.result_role: {intent.get('result_role', '')}")
        print(f"- intent.real_execution_performed: {intent.get('real_execution_performed', False)}")
    request = ensure_dict(acme_issuance_result.get("request"))
    if request:
        print(f"- request.challenge_mode: {request.get('challenge_mode', '')}")
        print(f"- request.acme_client: {request.get('acme_client', '')}")
        print(f"- request.staging: {request.get('staging', False)}")
    pending_execution_plan = ensure_dict(acme_issuance_result.get("pending_execution_plan"))
    if pending_execution_plan:
        planned_target_hosts = pending_execution_plan.get("planned_target_hosts")
        if isinstance(planned_target_hosts, list) and planned_target_hosts:
            print(f"- pending_execution_plan.planned_target_hosts: {', '.join(str(item) for item in planned_target_hosts)}")
        print(f"- pending_execution_plan.planned_challenge_mode: {pending_execution_plan.get('planned_challenge_mode', '')}")
        print(f"- pending_execution_plan.planned_challenge_fulfillment: {pending_execution_plan.get('planned_challenge_fulfillment', '')}")
        print(f"- pending_execution_plan.planned_acme_client: {pending_execution_plan.get('planned_acme_client', '')}")
        print(f"- pending_execution_plan.planned_acme_directory: {pending_execution_plan.get('planned_acme_directory', '')}")
    execution = ensure_dict(acme_issuance_result.get("execution"))
    if execution:
        print(f"- execution.client_invoked: {execution.get('client_invoked', False)}")
        print(f"- execution.issued_certificate: {execution.get('issued_certificate', False)}")
    deployment_boundary = ensure_dict(acme_issuance_result.get("deployment_boundary"))
    if deployment_boundary:
        print(f"- deployment_boundary.writes_live_tls_paths: {deployment_boundary.get('writes_live_tls_paths', False)}")
        print(f"- deployment_boundary.modifies_live_nginx: {deployment_boundary.get('modifies_live_nginx', False)}")
        print(f"- deployment_boundary.reloads_nginx: {deployment_boundary.get('reloads_nginx', False)}")
    operator_prerequisites = ensure_dict(acme_issuance_result.get("operator_prerequisites"))
    if operator_prerequisites:
        pending = [
            key
            for key in [
                "review_issue_result_before_execute",
                "implement_real_execute_path",
                "confirm_challenge_fulfillment_path",
                "confirm_certificate_write_target",
                "confirm_deployment_boundary",
            ]
            if jsonish_bool(operator_prerequisites.get(key, False))
        ]
        if pending:
            print(f"- operator_prerequisites.pending: {', '.join(pending)}")
    next_step = acme_issuance_result.get("next_step")
    if next_step:
        print(f"- next_step: {next_step}")
    print()


def resolve_followup_result_json_paths(artifacts: dict, apply_result_json_path: str):
    artifacts = with_companion_fallback(artifacts)
    repair_result_json_path = artifacts.get("repair_result_json") or ""
    rollback_result_json_path = artifacts.get("rollback_result_json") or ""
    if not repair_result_json_path or not rollback_result_json_path:
        base_dir = resolve_artifact_base_dir(artifacts)
        if base_dir is not None:
            if not repair_result_json_path:
                candidate = base_dir / "REPAIR-RESULT.json"
                if candidate.exists():
                    repair_result_json_path = str(candidate)
            if not rollback_result_json_path:
                candidate = base_dir / "ROLLBACK-RESULT.json"
                if candidate.exists():
                    rollback_result_json_path = str(candidate)
    return repair_result_json_path, rollback_result_json_path


def build_lineage_chain(current_state: dict, runs_root: Path):
    current_state = ensure_dict(current_state)
    chain = []
    seen = set()
    cur = current_state

    while cur:
        cur = ensure_dict(cur)
        run_id = cur.get("run_id", "")
        if not run_id or run_id in seen:
            break
        seen.add(run_id)
        status = ensure_dict(cur.get("status"))
        lineage = ensure_dict(cur.get("lineage"))
        alerts = collect_abnormal_status_alerts(status)
        chain.append({
            "run_id": run_id,
            "checkpoint": cur.get("checkpoint", "") or "未知",
            "final": status.get("final", "") or "未知",
            "resume_strategy": lineage.get("resume_strategy", "") or "",
            "resume_strategy_reason": lineage.get("resume_strategy_reason", "") or "",
            "is_resumed_run": is_effectively_resumed_run(cur, lineage),
            "alerts": alerts,
            "artifacts": ensure_dict(cur.get("artifacts")),
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
artifacts = ensure_dict(state.get("artifacts"))
apply_result_json_path = artifacts.get("apply_result_json") or ""
apply_result = load_json_if_exists(apply_result_json_path, "apply result json")
issue_result_json_path, acme_issuance_result_json_path = resolve_tls_issue_result_json_paths(artifacts)
issue_result = load_json_if_exists_quiet(issue_result_json_path)
acme_issuance_result = load_json_if_exists(acme_issuance_result_json_path, "acme issuance result json")

repair_result_json_path, rollback_result_json_path = resolve_followup_result_json_paths(
    artifacts,
    apply_result_json_path,
)

repair_result = load_json_if_exists(repair_result_json_path, "repair result json")
rollback_result = load_json_if_exists(rollback_result_json_path, "rollback result json")

raw_lineage = ensure_dict(state.get("lineage"))
effective_lineage = with_effective_resume_strategy(
    raw_lineage,
    load_json_if_exists_quiet(apply_result_json_path),
    load_json_if_exists_quiet(repair_result_json_path),
    load_json_if_exists_quiet(rollback_result_json_path),
    load_json_if_exists_quiet(acme_issuance_result_json_path),
)
lineage = effective_lineage
lineage_for_display = effective_lineage if is_effectively_resumed_run(state, raw_lineage) else raw_lineage
lineage_chain = build_lineage_chain(state, runs_root)
current_run_status = ensure_dict(state.get("status"))
current_run_alerts = collect_abnormal_status_alerts(current_run_status)
current_run_priority = summarize_artifact_priority({
    "alerts": current_run_alerts,
    "artifacts": ensure_dict(state.get("artifacts")),
})
current_run_priority = maybe_prefer_strategy_priority_for_current_run(
    state,
    lineage,
    current_run_alerts,
    current_run_priority,
)
print_current_run_machine_summary(current_run_alerts, current_run_priority)
if lineage_for_display:
    print_lineage_machine_summary(state, lineage_for_display)
    print()
    print("[doctor] lineage 摘要")
    if is_effectively_resumed_run(state, raw_lineage):
        preferred_lineage_priority = print_resume_lineage_summary(state, effective_lineage, lineage_chain)
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
inputs = ensure_dict(state.get("inputs"))
print_inputs_summary(inputs)
status = ensure_dict(state.get("status"))
print_status_summary(status)
print_artifacts_summary(artifacts)

if apply_result:
    print_apply_result_summary(apply_result, apply_result_json_path)

if acme_issuance_result:
    print_acme_issuance_result_summary(acme_issuance_result, acme_issuance_result_json_path)

if repair_result:
    print_repair_result_summary(repair_result, repair_result_json_path)

if rollback_result:
    print_rollback_result_summary(rollback_result, rollback_result_json_path)

print_journal_summary(journal_entries, last_event)

final_status = status.get("final", "")
checkpoint = state.get("checkpoint", "")
suggestion = None
resume_strategy = lineage.get("resume_strategy", "") or ""
suggestion_focus = choose_resume_strategy_suggestion_focus(lineage)
repair_result_hint_path = first_existing_artifact(artifacts, "repair_result_json", "repair_result")
rollback_result_hint_path = first_existing_artifact(artifacts, "rollback_result_json", "rollback_result")

if apply_result and suggestion_focus in {"", "apply"}:
    apply_result = ensure_dict(apply_result)
    apply_final = apply_result.get("final_status", "")
    summary = ensure_dict(apply_result.get("summary"))
    recovery = ensure_dict(apply_result.get("recovery"))
    operator_action = recovery.get("operator_action", "")
    resume_recommended = jsonish_bool(recovery.get("resume_recommended", True))
    if apply_final == "blocked":
        if safe_int(summary.get("conflict"), 0) > 0:
            suggestion = "apply 结果显示存在冲突项；建议先处理目标文件冲突，再重新执行 apply / resume。"
        elif safe_int(summary.get("missing_source"), 0) > 0:
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
    elif operator_action == "manual-review":
        suggestion = apply_result.get("next_step") or "apply 已明确要求先人工复核；建议先检查当前 run 的 apply result 与 recovery 字段，再决定是否继续。"
    elif status.get("apply_execute") == "success":
        suggestion = apply_result.get("next_step") or "真实 apply 已完成；建议人工确认后再决定是否 reload nginx。"
    elif status.get("apply_dry_run") == "success":
        suggestion = "dry-run 已成功；若人工审核计划无误，可带 --execute-apply 继续真实 apply。"

    if suggestion and resume_recommended is False:
        suggestion += " 当前不建议把 resume 当作默认下一步。"

if repair_result and suggestion_focus in {"", "repair"}:
    repair_result = ensure_dict(repair_result)
    repair_final = repair_result.get("final_status", "")
    repair_execution = ensure_dict(repair_result.get("execution"))
    rerun_status = repair_execution.get("nginx_test_rerun_status", "")
    if rerun_status == "passed":
        suggestion = repair_result.get("next_step") or "已存在 repair 结果且 nginx -t 重跑已通过；建议人工确认后，再决定是否继续后续操作。"
    elif rerun_status == "failed":
        suggestion = repair_result.get("next_step") or "已存在 repair 结果且 nginx -t 重跑仍失败；建议优先查看 REPAIR-RESULT，再决定 selective rollback 还是人工修复。"
    elif repair_final in {"blocked", "needs-attention"}:
        suggestion = repair_result.get("next_step") or "已有 repair 结果；建议先按 repair 结论决定 rollback 还是人工修复。"
elif suggestion_focus == "repair" and resume_strategy == "post-repair-verification" and repair_result_hint_path:
    suggestion = "当前处于 post-repair-verification，但结构化 repair 结果缺失或不可读；建议先查看当前 run 的 repair 结果文件，再确认 nginx -t 复查结论。"

if rollback_result and suggestion_focus in {"", "rollback"}:
    rollback_result = ensure_dict(rollback_result)
    rollback_final = rollback_result.get("final_status", "")
    rollback_mode = rollback_result.get("mode", "")
    rollback_flags = ensure_dict(rollback_result.get("flags"))
    if rollback_mode == "execute" and rollback_final == "ok":
        suggestion = rollback_result.get("next_step") or "selective rollback 已执行完成；请先手工运行 nginx -t，再决定是否 reload。"
    elif rollback_final in {"blocked", "needs-attention"}:
        suggestion = rollback_result.get("next_step") or "已存在 rollback 结果；建议先处理 rollback 结果里提示的阻断项或待确认项。"
    elif rollback_flags.get("execute"):
        suggestion = rollback_result.get("next_step") or "已存在 rollback 执行结果；建议先按 rollback 结果复核当前系统状态。"
elif suggestion_focus == "rollback" and resume_strategy == "post-rollback-inspection" and rollback_result_hint_path:
    suggestion = "当前处于 post-rollback-inspection，但结构化 rollback 结果缺失或不可读；建议先查看当前 run 的 rollback 结果文件，再确认现场状态后决定是否继续。"

if suggestion is None and suggestion_focus == "acme" and acme_issuance_result:
    acme_issuance_result = ensure_dict(acme_issuance_result)
    acme_intent = ensure_dict(acme_issuance_result.get("intent"))
    acme_execution = ensure_dict(acme_issuance_result.get("execution"))
    if acme_placeholder_requires_review(acme_issuance_result, acme_intent, acme_execution):
        suggestion = (
            acme_issuance_result.get("next_step")
            or "当前 ACME execute 结果仍是占位语义；请先核对 ISSUE/ACME companion result，再决定是否设计真实 execute 子路径。"
        )

if suggestion is None and acme_issuance_result:
    acme_issuance_result = ensure_dict(acme_issuance_result)
    acme_intent = ensure_dict(acme_issuance_result.get("intent"))
    acme_execution = ensure_dict(acme_issuance_result.get("execution"))
    if (
        acme_intent.get("result_role", "") == "execute-placeholder"
        or not jsonish_bool(acme_intent.get("real_execution_performed", True))
        or acme_issuance_result.get("final_status", "") == "blocked"
        or not jsonish_bool(acme_execution.get("client_invoked", True))
    ):
        suggestion = (
            acme_issuance_result.get("next_step")
            or "当前 ACME execute 结果仍是占位语义；请先核对 ISSUE/ACME companion result，再决定是否设计真实 execute 子路径。"
        )
    elif issue_result:
        issue_result = ensure_dict(issue_result)
        if issue_result.get("next_step"):
            suggestion = issue_result.get("next_step")

if suggestion is None:
    if resume_strategy in {"repair-review-first", "post-repair-verification", "post-rollback-inspection", "inspect-after-apply-attention", "inspect-after-acme-placeholder"}:
        suggestion = (
            f"当前处于 {resume_strategy}；建议先跑 ./install-interactive.sh --doctor {state.get('run_id', '')} "
            "复核当前 run 与 companion result，再决定是否只做 dry-run、repair、rollback 或人工处理。"
        )
    elif final_status in {"success", "cancelled"}:
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
