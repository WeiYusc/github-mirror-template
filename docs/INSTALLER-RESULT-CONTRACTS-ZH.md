# Installer Result Contracts（中文）

> 状态：实现对齐文档
> 适用分支：`weiyusc/exp/interactive-installer`
> 适用范围：`state.json`、`INSTALLER-SUMMARY.json`、`ISSUE-RESULT.json`、`APPLY-PLAN.json`、`APPLY-RESULT.json`、`REPAIR-RESULT.json`、`ROLLBACK-RESULT.json`，以及 future real execute 预留的 `ACME-ISSUANCE-RESULT.json` 最小 skeleton

---

## 1. 这份文档解决什么问题

`docs/INSTALLER-STATE-MODEL-ZH.md` 负责解释 **状态语义**。

这份文档只做另一件事：

> 把 installer 当前产出的 7 类 JSON 文件，按“职责 / 稳定字段 / 消费方 / 兼容策略”收成一份结果契约说明。

它不是 JSON Schema 标准文件，也不是 OpenAPI。

它回答的是更实际的问题：

- 哪个 JSON 文件该拿来做什么
- 哪些字段可以被后续逻辑稳定依赖
- 哪些字段更像实现细节，后续仍可能扩展
- `doctor` / `resume` 当前到底优先消费哪些结果

---

## 2. 当前涉及的 7 类已产出 JSON 产物 + 1 个预留 execute skeleton

### 2.1 主状态账本

- `state.json`

### 2.2 主流程摘要

- `INSTALLER-SUMMARY.json`

### 2.3 issue 规划 / 证据结果

- `ISSUE-RESULT.json`

### 2.4 apply 规划

- `APPLY-PLAN.json`

### 2.5 apply 结果

- `APPLY-RESULT.json`

### 2.6 repair 结果

- `REPAIR-RESULT.json`

### 2.7 rollback 结果

- `ROLLBACK-RESULT.json`

### 2.8 future real execute 结果容器 skeleton

- `ACME-ISSUANCE-RESULT.json`（当前只定义最小 contract skeleton，不要求当前 helper 产出）

---

## 3. 顶层 schema 元信息

当前实现已为这些 JSON 增加统一的顶层元信息：

- `schema_kind`
- `schema_version`

当前约定：

- `schema_kind` 用来区分文件类型
- `schema_version` 当前固定为 `1`

当前对应关系：

- `state.json` → `installer-state`
- `INSTALLER-SUMMARY.json` → `installer-summary`
- `ISSUE-RESULT.json` → `issue-result`
- `APPLY-PLAN.json` → `apply-plan`
- `APPLY-RESULT.json` → `apply-result`
- `REPAIR-RESULT.json` → `repair-result`
- `ROLLBACK-RESULT.json` → `rollback-result`
- `ACME-ISSUANCE-RESULT.json` → `acme-issuance-result`（当前为 future execute 预留 skeleton kind）

### 3.1 兼容原则

当前建议按下面的兼容规则继续演进：

1. **优先追加字段，不轻易删字段**
2. 已存在字段如需改语义，应优先新增字段而不是静默改旧字段含义
3. 只有在“旧消费方无法安全理解新结构”时，才考虑提升 `schema_version`
4. `doctor` / `resume` 这类内部消费逻辑，应先保持对旧样本的宽容 fallback

---

## 4. 消费优先级总览

真实消费顺序不是所有 JSON 平级乱读，而是有主次的。

### 4.1 人工排查时

推荐顺序：

1. `./install-interactive.sh --doctor <run_id>`
2. `state.json`
3. `ISSUE-RESULT.json`（如果当前 run 做过 `acme-http01` issue helper）
4. `APPLY-RESULT.json`
5. `REPAIR-RESULT.json`
6. `ROLLBACK-RESULT.json`
7. `INSTALLER-SUMMARY.json`
8. `APPLY-PLAN.json`

### 4.2 `resume` 当前的主消费面

`state_load_resume_context()` 当前会直接读取：

- `state.json.status.*`
- `state.json.artifacts.*`
- `APPLY-RESULT.json.recovery.*`
- `APPLY-RESULT.json.next_step`
- `REPAIR-RESULT.json.final_status`
- `REPAIR-RESULT.json.execution.nginx_test_rerun_status`
- `REPAIR-RESULT.json.next_step`
- `ROLLBACK-RESULT.json.final_status`
- `ROLLBACK-RESULT.json.mode`
- `ROLLBACK-RESULT.json.flags.execute`
- `ROLLBACK-RESULT.json.next_step`

当前 `ISSUE-RESULT.json` **不会**驱动 `resume` 策略决策。它的职责更窄：

