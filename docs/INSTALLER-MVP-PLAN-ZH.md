# Interactive Installer MVP 计划（中文优先）

> 状态：实验分支 MVP 规划稿
> 对应设计稿：`docs/INSTALLER-DESIGN-ZH.md`

---

# 1. 目标

为 `github-mirror-template` 增加一条新的实验性工作流：

> 管理员通过中文交互式脚本提供基础部署信息，脚本完成 preflight 检查、生成标准部署包，并在显式确认后执行受控 apply。

本阶段目标不是“黑盒一键接管”，而是：

- 降低第一次部署门槛
- 固化部署知识
- 减少人工漏项
- 保持生成结果可审计
- 为后续证书自动化与更高阶 apply 能力打基础

---

# 2. MVP 范围

## 2.1 纳入 MVP

### 交互式输入

支持收集：

- `deployment_name`
- `domain.base_domain`
- `domain.mode`
- `deployment.platform`
- 证书方案（首版优先已有证书）
- `paths.error_root`
- `paths.log_dir`
- `paths.output_dir`
- 是否仅生成 / 是否继续 apply
- 是否在真实 apply 后执行 `nginx -t`

### preflight 检查

支持：

- `bash` / `python3` / `PyYAML` / `nginx` 可用性检查
- plain nginx / bt-panel-nginx 基础环境识别
- 目标路径存在性与可写性检查
- 证书路径存在性检查（已有证书）
- 域名解析基础检查
- 80 / 443 端口基础检查（用于提示，不一定都阻断）
- 进入真实 apply 前的部署包结构校验与目标路径校验

### 配置生成与渲染

支持：

- 根据交互结果生成标准配置文件
- 调用 `generate-from-config.sh`
- 生成 `dist/<deployment_name>/`

### 安装计划展示

支持：

- 列出本次将生成/复制/修改的内容
- 展示派生域名
- 展示证书方案
- 展示 apply 前确认提示
- 展示逐文件 candidate copy plan

### 可选 apply

支持：

- 创建目标目录
- 复制错误页
- 复制 snippets
- 复制 vhost/conf
- 备份已有文件
- 可选执行 `nginx -t`
- 在 `nginx -t` 失败时输出执行摘要与回滚提示
- 写出 `APPLY-RESULT.md`
- 默认不 reload nginx

---

## 2.2 暂不纳入 MVP

- 自动改 DNS
- DNS provider API 对接
- DNS-01 证书自动申请
- 宝塔深度 API 接管
- 复杂事务式回滚
- 多平台高级兼容
- 完整自动续期闭环管理

---

# 3. 推荐目录骨架

```text
github-mirror-template/
├── install-interactive.sh
├── apply-generated-package.sh
├── scripts/
│   └── lib/
│       ├── ui.sh
│       ├── config.sh
│       ├── checks.sh
│       ├── dns.sh
│       ├── tls.sh
│       ├── backup.sh
│       └── platforms/
│           ├── plain-nginx.sh
│           └── bt-panel-nginx.sh
├── docs/
│   ├── INSTALLER-DESIGN-ZH.md
│   └── INSTALLER-MVP-PLAN-ZH.md
```

---

# 4. 组件职责拆分

## 4.1 `install-interactive.sh`

职责：

- 中文交互入口
- 收集配置
- 调用 preflight
- 写配置文件
- 调 generator
- 显示安装计划
- 询问是否继续 apply
- 询问是否在真实 apply 后执行 `nginx -t`

## 4.2 `apply-generated-package.sh`

职责：

- 根据已生成的包执行落地
- 支持非交互 apply
- 在当前阶段至少支持 `--dry-run` / `--print-plan`
- 输出候选复制计划（candidate copy plan）
- 在进入真实 apply 前执行目标路径 / 部署包结构校验
- 集中处理复制、备份、测试、reload 逻辑
- 写出 `APPLY-RESULT.md`

## 4.3 `scripts/lib/ui.sh`

职责：

- 中文提示
- 选项菜单
- yes/no 确认
- 彩色输出（如有）

## 4.4 `scripts/lib/config.sh`

职责：

- 接收交互结果
- 组装 deploy 配置
- 写出 YAML

## 4.5 `scripts/lib/checks.sh`

职责：

- 统一 preflight 框架
- 汇总 `PASS` / `WARN` / `BLOCK`

## 4.6 `scripts/lib/dns.sh`

职责：

- 解析派生域名
- 对比当前服务器 IP
- 输出 DNS 检查摘要
- 在当前阶段至少提供派生域名 / DNS 摘要骨架

## 4.7 `scripts/lib/tls.sh`

职责：

- 检查已有证书路径
- 后续可扩展自动申请证书逻辑
- 在当前阶段至少提供证书路径检查摘要骨架

## 4.8 `scripts/lib/backup.sh`

职责：

- 备份已有目标文件
- 生成备份路径清单
- 在当前阶段至少提供备份计划输出骨架

## 4.9 `scripts/lib/apply-plan.sh`

职责：

- 校验部署包结构是否完整
- 校验目标路径输入是否基本合理
- 输出逐文件 candidate copy plan
- 为真实 apply 前的安全台阶提供统一入口

## 4.10 `scripts/lib/platforms/*.sh`

职责：

