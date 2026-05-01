# GitHub Mirror Template Pack

一个用于部署 **GitHub 公共只读镜像** 的 Nginx/宝塔模板包。

> 文档导航与权威层级：见 `docs/README.md`
> - 想快速部署：优先读 `README.md` + `INSTALL.md`
> - 想处理 installer 异常 run：优先读 runbook / state model / result contracts
> - 想继续开发 installer：优先读 roadmap / backlog / handoff

它的目标不是“克隆一个完整 GitHub”，而是提供一套 **可部署、可审计、可回滚** 的公共只读镜像方案，覆盖：

- 公共仓库页面浏览
- `raw` 文件访问
- `gist` 页面与 gist raw
- `archive` 源码包下载
- `release download` 下载链路
- GitHub 静态资源镜像

适用场景包括：

- 搭建公共只读镜像部署环境
- 在 Nginx / 宝塔环境中按模板落地多域镜像
- 基于现有配置骨架继续做审计、裁剪和二次改造

---

# Quick Start

如果你只想用最短路径确认这套模板怎么跑，直接这样：

```bash
cp deploy.example.yaml deploy.yaml
./generate-from-config.sh --config ./deploy.yaml
```

如果你只想临时改输出目录，不改 `deploy.yaml`，也可以：

```bash
./generate-from-config.sh --config ./deploy.yaml --output-dir ./dist/github-mirror-test
```

如果你只想先看派生域名和关键值，不生成部署包，可以：

```bash
./generate-from-config.sh --config ./deploy.yaml --print-derived
```

如果你想做一次生成前预演，但仍不写文件，可以：

```bash
./generate-from-config.sh --config ./deploy.yaml --dry-run
```

然后做 3 件事：

1. 检查生成出来的 `dist/<deployment-name>/`
2. 读一遍 `DEPLOY-STEPS.md` / `DNS-CHECKLIST.md`
3. 按 `INSTALL.md` / `BT-PANEL-DEPLOYMENT-v1.md` 做人工落地

> 说明：`generate-from-config.sh` 当前依赖 `python3` 和 Python `PyYAML`。

## 可选：实验性中文交互 installer

如果希望先用中文交互方式收集参数，再调用 generator，也可以试用当前实验性的 installer 编排入口：

```bash
./install-interactive.sh
```

如果希望**少交互或完全脚本化**，现在也可以直接传最小 flags：

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

它当前已经支持：

- 中文交互收集基础部署参数
- 也支持用 flags 直接覆盖常用输入
- 支持为每次 installer 运行生成 `run_id` 与运行状态目录（`scripts/generated/runs/<run_id>/`）
- 支持 `--doctor <run_id>` 查看某次运行的 state/journal/产物摘要
- `--doctor` 现在会额外输出一段 **lineage 摘要**，把这轮 run 是否来自历史 resume、源 run 停点、源 run 是否本身又来自更早 run、当前 resume strategy 与 strategy reason 用人话总结出来
- 支持 `--resume <run_id>` 复用上次输入，并在条件满足时跳过已完成的 preflight / generator / apply plan 阶段
- `--resume` 现在会优先按 **`lineage.resume_strategy` → `APPLY-RESULT.recovery.*` → `REPAIR/ROLLBACK-RESULT` 关键事实字段** 理解 run 级 `repair` / `rollback` 结果语义：若已执行 rollback，或 repair 的 nginx `-t` 重跑已通过 / 仍需人工处理，会默认收紧为“复查优先”，而不是继续把真实 apply 当默认下一步
- 在这些 inspection-first 的 resume 策略下，仍允许你显式传 `--run-apply-dry-run` 做只读预演；但若显式传 `--execute-apply`，installer 现在会直接拒绝，避免把“继续看看”误变成“继续落地改写”
- 基础 preflight 摘要
- 额外落盘 `scripts/generated/preflight.generated.md`
- 额外落盘 `scripts/generated/preflight.generated.json`
- 额外落盘 `scripts/generated/INSTALLER-SUMMARY.generated.json`
- 自动生成 deploy config 并调用 `generate-from-config.sh`
- 输出 `APPLY-PLAN.md`
- 输出 `APPLY-PLAN.json`
- 在部署输出目录额外落盘 `INSTALLER-SUMMARY.json`
- 可选执行一次 `apply-generated-package.sh --dry-run --print-plan`
- 在显式确认后执行保守式真实 apply
- 显式确认 `backup_dir`
- 可选执行 nginx 测试，并显式指定 `nginx-test-cmd`
- 写出 `APPLY-RESULT.md`
- 写出 `APPLY-RESULT.json`
- `--doctor` 会优先读取 `APPLY-RESULT.json`，并按 **`lineage.resume_strategy` → `APPLY-RESULT.recovery.*` → `REPAIR/ROLLBACK-RESULT` 关键字段 → `next_step`** 的顺序汇总 inspection-first 语义；若 `state.json` 中已登记 `REPAIR-RESULT.json` / `ROLLBACK-RESULT.json` 会优先直接消费，旧 run 尚未登记时也会退回到同目录自动发现