- 为 `tls.mode=acme-http01` 的 conservative helper 提供独立的 planning / evidence contract
- 把 HTTP-01 issue 尝试的模式、检查结果、阶段边界与 operator 下一步建议落成 companion result
- 让 `state.json` / `INSTALLER-SUMMARY.json` / `journal.jsonl` 能稳定回指这份结果

所以当前结论很明确：

> `resume` 不是只看 `state.json`，而是已经把 apply/repair/rollback companion result 视为正式输入的一部分；而 `ISSUE-RESULT.json` 当前主要服务于 operator review / contract 对齐，不代表已经接通真实 ACME lifecycle。

### 4.3 `doctor` 当前的主消费面

`doctor` 当前会：

- 先看 `state.json`
- 再按 `artifacts` 指针找 `apply/repair/rollback` result
- 如果老 run 没登记 `repair_result_json` / `rollback_result_json`，会从 `apply_result_json` 同目录自动回退发现
- 如果当前 run 已登记 `issue_result_json`，会把它作为补充 artifact 展示给 operator

这意味着：

> apply/repair/rollback companion result 的“同目录约定名”当前也是兼容契约的一部分；而 `ISSUE-RESULT.json` 目前更像 TLS issue helper 的 operator-facing companion artifact，不参与 resume strategy 推导。

### 4.4 inspection-first 策略的字段消费顺序

当 `resume` / `doctor` 面对 inspection-first 四类策略时，当前更可靠的消费顺序不是“只看某一个 final/status 字段”，而是：

1. 先看 **当前可解析到的 companion/apply 结果** 是否已经足以重新推导 effective strategy
   - `ROLLBACK-RESULT.json.mode=execute && final_status=ok` → `post-rollback-inspection`
   - `REPAIR-RESULT.json.execution.nginx_test_rerun_status=passed` → `post-repair-verification`
   - `REPAIR-RESULT.json.final_status in {needs-attention, blocked}` → `repair-review-first`
   - `APPLY-RESULT.json.recovery.resume_recommended=false` → `inspect-after-apply-attention`
2. 如果这些 direct truth-source 不足，再回退看 `state.json.lineage.resume_strategy`
3. 然后再看 `APPLY-RESULT.json.recovery.resume_strategy` / `resume_recommended` / `operator_action`
4. 若已有 repair 结果，则优先看 `REPAIR-RESULT.json.final_status` 与 `execution.nginx_test_rerun_status`
5. 若已有 rollback 结果，则优先看 `ROLLBACK-RESULT.json.final_status`、`mode`、`flags.execute`
6. 最后才把 `next_step` 当成人类说明补充，而不是唯一机器判定来源

也就是说：

> inspection-first 相关判断当前依赖的是 **lineage + recovery.* + companion result final/execution 字段** 的组合；其中当 `lineage.resume_strategy` 缺失、陈旧、或与 companion result 冲突时，`doctor` / `resume planner` 都应优先让当前结果文件重新推导出的 effective strategy 说了算。

这也是为什么当前 contract regression 更适合优先钉这些字段，而不会把完整中文提示句当成强契约。

一个容易误读、但当前实现已经明确的冲突例子是：

- 如果 `APPLY-RESULT.json.recovery.resume_recommended=false`，但同一个当前 run 的 `REPAIR-RESULT.json.final_status=needs-attention`，
- 那么 `doctor` / `resume planner` 都应把 **repair-review-first** 当成更强的 effective strategy，
- 而不是继续坚持 `inspect-after-apply-attention`。

换句话说，apply recovery 不是 inspection-first 家族里的“永久最高优先级”；它会被更晚、更贴近现场的 repair / rollback companion 结果覆盖。

---

## 5. `state.json`

### 5.1 职责

`state.json` 是 **主状态账本**，负责记录：

- 这轮 run 是谁
- 当前停在哪个 checkpoint
- 各阶段状态是什么
- 主要输入和产物路径是什么
- 是否来自 resume，以及 lineage 信息

### 5.2 当前应稳定依赖的字段

顶层：

- `schema_kind`
- `schema_version`
- `run_id`
- `state_dir`
- `updated_at`
- `checkpoint`
- `note`
- `resumed_from`

`lineage`：

- `mode`
- `source_run_id`
- `source_checkpoint`
- `source_resumed_from`
- `resume_strategy`
- `resume_strategy_reason`
- `is_resumed_run`

`status`：

- `preflight`
- `generator`
- `apply_plan`
- `apply_dry_run`
- `apply_execute`
- `repair`
- `rollback`
- `final`

`inputs`：

- `deployment_name`
- `base_domain`
- `domain_mode`
- `platform`
- `input_mode`
- `tls_cert`
- `tls_key`
- `error_root`
- `log_dir`
- `output_dir`
- `snippets_target`
- `vhost_target`

`flags`：

