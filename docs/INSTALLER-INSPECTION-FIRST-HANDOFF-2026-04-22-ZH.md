# Interactive Installer inspection-first 收口 handoff（2026-04-22，2026-04-28 refreshed）

> 状态：**inspection-first 主线已收口，当前停在最近一轮可靠性维护后的稳定基线**
> 仓库：`github-mirror-template`
> 分支：`weiyusc/exp/interactive-installer`
> 远端：`origin`
> handoff 时间：2026-04-28（首版 2026-04-22）
> 当前停点提交：`0633d07 test: wire summary isolation regression into CI`

---

## 1. 这份 handoff 的用途

这不是总归档，也不是发布说明。

它只服务一个目标：

> **把 2026-04-22 这整轮 inspection-first / review-first 相关收口，压成一份下次续接时能快速恢复上下文的短入口。**

如果未来用户说“继续 interactive installer 这条 inspection-first 线”，优先先读这份，再回看更大的总归档与契约文档，而不是重新从聊天记录倒推。

> 2026-04-28 refresh 说明：最近几笔本地提交不是新开功能面，而是沿着既有 inspection-first / control-plane 线继续补可靠性护栏；把最新停点继续收口在这份 handoff 里，比改写更宽的 roadmap 更利于下次直接恢复上下文。

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

### 3.5 当前新增确认的 CLI 入口结论

在本轮最后一刀里，又额外确认并修掉了一个此前容易被忽略的 **CLI 入口顺序问题**：

- `install-interactive.sh` 之前会在识别 `--resume` / `--doctor` 之前，先按默认 `INSTALLER_MODE="new"` 执行 `validate_noninteractive_requirements(...)`
- 这会导致用户从真实 CLI 入口直跑：

```bash
./install-interactive.sh --resume <run_id> --execute-apply --yes
```

时，可能还没进入 resume 语义分支，就先误报：

- `缺少必填参数：--deployment-name`

这不是 inspection-first refusal 文案问题，而是 **effective mode 决定时机** 的真实 bug。

当前已完成的最小修复是：

1. 先做 `--doctor` / `--resume` 的互斥检查
2. 先根据 flags 决定 effective `INSTALLER_MODE`（`doctor` / `resume` / `new`）
3. 再执行 `validate_noninteractive_requirements(...)`

这使得：

- `--resume` 不再被 new-run 的非交互必填参数校验误伤
- `--doctor` 路径也不再走错校验分支
- inspection-first resumed run 下显式 `--execute-apply` 的拒绝逻辑，终于从**实现上存在**变成**真实 CLI 入口可达且已被 regression 钉住**

这条结论值得单独记住，因为它说明：

> 当前 inspection-first 的 execute refusal 不只是内部函数层面的语义，而是已经真正闭环到 direct CLI invocation。

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
16. `b604f80` — `docs: add inspection-first handoff`
17. `551cebd` — `test: pin inspect-after-apply-attention coverage`
18. `448b913` — `docs: surface inspect-after-apply-attention in README`
19. `cac0b17` — `docs: clarify inspection-first resume messaging`
20. `4bb1ef5` — `fix: allow resume before noninteractive validation`

如果只想把 2026-04-22 这一轮的演进压成一句话：

> 先把坏路径和 drift 场景打牢，再把 inspection-first 的实现语义、字段契约、操作者口径和 fixture 说明压成一套语言系统；最后再把 direct CLI invocation 也真正收口到同一套保护边界里。

在 `48a8a74 docs: refresh installer handoff and roadmap stop points` 之后，又沿同一条线补了 7 个可靠性维护提交：

1. `66dfed1` — `fix: isolate per-run installer summary snapshots`
2. `5e5a895` — `fix: snapshot preflight and config artifacts per run`
3. `884a7d7` — `test: lock per-run artifact snapshot contracts`
4. `0ad3f8e` — `test: cover doctor strategy priority semantic drift`
5. `0fdc51d` — `fix: align doctor suggestion priority with inspection-first strategy`
6. `afcb30d` — `test: extend deploy config yaml boundary samples`
7. `0633d07` — `test: wire summary isolation regression into CI`

这 7 笔的含义不是继续扩功能面，而是把已有 control-plane 语义再压实一层：

