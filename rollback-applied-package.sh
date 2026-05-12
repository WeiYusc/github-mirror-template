#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./rollback-applied-package.sh \
    --result-json <path> \
    [--dry-run] \
    [--execute] \
    [--delete-new] \
    [--result-file <path>]

Current stage:
  - Default is dry-run
  - Restore REPLACE files from backup_dir/files/<absolute-path>
  - NEW files are deleted only with explicit --delete-new
  - NEW file deletion is conservative: only when current target still matches recorded source
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
DELETE_NEW="0"
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
    --delete-new)
      DELETE_NEW="1"; shift ;;
    --result-file)
      RESULT_FILE="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "[rollback] Unknown argument: $1" >&2
      usage >&2
      exit 1 ;;
  esac
done

if [[ -z "$RESULT_JSON" ]]; then
  echo "[rollback] Missing required argument: --result-json <path>" >&2
  exit 2
fi

if [[ ! -f "$RESULT_JSON" ]]; then
  echo "[rollback] Result JSON not found: $RESULT_JSON" >&2
  exit 3
fi

if [[ "$DRY_RUN" == "1" && "$EXECUTE" == "1" ]]; then
  echo "[rollback] --dry-run 与 --execute 不能同时使用。" >&2
  exit 4
fi

if [[ "$DRY_RUN" != "1" && "$EXECUTE" != "1" ]]; then
  DRY_RUN="1"
fi

if [[ -z "$RESULT_FILE" ]]; then
  RESULT_FILE="$(dirname "$RESULT_JSON")/ROLLBACK-RESULT.md"
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
import os
import sys
from pathlib import Path

result_json, out_tsv = sys.argv[1:3]
data = json.loads(Path(result_json).read_text(encoding="utf-8"))
backup_dir = data.get("backup_dir", "")
mode = data.get("mode", "")
final_status = data.get("final_status", "")
platform = data.get("platform", "")
targets = data.get("targets") or {}
summary = data.get("summary") or {}
items = data.get("items") or []

with open(out_tsv, "w", encoding="utf-8") as fh:
    fh.write(f"META\tbackup_dir\t{backup_dir}\n")
    fh.write(f"META\tmode\t{mode}\n")
    fh.write(f"META\tfinal_status\t{final_status}\n")
    fh.write(f"META\tplatform\t{platform}\n")
    fh.write(f"META\tsnippets\t{targets.get('snippets', '')}\n")
    fh.write(f"META\tvhost\t{targets.get('vhost', '')}\n")
    fh.write(f"META\terror_root\t{targets.get('error_root', '')}\n")
    fh.write(f"META\tsummary_new\t{summary.get('new', 0)}\n")
    fh.write(f"META\tsummary_replace\t{summary.get('replace', 0)}\n")
    fh.write(f"META\tsummary_same\t{summary.get('same', 0)}\n")
    fh.write(f"META\tsummary_conflict\t{summary.get('conflict', 0)}\n")
    fh.write(f"META\tsummary_target_block\t{summary.get('target_block', 0)}\n")
    fh.write(f"META\tsummary_missing_source\t{summary.get('missing_source', 0)}\n")
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

ROLLBACK_SOURCE_MODE=""
ROLLBACK_SOURCE_FINAL_STATUS=""
ROLLBACK_PLATFORM=""
ROLLBACK_BACKUP_DIR=""
ROLLBACK_SNIPPETS_TARGET=""
ROLLBACK_VHOST_TARGET=""
ROLLBACK_ERROR_ROOT=""
SOURCE_SUMMARY_NEW="0"
SOURCE_SUMMARY_REPLACE="0"
SOURCE_SUMMARY_SAME="0"
SOURCE_SUMMARY_CONFLICT="0"
SOURCE_SUMMARY_TARGET_BLOCK="0"
SOURCE_SUMMARY_MISSING_SOURCE="0"

