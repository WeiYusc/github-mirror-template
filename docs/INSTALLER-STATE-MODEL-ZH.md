# Installer State Model（中文）

> 状态：实现对齐文档
> 适用分支：`weiyusc/exp/interactive-installer`
> 适用范围：`install-interactive.sh`、`scripts/lib/state.sh`、`apply-generated-package.sh`、`repair-applied-package.sh`、`rollback-applied-package.sh`

---

## 1. 这份文档解决什么问题

这不是“怎么部署”的说明，也不是“异常时怎么处理”的 runbook。

它只回答一件事：

> installer 当前到底把 **run / checkpoint / status / final / lineage / companion result** 定义成了什么。

如果你要做这些事，这份文档就是基线：

- 理解 `state.json` 每个字段的语义
- 判断 `checkpoint` 和 `status.*` 谁才是主依据
- 看懂 `--doctor` 的输出来源
- 判断一轮 `--resume` 为什么会走某条 strategy
- 后续想补测试、补文档、补更严格契约时，先对齐这里

---

## 2. 先记住 4 条总规则

### 2.1 `checkpoint` 是“停点/路标”，不是完整判定结果

`checkpoint` 主要回答：

- 这轮 run 最近走到了哪一步
- 最近一次状态落盘时，脚本认为自己处在什么阶段

它适合看“流程位置”，不适合单独用来判断“这轮 run 是否安全完成”。

---

### 2.2 `status.*` 才是阶段级语义

`state.json.status` 才是当前实现真正维护的阶段状态集合，当前包含：

- `preflight`
- `generator`
- `apply_plan`
- `apply_dry_run`
- `apply_execute`
- `repair`
- `rollback`
- `final`

其中：

- 前 5 个是 installer 主流程直接维护
- `repair` / `rollback` 是后续 companion helper 回写到原 run 的附加状态
- `final` 是整轮 run 的归一结论

---

### 2.3 `final` 是整轮 run 的归一结论，但当前**不回溯吸收** repair / rollback 结果

当前 `status.final` 由 `install-interactive.sh` 在主流程结束时计算一次。

它目前会考虑：

- `preflight`
- `generator`
- `apply_dry_run`
- `apply_execute`
- 某些取消场景

它**不会**在 repair / rollback 之后自动重新计算。

也就是说：

- `status.repair` / `status.rollback` 可以晚于 `status.final` 出现
- `--doctor` 会把它们纳入摘要
- 但 `status.final` 本身当前不会因为 companion result 被回写而自动变化

这是当前实现边界，不是文档笔误。

---

### 2.4 真正做判断时，建议区分“观察入口”与“事实来源顺序”

实际操作上，建议把这两件事分开理解：

1. **观察入口**先看 `./install-interactive.sh --doctor <run_id>`
2. **主账本**再看 `state.json`
3. **事实来源**则继续按下面顺序理解：
   - 先看 `state.json.lineage.resume_strategy`
   - 再看 `APPLY-RESULT.json.recovery.*`
   - 若存在，再看 `REPAIR-RESULT.json` / `ROLLBACK-RESULT.json` 的关键状态字段
   - 最后才把 `next_step` 当成人类说明补充

也就是说：

- `doctor` 是最方便的观察入口，但它本身已经是对 `state.json + APPLY/REPAIR/ROLLBACK-RESULT.json` 的汇总视图
- `checkpoint` / `status.*` 负责告诉你“走到哪、各阶段结果如何”
- `lineage + recovery.* + companion result` 负责告诉你 inspection-first / review-first 语义下真正更接近事实的恢复判断

不要把“先看 doctor”误理解成“真正做机器/语义判断时只用 doctor 或只用 `state.json` 就够”。

---

## 3. run 目录与核心产物

每次 installer run 都会落到：

```text
scripts/generated/runs/<run_id>/
```

当前关键文件：

- `state.json`：主状态快照
- `journal.jsonl`：事件时间线
- `inputs.env`：输入快照

此外，主流程和 companion helper 还会产出：

