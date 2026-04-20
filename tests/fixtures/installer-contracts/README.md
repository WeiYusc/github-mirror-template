# Installer Contract Fixtures

这套 fixture 不是为了复现完整 installer 运行环境，而是为了把当前 **结果契约层** 钉住。

## 设计原则

- 不引入重型测试框架
- 不依赖真实 nginx / 文件落地环境
- 用静态 JSON 样本覆盖 `state_doctor()` / `state_load_resume_context()` 当前真正依赖的字段
- 通过临时目录 materialize，避免 fixture 模板里写死开发机绝对路径
- 回归分两层：**场景语义断言** + **稳定字段矩阵 smoke check**，前者防 resume/doctor 语义漂移，后者防 contract 关键字段被静默删改

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

## 运行方式

在仓库根目录执行：

```bash
bash tests/installer-contracts-regression.sh
```

预期输出：

```text
[PASS] installer contract regression
```
