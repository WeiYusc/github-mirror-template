# Interactive Installer 设计草案（中文优先）

> 状态：实验分支设计稿
> 分支：`weiyusc/exp/interactive-installer`
> 目标：在不破坏现有 generator 内核的前提下，为 `github-mirror-template` 增加一层“中文交互式安装 / apply orchestration”能力。

---

# 1. 设计背景

当前 `github-mirror-template` 已具备：

- 模板层：`conf.d/`、`snippets/`、`html/errors/`
- 渲染层：`render-from-base-domain.sh`
- 校验层：`validate-rendered-config.sh`
- 生成层：`generate-from-config.sh`
- 交付层：`dist/<deployment_name>/` + 中文部署文档

当前项目已经能稳定完成：

> 配置输入 → 渲染/校验 → 生成可审查部署包

但仍未解决“第一次上手部署成本高”的问题，主要表现为：

1. 需要手工理解 `deploy.yaml` 字段
2. 需要自己选择域名模型
3. 需要自己判断平台差异（宝塔 / plain nginx）
4. 需要自己组织证书策略
5. 需要自己做部署前检查
6. 需要自己把“生成”衔接到“应用”

因此，本轮实验分支不再只关注 generator，而是引入一层：

> 交互式安装 / 应用编排层（installer-orchestrator）

---

# 2. 核心结论

本分支建议的方向不是：

- 把项目整体翻成 installer-first
- 直接做无脑一键上线器
- 自动接管全部线上环境

而是：

> 保留现有 generator 作为稳定内核，在外层增加一层“交互式安装 / apply orchestration”能力。

一句话：

> generator 仍是核心；installer 只是 orchestration layer。

---

# 3. 分层建议

建议把项目明确拆成三层：

## L1 模板层

职责：

- 提供 Nginx 模板本体
- 提供错误页模板
- 提供 snippets 骨架

当前对应内容：

- `conf.d/`
- `snippets/`
- `html/errors/`

## L2 生成层（现有核心）

职责：

- 从声明式配置生成标准部署包
- 产出 `dist/<deployment_name>/`
- 生成中文部署说明、DNS 检查清单、风险提示等文档

当前对应入口：

- `generate-from-config.sh`

设计原则：

- 不直接碰线上
- 先生成，再审查，再应用

## L3 安装 / 编排层（本轮新增）

职责：

- 通过中文交互收集部署输入
- 执行 preflight 检查
- 生成 `deploy.yaml`
- 调用 generator
- 输出安装计划
- 在用户显式确认后执行受控 apply

建议入口：

- `install-interactive.sh`
- `apply-generated-package.sh`

---

# 4. 本轮 installer 的目标定位

本轮实验分支中的 installer 应定位为：

> 带交互引导和前置检查的安装编排器

而不是：

> 黑盒式的一键接管生产安装器

这意味着：

- 它可以帮助管理员少填、少猜、少踩坑
- 它可以做更多自动检查和有限自动 apply
- 但它不应在未确认情况下直接接管生产环境

---

# 5. 设计原则

## 5.1 保留 generator 内核稳定性

新增 installer 逻辑不应把 `generate-from-config.sh` 变成一坨“大一统万能脚本”。

installer 应作为上层入口存在，而不是把 generator 本身演化成所有职责的总入口。

## 5.2 继续坚持“先生成，再审查，再应用”

即使支持交互式安装，也应保留清晰阶段：

1. 收集输入
2. 做 preflight
3. 生成部署包
4. 显示计划
5. 显式确认后 apply

## 5.3 中文优先

本轮交互、提示、文档、执行摘要都应优先提供中文说明。

技术标识（脚本名、变量名、字段名、目录名）继续保留英文。

## 5.4 默认保守，显式升级

高风险动作：

- 覆盖已有配置
- reload nginx
- 自动申请证书
- 写入宝塔/nginx 目标目录

都应默认保守，并要求显式确认。

补充说明：

- `tls.mode=existing` 才要求 `tls.cert` / `tls.key` 在输入期就齐全。
- `tls.mode=acme-http01` / `tls.mode=acme-dns-cloudflare` 当前先停留在 Phase 1 review-first scaffolding：installer / generator 可以产出对齐后的 preflight / state / plan artifacts，但不应把“自动申请证书”当作这一阶段已经完成的能力。