- 每轮 run 的 `INSTALLER-SUMMARY.generated.json`、`preflight.generated.{md,json}`、`deploy.generated.yaml` 继续保持 run 级隔离
- `state.json.artifacts.*` 明确指回当前 run 自己的快照，而不是相邻 run 的产物
- `doctor` 的 suggestion priority 与 inspection-first 策略边界继续对齐
- deploy config YAML regression 额外钉住 `true` / `null` / `00123` / 多行值 / 空字符串 / 边界空白 这类最容易回退的 writer 样本
- summary isolation regression 已进入 CI，不再只是本地额外自觉运行

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
bash tests/deploy-config-yaml-regression.sh
bash tests/installer-smoke.sh
bash tests/installer-summary-isolation.sh
bash tests/installer-contracts-regression.sh
```

然后建议按顺序读：

1. `docs/INSTALLER-INSPECTION-FIRST-HANDOFF-2026-04-22-ZH.md`（本文件）
2. `docs/INSTALLER-PAUSE-HANDOFF-2026-04-21-ZH.md`
3. `docs/INSTALLER-RESULT-CONTRACTS-ZH.md`
4. `docs/INSTALLER-STATE-MODEL-ZH.md`
5. `docs/INSTALLER-OPERATOR-RUNBOOK-ZH.md`
6. `tests/fixtures/installer-contracts/README.md`

如果这 4 条回归都为绿，说明当前停点仍然适合作为下一轮基线。

---

## 8. 如果以后还要继续，最值得从哪接

当前我不建议继续无脑扩文档，也不建议在这个停点继续补零碎功能。

如果以后恢复这条线，更合理的优先级是：

### 第一优先级

继续盯 **control-plane correctness / artifact isolation**，尤其是：

- 非交互 `preflight -> generator -> apply` 串通是否还存在脆弱点
- 提前退出 / on-exit summary / `status.final` / `checkpoint` 是否还有互相打架的边角
- run 级 summary / preflight / config snapshot 是否在更多路径下都保持隔离
- `doctor` / `resume` 所依赖 run 的可信度是否继续稳定

### 第二优先级

继续补 **最值钱、最贴近 operator 入口的真实 CLI smoke / regression**，但要优先挑最容易漂移的入口：

- summary isolation 的相邻 run 污染场景
- `doctor` suggestion priority 与 inspection-first strategy 的对齐场景
- deploy config writer/readback 的高风险边界样本
- 任何会影响 `README` / `INSTALL` 推荐命令的真实入口

所以这一步的重点不是“补更多测试数量”，而是“补最可能把停点带偏的入口级护栏”。

### 第三优先级

维护 **现有 CI / 文档停点 / roadmap 口径同步**：

- 保持 `.github/workflows/installer-regressions.yml` 与本地推荐回归入口一致
- 新增高价值 regression 时优先纳入现有 workflow
- 定期刷新 handoff / roadmap，避免把已完成护栏重新写回未来 TODO

### 现在不值得优先做

- 不继续机械补 inspection-first 文案小变体或 fixture 说明枝节
- 不为了“看起来更完整”去扩新的 installer 功能面
- 不急着做 Python 化 / 大规模 Bash 拆分 / 大规模文档搬家
- 不在没有新失稳证据的前提下，把时间花在零碎测试补丁上替代现有入口级护栏

---

## 9. 一句话停点结论

> 到 `0633d07` 为止，interactive installer 这条线已经把 inspection-first 的实现/契约/文档收口，进一步补齐了 per-run summary 与 artifact snapshot 隔离、doctor suggestion priority 对齐、deploy config YAML 边界样本，以及把 summary isolation regression 接进 CI；如果现在停，这是一个比继续补零碎测试更适合续接的稳定停点。

---

## 10. 如果下次不是继续补 inspection-first，而是重开整个 installer 改造，建议顺序

这部分是给“以后回来时先做什么”准备的超短附录。

当前判断是：**inspection-first 这条线已经够停，不值得继续机械补 fixture / 文案；更高杠杆的后续工作已经转回 control-plane 可靠性与工程护栏。**

如果下次恢复开发，建议按这个顺序重开：

### 10.1 第一优先级：先查非交互 happy path / summary 可靠性

先验证并收口这些问题：

- `preflight -> generator -> apply` 是否能在非交互路径稳定串通
- 是否还存在提前退出却写出误导性 success summary 的情况
- `checkpoint` / `status.final` / `INSTALLER-SUMMARY.generated.json` 是否仍可能互相打架

这条优先级高于继续补 inspection-first 变体，因为它直接影响：

- operator 对“是否执行成功”的判断
- `doctor` / `resume` 所依赖的 run 可信度
- 后续 smoke / CI 是否有可靠主路径可钉

### 10.2 第二优先级：继续扩真实 CLI smoke / integration tests

这块在 2026-04-23 前后已经不是空白：

- 已有 `bash tests/installer-smoke.sh`
- 已覆盖真实非交互 happy path / execute `needs-attention` / inspection-first resume refusal / generator fail-fast

所以下一步不再是“从 0 到 1 补 smoke”，而是：

- 继续挑**最值钱、最容易漂移**的入口补回归
- 让 smoke 断言始终对齐实现真相源，而不是沿用过期 fixture/文案假设
- 在补新 smoke 时，顺手检查 contract regression / fixture README 是否也要同步更新

### 10.3 第三优先级：维护已接入的 CI 护栏

这块同样已不是未来事项：

- 仓库已有 `.github/workflows/installer-regressions.yml`
- 当前会自动执行 deploy-config YAML regression、真实 CLI smoke、summary isolation regression 与 contract regression

因此更自然的后续工作是：

1. 保持 workflow 与 README / INSTALL 里的本地推荐回归入口一致
2. 新增高价值 regression 时，优先纳入现有 workflow
3. 定期清理 handoff / roadmap 里的过期 TODO，避免下次续接被旧优先级带偏

### 10.4 第四优先级：维护 YAML 序列化 regression，而不是重复规划已完成迁移

`scripts/lib/config.sh` 里的 `write_deploy_config()` 现已改为安全序列化，不再是手工拼 YAML。

更合理的后续重点是：

- 保留 shell 入口 + Python/PyYAML writer 这条分工
- 持续用 regression 钉住特殊字符、注释符、多行值、边界空白、YAML-like scalars 等样本
- 新增字段时优先补回归，避免后续重构把序列化悄悄写回退

这件事不再是“要不要迁移 writer”的方向选择，而是“如何让已完成的安全序列化持续不回退”的维护问题，仍值得在 smoke / CI 之后持续跟着走。

### 10.5 第五优先级：最后再整理文档信息架构

文档入口层级混杂这个问题仍然成立，但当前不应抢在可靠性问题之前处理。

更合理的节奏是：

1. 先修 correctness
2. 再补自动护栏
3. 再清明确技术债
4. 最后才整理文档入口分层

如果以后真要整理，建议至少分成：

- 用户入口
- operator 文档
- architecture / design
- archive / handoff

### 10.6 一句话重开原则

> 先修可靠性，再补自动护栏，再清技术债，最后整理文档。

