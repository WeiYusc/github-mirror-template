# Installer Operator Runbook（中文）

> 状态：面向操作者的人工处理手册
> 适用分支：`weiyusc/exp/interactive-installer`
> 适用范围：`install-interactive.sh` 产生的 `state.json` / `journal.jsonl` / `INSTALLER-SUMMARY.json` / `APPLY-RESULT.json`

---

## 1. 这份手册是干什么的

这不是功能说明，也不是发布文案。

如果你是从 `INSTALL.md` 第一次顺着 experimental installer 走到这里，先记住一句话：

> 遇到异常 run 时，默认顺序是 **先 doctor，再看 state / apply result，最后才决定要不要 resume / repair / rollback**。

它只回答一个实际问题：

> 当 installer 跑完后，状态不是干净的 `success`，操作者下一步该怎么判断、先看什么、不要乱做什么。

当前重点覆盖 4 种状态：

- `needs-attention`
- `blocked`
- `failed`
- `cancelled`

这 4 种状态都意味着：

- 不要把当前 run 当成“已经安全完成”
- 不要跳过检查直接继续生产动作
- 先基于 run 产物做判断，再决定是否 `--resume`、人工修复、或重新跑一轮

---

## 2. 先记住当前 installer **不会**替你做什么

当前 installer 路线是“保守编排层”，不是全自动运维器。

它**不会**自动做这些事：

- 不会自动 rollback 已写入的 nginx 配置
- 不会自动 reload nginx
- 不会自动修改 DNS
- 不会自动接管复杂线上站点
- 不会在 `needs-attention` 场景下帮你做最终生产判断

所以看到异常状态时，正确思路不是“让脚本替我赌一次”，而是：

> 先查清当前 run 到底做到哪一步，再决定要不要继续。

---

## 3. 先看哪里：标准检查顺序

拿到一个 `run_id` 后，建议始终按这个顺序看：

### 第一步：先跑 doctor

```bash
./install-interactive.sh --doctor <run_id>
```

先用它拿摘要，不要一上来就 resume。

doctor 的用途是：

- 看当前 run 的 checkpoint
- 看当前 `status.preflight / generator / apply_plan / apply_dry_run / apply_execute / repair / rollback / final`
- 看有没有 `APPLY-RESULT.json`
- 如果 `state.json` 已登记 `REPAIR-RESULT.json` / `ROLLBACK-RESULT.json`，会优先直接读取
- 对旧 run，如果同目录已经存在 `REPAIR-RESULT.json` / `ROLLBACK-RESULT.json`，也会一起显示
- 看脚本给出的下一步建议

---

### 第二步：看 run 目录里的原始状态文件

```bash
cat scripts/generated/runs/<run_id>/state.json
cat scripts/generated/runs/<run_id>/journal.jsonl
```

如果想更容易读 JSON，可以用：

```bash
python3 -m json.tool scripts/generated/runs/<run_id>/state.json
python3 -m json.tool scripts/generated/runs/<run_id>/APPLY-RESULT.json
```

重点关注：

- `checkpoint`
- `status.final`
- `status.apply_execute`
- `artifacts.apply_result_json`
- `artifacts.summary_output`
- `resumed_from`

---

### 第三步：如果存在 `APPLY-RESULT.json`，优先读它（以及同目录 companion result）

```bash
cat scripts/generated/runs/<run_id>/APPLY-RESULT.json
```

重点看这些字段：

- `mode`
- `final_status`
- `execution.backup_status`
- `execution.copy_status`
- `nginx_test.requested`
- `nginx_test.status`
- `recovery.installer_status`
- `recovery.resume_strategy`
- `recovery.resume_recommended`
- `recovery.operator_action`
- `next_step`

它比单看 checkpoint 更接近真实处境。

如果你已经跑过 repair / rollback，还应顺手看同目录下这些结果：

- `REPAIR-RESULT.json`
- `ROLLBACK-RESULT.json`

现在 `--doctor` 也会自动把这两个结果纳入摘要：

- 若 repair 已重跑 `nginx -t` 且通过，会优先提示“人工确认后决定是否继续”
- 若 repair 已重跑 `nginx -t` 且仍失败，会优先提示先按 repair 结论决定 rollback 还是人工修配置
- 若 rollback 已实际执行，也会优先提示先手工 `nginx -t`，再判断是否继续

---

### 第四步：再决定是否 resume

只有在你已经知道：

- 上次 run 停在哪一步
- 是否已经真实 apply
- 是否做过 nginx test
- 当前是不是推荐 resume

之后，才考虑：

```bash
./install-interactive.sh --resume <run_id>
```

---

## 4. 四种状态分别怎么处理

---

## 4.1 `needs-attention`

### 这是什么意思

这通常表示：

- 脚本不是单纯“报错退出”
- 而是已经做了部分有意义的动作
- 但当前处境需要人工确认，不能继续假装是成功

最典型场景是：

- 真实 apply 已经执行
- 但后续 nginx test 失败
- 或 apply 结果提示当前更适合人工检查，而不是自动续跑

### 推荐检查顺序

1. 先跑：

