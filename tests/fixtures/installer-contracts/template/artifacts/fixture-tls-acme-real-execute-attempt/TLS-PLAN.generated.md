# TLS PLAN

## 执行概览

- 状态：warn
- tls.mode：acme-http01
- deployment_name：fixture-tls-acme-real-execute-attempt
- base_domain：github.example.com
- domain.mode：flat-siblings
- deployment.platform：plain-nginx
- paths.output_dir：./dist/fixture-tls-acme-real-execute-attempt

## 模式说明

- 计划后续使用 ACME HTTP-01 申请证书。
- 本阶段不会执行 acme.sh / certbot / nginx 改写 / 证书申请。
- 仅生成预检结论与后续操作计划。

## 派生域名

- github.example.com
- raw.example.com
- gist.example.com
- assets.example.com
- archive.example.com
- download.example.com

## 当前阶段边界

- 不申请证书
- 不安装 acme.sh / certbot
- 不改动 Cloudflare DNS
- 不接管现网 nginx challenge 配置
- 若存在 BLOCK，generator 不会继续

## 后续建议

1. 先确保全部派生域名解析到当前机器。
2. 确认 80 端口可被 challenge 使用。
3. 后续单独实现显式 ACME issue 步骤，再接入 generator 之后的 apply。
