# Interactive Installer Recovery Round-up（2026-04-19）

> 状态：本地阶段性收口说明
> 分支：`weiyusc/exp/interactive-installer`
> 说明：这份 round-up 只覆盖当时那一轮早期 recovery / final-status 语义收口提交；后续新增的 repair / rollback helper、state artifact 回写、resume inspection strategy 门控与文档同步，不在本文覆盖范围内，应以 `README.md`、`INSTALL.md` 与 `docs/INSTALLER-OPERATOR-RUNBOOK-ZH.md` 的当前口径为准。
> 覆盖提交：
> - `044ff26 feat: refine apply execute recovery semantics`
> - `b85b2e4 feat: make resume conservative after apply warnings`
> - `ffd230f feat: align installer final status with apply outcome`

---

## 1. 这轮主要补了什么

这一轮不是扩功能面，而是把 installer 在 **真实 apply / nginx test 失败 / resume 续接** 这一段的语义补硬。

核心目标只有三个：

1. **让 apply execute 的结果更机器可读**
2. **让 needs-attention 场景下的 resume 更保守**
3. **让整轮 run 的 final status 不再假装 success**

换句话说，这一轮做的是 recovery / doctor / resume / final-status 之间的语义对齐，而不是继续加新入口。

---

## 2. 本轮补齐后的行为变化

### 2.1 `APPLY-RESULT.json` 不再只说“成没成”

真实 apply 后，结果 JSON 现在会额外表达：

- `execution.backup_status`
- `execution.copy_status`
- `nginx_test.requested`
- `nginx_test.status`
- `recovery.installer_status`
- `recovery.resume_strategy`
- `recovery.resume_recommended`
- `recovery.operator_action`
- `next_step`

这意味着后续的 `--doctor`、`state.json`、以及 resume 决策，不必再只靠 checkpoint 猜测当前处境。

特别是在这些场景里，语义已经能明显分开：

- 真实 apply 已落盘，但没做 nginx test
- 真实 apply 已落盘，且 nginx test 失败
- apply 被冲突 / 缺失源文件 / 目标阻断挡住
- 当前是否推荐 resume
- 当前更适合“继续执行”还是“人工恢复/修复”

---

### 2.2 `--resume` 在 `needs-attention` 场景下默认收紧

之前的 resume 更偏“沿着上次状态继续推进”。

这在普通中断场景没问题，但在下面这种情况里会有误导性：

- 上次真实 apply 已经执行过
- nginx test 失败
- `APPLY-RESULT.json` 已明确给出 `resume_recommended=false`

如果这种时候 resume 还默认继承 `--execute-apply` / `--run-nginx-test` 的执行意图，就很容易把 resume 变成“半自动重放 apply”。

这轮之后，行为改成：

- 仍可 `--resume <run_id>`
- 仍会复用输入、preflight、generator 输出和 apply plan 等产物
- 但默认会主动清空：
  - `RUN_APPLY_DRY_RUN`
  - `EXECUTE_APPLY`
  - `RUN_NGINX_TEST_AFTER_EXECUTE`
- 并把策略标成：
  - `inspect-after-apply-attention`

也就是说：

> `needs-attention` 场景下，resume 现在默认是“检查优先、提示优先”，而不是“重放 apply 优先”。

终端输出也会明确提示：

- 源运行的 apply 结果标记为需人工处理
- 默认不会继承上次的真实 apply / nginx test 执行意图
- 源运行建议的下一步动作是什么

---

### 2.3 `status.final` 现在与真实处境对齐

之前还有一个语义裂缝：

- `apply_execute = needs-attention`
- 但 `INSTALLER-SUMMARY.json.status.final` / `state.json.status.final`
  仍可能是 `success`

这会让 doctor、summary、后续脚本消费方拿到一个“整体成功”的假信号。

现在 `install-interactive.sh` 已加入统一归一逻辑，`status.final` 会自动归一成：

- `success`
- `cancelled`
- `blocked`
- `failed`
- `needs-attention`

当前归一规则大致是：

- `preflight=blocked` → `final=blocked`
- `generator failed` / `dry-run failed` / `execute failed` → `final=failed`
- `apply_execute=needs-attention` → `final=needs-attention`
- 执行取消 → `final=cancelled`
- 否则 → `final=success`

这让 run 级状态终于和 apply 阶段语义站到一条线上了。

---

## 3. 这一轮实际验证了什么

本轮做了针对性的最小验证，而不是只看代码 diff：

### 验证 A：apply execute recovery 语义

构造真实 `--execute-apply` + `--run-nginx-test`，并令 nginx test 故意失败，确认：

- `APPLY-RESULT.json` 会写出 recovery 字段
- `installer_status` 不再一律是 `success`
- `doctor` 能读懂这些字段并给出更具体建议

### 验证 B：resume 默认不重放 apply

先造一个 `needs-attention` 的源 run，再执行：

```bash
./install-interactive.sh --resume <run_id> --yes
```

确认新的 resume run：

- `apply_dry_run = skipped`
- `apply_execute = skipped`
- 策略是 `inspect-after-apply-attention`
- 输出里会明确告知“默认不会继承上次 apply 执行意图”

### 验证 C：final status 对齐

再次构造 execute + nginx test fail 场景，确认：

- `INSTALLER-SUMMARY.json.status.apply_execute = needs-attention`
- `INSTALLER-SUMMARY.json.status.final = needs-attention`
- `state.json.status.apply_execute = needs-attention`
- `state.json.status.final = needs-attention`

这一条很关键，因为它说明整体 run 状态已经不再和局部 apply 状态打架。

---

## 4. 这一轮之后，当前 recovery 线的稳定结论

到这一步，installer 的 recovery 线已经形成一组比较完整的闭环：

1. **state / journal / summary 已落盘**
2. **apply 结果已具备更细机器语义**
3. **doctor 能基于 apply result 给出更靠谱的建议**
4. **resume 不会在 needs-attention 场景下默认重放 apply**
5. **final status 能真实反映整轮 run 的最终处境**

所以这轮的价值，不是“更炫”，而是：

> 在最容易把状态搞乱的 execute/recovery 边界上，installer 现在比之前诚实得多，也保守得多。

---

## 5. 当前仍然刻意没做的事

这轮没有做这些事，而且是故意没做：

- 不自动 rollback nginx / 配置文件
- 不自动 reload nginx
- 不让 resume 直接变成“重放 apply”按钮
- 不把 `needs-attention` 伪装成 `success`
- 不试图在 doctor 里替操作者做最终生产决定

也就是说，当前设计仍然坚持：

> **自动化负责把上下文、状态和建议说清楚；真正越过生产边界的动作仍由操作者显式决定。**

---

## 6. 当前本地停点

当前分支：`weiyusc/exp/interactive-installer`

相对远端 `origin/weiyusc/exp/interactive-installer`，本地新增未推送提交为：

- `044ff26 feat: refine apply execute recovery semantics`
- `b85b2e4 feat: make resume conservative after apply warnings`
- `ffd230f feat: align installer final status with apply outcome`

这一组现在已经是一个比较自然的可推停点。

如果后续继续，最顺的两个方向是：

1. **直接推远端**，把 recovery 收口提交补上去
2. **继续补一层 operator-facing 文档**，例如把 `needs-attention` / `blocked` / `failed` 的人工处理路径写成单独手册

---

## 7. 一句话结论

这一轮没有让 installer 更激进，反而让它在最危险的 execute/recovery 边界上更保守了。

这是对的。