- `assume_yes`
- `run_apply_dry_run`
- `execute_apply`
- `run_nginx_test_after_execute`

`artifacts`：

- `config`
- `output_dir_abs`
- `preflight_markdown`
- `preflight_json`
- `apply_plan_markdown`
- `apply_plan_json`
- `apply_result`
- `apply_result_json`
- `issue_result`
- `issue_result_json`
- `repair_result`
- `repair_result_json`
- `rollback_result`
- `rollback_result_json`
- `summary_generated`
- `summary_output`
- `state_json`
- `inputs_env`
- `journal_jsonl`

### 5.3 当前更像实现细节的部分

以下字段虽然当前存在，但后续更适合视作“允许扩展”的区域：

- `note` 的具体文本口径
- `lineage.resume_strategy_reason` 的具体文案
- `artifacts` 中是否继续追加更多路径

### 5.4 兼容备注

- 对旧 run，`repair_result_json` / `rollback_result_json` 允许为空
- 对已经产出本地 companion result 的当前 / resumed run，`state.artifacts.repair_result_json` / `rollback_result_json` 应优先视为正式账本字段，而不是继续依赖空值回退
- 当前消费方会在旧 run 或兼容探针样本上，从 `apply_result_json` 同目录回退发现 companion result

---

## 6. `INSTALLER-SUMMARY.json`

### 6.1 职责

`INSTALLER-SUMMARY.json` 是 **主流程结束时的人机共用摘要**。

它不是完整状态账本，也不是 apply/repair/rollback 的细粒度结果。

它更适合回答：

- 这轮 installer 最终大体怎样
- 输出目录和核心产物在哪
- 这轮 flags 是什么

### 6.2 当前应稳定依赖的字段

顶层：

- `schema_kind`
- `schema_version`
- `deployment_name`
- `base_domain`
- `domain_mode`
- `platform`
- `input_mode`

`flags`：

- `assume_yes`
- `run_apply_dry_run`
- `execute_apply`
- `run_nginx_test_after_execute`

`status`：

- `preflight`
- `generator`
- `apply_plan`
- `apply_dry_run`
- `apply_execute`
- `final`
- `exit_code`

`artifacts`：

- `preflight_markdown`
- `preflight_json`
- `config`
- `output_dir`
- `apply_plan_markdown`
- `apply_plan_json`
- `apply_result`
- `apply_result_json`
- `issue_result`
- `issue_result_json`
- `summary_generated`
- `summary_output`
- `state_dir`
- `state_json`
- `journal_jsonl`
- `run_id`
- `apply_result_exists`
- `apply_result_json_exists`

其中：

- `config` 应稳定指向 **当前 run 的 deploy config 快照**（优先是 `scripts/generated/runs/<run_id>/deploy.generated.yaml`）
- `preflight_markdown` / `preflight_json` 应稳定指向 **当前 run 的 preflight 快照**（优先是 `scripts/generated/runs/<run_id>/preflight.generated.md|json`）
- `summary_generated` 应稳定指向 **当前 run 的 generated summary 快照**（优先是 `scripts/generated/runs/<run_id>/INSTALLER-SUMMARY.generated.json`）
- `summary_output` 是当前 output 目录下的 summary 镜像（通常为 `<output_dir>/INSTALLER-SUMMARY.json`）
- 共享 `scripts/generated/deploy.generated.yaml`、`scripts/generated/preflight.generated.*`、`scripts/generated/INSTALLER-SUMMARY.generated.json` 都只代表 latest 视图，可供人工快速查看最近一轮，但不应被当作历史 run 的唯一真相源

进一步说，`INSTALLER-SUMMARY.json.artifacts` 与 `state.json.artifacts` 在 path 语义上保持同一套分层：

1. **run-local snapshot**
   - `config`
   - `preflight_markdown`
   - `preflight_json`
   - `summary_generated`
   - `state_json`
   - `journal_jsonl`
   - `run_id`
2. **working/output mirror**
   - `output_dir`
   - `apply_plan_markdown`
   - `apply_plan_json`
   - `apply_result`
   - `apply_result_json`
   - `issue_result`
   - `issue_result_json`
   - `summary_output`

也就是说：

- 前一组字段应尽量稳定锚定到当前 run 自己的快照/账本
- 后一组字段表达的是“当前这轮实际接着看、接着写、接着消费的 output 结果位置”；在 resume 场景下允许继续沿用源 run 的 output 路径

### 6.2.1 `summary_output` 与 `summary_generated` 不要混用

这是最近最容易漂移的一对字段：

- `summary_generated`
  - 代表当前 run 的 generated summary 快照
  - 语义上更接近 run-scoped immutable snapshot
- `summary_output`
  - 代表当前工作 output 下的人机共用 summary
  - 语义上更接近 output mirror / latest-on-that-output

