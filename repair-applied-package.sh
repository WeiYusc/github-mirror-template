#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./repair-applied-package.sh \
    --result-json <path> \
    [--dry-run] \
    [--execute] \
    [--nginx-test-cmd <cmd>] \
    [--result-file <path>]

Current stage:
  - Default is dry-run
  - Does NOT modify deployed files
  - Focuses on conservative post-apply diagnosis for needs-attention cases
  - Optional execute mode only re-runs nginx test command and records findings
  - Does NOT reload nginx
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"

# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/apply-plan.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/state.sh"

RESULT_JSON=""
DRY_RUN="0"
EXECUTE="0"
NGINX_TEST_CMD="nginx -t"
RESULT_FILE=""
RESULT_JSON_OUTPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --result-json)
      RESULT_JSON="$2"; shift 2 ;;
    --dry-run)
      DRY_RUN="1"; shift ;;
    --execute)
      EXECUTE="1"; shift ;;
    --nginx-test-cmd)
      NGINX_TEST_CMD="$2"; shift 2 ;;
    --result-file)
      RESULT_FILE="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "[repair] Unknown argument: $1" >&2
      usage >&2
      exit 1 ;;
  esac
done

if [[ -z "$RESULT_JSON" ]]; then
  echo "[repair] Missing required argument: --result-json <path>" >&2
  exit 2
fi

if [[ ! -f "$RESULT_JSON" ]]; then
  echo "[repair] Result JSON not found: $RESULT_JSON" >&2
  exit 3
fi

if [[ "$DRY_RUN" == "1" && "$EXECUTE" == "1" ]]; then
  echo "[repair] --dry-run 与 --execute 不能同时使用。" >&2
  exit 4
fi

if [[ "$DRY_RUN" != "1" && "$EXECUTE" != "1" ]]; then
  DRY_RUN="1"
fi

if [[ -z "$RESULT_FILE" ]]; then
  RESULT_FILE="$(dirname "$RESULT_JSON")/REPAIR-RESULT.md"
fi
RESULT_JSON_OUTPUT="${RESULT_FILE%.md}.json"
if [[ "$RESULT_JSON_OUTPUT" == "$RESULT_FILE" ]]; then
  RESULT_JSON_OUTPUT="$RESULT_FILE.json"
fi

PARSED_TSV="$(mktemp)"
cleanup() {
  rm -f "$PARSED_TSV"
}
trap cleanup EXIT

python3 - "$RESULT_JSON" "$PARSED_TSV" <<'PY'
import json
import sys
from pathlib import Path

result_json, out_tsv = sys.argv[1:3]
data = json.loads(Path(result_json).read_text(encoding="utf-8"))
backup_dir = data.get("backup_dir", "")
mode = data.get("mode", "")
final_status = data.get("final_status", "")
platform = data.get("platform", "")
next_step = data.get("next_step", "")
execution = data.get("execution") or {}
nginx_test = data.get("nginx_test") or {}
recovery = data.get("recovery") or {}
targets = data.get("targets") or {}
summary = data.get("summary") or {}
items = data.get("items") or []

with open(out_tsv, "w", encoding="utf-8") as fh:
    metas = {
        "backup_dir": backup_dir,
        "mode": mode,
        "final_status": final_status,
        "platform": platform,
        "next_step": next_step,
        "execution_backup_status": execution.get("backup_status", ""),
        "execution_copy_status": execution.get("copy_status", ""),
        "execution_reload_performed": str(execution.get("reload_performed", False)).lower(),
        "nginx_test_requested": str(nginx_test.get("requested", False)).lower(),
        "nginx_test_status": nginx_test.get("status", ""),
        "recovery_installer_status": recovery.get("installer_status", ""),
        "recovery_resume_strategy": recovery.get("resume_strategy", ""),
        "recovery_resume_recommended": str(recovery.get("resume_recommended", False)).lower(),
        "recovery_operator_action": recovery.get("operator_action", ""),
        "snippets": targets.get("snippets", ""),
        "vhost": targets.get("vhost", ""),
        "error_root": targets.get("error_root", ""),
        "summary_new": summary.get("new", 0),
        "summary_replace": summary.get("replace", 0),
        "summary_same": summary.get("same", 0),
        "summary_conflict": summary.get("conflict", 0),
        "summary_target_block": summary.get("target_block", 0),
        "summary_missing_source": summary.get("missing_source", 0),
    }
    for key, value in metas.items():
        fh.write(f"META\t{key}\t{value}\n")
    for item in items:
        category = str(item.get("category", ""))
        source = str(item.get("source", ""))
        dest = str(item.get("dest", ""))
        status = str(item.get("status", ""))
        note = str(item.get("note", ""))
        fh.write("ITEM\t%s\t%s\t%s\t%s\t%s\n" % (
            category.replace("\t", " "),
            source.replace("\t", " "),
            dest.replace("\t", " "),
            status.replace("\t", " "),
            note.replace("\t", " "),
        ))
