# INSTALL.md

> 文档导航与权威层级：见 `docs/README.md`
> - 第一次部署：优先按本文顺序读
> - 想处理 experimental installer 异常 run：优先补读 runbook / state model / result contracts
> - 想继续改 installer：优先补读 roadmap / backlog / handoff

这份文档面向：

- 第一次部署这套 GitHub 公共只读镜像的人
- 准备把模板仓库整理成可发布项目的人
- 需要按步骤落地、而不是只看原理说明的人

本文尽量用“从零到可验收”的顺序来写。

---

# 1. 你要先接受的边界

在继续之前，先确认你部署的是：

- GitHub **公共只读镜像**
- 不是完整 GitHub 替代品
- 不是登录代理
- 不是私有仓库网关

如果你的目标是登录、写入、私有仓库、账号态交互，这套东西不适合。

---

# 2. 依赖与环境要求

至少需要：

- Linux 服务器
- Nginx
- 域名 DNS 控制权
- 可用 TLS 证书
- 可修改 Nginx 配置并 reload 的权限
- `python3`（使用 v0.2 生成器时需要）
- Python `PyYAML`（使用 v0.2 生成器时需要）

推荐环境：

- 宝塔面板 + Nginx
- 有独立镜像域名
- 能复用通配符证书

---

# 3. 选择域名模式

模板支持两种：

- `nested`
- `flat-siblings`

## 推荐：flat-siblings

如果你已有类似 `*.example.com` 的通配符证书，推荐：

```text
BASE_DOMAIN=github.example.com
DOMAIN_MODE=flat-siblings
```

这样实际域名会是：

- `github.example.com`
- `raw.example.com`
- `gist.example.com`
- `assets.example.com`
- `archive.example.com`
- `download.example.com`

## 什么时候用 nested

如果你就是想把镜像整组收在同一主域下面，可以用：

```text
BASE_DOMAIN=github.example.com
DOMAIN_MODE=nested
```

派生为：

- `github.example.com`
- `raw.github.example.com`
- `gist.github.example.com`
- `assets.github.example.com`
- `archive.github.example.com`
- `download.github.example.com`

---

# 4. 准备证书与错误页目录

你需要提前确认：

- `SSL_CERT`
- `SSL_KEY`
- `ERROR_ROOT`
- `LOG_DIR`

例如：

```text
SSL_CERT=/etc/ssl/example/fullchain.pem
SSL_KEY=/etc/ssl/example/privkey.pem
ERROR_ROOT=/www/wwwroot/github-mirror-errors
LOG_DIR=/www/wwwlogs
```

---

# 5. 先选入口：generator / experimental installer / low-level renderer

当前这套仓库有 3 条入口，建议先按你的目标选路：

## 5.1 推荐默认：v0.2 声明式 generator

适合：

- 希望输入稳定、可复用、可版本化
- 希望先生成部署包，再人工审查
- 希望把配置保留在 `deploy.yaml` 中

推荐入口：

- `deploy.example.yaml`
- `DEPLOY-CONFIG.md`
- `generate-from-config.sh`

这是当前最稳的默认路径。

## 5.2 可选：v0.3 实验性中文交互 installer

适合：

- 想先用中文交互收集参数
- 想少手写 YAML
- 想在生成部署包之后，继续走一次受控 apply / dry-run / 最终确认流程
- 或希望通过最小 flags 做非交互 / 半非交互调用
- 或需要针对异常 run 做 `doctor / resume / repair / rollback` 一类恢复判断

入口：

- `install-interactive.sh`
- `apply-generated-package.sh`
- `repair-applied-package.sh`
- `rollback-applied-package.sh`
- `docs/INSTALLER-DESIGN-ZH.md`
- `docs/INSTALLER-MVP-PLAN-ZH.md`
- `docs/INSTALLER-OPERATOR-RUNBOOK-ZH.md`
- `docs/INSTALLER-STATE-MODEL-ZH.md`
- `docs/INSTALLER-RESULT-CONTRACTS-ZH.md`

这条路线当前定位是：