```bash
./install-interactive.sh --doctor <run_id>
```

2. 看：

```bash
python3 -m json.tool scripts/generated/runs/<run_id>/state.json
python3 -m json.tool scripts/generated/runs/<run_id>/APPLY-RESULT.json
```

3. 重点确认：

- `status.apply_execute` 是否为 `needs-attention`
- `status.final` 是否也已经对齐为 `needs-attention`
- `recovery.resume_recommended` 是否为 `false`
- `recovery.operator_action` 要你先做什么
- `nginx_test.status` 是失败、未执行，还是不适用
- 备份是否已经生成

4. 人工检查目标机上实际状态：

- 目标配置是否已复制
- 证书路径是否正确
- include 路径是否存在
- 手工执行 `nginx -t` 的真实报错是什么

5. 只有在你确认当前处境已被理解后，才考虑 resume：

```bash
./install-interactive.sh --resume <run_id> --yes
```

如果你已经确认本轮真实 apply 写入需要撤回，也可以先做一轮**保守式 selective rollback 预演**：

```bash
./rollback-applied-package.sh --result-json scripts/generated/runs/<run_id>/../<dist>/APPLY-RESULT.json --dry-run
```

更常见的做法是直接从 `state.json` 里取 `artifacts.apply_result_json` 的真实路径，再把它传给 rollback helper。

如果你当前还没决定是“撤回”还是“修一修再测”，先跑一轮 repair 诊断更稳：

```bash
./repair-applied-package.sh --result-json <APPLY-RESULT.json> --dry-run
```

它当前会：

- 复核 apply result 里的 `NEW / REPLACE` 项现在是否还在目标机上
- 复核 `REPLACE` 项对应备份是否齐全
- 给出“更像该 rollback 还是更像该人工修配置”的保守提示
- **不会**直接改文件

如果你只是想重新验证当前配置有没有已经恢复正常，也可以再显式跑：

```bash
./repair-applied-package.sh --result-json <APPLY-RESULT.json> --execute --nginx-test-cmd 'nginx -t'
```

即便用了 `--execute`，当前也只是重跑 nginx 测试并记录结果，不会自动 reload nginx。

### 不要直接做的事

- 不要把 `needs-attention` 当成“只是小 warning”
- 不要默认 resume 就会替你安全修好
- 不要不看 `APPLY-RESULT.json` 就重复执行真实 apply
- 不要在没看手工 `nginx -t` 结果前直接继续生产动作
- 不要在未审查 NEW/REPLACE 明细前直接执行 rollback helper 的 `--execute --delete-new`

### 这类状态下对 resume 的理解

当前实现里，`needs-attention` 场景下的 `--resume` 默认是：

- 复用输入和已完成产物
- 默认收紧执行意图
- 不把“重放 apply”当默认动作
- 如果已经有 `REPAIR-RESULT.json`：
  - `nginx_test_rerun_status=passed` 时，会优先进入“post-repair verification”语义
  - 仍为 `failed / blocked / needs-attention` 时，会优先进入“repair-review-first”语义
- 如果已经有 `ROLLBACK-RESULT.json` 且 rollback 已执行成功：
  - 会优先进入“post-rollback inspection”语义
  - 默认继续保持不继承真实 apply 意图
- 在这些 inspection-first 语义下：
  - 可以显式带 `--run-apply-dry-run` 再做一次只读预演
  - 但若显式带 `--execute-apply`，当前实现会直接拒绝，要求先完成人工复查

所以它更像“带上下文的保守续接”，不是“一键重试执行器”。

---

## 4.2 `blocked`

### 这是什么意思

这表示当前 run 被明确阻断，继续往下走没有意义。

常见来源：

- preflight 检查未通过
- 关键输入缺失
- 路径/目标不满足执行前提
- apply plan 发现必须先人工处理的冲突或阻断项

### 推荐检查顺序

1. 先跑：

```bash
./install-interactive.sh --doctor <run_id>
```

2. 看：

```bash
python3 -m json.tool scripts/generated/runs/<run_id>/state.json
```

3. 重点确认：

- `status.preflight` 是否为 `blocked`
- `status.final` 是否为 `blocked`
- 是输入问题、路径问题、TLS 问题、还是目标环境问题
- 是否还没进入 generator / apply 阶段

4. 如果存在 preflight 报告，直接读对应产物：

- `preflight.generated.md`
- `preflight.generated.json`

5. 修掉阻断条件后，再重新跑一轮；是否用旧 run resume，要按 doctor 建议判断。

### 不要直接做的事

- 不要把 `blocked` 当成瞬时失败然后强行 resume
- 不要跳过 preflight 提示继续真实 apply
- 不要在阻断原因没消失前重复跑同一套执行动作

### 一般建议

`blocked` 往往更适合：

- 先修输入或环境
- 再重新发起一次新的 run

而不是执着于把旧 run 硬续下去。

---

## 4.3 `failed`

### 这是什么意思

这表示某个关键阶段明确失败了。

常见场景包括：

- generator 失败
- dry-run 失败
- execute 失败
- 某个关键脚本返回非零退出码

它和 `needs-attention` 的差别在于：

