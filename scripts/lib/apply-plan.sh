#!/usr/bin/env bash
set -euo pipefail

APPLY_PLAN_ROWS=()
APPLY_PLAN_COUNT_NEW=0
APPLY_PLAN_COUNT_REPLACE=0
APPLY_PLAN_COUNT_SAME=0
APPLY_PLAN_COUNT_CONFLICT=0
APPLY_PLAN_COUNT_TARGET_BLOCK=0
APPLY_PLAN_COUNT_MISSING_SOURCE=0

apply_plan_json_escape() {
  python3 - <<'PY' "$1"
import json
import sys
print(json.dumps(sys.argv[1], ensure_ascii=False))
PY
}

apply_plan_reset() {
  APPLY_PLAN_ROWS=()
  APPLY_PLAN_COUNT_NEW=0
  APPLY_PLAN_COUNT_REPLACE=0
  APPLY_PLAN_COUNT_SAME=0
  APPLY_PLAN_COUNT_CONFLICT=0
  APPLY_PLAN_COUNT_TARGET_BLOCK=0
  APPLY_PLAN_COUNT_MISSING_SOURCE=0
}

apply_plan_add_row() {
  local category="$1"
  local source="$2"
  local dest="$3"
  local status="$4"
  local note="${5:-}"

  APPLY_PLAN_ROWS+=("$category"$'\t'"$source"$'\t'"$dest"$'\t'"$status"$'\t'"$note")

  case "$status" in
    NEW) APPLY_PLAN_COUNT_NEW=$((APPLY_PLAN_COUNT_NEW + 1)) ;;
    REPLACE) APPLY_PLAN_COUNT_REPLACE=$((APPLY_PLAN_COUNT_REPLACE + 1)) ;;
    SAME) APPLY_PLAN_COUNT_SAME=$((APPLY_PLAN_COUNT_SAME + 1)) ;;
    CONFLICT) APPLY_PLAN_COUNT_CONFLICT=$((APPLY_PLAN_COUNT_CONFLICT + 1)) ;;
    TARGET-BLOCK) APPLY_PLAN_COUNT_TARGET_BLOCK=$((APPLY_PLAN_COUNT_TARGET_BLOCK + 1)) ;;
    MISSING-SOURCE) APPLY_PLAN_COUNT_MISSING_SOURCE=$((APPLY_PLAN_COUNT_MISSING_SOURCE + 1)) ;;
  esac
}

apply_plan_classify_item() {
  local source="$1"
  local dest="$2"

  if [[ -e "$dest" && ! -f "$dest" ]]; then
    printf 'CONFLICT\n'
    return 0
  fi

  if [[ ! -e "$dest" ]]; then
    printf 'NEW\n'
    return 0
  fi

  if cmp -s "$source" "$dest"; then
    printf 'SAME\n'
  else
    printf 'REPLACE\n'
  fi
}

apply_plan_scan_dir() {
  local category="$1"
  local source_dir="$2"
  local target_dir="$3"

  if [[ -e "$target_dir" && ! -d "$target_dir" ]]; then
    apply_plan_add_row "$category" "-" "$target_dir" "TARGET-BLOCK" "目标路径存在但不是目录"
    return 0
  fi

  if [[ ! -d "$source_dir" ]]; then
    apply_plan_add_row "$category" "$source_dir" "$target_dir" "MISSING-SOURCE" "部署包缺少该目录"
    return 0
  fi

  while IFS= read -r -d '' file; do
    local base dest status note
    base="$(basename "$file")"
    dest="$target_dir/$base"
    status="$(apply_plan_classify_item "$file" "$dest")"
    note=""
    case "$status" in
      NEW) note="目标文件不存在，将新建" ;;
      REPLACE) note="目标文件已存在，内容不同，将覆盖" ;;
      SAME) note="目标文件已存在且内容一致，可跳过" ;;
      CONFLICT) note="目标路径已存在但不是普通文件" ;;
    esac
    apply_plan_add_row "$category" "$file" "$dest" "$status" "$note"
  done < <(find "$source_dir" -maxdepth 1 -type f -print0 | sort -z)
}