- `scripts/generated/preflight.generated.md`
- `scripts/generated/preflight.generated.json`
- `scripts/generated/INSTALLER-SUMMARY.generated.json`（共享 latest summary，表示最近一轮主流程摘要，不保证绑定某个历史 run）
- `scripts/generated/runs/<run_id>/INSTALLER-SUMMARY.generated.json`（当前 run 的不可变 summary 快照）
- `<output_dir>/APPLY-PLAN.md`
- `<output_dir>/APPLY-PLAN.json`
- `<output_dir>/APPLY-RESULT.md`
- `<output_dir>/APPLY-RESULT.json`
- `<output_dir>/INSTALLER-SUMMARY.json`
- `<output_dir>/REPAIR-RESULT.md`
- `<output_dir>/REPAIR-RESULT.json`
- `<output_dir>/ROLLBACK-RESULT.md`
- `<output_dir>/ROLLBACK-RESULT.json`

注意：

- `state.json` 会记录这些文件路径
- `doctor` 会优先从 `state.json.artifacts` 取 companion result
- 对旧 run，如果 `state.json` 里还没登记，也会按同目录约定名做回退发现

---

## 4. `state.json` 数据模型

当前主结构可以概括成：

```json
{
  "run_id": "...",
  "state_dir": "...",
  "updated_at": "...",
  "checkpoint": "...",
  "note": "...",
  "resumed_from": "...",
  "lineage": { ... },
  "status": { ... },
  "inputs": { ... },
  "flags": { ... },
  "artifacts": { ... }
}
```

### 4.1 顶层字段

- `run_id`：当前 run 标识
- `state_dir`：当前 run 的状态目录
- `updated_at`：最近一次写状态的时间
- `checkpoint`：最近停点
- `note`：这次写状态时附带的人类备注
- `resumed_from`：如果这是 resumed run，记录直接来源 run_id；否则为空

### 4.2 `lineage`

当前字段：

- `mode`：`new` 或 `resume`
- `source_run_id`：本轮直接承接的源 run
- `source_checkpoint`：源 run 当时停点
- `source_resumed_from`：源 run 自己是否也来自更早 run
- `resume_strategy`：本轮恢复策略名
- `resume_strategy_reason`：为什么采用这条策略
- `is_resumed_run`：是否为 resumed run

### 4.3 `status`

当前字段：

- `preflight`
- `generator`
- `apply_plan`
- `apply_dry_run`
- `apply_execute`
- `repair`
- `rollback`
- `final`

### 4.4 `inputs`

这是给 `doctor` 和后续 resume 看的输入层快照，当前包括：

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

### 4.5 `flags`

当前记录这些执行意图：

- `assume_yes`
- `run_apply_dry_run`
- `execute_apply`
- `run_nginx_test_after_execute`

### 4.6 `artifacts`

当前主要记录：

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

其中：

- `config` 应优先指向 **当前 run 自己的 deploy config 快照**（通常是 `scripts/generated/runs/<run_id>/deploy.generated.yaml`）；共享 `scripts/generated/deploy.generated.yaml` 仅代表 latest config 视图
- `preflight_markdown` / `preflight_json` 应优先指向 **当前 run 自己的 preflight 快照**（通常是 `scripts/generated/runs/<run_id>/preflight.generated.md|json`）；共享 `scripts/generated/preflight.generated.*` 仅代表 latest preflight 视图
- `summary_generated` 应视为 **当前 run 自己的 generated summary 快照路径**，优先指向 `scripts/generated/runs/<run_id>/INSTALLER-SUMMARY.generated.json`
- `summary_output` 应视为 **当前 output_dir 下的人机共用 summary**（通常是 `<output_dir>/INSTALLER-SUMMARY.json`）
- 共享 `scripts/generated/INSTALLER-SUMMARY.generated.json` 仅表示最近一轮 installer 的 latest summary，不应用作历史 run 的稳定追溯锚点

---

## 5. 各阶段状态枚举

下面写的是**当前实现真实可见的状态域**，不是理想化设计图。

> 当前实现侧单一枚举入口：`scripts/lib/status-contracts.sh`
> - installer / regression 应优先复用这里的枚举定义
> - 本文档负责解释语义，不再鼓励在多处手写独立枚举副本

---

### 5.1 `status.preflight`

来源：`check_preflight_status()`

> 当前实现侧权威枚举源：`scripts/lib/status-contracts.sh`

