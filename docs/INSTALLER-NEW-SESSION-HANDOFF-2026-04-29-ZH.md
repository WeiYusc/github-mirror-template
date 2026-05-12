# Interactive Installer 新会话交接（2026-04-29）

> 用途：这份不是历史归档，而是给**新开会话**快速接手当前 `interactive-installer` 工作线用的。
> 仓库：`github-mirror-template`
> 分支：`weiyusc/exp/interactive-installer`
> 当前 HEAD：`06094d9 docs: add control-plane handoff note`
> 关键功能提交：`4c6a56f test: add normalized doctor golden regression`
> 当前状态：**本地与远端已对齐，工作树应为干净**

---

## 1. 这一轮刚完成了什么

本轮刚完成的是 **interactive installer control-plane correctness / doctor truth-source / doctor golden** 这一段收口，不是新功能开发。

核心完成项：

1. 修正 `state_doctor()` 不再机械偏信落盘 `lineage.resume_strategy`
2. 让 `doctor` 与 `planner` 在 resume strategy / inspection-first 语义上使用同一套事实优先级
3. 补齐 `doctor` 输出级 **规范化 golden regression**：
   - 新增 `tests/installer-doctor-golden.sh`
   - 新增 `tests/fixtures/installer-contracts/doctor-golden/*.golden.txt`
4. 收口 companion result / artifact path / fixture journal 等 contract 漂移
5. 补了 handoff 与文档导航，方便后续会话直接接手

一句话：

> 这轮重点不是“扩功能”，而是把 `doctor`、artifact/result 契约、回归护栏压实，避免后续整理 helper / 文案 / 摘要时把诊断语义悄悄改坏。

---

## 2. 当前最重要的稳定结论

### 2.1 `doctor` 的 truth-source 优先级

当前稳定优先级：

```text
rollback execute ok
> repair rerun passed
> repair needs-attention/blocked
> apply recovery resume_recommended=false
> lineage fallback
```

含义：

- 不再把 `lineage.resume_strategy` 当唯一真相源
- 已有当前 run / companion result 的事实时，应优先信结果文件
- 只有事实不足时，才回退到 lineage 文本

### 2.2 `doctor` golden 的设计边界

当前 golden 是 **半弹性 / 规范化输出回归**，不是整段逐字快照。

会钉住：

- `resume_strategy`
- current / lineage / ancestor 关键摘要
- 优先查看产物
- apply / repair / rollback result section 的关键字段
- `next_step` 主语义

不会钉死：

- 临时目录路径
- 全量产物清单
- 非关键中文文案细节
- 展示层排版噪音

### 2.3 当前这轮不是空口结论，已经过实跑验证

已通过：

```bash
bash tests/installer-smoke.sh
bash tests/installer-contracts-regression.sh
bash tests/installer-doctor-golden.sh
```

---

## 3. 这轮关键文件

### 新增 / 关键测试文件

- `tests/installer-doctor-golden.sh`
- `tests/fixtures/installer-contracts/doctor-golden/fixture-legacy-fallback.golden.txt`
- `tests/fixtures/installer-contracts/doctor-golden/fixture-resumed-repair-review.golden.txt`
- `tests/fixtures/installer-contracts/doctor-golden/fixture-current-apply-attention.golden.txt`
- `tests/fixtures/installer-contracts/doctor-golden/fixture-post-repair-verification.golden.txt`
- `tests/fixtures/installer-contracts/doctor-golden/fixture-post-rollback-inspection.golden.txt`
- `tests/fixtures/installer-contracts/doctor-golden/fixture-inspect-after-apply-attention.golden.txt`
- `tests/fixtures/installer-contracts/doctor-golden/fixture-missing-source-state.golden.txt`

### 关键实现 / 契约入口

- `scripts/lib/state.sh`
- `tests/installer-contracts-regression.sh`
- `tests/fixtures/installer-contracts/README.md`

### 本轮新增 / 推荐优先读的交接文档

1. `docs/INSTALLER-TLS-PHASE1-HANDOFF-2026-05-01-ZH.md`（TLS Phase 1 专用续接入口）
2. `docs/INSTALLER-NEW-SESSION-HANDOFF-2026-04-29-ZH.md`
3. `docs/INSTALLER-CONTROL-PLANE-HANDOFF-2026-04-29-ZH.md`
4. `docs/INSTALLER-INSPECTION-FIRST-HANDOFF-2026-04-22-ZH.md`
5. `docs/INSTALLER-PAUSE-HANDOFF-2026-04-21-ZH.md`
6. `docs/INSTALLER-RESULT-CONTRACTS-ZH.md`
7. `docs/INSTALLER-STATE-MODEL-ZH.md`

---

如果新会话要继续，先做什么

在仓库根目录先执行：

```bash
git checkout weiyusc/exp/interactive-installer
git pull --ff-only
bash tests/installer-smoke.sh
bash tests/installer-contracts-regression.sh
bash tests/installer-doctor-golden.sh
```

如果要继续的是 **TLS / 自动 SSL / ACME** 这条线，再额外读：

- `docs/INSTALLER-TLS-PHASE1-HANDOFF-2026-05-01-ZH.md`

如果都为绿，说明当前停点仍然可靠，可以继续下一轮。

---

## 5. 新会话最值得接的方向

### 第一优先级

继续看 **control-plane correctness / operator-facing guardrails**：

- 非交互 `preflight -> generator -> apply` 还有没有 summary / checkpoint / final status 打架的边角
- `doctor` / `resume` 是否还有新的 truth-source 不一致
- run 级 artifact / result / summary snapshot 是否在更多入口下持续隔离

### 第二优先级

继续补 **最值钱的入口级 smoke / regression**：

- `doctor` strategy priority / recommendation drift
- summary isolation / 相邻 run 污染
- artifact path / result registration drift
- README / INSTALL 推荐命令的真实可达性

### 当前不值得优先做

- 不继续机械补 fixture 文案小变体
- 不为了“看起来更完整”去扩新 installer 功能面
- 不在没有新失稳证据时，花时间补低价值测试枝节

---

## 6. 给新会话的最短提示词（可直接贴）

下面这段可以直接复制到新会话：

```text
继续 `github-mirror-template` 的 `interactive-installer` 这条线，仓库在 `research/github-mirror-template`，分支是 `weiyusc/exp/interactive-installer`。先读：
1. docs/INSTALLER-NEW-SESSION-HANDOFF-2026-04-29-ZH.md
2. docs/INSTALLER-CONTROL-PLANE-HANDOFF-2026-04-29-ZH.md
3. docs/INSTALLER-INSPECTION-FIRST-HANDOFF-2026-04-22-ZH.md
4. docs/INSTALLER-PAUSE-HANDOFF-2026-04-21-ZH.md

然后先跑：
- bash tests/installer-smoke.sh
- bash tests/installer-contracts-regression.sh
- bash tests/installer-doctor-golden.sh

当前已知最新提交是：
- 06094d9 docs: add control-plane handoff note
- 4c6a56f test: add normalized doctor golden regression
- be3b7a6 fix: align doctor truth-source priority with planner

这轮刚完成的重点不是新功能，而是：
- doctor/planner truth-source priority 对齐
- doctor 输出级 normalized golden regression
- artifact / companion result / fixture journal contract 收口

继续时优先看 control-plane correctness / operator-facing guardrails，不要先回头机械补 fixture 文案枝节。
```

---

## 7. 一句话交接结论

> 现在这个停点已经有代码、测试、文档、handoff，而且本地远端对齐；新会话最合适的起手式不是重新梳理历史，而是先读本文件、跑三条回归，再直接挑下一个 control-plane correctness 问题下手。