所以在 new / resume / inspection-first / review-first 场景里，都不要把两者混成“随便一个 summary 路径都行”。

### 6.2.2 与 journal path contract 的关系

如果 `journal.jsonl` 中出现：

- `run.complete`
  - path 应优先回指 `summary_output`
- `run.exit`
  - path 应回指 `state_json`
- `preflight.reused`
  - path 应回指当前 run 的 `preflight_json`
- `generator.reused`
  - path 应回指当前 run 的 `config`
- `apply-plan.reused`
  - path 应回指当前续接实际使用的 `apply_plan_json`

也就是说，summary/state/artifact 三层路径语义在当前 contract 中是互相咬合的，而不是各写各的。

### 6.3 当前主要消费方

- 人工排查
- `repair-applied-package.sh` / `rollback-applied-package.sh` 用它反查 `state_json`

### 6.4 兼容备注

- 它当前不承担 resume 策略决策核心输入
- 它更像 state/artifacts 的摘要镜像，而不是唯一真相源

---

## 7. `ISSUE-RESULT.json`

### 7.1 职责

`ISSUE-RESULT.json` 是 **`tls.mode=acme-http01` conservative issue helper 的 planning / evidence result**。

> 这份 contract 是刻意收窄的：**永远只承载 planning / evidence / conservative helper 语义，不升级成真实签发执行结果。**

它回答：

- 这次 helper 是以 `dry-run` 还是 `execute` 标记运行
- 当前派生域名、DNS 指向本机、80 端口、webroot 前提是否满足
- 当前打算采用什么 challenge 模式与 acme client
- 当前阶段边界是否仍停留在“只出计划、不真实签发”
- operator 下一步更像该补哪些前置条件，而不是把它误解成证书已签发
- 如果未来要接通真实签发，应该把执行结果分叉到独立 companion contract，而不是复用这份文件

### 7.2 当前应稳定依赖的字段

顶层：

- `schema_kind`
- `schema_version`
- `contract_scope`
- `reserved_execute_result.schema_kind`
- `reserved_execute_result.artifact_json`
- `reserved_execute_result.artifact_markdown`
- `reserved_execute_result.status`
- `mode`
- `final_status`
- `next_step`

`context`：

- `run_id`
- `deployment_name`
- `base_domain`
- `domain_mode`
- `platform`
- `tls_mode`

`request`：

- `challenge_mode`
- `webroot`
- `acme_client`
- `account_email`
- `staging`

`checks`：

- `derived_hosts`
- `dns_points_to_local_ready`
- `port_80_status`
- `port_80_ready`
- `needs_webroot`
- `webroot_ready`

`phase_boundary`：

- `issues_certificate`
- `installs_acme_client`
- `modifies_live_nginx`
- `reloads_nginx`
- `writes_tls_files`

另外还有：

- `blockers`

### 7.3 当前最关键的机器/操作语义

当前最该被读者抓住的不是 `execute` 这个词，而是 `phase_boundary.*` 这一组布尔字段，以及 contract 本身显式暴露的 fork 护栏：

- `contract_scope=planning-evidence-only`
- `reserved_execute_result.schema_kind=acme-issuance-result`
- `reserved_execute_result.artifact_json=ACME-ISSUANCE-RESULT.json`
- `reserved_execute_result.artifact_markdown=ACME-ISSUANCE-RESULT.md`
- `reserved_execute_result.status=reserved-not-implemented`
- `issues_certificate=false`
- `installs_acme_client=false`
- `modifies_live_nginx=false`
- `reloads_nginx=false`
- `writes_tls_files=false`

也就是说：

> `ISSUE-RESULT.json` 当前不是“签发成功记录”，而是“保守式 issue planning / evidence contract”；未来真实 execute 结果也**不得**继续复用它，而应独立落成 `ACME-ISSUANCE-RESULT.{md,json}` / `schema_kind=acme-issuance-result`。

即便 helper 以 `--execute` 运行，当前也不会真实签发；相反，它应稳定表现为：

- `final_status=blocked`
- `blockers[]` 含清晰的 execute 占位边界说明（例如 `execute path not implemented: 当前 --execute 仅为占位语义，不会真实签发证书`）
- `next_step` 明确指向“先设计/实现独立 execute 子路径，并把真实结果单独落成 `ACME-ISSUANCE-RESULT.{md,json}` companion contract”

这样做是为了让 operator / 自动化 / resume logic 不会把：

- `mode=execute`
- planning helper 的检查结果
- 未来真实 ACME issue 成败

混成同一个双义 artifact。

### 7.4 与 `state.json` / `INSTALLER-SUMMARY.json` / journal 的关系

当前 helper 落盘后会同步更新：