当前取值：

- `pending`：尚未实际做 preflight
- `ok`：无 warning / blocker
- `warn`：有 warning，但没有 blocker
- `blocked`：存在 blocker，installer 会停止继续调用 generator

关键点：

- `warn` 不会直接把整轮 run 判成失败
- 只有 `blocked` 才会触发主流程终止，并让 `status.final=blocked`

---

### 5.2 `status.generator`

当前取值：

- `pending`
- `running`
- `success`
- `failed`

说明：

- `generator-reused` 场景会直接把它记为 `success`
- 当前没有单独的 `skipped` 枚举；复用已有产物在状态层视为成功复用

---

### 5.3 `status.apply_plan`

当前取值：

- `pending`
- `generated`

说明：

- 当前 apply plan 阶段的语义比较轻：要么还没生成，要么已经生成/复用
- 当前没有单独的 `failed` 状态；若前面失败，通常不会走到这里

---

### 5.4 `status.apply_dry_run`

当前取值：

- `not-requested`
- `running`
- `success`
- `failed`
- `skipped`

语义区分：

- `not-requested`：初始值，还没进入“是否执行 dry-run”的决策
- `skipped`：已经到了该决策点，但操作者没跑 dry-run
- `success` / `failed`：实际跑过 dry-run 后的结果

---

### 5.5 `status.apply_execute`

当前取值：

- `not-requested`
- `running`
- `success`
- `needs-attention`
- `blocked`
- `cancelled`
- `failed`
- `skipped`

注意两个关键细节：

#### 细节 A：这里消费的是 **installer 级恢复语义**

当真实 apply 成功返回后，installer 不是直接读取 `APPLY-RESULT.json.final_status` 填到 `status.apply_execute`。

它实际消费的是：

```json
APPLY-RESULT.json.recovery.installer_status
```

当前映射来源是：

- `success`
- `needs-attention`
- `blocked`

所以：

- `APPLY-RESULT.json.final_status=ok`
- 不代表 `status.apply_execute` 一定字面等于 `ok`
- 当前写回 `status.apply_execute` 的值会是更高一层的 installer 语义，如 `success` 或 `needs-attention`

#### 细节 B：`failed` 代表脚本级失败，不等于 apply 结果里的业务判断

如果执行真实 apply 命令本身返回非 0，installer 会把：

- `status.apply_execute=failed`

并直接按 shell exit code 退出。

这和 `APPLY-RESULT.json` 里的“有结果但需要人工处理”不是一回事。

---

### 5.6 `status.repair`

来源：`repair-applied-package.sh` 回写

当前常见取值：

- 空字符串：尚未记录 repair 结果
- `ok`
- `needs-attention`
- `blocked`

当前不会自动参与 `status.final` 重算。

---

### 5.7 `status.rollback`

来源：`rollback-applied-package.sh` 回写

当前常见取值：

- 空字符串：尚未记录 rollback 结果
- `ok`
- `needs-attention`
- `blocked`

当前同样不会自动参与 `status.final` 重算。

---

### 5.8 `status.final`

当前取值：

- `running`
- `blocked`
- `failed`
- `needs-attention`
- `cancelled`
- `success`

它不是简单抄某一个阶段，而是通过 `installer_determine_final_status()` 归一出来。

---

## 6. `status.final` 的当前判定逻辑

当前实现顺序是：

1. 如果 `preflight == blocked` → `final = blocked`
2. 否则如果 `generator == failed` → `final = failed`
3. 否则如果 `apply_dry_run == failed` → `final = failed`
4. 否则如果 `apply_execute == failed` → `final = failed`
5. 否则如果 `apply_execute == needs-attention` → `final = needs-attention`
6. 否则如果 `apply_execute == cancelled` → `final = cancelled`
7. 否则如果 `INSTALLER_FINAL_STATUS` 之前已被标成 `cancelled` → `final = cancelled`
8. 其余情况 → `final = success`

这意味着几个很重要的现实结论：

### 6.1 preflight `warn` 仍可能对应整轮 `success`

只要没有 blocker，后面阶段也没失败，当前 final 仍会是 `success`。

也就是说：

> `warn` 是“需要注意”，不是“自动失败”。

