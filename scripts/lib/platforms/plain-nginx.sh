#!/usr/bin/env bash
set -euo pipefail

platform_explain_plain_nginx() {
  cat <<'EOF'
plain-nginx 平台说明：
- 适用于常规 nginx 部署
- 后续 apply 阶段通常落到 /etc/nginx/conf.d 或 sites-enabled 风格目录
- 当前 installer 已支持 dry-run / print-plan，以及显式确认后的保守式 real apply
EOF
}

platform_plan_plain_nginx() {
  cat <<EOF
平台计划（plain-nginx）：
- 目标 snippets 提示路径：${NGINX_SNIPPETS_TARGET_HINT}
- 目标 vhost 提示路径：${NGINX_VHOST_TARGET_HINT}
- 后续 apply 可接入 nginx -t / reload
EOF
}

platform_apply_plan_plain_nginx() {
  local from_path="$1"
  cat <<EOF
平台 apply 计划（plain-nginx）：
- 源部署包：${from_path}
- 建议先备份 ${NGINX_SNIPPETS_TARGET_HINT} 与 ${NGINX_VHOST_TARGET_HINT} 中现有同名文件
- 建议复制 snippets/*.conf → ${NGINX_SNIPPETS_TARGET_HINT}/
- 建议复制 conf.d/*.conf → ${NGINX_VHOST_TARGET_HINT}/
- 建议复制 html/errors/* → ${ERROR_ROOT}/
- 建议完成后执行：nginx -t
- 若测试通过，再人工执行：nginx -s reload
EOF
}