- `state.json.artifacts.issue_result`
- `state.json.artifacts.issue_result_json`
- `INSTALLER-SUMMARY.generated.json.artifacts.issue_result`
- `INSTALLER-SUMMARY.generated.json.artifacts.issue_result_json`
- `INSTALLER-SUMMARY.json.artifacts.issue_result`
- `INSTALLER-SUMMARY.json.artifacts.issue_result_json`
- `journal.jsonl` 中的 `issue.result.recorded`

因此当前 contract 边界是：

- `state.json` 负责把这份 issue result 记成 run 的正式 companion artifact 路径
- `INSTALLER-SUMMARY.json` 负责把它暴露给人机共用摘要视图
- `journal.jsonl` 负责记录“这份 companion result 何时被登记、路径指向哪里”
- `ISSUE-RESULT.json` 本身负责承载 helper 的 planning / evidence 语义

### 7.5 兼容备注

- 当前 `ISSUE-RESULT.json` 不参与 `resume` 的策略优先级判定
- 当前也不应该被外部自动化当成“证书已签发 / 可直接部署”的依据
- 为避免 operator / automation / resume logic 混淆“计划结果”和“真实签发结果”，未来真实 ACME execute / renew / deploy lifecycle **必须**走独立 companion contract：
  - `schema_kind=acme-issuance-result`
  - `ACME-ISSUANCE-RESULT.json`
  - `ACME-ISSUANCE-RESULT.md`
- 也就是说，后续若真正落地 execute：
  - 可以新增 state/summary artifact 指针
  - 可以新增 execute-specific 字段与结果状态
  - **但不能静默把 `ISSUE-RESULT.json` 扩成同时表示 planning + real issuance 的双义契约**

推荐这样分工：

- `ISSUE-RESULT.json`：前置条件、检查、challenge 方案、保守边界、operator review
- `ACME-ISSUANCE-RESULT.json`：真实签发尝试、challenge fulfillment、client execution、证书产物落盘、部署/回写边界、可恢复执行结果

### 7.6 `ACME-ISSUANCE-RESULT.json` 最小 contract skeleton（future real execute 预留）

> 这一节定义的是 **future real execute 的最小稳定骨架**，不是当前实现承诺。
> 当前 helper 不会产出它；这份 skeleton 的作用，是让后续真正实现 execute 子路径的人有一个可直接落地的结果容器下限。

### 7.6.1 职责边界

`ACME-ISSUANCE-RESULT.json` 只回答一类问题：

- 当真实 ACME execute 子路径被实现后，这次**真实签发尝试**做到了什么程度
- challenge 实际采用了什么 fulfillment 策略
- ACME client 是否真的执行过
- 是否产生了可供后续部署/引用的证书产物指针
- 当前停点更接近成功、部分完成、阻断、失败，还是需要人工接管
- 下一步应该继续签发恢复、人工修正 challenge，还是再进入部署/验证阶段

它**不负责**重复表达这些 planning 语义：

- 派生域名是否理论可行
- 当前 conservative helper 的 review 建议
- “当前 helper 不会真实签发”的阶段边界声明

这些继续留在 `ISSUE-RESULT.json`。

### 7.6.2 建议锁定的最小稳定字段

顶层：

- `schema_kind`
- `schema_version`
- `mode`
- `final_status`
- `next_step`

`context`：

- `run_id`
- `deployment_name`
- `base_domain`
- `domain_mode`
- `platform`
- `tls_mode`

`request`：

- `challenge_mode`
- `acme_client`
- `account_email`
- `staging`

`execution`：

- `attempted_hosts`
- `fulfilled_challenge_strategy`
- `client_invoked`
- `issued_certificate`

`artifacts`：

- `cert_path`
- `key_path`
- `fullchain_path`

`deployment_boundary`：

- `writes_live_tls_paths`
- `modifies_live_nginx`
- `reloads_nginx`

`recovery`：

- `recoverable`
- `blocker_summary`

### 7.6.3 字段设计意图（为什么只留这些）

这份 skeleton 刻意只保留长期稳定、且对 operator / automation / 后续 deploy helper 真有价值的骨架：

- `schema_kind/schema_version`：让未来 companion result 能独立演进
- `mode`：至少区分 `execute` 与未来可能存在的只读 replay / inspect 语义
- `final_status`：表达真实 execute 结果，而不是 planning helper 的 `blocked` 占位含义
- `execution.attempted_hosts`：钉住“这次到底尝试给哪些 host 做真实签发”
- `execution.fulfilled_challenge_strategy`：钉住真实 challenge fulfill 路径，而不是只停留在 plan
- `execution.client_invoked` / `issued_certificate`：用最小布尔边界区分“只是进入 execute 子路径”与“证书确实签出来了”
- `artifacts.*_path`：只定义为**结果指针位**，不要求当前已有文件，也不在本阶段假装 live artifact 已存在
- `deployment_boundary.*`：明确真实签发结果是否已经跨到 live TLS / live nginx / reload 边界，避免后续把 issuance 与 deploy 混成一个黑盒动作
- `recovery.*`：给 resume / doctor / operator 留下最小恢复语义，而不是只剩一段中文总结

