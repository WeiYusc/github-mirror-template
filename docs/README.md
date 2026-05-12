# 文档导航与权威层级

这份索引页的目标是解决一个现实问题：仓库里的文档已经不少，但它们的用途并不完全一样。

当前最容易让新读者困惑的，不是“没有文档”，而是：

- 哪份应该先读
- 哪份是当前权威入口
- 哪份是面向操作的手册
- 哪份只是设计/规划/归档材料

下面按**用途**和**权威等级**整理。

---

## 1. 如果你是第一次来：先从这里读

### 最高优先级入口

1. `../README.md`
   - 仓库总入口
   - 适合先理解项目定位、三条入口（generator / experimental installer / low-level renderer）以及快速开始方式

2. `../INSTALL.md`
   - 当前最适合第一次真正落地时按步骤跟的操作手册
   - 适合从“准备环境 → 选入口 → 生成部署包 → 人工落地/验证”一路顺着读

3. `DEPLOY-BT-PANEL-UI-ZH.md` / `DEPLOY-BT-PANEL-CLI-ZH.md`
   - 当前面向管理员的直接执行手册
   - 一个偏宝塔 UI，一个偏 SSH / 命令行

如果你只想快速跑通主流程，通常 `README.md` + `INSTALL.md` + 对应的 UI/CLI 手册就够了。

---

## 2. 稳定主线（推荐默认）：v0.2 generator / 部署包流程

这些文档围绕当前**稳定主线**组织：先生成部署包，再人工审查和落地。

### 当前权威文档

- `../INSTALL.md`
  - 生成与落地步骤主手册
- `DEPLOY-BT-PANEL-UI-ZH.md`
  - 宝塔 UI 主导的部署手册
- `DEPLOY-BT-PANEL-CLI-ZH.md`
  - SSH / 命令行主导的部署手册
- `BT-PANEL-ACCEPTANCE-CHECKLIST-ZH.md`
  - 宝塔识别、HTTP 链路与上线验收清单
- `BT-PANEL-TROUBLESHOOTING-ZH.md`
  - 宝塔镜像部署常见故障排查
- `../DEPLOY-CONFIG.md`
  - `deploy.yaml` 字段解释与配置方式
- `../BT-PANEL-DEPLOYMENT-v1.md`
  - 宝塔 / Nginx 部署背景说明与兼容参考
- `../DEPLOY-CHECKLIST.md`
  - 上线前后检查清单

### 辅助参考

- `../OPERATIONS.md`
- `../FAQ.md`
- `../TEMPLATE-VARIABLES.md`
- `../V0.2-SIMPLIFIED-DEPLOYMENT-DESIGN.md`

如果你只是要把公共只读镜像部署起来，优先读这一组，不必先钻 installer 内部文档。

---

## 3. 实验路线：interactive installer / orchestration / state control-plane

这一组文档主要服务于当前实验性的 installer 编排层。

### 3.1 当前实现语义的权威文档

如果你要理解**当前实现到底怎么工作**，优先看这三份：

- `INSTALLER-OPERATOR-RUNBOOK-ZH.md`
  - 回答“遇到 `needs-attention` / `blocked` / `failed` / `cancelled` 时现在该怎么处理”
- `INSTALLER-STATE-MODEL-ZH.md`
  - 回答 `state.json` / `checkpoint` / `status.*` / `status.final` / `lineage` / `resume_strategy` / companion result 的当前语义
- `INSTALLER-RESULT-CONTRACTS-ZH.md`
  - 回答 6 类 JSON 结果文件的职责边界、稳定字段、消费顺序与兼容策略

> 如果这三份与更早的设计稿/roundup 有出入，**以这三份为准**。

### 3.2 当前执行与改造方向

如果你要继续推进 installer 改造，优先看：

- `INSTALLER-REFACTOR-ROADMAP-ZH.md`
  - 当前有效的改造路线与优先级
