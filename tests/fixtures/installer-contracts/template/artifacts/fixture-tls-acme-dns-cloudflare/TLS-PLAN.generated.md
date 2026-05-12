# TLS PLAN

## 执行概览

- 状态：warn
- tls.mode：acme-dns-cloudflare
- deployment_name：fixture-tls-acme-dns-cloudflare
- base_domain：github.example.com
- domain.mode：flat-siblings
- deployment.platform：plain-nginx
- paths.output_dir：./dist/fixture-tls-acme-dns-cloudflare

## 模式说明

- 计划后续使用 ACME DNS-01 + Cloudflare 申请证书。
- 本阶段不会调用 Cloudflare API，不会安装 acme.sh，不会申请证书。
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

1. 准备 Cloudflare zone / token / 最小权限策略。
2. 确认通配符 / 多 SAN 证书需求。
3. 后续单独实现显式 DNS-01 issue 步骤，再接入 generator 之后的 apply。