### 6.2 没执行真实 apply，也可能整轮 `success`

如果：

- preflight 正常
- generator 成功
- apply plan 正常生成
- dry-run 没失败
- 真实 apply 没被要求执行

当前 final 仍可能是 `success`。

所以当前的 `success` 更准确地理解为：

> 这轮 installer 以当前目标与当前边界来看，**正常结束**。

它**不等于**：

- nginx 已 reload
- 线上已最终生效
- 无需人工复核

### 6.3 repair / rollback 不会回刷 final

哪怕后面又做了 repair / rollback：

- `status.repair` / `status.rollback` 会更新
- `doctor` 会显示它们
- 但 `status.final` 当前不会自动重新计算

---

## 7. checkpoint 模型

### 7.1 checkpoint 的定位

当前 checkpoint 更像“流程路标”，不是有限状态机的唯一状态源。

所以判断 run 时应遵守：

- 看流程位置：先看 `checkpoint`
- 看阶段结果：再看 `status.*`
- 看后续修复建议：再看 companion result

### 7.2 当前已出现的主要 checkpoint

主流程常见值：

- `initialized`
- `inputs-reused`
- `collect-inputs`
- `inputs-confirmed`
- `preflight-reused`
- `preflight-complete`
- `generator-reused`
- `config-written`
- `generator-running`
- `generator-success`
- `apply-plan-reused`
- `apply-plan-generated`
- `apply-dry-run-running`
- `apply-dry-run-success`
- `apply-execute-running`
- `apply-execute-success`
- `completed`

理解方式：

- `*-running`：阶段已启动但尚未落最终结果
- `*-success` / `*-complete` / `*-generated`：该阶段已走完
- `*-reused`：resume 直接复用历史产物，没有重新执行该阶段
- `completed`：installer 主流程已收尾，并写出 `status.final`

### 7.3 为什么不要只盯 `checkpoint`

因为像这些信息，checkpoint 本身并不表达完整：

- `apply-execute-success` 之后到底是 `success` 还是 `needs-attention`
- 当前 run 是否来自 resume
- 当前是否已经有 repair / rollback 结果
- 当前是否允许继续 execute

这些都要靠 `status.*`、`lineage.*` 和 companion result 补齐。

---

## 8. resume / lineage 模型

---

### 8.1 顶层 `resumed_from` 与 `lineage.source_run_id`

对当前实现来说，这两个字段表达的是同一条直接继承链的两个视角：

- `resumed_from`：当前 run 顶层直接来源
- `lineage.source_run_id`：写在 lineage 里的直接来源

而：

- `lineage.source_resumed_from`

则是在说：

> 源 run 自己是不是也来自更早的一轮。

所以它们组合起来，才能回答多跳 lineage 问题。

---

### 8.2 resume 会从源 run 读取什么

当前 `state_load_resume_context()` 会从源 run 的 `state.json` 和 companion result 中加载：

- 源 run 的 `checkpoint`
- 源 run 的 `status.preflight/generator/apply_plan/apply_dry_run/apply_execute/final`
- 源 run 的 `status.repair/rollback`
- 产物路径（config / output / preflight / apply plan / apply result / repair result / rollback result / summary / inputs / journal）
- `APPLY-RESULT.json.recovery.*`
- `REPAIR-RESULT.json` 的 `final_status`、`nginx_test_rerun_status`、`next_step`
- `ROLLBACK-RESULT.json` 的 `final_status`、`mode`、`flags.execute`、`next_step`

也就是说，resume 决策当前并不只看 `state.json`，而是会吃掉 companion result 的语义。

---

### 8.3 当前 resume strategy 的真实来源

当前策略选择顺序大致是：

1. 若源 run 已执行 rollback 且成功 → `post-rollback-inspection`
2. 若源 run 的 repair 已重跑 `nginx -t` 且通过 → `post-repair-verification`
3. 若源 run repair 仍是 `needs-attention` / `blocked` → `repair-review-first`
4. 若源 run apply 明确 `resume_recommended != 1` → `inspect-after-apply-attention`
5. 若可复用 apply plan → `reuse-apply-plan`
6. 若可复用 generator 输出 → `reuse-generated-output`
7. 若可复用 preflight/config → `reuse-preflight`
8. 否则 → `re-enter-from-inputs`

