# Interactive Installer 改造路线与优先级清单（2026-04-21）

> 仓库：`github-mirror-template`
> 分支：`weiyusc/exp/interactive-installer`
> 适用范围：**installer / orchestration / state control-plane**
> 不建议大改对象：`v0.2 generator` 主线（`generate-from-config.sh` / `render-from-base-domain.sh` / `validate-rendered-config.sh` / 标准部署包产物）

---

## 1. 结论先行

当前项目**不建议全仓重写**，但**建议尽快重构 installer / orchestration / state 这一层**。

更准确地说：

- **保留** generator → apply 的总体架构方向
- **暂停** installer 新功能扩展
- **优先修** happy path、状态契约漂移、summary 误判、最小 smoke/CI 护栏
- **随后拆** Bash 编排层职责
- **中期考虑** 将 orchestration/control-plane 逐步迁到 Python，同时保留 shell 叶子节点

---

## 2. 为什么不是全盘重写

因为当前项目的核心架构方向本身是对的：

- 先 generator，后 apply
- 明确只读边界
- 先计划，后执行
- 结果 JSON 化
- 引入 doctor / resume / repair / rollback
- 对 operator 保持保守策略

当前问题不在“设计方向错了”，而在：

> 这套设计继续压在 Bash 大脚本里，会越来越难维护，也越来越难保证控制面可靠性。

---

## 3. 当前已确认的主要风险

### P0-A. 非交互 / happy path 可靠性不足

已观察到：

- 非交互路径不能稳定串起 preflight → generator → apply plan / apply
- checkpoint 可能停在 `inputs-confirmed` 或 `generator-running`
- EXIT 路径会写 summary / state，存在**提前退出却给出误导性成功摘要**的风险

这类问题会直接污染：

- `INSTALLER-SUMMARY.generated.json`
- `state.json`
- operator 对“是否成功”的判断
- 后续 `doctor` / `resume` 的信任基础

### P0-B. 状态契约已经出现漂移

已出现：

- 文档 / 实现 / 测试 对 `status.*` 枚举不一致
- 例如 `status.preflight` 已出现 `ok|warn|blocked` vs `warn|success` 的漂移

这说明当前尚未真正做到“代码即真相 / 单一真相源”。

### P1-A. deploy config 写入已切到 Python/PyYAML，后续重点转回归样本

`scripts/lib/config.sh` 中的 `write_deploy_config()` 已改为通过内嵌 Python + `PyYAML` 做结构化序列化，而不是继续用 shell 文本拼接。

当前更值得持续盯住的是：

- `tests/deploy-config-yaml-regression.sh` 是否覆盖了最容易回退的字符串边界（特殊字符、空字符串、前后空白、多行值、YAML-like scalars）
- 后续若扩字段，是否继续沿用结构化 writer，而不是重新退回 shell 手工拼 YAML
- regression 断言是否同时覆盖“installer 写出 config”与“generator 重新读入 config”这两段链路

### P1-B. 已补真实 smoke/integration 护栏

当前已新增并持续扩充：

- `tests/installer-smoke.sh`
- `tests/installer-contracts-regression.sh`
- `tests/deploy-config-yaml-regression.sh`

其中真实 CLI smoke 已不再只停留在 happy path，而是至少覆盖：

- `install-interactive.sh` 非交互真实执行成功路径
- `--execute-apply --run-nginx-test --nginx-test-cmd 'false' --yes` 的 `needs-attention` 收口
- inspection-first `--resume ... --execute-apply --yes` refusal
- generator fail-fast / 非零退出样本

所以这里的重点已经从“有没有 smoke”转成：

- 是否继续补最值钱的新入口
- 是否让 smoke 断言始终对齐实现真相源
- 是否避免 fixture / smoke / docs 三层重新漂移

### P1-C. 已接入最小 CI 护栏

当前仓库已存在：

- `.github/workflows/installer-regressions.yml`

并会自动执行：

- `bash tests/deploy-config-yaml-regression.sh`
- `bash tests/installer-smoke.sh`
- `bash tests/installer-summary-isolation.sh`
- `bash tests/installer-contracts-regression.sh`

所以这条不再是“从 0 到 1 接 CI”，而是：

- 持续保持 workflow 与本地推荐回归入口一致
- 避免 handoff / roadmap 继续把已完成的 smoke / CI 写成未来 TODO
- 后续若新增高价值回归，应优先判断是否纳入现有 workflow，而不是另起一套口径

### P2. 文档入口层级混杂

当前文档内容质量不差，但入口与权威等级未真正分层。

新读者很难快速判断：

- 哪些是权威入口
- 哪些是 operator 手册
- 哪些是 architecture/design
- 哪些只是 handoff / roundup / 阶段性归档

---

## 4. 改造总原则

### 原则 1：先修 correctness，再扩能力