build_apply_plan() {
  local from_path="$1"
  local snippets_target="$2"
  local vhost_target="$3"
  local error_root="$4"

  apply_plan_reset
  apply_plan_scan_dir "snippets" "$from_path/snippets" "$snippets_target"
  apply_plan_scan_dir "conf.d" "$from_path/conf.d" "$vhost_target"
  apply_plan_scan_dir "errors" "$from_path/html/errors" "$error_root"
}

apply_plan_has_blockers() {
  [[ $((APPLY_PLAN_COUNT_CONFLICT + APPLY_PLAN_COUNT_TARGET_BLOCK + APPLY_PLAN_COUNT_MISSING_SOURCE)) -gt 0 ]]
}

write_apply_plan_json() {
  local target_path="$1"
  local mode="$2"
  local platform="$3"
  local from_path="$4"
  local snippets_target="$5"
  local vhost_target="$6"
  local error_root="$7"

  mkdir -p "$(dirname "$target_path")"

  {
    echo '{'
    printf '  "schema_kind": %s,\n' "$(apply_plan_json_escape "apply-plan")"
    printf '  "schema_version": 1,\n'
    printf '  "mode": %s,\n' "$(apply_plan_json_escape "$mode")"
    printf '  "platform": %s,\n' "$(apply_plan_json_escape "$platform")"
    echo '  "summary": {'
    printf '    "new": %s,\n' "$APPLY_PLAN_COUNT_NEW"
    printf '    "replace": %s,\n' "$APPLY_PLAN_COUNT_REPLACE"
    printf '    "same": %s,\n' "$APPLY_PLAN_COUNT_SAME"
    printf '    "conflict": %s,\n' "$APPLY_PLAN_COUNT_CONFLICT"
    printf '    "target_block": %s,\n' "$APPLY_PLAN_COUNT_TARGET_BLOCK"
    printf '    "missing_source": %s,\n' "$APPLY_PLAN_COUNT_MISSING_SOURCE"
    printf '    "has_blockers": %s\n' "$(if apply_plan_has_blockers; then echo true; else echo false; fi)"
    echo '  },'
    echo '  "paths": {'
    printf '    "from": %s,\n' "$(apply_plan_json_escape "$from_path")"
    printf '    "snippets_target": %s,\n' "$(apply_plan_json_escape "$snippets_target")"
    printf '    "vhost_target": %s,\n' "$(apply_plan_json_escape "$vhost_target")"
    printf '    "error_root": %s\n' "$(apply_plan_json_escape "$error_root")"
    echo '  },'
    echo '  "items": ['

    local row_count="${#APPLY_PLAN_ROWS[@]}"
    local idx=0
    local row category source dest status note
    for row in "${APPLY_PLAN_ROWS[@]}"; do
      idx=$((idx + 1))
      IFS=$'\t' read -r category source dest status note <<< "$row"
      echo '    {'
      printf '      "category": %s,\n' "$(apply_plan_json_escape "$category")"
      printf '      "source": %s,\n' "$(apply_plan_json_escape "$source")"
      printf '      "dest": %s,\n' "$(apply_plan_json_escape "$dest")"
      printf '      "status": %s,\n' "$(apply_plan_json_escape "$status")"
      printf '      "note": %s\n' "$(apply_plan_json_escape "$note")"
      if [[ "$idx" -lt "$row_count" ]]; then
        echo '    },'
      else
        echo '    }'
      fi
    done

    echo '  ]'
    echo '}'
  } > "$target_path"
}