- 平台适配
- 推导目标路径
- 定义测试/reload 命令
- 控制宝塔/plain nginx 差异

---

# 5. 交互流程草图

## Step 1：欢迎与边界提示

向管理员明确说明：

- 当前脚本不是黑盒一键接管器
- 当前流程仍然遵循“先生成、再审查、再应用”
- 高风险动作会再次确认

## Step 2：收集基础参数

依次收集：

1. 部署名
2. 基础域名
3. 域名模型
4. 目标平台
5. 证书方案
6. 错误页目录
7. 日志目录
8. 输出目录

## Step 3：展示派生域名与配置摘要

例如：

- Hub 域名
- Raw 域名
- Gist 域名
- Assets 域名
- Archive 域名
- Download 域名

## Step 4：执行 preflight

输出：

- 依赖检查结果
- 平台检查结果
- DNS 检查结果
- 路径检查结果
- 证书检查结果

并给出总体评级：

- 可继续
- 有警告但可继续
- 存在阻断项，建议停止

当前实验分支额外约定：在 generator 完成后，可选择立即进入一次 `apply-generated-package.sh --dry-run --print-plan` 预演；若管理员继续确认，还可进入一次默认不 reload 的真实 apply，并可单独确认是否在 apply 后执行 `nginx -t`。

## Step 5：生成部署包

- 写出 deploy 配置
- 调用 `generate-from-config.sh`
- 输出 dist 路径

## Step 6：显示 apply 计划

- 将修改哪些目录
- 将创建哪些文件
- 将备份哪些现有文件
- 是否会执行 reload nginx

## Step 7：显式确认后 apply

仅在管理员确认后执行。

## Step 8：输出结果与回滚建议

包括：

- 实际落点
- 备份位置
- 检查结果
- 下一步验证建议

---

# 6. preflight 分级建议

建议统一使用：

- `PASS`
- `WARN`
- `BLOCK`

## 6.1 典型 `PASS`

- `python3` 可用
- `PyYAML` 可用
- `nginx` 可用
- 证书路径存在
- 输出目录可写

## 6.2 典型 `WARN`

- DNS 尚未全部就绪，但当前只做生成不 apply
- 输出目录已存在但为空
- 路径看起来像生产目录，需要再次确认

## 6.3 典型 `BLOCK`

- 关键依赖缺失
- 目标平台识别失败
- 证书文件不存在（已有证书模式）
- 目标配置目录不可写
- 自动证书模式下，域名未解析到当前主机
- `nginx -t` 失败

---

# 7. apply 策略建议

MVP 阶段的 apply 应保持保守。

## 7.1 允许自动执行的动作

- 创建目录
- 复制文件
- 备份旧文件
- 执行 `nginx -t`
- 写出 `APPLY-RESULT.md`

## 7.2 必须显式确认的动作

- 覆盖已有配置
- 覆盖已有 snippets
- 覆盖目标错误页目录
- 进入真实 apply
- 执行 `nginx -t`
- reload nginx

## 7.3 默认拒绝的动作

- 自动删除未知文件
- 自动改 DNS
- 自动接管已存在复杂站点
- preflight 存在 `BLOCK` 时继续破坏性操作

---

# 8. 首版证书策略

MVP 推荐首版仅正式支持：

- 已有证书路径

交互中可保留“自动申请证书”选项说明，但首版应明确标注：

- 暂未实现
- 或仅进入设计占位流程

这样可以避免过早把工程复杂度拉高。

---

# 9. 开发顺序建议

建议按以下顺序推进：

## Phase A：设计定稿

- 完成 `INSTALLER-DESIGN-ZH.md`
- 完成 `INSTALLER-MVP-PLAN-ZH.md`

## Phase B：目录与脚本骨架

- 新建 `install-interactive.sh`
- 新建 `apply-generated-package.sh`
- 新建 `scripts/lib/` 目录和空骨架

## Phase C：只做交互 + 生成

- 先实现输入收集
- 先实现 deploy 配置写出
- 先实现调用 generator
- 暂不 apply

## Phase D：补 preflight

- 引入统一检查框架
- 实现 PASS/WARN/BLOCK 汇总

## Phase E：补 apply

- 先做 plain nginx
- 再做 bt-panel-nginx
- 先支持已有证书

## Phase F：文档与示例

- 增补 README 中的 installer 实验说明
- 增补操作示例
- 增补已知限制说明

---

# 10. 验收标准（MVP）

当满足以下条件时，可认为 MVP 达标：

1. 管理员可以通过中文交互完成一套 deploy 配置输入
2. 脚本能调用现有 generator 正常输出 `dist/<deployment_name>/`
3. 能输出清晰的 preflight 结果
4. 能输出 apply 计划
5. 在已有证书模式下，可对 plain nginx / bt-panel-nginx 至少一种平台完成受控 apply
6. 失败时不会无提示破坏线上环境
7. 最终有明确结果摘要、`APPLY-RESULT.md` 与回滚提示

---

# 11. 当前建议

本 MVP 不追求“立即变成全自动 installer”，而追求：

> 先把“部署知识 + 人工步骤 + 风险边界”整理成一个可执行、可检查、可确认的中文交互流程。

这是比直接写大脚本更稳、更可持续的第一步。
