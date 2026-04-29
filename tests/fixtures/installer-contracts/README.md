# Installer Contract Fixtures

这套 fixture 不是为了复现完整 installer 运行环境，而是为了把当前 **结果契约层** 钉住。

## 设计原则

- 不引入重型测试框架
- 不依赖真实 nginx / 文件落地环境
- 用静态 JSON 样本覆盖 `state_doctor()` / `state_load_resume_context()` 当前真正依赖的字段
- 通过临时目录 materialize，避免 fixture 模板里写死开发机绝对路径
- 回归分三层：**场景语义断言** + **稳定字段矩阵 smoke check** + **最小值域级断言**
  - 场景语义断言：防 `state_doctor()` / `state_load_resume_context()` 的恢复语义漂移
  - 稳定字段矩阵：防关键 contract 字段被静默删改
  - 最小值域级断言：防关键状态字段从约定枚举/布尔/整数语义悄悄漂到别的形状

## inspection-first 场景的断言口径

这套 fixture 在 inspection-first 语义上，当前不是把“哪句中文提示长什么样”当主 contract，而是优先钉下面几类字段关系：

1. `state.json.lineage.resume_strategy`
2. `APPLY-RESULT.json.recovery.resume_strategy` / `resume_recommended` / `operator_action`
3. `REPAIR-RESULT.json.final_status` / `execution.nginx_test_rerun_status`
4. `ROLLBACK-RESULT.json.final_status` / `mode` / `flags.execute`
5. `next_step` 只作为人工提示补充，不作为唯一机器判定来源

因此在 fixture / regression 层，inspection-first 相关回归主要关注的是：

- strategy 有没有被正确保留下来
- repair / rollback companion result 有没有被当前 run / direct source / ancestor 正确解析
- doctor 的“优先查看产物”是否仍跟着策略主线走
- 字段类型/value drift/path drift 出现时，是否还能保住 review-first / inspection-first 的保守语义

换句话说：

> 这里真正要钉住的是 **字段消费顺序与策略主语义**，不是完整提示文案逐字不变。

## 当前覆盖的场景

### 1. `fixture-legacy-fallback`

模拟旧 run / 兼容探针：

- `state.json.artifacts.repair_result_json` 为空
- `state.json.artifacts.rollback_result_json` 为空
- 但同目录存在 `REPAIR-RESULT.json` / `ROLLBACK-RESULT.json`
- 这个场景的重点不是鼓励新 run 继续省略登记，而是把“旧账本仍可被同目录 companion 自动发现”这条兼容 backstop 单独钉住

用于验证：

- `state_load_resume_context()` 的 companion result fallback
- `state_doctor()` 的同目录自动发现语义
- 6 类 JSON 的 `schema_kind` / `schema_version`

### 2. `fixture-resumed-repair-review`

模拟 resumed run：

- `lineage.resume_strategy=repair-review-first`
- `resumed_from=fixture-legacy-fallback`
- 当前 run 显式登记自己的 `repair_result_json` / `rollback_result_json`
- 祖先 run 仍可通过 legacy fallback 解析到 companion result

用于验证：

- `state_doctor()` 的 lineage 摘要
- 最近异常祖先节点提示
- repair 优先产物提示
- `state_load_resume_context()` 对 repair/rollback 关键字段的提取

### 3. `fixture-current-apply-attention`

模拟当前 run 自身在真实 apply 后进入 `needs-attention`：

- `lineage.mode=new`
- `status.apply_execute=needs-attention`
- `status.final=needs-attention`
- `APPLY-RESULT.json.recovery.resume_strategy=manual-recovery-first`
- `APPLY-RESULT.json.recovery.operator_action=rollback-or-fix`
- `APPLY-RESULT.json.nginx_test.status=failed`
- 当前 run 显式登记自己的 repair / rollback companion 路径；这些 companion 只是补充观察面，不是让 state 继续依赖空值 fallback

用于验证：