- 在现有 generator 之上增加“中文交互 + 受控 apply”的实验性编排层
- 不是替代人工审查的一键黑盒安装器
- 更像“把输入、产物、状态、恢复建议说清楚”的保守安装骨架

它当前已经支持：

- 中文交互收集参数
- 也支持用 flags 直接覆盖常用输入
- 为每次运行生成 `run_id` 与状态目录（`scripts/generated/runs/<run_id>/`）
- 支持 `--doctor <run_id>` 查看某次运行的 state / journal / 产物摘要
- `--doctor` 现在还会输出一段 **lineage 摘要**，说明当前 run 是否是 resumed run、源 run 停在哪个 checkpoint、源 run 是否还承接了更早 run、以及当前 resume strategy / reason
- 支持 `--resume <run_id>` 复用上次输入，并在条件满足时跳过已完成的 preflight / generator / apply plan 阶段
- preflight 摘要
- 额外落盘 `scripts/generated/preflight.generated.md`
- 额外落盘 `scripts/generated/preflight.generated.json`
- 额外落盘 `scripts/generated/INSTALLER-SUMMARY.generated.json`
- 调用 `generate-from-config.sh`
- 输出 `APPLY-PLAN.md`
- 输出 `APPLY-PLAN.json`
- 在部署输出目录额外落盘 `INSTALLER-SUMMARY.json`
- 可选执行 apply dry-run
- 显式确认后执行保守式真实 apply
- 显式设置 `backup_dir`
- 可选执行 nginx 测试，并显式设置 `nginx-test-cmd`
- 输出 `APPLY-RESULT.md`
- 输出 `APPLY-RESULT.json`
- 提供保守式 rollback helper：`./rollback-applied-package.sh --result-json <APPLY-RESULT.json>`
- 提供轻量 repair helper：`./repair-applied-package.sh --result-json <APPLY-RESULT.json>`

其中，当前恢复语义已经明确收紧为：

- `--doctor` 会优先读取 `APPLY-RESULT.json`
- 如果 `state.json` 已登记 `REPAIR-RESULT.json` / `ROLLBACK-RESULT.json`，`--doctor` 会优先直接消费；旧 run 未登记时，也会退回到同目录自动发现
- `--doctor` 会把当前 run 的 lineage 也纳入摘要：不只告诉你“现在状态是什么”，还会告诉你“这轮是从哪一轮续出来的、为什么走这条 resume strategy”
- `--resume` 会优先消费 run 级 `repair` / `rollback` 结果语义
- 若进入 inspection-first 的 resume 策略，启动提示与默认行为都会明确收紧为“优先复查可复用产物”，而不是把继续真实 apply 当默认动作
- 如果源运行的 `APPLY-RESULT.json` 已标记 `resume_recommended=false`，resume 默认不会继承上次的真实 apply / nginx test 执行意图
- 在这些 inspection-first 的 resume 策略下，仍允许显式传 `--run-apply-dry-run` 做只读预演；但若显式传 `--execute-apply`，当前会直接拒绝
- 目前常见的 inspection-first 语义包括：`inspect-after-apply-attention`、`post-repair-verification`、`repair-review-first`、`post-rollback-inspection`

### inspection-first / resume strategy 动作矩阵