暂停继续加 installer 新功能；先把 happy path、状态契约、summary 判定、smoke/CI 护栏补齐。

### 原则 2：保留 generator 主线，优先重构 control-plane

优先动：

- `install-interactive.sh`
- `scripts/lib/state.sh`
- `scripts/lib/config.sh`
- summary / result / resume / doctor 相关控制面逻辑

暂不大改：

- `generate-from-config.sh` 主逻辑
- `render-from-base-domain.sh`
- `validate-rendered-config.sh`
- `apply-generated-package.sh` 的叶子执行语义（除非为 smoke / contract 修 bug）

### 原则 3：先立自动护栏，再做结构重组

没有最小 smoke / regression / CI 护栏时，不做大规模模块迁移。

### 原则 4：中期迁 Python，但不推倒重写

建议保留 shell 叶子节点，把 orchestration/control-plane 逐步迁到 Python。

---

## 5. 优先级清单

## P0：立刻做（阻塞后续扩展）

### P0-1. 修非交互 happy path / 提前退出 / 假成功 summary

#### 目标

确保以下结论成立：

- 非交互路径要么稳定推进到合理终点，要么明确失败
- 不再出现 `rc=0` 但 `status.final=success` 误导成功的情况
- `checkpoint` 不会因提前写点/异常退出形成假完成语义

#### 建议动作

- 复核 `ui_confirm()` / `ui_prompt()` 在无 TTY/EOF 下的行为
- 明确非交互模式规则：
  - `--yes` 才允许默认继续
  - 无输入且缺必要参数时 fail-fast
- 调整 `inputs-confirmed`、`generator-running` 等 checkpoint 的写点时机
- 收紧 `installer_determine_final_status()` 的 success 判定条件
- 让 summary/state on-exit 在“不完整 run”场景给出保守结论，而不是乐观结论

#### 验收标准

- README 中的非交互命令可稳定执行
- `state.json.status.final != running`
- `checkpoint` 与 `status.*` 一致
- summary 不再把不完整 run 误写成 success

---

### P0-2. 统一 `status.*` 枚举与真相源

#### 目标

让这几层共用同一套枚举口径：

- implementation
- docs
- fixtures / regression
- summary / state writers

#### 最低覆盖字段

- `status.preflight`
- `status.generator`
- `status.apply_plan`
- `status.apply_dry_run`
- `status.apply_execute`
- `status.repair`
- `status.rollback`（若引入/已存在）
- `status.final`

#### 建议动作

- 先做一份权威枚举表（repo 内单一来源）
- 用它逐项核对：`state.sh` / `checks.sh` / regression / fixtures / docs
- 先修已确认漂移的 `status.preflight`
- 把“允许动作 / 禁止动作”也挂到同一权威模型上

#### 验收标准

- 文档、实现、回归不再出现同一字段多套枚举
- 新增枚举或修改枚举时，有明确同步点

---

### P0-3. 已补最小真实 smoke test

#### 当前状态

这条已不再是未来任务。

当前仓库已具备并持续扩充：

- `tests/installer-smoke.sh`

且已覆盖的真实 CLI 主路径不再只停留在最小 happy path，而是至少包括：

- README/INSTALL 风格的非交互真实执行成功路径
- `--execute-apply --run-nginx-test --nginx-test-cmd 'false' --yes` 的 `needs-attention` 收口
- inspection-first `--resume ... --execute-apply --yes` refusal
- generator fail-fast / 非零退出样本
- 普通 success-source 的正向 `resume + dry-run`
- `--doctor` CLI 入口
- inspection-first source run 的正向 review-first `resume + dry-run`

#### 现在的重点

这条的重点已经从“先补一个 smoke test”转成：

- 是否继续补最值钱的新入口
- 是否让 smoke 断言持续对齐实现真相源
- 是否避免 fixture / smoke / docs / handoff 四层重新漂移

---

## P1：紧接着做（把原型推进到可靠工程）

### P1-1. 模块化拆分 `install-interactive.sh`

#### 目标

把当前大脚本拆成更清晰的职责层。

#### 建议拆分方向

至少拆出：

- CLI / arg parsing
- input collection
- preflight runner
- generator runner
- apply runner
- summary / result writer

#### 重点

- 收掉重复 execute path
- 抽统一 runner / finalize helper
- 把交互提示与状态推进逻辑分开

#### 验收标准

- 主入口更多只负责编排
- 关键策略不再散落在主脚本长分支里

---

### P1-2. 拆分 `scripts/lib/state.sh`

#### 目标

把“状态账本”与“诊断呈现”拆开。

#### 建议拆分

- state IO
- lineage / resume resolution
- doctor rendering

#### 原因

`doctor` 这种格式化呈现逻辑，不应和状态写入/回写搅在同一个 Bash 文件里。

#### 验收标准

- 调整 doctor 输出，不易误伤状态账本
- 调整 lineage/resume 逻辑，不易误伤 human-facing rendering