它当前明确**不会**自动做这些事：

- 不会自动改 DNS
- 不会自动 reload nginx
- 不会自动接管现有复杂站点
- 不会在未确认前直接改写目标目录
- 不会在 nginx 测试失败后自动回滚

更准确地说，这条 installer 路线的定位是：

> 在现有 generator 之上增加一层“中文交互 + 受控 apply”的实验性编排层，
> 而不是替代人工审查的一键黑盒安装器。

如果想先看脚本帮助：

```bash
./install-interactive.sh --help
./install-interactive.sh --doctor <run_id>
./install-interactive.sh --resume <run_id>
./apply-generated-package.sh --help
./rollback-applied-package.sh --help
./repair-applied-package.sh --help
```

另外，如果你需要针对异常状态做人工判断，当前最该看的三份是：

- `docs/INSTALLER-OPERATOR-RUNBOOK-ZH.md`：面向 `needs-attention` / `blocked` / `failed` / `cancelled` 的检查顺序、建议动作与禁止误操作说明
- `docs/INSTALLER-STATE-MODEL-ZH.md`：面向 `state.json` / `checkpoint` / `status.final` / `lineage` / `resume_strategy` / companion result 的实现语义说明
- `docs/INSTALLER-RESULT-CONTRACTS-ZH.md`：面向 `state.json` / `INSTALLER-SUMMARY.json` / `ISSUE-RESULT.json` / `APPLY-PLAN.json` / `APPLY-RESULT.json` / `REPAIR-RESULT.json` / `ROLLBACK-RESULT.json` 的职责边界、稳定字段与兼容策略说明

更完整的“从哪读起 / 哪份算权威 / 哪些只是历史材料”导航，见：`docs/README.md`

如果你准备修改 installer 的状态/结果契约，建议在提交前额外跑一次最小回归：

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

`installer-contracts-regression.sh` 当前主要覆盖：

- 6 类 JSON 的 `schema_kind` / `schema_version`
- `state_doctor()` / `state_load_resume_context()` 当前依赖的关键字段
- 旧 run companion result 未登记时的同目录 fallback
- inspection-first resume 语义（`inspect-after-apply-attention` / `repair-review-first` / `post-repair-verification` / `post-rollback-inspection`）

如果你动到了 `state_doctor()` 的摘要结构、策略优先级、下一步建议语义，建议再补跑：

```bash
bash tests/installer-doctor-golden.sh
```

它会对代表性 run 的 `doctor` 输出做**规范化 golden 回归**：

- 覆盖普通 / resumed / current run needs-attention / post-repair / post-rollback / ancestor 缺失来源样本
- 过滤临时目录路径噪音，仅保留关键摘要、优先产物、策略原因、结果 section 与下一步建议
- 允许非关键文案重排保留弹性，但会在核心诊断语义漂移时直接失败

其中 apply 阶段现在会同时产出：