print_copy_candidates() {
  local from_path="$1"
  local snippets_target="$2"
  local vhost_target="$3"
  local error_root="$4"

  build_apply_plan "$from_path" "$snippets_target" "$vhost_target" "$error_root"

  echo "候选复制计划："
  echo "- NEW: $APPLY_PLAN_COUNT_NEW"
  echo "- REPLACE: $APPLY_PLAN_COUNT_REPLACE"
  echo "- SAME: $APPLY_PLAN_COUNT_SAME"
  echo "- CONFLICT: $APPLY_PLAN_COUNT_CONFLICT"
  echo

  local row category source dest status note
  for row in "${APPLY_PLAN_ROWS[@]}"; do
    IFS=$'\t' read -r category source dest status note <<< "$row"
    case "$status" in
      NEW|REPLACE|SAME|CONFLICT)
        echo "- [$status] $category: $source -> $dest"
        [[ -n "$note" ]] && echo "  - $note"
        ;;
      TARGET-BLOCK)
        echo "- [BLOCK] $category 目标根路径不可用: $dest"
        [[ -n "$note" ]] && echo "  - $note"
        ;;
      MISSING-SOURCE)
        echo "- [BLOCK] $category 缺少源目录: $source"
        [[ -n "$note" ]] && echo "  - $note"
        ;;
    esac
  done
}

