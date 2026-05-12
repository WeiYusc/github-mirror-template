# Interactive Installer TLS Phase 2 handoff（2026-05-02）

> 状态：**TLS Phase 2 conservative ACME placeholder / doctor / resume 语义已收口并推到远端**
> 仓库：`github-mirror-template`
> 分支：`weiyusc/exp/interactive-installer`
> 远端：`origin`
> handoff 时间：2026-05-02
> 当前停点提交：`73f38ef docs(tls): align acme placeholder resume contracts`

---

## 1. 这份 handoff 的用途

这份不是 TLS Phase 1 的重复版，也不是整个 interactive installer 的总入口。

它只服务一个目标：

> **把 TLS Phase 2 这轮“先做 conservative ACME issue helper，再把 execute placeholder / doctor / resume / contract 文档收紧”的工作，压成下一次能直接续接的短入口。**

如果下次用户说：

- “继续 interactive installer 的 TLS / ACME 这条线”
- “继续 ACME HTTP-01 那轮”
- “继续 placeholder 之后的真实签发接入”
- “继续 resume / doctor 的 ACME 语义”

优先先读这份，再回看：

- `docs/INSTALLER-TLS-PHASE1-HANDOFF-2026-05-01-ZH.md`
- `docs/INSTALLER-NEW-SESSION-HANDOFF-2026-04-29-ZH.md`
- `docs/INSTALLER-CONTROL-PLANE-HANDOFF-2026-04-29-ZH.md`
- `docs/INSTALLER-NEXT-STAGE-BACKLOG-ZH.md`

---

## 2. 这轮到底完成了什么

这轮完成的不是“真实 ACME 自动签发”，而是 **TLS Phase 2 conservative ACME placeholder control-plane 收口**。

### 已落地的能力

1. 已新增独立 helper：
   - `./acme-issue-http01.sh`

2. `acme-issue-http01.sh` 当前已形成明确的 **planning / evidence contract**：
   - 默认 `dry-run`
   - 输出 `ISSUE-RESULT.md`
   - 输出 `ISSUE-RESULT.json`
   - 当前不会真实签发

3. `--execute` 当前仍是 **placeholder execute path**，但已明确落成单独 companion result：
   - `ACME-ISSUANCE-RESULT.md`
   - `ACME-ISSUANCE-RESULT.json`
   - `schema_kind=acme-issuance-result`

4. placeholder execute result 的稳定边界已经钉住：
   - `intent.result_role=execute-placeholder`
   - `intent.real_execution_performed=false`
   - `execution.client_invoked=false`
   - `execution.issued_certificate=false`
   - deployment boundary 维持全 false

5. `doctor` 已能消费 ACME execute placeholder companion result，向 operator 说明：
   - 当前不是已真实签发
   - 当前不是已证书落盘
   - 当前不是已部署到 nginx
   - 当前应进入 review-first / inspection-first 理解

6. `resume` 已能消费 ACME execute placeholder companion result，并推导新的 inspection-first 策略：
   - `inspect-after-acme-placeholder`

7. `inspect-after-acme-placeholder` 已纳入当前实现与文档契约：
   - install help
   - contract regression
   - doctor golden
   - state model
   - operator runbook
   - result contracts
   - README 摘要

---

## 3. 这轮最重要的语义边界

### 3.1 `ISSUE-RESULT.json` 和 `ACME-ISSUANCE-RESULT.json` 不能混

当前稳定边界是：

- `ISSUE-RESULT.json`
  - 只代表 **planning / evidence**
  - 主要服务于 operator review
  - 不代表真实签发结果

- `ACME-ISSUANCE-RESULT.json`
  - 是 future real execute 预留的 companion result 容器
  - 当前即使在 `--execute` 路径下，也仍可能只是 **placeholder skeleton**
  - 它当前提供的是“execute intent + 未真实执行”的稳定事实，而不是“证书已签发”

一句话：

> planning result 和 future issuance result 已经在 contract 层正式分叉，后续不能再把真实签发结果塞回 `ISSUE-RESULT.json`。

### 3.2 `inspect-after-acme-placeholder` 的真实含义

它表示：

- 当前 run 已经碰到 ACME execute placeholder companion result
- 但 companion result 明确说明：
  - 还没真实调用 client
  - 还没真实签发证书
  - 还没落盘证书文件
  - 还没进入 nginx deploy 执行
- 所以下一次 resume 不允许把这轮误当成“可以继续真实 apply / 真实签发”的断点

也就是说：

> `inspect-after-acme-placeholder` 更像“先复查 placeholder 与 operator 前提”，不是“继续 issue 执行”。

### 3.3 inspection-first 家族现在已经是 5 类

当前需要记住的 inspection-first / review-first 策略是：

- `inspect-after-acme-placeholder`
- `inspect-after-apply-attention`
- `repair-review-first`
- `post-repair-verification`
- `post-rollback-inspection`

在这 5 类策略下：

- 可以显式 `--run-apply-dry-run`
- 不允许显式 `--execute-apply`

---

## 4. 这轮最终收口提交

本轮本地 ahead 9 个提交已经全部推到远端；其上又补了 1 个文档契约对齐提交。

### Phase 2 关键提交序列