| strategy | 典型来源 | 默认动作 | 是否允许 `--run-apply-dry-run` | 是否允许 `--execute-apply` | 预期当前 run-local artifacts | 可继续复用的 artifacts / 上下文 |
| --- | --- | --- | --- | --- | --- | --- |
| `inspect-after-apply-attention` | apply 已落到 attention，且 `resume_recommended != 1` | 进入 apply attention 复查；先看 `APPLY-RESULT.json` / `--doctor`，不把 `--resume` 当 execute 重放 | 允许 | 不允许 | `inputs.env`、run-local `deploy.generated.yaml`、run-local `preflight.generated.*`、run-local `INSTALLER-SUMMARY.generated.json` | `APPLY-RESULT.json`、`INSTALLER-SUMMARY.json`、必要时 `REPAIR-RESULT.json` / `ROLLBACK-RESULT.json` |
| `repair-review-first` | repair 结果仍是 `needs-attention` / `blocked` | 先复核 repair 诊断是否收口，再决定人工处理或新开 run | 允许 | 不允许 | `inputs.env`、run-local `deploy.generated.yaml`、run-local `preflight.generated.*`、run-local `INSTALLER-SUMMARY.generated.json` | `REPAIR-RESULT.json`、相关 `APPLY-RESULT.json`、必要时 rollback 结果 |
| `post-repair-verification` | repair 已重跑 `nginx -t` 且通过 | 先验证“修好后的现场”是否稳定，而不是继续 apply | 允许 | 不允许 | `inputs.env`、run-local `deploy.generated.yaml`、run-local `preflight.generated.*`、run-local `INSTALLER-SUMMARY.generated.json` | `REPAIR-RESULT.json`、相关 `APPLY-RESULT.json`、已有 output 内 plan/result |
| `post-rollback-inspection` | rollback 已执行且成功 | 先确认 rollback 后现场状态，再决定是否新开 run 或继续人工处理 | 允许 | 不允许 | `inputs.env`、run-local `deploy.generated.yaml`、run-local `preflight.generated.*`、run-local `INSTALLER-SUMMARY.generated.json` | `ROLLBACK-RESULT.json`、相关 `APPLY-RESULT.json`、必要时 repair 结果 |
| `reuse-apply-plan` | apply plan 已生成且 JSON 仍可复用 | 从 apply-plan 边界续接；默认仍可继续后续 dry-run / execute 决策 | 允许 | 允许 | `inputs.env`、run-local `deploy.generated.yaml`、run-local `preflight.generated.*`、run-local `INSTALLER-SUMMARY.generated.json` | 已存在的 `APPLY-PLAN.json`、共享 `output_dir`、后续新产出的 `APPLY-RESULT.json` |
| `reuse-generated-output` | generator 输出目录仍可复用 | 跳过 generator，重新生成/确认 apply plan 后继续 | 允许 | 允许 | `inputs.env`、run-local `deploy.generated.yaml`、run-local `preflight.generated.*`、run-local `INSTALLER-SUMMARY.generated.json` | 已存在 `output_dir_abs` 与其中渲染结果 |
| `reuse-preflight` | config + preflight 可复用 | 跳过输入/preflight，从 generator 之后继续 | 允许 | 允许 | `inputs.env`、run-local `deploy.generated.yaml`、run-local `preflight.generated.*`、run-local `INSTALLER-SUMMARY.generated.json` | 源 run 的可复用 config/preflight 上下文 |
| `re-enter-from-inputs` | 只有输入快照可复用 | 从输入边界重新进入，后续阶段按普通新 run 重新走 | 允许 | 允许 | `inputs.env`、后续新写出的 run-local config/preflight/generated summary | 历史 `inputs.env` |

读这张表时，建议把 artifact 分两层理解：

- **当前 run-local 必备快照**：`inputs.env`、run-local `deploy.generated.yaml`、run-local `preflight.generated.*`、run-local `INSTALLER-SUMMARY.generated.json`
- **可继续复用的工作结果**：`APPLY-PLAN.json`、`APPLY-RESULT.json`、`REPAIR-RESULT.json`、`ROLLBACK-RESULT.json`、`INSTALLER-SUMMARY.json`、共享 `output_dir_abs`

可以把 inspection-first 那 4 类再记成一句话：

> 先 doctor / 看 result / 做人工复查；可 dry-run，但不默认继续真实 apply。

一个最小脚本化示例：

```bash
./install-interactive.sh \
  --deployment-name github-mirror-prod \
  --base-domain github.example.com \
  --domain-mode flat-siblings \
  --platform bt-panel-nginx \
  --tls-cert /etc/ssl/example/fullchain.pem \
  --tls-key /etc/ssl/example/privkey.pem \
  --input-mode basic \
  --run-apply-dry-run \
  --yes
```

如果想先看帮助或检查某次异常 run，可以先用：