- `INSTALLER-NEXT-STAGE-BACKLOG-ZH.md`
  - 下一阶段 backlog / 候选任务清单

> 这两份属于**当前规划层入口**，不是结果契约本身，但决定“接下来往哪做”。

---

## 4. 历史设计 / 阶段总结 / 归档材料

下面这些文档仍有参考价值，但它们**不是当前一线权威入口**，更适合在需要历史上下文时回看。

### 4.1 设计与早期规划

- `INSTALLER-DESIGN-ZH.md`
- `INSTALLER-MVP-PLAN-ZH.md`

用途：理解这条 installer 路线最初是怎么设想出来的。

### 4.2 阶段性总结 / round-up

- `INSTALLER-V0.3-SHORT-SUMMARY-ZH.md`
- `INSTALLER-V0.3-ROUNDUP-ZH.md`
- `INSTALLER-RECOVERY-ROUNDUP-2026-04-19-ZH.md`

用途：回看某一轮收口时“当时完成了什么”。

### 4.3 归档 / handoff

- `INSTALLER-PAUSE-HANDOFF-2026-04-21-ZH.md`
- `INSTALLER-INSPECTION-FIRST-HANDOFF-2026-04-22-ZH.md`
- `INSTALLER-CONTROL-PLANE-HANDOFF-2026-04-29-ZH.md`
- `INSTALLER-NEW-SESSION-HANDOFF-2026-04-29-ZH.md`

用途：给“下次继续开发时恢复上下文”或“新开会话直接接手”使用；它们不是对外发布说明，也不是面向第一次使用者的入口。

---

## 5. 按角色选阅读路径

### 我只是想部署

按这个顺序读：

1. `../README.md`
2. `../INSTALL.md`
3. `DEPLOY-BT-PANEL-UI-ZH.md` 或 `DEPLOY-BT-PANEL-CLI-ZH.md`
4. `BT-PANEL-ACCEPTANCE-CHECKLIST-ZH.md`
5. `BT-PANEL-TROUBLESHOOTING-ZH.md`
6. `../DEPLOY-CONFIG.md`
7. `../BT-PANEL-DEPLOYMENT-v1.md`

### 我想让 agent 代工，但先了解当前能力边界

按这个顺序读：

1. `../README.md`
2. `../INSTALL.md`
3. `DEPLOY-BT-PANEL-CLI-ZH.md`
4. `BT-PANEL-ACCEPTANCE-CHECKLIST-ZH.md`
5. `BT-PANEL-TROUBLESHOOTING-ZH.md`

### 我想使用实验 installer

按这个顺序读：

1. `../README.md`
2. `../INSTALL.md`
3. `INSTALLER-OPERATOR-RUNBOOK-ZH.md`
4. `INSTALLER-STATE-MODEL-ZH.md`
5. `INSTALLER-RESULT-CONTRACTS-ZH.md`

### 我要继续改 installer

按这个顺序读：

1. `INSTALLER-NEW-SESSION-HANDOFF-2026-04-29-ZH.md`
2. `INSTALLER-REFACTOR-ROADMAP-ZH.md`
3. `INSTALLER-NEXT-STAGE-BACKLOG-ZH.md`
4. `INSTALLER-CONTROL-PLANE-HANDOFF-2026-04-29-ZH.md`
5. `INSTALLER-INSPECTION-FIRST-HANDOFF-2026-04-22-ZH.md`
6. `INSTALLER-STATE-MODEL-ZH.md`
7. `INSTALLER-RESULT-CONTRACTS-ZH.md`
8. `INSTALLER-PAUSE-HANDOFF-2026-04-21-ZH.md`

---

## 6. 一句话规则

- **想部署**：优先看 root `README.md` + root `INSTALL.md`
- **想处理异常 run**：优先看 runbook / state model / result contracts
- **想继续开发 installer**：优先看 roadmap / backlog / state model / result contracts
- **想补历史上下文**：再回看 design / MVP / roundup / handoff
