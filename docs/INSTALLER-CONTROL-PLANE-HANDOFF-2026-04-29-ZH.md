# Interactive Installer control-plane handoff（2026-04-29）

> 状态：**doctor truth-source / artifact contract / doctor golden 这一轮已收口并推到远端**
> 仓库：`github-mirror-template`
> 分支：`weiyusc/exp/interactive-installer`
> 远端：`origin`
> handoff 时间：2026-04-29
> 当前停点提交：`4c6a56f test: add normalized doctor golden regression`

---

## 1. 这份 handoff 的用途

这不是总归档，也不是第一次读仓库时的入口。

它只服务一个目标：

> **把 2026-04-29 这轮围绕 control-plane correctness / doctor truth-source / 结果契约护栏的连续收口，压成下一次续接时能快速恢复上下文的短入口。**

如果下次用户说“继续 interactive installer 最近这轮 control-plane / doctor 收口”，优先先读这份，再回看更大的 inspection-first handoff、pause handoff 与结果契约文档。

---

## 2. 这轮到底做了什么

这轮不是扩新功能面，而是继续沿着既有 installer control-plane 线补可靠性护栏，重点处理三类问题：

1. **artifact / journal / result contract 漂移**
2. **`doctor` 与 `planner` truth-source 优先级不一致**
3. **`doctor` 缺少输出级 golden 护栏，后续改文案/重组摘要时容易误伤诊断语义**

最终落点不是“又多几条零散 fixture”，而是把下面几件事接成一条更完整的护栏链：

- current / resumed run 的 artifact path contract
- fixture journal event / anchor path contract
- companion result 显式登记边界
- `state_doctor()` 的有效策略推导顺序
- `doctor` 输出的半弹性 golden 回归

---

## 3. 当前已经稳定下来的核心结论

### 3.1 `doctor` 不该再机械偏信落盘 `lineage.resume_strategy`

这轮确认的真实缺口是：

> `state_doctor()` 之前仍可能直接沿用 `state.json.lineage.resume_strategy`，而不是像 planner 一样根据当前 companion/apply/repair/rollback result 重新推导有效策略。

当前已经收口为：

- `doctor` 与 `planner` 使用同一优先级思路看事实
- 旧 lineage 文本可以保留，但不能再单独充当唯一 truth-source

### 3.2 当前冲突优先级已明确收口

当 `lineage.resume_strategy` 与当前可读结果冲突时，当前稳定优先级是：

```text
rollback execute ok
> repair rerun passed
> repair needs-attention/blocked
> apply recovery resume_recommended=false
> lineage fallback
```

也就是：

- 已真实执行成功的 rollback inspection 语义最高
- repair rerun 已通过时应进入 `post-repair-verification`
- repair 仍需人工处理时应优先保住 `repair-review-first`
- apply 明确不建议 resume 时，应落到 inspection/review-first 语义
- 最后才回退到 lineage 文本

### 3.3 `doctor` 输出回归现在钉的是“诊断语义”，不是整份逐字快照

这轮新增了：

- `tests/installer-doctor-golden.sh`
- `tests/fixtures/installer-contracts/doctor-golden/*.golden.txt`

它当前采取的是**规范化 / 半弹性 golden**，也就是：

#### 会钉住的内容

- `resume_strategy`
- current / lineage / ancestor 关键摘要
- 优先查看产物
- apply / repair / rollback result section 的关键字段
- `next_step` 的主语义

#### 不会逐字锁死的内容

- 临时目录绝对路径
- 全量产物清单
- 非关键中文文案细节
- 纯展示层的排版噪音

这个边界很重要，因为它把 `doctor` 真正当作**诊断面板**来回归，而不是把长段中文说明硬编码成脆弱 snapshot。

### 3.4 companion result / artifact path contract 现在更清楚了

这轮还补齐并钉清了：

