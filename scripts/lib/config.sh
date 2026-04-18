#!/usr/bin/env bash
set -euo pipefail

write_deploy_config() {
  local target_path="$1"

  cat > "$target_path" <<EOF
deployment_name: ${DEPLOYMENT_NAME}

domain:
  base_domain: ${BASE_DOMAIN}
  mode: ${DOMAIN_MODE}

tls:
  cert: ${TLS_CERT}
  key: ${TLS_KEY}

paths:
  error_root: ${ERROR_ROOT}
  log_dir: ${LOG_DIR}
  output_dir: ${OUTPUT_DIR}

nginx:
  snippets_target_hint: ${NGINX_SNIPPETS_TARGET_HINT}
  vhost_target_hint: ${NGINX_VHOST_TARGET_HINT}
  include_redirect_whitelist_map: true

deployment:
  platform: ${PLATFORM}
  dns_provider: manual
  review_before_apply: true
  generate_checklists: true

docs:
  language: zh-CN
  audience: operator
EOF
}

write_apply_plan_markdown() {
  local target_path="$1"
  local rendered_values_path="$2"
  local generated_config_path="$3"
  local output_dir_abs="$4"

  if [[ -f "$rendered_values_path" ]]; then
    # shellcheck disable=SC1090
    source "$rendered_values_path"
  fi

  cat > "$target_path" <<EOF
# APPLY PLAN（骨架阶段，仅计划）

## 1. 本次生成来源

- 生成配置：${generated_config_path}
- 部署名称：${DEPLOYMENT_NAME}
- 基础域名：${BASE_DOMAIN}
- 域名模型：${DOMAIN_MODE}
- 部署平台：${PLATFORM}
- 部署输出目录：${output_dir_abs}

## 2. 派生域名

- Hub：${HUB_URL:-https://${BASE_DOMAIN}}
- Raw：${RAW_URL:-}
- Gist：${GIST_URL:-}
- Assets：${ASSETS_URL:-}
- Archive：${ARCHIVE_URL:-}
- Download：${DOWNLOAD_URL:-}

## 3. 计划落地目标（当前仅提示，不执行）

- snippets/*.conf → ${NGINX_SNIPPETS_TARGET_HINT}/
- conf.d/*.conf → ${NGINX_VHOST_TARGET_HINT}/
- html/errors/* → ${ERROR_ROOT}/

## 4. 当前不会执行的动作

- 不会复制文件到线上目标目录
- 不会覆盖已有 nginx / 宝塔配置
- 不会执行 nginx -t
- 不会 reload nginx
- 不会修改 DNS

## 5. 建议人工检查顺序

1. 检查 RENDERED-VALUES.env 与 deploy.resolved.yaml
2. 检查 conf.d/ 与 snippets/ 是否符合目标平台目录结构
3. 检查错误页目录与证书路径是否真实存在
4. 再决定是否进入后续 apply 阶段

## 6. 参考命令

~~~bash
./apply-generated-package.sh \
  --from "${output_dir_abs}" \
  --platform "${PLATFORM}" \
  --snippets-target "${NGINX_SNIPPETS_TARGET_HINT}" \
  --vhost-target "${NGINX_VHOST_TARGET_HINT}" \
  --error-root "${ERROR_ROOT}"
~~~
EOF
}

print_config_summary() {
  cat <<EOF
- deployment_name: ${DEPLOYMENT_NAME}
- base_domain: ${BASE_DOMAIN}
- domain.mode: ${DOMAIN_MODE}
- tls.cert: ${TLS_CERT}
- tls.key: ${TLS_KEY}
- paths.error_root: ${ERROR_ROOT}
- paths.log_dir: ${LOG_DIR}
- paths.output_dir: ${OUTPUT_DIR}
- deployment.platform: ${PLATFORM}
- nginx.snippets_target_hint: ${NGINX_SNIPPETS_TARGET_HINT}
- nginx.vhost_target_hint: ${NGINX_VHOST_TARGET_HINT}
EOF
}
