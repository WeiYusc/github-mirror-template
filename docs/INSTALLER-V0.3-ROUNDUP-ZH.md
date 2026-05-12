# Interactive Installer v0.3 本轮收口说明（中文）

> 状态：实验分支阶段性收口说明
> 分支：`weiyusc/exp/interactive-installer`
> 对应提交：`f91d33e feat: complete installer safety and non-interactive flow`
> 时间：2026-04-18

---

# 1. 这份说明是干什么的

这份文档用于说明 `github-mirror-template` 在实验分支 `weiyusc/exp/interactive-installer` 上，围绕 **interactive installer / apply orchestration layer** 本轮到底完成了什么、边界是什么、验证做到哪一步，以及后续应如何理解当前停点。

它不是发布公告，也不是最终版本承诺；更像是一份：

- 阶段性正式变更说明
- 方便回看/转发的收口摘要
- 后续整理 PR 描述或 release 文案时可复用的底稿

---

# 2. 本轮最终结论

本轮 `v0.3` installer 实验已经从“骨架可跑”推进到：

> **具备基础/高级输入、只读 DNS/TLS 判断、文件级 apply 计划与备份、最小非交互调用能力，以及一轮完整安全路径实跑验证的保守式 installer/orchestration layer。**

换句话说，当前它已经不再只是演示骨架，而是一个：

- 可以收集部署输入
- 可以调用现有 generator 产出部署包
- 可以生成可审查的 apply 计划
- 可以在显式确认后执行保守式 real apply
- 可以在失败时给出更诚实的结果状态与人工接管提示

的实验性编排层。

但它仍然**不是**黑盒一键安装器。

---

# 3. 本轮主要新增/收口能力

## 3.1 输入契约收口：基础模式 / 高级模式

`install-interactive.sh` 本轮已从“首次运行就要求把全部路径一次填完”的形态，收口为更低摩擦的双模式输入：

- `basic`
- `advanced`

### basic 模式

优先只收集：

- `deployment_name`
- `base_domain`
- `domain_mode`
- `platform`
- `tls.cert`
- `tls.key`

随后按平台自动推导默认路径。

### advanced 模式

在需要时才覆盖：

- `error_root`
- `log_dir`
- `output_dir`
- `snippets_target`
- `vhost_target`

### 已固定的平台默认路径策略

#### `bt-panel-nginx`

- `DEFAULT_ERROR_ROOT="/www/wwwroot/github-mirror-errors"`
- `DEFAULT_LOG_DIR="/www/wwwlogs"`
- `DEFAULT_OUTPUT_DIR="./dist/${DEPLOYMENT_NAME}"`
- `DEFAULT_NGINX_SNIPPETS_TARGET_HINT="/www/server/nginx/snippets"`
- `DEFAULT_NGINX_VHOST_TARGET_HINT="/www/server/panel/vhost/nginx"`

#### `plain-nginx`

- `DEFAULT_ERROR_ROOT="/var/www/github-mirror-errors"`
- `DEFAULT_LOG_DIR="/var/log/nginx"`
- `DEFAULT_OUTPUT_DIR="./dist/${DEPLOYMENT_NAME}"`
- `DEFAULT_NGINX_SNIPPETS_TARGET_HINT="/etc/nginx/snippets"`
- `DEFAULT_NGINX_VHOST_TARGET_HINT="/etc/nginx/conf.d"`

此外，配置摘要中现在会明确显示当前是 `basic` 还是 `advanced`，不再让“路径来自默认推导还是人工覆盖”处于隐含状态。

---

## 3.2 DNS / TLS 从摘要升级为只读判断

本轮将 `scripts/lib/dns.sh` 与 `scripts/lib/tls.sh` 从“打印摘要”推进到“只读判断型检查”。

### DNS 方向

已支持：

- 按 domain mode 派生 6 个镜像域名
- 尝试通过 `getent` / `dig` / `nslookup` 做只读解析查询
- 输出 A/AAAA 结果或未解析状态

### TLS 方向

已支持：

- 证书文件存在性检查
- 私钥文件存在性检查
- 读取证书 Subject
- 读取 SAN 列表
- 读取到期时间与剩余天数
- 校验证书与私钥公钥指纹是否匹配

当前定位仍是：

> **先只读检查，再给判断；不自动改 DNS、不自动申请证书。**

---

## 3.3 apply 安全模型升级为文件级计划

`apply-generated-package.sh` 背后的核心 apply 内核已明显从“平铺 copy 候选”升级为**文件级计划模型**。

`scripts/lib/apply-plan.sh` 现在会对候选文件逐项分类：

- `NEW`
- `REPLACE`
- `SAME`
- `CONFLICT`
- `TARGET-BLOCK`
- `MISSING-SOURCE`

对应行为也更明确：

- `NEW / REPLACE`：进入复制路径
- `SAME`：跳过
- `CONFLICT / TARGET-BLOCK / MISSING-SOURCE`：阻断并要求人工处理

这使 apply 阶段从“目录级粗粒度动作”变成了：

> **逐文件、可解释、可复查的计划执行模型。**

---

## 3.4 备份模型升级为文件级备份

`scripts/lib/backup.sh` 本轮也不再是“整目标粗备份”，而是只针对 `REPLACE` 路径做备份，并把备份落到：

- `backup_dir/files/<原绝对路径>`

这种结构的好处是：

- 只备份真实会被覆盖的文件
- 回滚路径更清楚
- 不必为了一个小替换备份整个目录树

同时也修掉了一个真实小问题：

