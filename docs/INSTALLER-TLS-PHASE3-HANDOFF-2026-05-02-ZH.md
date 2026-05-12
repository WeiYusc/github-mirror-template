# Interactive Installer TLS Phase 3 handoff（2026-05-02）

> 状态：**ACME placeholder marker / formalized real-execute synthetic fixture 边界已收口并推到远端**
> 仓库：`github-mirror-template`
> 分支：`weiyusc/exp/interactive-installer`
> 远端：`origin`
> handoff 时间：2026-05-02
> 本轮代码停点提交：`4ba103f feat: formalize ACME placeholder and real-execute fixture boundaries`

---

## 1. 这份 handoff 的用途

这份 handoff 只服务一个目标：

> **把 TLS Phase 3 这轮“显式 placeholder marker + 正式 synthetic non-placeholder fixture + regression 改为固定样本”的工作，压成下一次能直接续接的短入口。**

如果下次用户说：

- “继续 interactive installer 的 TLS / ACME 这条线”
- “继续 placeholder 和 real execute attempt 那轮”
- “继续 doctor / resume 的 ACME companion result 语义”
- “继续 future real execute attempt 的 contract”

优先先读这份，再回看：

- `docs/INSTALLER-TLS-PHASE2-HANDOFF-2026-05-02-ZH.md`
- `docs/INSTALLER-TLS-PHASE1-HANDOFF-2026-05-01-ZH.md`
- `docs/INSTALLER-RESULT-CONTRACTS-ZH.md`
- `docs/INSTALLER-STATE-MODEL-ZH.md`
- `docs/INSTALLER-OPERATOR-RUNBOOK-ZH.md`

---

## 2. 这轮到底完成了什么

这轮完成的不是“真实 ACME execute 接通”，而是把 **placeholder 与 future real execute attempt 的边界从宽条件推断，升级成显式 contract 驱动**。

### 已落地的能力

1. `acme-issue-http01.sh --execute` 产出的 `ACME-ISSUANCE-RESULT.{md,json}` 已新增显式 placeholder marker：
   - `placeholder.is_placeholder=true`
   - `placeholder.placeholder_kind=conservative-execute-skeleton`
   - `placeholder.review_required=true`
   - `placeholder.source_of_truth=explicit-placeholder-marker`

2. `state.sh` 内对 `inspect-after-acme-placeholder` 的判定不再靠宽条件猜测：
   - 不再靠 `final_status=blocked` 这类宽条件就把结果误判回 placeholder
   - 现在优先依赖显式 `placeholder.*` + `intent.*` + `execution.*` 组合

3. `doctor` 输出已显式打印 placeholder 摘要：
   - `placeholder.is_placeholder`
   - `placeholder.placeholder_kind`
   - `placeholder.review_required`

4. `fixture-tls-acme-http01` 的 companion result 已正式固化进模板：
   - `ISSUE-RESULT.{md,json}`
   - `ACME-ISSUANCE-RESULT.{md,json}`

5. 仓库内已新增正式 synthetic fixture：
   - `fixture-tls-acme-real-execute-attempt`
   - 它是 **non-placeholder future real execute attempt** 样本
   - 仅用于守住 contract / doctor / resume 边界
   - **不代表真实 ACME client 已接通**

6. regression 已从“运行时临时 python mutation 改 JSON”切换成“直接消费正式 fixture”：
   - contract regression
   - doctor golden
   - fixture README / 文档说明

7. regression harness 还顺手修了一个真实问题：
   - 原本固定 `runs.test-backup` 的备份目录在重复跑/嵌套跑时会相互踩
   - 现在改成带随机后缀的临时备份目录，避免 rerun 套娃冲突

---

## 3. 这轮最重要的语义边界

### 3.1 placeholder 和 future real execute attempt 现在必须靠显式字段区分

当前稳定边界：

#### A. conservative execute placeholder

适用于 `fixture-tls-acme-http01` 这类当前 helper `--execute` 语义：

- `placeholder.is_placeholder=true`
- `placeholder.placeholder_kind=conservative-execute-skeleton`
- `placeholder.review_required=true`
- `intent.result_role=execute-placeholder`
- `intent.real_execution_performed=false`
- `execution.client_invoked=false`

这类结果允许 `doctor` / `resume` 进入：

- `inspect-after-acme-placeholder`

#### B. synthetic non-placeholder future real execute attempt

适用于 `fixture-tls-acme-real-execute-attempt`：

- `placeholder.is_placeholder=false`
- `placeholder.placeholder_kind=future-real-execute`
- `placeholder.review_required=false`
- `intent.result_role=real-execute-attempt`
- `intent.real_execution_performed=true`
- `execution.client_invoked=true`

这类结果的核心目标不是代表“真实已成功签发”，而是守住：

> **即使 `final_status=blocked`，也不能再被宽条件误判回 placeholder。**

同时，在当前策略模型里，`doctor` / `resume` 会把这类样本直接收口到：

- `inspect-after-acme-real-execute-attempt`

也就是说，后续重点应是先复核 `ACME-ISSUANCE-RESULT.json` / `ISSUE-RESULT.json` / operator prerequisites，而不是再把它解释回 `reuse-apply-plan + override` 那套旧口径。