- `state_doctor()` 的“当前 run 异常摘要”区块
- 当前 run 优先产物应指向 `APPLY-RESULT.json`
- apply attention 场景下的 suggestion 文案与 repair dry-run 引导
- 当前 run 自身的 apply recovery 语义仍保持“先人工恢复/修复”，不会误漂成 inspection-first resumed run 的 `post-apply-review`

### 4. `fixture-post-repair-verification`

模拟 repair 已完成复查且 `nginx -t` 重跑通过后的 resumed run：

- `lineage.resume_strategy=post-repair-verification`
- `resumed_from=fixture-legacy-fallback`
- `REPAIR-RESULT.json.execution.nginx_test_rerun_status=passed`
- 当前 run 语义是“先复核修复后现场状态”，而不是继续真实 apply
- 为保持 6 类结果契约集合完整，fixture 仍保留一个中性的 rollback companion；但本场景断言聚焦 repair 主线
- 当前 run 也显式登记 `repair_result_json` / `rollback_result_json`；这里要钉的是 inspection-first 当前 run 的正式账本形状，而不是继续复用 legacy 空值语义

用于验证：

- `state_doctor()` 对 `post-repair-verification` 的摘要文案
- repair 已通过后的关键字段提取
- inspection-first resume 场景下的 operator hint 与 repair 优先语义

### 5. `fixture-post-rollback-inspection`

模拟 rollback 已真实执行成功后的 resumed run：

- `lineage.resume_strategy=post-rollback-inspection`
- `resumed_from=fixture-legacy-fallback`
- `status.rollback=ok`
- `ROLLBACK-RESULT.json.final_status=ok`
- `ROLLBACK-RESULT.json.flags.execute=true`
- 当前 run 语义是“先复查 rollback 后现场状态”，而不是立刻重新 apply
- 为保持 6 类结果契约集合完整，fixture 仍保留一个中性的 apply companion；但本场景断言聚焦 rollback 主线
- 当前 run 也显式登记 `repair_result_json` / `rollback_result_json`；doctor / resume 应优先消费这些已登记路径，而不是把 fallback 当主通路

用于验证：

- `state_load_resume_context()` 会优先把当前 run 的 rollback result 视作事实来源，而不是错误退回更早祖先
- `state_doctor()` 对 `post-rollback-inspection` 的摘要文案与策略优先产物提示
- semantic drift / artifact drift 下，rollback 主语义不会被 generic artifact 或旧 `state.status` 摘要抢走

### 6. `fixture-inspect-after-apply-attention`

模拟 resumed run 继承到一个 **apply recovery 已明确标注“不建议默认 resume”** 的 inspection-first 场景：

- `lineage.resume_strategy=inspect-after-apply-attention`
- `resumed_from=fixture-legacy-fallback`
- `APPLY-RESULT.json.recovery.resume_strategy=post-apply-review`
- `APPLY-RESULT.json.recovery.resume_recommended=false`
- `APPLY-RESULT.json.recovery.operator_action=manual-review`
- 当前 run 仍保留中性的 repair / rollback companion result，并显式登记到 `state.artifacts`，用于验证它们不会抢走 apply recovery 主语义

用于验证：

- `state_doctor()` 在 `inspect-after-apply-attention` 下会优先把 **当前 run 的 `APPLY-RESULT.json`** 当作策略优先产物
- doctor 的 operator hint 会明确回到 “先看 apply result / recovery 字段，再决定后续动作”
- 即使同目录存在 repair / rollback companion result，也不会让它们在该策略下抢走当前 run 的主观察面
- 这类场景真正钉住的是 **`lineage.resume_strategy` + `APPLY-RESULT.json.recovery.*` 的组合语义**，而不是某句中文提示文案逐字相同

### 7. `fixture-source-priority-over-ancestor`

模拟 resumed run 本身没有 companion result，但直接 source run 有：

