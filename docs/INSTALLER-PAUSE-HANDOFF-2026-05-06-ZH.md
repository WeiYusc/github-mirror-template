# Interactive Installer 阶段性暂停 handoff（2026-05-06）

> 状态：**可安全阶段性暂停；当前更适合先归档停点，而不是继续扩 ACME / installer 改动**
> 仓库：`github-mirror-template`
> 分支：`weiyusc/exp/interactive-installer`
> 参考停点提交：`5e3d58f refactor(resume): align execute gating with review boundary`
> handoff 时间：2026-05-06 09:43 CST

---

## 1. 这份 handoff 的用途

这份文档服务一个很具体的目标：

> **把 2026-05-05 ~ 2026-05-06 这一轮围绕 review-boundary truth-source、inspection-first execute gating，以及 ACME 下一刀审计的阶段性停点压成一个下次可直接恢复的入口。**

这不是总归档，也不是从零理解 installer 的总导航。

如果下次用户说：

- “继续 interactive installer 最近这轮”
- “继续 execute gating / review boundary 那几刀”
- “继续 ACME placeholder / real execute attempt 那条 smoke 覆盖线”
- “继续 installer 现在最值得补的下一刀”

优先先读这份，再回看：

1. `docs/INSTALLER-TLS-PHASE3-HANDOFF-2026-05-02-ZH.md`
2. `docs/INSTALLER-CONTROL-PLANE-HANDOFF-2026-04-29-ZH.md`
3. `docs/INSTALLER-PAUSE-HANDOFF-2026-04-21-ZH.md`
4. `docs/INSTALLER-RESULT-CONTRACTS-ZH.md`
5. `docs/INSTALLER-STATE-MODEL-ZH.md`

---

## 2. 当前为什么可以暂停

当前停在这里是安全的，原因很明确：

### 2.1 最近三刀主收口已经完成并有回归支撑

最近已完成并记录在 `TASKS.md` 的三刀是：

1. `resume strategy truth-source cut 8`
2. `shell control-plane truth-source cut 9`
3. `execute-gating + install-doc alignment cut 10`

这三刀已经把下面这些关键点收口过一轮：

- `state.sh` / `install-interactive.sh` 对 inspection-first / review-first 边界的 truth-source 对齐
- execute refusal / warning helper 收口，避免 shell 侧继续散落重复语义
- `INSTALL.md` 对 inspection-first 六类口径与矩阵补齐
- contract regression / smoke 闸门维持为绿

### 2.2 这轮新发现的“下一刀”还停留在审计结论，不是半落地代码

本轮额外审计了 ACME 相关两类 fixture 的真实 CLI 行为：

- `fixture-tls-acme-http01`
- `fixture-tls-acme-real-execute-attempt`

结论是：

> **当前最值得继续补的，不是主逻辑改造，而是把这两类 ACME `review-first / inspection-first` 续接路径，补进 `tests/installer-smoke.sh` 的 smoke 级 CLI 覆盖。**

但这个结论目前仍停在“已审计、已验证候选断言、尚未落正式代码改动”的阶段，因此现在暂停是干净的：

- 没有未收口的主逻辑改动
- 没有半改到一半的测试文件
- 没有新的未验证功能分支落地

### 2.3 当前工作树实际上没有新增代码改动包袱

阶段性暂停时，仓库可见状态是：

- 分支仍为 `weiyusc/exp/interactive-installer`
- 相对远端 `origin/weiyusc/exp/interactive-installer` 为 `ahead 6`
- 本轮暂停前，工作树里真正的项目级改动主要是本地 `TASKS.md` 记录

换句话说：

> **现在暂停不会把仓库卡在“逻辑改了一半、测试没落、文档没补”的坏状态。**

---

## 3. 本轮已经确认到的关键结论

### 3.1 ACME 下一刀的最佳方向

当前最值得继续的下一刀是：

> **为 `fixture-tls-acme-http01` 与 `fixture-tls-acme-real-execute-attempt` 增补 smoke 级 CLI 覆盖，而不是继续改 installer 主逻辑。**

原因：

- contract regression 已经覆盖了不少 contract / strategy 语义
- 但 smoke 级 CLI 还没有把这两类 ACME review-first 续接路径真正钉住
- 这块最接近真实 operator 入口，价值比继续重构逻辑更高

### 3.2 已审计到的稳定行为（可直接作为下次断言素材）

#### A. `fixture-tls-acme-http01`

执行：

```bash
bash install-interactive.sh --resume fixture-tls-acme-http01 --run-apply-dry-run --yes
```

当前已确认的稳定行为：

- 会新建新的 run 目录
- `stdout` 会打印：
  - `本次 resume 策略：inspect-after-acme-placeholder`
  - `review-first 续接`
- `stderr` 会打印：
  - `inspect-after-acme-placeholder / review-first 续接`
  - `默认不会直接执行真实 apply`
  - `[BLOCK] 缺少部署包目录`
- `state.json` 侧：
  - `lineage.resume_strategy=inspect-after-acme-placeholder`
  - `status.apply_dry_run=failed`
  - `status.apply_execute=not-requested`
  - `status.final=failed`
- `APPLY-RESULT.json` 侧：
  - `mode=dry-run`
  - `recovery.resume_strategy=fix-blockers`
  - `final_status=blocked`
- `journal` 尾部稳定包含：
  - `run.initialized`
  - `inputs.reused`
  - `preflight.reused`
  - `generator.reused`
  - `apply-plan.reused`
  - `apply-dry-run.start`
  - `run.exit`