---

# 6. 交互式 installer 应承担的职责

## 6.1 输入收集

installer 应负责通过中文问答收集：

- `deployment_name`
- `domain.base_domain`
- `domain.mode`
- `deployment.platform`
- `tls.mode`（`existing` / `acme-http01` / `acme-dns-cloudflare`）
- 证书方案（已有证书 / 自动申请）
- `paths.error_root`
- `paths.log_dir`
- `paths.output_dir`
- 是否 review before apply
- 是否仅生成、不落地

## 6.2 preflight 检查

installer 应负责在真正生成/落地前进行：

- 依赖检查（bash、python3、PyYAML、nginx 等）
- 平台检查（plain nginx / bt-panel-nginx）
- 路径检查（目标目录、证书路径、输出目录）
- DNS 检查（域名是否已指向当前机器）
- 端口检查（80/443 是否被占用，是否影响证书申请）
- TLS mode 对应的计划输出（例如在 `acme-http01` / `acme-dns-cloudflare` 下先生成 `TLS-PLAN.*`，而不是直接执行签发）

## 6.3 配置生成

installer 应把交互结果落为标准配置文件，例如：

- `deploy.yaml`
- 或 `.generated/deploy.generated.yaml`

然后调用现有：

- `./generate-from-config.sh --config ...`

## 6.4 安装计划展示

在真正 apply 前，installer 应明确展示：

- 将生成哪些内容
- 将复制哪些文件
- 将修改哪些路径
- 将使用哪套证书
- 将执行哪些检查 / reload
- 哪些步骤不会自动执行

## 6.5 受控 apply

在用户显式确认后，installer 可执行有限自动化动作：

- 创建目标目录
- 复制错误页
- 复制 snippets
- 复制 vhost/conf
- 备份已存在配置
- 执行 `nginx -t`
- 成功后 reload nginx

## 6.6 结果摘要与回滚信息输出

installer 最终应输出：

- 实际修改路径清单
- 最终使用的配置摘要
- 证书落点
- DNS 检查结果
- 回滚建议
- 备份文件位置

---

# 7. installer 不应承担的职责

## 7.1 默认不自动改 DNS

当前阶段不应把 DNS provider API 接入作为 MVP 默认能力。

installer 可以检查、报告、阻断，但不应直接代替管理员修改 DNS。

## 7.2 默认不自动删除未知线上配置

发现目标目录已有内容时，不应直接删。

应优先：

- 备份
- 提示
- 显式确认

## 7.3 不把自动申请证书做成黑盒

即便将来支持自动申请，也不应把“申请证书 + 安装配置 + reload”合成黑盒动作。

证书申请过程必须有：

- 前置检查
- 明确日志
- 明确证书路径
- 明确失败点

## 7.4 不突破项目原有安全边界

仍然不支持：

- 登录态
- 私有仓库
- 写操作代理
- PAT / SSH 凭据代理
- 完整 GitHub 会话模拟

---

# 8. 证书方案设计边界

建议抽象成 provider 风格：

## 8.1 方案 A：已有证书（MVP 优先）

管理员提供：

- `tls.cert`
- `tls.key`

installer 负责：

- 检查文件存在
- 检查可读性
- 检查路径形态
- 在 deploy 配置中写入真实路径

优点：

- 风险最低
- 通用性最好
- 最适合作为 MVP 首版支持

## 8.2 方案 B：自动申请证书（后续阶段）

建议后续再支持，并优先考虑：

- HTTP-01
- 基于 `acme.sh` 或 `certbot`

注意：

- 必须先检查域名已解析到当前机器
- 必须确认 80 端口可达
- 必须明确证书最终落点
- 必须输出自动续期方式与失败说明

当前阶段不建议首版就引入：

- DNS-01
- 多 DNS provider API
- 黑盒自动续期管理

---

# 9. 域名模型选择建议

installer 应保留现有两种模式：

- `nested`
- `flat-siblings`

同时在交互中为每种模式提供中文解释。

## `nested`

适合：

- 想把镜像域收束在 `github.example.com` 之下
- 更集中管理的场景