```bash
./install-interactive.sh --help
./install-interactive.sh --doctor <run_id>
./install-interactive.sh --resume <run_id>
./apply-generated-package.sh --help
./rollback-applied-package.sh --help
./repair-applied-package.sh --help
```

如果你准备修改 installer 的状态/结果契约，建议提交前顺手跑一次：

```bash
bash tests/installer-contracts-regression.sh
```

如果你动到了 summary/state/artifact snapshot 这类 control-plane 路径，建议再补一条：

```bash
bash tests/installer-summary-isolation.sh
```

它会专门钉住：

- 每轮 run 的 `summary_generated` 是否保持 run 级隔离
- `preflight.generated.{md,json}` / `deploy.generated.yaml` 是否落到各自 run 目录，而不是被相邻 run 污染
- `state.json.artifacts.*` 是否始终指向当前 run 自己的快照路径

这条轻量回归当前主要钉住：

- 6 类 JSON 的 `schema_kind` / `schema_version`
- `state_doctor()` / `state_load_resume_context()` 当前依赖的关键字段
- 旧 run companion result 未登记时的同目录 fallback
- inspection-first resume 语义（包括 `repair-review-first` / `post-rollback-inspection`）

它当前明确不会：

- 不会自动改 DNS
- 不会自动 reload nginx
- 不会自动接管复杂现网
- 不会在未确认前直接改写目标目录
- 不会在 nginx 测试失败后自动回滚
- 不会把 `needs-attention` 场景下的 `--resume` 当成重放 apply 的快捷键

如果你是第一次碰到异常 run，建议先看：

- `docs/INSTALLER-OPERATOR-RUNBOOK-ZH.md`
- `docs/INSTALLER-STATE-MODEL-ZH.md`
- `docs/INSTALLER-RESULT-CONTRACTS-ZH.md`

其中：

- runbook 负责回答“现在该怎么处理”
- state model 负责回答“这些 checkpoint / status.* / final / lineage / companion result 到底是什么意思”
- result contracts 负责回答“这些 JSON 产物分别该依赖什么字段、消费顺序是什么、兼容边界在哪里”

更完整的文档分层与阅读顺序，见：`docs/README.md`

这份手册专门覆盖 `needs-attention` / `blocked` / `failed` / `cancelled` 的检查顺序、建议动作与禁止误操作说明。

## 5.3 保留入口：low-level renderer

适合：

- 需要直接控制底层渲染参数
- 正在调模板
- 不想经过 YAML 或交互式 installer

入口：

- `render-from-base-domain.sh`
- `validate-rendered-config.sh`

---

# 6. 推荐入口：v0.2 声明式生成

如果你不想手工拼一长串参数，推荐优先使用：

- `deploy.example.yaml`
- `DEPLOY-CONFIG.md`
- `generate-from-config.sh`

## 6.1 最短路径

```bash
cp deploy.example.yaml deploy.yaml

./generate-from-config.sh --config ./deploy.yaml
```

> 说明：`generate-from-config.sh` 当前依赖 `python3` 和 Python `PyYAML`。

执行后会在 `dist/<deployment_name>/` 下生成：

- 渲染后的 `conf.d/`
- 渲染后的 `snippets/`
- `html/errors/`
- `RENDERED-VALUES.env`
- `deploy.resolved.yaml`
- `DEPLOY-STEPS.md`
- `DNS-CHECKLIST.md`
- `RISK-NOTES.md`
- `SUMMARY.md`

## 6.2 这一入口的边界

它会：

- 读取 YAML 配置
- 调用底层渲染器
- 调用底层静态校验器
- 生成中文部署说明文档

建议搭配阅读：

- `DEPLOY-CONFIG.md`
- `TEMPLATE-VARIABLES.md`

它不会：

- 自动改线上 Nginx 配置
- 自动 reload
- 自动改 DNS
- 自动上线

---

# 7. 底层渲染模板

如果你仍然想直接使用原始脚本，也可以继续走底层渲染路径。

示例：