- current / resumed fixture 如果本地已经产出 companion result，应该优先显式登记 `state.artifacts.*_result_json`
- `repair_result_json` / `rollback_result_json` 的“空值 + companion fallback”只保留为旧 run / lineage priority probe / 定向坏样本的兼容 backstop
- `run.initialized` / `run.complete` 与 apply / repair / rollback 关键 event 的 path 语义已下沉到 contract regression
- fixture 遗留的 `repair.review` / `rollback.review` 已收口为 runtime 实际契约事件 `repair.result.recorded` / `rollback.result.recorded`

---

## 4. 本轮相关关键提交

相对 `0633d07 test: wire summary isolation regression into CI`，本轮关键提交为：

1. `48945c0` — `docs: refresh installer handoff stop point`
2. `a222a83` — `fix: preserve run-local artifacts across resume reuse`
3. `b260c61` — `docs: converge installer artifact and resume contracts`
4. `de60f6f` — `test: align resume artifact path assertions`
5. `451e38e` — `test: lock fixture journal anchor paths`
6. `f05a52f` — `test: align fixture companion journal events`
7. `f5fff8f` — `test: tighten companion result state artifact contracts`
8. `be3b7a6` — `fix: align doctor truth-source priority with planner`
9. `4c6a56f` — `test: add normalized doctor golden regression`

如果只把 2026-04-29 这轮压成一句话：

> 先把 artifact/journal/companion result 的 contract 边界钉清，再让 `doctor` 的事实来源优先级与 `planner` 对齐，最后补上输出级半弹性 golden，避免后续 helper 收口、摘要重组或文案整理时悄悄改掉核心诊断语义。

---

## 5. 本轮已跑过并通过的验证

当前已确认通过：

```bash
bash tests/installer-smoke.sh
bash tests/installer-contracts-regression.sh
bash tests/installer-doctor-golden.sh
```

关键含义：

- 非交互 happy path / smoke 仍在
- contract regression 与新 truth-source 优先级一致
- `doctor` 输出级回归已经真正落地，而不是停在口头设计

---

## 6. 下次续接的最短恢复路径

在仓库根目录执行：

```bash
git checkout weiyusc/exp/interactive-installer
git pull --ff-only
bash tests/installer-smoke.sh
bash tests/installer-contracts-regression.sh
bash tests/installer-doctor-golden.sh
```

然后建议按顺序读：

1. `docs/INSTALLER-CONTROL-PLANE-HANDOFF-2026-04-29-ZH.md`（本文件）
2. `docs/INSTALLER-INSPECTION-FIRST-HANDOFF-2026-04-22-ZH.md`
3. `docs/INSTALLER-PAUSE-HANDOFF-2026-04-21-ZH.md`
4. `docs/INSTALLER-RESULT-CONTRACTS-ZH.md`
5. `docs/INSTALLER-STATE-MODEL-ZH.md`
6. `tests/fixtures/installer-contracts/README.md`

如果这 3 条回归都为绿，说明当前停点仍然适合作为下一轮基线。

---

## 7. 如果以后还要继续，最值得从哪接

当前我不建议回头继续机械补 fixture 文案枝节。

如果以后恢复这条线，更合理的优先级是：

### 第一优先级

继续盯 **control-plane correctness / operator-facing guardrails**，尤其是：

- 非交互 `preflight -> generator -> apply` 是否还有 summary / checkpoint / final status 打架的边角
- `doctor` / `resume` 是否还存在新的 truth-source 不一致
- run 级 artifact / summary / result snapshot 在更多入口下是否继续保持隔离

### 第二优先级

继续补 **最值钱、最贴近 operator 入口的真实 smoke / regression**，优先挑最容易漂移的面：

- `doctor` strategy priority / recommendation drift
- summary isolation / 相邻 run 污染
- artifact path / result registration 漂移
- README / INSTALL 推荐命令真实可达性

### 现在不值得优先做

- 不继续机械补 inspection-first 文案小变体
- 不为了“看起来更完整”去扩新 installer 功能面
- 不在没有新失稳证据时，把时间花在大量低价值 fixture 细枝末节上

---

## 8. 一句话停点结论

> 到 `4c6a56f` 为止，interactive installer 这条线已经把最近一轮 control-plane correctness / doctor truth-source / doctor golden 护栏收口完成，并已推到远端；如果现在停，这是一个适合下次直接续接的稳定停点。