- `APPLY-RESULT.md`：给人读的摘要
- `APPLY-RESULT.json`：给 `state.json` / `--doctor` / 后续 resume 策略消费的机器可读结果
- `INSTALLER-SUMMARY.json` / `state.json` 中的 `status.final` 现在会按整轮实际结果归一，可能是 `success` / `cancelled` / `blocked` / `failed` / `needs-attention`

`APPLY-RESULT.json` 当前会记录至少这些关键信息：

- `mode`：`dry-run` / `execute`
- `final_status`：如 `ok` / `blocked`
- `execution`：`backup_status` / `copy_status` / `reload_performed`
- `nginx_test.requested` 与 `nginx_test.status`
- `recovery`：`installer_status` / `resume_strategy` / `resume_recommended` / `operator_action`
- `summary`：`new` / `replace` / `same` / `conflict` / `target_block` / `missing_source`
- `targets`：snippets / vhost / error_root
- `next_step`：当前建议的下一步动作

另外，当前还新增了一个保守式 rollback helper：

- `./rollback-applied-package.sh --result-json <APPLY-RESULT.json>`：默认只做 dry-run，按 `backup_dir` 规划 selective rollback
- `REPLACE` 类文件优先从备份恢复
- `NEW` 类文件默认**不会删除**；只有显式传入 `--delete-new`，且当前目标仍与原始部署源一致时，才会纳入删除计划
- 当前同样**不会**自动 reload nginx
- 若来源 run 可定位到 `state.json`，rollback 结果还会自动回写到该 run 的 `artifacts` / `status.rollback`，供后续 `--doctor` 直接消费

另外，还补了一个更轻量的 repair helper：

- `./repair-applied-package.sh --result-json <APPLY-RESULT.json>`：默认只做 **post-apply 诊断**，不直接改写已部署文件
- 重点适用于 `needs-attention` 场景，帮助判断当前更适合 **selective rollback** 还是 **人工修复后重跑 nginx -t**
- `--execute` 当前也只会重跑 `nginx -t`（或你指定的 `--nginx-test-cmd`）并把结果落盘，不会自动 reload nginx
- 会输出 `REPAIR-RESULT.md` / `REPAIR-RESULT.json`
- 若来源 run 可定位到 `state.json`，repair 结果还会自动回写到该 run 的 `artifacts` / `status.repair`，供后续 `--doctor` 直接消费

另外，针对 `tls.mode=acme-http01` 的 run，当前还补了一个保守式 issue helper：

- `./acme-issue-http01.sh --state-json <state.json>`：默认只做 dry-run，只输出 HTTP-01 issue planning / evidence
- `--execute` 当前**不会**真实签发；它会把本次结果明确落成 `blocked`，并写出“execute path not implemented / 当前仅为占位语义”的稳定 blocker + next step，避免被误读为已经尝试签发
- 关键参数至少包括：
  - `--state-json <path>`
  - `--dry-run`
  - `--execute`
  - `--challenge-mode <standalone|webroot|file-plan>`
  - `--webroot <path>`
  - `--acme-client <acme.sh|certbot|manual>`
  - `--account-email <email>`
  - `--staging`
- 会输出 `ISSUE-RESULT.md` / `ISSUE-RESULT.json`
- 若来源 run 可定位到 `state.json`，helper 会把 `issue_result` / `issue_result_json` 回写到该 run 的 `artifacts`，并同步到 generated summary / output summary / `journal.jsonl`
- 当前 **不会** 真实签发证书、不会安装 acme client、不会改 live nginx、不会 reload nginx、不会写入证书文件
- 所以它当前的定位仍是 **planning / evidence helper**，不是完整 ACME lifecycle

另外，`--resume <run_id>` 现在有一个更保守的新约束：

