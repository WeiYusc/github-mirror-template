# Interactive Installer TLS Phase 1 handoff（2026-05-01）

> 状态：**TLS Phase 1 scaffolding 已收口并推到远端**
> 仓库：`github-mirror-template`
> 分支：`weiyusc/exp/interactive-installer`
> 远端：`origin`
> handoff 时间：2026-05-01
> 当前停点提交：`26acd24 feat: align tls phase-1 scaffolding contracts`

---

## 1. 这份 handoff 的用途

这份不是总归档，也不是第一次读仓库时的总入口。

它只服务一个目标：

> **把 TLS Phase 1 这轮“先把 `tls.mode` / preflight / TLS plan / result contract 收紧”的工作，压成下一次能直接续接的短入口。**

如果以后用户说：

- “继续 interactive installer 的 TLS 这条线”
- “继续自动 SSL / ACME 那轮”
- “从 Phase 1 往 Phase 2 推”

优先先读这份，再回看更大的 new-session / control-plane / next-stage backlog 文档。

---

## 2. 这轮到底完成了什么

这轮完成的不是“真正申请证书”，而是 **TLS Phase 1 scaffolding**：

### 已落地的能力

1. installer 输入层已经有显式 `tls.mode` 抽象
   - `existing`
   - `acme-http01`
   - `acme-dns-cloudflare`

2. `tls.mode=existing` 与两种 ACME 模式已经进入统一状态/摘要契约
   - `state.json`
   - `INSTALLER-SUMMARY.json`
   - resume source loading

3. 非 `existing` 模式会生成独立 TLS plan artifacts
   - `TLS-PLAN.generated.md`
   - `TLS-PLAN.generated.json`

4. preflight 已具备 mode-aware 语义
   - `existing`：继续做 cert/key 只读校验
   - `acme-http01`：给出 scaffold-only warning，并做域名是否指向本机 / 80 端口状态提示
   - `acme-dns-cloudflare`：给出 scaffold-only warning，明确当前不会调用 Cloudflare API

5. generator / summary / state / fixture / regression 已对齐 TLS plan contract

### 明确还没做的事

这轮 **没有** 做：

- 不申请证书
- 不安装 `acme.sh` / `certbot`
- 不调用 Cloudflare API
- 不自动改 DNS
- 不接管现网 nginx challenge 配置
- 不引入真正的 ACME issue / renew / deploy 生命周期

一句话：

> 这轮是把 TLS 从“只有 existing cert/key”推进到“有清晰模式抽象、只读预检、计划工件、结果契约和测试护栏”的 Phase 1，而不是直接落 ACME 执行器。

---

## 3. 这轮最终收口点

### 3.1 关键实现改动

本轮真正关键的收口是：

- `scripts/lib/state.sh`
  - 新增 `tls_plan_markdown`
  - 新增 `tls_plan_json`
  - 让它们进入：
    - state artifact snapshot
    - installer summary artifact snapshot
    - `state_load_resume_context()` 的 resume source values

这意味着：

> TLS plan 不再只是临时生成给人看的附件，而是正式进入 installer contract。

### 3.2 关键测试收口

本轮没有继续走“只补半个 fixture state.json”的坏方向，而是把 TLS fixture 补成**最小完整 contract 样本**。

新增/补齐：

- `tests/fixtures/installer-contracts/template/runs/fixture-tls-acme-http01/`
- `tests/fixtures/installer-contracts/template/artifacts/fixture-tls-acme-http01/`
- `tests/fixtures/installer-contracts/template/runs/fixture-tls-acme-dns-cloudflare/`
- `tests/fixtures/installer-contracts/template/artifacts/fixture-tls-acme-dns-cloudflare/`

并在：

- `tests/installer-contracts-regression.sh`

新增 TLS plan artifact contract 断言，显式锁定：

- `inputs.tls_mode`
- summary 里的 `tls_mode`
- `artifacts.tls_plan_markdown`
- `artifacts.tls_plan_json`
- 它们与 run-scoped artifact snapshot 的路径关系

### 3.3 为什么最终还是补 fixture，而不是只靠 smoke

这轮中途一度判断“更适合转去 smoke”。后来实际验证后，稳定结论变成：

- **只补 `state.json`** 确实不对，会让 regression 自己坏掉
- 但 **补成最小完整 fixture 套件** 是对的，因为这轮要钉的是 **contract 层**，不是单纯入口行为

所以最后正确路线不是：

- “放弃 contract，只测 smoke”

而是：

- “先把 TLS fixture 做完整，让 contract regression 真能表达这层语义；同时保留 smoke / doctor / deploy-config 回归做外围护栏”

---

## 4. 本轮提交与验证

### 关键提交

- `26acd24 feat: align tls phase-1 scaffolding contracts`

### 已确认通过的验证

```bash
bash tests/installer-contracts-regression.sh
bash tests/installer-smoke.sh
bash tests/deploy-config-yaml-regression.sh
bash tests/installer-doctor-golden.sh
```

当前稳定结论是：

> 这轮不是“本地改好了但没收口”，而是已经形成完整本地提交并 push 到远端，且本地与远端重新对齐。

---

## 5. 当前最值得记住的边界

### `acme-http01` 当前语义

- 已有 `tls.mode=acme-http01`
- 已有 preflight warning / blocker / dns / port80 摘要
- 已有 TLS plan 工件
- **没有真实 ACME issue**