这也是 `lineage.resume_strategy` 和 `lineage.resume_strategy_reason` 的来源。

---

### 8.4 当前哪些 strategy 禁止直接 execute

`resume_strategy_allows_execute()` 当前明确禁止这 4 类策略直接进入真实 apply：

- `post-rollback-inspection`
- `post-repair-verification`
- `repair-review-first`
- `inspect-after-apply-attention`

如果在这些策略下显式传：

```bash
--execute-apply
```

installer 会直接拒绝，而不是默默降级。

但在这些 inspection-first 策略下，当前仍允许：

```bash
--run-apply-dry-run
```

也就是：

> 可以做只读预演，但不允许把“复查优先”误变成“继续执行真实 apply”。

### 8.4.1 inspection-first 四类策略的统一动作矩阵

| strategy | 触发来源 | resume 的默认主语义 | 默认先看什么 | 显式允许 | 明确禁止 |
| --- | --- | --- | --- | --- | --- |
| `inspect-after-apply-attention` | `APPLY-RESULT.json.recovery.resume_recommended != 1` | 先复查 apply attention，而不是继续 execute | `APPLY-RESULT.json`、`recovery.operator_action`、`--doctor` | 复用可用产物；显式 `--run-apply-dry-run` | 显式 `--execute-apply`；把 `--resume` 视作 apply 重放 |
| `repair-review-first` | repair 结果仍是 `needs-attention` / `blocked` | 先看 repair 诊断是否收口 | `REPAIR-RESULT.json`、`diagnosis.*`、`next_step` | 人工继续排查；必要时再次 repair；显式 dry-run | 绕过 repair 结论直接真实 apply |
| `post-repair-verification` | repair 已重跑 `nginx -t` 且通过 | 先验证“修好”是否真的稳定 | `REPAIR-RESULT.json`、`execution.nginx_test_rerun_status`、手工复核 | 复用可用产物；显式 dry-run；人工确认现场 | 因 repair passed 就默认继续 execute；显式 `--execute-apply` |
| `post-rollback-inspection` | rollback 已执行且成功 | 先确认 rollback 后现场，而不是继续部署 | `ROLLBACK-RESULT.json`、rollback 后目标机状态 | 复核 rollback 结果；显式 dry-run；必要时新开 run | 把 rollback 后状态直接视作可继续 execute 的干净起点；显式 `--execute-apply` |

可以把这 4 类统一记成：

> inspection-first = 先 doctor / 看 companion result / 做人工复查；可 dry-run，但不默认继续真实 apply。

---

### 8.5 当前哪些阶段会被 resume 复用/跳过

当前 resume 会根据源 run 状态决定：

- 是否跳过输入阶段
- 是否跳过 preflight
- 是否跳过 generator
- 是否跳过 apply plan

大致规则是：

- 只要源 preflight 不是 `blocked` 且配置文件还在，就可复用输入 / preflight
- 源 generator 若成功且输出目录还在，就可复用 generator 输出
- 源 apply plan 若已生成且 JSON 还在，就可复用 apply plan

因此当前 resume 不是“从一个统一断点恢复”，而是：

> 基于已有产物的保守式复用与续接。

---

## 9. companion result 与主状态的关系

---

### 9.1 `APPLY-RESULT.json`

它主要回答：

- apply 是 `plan-only` / `dry-run` / `execute`
- 执行层状态是 `ok` 还是 `blocked`
- nginx test 是否请求、是否通过
- installer 视角下的 recovery 建议是什么

当前最关键的字段是：

- `final_status`
- `execution.backup_status`
- `execution.copy_status`
- `nginx_test.requested`
- `nginx_test.status`
- `recovery.installer_status`
- `recovery.resume_strategy`
- `recovery.resume_recommended`
- `recovery.operator_action`
- `next_step`

其中尤其要注意：

- `state.status.apply_execute` 当前对齐的是 `recovery.installer_status`
- 不是 `final_status`

#### 当前 `recovery.installer_status` 的典型来源

- `blocked`：apply 输入校验就被阻断
- `success`：
  - dry-run 正常
  - 或 execute 后 nginx test 已通过