- `0bf0477 feat: add conservative acme http01 issue helper`
- `eb57c5d docs: document acme issue helper contract`
- `951fe4e test: tighten acme issue helper execute placeholder semantics`
- `d721e74 docs,test: fork acme issue planning contract from future issuance result`
- `5df4b89 docs(tls): define minimal ACME-ISSUANCE-RESULT contract skeleton`
- `7d7aa9c feat(tls): emit ACME-ISSUANCE-RESULT execute placeholder`
- `9c761cc feat(tls): enrich acme issuance execute placeholder intent`
- `d0de0c0 feat(tls): surface acme execute placeholder in doctor`
- `22b5786 fix: tighten inspection-first resume semantics`
- `73f38ef docs(tls): align acme placeholder resume contracts`

### 最后一个提交为什么要补

发布前审计发现：

- 代码/测试本身已基本收住
- 但 `docs/INSTALLER-STATE-MODEL-ZH.md`
- `docs/INSTALLER-OPERATOR-RUNBOOK-ZH.md`
- `docs/INSTALLER-RESULT-CONTRACTS-ZH.md`
- `README.md`

仍停留在“inspection-first 四类策略”的旧口径，没有把 `inspect-after-acme-placeholder` 和 `ACME-ISSUANCE-RESULT` 的消费边界补进去。

所以最终新增：

- `73f38ef docs(tls): align acme placeholder resume contracts`

把文档/契约层重新对齐实现。

---

## 5. 已确认通过的验证

本轮实际确认通过：

```bash
bash tests/installer-contracts-regression.sh
bash tests/installer-doctor-golden.sh
bash tests/installer-smoke.sh
bash tests/deploy-config-yaml-regression.sh
```

在最终文档对齐提交之后，又至少重新确认通过：

```bash
bash tests/installer-contracts-regression.sh
bash tests/installer-doctor-golden.sh
bash tests/installer-smoke.sh
```

当前稳定结论：

> 本地与远端已重新对齐，工作树干净，当前停点不是“半做半停”，而是已经形成可继续续接的可靠阶段性收口。

---

## 6. 当前最值得记住的边界

### 当前还**没有**做的事

这轮仍然**没有**做：

- 不真实调用 `acme.sh` / `certbot`
- 不完成 HTTP-01 challenge fulfillment
- 不落盘真实证书/私钥
- 不自动改 live nginx challenge 配置
- 不自动 reload nginx
- 不自动把 ACME issue 成功结果接到 apply/deploy 生命周期

### 当前真正完成的是

- 把 ACME Phase 2 的 **结果契约** 钉清楚
- 把 execute placeholder 的 **事实字段** 钉清楚
- 把 `doctor` / `resume` / 文档 对 placeholder 的 **保守解释链条** 钉清楚

换句话说：

> 这轮重点是 control-plane / contract clarity，不是 ACME runtime execute completeness。

---

## 7. 下次续接的最短恢复路径

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

1. `docs/INSTALLER-TLS-PHASE2-HANDOFF-2026-05-02-ZH.md`（本文件）
2. `docs/INSTALLER-TLS-PHASE1-HANDOFF-2026-05-01-ZH.md`
3. `docs/INSTALLER-RESULT-CONTRACTS-ZH.md`
4. `docs/INSTALLER-STATE-MODEL-ZH.md`
5. `docs/INSTALLER-OPERATOR-RUNBOOK-ZH.md`
6. `docs/INSTALLER-NEXT-STAGE-BACKLOG-ZH.md`

如果四条回归都为绿，说明当前 TLS Phase 2 停点仍然可靠。

---

## 8. 如果继续做 TLS，下一步最值得从哪接

### 第一优先级：把 ACME execute placeholder 推进成“真实 execute 前的明确接线层”

当前最自然的下一刀，不是直接猛上全量真实签发，而是继续保持保守边界，先把这些东西补实：

1. 明确 challenge mode 的真实执行边界
   - `standalone`
   - `webroot`
   - `file-plan`

2. 明确 ACME client 适配层
   - `acme.sh`
   - `certbot`
   - `manual`

3. 先补 execute preconditions / evidence / operator gating
   - 哪些前提必须满足才能从 placeholder 进入 real execute
   - 哪些字段一旦进入 real execute 必须由新结果明确表达

4. 在真实签发前，继续保持：
   - 不默认 takeover live nginx
   - 不默认 reload nginx
   - 不把“已有 placeholder”误当“已可以恢复执行”

### 第二优先级：把 contract regression 再往前钉一层

如果下一轮不想立刻碰真实 ACME client，也可以先继续补测试护栏：

- 为 `inspect-after-acme-placeholder` 增补更完整 fixture / golden 覆盖
- 钉 `ACME-ISSUANCE-RESULT.json` 的更多稳定字段矩阵
- 钉 `doctor` 对 placeholder / future execute / operator prerequisite 的摘要边界

### 不建议的路线

当前**不建议**直接做：

- 把真实签发结果继续塞进 `ISSUE-RESULT.json`
- 让 `resume` 默认继承 placeholder run 的 execute 意图
- 在没有额外 gating 的情况下让 `--execute` 直接改 live nginx / reload

---

## 9. 一句话结论

当前 `weiyusc/exp/interactive-installer` 的 TLS / ACME 线已经从：

- Phase 1 的 TLS scaffolding / plan contract

推进到了：

- Phase 2 的 conservative issue helper + ACME execute placeholder + doctor/resume/documentation contract 对齐

最稳的理解是：

> 现在最难的那层“别把 planning / placeholder / future real execute 混掉”已经基本钉住；下一次继续时，应在这个清晰边界上继续推进真实 ACME execute 接线，而不是重新回到 contract 混沌状态。