### 7.6.4 推荐的最小 `final_status` 语义

这份 future skeleton 建议至少允许这些最小状态：

- `ok`
- `partial`
- `blocked`
- `failed`
- `needs-attention`

其中关键区别是：

- `ISSUE-RESULT.json.final_status` 当前是在 planning/evidence contract 里表达 review 结论或 execute 占位阻断
- `ACME-ISSUANCE-RESULT.json.final_status` 将来表达的是**真实 execute 现场结果**

所以即便两边都可能出现 `blocked` / `needs-attention`，语义源也不同，不能合并成同一份 artifact。

### 7.6.5 最小 skeleton 示例（仅示意 contract，不代表当前实现）

```json
{
  "schema_kind": "acme-issuance-result",
  "schema_version": 1,
  "mode": "execute",
  "final_status": "blocked",
  "context": {
    "run_id": "<run_id>",
    "deployment_name": "<deployment_name>",
    "base_domain": "<base_domain>",
    "domain_mode": "<domain_mode>",
    "platform": "<platform>",
    "tls_mode": "acme-http01"
  },
  "request": {
    "challenge_mode": "standalone",
    "acme_client": "acme.sh",
    "account_email": "ops@example.com",
    "staging": true
  },
  "execution": {
    "attempted_hosts": ["github.example.com"],
    "fulfilled_challenge_strategy": "standalone",
    "client_invoked": false,
    "issued_certificate": false
  },
  "artifacts": {
    "cert_path": "",
    "key_path": "",
    "fullchain_path": ""
  },
  "deployment_boundary": {
    "writes_live_tls_paths": false,
    "modifies_live_nginx": false,
    "reloads_nginx": false
  },
  "recovery": {
    "recoverable": true,
    "blocker_summary": "challenge fulfillment not completed"
  },
  "next_step": "补足 challenge fulfillment / client execute / artifact write 的真实子路径后，再决定是否进入部署阶段"
}
```

### 7.6.6 与 `ISSUE-RESULT.json` 的最小分工红线

最小红线只有三条，但都必须守住：

1. `ISSUE-RESULT.json` 继续只表示 planning / evidence / conservative boundary
2. `ACME-ISSUANCE-RESULT.json` 才表示真实 execute / challenge fulfillment / artifact outcome
3. 后续实现可以让两份结果互相引用，但**不能**把真实 execute 字段直接塞回 `ISSUE-RESULT.json`

只要这三条不倒退，后续就还能在 execute / renew / deploy 方向安全扩展，而不会把 operator 语义、自动化输入和恢复逻辑搅成一团。

---

## 8. `APPLY-PLAN.json`

### 7.1 职责

`APPLY-PLAN.json` 是 **apply 前的文件级计划**。

它回答：

- 源目录和目标目录分别是什么
- 本轮计划里有多少 `NEW / REPLACE / SAME / CONFLICT / TARGET-BLOCK / MISSING-SOURCE`
- 每一项准备怎么处理

### 7.2 当前应稳定依赖的字段

顶层：

- `schema_kind`
- `schema_version`
- `mode`
- `platform`

`summary`：

- `new`
- `replace`
- `same`
- `conflict`
- `target_block`
- `missing_source`
- `has_blockers`

`paths`：

- `from`
- `snippets_target`
- `vhost_target`
- `error_root`

`items[*]`：

- `category`
- `source`
- `dest`
- `status`
- `note`

### 7.3 当前主要消费方

- 人工审查部署计划
- `apply-generated-package.sh` 之前/之后的计划核对

### 7.4 兼容备注

- `items[*].note` 的文案不应被强绑定为严格机器契约
- 真正稳定的机器语义更应放在 `status` 与 `summary` 计数上

---

## 9. `APPLY-RESULT.json`

### 8.1 职责

`APPLY-RESULT.json` 是 **apply 阶段的正式结果文件**。

它既记录“这轮 apply 做没做、做到什么程度”，也提供后续恢复语义。

### 8.2 当前应稳定依赖的字段

顶层：

- `schema_kind`
- `schema_version`
- `mode`
- `platform`
- `final_status`
- `backup_dir`
- `next_step`

`execution`：

- `backup_status`
- `copy_status`
- `reload_performed`

`nginx_test`：

- `requested`
- `status`

`recovery`：

- `installer_status`
- `resume_strategy`
- `resume_recommended`
- `operator_action`

`targets`：

- `snippets`
- `vhost`
- `error_root`

