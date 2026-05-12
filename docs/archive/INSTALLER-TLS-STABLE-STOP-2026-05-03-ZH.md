# Interactive Installer TLS Stable Stop Archive Handoff（2026-05-03）

> 状态：**Phase 1 / 2 / 3 已形成可回放历史链；当前最新稳定停点是 Phase 3 之后又补了两个 review-first 语义修正提交**
> 仓库：`github-mirror-template`
> 分支：`weiyusc/exp/interactive-installer`
> 远端：`origin`
> 归档时间：2026-05-03
> 当前最新稳定停点提交链：
> - `4ba103f feat: formalize ACME placeholder and real-execute fixture boundaries`
> - `8f03d36 fix(tls): prefer acme result for real execute attempts`
> - `da8ff54 fix: keep acme real execute resume review-first`

---

## 1. 背景与用途

这份文档不是新用户入口，也不是 operator runbook。

它只服务一个目标：

> **把 interactive-installer 的 TLS Phase 1 → 3 以及后续两笔 review-first 语义修正，压成一次稳定停点归档，供下次恢复时快速对齐现态。**

如果下次用户说：

- “继续 interactive installer 的 TLS / ACME 这条线”
- “继续 placeholder / real execute attempt 那轮”
- “继续 doctor / resume 的 ACME companion result 语义”
- “继续 review-first / reuse-apply-plan 那个边界修正”

优先先读这份，再按文末恢复顺序进入权威文档。

---

## 2. 工作文件审计总结

### 2.1 当前权威入口（应优先视为现行真相源）

1. `docs/INSTALLER-STATE-MODEL-ZH.md`
   - 负责 `run / checkpoint / status / final / lineage / resume` 的主语义。
   - 这是理解控制面的第一入口。

2. `docs/INSTALLER-RESULT-CONTRACTS-ZH.md`
   - 负责 JSON / result artifact 的职责边界。
   - 特别是 `ISSUE-RESULT.json` 与 `ACME-ISSUANCE-RESULT.json` 的分工红线。

3. `docs/INSTALLER-OPERATOR-RUNBOOK-ZH.md`
   - 负责 operator 实操顺序。
   - 当前 `doctor` / `state.json` / companion result / `--resume` 的阅读与禁行动作应以它为准。

4. `docs/INSTALLER-NEXT-STAGE-BACKLOG-ZH.md`
   - 当前后续工作优先级入口。
   - 比 `docs/INSTALLER-REFACTOR-ROADMAP-ZH.md` 更贴近现在的收口状态。

### 2.2 阶段归档 / 历史材料（保留，但不再作为现态总入口）

- `docs/INSTALLER-TLS-PHASE1-HANDOFF-2026-05-01-ZH.md`
  - 记录 TLS mode / TLS plan contract 的正式起点。
- `docs/INSTALLER-TLS-PHASE2-HANDOFF-2026-05-02-ZH.md`
  - 记录 conservative issue helper 与 execute placeholder 分叉语义。
- `docs/INSTALLER-TLS-PHASE3-HANDOFF-2026-05-02-ZH.md`
  - 记录显式 placeholder marker 与 synthetic non-placeholder fixture 边界收口。
  - 但它停在 `4ba103f`，**不再足以代表当前最新现态**。
- `docs/INSTALLER-REFACTOR-ROADMAP-ZH.md`
  - 更适合视为 2026-04-21 的战略背景文档。
  - 其中部分 P0/P1 已完成或被后续 backlog 吸收，不宜再当现行入口。

### 2.3 最近提交链的现态含义

最近 12 个提交里，与当前停点最相关的是：

- `4ba103f feat: formalize ACME placeholder and real-execute fixture boundaries`
- `ef9a454 docs(tls): add phase-3 handoff and continue prompt`
- `8605a01 docs(tls): remove checked-in continue prompt`
- `8f03d36 fix(tls): prefer acme result for real execute attempts`
- `da8ff54 fix: keep acme real execute resume review-first`

这说明当前现态已经不是“单纯 Phase 3 完成”，而是：

> **Phase 3 contract / fixture 边界收口之后，又补了 doctor 优先阅读顺序与 resume review-first override。**

---

