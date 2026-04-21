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

## 当前覆盖的场景

### 1. `fixture-legacy-fallback`

模拟旧 run：

- `state.json.artifacts.repair_result_json` 为空
- `state.json.artifacts.rollback_result_json` 为空
- 但同目录存在 `REPAIR-RESULT.json` / `ROLLBACK-RESULT.json`

用于验证：

- `state_load_resume_context()` 的 companion result fallback
- `state_doctor()` 的同目录自动发现语义
- 6 类 JSON 的 `schema_kind` / `schema_version`

### 2. `fixture-resumed-repair-review`

模拟 resumed run：

- `lineage.resume_strategy=repair-review-first`
- `resumed_from=fixture-legacy-fallback`
- 当前 run 与祖先 run 都可解析到 repair/rollback companion result

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
- `APPLY-RESULT.json.recovery.operator_action=rollback-or-fix`
- `APPLY-RESULT.json.nginx_test.status=failed`

用于验证：

- `state_doctor()` 的“当前 run 异常摘要”区块
- 当前 run 优先产物应指向 `APPLY-RESULT.json`
- apply attention 场景下的 suggestion 文案与 repair dry-run 引导

### 4. `fixture-post-repair-verification`

模拟 repair 已完成复查且 `nginx -t` 重跑通过后的 resumed run：

- `lineage.resume_strategy=post-repair-verification`
- `resumed_from=fixture-legacy-fallback`
- `REPAIR-RESULT.json.execution.nginx_test_rerun_status=passed`
- 当前 run 语义是“先复核修复后现场状态”，而不是继续真实 apply
- 为保持 6 类结果契约集合完整，fixture 仍保留一个中性的 rollback companion；但本场景断言聚焦 repair 主线

用于验证：

- `state_doctor()` 对 `post-repair-verification` 的摘要文案
- repair 已通过后的关键字段提取
- inspection-first resume 场景下的 operator hint 与 repair 优先语义

### 6. `fixture-source-priority-over-ancestor`

模拟 resumed run 本身没有 companion result，但直接 source run 有：

- `resumed_from=fixture-post-rollback-inspection`
- 当前 run 自己的 `repair_result_json` / `rollback_result_json` 为空
- 直接 source run 可解析到自己的 companion result
- 更早祖先 `fixture-legacy-fallback` 也同样有 companion result

用于验证：

- `state_load_resume_context()` 在 **current 缺失** 时，优先取 **direct source**，而不是直接跳到更早 ancestor
- rollback / repair 两类 companion result 的 owner run id 与关键字段能跟着最近 source 保持一致

### 7. `fixture-ancestor-fallback-after-source-gap`

模拟 current run 与 direct source run 都没有 companion result，需要继续沿 lineage 向上回溯：

- `resumed_from=fixture-source-priority-over-ancestor`
- 当前 run 自己无 companion result
- direct source run 也无 companion result
- 更早 ancestor `fixture-post-rollback-inspection` 仍保留可解析的 companion result

用于验证：

- `state_load_resume_context()` 在 **current 缺失 + direct source 缺失** 时，会继续走到最近可用 ancestor
- owner run id 可以明确指出最终取值来源，避免“看起来像当前 run，实际却来自更早祖先”的语义漂移

> 说明：这两个 fixture 主要用于 resume 载入优先级回归，不进入 6 类 contract 全套 smoke/check 矩阵。

## 运行方式

在仓库根目录执行：

```bash
bash tests/installer-contracts-regression.sh
```

预期输出：

```text
[PASS] installer contract regression
```

