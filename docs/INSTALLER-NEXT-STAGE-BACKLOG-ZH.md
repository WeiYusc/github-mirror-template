# github-mirror-template 下一阶段可执行 Backlog（架构视角）

> 适用分支：`weiyusc/exp/interactive-installer`
> 目的：把当前“架构回顾结论”转成可以继续推进的工作清单，而不是停留在口头判断。
> 当前判断：项目已经拥有稳定的 `v0.2 generator` 内核，以及具备恢复语义雏形的 `v0.3/v0.4 installer orchestration`。`INSTALLER-STATE-MODEL-ZH.md` 已经落地；下一阶段最值得优先投入的，不是继续横向堆功能，而是继续把 **结果契约 / 回归体系 / 信息架构** 收紧，再决定是否继续向更激进自动化扩展。

---

## 0. 当前共识与目标校准

### 已经稳定成立的部分

- `v0.2`：声明式 generator 路线已经是稳定内核
  - `deploy.example.yaml`
  - `generate-from-config.sh`
  - `render-from-base-domain.sh`
  - `validate-rendered-config.sh`
  - `dist/<deployment_name>/` 标准部署包
- `v0.3+`：interactive installer 已不再是 demo，而是具备以下能力的安装/编排骨架
  - 中文交互 / flags 混合输入
  - preflight / DNS / TLS 只读检查
  - apply dry-run / conservative execute
  - `run_id`、`state.json`、`journal.jsonl`
  - `--doctor` / `--resume`
  - `repair` / `rollback`
  - lineage / resume strategy / result summary

### 当前真正缺的不是“更多功能”，而是“三个后续收口”

1. **结果契约收口**：把 state / apply / repair / rollback 等 JSON 产物继续提升为更稳定的契约
2. **回归体系收口**：把 `doctor / resume / repair / rollback` 的行为固定下来
3. **信息架构收口**：把对外入口和内部设计材料分层整理

---

## 1. 总体优先级

按建议优先级分为：

- **P0：现在最该做，做完后整个系统会更稳**
- **P1：紧接着做，能把“原型”推进到“可靠工程”**
- **P2：在 P0/P1 之后再扩，避免放大风险**
- **P3：可选增强，暂不抢**

---

## 2. P0：状态机与结果契约正式化

### P0-1. 继续维护权威状态模型文档

**现状**：`docs/INSTALLER-STATE-MODEL-ZH.md` 已落地

#### 目标

把当前散落在代码、runbook、doctor 输出里的“真实运行语义”收成一个单一真相源。

#### 最低应覆盖内容

- run 生命周期的主阶段
  - input collection
  - preflight
  - generator
  - apply plan
  - apply dry-run
  - apply execute
  - repair
  - rollback
  - final
- `checkpoint` 的取值、含义、进入条件、退出条件
- `status.*` 的枚举与含义
- `final` 如何从局部状态归并
- `resume_strategy` 的枚举、适用场景与禁止动作
- `doctor` 应优先消费哪些结果文件
- `repair` / `rollback` / `resume` 的优先级关系
- 哪些 JSON 字段属于**稳定契约**，哪些仍属内部实现细节

#### 验收标准

- 架构师/维护者不看源码，也能回答：
  - 一个 run 现在处于什么阶段
  - 为什么是 `needs-attention` 而不是 `failed`
  - 当前是否允许 `--execute-apply`
  - 哪种情况下应先 `repair` 或 `rollback`
- runbook 与 README / INSTALL 中引用的状态术语不再互相漂移

---

### P0-2. 给 JSON 结果文件加“契约意识”

#### 目标

把现有这些产物从“代码顺手写出的结构”提升为“可依赖的结果契约”：

- `state.json`
- `INSTALLER-SUMMARY.json`
- `APPLY-PLAN.json`
- `APPLY-RESULT.json`
- `REPAIR-RESULT.json`
- `ROLLBACK-RESULT.json`

#### 建议动作

- 明确每个文件的职责边界
- 给每个文件补 schema 概览表
- 增加 `schema_version` 或等价版本字段
- 记录兼容策略：
  - 新字段是否允许追加
  - 旧 run 如何兼容
  - `doctor` 如何做向后兼容 fallback

#### 验收标准

- 未来调整字段时，不需要靠“读所有历史提交”判断会不会炸旧 run
- `doctor` 的消费顺序可以被文档化、测试化

---

### P0-3. 把“允许动作 / 禁止动作”明确挂到状态模型上

#### 目标

现在系统已经隐含有这些规则：

- 某些 inspection-first resume 下，不允许 `--execute-apply`
- `needs-attention` 不等于可直接继续安装
- rollback 与 repair 不是等价动作

但这些规则目前还偏“藏在实现里”。

#### 建议动作

在状态模型里补一张表：