while IFS=$'\t' read -r kind key value extra1 extra2 extra3; do
  if [[ "$kind" != "META" ]]; then
    continue
  fi
  case "$key" in
    backup_dir) ROLLBACK_BACKUP_DIR="$value" ;;
    mode) ROLLBACK_SOURCE_MODE="$value" ;;
    final_status) ROLLBACK_SOURCE_FINAL_STATUS="$value" ;;
    platform) ROLLBACK_PLATFORM="$value" ;;
    snippets) ROLLBACK_SNIPPETS_TARGET="$value" ;;
    vhost) ROLLBACK_VHOST_TARGET="$value" ;;
    error_root) ROLLBACK_ERROR_ROOT="$value" ;;
    summary_new) SOURCE_SUMMARY_NEW="$value" ;;
    summary_replace) SOURCE_SUMMARY_REPLACE="$value" ;;
    summary_same) SOURCE_SUMMARY_SAME="$value" ;;
    summary_conflict) SOURCE_SUMMARY_CONFLICT="$value" ;;
    summary_target_block) SOURCE_SUMMARY_TARGET_BLOCK="$value" ;;
    summary_missing_source) SOURCE_SUMMARY_MISSING_SOURCE="$value" ;;
  esac
done < "$PARSED_TSV"

if [[ -z "$ROLLBACK_BACKUP_DIR" ]]; then
  echo "[rollback] APPLY-RESULT.json 中缺少 backup_dir，无法继续。" >&2
  exit 5
fi

MODE_LABEL="dry-run"
if [[ "$EXECUTE" == "1" ]]; then
  MODE_LABEL="execute"
fi

ACTION_ROWS=()
ACTION_COUNT_RESTORE=0
ACTION_COUNT_DELETE=0
ACTION_COUNT_SKIP=0
ACTION_COUNT_BLOCKED=0
ACTION_COUNT_PENDING=0
ACTION_COUNT_RESTORE_DONE=0
ACTION_COUNT_DELETE_DONE=0
ACTION_COUNT_SKIPPED_ALREADY=0
ACTION_COUNT_ITEMS=0

rollback_add_action_row() {
  local category="$1"
  local source="$2"
  local dest="$3"
  local original_status="$4"
  local action="$5"
  local outcome="$6"
  local note="$7"
  local backup_path="$8"

  ACTION_ROWS+=("$category"$'\t'"$source"$'\t'"$dest"$'\t'"$original_status"$'\t'"$action"$'\t'"$outcome"$'\t'"$note"$'\t'"$backup_path")
  ACTION_COUNT_ITEMS=$((ACTION_COUNT_ITEMS + 1))

  case "$action" in
    RESTORE) ACTION_COUNT_RESTORE=$((ACTION_COUNT_RESTORE + 1)) ;;
    DELETE) ACTION_COUNT_DELETE=$((ACTION_COUNT_DELETE + 1)) ;;
    SKIP) ACTION_COUNT_SKIP=$((ACTION_COUNT_SKIP + 1)) ;;
    BLOCK) ACTION_COUNT_BLOCKED=$((ACTION_COUNT_BLOCKED + 1)) ;;
    PENDING) ACTION_COUNT_PENDING=$((ACTION_COUNT_PENDING + 1)) ;;
  esac

  case "$outcome" in
    restored) ACTION_COUNT_RESTORE_DONE=$((ACTION_COUNT_RESTORE_DONE + 1)) ;;
    deleted) ACTION_COUNT_DELETE_DONE=$((ACTION_COUNT_DELETE_DONE + 1)) ;;
    already-restored|already-absent|skipped) ACTION_COUNT_SKIPPED_ALREADY=$((ACTION_COUNT_SKIPPED_ALREADY + 1)) ;;
  esac
}

plan_replace_action() {
  local category="$1"
  local source="$2"
  local dest="$3"
  local original_status="$4"
  local backup_path="$5"

  if [[ ! -f "$backup_path" ]]; then
    rollback_add_action_row "$category" "$source" "$dest" "$original_status" "BLOCK" "missing-backup" "缺少备份文件，拒绝回滚该项" "$backup_path"
    return 0
  fi

  if [[ -f "$dest" ]] && cmp -s "$backup_path" "$dest"; then
    rollback_add_action_row "$category" "$source" "$dest" "$original_status" "SKIP" "already-restored" "当前目标已与备份一致，无需重复恢复" "$backup_path"
    return 0
  fi

  if [[ -e "$dest" && ! -f "$dest" ]]; then
    rollback_add_action_row "$category" "$source" "$dest" "$original_status" "BLOCK" "dest-not-regular-file" "目标路径存在但不是普通文件，拒绝直接覆盖" "$backup_path"
    return 0
  fi

  if [[ "$EXECUTE" == "1" ]]; then
    mkdir -p "$(dirname "$dest")"
    cp -a "$backup_path" "$dest"
    rollback_add_action_row "$category" "$source" "$dest" "$original_status" "RESTORE" "restored" "已从备份恢复目标文件" "$backup_path"
  else
    rollback_add_action_row "$category" "$source" "$dest" "$original_status" "RESTORE" "planned" "将从备份恢复目标文件" "$backup_path"
  fi
}