```bash
./render-from-base-domain.sh \
  --base-domain github.example.com \
  --domain-mode flat-siblings \
  --ssl-cert /etc/ssl/example/fullchain.pem \
  --ssl-key /etc/ssl/example/privkey.pem \
  --error-root /www/wwwroot/github-mirror-errors \
  --log-dir /www/wwwlogs \
  --output-dir ./rendered/github.example.com
```

这个步骤只会：

- 生成渲染后的 conf/snippets/errors 文件
- 生成 `RENDERED-VALUES.env`

它不会：

- 修改目标环境中的 Nginx 配置
- 自动部署
- 自动 reload

---

# 8. 运行静态自检

```bash
./validate-rendered-config.sh \
  --rendered-dir ./rendered/github.example.com
```

检查点包括：

- 目录结构是否完整
- conf/snippet/error 文件是否齐全
- 是否残留未替换占位符
- `RENDERED-VALUES.env` 是否完整
- 关键域名是否已经落进对应 conf

---

# 9. DNS 解析

按你的域名模式，把以下域名都解析到目标服务器：

- hub
- raw
- gist
- assets
- archive
- download

如果是 `flat-siblings`，例如：

- `github.example.com`
- `raw.example.com`
- `gist.example.com`
- `assets.example.com`
- `archive.example.com`
- `download.example.com`

---

# 10. 在宝塔中建站

推荐做法：

- 为 6 个镜像域名分别建站
- 让宝塔先生成基础 vhost 与 SSL 绑定
- 再把模板逻辑接进去

这样做的好处是：

- 证书绑定更直观
- 站点拆分更清晰
- 回滚时影响面更小

---

# 11. 放置渲染结果

你通常需要做 3 类落地：

## 11.1 snippets

把渲染结果中的 `snippets/` 放到你的 Nginx snippets 目录。

## 11.2 errors

把 `html/errors/` 放到 `ERROR_ROOT`。

## 11.3 站点 conf

把 `conf.d/*.conf` 中的逻辑整理到你的宝塔 vhost 文件里。

> 注意：这里不是要求你机械覆盖，而是按目标环境路径修正 include 与日志位置后再落地。

---

# 12. redirect whitelist 接入

这是生产部署里最不能漏的一步。

你必须把：

- `snippets/http-redirect-whitelist-map.conf`

接入 Nginx 主配置的：

- `http {}` 作用域

不要把它 include 到 `server {}` 里。

否则 archive / download 的重定向收口会不对。

---

# 13. 上线前检查

在 reload 前至少确认：

- 没覆盖原有站点 conf
- 没改现有业务域名绑定
- 所有镜像域名都使用新增配置
- 错误页路径存在
- snippets include 路径真实有效
- redirect whitelist 已在 `http {}` 接入

---

# 14. Nginx 检查与重载

```bash
nginx -t
nginx -s reload
```

规则：

- `nginx -t` 不通过，绝不 reload
- 通过后再 reload
- reload 后立即做首轮验收

---

# 15. 首轮验收建议

至少测这些：

## 页面链路

- 仓库主页
- README
- 文件树
- blob 页面
- gist 页面

## 内容链路

- raw 文件
- archive 下载
- release download

## 安全边界

- `/login` 应进入登录禁用提示页
- `/settings/profile` 应进入登录禁用提示页或拒绝访问
- `/octocat/Hello-World/fork` 应进入只读限制提示页
- POST 请求应被拒绝

---

# 16. 回滚方法

如果本轮部署有问题：

1. 禁用新增镜像 vhost conf
2. 恢复被改过的 `nginx.conf` 或 include 配置
3. 再跑 `nginx -t`
4. 再 reload

目标是：

- 只回滚本次新增镜像配置
- 不碰原有业务站点

---

# 17. 你还应该继续看的文档

- `BT-PANEL-DEPLOYMENT-v1.md`：更偏宝塔落地
- `DEPLOY-CHECKLIST.md`：执行清单
- `OPERATIONS.md`：运维、升级、排障、回滚
- `FAQ.md`：限制与常见问题
