# Interactive Installer inspection-first 收口 handoff（2026-04-22）

> 状态：**本轮 inspection-first 收口已基本完成，可作为阶段性停点**
> 仓库：`github-mirror-template`
> 分支：`weiyusc/exp/interactive-installer`
> 远端：`origin`
> handoff 时间：2026-04-22
> 当前停点提交：`4bb1ef5 fix: allow resume before noninteractive validation`

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

如果只想把这一轮的演进压成一句话：

> 先把坏路径和 drift 场景打牢，再把 inspection-first 的实现语义、字段契约、操作者口径和 fixture 说明压成一套语言系统；最后再把 direct CLI invocation 也真正收口到同一套保护边界里。

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

> 到 `4bb1ef5` 为止，interactive installer 这条 inspection-first 线已经从“实现有这个意思”推进到“实现、回归、结果契约、状态模型、操作手册、fixture 说明、CLI 入口行为都基本讲同一种话”；如果现在停，这已经是一个干净、可恢复、可继续演化的阶段性停点。

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
- 当前会自动执行 contract regression、真实 CLI smoke、deploy-config YAML regression

因此更自然的后续工作是：

1. 保持 workflow 与 README / INSTALL 里的本地推荐回归入口一致
2. 新增高价值 regression 时，优先纳入现有 workflow
3. 定期清理 handoff / roadmap 里的过期 TODO，避免下次续接被旧优先级带偏

### 10.4 第四优先级：修 YAML 写入方式

`scripts/lib/config.sh` 里的 `write_deploy_config()` 如果仍是手工拼 YAML，那么这笔债仍然成立。

更合理的方向是：

- 保留 shell 入口
- 但把 YAML 写入改成安全序列化
- 避免特殊字符、注释符、多行值、边界空白把配置语义悄悄写坏

这件事不一定像 P0 那样立刻阻塞，但属于“迟早会咬人、而且修法明确”的问题，值得在 smoke / CI 之后尽快处理。

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