plan_new_action() {
  local category="$1"
  local source="$2"
  local dest="$3"
  local original_status="$4"

  if [[ "$DELETE_NEW" != "1" ]]; then
    rollback_add_action_row "$category" "$source" "$dest" "$original_status" "PENDING" "keep-new" "NEW 类文件默认不删；如确认要删，请显式加 --delete-new" ""
    return 0
  fi

  if [[ ! -e "$dest" ]]; then
    rollback_add_action_row "$category" "$source" "$dest" "$original_status" "SKIP" "already-absent" "目标文件已不存在，无需删除" ""
    return 0
  fi

  if [[ ! -f "$dest" ]]; then
    rollback_add_action_row "$category" "$source" "$dest" "$original_status" "BLOCK" "dest-not-regular-file" "目标路径不是普通文件，拒绝删除" ""
    return 0
  fi

  if [[ ! -f "$source" ]]; then
    rollback_add_action_row "$category" "$source" "$dest" "$original_status" "BLOCK" "missing-source" "记录中的源文件已不存在，无法安全比对后删除" ""
    return 0
  fi

  if ! cmp -s "$source" "$dest"; then
    rollback_add_action_row "$category" "$source" "$dest" "$original_status" "BLOCK" "target-modified-since-apply" "当前目标文件已不再与原始部署源一致，拒绝删除" ""
    return 0
  fi

  if [[ "$EXECUTE" == "1" ]]; then
    rm -f "$dest"
    rollback_add_action_row "$category" "$source" "$dest" "$original_status" "DELETE" "deleted" "已删除本轮 apply 新建且未被改动的文件" ""
  else
    rollback_add_action_row "$category" "$source" "$dest" "$original_status" "DELETE" "planned" "将删除本轮 apply 新建且未被改动的文件" ""
  fi
}