PY

REPAIR_SOURCE_MODE=""
REPAIR_SOURCE_FINAL_STATUS=""
REPAIR_PLATFORM=""
REPAIR_BACKUP_DIR=""
REPAIR_NEXT_STEP_FROM_APPLY=""
REPAIR_EXECUTION_BACKUP_STATUS=""
REPAIR_EXECUTION_COPY_STATUS=""
REPAIR_EXECUTION_RELOAD_PERFORMED="false"
REPAIR_NGINX_TEST_REQUESTED="false"
REPAIR_NGINX_TEST_STATUS=""
REPAIR_INSTALLER_STATUS=""
REPAIR_RESUME_STRATEGY=""
REPAIR_RESUME_RECOMMENDED="false"
REPAIR_OPERATOR_ACTION=""
REPAIR_SNIPPETS_TARGET=""
REPAIR_VHOST_TARGET=""
REPAIR_ERROR_ROOT=""
SOURCE_SUMMARY_NEW="0"
SOURCE_SUMMARY_REPLACE="0"
SOURCE_SUMMARY_SAME="0"
SOURCE_SUMMARY_CONFLICT="0"
SOURCE_SUMMARY_TARGET_BLOCK="0"
SOURCE_SUMMARY_MISSING_SOURCE="0"

ITEM_TOTAL=0
ITEM_PRESENT=0
ITEM_MISSING=0
ITEM_NONREGULAR=0
ITEM_SOURCE_MISSING=0
ITEM_NEW=0
ITEM_REPLACE=0
ITEM_SAME=0
ITEM_CONFLICT=0
ITEM_TARGET_BLOCK=0
ITEM_MISSING_SOURCE_STATUS=0
BACKUP_PRESENT=0
BACKUP_MISSING=0
TARGET_ROWS=()
ROW_SEP=$'\x1f'

