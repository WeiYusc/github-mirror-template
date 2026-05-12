# Interactive Installer 暂停开发归档 / 续接指引（2026-04-21）

> 状态：**阶段性暂停开发，已归档停点**
> 仓库：`github-mirror-template`
> 分支：`weiyusc/exp/interactive-installer`
> 远端：`origin`
> 归档时间：2026-04-21
> 当前停点提交：`4b7fa10 fix: recurse resume companion priority across lineage`

---

## 1. 这份文档的用途

这不是发布公告，而是给“下次继续开发时快速恢复上下文”用的归档 handoff。

目标是让未来续接时，不需要重新翻整段聊天记录，也不需要重新猜：

- 当前实验分支到底做到哪了
- 最近一轮到底改了什么
- 哪些材料应该先读
- 应该先跑什么验证
- 下一步最值得从哪里接

---

## 2. 当前项目状态（归档口径）

`github-mirror-template` 当前应按两层理解：

- **稳定主线**：`v0.2 generator`
  - 这是已经正式落地并对外稳定呈现的主流程
- **实验分支**：`weiyusc/exp/interactive-installer`
  - 这是偏 `v0.3` 方向的 installer / orchestration / apply 层实验分支
  - 当前已不是 demo 骨架，而是具备结果契约、状态模型、resume / doctor / repair / rollback 语义，以及轻量回归体系的实验编排层

本次归档的含义是：

> **暂时停止继续推进这个实验分支的新开发，但把当前停点整理清楚、推到远端，并留下可恢复的入口。**

---

## 3. 本次暂停前已经完成的核心收口

### 3.1 结果契约与状态模型

已补齐/正式化：

- `docs/INSTALLER-RESULT-CONTRACTS-ZH.md`
- `docs/INSTALLER-STATE-MODEL-ZH.md`

当前 6 类结果文件已经进入“有契约意识”的状态：

- `state.json`
- `INSTALLER-SUMMARY.json`
- `APPLY-PLAN.json`
- `APPLY-RESULT.json`
- `REPAIR-RESULT.json`
- `ROLLBACK-RESULT.json`

并已加入 `schema_kind` / `schema_version` 这类顶层识别字段。

### 3.2 installer contract regression 体系

已建立轻量 shell 回归：

- `tests/installer-contracts-regression.sh`
- `tests/fixtures/installer-contracts/`

当前回归不依赖重型测试框架，已经覆盖：

- schema 元信息
- 稳定字段矩阵 smoke check
- 最小值域/类型断言
- `state_doctor()` 输出骨架与关键语义
- `state_load_resume_context()` 的关键消费链
- legacy fallback / resumed / current apply attention / post-repair / post-rollback 等代表场景

### 3.3 doctor / resume 语义收口

最近几刀重点收口的是：

- `state_doctor()` 的摘要、产物、journal、lineage 语义
- `state_load_resume_context()` 对 companion result 的消费优先级

当前已明确并通过回归钉住：

- `doctor`：**current run companion 优先**，祖先异常结果仅作参考线索
- `resume`：**current run > direct source run > ancestor fallback**

其中最后一刀为：

- `4b7fa10 fix: recurse resume companion priority across lineage`

它让 `state_load_resume_context()` 不再只看本轮或同目录 fallback，而是会沿 lineage 递归向上找最近可用 companion result。

---

## 4. 本次暂停前未推送并已整理推送的提交（归档清单）

暂停前整理并审核的是这 12 个提交：

1. `d4dbaee` — `docs: formalize installer result contracts`
2. `55b8b80` — `test: add installer contract regression fixtures`
3. `c7c58b8` — `test: extend installer contract regression coverage`
4. `3907aaf` — `test: cover post-repair verification resume flow`
5. `e7e2d32` — `test: add installer contract smoke matrix`
6. `62a8b99` — `test: add installer contract value assertions`
7. `bcb67b7` — `test: cover current-run apply attention doctor semantics`
8. `632626c` — `test: pin doctor summary and artifact sections`
9. `9baca47` — `test: pin doctor journal summary output`
10. `cb40d89` — `test: pin doctor and resume companion consistency`
11. `9560fa0` — `fix: prefer current companion artifacts in doctor lineage`
12. `4b7fa10` — `fix: recurse resume companion priority across lineage`

这些提交共同完成了：

- 契约文档成型
- fixture / regression 体系落地
- doctor / resume 消费链关键语义收口

---

## 5. 当前最重要的文件入口

### 必读（下次续接优先读）

1. `docs/INSTALLER-PAUSE-HANDOFF-2026-04-21-ZH.md`（本文件）
2. `docs/INSTALLER-V0.3-ROUNDUP-ZH.md`
3. `docs/INSTALLER-RESULT-CONTRACTS-ZH.md`
4. `docs/INSTALLER-STATE-MODEL-ZH.md`
5. `docs/INSTALLER-NEXT-STAGE-BACKLOG-ZH.md`

### 关键实现/回归入口

- `scripts/lib/state.sh`
- `tests/installer-contracts-regression.sh`
- `tests/fixtures/installer-contracts/README.md`

---

## 6. 下次继续开发时的最短恢复路径

在仓库根目录执行：

```bash
git checkout weiyusc/exp/interactive-installer
git pull --ff-only
bash tests/installer-contracts-regression.sh
```

然后按顺序读：

1. 本文档
2. `docs/INSTALLER-V0.3-ROUNDUP-ZH.md`
3. `docs/INSTALLER-RESULT-CONTRACTS-ZH.md`
4. `docs/INSTALLER-STATE-MODEL-ZH.md`
5. `docs/INSTALLER-NEXT-STAGE-BACKLOG-ZH.md`

如果回归通过，说明当前停点仍然可作为续接基线。

---

## 7. 推荐的续接方向（不是现在要做，只是留钩子）

如果以后恢复开发，优先级建议仍然是：

### 第一优先级

继续补 **异常路径回归**，尤其是 lineage / resume 的坏路径：

- source 链断裂
- 结果 JSON 缺失或损坏
- 历史 run 只有部分 companion result
- lineage 循环或异常引用
- `doctor` / `resume` 对坏样本的保守降级语义

### 第二优先级

继续补 **状态推进/允许动作** 的约束回归：

- 某些 inspection-first resume 下禁止直接真实 apply
- `needs-attention` 与 `blocked` 的动作边界
- repair / rollback / resume 的优先级冲突

### 第三优先级

再考虑信息架构与对外入口收口，而不是先横向继续加功能。

---

## 8. 归档时的验证口径

本次暂停归档前，至少应满足：

```bash
bash tests/installer-contracts-regression.sh
```

预期：

```text
[PASS] installer contract regression
```

建议额外做：

```bash
git diff --check
git status --short --branch
```

归档完成的理想状态是：

- 关键回归为绿
- 工作树干净
- 分支已推到远端
- 下次续接入口明确

---

## 9. 备注

- `TASKS.md` 被 `.gitignore` 忽略，不作为远端归档材料的一部分。
- 因此真正用于跨会话/跨机器续接的持久资料，应以：
  - 本文档
  - docs 系列文档
  - 已推送提交历史
  为准。

---

## 10. 一句话停点结论

> `weiyusc/exp/interactive-installer` 当前已完成“结果契约 + 轻量回归 + doctor/resume 关键优先级语义”这一轮核心收口；现在适合暂停，把它当作一个**可恢复、可验证、可继续演化**的实验停点保存，而不是继续无边界往前堆功能。
