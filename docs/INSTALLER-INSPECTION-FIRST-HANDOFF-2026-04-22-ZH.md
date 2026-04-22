# Interactive Installer inspection-first 收口 handoff（2026-04-22）

> 状态：**本轮 inspection-first 收口已基本完成，可作为阶段性停点**
> 仓库：`github-mirror-template`
> 分支：`weiyusc/exp/interactive-installer`
> 远端：`origin`
> handoff 时间：2026-04-22
> 当前停点提交：`8b68f2d docs: align inspection-first terminology`

---

## 1. 这份 handoff 的用途

这不是总归档，也不是发布说明。

它只服务一个目标：

> **把 2026-04-22 这整轮 inspection-first / review-first 相关收口，压成一份下次续接时能快速恢复上下文的短入口。**

如果未来用户说“继续 interactive installer 这条 inspection-first 线”，优先先读这份，再回看更大的总归档与契约文档，而不是重新从聊天记录倒推。

---

## 2. 本轮到底收口了什么

这轮不是大改状态机，而是把同一条语义链在 **实现 / 回归 / 运行提示 / 操作手册 / 状态模型 / 结果契约 / fixture 测试说明** 几层逐步压齐。

收口的核心对象是这几类 inspection-first strategy：

- `inspect-after-apply-attention`
- `repair-review-first`
- `post-repair-verification`
- `post-rollback-inspection`

本轮最终想钉住的不是“哪句提示文案长什么样”，而是：

1. 这些 strategy 在当前实现里到底代表什么边界
2. `resume` / `doctor` 到底应该优先信哪些字段
3. companion result 与旧 `state.status.*` 冲突时谁更接近事实
4. 哪些动作允许，哪些动作必须明确拒绝
5. 哪些东西不该被当成硬机器契约

---

## 3. 当前已经稳定下来的核心结论

### 3.1 inspection-first 的主语义

当前这四类 strategy 的共同含义已经明确收紧为：

> **先复查、先看结果、先做人判断；可以 dry-run，但不默认继续真实 apply。**

更像：

- 带上下文的保守复查
- review boundary / inspection boundary

而不是：

- 一键重试执行器
- 把 `--resume` 当成真实 apply 重放快捷键

---

### 3.2 当前更可靠的字段消费顺序

本轮多个文档已经统一到同一条链：

> `state.json.lineage.resume_strategy`
> → `APPLY-RESULT.json.recovery.*`
> → `REPAIR-RESULT.json` / `ROLLBACK-RESULT.json` 的关键事实字段
> → 最后才是 `next_step`

更具体地说：

1. 先看 `lineage.resume_strategy`
2. 再看 `APPLY-RESULT.json.recovery.resume_strategy` / `resume_recommended` / `operator_action`
3. 若已有 repair 结果，优先看：
   - `REPAIR-RESULT.json.final_status`
   - `REPAIR-RESULT.json.execution.nginx_test_rerun_status`
4. 若已有 rollback 结果，优先看：
   - `ROLLBACK-RESULT.json.final_status`
   - `ROLLBACK-RESULT.json.mode`
   - `ROLLBACK-RESULT.json.flags.execute`
5. `next_step` 更适合当人类提示补充，而不是唯一机器真相源

---

### 3.3 两个关键事实信号

本轮已经明确写死的 inspection-first 关键事实字段有两个：

- `REPAIR-RESULT.json.execution.nginx_test_rerun_status=passed`
  - 是进入 `post-repair-verification` 的关键事实来源
- `ROLLBACK-RESULT.json.final_status=ok` 且 `ROLLBACK-RESULT.json.flags.execute=true`
  - 是进入 `post-rollback-inspection` 的关键事实来源

也就是说，repair / rollback companion result 不再只是“附带摘要”，而是 inspection-first 恢复语义里的正式输入。

---

### 3.4 当前允许 / 禁止动作边界

当前已统一的边界是：

#### 允许

- 复用输入与可用产物
- 显式 `--run-apply-dry-run`
- 先跑 `--doctor`
- 人工继续排查 / 复核 repair / 复核 rollback 结果
- 必要时新开 run

#### 不允许默认发生

- 把 `--resume` 理解成真实 apply 重放
- 因为 repair passed 就默认继续 execute
- 因为 rollback 完成就把现场直接视作干净起点继续 execute

#### 明确禁止

- inspection-first 策略下显式 `--execute-apply`

---

## 4. 本轮已经覆盖到哪些层

到当前停点，inspection-first 这条线已经被压进这些层次：

1. **实现层**
   - `install-interactive.sh`
   - `scripts/lib/state.sh`