---

### P1-3. deploy config 序列化改造已完成，后续保持 regression 护栏

#### 当前状态

`write_deploy_config()` 已由 Python / `PyYAML` 接管，当前重点不再是替换 writer 本身，而是防止后续字段扩展或重构时把安全序列化能力写回退。

#### 建议动作

- 持续维护 `tests/deploy-config-yaml-regression.sh` 的高风险样本
- 新增 deploy config 字段时，优先补对应 regression，再改 writer / reader
- 保持“installer 写出 YAML”与“generator 读回 YAML”两段链路都在同一条回归里被覆盖

#### 验收标准

- 多行字符串、空字符串、边界空白、YAML-like scalars 等样本不会把 YAML 结构写坏
- `bash tests/deploy-config-yaml-regression.sh` 能稳定钉住 writer / reader 的当前行为
- 后续扩字段时，不需要重新依赖 shell 手工转义

---

### P1-4. 已接入最小 CI

#### 当前状态

这条同样已不再是未来任务。

当前仓库已存在：

- `.github/workflows/installer-regressions.yml`

并会自动执行：

- `bash tests/deploy-config-yaml-regression.sh`
- `bash tests/installer-smoke.sh`
- `bash tests/installer-summary-isolation.sh`
- `bash tests/installer-contracts-regression.sh`

#### 现在的重点

- 保持 workflow 与本地推荐回归入口一致
- 新增高价值 regression 时，优先判断是否纳入现有 workflow
- 避免 roadmap / handoff / README 继续把已完成的 smoke / CI 写成未来 TODO

---

## P2：在 P0/P1 之后再做

### P2-1. 文档信息架构重排

#### 建议目录分层

- `docs/operator/`
- `docs/architecture/`
- `docs/archive/`
- （可选）`docs/dev/`

#### 目标

让新读者能快速判断：

- 哪些是权威入口
- 哪些是 operator 文档
- 哪些是 architecture/design
- 哪些只是阶段性材料

---

### P2-2. 进一步收口 result contract / state model 生成方式

如果 P0/P1 顺利，进一步考虑：

- 用统一 schema/常量源生成 docs / fixtures / validators 的一部分
- 让“契约”更接近代码生成/代码校验，而不是分散维护

---

## 6. 中期演进方向：是否迁 Python？

### 结论

**值得考虑，而且大概率是正确方向。**

但建议采用：

- **不推倒重写**
- **保留 shell 叶子节点**
- **逐步把 orchestration/control-plane 迁到 Python**

### 优先迁移对象

- config serialization
- run state update
- summary generation
- resume resolution
- doctor rendering
- orchestration main loop

### 暂不优先迁移对象

- generator 主逻辑
- apply/repair/rollback 的叶子执行脚本

---

## 7. 建议的执行顺序（我们接下来按这个打）

### Phase 0：冻结功能扩展

- 暂停继续加 installer 新能力
- 暂停继续扩 doctor / resume 语义
- 先修 correctness / contract / smoke/CI

### Phase 1：修 correctness

1. 修非交互 happy path / 提前退出 / summary 假成功
2. 统一 `status.*` 枚举
3. 继续扩最值钱的真实 smoke 入口，并保持断言与实现真相源对齐

### Phase 2：补工程护栏

4. 维护已接入 CI，与本地回归入口保持一致
5. 维护 deploy config YAML regression，防止序列化回退

### Phase 3：拆 Bash 编排层

6. 拆 `install-interactive.sh`
7. 拆 `state.sh`

### Phase 4：文档和信息架构收口

8. 文档重排：operator / architecture / archive
9. 收口 README / INSTALL / runbook / archive 的权威入口说明

### Phase 5：中期 Python 化

10. 逐步把 orchestration/control-plane 迁到 Python

---

## 8. 当前不做的事

以下事项**暂不作为当前轮主线**：

- 不全盘重写仓库
- 不先重写 generator 主线
- 不先做激进自动化能力扩展
- 不先做大规模文档搬家而忽略 correctness
- 不继续只补 fixture，而不补真实执行 smoke

---

## 9. 第一批待执行任务（建议立刻开始）

### Task 1（P0）
修非交互 happy path / summary 假成功

### Task 2（P0）
统一状态枚举，先修 `status.preflight` 漂移

### Task 3（P1）
继续扩最值钱的新 smoke 入口，并保持 smoke / contract / docs / handoff 口径同步

### Task 4（P1）
维护现有 CI workflow 与本地推荐回归入口一致

### Task 5（P1）
维护 `write_deploy_config()` 的 YAML regression，确保后续字段扩展不会把结构化序列化退回到脆弱的字符串拼接

---

## 10. 备注

这份路线图的核心不是“换语言”，而是：

> 先把 installer/control-plane 从“能跑的实验骨架”，推进到“有护栏、可维护、可继续演化的编排层”。