while IFS=$'\t' read -r kind category source dest original_status note; do
  if [[ "$kind" != "ITEM" ]]; then
    continue
  fi

  backup_path=""
  if [[ -n "$dest" && "$dest" == /* ]]; then
    backup_path="$ROLLBACK_BACKUP_DIR/files/${dest#/}"
  fi

  case "$original_status" in
    REPLACE)
      plan_replace_action "$category" "$source" "$dest" "$original_status" "$backup_path"
      ;;
    NEW)
      plan_new_action "$category" "$source" "$dest" "$original_status"
      ;;
    SAME)
      rollback_add_action_row "$category" "$source" "$dest" "$original_status" "SKIP" "skipped" "该文件在原始 apply 中即为 SAME，无需回滚" "$backup_path"
      ;;
    CONFLICT|TARGET-BLOCK|MISSING-SOURCE)
      rollback_add_action_row "$category" "$source" "$dest" "$original_status" "SKIP" "skipped" "该项在原始 apply 计划中属于阻断/未执行项，不做回滚动作" "$backup_path"
      ;;
    *)
      rollback_add_action_row "$category" "$source" "$dest" "$original_status" "BLOCK" "unknown-status" "遇到未知原始状态，拒绝继续处理该项" "$backup_path"
      ;;
  esac
done < "$PARSED_TSV"

ROLLBACK_FINAL_STATUS="ok"
ROLLBACK_NEXT_STEP="回滚计划可执行。执行后请手工运行 nginx -t 再决定是否 reload。"
if [[ "$ROLLBACK_SOURCE_MODE" != "execute" ]]; then
  ROLLBACK_FINAL_STATUS="blocked"
  ROLLBACK_NEXT_STEP="来源 APPLY-RESULT.json 不是 execute 模式；当前不建议把它当作真实回滚依据。"
elif [[ "$ACTION_COUNT_BLOCKED" -gt 0 ]]; then
  ROLLBACK_FINAL_STATUS="blocked"
  ROLLBACK_NEXT_STEP="存在被阻断的回滚项；请先人工检查缺失备份、被修改的新文件或异常目标路径。"
elif [[ "$ACTION_COUNT_PENDING" -gt 0 ]]; then
  ROLLBACK_FINAL_STATUS="needs-attention"
  ROLLBACK_NEXT_STEP="当前仍有 NEW 类文件未处理；如确认需要撤销这些新建文件，可在检查后加 --delete-new。"
fi

if [[ "$EXECUTE" == "1" && "$ROLLBACK_FINAL_STATUS" == "ok" ]]; then
  ROLLBACK_NEXT_STEP="回滚已执行完成。请先手工运行 nginx -t，确认恢复正常后再决定是否 reload。"
fi

json_bool() {
  if [[ "${1:-0}" == "1" ]]; then
    printf 'true'
  else
    printf 'false'
  fi
}

write_rollback_result_json() {
  local target_json="$1"
  mkdir -p "$(dirname "$target_json")"

  {
    echo '{'
    printf '  "schema_kind": %s,\n' "$(apply_plan_json_escape "rollback-result")"
    printf '  "schema_version": 1,\n'
    printf '  "mode": %s,\n' "$(apply_plan_json_escape "$MODE_LABEL")"
    printf '  "final_status": %s,\n' "$(apply_plan_json_escape "$ROLLBACK_FINAL_STATUS")"
    printf '  "source_apply_result": %s,\n' "$(apply_plan_json_escape "$RESULT_JSON")"
    printf '  "source_mode": %s,\n' "$(apply_plan_json_escape "$ROLLBACK_SOURCE_MODE")"
    printf '  "source_final_status": %s,\n' "$(apply_plan_json_escape "$ROLLBACK_SOURCE_FINAL_STATUS")"
    printf '  "platform": %s,\n' "$(apply_plan_json_escape "$ROLLBACK_PLATFORM")"
    printf '  "backup_dir": %s,\n' "$(apply_plan_json_escape "$ROLLBACK_BACKUP_DIR")"
    echo '  "flags": {'
    printf '    "delete_new": %s,\n' "$(json_bool "$DELETE_NEW")"
    printf '    "execute": %s\n' "$(json_bool "$EXECUTE")"
    echo '  },'
    echo '  "source_summary": {'
    printf '    "new": %s,\n' "$SOURCE_SUMMARY_NEW"
    printf '    "replace": %s,\n' "$SOURCE_SUMMARY_REPLACE"
    printf '    "same": %s,\n' "$SOURCE_SUMMARY_SAME"
    printf '    "conflict": %s,\n' "$SOURCE_SUMMARY_CONFLICT"
    printf '    "target_block": %s,\n' "$SOURCE_SUMMARY_TARGET_BLOCK"
    printf '    "missing_source": %s\n' "$SOURCE_SUMMARY_MISSING_SOURCE"
    echo '  },'
    echo '  "summary": {'
    printf '    "restore": %s,\n' "$ACTION_COUNT_RESTORE"
    printf '    "delete": %s,\n' "$ACTION_COUNT_DELETE"
    printf '    "skip": %s,\n' "$ACTION_COUNT_SKIP"
    printf '    "blocked": %s,\n' "$ACTION_COUNT_BLOCKED"
    printf '    "pending": %s,\n' "$ACTION_COUNT_PENDING"
    printf '    "restored": %s,\n' "$ACTION_COUNT_RESTORE_DONE"
    printf '    "deleted": %s\n' "$ACTION_COUNT_DELETE_DONE"
    echo '  },'
    printf '  "next_step": %s,\n' "$(apply_plan_json_escape "$ROLLBACK_NEXT_STEP")"
    echo '  "items": ['

    local row_count="${#ACTION_ROWS[@]}"
    local idx=0
    local row category source dest original_status action outcome note backup_path
    for row in "${ACTION_ROWS[@]}"; do
      idx=$((idx + 1))
      IFS=$'\t' read -r category source dest original_status action outcome note backup_path <<< "$row"
      echo '    {'
      printf '      "category": %s,\n' "$(apply_plan_json_escape "$category")"
      printf '      "source": %s,\n' "$(apply_plan_json_escape "$source")"
      printf '      "dest": %s,\n' "$(apply_plan_json_escape "$dest")"
      printf '      "original_status": %s,\n' "$(apply_plan_json_escape "$original_status")"
      printf '      "action": %s,\n' "$(apply_plan_json_escape "$action")"
      printf '      "outcome": %s,\n' "$(apply_plan_json_escape "$outcome")"
      printf '      "note": %s,\n' "$(apply_plan_json_escape "$note")"
      printf '      "backup_path": %s\n' "$(apply_plan_json_escape "$backup_path")"
      if [[ "$idx" -lt "$row_count" ]]; then
        echo '    },'
      else
        echo '    }'
      fi
    done

    echo '  ]'
    echo '}'
  } > "$target_json"
}

write_rollback_result_markdown() {
  local target_file="$1"
  mkdir -p "$(dirname "$target_file")"

  cat > "$target_file" <<EOF
# ROLLBACK RESULT

## 执行概览

- 模式：$MODE_LABEL
- 状态：$ROLLBACK_FINAL_STATUS
- 来源 APPLY-RESULT.json：$RESULT_JSON
- 来源 apply 模式：$ROLLBACK_SOURCE_MODE
- 来源 apply 状态：$ROLLBACK_SOURCE_FINAL_STATUS
- 平台：$ROLLBACK_PLATFORM
- 备份目录：$ROLLBACK_BACKUP_DIR
- delete-new：$(if [[ "$DELETE_NEW" == "1" ]]; then echo "已启用"; else echo "未启用"; fi)
- nginx reload：未执行

## 回滚摘要

- RESTORE：$ACTION_COUNT_RESTORE
- DELETE：$ACTION_COUNT_DELETE
- SKIP：$ACTION_COUNT_SKIP
- BLOCKED：$ACTION_COUNT_BLOCKED
- PENDING：$ACTION_COUNT_PENDING
- 已恢复：$ACTION_COUNT_RESTORE_DONE
- 已删除：$ACTION_COUNT_DELETE_DONE

## 下一步建议

- $ROLLBACK_NEXT_STEP

## 风险边界

- 当前不会自动 reload nginx
- NEW 类文件默认不会删除，除非显式传入 --delete-new
- 即使传入 --delete-new，也只会删除当前仍与原始部署源一致的 NEW 文件
- 缺少备份或目标状态异常时，会拒绝继续处理对应项
EOF

  if [[ ${#ACTION_ROWS[@]} -gt 0 ]]; then
    {
      echo
      echo "## 明细"
      echo
      local row category source dest original_status action outcome note backup_path
      for row in "${ACTION_ROWS[@]}"; do
        IFS=$'\t' read -r category source dest original_status action outcome note backup_path <<< "$row"
        echo "- [$action/$outcome] $category: $dest"
        echo "  - 原始状态：$original_status"
        [[ -n "$source" ]] && echo "  - source：$source"
        [[ -n "$backup_path" ]] && echo "  - backup：$backup_path"
        [[ -n "$note" ]] && echo "  - $note"
      done
    } >> "$target_file"
  fi
}

write_rollback_result_markdown "$RESULT_FILE"
write_rollback_result_json "$RESULT_JSON_OUTPUT"

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
  state_record_companion_result "rollback" "$RESULT_FILE" "$RESULT_JSON_OUTPUT" "$ROLLBACK_FINAL_STATUS" "rollback result recorded"
fi

cat <<EOF
[rollback] 当前模式：$MODE_LABEL
[rollback] 来源 APPLY-RESULT.json：$RESULT_JSON
[rollback] 来源 apply 模式：$ROLLBACK_SOURCE_MODE
[rollback] 来源 apply 状态：$ROLLBACK_SOURCE_FINAL_STATUS
[rollback] 备份目录：$ROLLBACK_BACKUP_DIR
[rollback] delete-new：$DELETE_NEW
[rollback] 结果摘要文件：$RESULT_FILE
[rollback] 结果 JSON 文件：$RESULT_JSON_OUTPUT
[rollback] 计划摘要：RESTORE=$ACTION_COUNT_RESTORE DELETE=$ACTION_COUNT_DELETE SKIP=$ACTION_COUNT_SKIP BLOCKED=$ACTION_COUNT_BLOCKED PENDING=$ACTION_COUNT_PENDING
[rollback] 最终状态：$ROLLBACK_FINAL_STATUS
[rollback] 下一步：$ROLLBACK_NEXT_STEP
EOF

if [[ "$EXECUTE" == "1" && "$ROLLBACK_FINAL_STATUS" == "blocked" ]]; then
  exit 6
fi
