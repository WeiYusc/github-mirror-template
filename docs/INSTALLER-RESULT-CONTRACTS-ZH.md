# Installer Result Contracts（中文）

> 状态：实现对齐文档
> 适用分支：`weiyusc/exp/interactive-installer`
> 适用范围：`state.json`、`INSTALLER-SUMMARY.json`、`APPLY-PLAN.json`、`APPLY-RESULT.json`、`REPAIR-RESULT.json`、`ROLLBACK-RESULT.json`

---

## 1. 这份文档解决什么问题

`docs/INSTALLER-STATE-MODEL-ZH.md` 负责解释 **状态语义**。

这份文档只做另一件事：

> 把 installer 当前产出的 6 类 JSON 文件，按“职责 / 稳定字段 / 消费方 / 兼容策略”收成一份结果契约说明。

它不是 JSON Schema 标准文件，也不是 OpenAPI。

它回答的是更实际的问题：

- 哪个 JSON 文件该拿来做什么
- 哪些字段可以被后续逻辑稳定依赖
- 哪些字段更像实现细节，后续仍可能扩展
- `doctor` / `resume` 当前到底优先消费哪些结果

---

## 2. 当前涉及的 6 类 JSON 产物

### 2.1 主状态账本

- `state.json`

### 2.2 主流程摘要

- `INSTALLER-SUMMARY.json`

### 2.3 apply 规划

- `APPLY-PLAN.json`

### 2.4 apply 结果

- `APPLY-RESULT.json`

### 2.5 repair 结果

- `REPAIR-RESULT.json`

### 2.6 rollback 结果

- `ROLLBACK-RESULT.json`

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
- `APPLY-PLAN.json` → `apply-plan`
- `APPLY-RESULT.json` → `apply-result`
- `REPAIR-RESULT.json` → `repair-result`
- `ROLLBACK-RESULT.json` → `rollback-result`

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
3. `APPLY-RESULT.json`
4. `REPAIR-RESULT.json`
5. `ROLLBACK-RESULT.json`
6. `INSTALLER-SUMMARY.json`
7. `APPLY-PLAN.json`

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

所以当前结论很明确：

> `resume` 不是只看 `state.json`，而是已经把 companion result 视为正式输入的一部分。

### 4.3 `doctor` 当前的主消费面

`doctor` 当前会：

- 先看 `state.json`
- 再按 `artifacts` 指针找 `apply/repair/rollback` result
- 如果老 run 没登记 `repair_result_json` / `rollback_result_json`，会从 `apply_result_json` 同目录自动回退发现

这意味着：

> companion result 的“同目录约定名”当前也是兼容契约的一部分。

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
- 当前消费方会从 `apply_result_json` 同目录回退发现 companion result

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
- `summary_generated`
- `summary_output`
- `state_dir`
- `state_json`
- `journal_jsonl`
- `run_id`
- `apply_result_exists`
- `apply_result_json_exists`

### 6.3 当前主要消费方

- 人工排查
- `repair-applied-package.sh` / `rollback-applied-package.sh` 用它反查 `state_json`

### 6.4 兼容备注

- 它当前不承担 resume 策略决策核心输入
- 它更像 state/artifacts 的摘要镜像，而不是唯一真相源

---

## 7. `APPLY-PLAN.json`

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

## 8. `APPLY-RESULT.json`

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

---

## 9. `REPAIR-RESULT.json`

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

### 9.4 兼容备注

- `items[*]` 更偏诊断细节，可继续扩展
- `planned_action / planned_outcome` 已经开始带有半结构化语义，后续适合继续在这里增强，而不是把规则埋回文案

---

## 10. `ROLLBACK-RESULT.json`

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

### 10.4 兼容备注

- `items[*].action/outcome` 当前已经是最像正式 rollback 动作枚举的区域
- 如果后续要补 drift/reconcile，优先在 `items[*]` 继续扩展机器字段

---

## 11. 哪些字段现在不该被过度绑定

虽然这些 JSON 已经开始像正式契约，但当前仍有几类内容不建议当成强硬依赖：

### 11.1 人类说明文案

例如：

- `next_step` 的完整中文句子
- `note` 的完整中文句子
- `resume_strategy_reason` 的解释文案

这些内容适合展示，不适合做严格等值判断。

### 11.2 `items[*]` 的顺序

当前顺序来自扫描顺序，更多是实现产物，不宜默认当成严格语义。

### 11.3 Markdown 对应文件

- `APPLY-RESULT.md`
- `REPAIR-RESULT.md`
- `ROLLBACK-RESULT.md`

它们更偏人类阅读摘要，不应作为自动化主要输入。

---

## 12. 下一阶段最值得补强的地方

按当前实现边界，最值得继续推进的是：

1. 给这 6 类 JSON 产物补一份更明确的字段矩阵
2. 用 fixture/golden 把关键字段钉住
3. 明确哪些字段升级要 bump `schema_version`
4. 把 `doctor` / `resume` 对旧样本的 fallback 也纳入测试

---

## 13. 一句话结论

当前 installer 已经不只是“随手写几个 JSON”，而是已经长出了一个可继续收紧的结果契约层。

最核心的现实判断是：

> `state.json` 是主账本，`APPLY/REPAIR/ROLLBACK-RESULT.json` 是 companion contracts，而 `INSTALLER-SUMMARY.json` / `APPLY-PLAN.json` 更偏摘要与规划层。
