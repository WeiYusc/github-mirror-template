# PREFLIGHT REPORT

## 执行概览

- 状态：warn
- input_mode：advanced
- deployment_name：fixture-tls-acme-http01
- base_domain：github.example.com
- domain.mode：flat-siblings
- deployment.platform：plain-nginx
- paths.output_dir：./dist/fixture-tls-acme-http01
- WARN 数量：2
- BLOCK 数量：0

## Warnings

- tls.mode=acme-http01 当前仍是 Phase 1 scaffolding：只生成 TLS plan / preflight 结论，不会执行 ACME issue
- 当前未检测到 80 端口监听；后续若采用 standalone/webroot HTTP-01，请确认 challenge 路径可达

## Blockers

- 无