- `resumed_from=fixture-post-rollback-inspection`
- 当前 run 自己的 `repair_result_json` / `rollback_result_json` 为空
- 直接 source run 可解析到自己的 companion result
- 更早祖先 `fixture-legacy-fallback` 也同样有 companion result

用于验证：

- `state_load_resume_context()` 在 **current 缺失** 时，优先取 **direct source**，而不是直接跳到更早 ancestor
- 这里故意保持当前 run 自己的 `repair_result_json` / `rollback_result_json` 为空，用来钉住 lineage 向上回溯时的兼容优先级，而不是代表常规当前 run 契约
- rollback / repair 两类 companion result 的 owner run id 与关键字段能跟着最近 source 保持一致

### 8. `fixture-ancestor-fallback-after-source-gap`

模拟 current run 与 direct source run 都没有 companion result，需要继续沿 lineage 向上回溯：

- `resumed_from=fixture-source-priority-over-ancestor`
- 当前 run 自己无 companion result
- direct source run 也无 companion result
- 更早 ancestor `fixture-post-rollback-inspection` 仍保留可解析的 companion result

用于验证：

- `state_load_resume_context()` 在 **current 缺失 + direct source 缺失** 时，会继续走到最近可用 ancestor
- 这里同样故意保留空值，用于 pin 祖先 fallback 边界；不是新 run / 已登记 companion run 的推荐账本形状
- owner run id 可以明确指出最终取值来源，避免“看起来像当前 run，实际却来自更早祖先”的语义漂移

> 说明：这两个 fixture 主要用于 resume 载入优先级回归，不进入 6 类 contract 全套 smoke/check 矩阵。

### 9. `fixture-missing-source-state`

模拟 resumed run 指向的 source state 不存在或不可读：

- `resumed_from=fixture-missing-source-parent`
- 当前 run 自己没有 companion result
- source run 的 `state.json` 缺失

用于验证：

- `state_load_resume_context()` 会保留 `resumed_from` 线索，但不会伪造 repair / rollback companion 结果
- `state_doctor()` 会把缺失 source state 显式渲染到 lineage chain
- 最近异常祖先摘要会明确说明“state.json 缺失或不可读”，而不是静默截断

### 10. `fixture-lineage-cycle-a` / `fixture-lineage-cycle-b`

模拟两个 run 在 lineage 上互相指回，形成循环：

- `fixture-lineage-cycle-a.resumed_from=fixture-lineage-cycle-b`
- `fixture-lineage-cycle-b.resumed_from=fixture-lineage-cycle-a`

用于验证：

- `state_load_resume_context()` 不会因为 lineage 循环而无限递归，也不会伪造 companion 结果
- `state_doctor()` 不会因为 lineage 循环而无限递归
- lineage chain 会显式输出 cycle sentinel
- 最近异常祖先摘要会明确说明检测到 lineage 循环并已停止解析

### 11. 临时坏样本注入：损坏 JSON 的保守降级

这组不是静态 fixture 目录，而是在 regression 运行时对 `WORKDIR` 里的临时副本做“定点写坏”：

- 把某个 source run 的 `state.json` 改成不可解析 JSON
- 把某个当前 run 的 `REPAIR-RESULT.json` 改成不可解析 JSON

用于验证：

- `state_load_resume_context()` 在 source state **存在但坏掉** 时，行为与 source 缺失保持同级保守：保留 lineage 线索，但不伪造 companion result
- `state_doctor()` 在 follow-up result JSON **存在但坏掉** 时，会明确打印“读取失败”，但仍继续输出其它可读产物（如 apply/rollback）与下一步建议，而不是整段崩掉

### 12. 损坏输入快照 / 混入坏 journal 行

这组同样在 regression 运行时对临时 `WORKDIR` 做定点扰动：

- 把某个 run 的 `inputs.env` 改成不可安全加载的内容（包括损坏语法、或混入白名单外变量）
- 在 `journal.jsonl` 里混入不可解析坏行，同时保留一条后续有效事件

用于验证：