`summary`：

- `new`
- `replace`
- `same`
- `conflict`
- `target_block`
- `missing_source`

`items[*]`：

- `category`
- `source`
- `dest`
- `status`
- `note`

### 8.3 当前最关键的机器契约

真正给 `resume` 吃的关键语义，不是 `final_status` 本身，而是：

- `recovery.installer_status`
- `recovery.resume_strategy`
- `recovery.resume_recommended`
- `recovery.operator_action`
- `next_step`

也就是说：

> `APPLY-RESULT.json` 当前不只是“执行记录”，还是恢复策略输入。

### 8.4 兼容备注

- `final_status` 和 `recovery.installer_status` 不是同一层语义，不能混用
- 后续如果要增强恢复语义，优先在 `recovery` 下追加字段

### 8.4.1 inspection-first 时先看哪些字段

若 `APPLY-RESULT.json` 把当前 run 引到 inspection-first 语义，当前最值得优先消费的是：

1. `recovery.resume_strategy`
2. `recovery.resume_recommended`
3. `recovery.operator_action`
4. `recovery.installer_status`
5. `next_step`

其中优先级含义是：

- `resume_strategy` 决定它属于哪一类 inspection-first 语义
- `resume_recommended` 决定是否应默认继续普通 resume
- `operator_action` 决定操作者当前更像该先 doctor / repair / rollback / 人工检查什么
- `installer_status` 反映 installer 视角下当前是否仍处于 attention / blocked
- `next_step` 更适合作为展示与人工提示，不宜单独当成机器判定来源

换句话说：

> 对 inspection-first 场景，`APPLY-RESULT.json` 里最关键的不是“最后一句怎么写”，而是 `recovery.*` 这组恢复语义字段。

### 8.4.2 与 repair / rollback companion 的衔接

一旦同目录或 `state.artifacts.*` 中已经存在 `REPAIR-RESULT.json` / `ROLLBACK-RESULT.json`，当前实现会把这些 companion result 视作比旧 `state.status.*` 更接近事实的补充语义来源：

- repair 已产出时，优先看 `REPAIR-RESULT.json.final_status` 与 `execution.nginx_test_rerun_status`
- rollback 已产出时，优先看 `ROLLBACK-RESULT.json.final_status`、`mode`、`flags.execute`

因此 inspection-first 的真实消费链条当前更接近：

> `lineage.resume_strategy` → `APPLY-RESULT.recovery.*` → `REPAIR/ROLLBACK-RESULT` 核心状态字段 → `next_step` 文案。

---

## 10. `REPAIR-RESULT.json`

### 9.1 职责

`REPAIR-RESULT.json` 是 **post-apply 诊断 / nginx 测试重跑结果**。

它当前不直接改写已部署文件，重点是告诉操作者：

- 当前现场更接近“可继续观察”还是“仍需 attention”
- nginx 测试重跑结果如何
- 下一步更像该 rollback 还是人工修

### 9.2 当前应稳定依赖的字段

顶层：

- `schema_kind`
- `schema_version`
- `mode`
- `final_status`
- `source_apply_result`
- `source_mode`
- `source_final_status`
- `platform`
- `backup_dir`
- `nginx_test_cmd`
- `next_step`

`source_recovery`：

- `installer_status`
- `resume_strategy`
- `resume_recommended`
- `operator_action`

`execution`：

- `source_backup_status`
- `source_copy_status`
- `source_reload_performed`
- `nginx_test_rerun_status`
- `nginx_test_rerun_exit_code`
- `nginx_test_rerun_output`

`source_summary`：

- `new`
- `replace`
- `same`
- `conflict`
- `target_block`
- `missing_source`

`diagnosis`：

- `items_total`
- `targets_present`
- `targets_missing`
- `targets_non_regular`
- `sources_missing`
- `replace_backups_present`
- `replace_backups_missing`

`items[*]`：

- `category`
- `source`
- `dest`
- `original_status`
- `target_kind`
- `source_kind`
- `backup_path`
- `backup_kind`
- `planned_action`
- `planned_outcome`
- `note`

### 9.3 当前最关键的机器契约

给 `resume` 最有价值的字段是：

- `final_status`
- `execution.nginx_test_rerun_status`
- `next_step`

在 inspection-first 语义里，当前可以更具体地理解为：

- `final_status` 用来判断 repair 是否仍处于 `needs-attention` / `blocked`
- `execution.nginx_test_rerun_status=passed` 是进入 `post-repair-verification` 的关键信号
- `next_step` 主要用于向操作者解释“现在更像该继续观察、人工复查、还是转 rollback”

也就是说：

> `REPAIR-RESULT.json` 对 inspection-first 的核心机器贡献，不是替代 apply result，而是把“repair 是否已把现场带到 verification 边界”这件事补实。