- 如果源运行的 `APPLY-RESULT.json` 标记 `resume_recommended=false`
- 那么 resume 仍会复用输入和已完成产物
- 但**不会默认继承上次的真实 apply / nginx test 执行意图**
- 默认会收紧为“检查/提示优先”，避免在 `needs-attention` 场景下把 resume 当成重放 apply 的快捷键
- 同时如果该 run 已经有 `REPAIR-RESULT.json` / `ROLLBACK-RESULT.json`：
  - apply 已明确要求 operator 先复核，且 `resume_recommended != 1` 时，resume 会优先进入 **`inspect-after-apply-attention`** 语义
  - rollback 已执行成功时，resume 会优先进入 **`post-rollback-inspection`** 语义
  - repair 已把 `nginx -t` 重跑通过时，resume 会优先进入 **`post-repair-verification`** 语义
  - repair 仍是 `needs-attention` / `blocked` 时，resume 会优先进入 **`repair-review-first`** 语义
- 在这些 inspection-first 策略下：
  - 仍可显式带 `--run-apply-dry-run` 做只读预演
  - 但若显式带 `--execute-apply`，当前会直接拒绝，而不是默默降级或继续执行

这使得 `--doctor` 不再只凭 checkpoint 粗略判断，而能区分：

- dry-run 已成功，但尚未真实 apply
- 真实 apply 已执行，但尚未做 nginx 自检
- 真实 apply 已执行，但 nginx 测试失败，当前更适合先人工恢复而不是直接 resume
- 已经做过 repair，且 `nginx -t` 重跑通过 / 失败 / 尚未重跑
- 已经产出 rollback 计划，或 selective rollback 已实际执行
- apply 阶段被冲突、缺失源文件或目标阻断
- `--resume` 在 `needs-attention` 场景下默认只做保守续接，不把 apply 重放当默认动作
- 这轮 run 是否来自更早 run 的续接、源 run 停在何处、当前为何采用这条 resume strategy

- 调用底层渲染器生成 conf/snippets/errors
- 调用底层校验器做静态自检
- 额外生成中文版部署说明、DNS 检查清单、风险说明和摘要

它不会：

- 自动修改线上 Nginx
- 自动 reload
- 自动改 DNS
- 自动接管生产环境

如果你暂时还想直接使用底层渲染器，也可以继续走原来的 5 步：

1. 选定 `BASE_DOMAIN`、`DOMAIN_MODE` 与 `tls.mode`
2. 运行 `render-from-base-domain.sh` 渲染实际配置副本
3. 运行 `validate-rendered-config.sh` 做静态自检
4. 按 `INSTALL.md` / `BT-PANEL-DEPLOYMENT-v1.md` 落地到宝塔/Nginx
5. 用 `DEPLOY-CHECKLIST.md` 做上线前后验收

底层脚本示例：

```bash
./render-from-base-domain.sh \
  --base-domain github.example.com \
  --domain-mode flat-siblings \
  --tls-mode existing \
  --ssl-cert /path/to/fullchain.pem \
  --ssl-key /path/to/privkey.pem \
  --error-root /www/wwwroot/github-mirror-errors \
  --log-dir /www/wwwlogs \
  --output-dir ./rendered/github.example.com

./validate-rendered-config.sh \
  --rendered-dir ./rendered/github.example.com
```

> 说明：`render-from-base-domain.sh` 现在也接受 `--tls-mode <existing|acme-http01|acme-dns-cloudflare>`。
> 其中 `acme-http01` / `acme-dns-cloudflare` 当前仍属于 Phase 1 review-first scaffolding，主要用于对齐 renderer/generator/installer 的输入与产物契约，不代表已经自动签发证书。

详细步骤看：

- `INSTALL.md`
- `DEPLOY-CONFIG.md`
- `BT-PANEL-DEPLOYMENT-v1.md`
- `DEPLOY-CHECKLIST.md`
- `docs/README.md`

如果你正在用 experimental installer，再按需补读：

- `docs/INSTALLER-OPERATOR-RUNBOOK-ZH.md`
- `docs/INSTALLER-STATE-MODEL-ZH.md`
- `docs/INSTALLER-RESULT-CONTRACTS-ZH.md`

如果你是在继续改造 installer/control-plane，则优先看：