| 状态/策略 | 允许动作 | 禁止动作 | 推荐动作 |
|---|---|---|---|
| `inspect-after-apply-attention` | `doctor`, `repair --dry-run`, `rollback --dry-run` | `--execute-apply` | 先复核 apply 结果 |
| `post-repair-verification` | `doctor`, `--run-apply-dry-run` | 默认真实 apply | 人工确认后再决定 |
| `post-rollback-inspection` | `doctor`, 手工 `nginx -t` | 直接重放 apply | 先确认现场恢复情况 |

#### 验收标准

- runbook 里的建议不再只是“经验口径”，而是和状态模型一一对应

---

## 3. P1：自动化回归矩阵

### P1-1. 建立 fixture / golden 测试骨架

#### 目标

把当前依赖人工样本回放的验证，升级成可重复运行的回归体系。

#### 首批建议覆盖场景

1. 新 run：generator success
2. 新 run：apply dry-run success
3. 新 run：apply execute success
4. 新 run：apply execute 后 `nginx -t` failed -> `needs-attention`
5. 新 run：apply blocked
6. resumed run：跳过 preflight/generator/apply-plan
7. resumed run：来源 run `resume_recommended=false`
8. resumed run：已有 `REPAIR-RESULT.json`
9. resumed run：已有 `ROLLBACK-RESULT.json`
10. old run：没有显式登记 repair/rollback，但同目录存在结果文件

#### 验收标准

- 能自动判断：
  - `doctor` 输出关键摘要是否漂移
  - `resume_strategy` 是否变化
  - `final status` 是否错误归并
  - fallback 行为是否失效

---

### P1-2. 为 `doctor` 建立输出级回归

#### 目标

`doctor` 已经是这条线里最重要的诊断面板之一，必须把输出口径钉住。

#### 建议动作

- 给代表性 run 样本保留 golden 输出
- 至少覆盖：
  - 普通 run
  - resumed run
  - ancestor abnormal
  - current run needs-attention
  - repair-first
  - rollback-first
- 允许少量非关键行变化，但关键摘要字段必须稳定

#### 验收标准

- 后续再做 helper 收口、文案调整、输出重组时，不会无意改变核心诊断语义

---

### P1-3. 为状态推进写最小单元/集成校验

#### 目标

当前很多核心价值都落在“状态怎么推进、怎么归并、怎么回写”上。

#### 建议动作

优先围绕这些函数/模块建立最小测试：

- `state.sh` 中的状态写入与读取
- 历史 run 读取与 fallback
- `resume` 的 checkpoint 复用判定
- apply / repair / rollback 结果回写路径

#### 验收标准

- 改 `state.sh` 不再只能靠手工重跑真实样本才放心

---

## 4. P1：进一步拆薄 installer orchestration

### P1-4. 继续把主入口从“大脚本”拆成“可维护编排器”

#### 目标

`install-interactive.sh` 现在已经不只是 UI 入口，还承担了：

- 参数解析
- 状态判断
- resume 复用
- generator 调度
- apply 编排
- 结果落盘
- 最终状态归并

短期能扛，但中期容易变成总控巨石。

#### 建议动作

优先做“职责切分”而不是重写语言：

- `scripts/lib/installer-args.sh`
- `scripts/lib/installer-orchestrator.sh`
- `scripts/lib/installer-summary.sh`
- `scripts/lib/resume-policy.sh`
- `scripts/lib/result-contracts.sh`

> 不是必须按这个文件名；重点是把“状态推进逻辑”和“交互提示/UI”分开。

#### 验收标准

- 主入口文件更多是流程串联，而不是承载全部策略细节
- 新增一种 resume policy / result summary，不需要继续把主脚本越堆越厚

---

## 5. P2：文档与信息架构收口

### P2-1. 重新梳理文档分层

#### 当前问题

现在文档很多，而且里面同时混有：

- 面向首次使用者的入口文档
- 面向维护者的设计稿
- 阶段性 round-up
- 面向操作者的异常处理手册

这对内部很有帮助，但对外认知会越来越散。

#### 建议目标结构

### A. 对外 / 新用户

- `README.md`
- `INSTALL.md`

### B. 操作者 / 运维

- `docs/INSTALLER-OPERATOR-RUNBOOK-ZH.md`
- `docs/INSTALLER-STATE-MODEL-ZH.md`

### C. 维护者 / 设计说明

- `docs/INSTALLER-DESIGN-ZH.md`
- `docs/INSTALLER-MVP-PLAN-ZH.md`

### D. 阶段性归档

- `docs/archive/` 或等价位置
  - `INSTALLER-V0.3-ROUNDUP-ZH.md`
  - `INSTALLER-V0.3-SHORT-SUMMARY-ZH.md`
  - `INSTALLER-RECOVERY-ROUNDUP-2026-04-19-ZH.md`

#### 验收标准

- 新人第一次进仓库，知道先看什么
- 运维处理异常时，不会在多份总结文档里找行为规则
- 阶段总结保留，但不继续混在主入口叙事里