## 3. 当前最新稳定停点

当前最准确的停点描述应是：

> **控制面语义已进一步收紧到 review-first，不再把 non-placeholder ACME real-execute-attempt 误当成可直接续跑的 execute 断点；但 runtime 仍停留在 contract / test / fixture 层，尚未进入真实签发实现。**

### 3.1 当前已经稳定成立的事实

1. `ACME-ISSUANCE-RESULT.json` 已显式区分两类语义：
   - placeholder conservative execute skeleton
   - non-placeholder future real-execute-attempt

2. `doctor` 在 non-placeholder blocked / needs-attention 场景下：
   - 已优先指向 `ACME-ISSUANCE-RESULT.json`
   - 不再退回泛化的 `APPLY-PLAN.json`

3. `resume` 在 non-placeholder ACME real-execute-attempt 场景下：
   - 会直接落到 `inspect-after-acme-real-execute-attempt`
   - 默认按 **review-first** 理解
   - 不把 resume 当成真实签发或真实 apply 的续跑入口
   - 且显式 `--execute-apply` 会被直接拒绝

4. `tests/installer-contracts-regression.sh`、`tests/installer-smoke.sh`、`tests/deploy-config-yaml-regression.sh`、`tests/installer-doctor-golden.sh` 均已真实验证通过，并已随提交推到远端。

### 3.2 当前明确还没有做的事

这条线**仍然没有**做：

- 不真实调用 `acme.sh` / `certbot`
- 不完成 HTTP-01 challenge fulfillment
- 不落盘真实证书 / 私钥 / fullchain
- 不接 live nginx challenge / deploy
- 不把真实 issuance 成果正式接进 apply / deploy 生命周期

一句话：

> **当前完成的是 control-plane / contract clarity，不是 ACME runtime completeness。**

---

## 4. 已钉死的语义红线

### 4.1 `ISSUE-RESULT.json` ≠ real issuance outcome

`ISSUE-RESULT.json` 仍只表示：

- planning
- evidence
- conservative boundary

它**不是**真实签发结果容器。

### 4.2 placeholder ≠ non-placeholder real-execute-attempt

当前必须靠显式字段区分：

- `placeholder.is_placeholder=true` → conservative execute placeholder
- `placeholder.is_placeholder=false` 且 `intent.result_role=real-execute-attempt` / `intent.real_execution_performed=true` / `execution.client_invoked=true` → non-placeholder future real-execute-attempt

不能再靠 `final_status=blocked` 这种宽条件糊推。

### 4.3 non-placeholder blocked execute attempt 仍是 review-first

这是当前最容易被误读的一条：

- 当前会直接进入 `inspect-after-acme-real-execute-attempt`
- 只要源运行带有 non-placeholder ACME real-execute-attempt companion result
- 当前恢复语义就按 **review-first** 理解
- 不把 resume 当成真实签发 / 真实 apply 的续跑入口
- 显式 `--execute-apply` 会被直接拒绝

---

## 5. 当前仍适合保留的历史 handoff 索引

### Phase 1

文件：`docs/INSTALLER-TLS-PHASE1-HANDOFF-2026-05-01-ZH.md`

保留价值：

- TLS mode 正式引入
- TLS plan artifact contract 成型
- `acme-http01` / `acme-dns-cloudflare` 的 scaffolding 边界被明确写死

### Phase 2

文件：`docs/INSTALLER-TLS-PHASE2-HANDOFF-2026-05-02-ZH.md`

保留价值：

- `acme-issue-http01.sh` 形成 conservative helper
- `ISSUE-RESULT.json` 与 `ACME-ISSUANCE-RESULT.json` 分叉正式建立
- `inspect-after-acme-placeholder` 进入 doctor / resume / docs / regression

### Phase 3

文件：`docs/INSTALLER-TLS-PHASE3-HANDOFF-2026-05-02-ZH.md`

保留价值：

- 显式 placeholder marker 正式落地
- synthetic non-placeholder real-execute-attempt fixture 正式固化
- 回归从运行时 mutation 走向正式 fixture

限制：

- 该文档停点写在 `4ba103f`
- 没覆盖 `8f03d36` 与 `da8ff54` 带来的“doctor 优先读 ACME + resume review-first override”这层现态