## `flat-siblings`

适合：

- 已有 `*.example.com` 证书
- 宝塔多子域独立建站
- 更直观地管理多个兄弟域名

installer 应在用户选择后，直接展示派生域名预览。

---

# 10. DNS 检查策略

建议 DNS 在 installer 中采用“检查 + 报告 + 分级阻断”，而非“自动修改”。

建议检查：

- hub/raw/gist/assets/archive/download 各域名解析状态
- 是否指向当前服务器 IP
- 是否存在缺漏或不一致

建议输出分级：

- `PASS`
- `WARN`
- `BLOCK`

例如：

- 若选择已有证书、仅生成部署包，则 DNS 不一致可记为 `WARN`
- 若选择 HTTP-01 自动申请证书，但域名未指向本机，则应记为 `BLOCK`

---

# 11. 平台适配建议

建议用平台适配器模式，而不是把逻辑写死在主 installer 里。

例如：

- `scripts/lib/platforms/plain-nginx.sh`
- `scripts/lib/platforms/bt-panel-nginx.sh`

每个平台适配器负责：

- 目标目录推导
- 文件复制策略
- 备份策略
- `nginx -t` 命令
- reload 命令

这样后续扩展会更干净。

---

# 12. MVP 建议范围

建议本轮 MVP 明确控制为：

> 中文交互式配置收集 + preflight 检查 + 生成部署包 + 可选 apply（已有证书优先）

## 建议纳入 MVP

- 中文交互问答
- 生成标准 `deploy.yaml`
- 域名模型选择与派生域名预览
- plain nginx / bt-panel-nginx 的基础识别
- 目标路径存在性与冲突检查
- DNS 基础检查
- 证书路径检查（已有证书）
- 调用现有 generator
- 生成安装计划
- 可选 apply：复制文件、备份、`nginx -t`、reload

## 建议暂不纳入 MVP

- 自动改 DNS
- DNS provider API
- DNS-01 自动申请
- 宝塔深度 API 接管
- 跨多平台高级兼容逻辑
- 复杂事务式回滚系统

---

# 13. 目录结构建议

建议在不破坏主线结构的前提下新增：

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

# 14. 推荐脚本入口

## 14.1 `install-interactive.sh`

职责：

- 交互收集配置
- 运行 preflight
- 写出 deploy 配置
- 调 generator
- 询问是否 apply

## 14.2 `apply-generated-package.sh`

职责：

- 对已生成的部署包执行落地
- 支持非交互重放
- 为将来 CI / 更高自动化留接口

---

# 15. 配置流建议

建议整体流程固定为：

1. 中文交互输入
2. 生成配置对象
3. 写出 `deploy.yaml`
4. 调 `generate-from-config.sh`
5. 输出 `dist/<deployment_name>/`
6. preflight / apply 计划展示
7. 用户显式确认
8. `apply-generated-package.sh`

此设计可确保：

- 配置仍然是单一事实源
- generator 仍是稳定核心
- install/apply 失败可重试
- 结果仍可审计、可 diff、可回滚

---

# 16. 高风险动作与确认策略

## 必须显式确认

- 覆盖已有 Nginx / 宝塔配置文件
- 覆盖已有 snippets
- 覆盖目标错误页目录内容
- reload nginx
- 自动申请证书
- 接管已存在的同名站点/域名

## 默认拒绝

- 自动删除未知配置
- 自动修改 DNS
- 自动停掉现有业务站点
- 自动迁移复杂现网配置
- 在 preflight `BLOCK` 状态下继续执行破坏性操作

---

# 17. 当前推荐路线

当前推荐路线不是“立刻实现所有自动化”，而是：

1. 先定 installer 架构边界
2. 先定 MVP 范围
3. 先定目录结构与脚本职责
4. 再开始写交互/检查/apply 逻辑

因此本分支的第一步建议是：

- 先完成设计文档
- 再进入脚本骨架实现

---

# 18. 一句话总结

本实验分支的正确方向是：

> 不把 `github-mirror-template` 从 generator 改造成黑盒 installer，
> 而是在保留 generator 内核的前提下，加一层中文优先、可审计、可确认、可回滚的交互式安装编排层。