2. **回归层**
   - `tests/installer-contracts-regression.sh`
3. **fixture 说明层**
   - `tests/fixtures/installer-contracts/README.md`
4. **入口总览层**
   - `README.md`
5. **操作者手册层**
   - `docs/INSTALLER-OPERATOR-RUNBOOK-ZH.md`
6. **状态模型层**
   - `docs/INSTALLER-STATE-MODEL-ZH.md`
7. **结果契约层**
   - `docs/INSTALLER-RESULT-CONTRACTS-ZH.md`

目前这些层对下面几件事已经基本对齐：

- strategy 名称写法
- observation entry 与事实来源顺序的区分
- inspection-first 的默认动作边界
- `lineage` / `recovery.*` / companion result / `next_step` 的相对优先级

---

## 5. 本轮相关关键提交（从旧 pause handoff 之后）

相对 `8aa654f docs: archive installer pause handoff`，本轮关键提交为：

1. `5f307ea` — `refactor: harden installer control-plane guardrails`
2. `e6c6451` — `test: pin resume fallback behavior for broken lineage`
3. `18a2aba` — `test: pin corrupt-json fallback behavior`
4. `a07a1e4` — `fix: harden resume inputs snapshot loading`
5. `6b09214` — `test: pin missing-field fallback behavior`
6. `a48f729` — `fix: harden type-drift contract loading`
7. `f1e4cff` — `fix: harden value-drift contract handling`
8. `4aebfee` — `fix: harden artifact drift contract handling`
9. `d4f3e21` — `fix: harden semantic drift contract handling`
10. `983b6ca` — `fix: harden resume consumer semantic drift`
11. `6476e4a` — `fix: align inspection-first resume guidance`
12. `168c2cf` — `docs: align inspection-first strategy matrix`
13. `a62c358` — `docs: clarify inspection-first result contracts`
14. `9a218e1` — `docs: align fixture README with inspection-first contracts`
15. `8b68f2d` — `docs: align inspection-first terminology`

如果只想把这一轮的演进压成一句话：

> 先把坏路径和 drift 场景打牢，再把 inspection-first 的实现语义、字段契约、操作者口径和 fixture 说明压成一套语言系统。

---

## 6. 当前不要再误绑的东西

本轮已经明确：下次如果继续，不要再把下面这些当唯一真相源：

- `state.status.final`
- `state.status.repair`
- `state.status.rollback`
- 某一句完整中文 `next_step`
- 某个 `.md` 摘要文件
- `resume_strategy_reason` 的自然语言全文

这些都可以看，但不该单独拿来决定 inspection-first 真实语义。

---

## 7. 下次续接的最短恢复路径

在仓库根目录执行：

```bash
git checkout weiyusc/exp/interactive-installer
git pull --ff-only
bash tests/installer-contracts-regression.sh
```

然后建议按顺序读：

1. `docs/INSTALLER-INSPECTION-FIRST-HANDOFF-2026-04-22-ZH.md`（本文件）
2. `docs/INSTALLER-PAUSE-HANDOFF-2026-04-21-ZH.md`
3. `docs/INSTALLER-RESULT-CONTRACTS-ZH.md`
4. `docs/INSTALLER-STATE-MODEL-ZH.md`
5. `docs/INSTALLER-OPERATOR-RUNBOOK-ZH.md`
6. `tests/fixtures/installer-contracts/README.md`

如果回归是绿的，说明当前停点仍然适合作为下一轮基线。

---

## 8. 如果以后还要继续，最值得从哪接

当前我不建议继续无脑扩文档。

如果以后恢复这条线，更合理的优先级是：

### 第一优先级

继续补**还没完全 fixture 化的 inspection-first 变体**，尤其是：

- `inspect-after-apply-attention` 的更细粒度样本
- `operator_action` / `resume_recommended` 组合边界
- source / current / ancestor 之间多层结果互相打架时的更细回归

### 第二优先级

继续补**消费层与 contract 层之间的最后一小段缝**，但仍坚持最小修复：

- 不做状态机大手术
- 不做“为了文档更漂亮”式的大改
- 只处理会误导实际 resume / doctor / operator 判断的缝

### 第三优先级

再考虑是否要做下一轮 phase roundup / 面向外部的整理，而不是现在继续抛光文风。

---

## 9. 一句话停点结论

> 到 `8b68f2d` 为止，interactive installer 这条 inspection-first 线已经从“实现有这个意思”推进到“实现、回归、结果契约、状态模型、操作手册、fixture 说明都基本讲同一种话”；如果现在停，这已经是一个干净、可恢复、可继续演化的阶段性停点。