---

## 6. 恢复顺序与验证入口

### 6.1 下次恢复时建议先读的文件

1. `docs/archive/INSTALLER-TLS-STABLE-STOP-2026-05-03-ZH.md`（本文件）
2. `docs/INSTALLER-TLS-PHASE3-HANDOFF-2026-05-02-ZH.md`
3. `docs/INSTALLER-RESULT-CONTRACTS-ZH.md`
4. `docs/INSTALLER-OPERATOR-RUNBOOK-ZH.md`
5. `docs/INSTALLER-STATE-MODEL-ZH.md`
6. `docs/INSTALLER-NEXT-STAGE-BACKLOG-ZH.md`

### 6.2 下次恢复时先跑的验证

在仓库根目录执行：

```bash
git checkout weiyusc/exp/interactive-installer
git pull --ff-only
bash tests/installer-contracts-regression.sh
bash tests/installer-doctor-golden.sh
bash tests/installer-smoke.sh
bash tests/deploy-config-yaml-regression.sh
```

如果四条回归都为绿，说明当前稳定停点没有漂。

---

## 7. 风险与口径提醒

### 7.1 `docs/INSTALLER-STATE-MODEL-ZH.md` 对最新 override 仍有滞后风险

当前代码里已经存在：

- nominal strategy 可能还是 `reuse-apply-plan`
- 但只要源运行带有 non-placeholder ACME real-execute-attempt
- effective 行为仍是 review-first，并拒绝 `--execute-apply`

这层语义在本归档里已经明确，但在 State Model 文档里还没有完整吸收成同等强度的主叙述。

### 7.2 `docs/INSTALLER-TLS-PHASE3-HANDOFF-2026-05-02-ZH.md` 是最新历史 handoff，不是最新现态文档

它仍然有价值，但不能再单独当作“当前停点总入口”。

### 7.3 `docs/INSTALLER-REFACTOR-ROADMAP-ZH.md` 不能再当主优先级入口

因为其中多项 P0/P1：

- 最小 CI
- smoke 护栏
- state model
- contract 收口

已经不同程度落地。

### 7.4 旧 continue prompt 引用现在都应视为过时

最近已有：

- `8605a01 docs(tls): remove checked-in continue prompt`

因此如果外部笔记或旧交接还引用 `INSTALLER-TLS-PHASE3-CONTINUE-PROMPT-2026-05-02-ZH.md`，现在应一律按过时引用处理。

---

## 8. 下次启动项目的提示词

> 继续 `github-mirror-template` 的 `weiyusc/exp/interactive-installer` 分支，先把 interactive-installer 的 TLS / ACME 这条线恢复到 2026-05-03 的最新稳定停点。先读 `docs/archive/INSTALLER-TLS-STABLE-STOP-2026-05-03-ZH.md`，再读 `docs/INSTALLER-TLS-PHASE3-HANDOFF-2026-05-02-ZH.md`、`docs/INSTALLER-RESULT-CONTRACTS-ZH.md`、`docs/INSTALLER-OPERATOR-RUNBOOK-ZH.md`、`docs/INSTALLER-STATE-MODEL-ZH.md`。先运行 `bash tests/installer-contracts-regression.sh && bash tests/installer-doctor-golden.sh && bash tests/installer-smoke.sh && bash tests/deploy-config-yaml-regression.sh` 确认基线全绿。当前现态不是单纯 Phase 3，而是已经包含 `8f03d36` 与 `da8ff54`：non-placeholder ACME real-execute-attempt 必须按 effective review-first 理解，哪怕 nominal strategy 仍可能显示 `reuse-apply-plan`；不得把 resume 当成真实签发或真实 apply 的续跑入口，显式 `--execute-apply` 应保持拒绝。恢复后先做事实审计与口径对齐，再决定下一刀是继续补 state-model / docs 对最新 override 的收口，还是进入真实 ACME execute 路径设计。`

---

## 9. 一句话交接

> **这条线当前最稳的停点，不是“快接通真实 ACME 了”，而是“已经把 placeholder / non-placeholder / review-first 的控制面边界钉得更牢，下一次续接不该再从误判恢复语义开始返工”。**
