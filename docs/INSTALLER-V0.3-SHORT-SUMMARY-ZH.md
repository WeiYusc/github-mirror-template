# github-mirror-template installer v0.3 本轮收口摘要（可直接转发）

这轮 `weiyusc/exp/interactive-installer` 的核心结论可以概括为：

- 当前 experimental installer 已从“骨架可跑”推进到“可实际收集输入、调用 generator、输出 apply plan，并在显式确认后执行保守式 real apply”的阶段。
- 已补齐 `basic / advanced` 两级输入模型，并为 `bt-panel-nginx` / `plain-nginx` 固定平台默认路径。
- DNS / TLS 能力已从单纯摘要升级为只读判断：会检查域名解析、证书/私钥存在性、SAN、到期时间以及 cert/key 匹配性，但仍不自动改 DNS、不自动申请证书。
- apply 安全模型已升级为文件级计划与文件级备份：按 `NEW / REPLACE / SAME / CONFLICT / TARGET-BLOCK / MISSING-SOURCE` 分类执行，并对 `REPLACE` 文件做定点备份。
- installer 已支持最小非交互 / 半非交互调用，关键 flags 包括 `--deployment-name`、`--base-domain`、`--platform`、`--input-mode`、`--run-apply-dry-run`、`--execute-apply`、`--backup-dir`、`--run-nginx-test`、`--yes` 等。
- 失败路径表达已更诚实：`APPLY-RESULT.md` 与终端摘要会明确区分 `blocked`、`needs-attention`、正常完成，不再把失败看起来写得像成功。
- 已完成一轮成体系安全验证，覆盖 `--help`、basic dry-run、全 flags execute、nginx test 成功路径与故意构造的失败路径。

当前边界仍然明确保持不变：

- 不自动改 DNS
- 不自动申请证书
- 不自动 reload nginx
- 不在失败后自动回滚
- 不是黑盒一键安装器

更准确地说，当前这条 v0.3 路线应理解为：

> 在现有 v0.2 generator 之上，增加一层“中文交互 + 只读检查 + apply 计划 + 保守式 real apply”的实验性 orchestration layer，而不是推翻 generator 的 installer-first 重写。