- `state_load_inputs_env()` 采用**白名单变量 + 静态解析赋值**加载快照；对损坏/越界输入返回**可控错误**，而不是把当前 shell source 过程弄脏
- `state_doctor()` 对坏 journal 行保持保守忽略：仍能统计行数、提取最后一条有效事件，并继续输出整体摘要

### 13. `journal.jsonl` 的 anchor path contract

这组固定 fixture 额外把 `journal.jsonl` 里最容易语义漂移、但又最值得尽早在静态层锁住的 path contract 明确钉住：

- `run.initialized.path` 必须指向当前 run 的 `state_dir`
- `run.complete.path` 必须指向当前 run 的 `INSTALLER-SUMMARY.json`
- `apply-execute.complete.path` 必须指向当前 run 的 `APPLY-RESULT.json`
- `repair.result.recorded.path` / `rollback.result.recorded.path` 必须分别指向当前 run 的 `REPAIR-RESULT.json` / `ROLLBACK-RESULT.json`
- 对已经有本地 companion 文件的 current/resumed fixture，`state.artifacts.repair_result_json` / `rollback_result_json` 也应显式登记到当前 run 路径；空值语义只保留给 legacy / priority probe 这类兼容样本

用于验证：

- event 名称与 path 主锚点不会只在 smoke 里被动发现漂移，而能在 fixture regression 层更早失败
- inspection-first fixture 的 companion result recorded 事件仍明确回到 companion result，而不是漂到 generic summary 或祖先产物
- `run.initialized → state_dir`、`run.complete → summary_output`、阶段 recorded/execute 事件 → 对应 result json 的关系，始终与 `docs/INSTALLER-STATE-MODEL-ZH.md` 保持一致

### 15. JSON 合法但路径/产物漂移（path drift / artifact drift）的保守降级

这组场景里，JSON 结构、字段类型和值域都可能是合法的，但**artifact 路径本身漂了**，或只剩半套结果文件：

- `state.artifacts.apply_result_json` 指向错误目录或缺失文件
- `REPAIR-RESULT.json` 缺失/损坏，但同目录仍保留 `REPAIR-RESULT.md`
- resume strategy 仍指向 `post-repair-verification` / `post-rollback-inspection`

用于验证：

- doctor 的“优先查看产物”与 lineage 策略优先产物，会优先指向**当前存在的文件**，而不是把缺失路径继续当成有效线索
- companion fallback 的基准目录不会只盲信 `apply_result_json`，而会从当前可用 artifact 中恢复同目录的 repair / rollback companion 解析
- 当结构化 `repair/rollback` 结果缺失或不可读时，doctor 会保留对应策略的**人工复核语义**，而不是直接退回旧的 apply 建议抢占主语义

## 当前 inspection-first 覆盖边界

当前 fixture / regression 已明确覆盖的 inspection-first 主线主要有：

- `repair-review-first`
- `post-repair-verification`
- `post-rollback-inspection`
- `inspect-after-apply-attention`

其中：

- `post-repair-verification` 的关键事实字段是 `REPAIR-RESULT.json.execution.nginx_test_rerun_status=passed`
- `post-rollback-inspection` 的关键事实字段是 `ROLLBACK-RESULT.json.final_status=ok` 且 `flags.execute=true`
- `inspect-after-apply-attention` 的关键事实字段是 `lineage.resume_strategy=inspect-after-apply-attention` 配合 `APPLY-RESULT.json.recovery.resume_recommended=false` 与 `operator_action=manual-review`
- `repair-review-first` 更偏 source/current repair result 仍需 operator review 的场景

这意味着 README 当前表达的覆盖边界也应理解为：

> fixture 已经能把 inspection-first 的主 contract 面钉住，但并不是要求每一种 review-first 场景都必须依赖逐字相同的提示文案。

在仓库根目录执行：

```bash
bash tests/installer-contracts-regression.sh
```

预期输出：

```text
[PASS] installer contract regression
```