- `docs/INSTALLER-REFACTOR-ROADMAP-ZH.md`
- `docs/INSTALLER-NEXT-STAGE-BACKLOG-ZH.md`

---

# 1. 项目定位

这是一个 **GitHub 公共资源只读镜像模板**。

## 支持的能力

- 公共仓库主页、README、文件树、blob 页面只读浏览
- `raw.githubusercontent.com` 对应 raw 文件访问
- `gist.github.com` 与 gist raw 访问
- 源码归档下载（archive / codeload）
- release 下载链路代理
- GitHub 静态资源域镜像

## 明确不支持的能力

- 登录
- OAuth / 授权回调
- 私有仓库
- 任何账号态功能
- star / fork / watch / sponsor
- 新建 issue / PR / discussion
- push / 写入 / 上传
- PAT / token / SSH 凭据代理
- 账户设置、通知、dashboard

## 方法白名单

只允许：

- `GET`
- `HEAD`
- `OPTIONS`

其他方法统一拒绝。

---

# 2. 这不是啥

这不是：

- GitHub 完整替代站
- 登录后还能继续用的代理站
- 私有仓库访问网关
- 一键无脑安装器
- 官方支持的 GitHub 企业分发方案

如果你的目标是：

- 接管 GitHub 账号态功能
- 代理私有仓库
- 支持写操作
- 模拟完整用户会话

那这个项目就 **不适合**。

---

# 3. 当前目录结构

```text
github-mirror-template/
├── conf.d/
├── snippets/
├── html/errors/
├── README.md
├── INSTALL.md
├── OPERATIONS.md
├── FAQ.md
├── CHANGELOG.md
├── LICENSE
├── RELEASE-NOTES.md
├── BT-PANEL-DEPLOYMENT-v1.md
├── DEPLOY-CHECKLIST.md
├── DOMAIN-PLAN.md
├── TEMPLATE-VARIABLES.md
├── DEPLOY-CONFIG.md
├── REDIRECT-WHITELIST-DESIGN.md
├── REDIRECT-WHITELIST-CONFIG-SKETCH.md
├── deploy.example.yaml
├── V0.2-SIMPLIFIED-DEPLOYMENT-DESIGN.md
├── generate-from-config.sh
├── install-interactive.sh
├── apply-generated-package.sh
├── render-from-base-domain.sh
├── validate-rendered-config.sh
├── scripts/lib/
└── docs/
    ├── INSTALLER-DESIGN-ZH.md
    └── INSTALLER-MVP-PLAN-ZH.md
```

---

# 4. 域名模型

当前模板支持两种域名模式：

- `nested`
- `flat-siblings`

## 4.1 nested

示例：

- `BASE_DOMAIN=github.example.com`
- 派生：
  - `raw.github.example.com`
  - `gist.github.example.com`
  - `assets.github.example.com`
  - `archive.github.example.com`
  - `download.github.example.com`

## 4.2 flat-siblings

示例：

- `BASE_DOMAIN=github.example.com`
- 派生：
  - `github.example.com`
  - `raw.example.com`
  - `gist.example.com`
  - `assets.example.com`
  - `archive.example.com`
  - `download.example.com`

这个模式适合：

- 复用已有 `*.example.com` 通配符证书
- 避免再申请 `*.github.example.com` 这一层通配符
- 在宝塔中按 6 个兄弟子域独立建站

---

# 5. 模板包含的内容

模板包包含：

- hub/raw/gist/assets/archive/download 六类站点模板
- `render-from-base-domain.sh` 渲染脚本
- `validate-rendered-config.sh` 渲染结果静态自检脚本
- redirect whitelist 配置骨架
- 只读方法限制
- 高危/账号态路径拦截
- 两类自定义错误页：
  - 登录/授权已禁用
  - 只读镜像限制
- 宝塔/Nginx 手工部署文档
- 部署检查清单

---

# 6. 交付形态与使用方式

它目前的定位是：

> 一套以“手工审计部署”为主的模板包。