### `acme-dns-cloudflare` 当前语义

- 已有 `tls.mode=acme-dns-cloudflare`
- 已有 scaffold-only warning
- 已有 TLS plan 工件
- **没有 Cloudflare token 校验 / zone 查询 / DNS-01 issue**

### 当前阶段定位

这轮更接近：

- “把 operator-facing 语义说清楚”
- “把 contract 和测试护栏钉住”

而不是：

- “把自动 SSL 做完”

---

## 6. 下次续接的最短恢复路径

在仓库根目录执行：

```bash
git checkout weiyusc/exp/interactive-installer
git pull --ff-only
bash tests/installer-contracts-regression.sh
bash tests/installer-smoke.sh
bash tests/deploy-config-yaml-regression.sh
bash tests/installer-doctor-golden.sh
```

然后按顺序建议读：

1. `docs/INSTALLER-TLS-PHASE1-HANDOFF-2026-05-01-ZH.md`（本文件）
2. `docs/INSTALLER-NEW-SESSION-HANDOFF-2026-04-29-ZH.md`
3. `docs/INSTALLER-CONTROL-PLANE-HANDOFF-2026-04-29-ZH.md`
4. `docs/INSTALLER-NEXT-STAGE-BACKLOG-ZH.md`
5. `docs/INSTALLER-DESIGN-ZH.md`

如果四条回归都为绿，说明 TLS Phase 1 停点仍然可靠。

---

## 7. 如果继续做 TLS，下一步最值得从哪接

### 第一优先级：Phase 2 = ACME HTTP-01 真正 issue 接入

Phase 2 的第一刀现在已经落成 **conservative issue-helper** 形态，边界是：

- 独立 helper：`./acme-issue-http01.sh`
- 默认 `dry-run`；显式 `--execute` 当前也只做 execute-mode planning / evidence，不真实签发
- 当前会输出：
  - `ISSUE-RESULT.md`
  - `ISSUE-RESULT.json`
- 当前会把 `issue_result` / `issue_result_json` 回写进：
  - `state.json.artifacts.*`
  - `INSTALLER-SUMMARY.generated.json.artifacts.*`
  - `INSTALLER-SUMMARY.json.artifacts.*`
  - `journal.jsonl` 的 `issue.result.recorded`
- 当前 helper 至少支持这些参数：
  - `--state-json`
  - `--dry-run`
  - `--execute`
  - `--challenge-mode <standalone|webroot|file-plan>`
  - `--webroot`
  - `--acme-client <acme.sh|certbot|manual>`
  - `--account-email`
  - `--staging`
- 当前仍**不会**：
  - 真实申请证书
  - 安装 `acme.sh` / `certbot`
  - 改 live nginx / takeover challenge 流量
  - reload nginx
  - 写入证书/私钥文件

所以这一步完成的重点已经从“是否需要单独产物”收口为：

- `ISSUE-RESULT.json / md` 已经是单独 companion result
- 但它当前表达的是 **planning / evidence contract**，不是“证书签发成功”
- 并且这份 contract 现在已经显式预留 future real execute 分叉：
  - `ACME-ISSUANCE-RESULT.json`
  - `ACME-ISSUANCE-RESULT.md`
  - `schema_kind=acme-issuance-result`
- 未来真实签发结果不得继续复用 `ISSUE-RESULT.{md,json}`，避免 operator / automation / resume logic 把计划结果与执行结果混成双义 artifact

最值得继续做的是：

1. 保持独立 helper，而不是直接把所有逻辑塞回 installer 主脚本
2. 继续收紧 challenge 模式边界
   - standalone
   - webroot
   - file-plan
3. 继续收紧与现网 nginx 的关系
   - 不默认 takeover
   - 不默认 reload
   - 先 dry-run / 计划 / 显式确认
4. 在真正接通 execute 前，继续保持 result contract 分叉：
   - `ISSUE-RESULT.*` 只管 planning / evidence
   - `ACME-ISSUANCE-RESULT.*` 才承载 future real execute

### 第二优先级：Cloudflare DNS-01 设计收口

在真正开写前，先把这些定清：

- token 最小权限模型
- zone 定位方式
- wildcard / multi-SAN 的证书策略
- 失败后的 operator review 边界

### 当前不值得优先做

- 不要先做“自动续期全生命周期”
- 不要先堆 provider 抽象层
- 不要先把 installer 主脚本继续变成更厚的总控巨石
- 不要为了“看起来完整”先把 DNS-01 和 HTTP-01 一起全做

推荐顺序仍然是：

```text
Phase 1 contract/scaffolding ✅
-> Phase 2 acme-http01 conservative issue path
-> Phase 3 cloudflare dns-01
-> Phase 4 renew/deploy lifecycle
```

---

## 8. 一句话停点结论

> 到当前 Phase 2 first-cut 为止，interactive installer 的 TLS 这条线已经从“只有 `tls.mode` 抽象与 TLS plan 的 Phase 1 scaffolding”，推进到“拥有独立 `acme-issue-http01.sh`、`ISSUE-RESULT.{md,json}` companion contract、以及 state/summary/journal 路径回写”的保守 issue-helper 停点；但它仍只负责 planning / evidence，不代表已经接通真实 ACME issue / deploy lifecycle。