#### B. `fixture-tls-acme-real-execute-attempt`

执行：

```bash
bash install-interactive.sh --resume fixture-tls-acme-real-execute-attempt --run-apply-dry-run --yes
```

当前已确认的稳定行为：

- 会新建新的 run 目录
- `stdout` 会打印：
  - `本次 resume 策略：inspect-after-acme-real-execute-attempt`
- `stderr` 会打印：
  - `non-placeholder ACME real-execute-attempt companion result`
  - `当前虽然复用的是既有 apply-plan / generated-output 边界`
  - `默认不会直接执行真实 apply`
  - `[BLOCK] 缺少部署包目录`
- `state.json` 侧：
  - `lineage.resume_strategy=inspect-after-acme-real-execute-attempt`
  - `status.apply_dry_run=failed`
  - `status.apply_execute=not-requested`
  - `status.final=failed`
- `APPLY-RESULT.json` 侧：
  - `mode=dry-run`
  - `recovery.resume_strategy=fix-blockers`
  - `final_status=blocked`
- `journal` 尾部稳定包含：
  - `run.initialized`
  - `inputs.reused`
  - `preflight.reused`
  - `generator.reused`
  - `apply-plan.reused`
  - `apply-dry-run.start`
  - `run.exit`

### 3.3 当前不建议继续做什么

如果恢复开发，当前**不建议**优先做的是：

- 不先回头重构 installer 主逻辑
- 不继续机械扩 inspection-first 文案变体
- 不直接去接真实 ACME runtime / 签发 / 证书落盘

原因很简单：

> 当前更真实的缺口是 smoke 级 operator 入口覆盖，而不是逻辑层又缺一个大重构。

---

## 4. 本轮可依赖的验证基线

本轮暂停时，可依赖的已知基线是：

### 已完成且已绿的回归（来自最近已收口任务）

```bash
bash -n scripts/lib/state.sh
bash -n install-interactive.sh
bash -n tests/installer-contracts-regression.sh
bash -n tests/installer-smoke.sh
bash tests/installer-contracts-regression.sh
bash tests/installer-smoke.sh
```

以及更早的：

```bash
bash tests/installer-doctor-golden.sh
```

### 本轮新增的审计性验证（未落地成正式 smoke 代码，但已确认行为）

已人工/脚本确认：

```bash
bash install-interactive.sh --resume fixture-tls-acme-http01 --run-apply-dry-run --yes
bash install-interactive.sh --resume fixture-tls-acme-real-execute-attempt --run-apply-dry-run --yes
```

二者都能稳定复现上文 3.2 的行为与断言候选。

---

## 5. 下次恢复时的最短路径

在仓库根目录执行：

```bash
git checkout weiyusc/exp/interactive-installer
git pull --ff-only
bash tests/installer-contracts-regression.sh
bash tests/installer-smoke.sh
```

然后按顺序读：

1. `docs/INSTALLER-PAUSE-HANDOFF-2026-05-06-ZH.md`（本文件）
2. `docs/INSTALLER-TLS-PHASE3-HANDOFF-2026-05-02-ZH.md`
3. `docs/INSTALLER-CONTROL-PLANE-HANDOFF-2026-04-29-ZH.md`
4. `docs/INSTALLER-RESULT-CONTRACTS-ZH.md`
5. `docs/INSTALLER-STATE-MODEL-ZH.md`

如果要直接继续“下一刀”，就先补 `tests/installer-smoke.sh`，不要先动主逻辑。

---

## 6. 推荐的恢复起手式

如果下次继续，推荐优先做这一件事：

> **在 `tests/installer-smoke.sh` 中新增两条 ACME resume smoke 用例，复用现有 `activate_contract_fixture_runs` / run dir 前后对比 / state+stderr 断言模式。**

优先断言这些内容：

### `fixture-tls-acme-http01`

- 新 run 目录被创建
- `lineage.resume_strategy == inspect-after-acme-placeholder`
- `stdout` 含 `本次 resume 策略：inspect-after-acme-placeholder`
- `stderr` 含：
  - `inspect-after-acme-placeholder / review-first 续接`
  - `默认不会直接执行真实 apply`
  - `[BLOCK] 缺少部署包目录`
- `apply_result.mode == dry-run`
- `apply_result.final_status == blocked`

### `fixture-tls-acme-real-execute-attempt`

- 新 run 目录被创建
- `lineage.resume_strategy == inspect-after-acme-real-execute-attempt`
- `stdout` 含 `本次 resume 策略：inspect-after-acme-real-execute-attempt`
- `stderr` 含：
  - `non-placeholder ACME real-execute-attempt companion result`
  - `当前虽然复用的是既有 apply-plan / generated-output 边界`
  - `默认不会直接执行真实 apply`
  - `[BLOCK] 缺少部署包目录`
- `apply_result.mode == dry-run`
- `apply_result.final_status == blocked`

这刀做完后，再跑：

```bash
bash tests/installer-smoke.sh
bash tests/installer-contracts-regression.sh
```

---

## 7. 本次暂停时的一句话结论

> 到 `2026-05-06` 这个停点，interactive installer 这条线已经把 review-boundary / execute-gating 这一轮主收口做完；当前最值得继续的下一刀也已经审计清楚，但还没有落代码，因此现在非常适合阶段性暂停，并把下一次恢复入口固定在“补 ACME smoke 覆盖”，而不是重新发散需求。
