#!/usr/bin/env bash
set -euo pipefail

platform_explain_bt_panel_nginx() {
  cat <<'EOF'
bt-panel-nginx 平台说明：
- 适用于宝塔面板管理的 nginx 环境
- 常见目录包括 /www/server/panel/vhost/nginx 与 /www/server/nginx/snippets
- 当前骨架阶段仅输出计划，不执行真实写入
EOF
}

platform_plan_bt_panel_nginx() {
  cat <<EOF
平台计划（bt-panel-nginx）：
- 目标 snippets 提示路径：${NGINX_SNIPPETS_TARGET_HINT}
- 目标 vhost 提示路径：${NGINX_VHOST_TARGET_HINT}
- 后续 apply 需先做备份，再做 nginx -t / reload
EOF
}

platform_apply_plan_bt_panel_nginx() {
  local from_path="$1"
  cat <<EOF
平台 apply 计划（bt-panel-nginx）：
- 源部署包：${from_path}
- 建议先备份 ${NGINX_SNIPPETS_TARGET_HINT} 与 ${NGINX_VHOST_TARGET_HINT} 中现有同名文件
- 建议复制 snippets/*.conf → ${NGINX_SNIPPETS_TARGET_HINT}/
- 建议复制 conf.d/*.conf → ${NGINX_VHOST_TARGET_HINT}/
- 建议复制 html/errors/* → ${ERROR_ROOT}/
- 建议完成后执行：nginx -t
- 若测试通过，再通过宝塔或命令行 reload nginx
EOF
}