- `needs-attention`：
  - execute 后没跑 nginx test
  - 或 execute 后 nginx test 失败

---

### 9.2 `REPAIR-RESULT.json`

repair helper 的定位是：

> 保守式 post-apply diagnosis。

它默认不改已部署文件；`--execute` 也只是重跑 `nginx -t` 并记录结果。

当前重点字段：

- `mode`：`dry-run` / `execute`
- `final_status`：`ok` / `needs-attention` / `blocked`
- `source_recovery.*`
- `execution.nginx_test_rerun_status`：`not-run` / `passed` / `failed`
- `diagnosis.*`
- `next_step`

回写到原 run 后，会更新：

- `state.artifacts.repair_result`
- `state.artifacts.repair_result_json`
- `state.status.repair`

---

### 9.3 `ROLLBACK-RESULT.json`

rollback helper 的定位是：

> 基于 `APPLY-RESULT.json` 和备份目录的 selective rollback 规划/执行结果。

当前重点字段：

- `mode`：`dry-run` / `execute`
- `final_status`：`ok` / `needs-attention` / `blocked`
- `flags.delete_new`
- `flags.execute`
- `summary.restore/delete/skip/blocked/pending/restored/deleted`
- `next_step`

回写到原 run 后，会更新：

- `state.artifacts.rollback_result`
- `state.artifacts.rollback_result_json`
- `state.status.rollback`

---

## 10. `doctor` 在这个模型里的定位

可以把 `doctor` 理解成：

> 一个把 `state.json + journal.jsonl + companion result + lineage chain` 汇总成人类可读摘要的观察器。

它当前会做这些事：

- 输出 `lineage.*` 的机器可读摘要
- 输出 resumed run 的人话解释
- 输出 `status.*`
- 输出 `inputs`
- 输出 `artifacts`
- 输出 `APPLY-RESULT.json` 摘要
- 输出 `REPAIR-RESULT.json` / `ROLLBACK-RESULT.json` 摘要
- 输出 journal 摘要
- 输出 suggestion
- 在 lineage 场景中给出当前 run / 异常祖先的优先查看产物提示

所以当前推荐理解方式是：

- `doctor` 是阅读入口
- `state.json` 是主状态账本
- companion result 是细分阶段的证据文件

---

## 11. 操作语义上的边界

当前状态模型故意保持保守，至少有这些边界：

- `success` 不等于已经 reload nginx
- `warn` 不等于失败
- `needs-attention` 不等于脚本崩溃，而是“已发生有效动作，但需要人工判断”
- `resume` 不是“重放上一轮”的别名
- `repair` 不是自动修复器
- `rollback` 不是无条件全量回退器

换句话说，当前模型更接近：

> **把运行事实、风险边界和后续选择显式落盘**，而不是把复杂线上判断偷偷吞进脚本里。

---

## 12. 实际使用时的最小判断规则

如果你只想记住最少的几条：

1. 先看 `doctor`，不要直接 resume。
2. `checkpoint` 只告诉你走到哪，不单独代表结论。
3. 阶段结果看 `status.*`。
4. `status.final` 是主流程收尾结论，但不会自动吸收 repair / rollback。
5. `status.apply_execute` 看的是 installer recovery 语义，不是 apply raw final_status。
6. inspection-first 的 resume strategy 下，可以 dry-run，但不能直接 execute。
7. 真正做生产判断时，最后一定要结合 companion result 和目标机实际状态。

---

## 13. 相关文档

- `INSTALL.md`：部署入口与路径选择
- `README.md`：项目总览与 experimental installer 摘要
- `docs/INSTALLER-OPERATOR-RUNBOOK-ZH.md`：异常 run 的人工处理顺序
- `docs/INSTALLER-RESULT-CONTRACTS-ZH.md`：6 类 JSON 结果文件的职责边界、稳定字段、消费顺序与兼容策略
- `docs/INSTALLER-NEXT-STAGE-BACKLOG-ZH.md`：后续要补强的状态机/契约/测试方向

如果后续要补更严格的 fixture、golden test、契约测试，建议以这份文档为当前实现基线，再决定哪些地方要收紧，而不是先凭直觉重写状态语义。