while IFS=$'\t' read -r kind key value extra1 extra2 extra3; do
  if [[ "$kind" == "META" ]]; then
    case "$key" in
      backup_dir) REPAIR_BACKUP_DIR="$value" ;;
      mode) REPAIR_SOURCE_MODE="$value" ;;
      final_status) REPAIR_SOURCE_FINAL_STATUS="$value" ;;
      platform) REPAIR_PLATFORM="$value" ;;
      next_step) REPAIR_NEXT_STEP_FROM_APPLY="$value" ;;
      execution_backup_status) REPAIR_EXECUTION_BACKUP_STATUS="$value" ;;
      execution_copy_status) REPAIR_EXECUTION_COPY_STATUS="$value" ;;
      execution_reload_performed) REPAIR_EXECUTION_RELOAD_PERFORMED="$value" ;;
      nginx_test_requested) REPAIR_NGINX_TEST_REQUESTED="$value" ;;
      nginx_test_status) REPAIR_NGINX_TEST_STATUS="$value" ;;
      recovery_installer_status) REPAIR_INSTALLER_STATUS="$value" ;;
      recovery_resume_strategy) REPAIR_RESUME_STRATEGY="$value" ;;
      recovery_resume_recommended) REPAIR_RESUME_RECOMMENDED="$value" ;;
      recovery_operator_action) REPAIR_OPERATOR_ACTION="$value" ;;
      snippets) REPAIR_SNIPPETS_TARGET="$value" ;;
      vhost) REPAIR_VHOST_TARGET="$value" ;;
      error_root) REPAIR_ERROR_ROOT="$value" ;;
      summary_new) SOURCE_SUMMARY_NEW="$value" ;;
      summary_replace) SOURCE_SUMMARY_REPLACE="$value" ;;
      summary_same) SOURCE_SUMMARY_SAME="$value" ;;
      summary_conflict) SOURCE_SUMMARY_CONFLICT="$value" ;;
      summary_target_block) SOURCE_SUMMARY_TARGET_BLOCK="$value" ;;
      summary_missing_source) SOURCE_SUMMARY_MISSING_SOURCE="$value" ;;
    esac
    continue
  fi

  if [[ "$kind" != "ITEM" ]]; then
    continue
  fi

  category="$key"
  source="$value"
  dest="$extra1"
  original_status="$extra2"
  note="$extra3"
  ITEM_TOTAL=$((ITEM_TOTAL + 1))

  case "$original_status" in
    NEW) ITEM_NEW=$((ITEM_NEW + 1)) ;;
    REPLACE) ITEM_REPLACE=$((ITEM_REPLACE + 1)) ;;
    SAME) ITEM_SAME=$((ITEM_SAME + 1)) ;;
    CONFLICT) ITEM_CONFLICT=$((ITEM_CONFLICT + 1)) ;;
    TARGET-BLOCK) ITEM_TARGET_BLOCK=$((ITEM_TARGET_BLOCK + 1)) ;;
    MISSING-SOURCE) ITEM_MISSING_SOURCE_STATUS=$((ITEM_MISSING_SOURCE_STATUS + 1)) ;;
  esac

  target_kind="missing"
  target_note="目标不存在"
  if [[ -e "$dest" ]]; then
    if [[ -f "$dest" ]]; then
      target_kind="regular-file"
      target_note="目标存在且为普通文件"
      ITEM_PRESENT=$((ITEM_PRESENT + 1))
    else
      target_kind="non-regular"
      target_note="目标存在但不是普通文件"
      ITEM_NONREGULAR=$((ITEM_NONREGULAR + 1))
    fi
  else
    ITEM_MISSING=$((ITEM_MISSING + 1))
  fi

  source_kind="missing"
  source_note="记录中的源文件不存在"
  if [[ -f "$source" ]]; then
    source_kind="regular-file"
    source_note="记录中的源文件存在"
  else
    ITEM_SOURCE_MISSING=$((ITEM_SOURCE_MISSING + 1))
  fi

  backup_path=""
  backup_kind="not-applicable"
  backup_note="该项无需备份"
  if [[ "$original_status" == "REPLACE" && -n "$dest" && "$dest" == /* ]]; then
    backup_path="$REPAIR_BACKUP_DIR/files/${dest#/}"
    if [[ -f "$backup_path" ]]; then
      backup_kind="present"
      backup_note="REPLACE 对应备份存在"
      BACKUP_PRESENT=$((BACKUP_PRESENT + 1))
    else
      backup_kind="missing"
      backup_note="REPLACE 对应备份缺失"
      BACKUP_MISSING=$((BACKUP_MISSING + 1))
    fi
  fi

  planned_action="review"
  planned_outcome="diagnosed"
  planned_note="当前 repair 第一刀只做诊断，不直接改文件。"

  if [[ "$original_status" == "REPLACE" && "$backup_kind" == "missing" ]]; then
    planned_action="block"
    planned_outcome="missing-backup"
    planned_note="REPLACE 项缺少备份；若需要恢复，只能先人工补查备份来源。"
  elif [[ "$original_status" == "NEW" && "$target_kind" == "missing" ]]; then
    planned_action="review"
    planned_outcome="already-absent"
    planned_note="NEW 项当前已经不存在，无需修复或回滚。"
  elif [[ "$original_status" == "NEW" && "$target_kind" == "regular-file" ]]; then
    planned_action="review"
    planned_outcome="candidate-rollback-or-fix"
    planned_note="NEW 项已落地；若 nginx 测试失败，后续通常应在人工确认后选择 rollback 或修配置。"
  elif [[ "$original_status" == "REPLACE" && "$target_kind" == "regular-file" && "$backup_kind" == "present" ]]; then
    planned_action="review"
    planned_outcome="candidate-restore-or-fix"
    planned_note="REPLACE 项具备回滚条件；若确认为问题来源，可优先走 selective rollback。"
  elif [[ "$target_kind" == "non-regular" ]]; then
    planned_action="block"
    planned_outcome="dest-not-regular-file"
    planned_note="目标路径不是普通文件；后续无论 repair 还是 rollback 都应先人工处理。"
  fi

  TARGET_ROWS+=("$category${ROW_SEP}$source${ROW_SEP}$dest${ROW_SEP}$original_status${ROW_SEP}$target_kind${ROW_SEP}$source_kind${ROW_SEP}$backup_path${ROW_SEP}$backup_kind${ROW_SEP}$planned_action${ROW_SEP}$planned_outcome${ROW_SEP}$planned_note")
done < "$PARSED_TSV"

MODE_LABEL="dry-run"
if [[ "$EXECUTE" == "1" ]]; then
  MODE_LABEL="execute"
fi

NTEST_RUN_STATUS="not-run"
NTEST_EXIT_CODE=""
NTEST_OUTPUT_FILE=""
REPAIR_FINAL_STATUS="ok"
REPAIR_NEXT_STEP="建议先阅读诊断摘要，确认是应走 selective rollback 还是人工修复配置。"

if [[ "$REPAIR_SOURCE_MODE" != "execute" ]]; then
  REPAIR_FINAL_STATUS="blocked"
  REPAIR_NEXT_STEP="来源 APPLY-RESULT.json 不是 execute 模式；repair helper 当前不把 dry-run 结果当作 post-apply repair 依据。"
elif [[ "$REPAIR_INSTALLER_STATUS" == "needs-attention" || "$REPAIR_SOURCE_FINAL_STATUS" == "needs-attention" ]]; then
  REPAIR_FINAL_STATUS="needs-attention"
  REPAIR_NEXT_STEP="当前处于 needs-attention；建议先复核诊断项，再决定是 rollback 还是人工修复后重跑 nginx -t。"
fi

if [[ "$BACKUP_MISSING" -gt 0 || "$ITEM_NONREGULAR" -gt 0 ]]; then
  REPAIR_FINAL_STATUS="blocked"
  REPAIR_NEXT_STEP="诊断发现缺失备份或异常目标路径；应先人工处理这些阻断项，再考虑 repair / rollback。"
fi

if [[ "$EXECUTE" == "1" ]]; then
  NTEST_OUTPUT_FILE="$(dirname "$RESULT_JSON")/REPAIR-NGINX-TEST.txt"
  set +e
  bash -lc "$NGINX_TEST_CMD" > "$NTEST_OUTPUT_FILE" 2>&1
  NTEST_EXIT_CODE="$?"
  set -e
  if [[ "$NTEST_EXIT_CODE" == "0" ]]; then
    NTEST_RUN_STATUS="passed"
    if [[ "$REPAIR_FINAL_STATUS" != "blocked" ]]; then
      REPAIR_FINAL_STATUS="ok"
      REPAIR_NEXT_STEP="nginx -t 已通过；接下来应人工判断是否已无需 rollback，仅保留问题说明并继续后续操作。"
    fi
  else
    NTEST_RUN_STATUS="failed"
    if [[ "$REPAIR_FINAL_STATUS" != "blocked" ]]; then
      REPAIR_FINAL_STATUS="needs-attention"
      REPAIR_NEXT_STEP="重新执行 nginx -t 仍失败；请结合 REPAIR-RESULT 与测试输出，优先决定 rollback 还是人工修配置。"
    fi
  fi
fi

json_bool() {
  if [[ "${1:-0}" == "1" || "${1:-}" == "true" ]]; then
    printf 'true'
  else
    printf 'false'
  fi
}

write_repair_result_json() {
  local target_json="$1"
  mkdir -p "$(dirname "$target_json")"

  {
    echo '{'
    printf '  "mode": %s,\n' "$(apply_plan_json_escape "$MODE_LABEL")"
    printf '  "final_status": %s,\n' "$(apply_plan_json_escape "$REPAIR_FINAL_STATUS")"
    printf '  "source_apply_result": %s,\n' "$(apply_plan_json_escape "$RESULT_JSON")"
    printf '  "source_mode": %s,\n' "$(apply_plan_json_escape "$REPAIR_SOURCE_MODE")"
    printf '  "source_final_status": %s,\n' "$(apply_plan_json_escape "$REPAIR_SOURCE_FINAL_STATUS")"
    printf '  "platform": %s,\n' "$(apply_plan_json_escape "$REPAIR_PLATFORM")"
    printf '  "backup_dir": %s,\n' "$(apply_plan_json_escape "$REPAIR_BACKUP_DIR")"
    printf '  "nginx_test_cmd": %s,\n' "$(apply_plan_json_escape "$NGINX_TEST_CMD")"
    echo '  "source_recovery": {'
    printf '    "installer_status": %s,\n' "$(apply_plan_json_escape "$REPAIR_INSTALLER_STATUS")"
    printf '    "resume_strategy": %s,\n' "$(apply_plan_json_escape "$REPAIR_RESUME_STRATEGY")"
    printf '    "resume_recommended": %s,\n' "$(json_bool "$REPAIR_RESUME_RECOMMENDED")"
    printf '    "operator_action": %s\n' "$(apply_plan_json_escape "$REPAIR_OPERATOR_ACTION")"
    echo '  },'
    echo '  "execution": {'
    printf '    "source_backup_status": %s,\n' "$(apply_plan_json_escape "$REPAIR_EXECUTION_BACKUP_STATUS")"
    printf '    "source_copy_status": %s,\n' "$(apply_plan_json_escape "$REPAIR_EXECUTION_COPY_STATUS")"
    printf '    "source_reload_performed": %s,\n' "$(json_bool "$REPAIR_EXECUTION_RELOAD_PERFORMED")"
    printf '    "nginx_test_rerun_status": %s,\n' "$(apply_plan_json_escape "$NTEST_RUN_STATUS")"
    printf '    "nginx_test_rerun_exit_code": %s,\n' "$(apply_plan_json_escape "$NTEST_EXIT_CODE")"
    printf '    "nginx_test_rerun_output": %s\n' "$(apply_plan_json_escape "$NTEST_OUTPUT_FILE")"
    echo '  },'
    echo '  "source_summary": {'
    printf '    "new": %s,\n' "$SOURCE_SUMMARY_NEW"
    printf '    "replace": %s,\n' "$SOURCE_SUMMARY_REPLACE"
    printf '    "same": %s,\n' "$SOURCE_SUMMARY_SAME"
    printf '    "conflict": %s,\n' "$SOURCE_SUMMARY_CONFLICT"
    printf '    "target_block": %s,\n' "$SOURCE_SUMMARY_TARGET_BLOCK"
    printf '    "missing_source": %s\n' "$SOURCE_SUMMARY_MISSING_SOURCE"
    echo '  },'
    echo '  "diagnosis": {'
    printf '    "items_total": %s,\n' "$ITEM_TOTAL"
    printf '    "targets_present": %s,\n' "$ITEM_PRESENT"
    printf '    "targets_missing": %s,\n' "$ITEM_MISSING"
    printf '    "targets_non_regular": %s,\n' "$ITEM_NONREGULAR"
    printf '    "sources_missing": %s,\n' "$ITEM_SOURCE_MISSING"
    printf '    "replace_backups_present": %s,\n' "$BACKUP_PRESENT"
    printf '    "replace_backups_missing": %s\n' "$BACKUP_MISSING"
    echo '  },'
    printf '  "next_step": %s,\n' "$(apply_plan_json_escape "$REPAIR_NEXT_STEP")"
    echo '  "items": ['

    row_count="${#TARGET_ROWS[@]}"
    idx=0
    for row in "${TARGET_ROWS[@]}"; do
      idx=$((idx + 1))
      IFS="$ROW_SEP" read -r category source dest original_status target_kind source_kind backup_path backup_kind planned_action planned_outcome planned_note <<< "$row"
      echo '    {'
      printf '      "category": %s,\n' "$(apply_plan_json_escape "$category")"
      printf '      "source": %s,\n' "$(apply_plan_json_escape "$source")"
      printf '      "dest": %s,\n' "$(apply_plan_json_escape "$dest")"
      printf '      "original_status": %s,\n' "$(apply_plan_json_escape "$original_status")"
      printf '      "target_kind": %s,\n' "$(apply_plan_json_escape "$target_kind")"
      printf '      "source_kind": %s,\n' "$(apply_plan_json_escape "$source_kind")"
      printf '      "backup_path": %s,\n' "$(apply_plan_json_escape "$backup_path")"
      printf '      "backup_kind": %s,\n' "$(apply_plan_json_escape "$backup_kind")"
      printf '      "planned_action": %s,\n' "$(apply_plan_json_escape "$planned_action")"
      printf '      "planned_outcome": %s,\n' "$(apply_plan_json_escape "$planned_outcome")"
      printf '      "note": %s\n' "$(apply_plan_json_escape "$planned_note")"
      if [[ "$idx" -lt "$row_count" ]]; then
        echo '    },'
      else
        echo '    }'
      fi
    done

    echo '  ]'
    echo '}'
  } > "$target_json"

  return 0
}

write_repair_result_markdown() {
  local target_file="$1"
  mkdir -p "$(dirname "$target_file")"

  cat > "$target_file" <<EOF
# REPAIR RESULT

## 执行概览

- 模式：$MODE_LABEL
- 状态：$REPAIR_FINAL_STATUS
- 来源 APPLY-RESULT.json：$RESULT_JSON
- 来源 apply 模式：$REPAIR_SOURCE_MODE
- 来源 apply 状态：$REPAIR_SOURCE_FINAL_STATUS
- 平台：$REPAIR_PLATFORM
- 备份目录：$REPAIR_BACKUP_DIR
- nginx 测试重跑：$NTEST_RUN_STATUS
- nginx reload：未执行
- 当前 repair 边界：不直接改写已部署文件

## 来源 recovery 信息

- installer_status：$REPAIR_INSTALLER_STATUS
- resume_strategy：$REPAIR_RESUME_STRATEGY
- resume_recommended：$REPAIR_RESUME_RECOMMENDED
- operator_action：$REPAIR_OPERATOR_ACTION

## 诊断摘要

- 总项数：$ITEM_TOTAL
- 目标存在：$ITEM_PRESENT
- 目标缺失：$ITEM_MISSING
- 目标非普通文件：$ITEM_NONREGULAR
- 源文件缺失：$ITEM_SOURCE_MISSING
- REPLACE 备份存在：$BACKUP_PRESENT
- REPLACE 备份缺失：$BACKUP_MISSING

## 下一步建议

- $REPAIR_NEXT_STEP

## 风险边界

- 当前不会自动 reload nginx
- 当前不会直接修改目标文件
- 当前不会替你自动决定“修”还是“回滚”
- --execute 也只会重跑 nginx 测试命令并记录结果
EOF

  if [[ -n "$NTEST_OUTPUT_FILE" ]]; then
    {
      echo
      echo "## nginx 测试重跑输出"
      echo
      echo "- 输出文件：$NTEST_OUTPUT_FILE"
    } >> "$target_file"
  fi

  if [[ ${#TARGET_ROWS[@]} -gt 0 ]]; then
    {
      echo
      echo "## 明细"
      echo
      for row in "${TARGET_ROWS[@]}"; do
        IFS="$ROW_SEP" read -r category source dest original_status target_kind source_kind backup_path backup_kind planned_action planned_outcome planned_note <<< "$row"
        echo "- [$planned_action/$planned_outcome] $category: $dest"
        echo "  - 原始状态：$original_status"
        echo "  - 目标状态：$target_kind"
        echo "  - 源状态：$source_kind"
        [[ -n "$backup_path" ]] && echo "  - backup：$backup_path ($backup_kind)"
        [[ -n "$planned_note" ]] && echo "  - $planned_note"
      done
    } >> "$target_file"
  fi

  return 0
}

write_repair_result_markdown "$RESULT_FILE"
write_repair_result_json "$RESULT_JSON_OUTPUT"

STATE_JSON_HINT="$(python3 - "$(dirname "$RESULT_JSON")/INSTALLER-SUMMARY.json" <<'PY'
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
  state_record_companion_result "repair" "$RESULT_FILE" "$RESULT_JSON_OUTPUT" "$REPAIR_FINAL_STATUS" "repair result recorded"
fi

cat <<EOF
[repair] 当前模式：$MODE_LABEL
[repair] 来源 APPLY-RESULT.json：$RESULT_JSON
[repair] 来源 apply 模式：$REPAIR_SOURCE_MODE
[repair] 来源 apply 状态：$REPAIR_SOURCE_FINAL_STATUS
[repair] 备份目录：$REPAIR_BACKUP_DIR
[repair] nginx 测试重跑：$NTEST_RUN_STATUS
[repair] 结果摘要文件：$RESULT_FILE
[repair] 结果 JSON 文件：$RESULT_JSON_OUTPUT
[repair] 诊断摘要：items=$ITEM_TOTAL present=$ITEM_PRESENT missing=$ITEM_MISSING non_regular=$ITEM_NONREGULAR backup_missing=$BACKUP_MISSING
[repair] 最终状态：$REPAIR_FINAL_STATUS
[repair] 下一步：$REPAIR_NEXT_STEP
EOF

if [[ "$EXECUTE" == "1" && "$REPAIR_FINAL_STATUS" == "blocked" ]]; then
  exit 6
fi