---

### P2-2. 把版本语义写得更硬一点

#### 目标

避免后面继续出现“v0.2 / v0.3 / v0.4 到底指什么”的口径漂移。

#### 建议动作

在 README 或独立文档中固定：

- `v0.1`：公开发布的模板包
- `v0.2`：声明式 generator 稳定内核
- `v0.3`：interactive installer / conservative orchestration
- `v0.4`：stateful recovery / aggressive automation exploration

#### 验收标准

- 以后讨论版本时，不再把 installer 分支误说成“v0.2 的小修补”

---

## 6. P2：补一层“现场状态 / 漂移认知”

### P2-3. 设计 drift / reconcile 摘要能力

#### 目标

当前 apply 已有“文件级计划”，但还缺少一层更偏运维产品化的判断：

> 目标部署包、当前机器状态、历史 run 结果，这三者现在是否一致？

#### 可做的最小版能力

- 目标文件是否仍存在
- 当前文件是否仍与上次 source 一致
- `REPLACE` 项是否被人工改过
- `NEW` 项是否已漂移
- 当前现场更接近：
  - “apply 后待修复”
  - “已经部分回滚”
  - “现场已被人工接管修改”

#### 验收标准

- `repair` / `rollback` / `doctor` 不再只会看结果文件，还能对现场状态给出更像样的判断

---

## 7. P3：等核心收口后再扩的功能

这些不是不能做，而是**不建议现在抢在前面**。

### P3-1. fresh server / greenfield bootstrap

包括但不限于：

- 依赖安装
- nginx/目录底座准备
- 站点骨架创建
- 环境初始化

### P3-2. 自动证书

包括：

- 已有证书接入自动化
- HTTP-01 自动签发
- 证书状态续期链路

### P3-3. 更强平台适配

例如更多平台、更多控制面、更多部署环境。

### 为什么放后面

因为如果 **状态机 / 契约 / 回归** 还没稳，自动化越强，风险只会越大。

---

## 8. 建议的实际执行顺序

### Phase A：先稳语义（推荐立即开始）

1. 基于已落地的 `docs/INSTALLER-STATE-MODEL-ZH.md` 继续补结果文件 schema / version / 消费顺序说明
2. 为结果文件补 schema / version / 消费顺序说明
3. 把 `resume_strategy` 的允许/禁止动作表写清楚

### Phase B：再稳行为

4. 建 fixture / golden 回归样本
5. 给 `doctor` / `resume` / `repair` / `rollback` 建核心回归
6. 收口 `state.sh` 与主 orchestration 的策略边界

### Phase C：再稳入口

7. 整理 README / INSTALL / RUNBOOK / ROUNDUP 的层次
8. 把阶段总结文档归档化
9. 明确版本语义与主推荐路径

### Phase D：最后才扩自动化

10. 设计 drift/reconcile 层
11. 评估 fresh server bootstrap
12. 评估自动证书与更激进 apply 路线

---

## 9. 建议的任务拆分粒度（便于后续按 commit / PR 推进）

### 工作包 A：状态模型与契约文档

**目标**：把运行语义钉死

建议产出：
- 继续迭代 `docs/INSTALLER-STATE-MODEL-ZH.md`
- README / INSTALL 中补少量引用

### 工作包 B：结果契约 schema 化

**目标**：让 JSON 结果文件更像正式接口

建议产出：
- schema 说明文档
- `schema_version` / 兼容说明
- `doctor` 向后兼容策略梳理

### 工作包 C：状态语义回归测试

**目标**：把关键 run 场景自动回归起来

建议产出：
- fixture 样本
- golden 输出
- 基础测试脚本

### 工作包 D：installer orchestration 再拆一层

**目标**：减轻主脚本负担

建议产出：
- 策略与 UI 分离
- resume policy 抽象
- result summary / final status 归并逻辑集中

### 工作包 E：文档信息架构重整

**目标**：降低文档噪音，提高对外理解速度

建议产出：
- 主入口收敛
- round-up 归档
- 版本语义明确化

---

## 10. 最终建议（决策版）

如果下一轮只做一件最值的事，我建议是：

> **先做“状态机 + 结果契约 + next-action 规则”的正式化收口。**

原因很简单：

- 这条线当前真正有价值的，不只是多了几个脚本
- 而是已经长出了 **有状态运行 / lineage / resume strategy / operator-safe recovery semantics**
- 这些东西一旦收紧，后面不管是继续保守演进，还是转向更激进自动化，都会更稳

反过来说，如果现在继续优先加 fresh server bootstrap / 自动签证书 / 更强一键安装，而不先钉死运行语义，后面会越来越难控。

---

## 11. 一句话结论

当前 `github-mirror-template` 最值得推进的下一阶段，不是“再多做一点安装自动化”，而是：

> **把 installer 已经长出来的状态语义、恢复契约和行为边界正式化，然后再继续扩。**
