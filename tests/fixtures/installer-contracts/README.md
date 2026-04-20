# Installer Contract Fixtures

这套 fixture 不是为了复现完整 installer 运行环境，而是为了把当前 **结果契约层** 钉住。

## 设计原则

- 不引入重型测试框架
- 不依赖真实 nginx / 文件落地环境
- 用静态 JSON 样本覆盖 `state_doctor()` / `state_load_resume_context()` 当前真正依赖的字段
- 通过临时目录 materialize，避免 fixture 模板里写死开发机绝对路径

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

## 运行方式

在仓库根目录执行：

```bash
bash tests/installer-contracts-regression.sh
```

预期输出：

```text
[PASS] installer contract regression
```
