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
  state_init_paths "$RUNS_ROOT_DIR" "$run_id"

  if [[ ! -f "$STATE_INPUTS_PATH" ]]; then
    echo "[state] 未找到输入快照：$STATE_INPUTS_PATH" >&2
    return 1
  fi

  # shellcheck disable=SC1090
  source "$STATE_INPUTS_PATH"
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

state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
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
values = {
    "RESUME_SOURCE_RUN_ID": state.get("run_id", ""),
    "RESUME_SOURCE_CHECKPOINT": state.get("checkpoint", ""),
    "RESUME_SOURCE_PREFLIGHT_STATUS": status.get("preflight", ""),
    "RESUME_SOURCE_GENERATOR_STATUS": status.get("generator", ""),
    "RESUME_SOURCE_APPLY_PLAN_STATUS": status.get("apply_plan", ""),
    "RESUME_SOURCE_DRY_RUN_STATUS": status.get("apply_dry_run", ""),
    "RESUME_SOURCE_EXECUTE_STATUS": status.get("apply_execute", ""),
    "RESUME_SOURCE_FINAL_STATUS": status.get("final", ""),
    "RESUME_SOURCE_CONFIG_PATH": artifacts.get("config", ""),
    "RESUME_SOURCE_OUTPUT_DIR_ABS": artifacts.get("output_dir_abs", ""),
    "RESUME_SOURCE_PREFLIGHT_REPORT_MD": artifacts.get("preflight_markdown", ""),
    "RESUME_SOURCE_PREFLIGHT_REPORT_JSON": artifacts.get("preflight_json", ""),
    "RESUME_SOURCE_APPLY_PLAN_PATH": artifacts.get("apply_plan_markdown", ""),
    "RESUME_SOURCE_APPLY_PLAN_JSON_PATH": artifacts.get("apply_plan_json", ""),
    "RESUME_SOURCE_APPLY_RESULT_PATH": artifacts.get("apply_result", ""),
    "RESUME_SOURCE_APPLY_RESULT_JSON_PATH": artifacts.get("apply_result_json", ""),
    "RESUME_SOURCE_APPLY_RECOVERY_STATUS": recovery.get("installer_status", ""),
    "RESUME_SOURCE_APPLY_RESUME_STRATEGY": recovery.get("resume_strategy", ""),
    "RESUME_SOURCE_APPLY_RESUME_RECOMMENDED": "1" if recovery.get("resume_recommended", True) else "0",
    "RESUME_SOURCE_APPLY_OPERATOR_ACTION": recovery.get("operator_action", ""),
    "RESUME_SOURCE_APPLY_NEXT_STEP": apply_result.get("next_step", ""),
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

state_write_json() {
  local checkpoint="${1:-${INSTALLER_CHECKPOINT:-initialized}}"
  local note="${2:-}"
  local resumed_from="${RESUME_RUN_ID:-}"

  mkdir -p "$(dirname "$STATE_JSON_PATH")"

  python3 - "$STATE_JSON_PATH" "$checkpoint" "$note" "$resumed_from" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

state_path, checkpoint, note, resumed_from = sys.argv[1:]

def env(name: str, default: str = ""):
    return os.environ.get(name, default)

payload = {
    "run_id": env("RUN_ID"),
    "state_dir": env("STATE_DIR"),
    "updated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "checkpoint": checkpoint,
    "note": note,
    "resumed_from": resumed_from,
    "status": {
        "preflight": env("INSTALLER_PREFLIGHT_STATUS", "pending"),
        "generator": env("INSTALLER_GENERATOR_STATUS", "pending"),
        "apply_plan": env("INSTALLER_APPLY_PLAN_STATUS", "pending"),
        "apply_dry_run": env("INSTALLER_DRY_RUN_STATUS", "not-requested"),
        "apply_execute": env("INSTALLER_EXECUTE_STATUS", "not-requested"),
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

state_mark_checkpoint() {
  local checkpoint="$1"
  local note="${2:-}"
  INSTALLER_CHECKPOINT="$checkpoint"

  export RUNS_ROOT_DIR RUN_ID STATE_DIR STATE_JSON_PATH STATE_JOURNAL_PATH STATE_INPUTS_PATH
  export RESUME_RUN_ID INSTALLER_CHECKPOINT INSTALLER_MODE
  export DEPLOYMENT_NAME BASE_DOMAIN DOMAIN_MODE PLATFORM TLS_CERT TLS_KEY INPUT_MODE INSTALL_INPUT_MODE
  export ERROR_ROOT LOG_DIR OUTPUT_DIR NGINX_SNIPPETS_TARGET_HINT NGINX_VHOST_TARGET_HINT
  export RUN_APPLY_DRY_RUN EXECUTE_APPLY BACKUP_DIR RUN_NGINX_TEST_AFTER_EXECUTE NGINX_TEST_CMD ASSUME_YES
  export DEFAULT_ERROR_ROOT DEFAULT_LOG_DIR DEFAULT_OUTPUT_DIR DEFAULT_NGINX_SNIPPETS_TARGET_HINT DEFAULT_NGINX_VHOST_TARGET_HINT
  export INSTALLER_PREFLIGHT_STATUS INSTALLER_GENERATOR_STATUS INSTALLER_APPLY_PLAN_STATUS INSTALLER_DRY_RUN_STATUS INSTALLER_EXECUTE_STATUS INSTALLER_FINAL_STATUS
  export GENERATED_DIR PREFLIGHT_REPORT_MD PREFLIGHT_REPORT_JSON SUMMARY_JSON_PRIMARY SUMMARY_JSON_SECONDARY CONFIG_PATH OUTPUT_DIR_ABS APPLY_PLAN_PATH APPLY_PLAN_JSON_PATH APPLY_RESULT_PATH APPLY_RESULT_JSON_PATH

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

print("[doctor] 运行摘要")
print(f"- run_id: {state.get('run_id', '')}")
print(f"- state_dir: {state.get('state_dir', '')}")
print(f"- updated_at: {state.get('updated_at', '')}")
print(f"- checkpoint: {state.get('checkpoint', '')}")
print(f"- resumed_from: {state.get('resumed_from', '') or '无'}")
print()
print("[doctor] 输入")
inputs = state.get("inputs", {})
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
print("[doctor] 状态")
status = state.get("status", {})
for key in ["preflight", "generator", "apply_plan", "apply_dry_run", "apply_execute", "final"]:
    print(f"- {key}: {status.get(key, '')}")
print()
print("[doctor] 产物")
artifacts = state.get("artifacts", {})
for key, value in artifacts.items():
    if value:
        exists = "exists" if Path(value).exists() else "missing"
        print(f"- {key}: {value} ({exists})")
print()

apply_result = None
apply_result_json_path = artifacts.get("apply_result_json")
if apply_result_json_path and Path(apply_result_json_path).exists():
    try:
        apply_result = json.loads(Path(apply_result_json_path).read_text(encoding="utf-8"))
    except Exception as exc:
        print("[doctor] apply result json")
        print(f"- 读取失败: {apply_result_json_path} ({exc})")
        print()

if apply_result:
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

print("[doctor] journal")
print(f"- entries: {journal_entries}")
if last_event:
    print(f"- last_event: {last_event.get('event', '')} [{last_event.get('status', '')}]")
    if last_event.get("message"):
        print(f"- last_message: {last_event.get('message')}")
print()

final_status = status.get("final", "")
checkpoint = state.get("checkpoint", "")
suggestion = None
if apply_result:
    apply_final = apply_result.get("final_status", "")
    nginx_status = (apply_result.get("nginx_test") or {}).get("status", "")
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
        suggestion = "真实 apply 已落盘，但 nginx 测试失败；当前更适合先人工回滚或修复，再决定是否重跑，而不是直接 resume。"
    elif operator_action == "manual-nginx-test":
        suggestion = "真实 apply 已落盘，但尚未执行 nginx -t；建议先手工执行 nginx -t，再决定是否继续。"
    elif status.get("apply_execute") == "success":
        suggestion = apply_result.get("next_step") or "真实 apply 已完成；建议人工确认后再决定是否 reload nginx。"
    elif status.get("apply_dry_run") == "success":
        suggestion = "dry-run 已成功；若人工审核计划无误，可带 --execute-apply 继续真实 apply。"

    if suggestion and resume_recommended is False:
        suggestion += " 当前不建议把 resume 当作默认下一步。"

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

print("[doctor] 下一步建议")
print(f"- {suggestion}")
if Path(inputs_path).exists():
    print(f"- 输入快照可用于 resume：{inputs_path}")
PY
}