> 当一轮 apply 里全部是 `NEW`、没有 `REPLACE` 文件时，也会显式创建 backup 目录并给出说明，而不是让用户误以为“备份流程没跑”。

---

## 3.5 installer 支持最小非交互 / 半非交互入口

`install-interactive.sh` 本轮已补齐一套最小但实用的 flags 入口，并支持：

- 纯交互
- 半交互
- 全 flags 非交互

当前已支持的关键 flags 包括：

- `--deployment-name`
- `--base-domain`
- `--domain-mode`
- `--platform`
- `--tls-cert`
- `--tls-key`
- `--input-mode`
- `--error-root`
- `--log-dir`
- `--output-dir`
- `--snippets-target`
- `--vhost-target`
- `--run-apply-dry-run`
- `--execute-apply`
- `--backup-dir`
- `--run-nginx-test`
- `--nginx-test-cmd`
- `--yes`

已稳定下来的行为约定包括：

- flags 优先
- 缺失项再回退交互提问
- `--yes` 用于自动确认摘要
- 若传入路径类覆盖但未显式指定 `--input-mode`，会自动切到 `advanced`
- 若 `--execute-apply` 且未显式给 `--backup-dir`，会自动使用默认备份目录

这意味着当前 installer 已不再只能“人工一问一答”，而是可以被脚本化驱动。

---

## 3.6 failure-path / result summary 更诚实

本轮一个非常关键的收口，是把“失败时怎么说”这件事做得更诚实。

### 当前结果文件与终端摘要已能区分

- 正常完成
- `blocked`
- `needs-attention`

特别是 `nginx -t` 失败路径，现在会明确表达：

- 文件已落盘
- reload 未执行
- 未自动回滚
- 建议先参考备份目录回滚，再重新执行 `nginx -t`

这比“虽然失败了但摘要看起来像成功结束”要可靠得多，也更适合后续人工接手排错。

---

# 4. 本轮实际验证覆盖范围

这轮不是只改代码没验证，而是已经补了一轮成体系安全验证。

已覆盖的关键路径包括：

- `./install-interactive.sh --help`
- `basic` 模式 + `--run-apply-dry-run`
- 全 flags 非交互 `--execute-apply`
- `--run-nginx-test` 成功路径
- 故意构造的 `nginx test` 失败路径

本轮验证还明确检查过：

- 结果文件会真实落盘
- 失败路径状态会写成 `needs-attention`
- 不会在失败后自动 reload nginx
- 不会失败后悄悄自动回滚

这轮验证不是在真实 live nginx 目录直接乱写，而是优先使用安全测试目录做演练。

---

# 5. 本轮涉及的主要文件

本轮核心收口提交 `f91d33e` 的主要文件范围如下：

- `install-interactive.sh`
- `scripts/lib/apply-plan.sh`
- `scripts/lib/backup.sh`
- `scripts/lib/checks.sh`
- `scripts/lib/config.sh`
- `scripts/lib/dns.sh`
- `scripts/lib/tls.sh`
- `scripts/lib/platforms/plain-nginx.sh`
- `scripts/lib/platforms/bt-panel-nginx.sh`
- `README.md`
- `INSTALL.md`

按提交统计：

- 11 files changed
- 964 insertions
- 116 deletions

---

# 6. 本轮仍然刻意不做的事

需要再次强调：本轮能力增强，并不等于项目边界放开。

当前 installer 路线仍然明确**不会**自动做这些事：

- 不自动改 DNS
- 不自动申请证书
- 不自动 reload nginx
- 不做失败后自动回滚
- 不黑盒接管复杂 live nginx 配置

当前更准确的定位仍然是：

> **在现有 generator 之上增加一层“中文交互 + 只读检查 + apply 计划 + 保守式 real apply”的实验性 orchestration layer。**

而不是：

> 一键接管生产环境的全自动安装器。

---

# 7. 当前停点应该怎么理解

截至本轮收口，实验分支当前停点应理解为：

- `v0.2` generator 仍是稳定内核
- `v0.3` installer 已形成一条可运行、可验证、边界清晰的上层编排路径
- 当前分支已经完成本轮计划中的 5 个工作包
- 本轮核心收口提交已形成并已推送到远端实验分支

更简化地说：

> **这轮不是“还差最后一点点”的半成品了；它已经是一个有明确边界、可继续迭代的实验性 installer 基线。**

---

# 8. 后续若继续，最自然的方向

如果在这个停点上继续往前做，最自然的方向不再是“先补同类安全洞”，而更像是以下几类工作：

## 8.1 结构化输出继续收口

例如：

- 把更多结果整理为更稳定的结构化摘要
- 为未来 `--json` / CI 消费打基础
- 进一步统一终端输出与结果文件口径

## 8.2 文档/演练样例继续补齐

例如：

- 增加更多 plain-nginx / bt-panel-nginx 对照示例
- 增加更明确的失败后人工回滚说明
- 增加更贴近真实环境的非交互演练案例

## 8.3 只读检查继续增强

例如：

- 更细的证书覆盖判断
- 更明确的 DNS 未就绪提示
- 更结构化的 preflight 结论分类

但在当前阶段，仍不建议直接跨到：

- 自动改 DNS
- 自动申请证书
- 自动 reload nginx
- 黑盒复杂现网接管

---

# 9. 一句话总结

如果只用一句话概括本轮：

> `github-mirror-template` 的 `v0.3` experimental installer 已从“可演示骨架”推进到“具备保守式 real apply、只读 DNS/TLS 判断、文件级安全模型与完整安全路径验证的实验性编排基线”，但仍明确保持非黑盒、非自动接管的安全边界。