- `failed` 更像“某一步没跑通”
- `needs-attention` 更像“跑到了危险边界，需要人工接管判断”

### 推荐检查顺序

1. 先跑：

```bash
./install-interactive.sh --doctor <run_id>
```

2. 看 journal：

```bash
cat scripts/generated/runs/<run_id>/journal.jsonl
```

3. 再看 state：

```bash
python3 -m json.tool scripts/generated/runs/<run_id>/state.json
```

4. 确认失败发生在哪个阶段：

- `status.generator=failed`
- `status.apply_dry_run=failed`
- `status.apply_execute=failed`
- `status.final=failed`

5. 如果有 apply 结果文件，再读：

```bash
python3 -m json.tool scripts/generated/runs/<run_id>/APPLY-RESULT.json
```

6. 先定位根因，再决定：

- 修输入
- 修路径
- 修模板/脚本
- 还是重新生成部署包

### 不要直接做的事

- 不要只因为 `failed` 就条件反射去 `--resume`
- 不要先重跑 execute，再查失败原因
- 不要忽略 `journal.jsonl`，它通常比 summary 更接近故障点

### 一般建议

- 如果失败点在 generator / preflight / dry-run，更适合先修根因再重跑
- 如果失败点在 execute，要先确认有没有留下半完成状态

---

## 4.4 `cancelled`

### 这是什么意思

这表示本轮是人为取消、确认中止、或流程在设计上被显式终止。

它不等于失败，但也不等于完成。

典型场景：

- 操作者没有确认执行
- 真实 apply 前主动退出
- 某一步被显式标记为取消

### 推荐检查顺序

1. 跑 doctor：

```bash
./install-interactive.sh --doctor <run_id>
```

2. 看 state：

```bash
python3 -m json.tool scripts/generated/runs/<run_id>/state.json
```

3. 确认取消发生在什么边界：

- 是还没 apply 就取消
- 还是已经 apply 后某个后续动作取消
- 是否已有 deploy output / apply plan / backup 产物

4. 按取消位置决定后续：

- 如果只是执行前取消，通常可以放心重新跑
- 如果已经过真实 apply，再把它当 `needs-attention` 那样谨慎看待

### 不要直接做的事

- 不要因为是 `cancelled` 就默认认为线上一定没变
- 不要不看产物就假设“什么都没发生”
- 不要把取消后的 run 和全新 clean run 混为一谈

---

## 5. 一个更稳的人工处理流程

如果你不想每次临场判断，直接按这个固定流程走：

### 场景 A：先看摘要

```bash
./install-interactive.sh --doctor <run_id>
```

### 场景 B：看状态和产物路径

```bash
python3 -m json.tool scripts/generated/runs/<run_id>/state.json
```

### 场景 C：如果涉及 apply，优先看结果语义

```bash
python3 -m json.tool scripts/generated/runs/<run_id>/APPLY-RESULT.json
```

### 场景 D：如果仍不确定，读日志时间线

```bash
cat scripts/generated/runs/<run_id>/journal.jsonl
```

### 场景 E：最后才决定是否 resume

```bash
./install-interactive.sh --resume <run_id>
```

这比“先 resume 再看情况”稳得多。

---

## 6. 怎么理解几个关键文件

### `state.json`

这是 run 级总状态。

看它主要是为了知道：

- 当前 run 停在哪个 checkpoint
- 各阶段状态是什么
- `final` 最终归一成什么
- 相关产物文件路径在哪

### `journal.jsonl`

这是时间线。

适合查：

- 哪一步先发生
- 哪一步失败/取消
- 路径和消息线索

### `APPLY-RESULT.json`

这是 apply 阶段最重要的机器语义文件。

适合判断：

- 是否真的执行过 apply
- nginx test 是否被请求、是否失败
- 当前更推荐 resume 还是人工检查
- 操作者下一步应该做什么

### `INSTALLER-SUMMARY.json`

这是对外更容易消费的摘要。

适合快速确认：

- 本轮状态是否已归一
- `final` 是否仍是 `success`
- 状态是否和 `state.json` 一致

---

## 7. 常见误区

### 误区 1：`--resume` 就是“继续执行上次动作”

不是。

尤其在 `needs-attention` 场景，当前实现故意把 resume 收紧成“检查优先、提示优先”。

### 误区 2：`failed` 一定比 `needs-attention` 更严重

不一定。

- `failed` 是明确失败
- `needs-attention` 可能表示已经部分改动落地，但现在需要你接管判断

很多时候后者反而更需要谨慎。

### 误区 3：只看 `final` 就够了

不够。

还得一起看：

- `status.apply_execute`
- `APPLY-RESULT.json`
- `journal.jsonl`

### 误区 4：`cancelled` 就等于没动机器

不一定。

取消发生的阶段不同，留下的现场也不同。

---

## 8. 推荐的实际操作原则

最后压缩成一句话：

> 先 doctor，后读 state，再看 apply result，最后才决定 resume。

如果还要再压缩一句：

> 当前 installer 的职责是把状态和建议说清楚，不是替你越过生产边界做决定。

这就是这套 runbook 的核心。