validate_apply_inputs() {
  local from_path="$1"
  local snippets_target="$2"
  local vhost_target="$3"
  local error_root="$4"

  local blockers=0
  local warnings=0

  echo "[apply] 输入校验："

  if [[ ! -d "$from_path/conf.d" ]]; then
    echo "- [BLOCK] 缺少部署包目录：$from_path/conf.d" >&2
    blockers=$((blockers + 1))
  fi
  if [[ ! -d "$from_path/snippets" ]]; then
    echo "- [BLOCK] 缺少部署包目录：$from_path/snippets" >&2
    blockers=$((blockers + 1))
  fi
  if [[ ! -d "$from_path/html/errors" ]]; then
    echo "- [BLOCK] 缺少部署包目录：$from_path/html/errors" >&2
    blockers=$((blockers + 1))
  fi
  if [[ ! -f "$from_path/DEPLOY-STEPS.md" ]]; then
    echo "- [BLOCK] 缺少部署包说明：$from_path/DEPLOY-STEPS.md" >&2
    blockers=$((blockers + 1))
  fi

  if [[ "$snippets_target" != /* ]]; then
    echo "- [WARN] snippets 目标路径不是绝对路径：$snippets_target" >&2
    warnings=$((warnings + 1))
  fi
  if [[ "$vhost_target" != /* ]]; then
    echo "- [WARN] vhost 目标路径不是绝对路径：$vhost_target" >&2
    warnings=$((warnings + 1))
  fi
  if [[ "$error_root" != /* ]]; then
    echo "- [WARN] error_root 目标路径不是绝对路径：$error_root" >&2
    warnings=$((warnings + 1))
  fi

  build_apply_plan "$from_path" "$snippets_target" "$vhost_target" "$error_root"

  local row category source dest status note
  for row in "${APPLY_PLAN_ROWS[@]}"; do
    IFS=$'\t' read -r category source dest status note <<< "$row"
    case "$status" in
      CONFLICT)
        echo "- [BLOCK] $category 目标路径存在冲突：$dest" >&2
        [[ -n "$note" ]] && echo "  [detail] $note" >&2
        blockers=$((blockers + 1))
        ;;
      TARGET-BLOCK|MISSING-SOURCE)
        echo "- [BLOCK] $category: $note ($dest)" >&2
        blockers=$((blockers + 1))
        ;;
    esac
  done

  echo "- BLOCK: $blockers"
  echo "- WARN: $warnings"
  echo "- PLAN NEW: $APPLY_PLAN_COUNT_NEW"
  echo "- PLAN REPLACE: $APPLY_PLAN_COUNT_REPLACE"
  echo "- PLAN SAME: $APPLY_PLAN_COUNT_SAME"
  echo "- PLAN CONFLICT: $APPLY_PLAN_COUNT_CONFLICT"

  if [[ $blockers -ne 0 ]]; then
    echo "[apply] 结论：存在 BLOCK 项，当前不能继续执行 apply。" >&2
    return 1
  fi

  if [[ $warnings -gt 0 ]]; then
    echo "[apply] 结论：当前可继续，但建议先人工确认 WARN 项。"
  else
    echo "[apply] 结论：输入校验通过，可以继续。"
  fi
  return 0
}

run_apply_copy() {
  local from_path="$1"
  local snippets_target="$2"
  local vhost_target="$3"
  local error_root="$4"

  build_apply_plan "$from_path" "$snippets_target" "$vhost_target" "$error_root"

  echo "[apply] 开始执行真实复制（仍不 reload）。"

  local row category source dest status note
  for row in "${APPLY_PLAN_ROWS[@]}"; do
    IFS=$'\t' read -r category source dest status note <<< "$row"
    case "$status" in
      NEW|REPLACE)
        mkdir -p "$(dirname "$dest")"
        cp -a "$source" "$dest"
        echo "[apply] [$status] $source -> $dest"
        ;;
      SAME)
        echo "[apply] [SKIP] 内容一致，跳过：$dest"
        ;;
      CONFLICT|TARGET-BLOCK|MISSING-SOURCE)
        echo "[apply][error] 遇到未处理的阻断项：$status $dest" >&2
        return 1
        ;;
    esac
  done
}

print_rollback_guidance() {
  local backup_dir="$1"
  local snippets_target="$2"
  local vhost_target="$3"
  local error_root="$4"

  cat <<EOF
[apply] 回滚提示：
- 本次备份目录：$backup_dir
- 文件级备份根：$backup_dir/files
- 如需回滚，请从备份目录中按原绝对路径取回对应文件
- 例如 snippets 目标目录下的文件会备份到：$backup_dir/files/${snippets_target#/}/
- 例如 vhost 目标目录下的文件会备份到：$backup_dir/files/${vhost_target#/}/
- 例如错误页目标目录下的文件会备份到：$backup_dir/files/${error_root#/}/
- 回滚后请重新执行 nginx -t，确认配置恢复正常
EOF
}

print_execute_summary() {
  local backup_dir="$1"
  local run_nginx_test="$2"
  local nginx_test_status="$3"

  echo "[apply] 执行摘要："
  echo "- 模式：execute"
  echo "- 计划：NEW=$APPLY_PLAN_COUNT_NEW / REPLACE=$APPLY_PLAN_COUNT_REPLACE / SAME=$APPLY_PLAN_COUNT_SAME / CONFLICT=$APPLY_PLAN_COUNT_CONFLICT"
  echo "- 备份：已完成（文件级）"
  echo "- 复制：已完成"
  echo "- 备份目录：$backup_dir"
  if [[ "$run_nginx_test" == "1" ]]; then
    if [[ "$nginx_test_status" == "0" ]]; then
      echo "- nginx 测试：通过"
      echo "- reload：未执行（默认保守）"
      echo "- 结论：本次 apply 已完成，配置自检通过。"
      echo "- 下一步：如需继续，请人工确认后再决定是否 reload nginx"
    else
      echo "- nginx 测试：失败"
      echo "- reload：未执行"
      echo "- 结论：本次 apply 已落盘，但 nginx 自检未通过。"
      echo "- 下一步：建议先按回滚提示恢复，再重新执行 nginx -t"
    fi
  else
    echo "- nginx 测试：未执行"
    echo "- reload：未执行（默认保守）"
    echo "- 结论：本次 apply 已落盘，但尚未做 nginx 自检。"
    echo "- 下一步：如需继续，请手工执行 nginx -t"
  fi
}

write_apply_result_json() {
  local result_json="$1"
  local mode="$2"
  local platform="$3"
  local backup_dir="$4"
  local run_nginx_test="$5"
  local nginx_test_status="$6"
  local snippets_target="$7"
  local vhost_target="$8"
  local error_root="$9"
  local final_status="${10:-ok}"

  mkdir -p "$(dirname "$result_json")"

  local nginx_summary="not-run"
  local next_step="当前未进入真实执行。"
  local backup_status="not-started"
  local copy_status="not-started"
  local installer_status="success"
  local resume_strategy="plan-only"
  local resume_recommended="true"
  local operator_action="review-plan"

  if [[ "$final_status" == "blocked" ]]; then
    installer_status="blocked"
    resume_strategy="fix-blockers"
    operator_action="fix-blockers"
    next_step="请先处理冲突项、缺失目录或目标根路径问题，再重新执行 apply。"
  elif [[ "$mode" == "execute" ]]; then
    backup_status="completed"
    copy_status="completed"
    resume_recommended="false"
    if [[ "$run_nginx_test" == "1" && "$nginx_test_status" == "0" ]]; then
      nginx_summary="passed"
      installer_status="success"
      resume_strategy="post-apply-review"
      operator_action="manual-review"
      next_step="如需继续，请人工确认后再决定是否 reload nginx。"
    elif [[ "$run_nginx_test" == "1" && "$nginx_test_status" != "not-run" ]]; then
      nginx_summary="failed"
      installer_status="needs-attention"
      resume_strategy="manual-recovery-first"
      operator_action="rollback-or-fix"
      next_step="建议先按备份目录回滚或修复配置，再重新执行 nginx -t。"
    else
      installer_status="needs-attention"
      resume_strategy="run-nginx-test-first"
      operator_action="manual-nginx-test"
      next_step="已完成文件级备份与复制；请先手工执行 nginx -t，再决定是否继续。"
    fi
  elif [[ "$mode" == "dry-run" ]]; then
    installer_status="success"
    resume_strategy="dry-run-ok"
    operator_action="review-plan"
    next_step="当前未进入真实执行。"
  fi

  {
    echo '{'
    printf '  "schema_kind": %s,\n' "$(apply_plan_json_escape "apply-result")"
    printf '  "schema_version": 1,\n'
    printf '  "mode": %s,\n' "$(apply_plan_json_escape "$mode")"
    printf '  "platform": %s,\n' "$(apply_plan_json_escape "$platform")"
    printf '  "final_status": %s,\n' "$(apply_plan_json_escape "$final_status")"
    printf '  "backup_dir": %s,\n' "$(apply_plan_json_escape "$backup_dir")"
    printf '  "execution": {\n'
    printf '    "backup_status": %s,\n' "$(apply_plan_json_escape "$backup_status")"
    printf '    "copy_status": %s,\n' "$(apply_plan_json_escape "$copy_status")"
    printf '    "reload_performed": false\n'
    echo '  },'
    printf '  "nginx_test": {\n'
    printf '    "requested": %s,\n' "$(if [[ "$run_nginx_test" == "1" ]]; then echo true; else echo false; fi)"
    printf '    "status": %s\n' "$(apply_plan_json_escape "$nginx_summary")"
    echo '  },'
    printf '  "recovery": {\n'
    printf '    "installer_status": %s,\n' "$(apply_plan_json_escape "$installer_status")"
    printf '    "resume_strategy": %s,\n' "$(apply_plan_json_escape "$resume_strategy")"
    printf '    "resume_recommended": %s,\n' "$resume_recommended"
    printf '    "operator_action": %s\n' "$(apply_plan_json_escape "$operator_action")"
    echo '  },'
    echo '  "targets": {'
    printf '    "snippets": %s,\n' "$(apply_plan_json_escape "$snippets_target")"
    printf '    "vhost": %s,\n' "$(apply_plan_json_escape "$vhost_target")"
    printf '    "error_root": %s\n' "$(apply_plan_json_escape "$error_root")"
    echo '  },'
    echo '  "summary": {'
    printf '    "new": %s,\n' "$APPLY_PLAN_COUNT_NEW"
    printf '    "replace": %s,\n' "$APPLY_PLAN_COUNT_REPLACE"
    printf '    "same": %s,\n' "$APPLY_PLAN_COUNT_SAME"
    printf '    "conflict": %s,\n' "$APPLY_PLAN_COUNT_CONFLICT"
    printf '    "target_block": %s,\n' "$APPLY_PLAN_COUNT_TARGET_BLOCK"
    printf '    "missing_source": %s\n' "$APPLY_PLAN_COUNT_MISSING_SOURCE"
    echo '  },'
    printf '  "next_step": %s,\n' "$(apply_plan_json_escape "$next_step")"
    echo '  "items": ['

    local row_count="${#APPLY_PLAN_ROWS[@]}"
    local idx=0
    local row category source dest status note
    for row in "${APPLY_PLAN_ROWS[@]}"; do
      idx=$((idx + 1))
      IFS=$'\t' read -r category source dest status note <<< "$row"
      echo '    {'
      printf '      "category": %s,\n' "$(apply_plan_json_escape "$category")"
      printf '      "source": %s,\n' "$(apply_plan_json_escape "$source")"
      printf '      "dest": %s,\n' "$(apply_plan_json_escape "$dest")"
      printf '      "status": %s,\n' "$(apply_plan_json_escape "$status")"
      printf '      "note": %s\n' "$(apply_plan_json_escape "$note")"
      if [[ "$idx" -lt "$row_count" ]]; then
        echo '    },'
      else
        echo '    }'
      fi
    done

    echo '  ]'
    echo '}'
  } > "$result_json"
}

write_apply_result_markdown() {
  local result_file="$1"
  local mode="$2"
  local platform="$3"
  local backup_dir="$4"
  local run_nginx_test="$5"
  local nginx_test_status="$6"
  local snippets_target="$7"
  local vhost_target="$8"
  local error_root="$9"
  local final_status="${10:-ok}"

  mkdir -p "$(dirname "$result_file")"

  local nginx_summary="未执行"
  local next_step="当前未进入真实执行。"
  if [[ "$final_status" == "blocked" ]]; then
    next_step="请先处理冲突项、缺失目录或目标根路径问题，再重新执行 apply。"
  elif [[ "$run_nginx_test" == "1" && "$nginx_test_status" == "0" ]]; then
    nginx_summary="通过"
    next_step="如需继续，请人工确认后再决定是否 reload nginx。"
  elif [[ "$run_nginx_test" == "1" && "$nginx_test_status" != "not-run" ]]; then
    nginx_summary="失败"
    next_step="建议先按备份目录回滚，再重新执行 nginx -t。"
  elif [[ "$mode" == "execute" ]]; then
    next_step="已完成文件级备份与复制；如需继续，请手工执行 nginx -t。"
  fi

  cat > "$result_file" <<EOF
# APPLY RESULT

## 执行概览

- 模式：$mode
- 平台：$platform
- 状态：$final_status
- 备份目录：$backup_dir
- snippets 目标：$snippets_target
- vhost 目标：$vhost_target
- 错误页目标：$error_root
- nginx 测试：$nginx_summary
- reload：未执行
- 执行落盘：$(if [[ "$mode" == "execute" && "$final_status" != "blocked" ]]; then echo "已执行"; else echo "未执行"; fi)

## 变更计划摘要

- NEW：$APPLY_PLAN_COUNT_NEW
- REPLACE：$APPLY_PLAN_COUNT_REPLACE
- SAME：$APPLY_PLAN_COUNT_SAME
- CONFLICT：$APPLY_PLAN_COUNT_CONFLICT
- TARGET-BLOCK：$APPLY_PLAN_COUNT_TARGET_BLOCK
- MISSING-SOURCE：$APPLY_PLAN_COUNT_MISSING_SOURCE

## 风险边界

- 当前不会自动 reload nginx
- nginx 测试失败时不会自动回滚
- REPLACE 类文件会先做文件级备份
- SAME 类文件默认跳过，不重复覆盖
- 如需继续，应先人工确认目标目录与配置状态

## 下一步建议

- $next_step
EOF

  if [[ ${#APPLY_PLAN_ROWS[@]} -gt 0 ]]; then
    {
      echo
      echo "## 明细"
      echo
      local row category source dest status note
      for row in "${APPLY_PLAN_ROWS[@]}"; do
        IFS=$'\t' read -r category source dest status note <<< "$row"
        echo "- [$status] $category: $source -> $dest"
        [[ -n "$note" ]] && echo "  - $note"
      done
    } >> "$result_file"
  fi
}