### 9.4 兼容备注

- `items[*]` 更偏诊断细节，可继续扩展
- `planned_action / planned_outcome` 已经开始带有半结构化语义，后续适合继续在这里增强，而不是把规则埋回文案

---

## 11. `ROLLBACK-RESULT.json`

### 10.1 职责

`ROLLBACK-RESULT.json` 是 **基于 APPLY-RESULT 和备份目录得出的 selective rollback 规划/执行结果**。

它回答：

- 这轮 rollback 是 dry-run 还是 execute
- 是否允许删除 NEW 文件
- 准备 restore / delete / skip / block 哪些项
- 执行后结果如何

### 10.2 当前应稳定依赖的字段

顶层：

- `schema_kind`
- `schema_version`
- `mode`
- `final_status`
- `source_apply_result`
- `source_mode`
- `source_final_status`
- `platform`
- `backup_dir`
- `next_step`

`flags`：

- `delete_new`
- `execute`

`source_summary`：

- `new`
- `replace`
- `same`
- `conflict`
- `target_block`
- `missing_source`

`summary`：

- `restore`
- `delete`
- `skip`
- `blocked`
- `pending`
- `restored`
- `deleted`

`items[*]`：

- `category`
- `source`
- `dest`
- `original_status`
- `action`
- `outcome`
- `note`
- `backup_path`

### 10.3 当前最关键的机器契约

给 `resume` 直接消费的核心字段是：

- `final_status`
- `mode`
- `flags.execute`
- `next_step`

在 inspection-first 语义里，当前可以更具体地理解为：

- `final_status=ok` 且 `flags.execute=true` 是进入 `post-rollback-inspection` 的关键事实来源
- `mode` 用来区分这只是 rollback 预演，还是已经真实执行过
- `next_step` 主要负责告诉操作者 rollback 后该先核对什么，而不是单独决定 resume 策略

也就是说：

> `ROLLBACK-RESULT.json` 的关键价值，是把“rollback 是否真的执行并成功”这件事从旧 `state.status.rollback` 的摘要，提升成可直接消费的 companion contract。

### 10.4 兼容备注

- `items[*].action/outcome` 当前已经是最像正式 rollback 动作枚举的区域
- 如果后续要补 drift/reconcile，优先在 `items[*]` 继续扩展机器字段

---

## 12. 哪些字段现在不该被过度绑定

虽然这些 JSON 已经开始像正式契约，但当前仍有几类内容不建议当成强硬依赖：

### 11.1 人类说明文案

例如：

- `next_step` 的完整中文句子
- `note` 的完整中文句子
- `resume_strategy_reason` 的解释文案

这些内容适合展示，不适合做严格等值判断。

### 11.2 `items[*]` 的顺序

当前顺序来自扫描顺序，更多是实现产物，不宜默认当成严格语义。

### 12.3 Markdown 对应文件

- `ISSUE-RESULT.md`
- `APPLY-RESULT.md`
- `REPAIR-RESULT.md`
- `ROLLBACK-RESULT.md`

它们更偏人类阅读摘要，不应作为自动化主要输入。

### 11.4 inspection-first 场景下不要过度绑定的内容

对 inspection-first 四类策略，当前尤其不要把下面这些内容当成唯一真相源：

- 只看 `state.status.final`
- 只看 `state.status.repair` / `state.status.rollback`
- 只看 `next_step` 的完整中文句子
- 只看某一个 Markdown 文件里的总结段落

更稳妥的契约理解应该是：

- 策略类别先看 `lineage.resume_strategy` / `APPLY-RESULT.recovery.resume_strategy`
- 是否建议普通 resume 先看 `recovery.resume_recommended`
- repair / rollback 是否已把现场推进到新边界，先看 companion result 的 `final_status` / execution 字段
- 中文说明文案主要用于展示和人工判断补充

---

## 13. 下一阶段最值得补强的地方

按当前实现边界，最值得继续推进的是：

1. 给这 7 类 JSON 产物补一份更明确的字段矩阵
2. 用 fixture/golden 把关键字段钉住
3. 明确哪些字段升级要 bump `schema_version`
4. 把 `doctor` / `resume` 对旧样本的 fallback 也纳入测试
5. 在真正接入 ACME execute 子路径前，先把 `ISSUE-RESULT` 与未来真实签发结果的边界钉死

---

## 14. 一句话结论

当前 installer 已经不只是“随手写几个 JSON”，而是已经长出了一个可继续收紧的结果契约层。

最核心的现实判断是：

> `state.json` 是主账本，`ISSUE/APPLY/REPAIR/ROLLBACK-RESULT.json` 是 companion contracts，而 `INSTALLER-SUMMARY.json` / `APPLY-PLAN.json` 更偏摘要与规划层。