它还不是：

> 任意服务器上一条命令自动装完的成熟安装器。

上线前仍然需要人工确认：

- 证书路径
- 宝塔 vhost 目录布局
- snippets 最终 include 路径
- `http {}` 范围的 redirect whitelist map 接入
- DNS 解析
- `nginx -t` 检查
- 实站联调与抽样验收

---

# 7. 安全边界

这个项目的安全边界非常明确：

## 7.1 只读

- 非 `GET/HEAD/OPTIONS` 请求会被拒绝

## 7.2 账号态禁用

登录/账号/授权相关路径会进入单独提示页，例如：

- `/login`
- `/session`
- `/signup`
- `/settings/`
- `/account/`
- `/notifications`
- `/dashboard`

## 7.3 写操作禁用

只读镜像下不支持的交互路径会进入只读限制提示页，例如：

- `/fork`
- `/issues/new`
- `/pull/new`
- `/compare`
- `/releases/new`
- `/star`
- `/watching`
- `/sponsors`

## 7.4 不盲跟上游跳转

`archive` / `download` 下载链路必须通过 redirect whitelist 收口，不能无条件跟随任意上游 `Location`。

---

# 8. 最短使用路径

## 8.1 渲染模板

```bash
./render-from-base-domain.sh \
  --base-domain github.example.com \
  --domain-mode flat-siblings \
  --tls-mode existing \
  --ssl-cert /path/to/fullchain.pem \
  --ssl-key /path/to/privkey.pem \
  --error-root /www/wwwroot/github-mirror-errors \
  --log-dir /www/wwwlogs \
  --output-dir ./rendered/github.example.com
```

> 若改成 `--tls-mode acme-http01` 或 `--tls-mode acme-dns-cloudflare`，当前仍是 Phase 1 review-first scaffolding：可以生成对齐后的部署包与说明，但不代表会自动申请证书。

## 8.2 运行静态自检

```bash
./validate-rendered-config.sh \
  --rendered-dir ./rendered/github.example.com
```

## 8.3 按部署文档落地

优先阅读：

1. `INSTALL.md`
2. `BT-PANEL-DEPLOYMENT-v1.md`
3. `DEPLOY-CHECKLIST.md`
4. `OPERATIONS.md`
5. `FAQ.md`

---

# 9. 文档导航

## 快速了解

- `README.md`
- `DOMAIN-PLAN.md`
- `TEMPLATE-VARIABLES.md`

## 开始安装

- `INSTALL.md`
- `BT-PANEL-DEPLOYMENT-v1.md`
- `DEPLOY-CHECKLIST.md`
- `docs/INSTALLER-DESIGN-ZH.md`
- `docs/INSTALLER-MVP-PLAN-ZH.md`

## 理解下载链路收口

- `REDIRECT-WHITELIST-DESIGN.md`
- `REDIRECT-WHITELIST-CONFIG-SKETCH.md`

## 理解运维与回滚

- `OPERATIONS.md`
- `FAQ.md`

## 发布相关

- `CHANGELOG.md`
- `LICENSE`
- `RELEASE-NOTES.md`
- `PUBLIC-RELEASE-CHECKLIST.md`
- `REPO-METADATA-SUGGESTIONS.md`

---

# 10. 部署原则

部署时始终遵守：

1. 不覆盖现有站点 conf
2. 不修改现有业务域名逻辑
3. 所有镜像服务使用新域名增量接入
4. 先备份
5. 先写磁盘
6. 先 `nginx -t`
7. 通过后再 reload
8. 失败立即回滚新增配置

---

# 11. 推荐阅读顺序

如果你第一次接触这个项目，建议按顺序读：

1. `README.md`
2. `INSTALL.md`
3. `BT-PANEL-DEPLOYMENT-v1.md`
4. `DEPLOY-CHECKLIST.md`
5. `OPERATIONS.md`
6. `FAQ.md`
7. `RELEASE-NOTES.md`
8. `PUBLIC-RELEASE-CHECKLIST.md`