### 3.2 `ISSUE-RESULT.json` 和 `ACME-ISSUANCE-RESULT.json` 的分工继续成立

- `ISSUE-RESULT.json`
  - 仍只承载 planning / evidence 语义
  - 不代表真实 execute outcome

- `ACME-ISSUANCE-RESULT.json`
  - 承载 execute companion result 语义
  - 当前既可能是 conservative placeholder，也可能是 synthetic future real execute attempt
  - 但两者都不代表“真实 ACME runtime 已完整接通”

### 3.3 当前做完的是 contract clarity，不是 runtime completeness

这轮仍然**没有**做：

- 不真实调用 `acme.sh` / `certbot`
- 不真正完成 HTTP-01 challenge fulfillment
- 不落盘真实证书/私钥
- 不接 live nginx deploy
- 不把成功 issue 结果接进 apply/deploy 生命周期

换句话说：

> 这轮重点是把 companion result 的语义边界钉死，而不是把 ACME execute 做完。

---

## 4. 本轮关键提交

### 本轮代码收口提交

- `4ba103f feat: formalize ACME placeholder and real-execute fixture boundaries`

### 这笔提交实际收进去的内容

- `acme-issue-http01.sh`：显式 placeholder marker
- `scripts/lib/state.sh`：placeholder 判定改成显式 marker 驱动，并在 doctor 中打印 placeholder 摘要
- `docs/INSTALLER-OPERATOR-RUNBOOK-ZH.md`
- `docs/INSTALLER-RESULT-CONTRACTS-ZH.md`
- `docs/INSTALLER-STATE-MODEL-ZH.md`
- `tests/fixtures/installer-contracts/README.md`
- `tests/installer-contracts-regression.sh`
- `tests/installer-doctor-golden.sh`
- `fixture-tls-acme-http01` 的 companion result 固化
- `fixture-tls-acme-real-execute-attempt` 全套正式样本
- doctor golden 更新/新增

---

## 5. 已确认通过的验证

在本轮代码提交前，已确认通过：

```bash
bash tests/installer-contracts-regression.sh
bash tests/installer-doctor-golden.sh
bash tests/installer-smoke.sh
bash tests/deploy-config-yaml-regression.sh
```

当前稳定结论：

> 代码停点不是“工作区里看起来对”，而是已经在本地通过关键回归后提交，并已 push 到远端。

---

## 6. 下次续接的最短恢复路径

在仓库根目录执行：

```bash
git checkout weiyusc/exp/interactive-installer
git pull --ff-only
bash tests/installer-contracts-regression.sh
bash tests/installer-doctor-golden.sh
bash tests/installer-smoke.sh
bash tests/deploy-config-yaml-regression.sh
```

然后建议按下面顺序读：

1. `docs/INSTALLER-TLS-PHASE3-HANDOFF-2026-05-02-ZH.md`（本文件）
2. `docs/INSTALLER-TLS-PHASE2-HANDOFF-2026-05-02-ZH.md`
3. `docs/INSTALLER-TLS-PHASE1-HANDOFF-2026-05-01-ZH.md`
4. `docs/INSTALLER-RESULT-CONTRACTS-ZH.md`
5. `docs/INSTALLER-STATE-MODEL-ZH.md`
6. `docs/INSTALLER-OPERATOR-RUNBOOK-ZH.md`

如果四条回归都为绿，说明 Phase 3 停点仍然可靠。

---

## 7. 下一步最值得从哪接

当前最自然的下一刀，不是直接猛接真实签发，而是继续保持保守边界，优先把 **future real execute attempt 的策略槽位与 operator 语义** 补清。

> 这部分现已进一步收口为独立策略 `inspect-after-acme-real-execute-attempt`；后续如果再往前推进，应在这个独立策略与 companion contract 已稳定的前提下，再考虑真实 ACME runtime 接线。

### 推荐下一刀

1. 明确 non-placeholder future real execute attempt 对 `doctor` / `resume` 的默认策略
   - 当前只守住“不再误判成 placeholder”
   - 但还没有形成清晰的独立 strategy 命名与 operator hint

2. 决定是否需要新增独立 strategy，例如：
   - `inspect-after-real-execute-attempt`
   - 或继续复用更泛化的 inspection-first 语义，但要明确文档与提示

3. 补足 contract / doctor / resume 对 non-placeholder blocked execute attempt 的稳定解释：
   - 当前 `blocked` 但 `client_invoked=true` 的语义应该如何展示
   - 当前 `next_step` / `priority_artifact` / operator hint 应该落在哪个 companion result

4. 只有在这层 control-plane 讲清后，再考虑真实 ACME runtime 接线：
   - challenge strategy
   - client adapter
   - output artifact materialization
   - deploy handoff

### 不建议直接做的事

- 不建议跳过这层 strategy / operator 语义，直接把 `acme.sh` / `certbot` 接进来
- 不建议再回到“靠 `final_status=blocked` 猜语义”的宽条件逻辑
- 不建议把 synthetic fixture 当成真实 runtime 能力已经存在的证据

---

## 8. 一句话总结

当前停点的真正价值不是“又多了一个 fixture”，而是：

> **ACME companion result 现在已经正式区分“显式 placeholder”与“non-placeholder future real execute attempt”，doctor / resume / regression 不再靠宽条件瞎猜。**
