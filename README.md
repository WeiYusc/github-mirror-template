# GitHub Mirror Template Pack

一个用于部署 **GitHub 公共只读镜像** 的 Nginx/宝塔模板包。

它的目标不是“克隆一个完整 GitHub”，而是提供一套 **可部署、可审计、可回滚** 的公共只读镜像方案，覆盖：

- 公共仓库页面浏览
- `raw` 文件访问
- `gist` 页面与 gist raw
- `archive` 源码包下载
- `release download` 下载链路
- GitHub 静态资源镜像

适用场景包括：

- 搭建公共只读镜像部署环境
- 在 Nginx / 宝塔环境中按模板落地多域镜像
- 基于现有配置骨架继续做审计、裁剪和二次改造

---

# Quick Start

如果你只是想最快确认这套模板怎么用，推荐优先走 **v0.2 声明式生成流程**：

1. 复制 `deploy.example.yaml`
2. 按你的环境修改成 `deploy.yaml`
3. 运行 `generate-from-config.sh`
4. 检查生成出来的 `dist/<deployment-name>/`
5. 按 `INSTALL.md` / `BT-PANEL-DEPLOYMENT-v1.md` 做人工落地

最短命令路径：

```bash
cp deploy.example.yaml deploy.yaml

./generate-from-config.sh --config ./deploy.yaml
```

> 说明：`generate-from-config.sh` 当前依赖 `python3` 和 Python `PyYAML`。

生成器会：

- 调用底层渲染器生成 conf/snippets/errors
- 调用底层校验器做静态自检
- 额外生成中文版部署说明、DNS 检查清单、风险说明和摘要

它不会：

- 自动修改线上 Nginx
- 自动 reload
- 自动改 DNS
- 自动接管生产环境

如果你暂时还想直接使用底层渲染器，也可以继续走原来的 5 步：

1. 选定 `BASE_DOMAIN` 与 `DOMAIN_MODE`
2. 运行 `render-from-base-domain.sh` 渲染实际配置副本
3. 运行 `validate-rendered-config.sh` 做静态自检
4. 按 `INSTALL.md` / `BT-PANEL-DEPLOYMENT-v1.md` 落地到宝塔/Nginx
5. 用 `DEPLOY-CHECKLIST.md` 做上线前后验收

底层脚本示例：

```bash
./render-from-base-domain.sh \
  --base-domain github.example.com \
  --domain-mode flat-siblings \
  --ssl-cert /path/to/fullchain.pem \
  --ssl-key /path/to/privkey.pem \
  --error-root /www/wwwroot/github-mirror-errors \
  --log-dir /www/wwwlogs \
  --output-dir ./rendered/github.example.com

./validate-rendered-config.sh \
  --rendered-dir ./rendered/github.example.com
```

详细步骤看：

- `INSTALL.md`
- `BT-PANEL-DEPLOYMENT-v1.md`
- `DEPLOY-CHECKLIST.md`
- `V0.2-SIMPLIFIED-DEPLOYMENT-DESIGN.md`

---

# 1. 项目定位

这是一个 **GitHub 公共资源只读镜像模板**。

## 支持的能力

- 公共仓库主页、README、文件树、blob 页面只读浏览
- `raw.githubusercontent.com` 对应 raw 文件访问
- `gist.github.com` 与 gist raw 访问
- 源码归档下载（archive / codeload）
- release 下载链路代理
- GitHub 静态资源域镜像

## 明确不支持的能力

- 登录
- OAuth / 授权回调
- 私有仓库
- 任何账号态功能
- star / fork / watch / sponsor
- 新建 issue / PR / discussion
- push / 写入 / 上传
- PAT / token / SSH 凭据代理
- 账户设置、通知、dashboard

## 方法白名单

只允许：

- `GET`
- `HEAD`
- `OPTIONS`

其他方法统一拒绝。

---

# 2. 这不是啥

这不是：

- GitHub 完整替代站
- 登录后还能继续用的代理站
- 私有仓库访问网关
- 一键无脑安装器
- 官方支持的 GitHub 企业分发方案

如果你的目标是：

- 接管 GitHub 账号态功能
- 代理私有仓库
- 支持写操作
- 模拟完整用户会话

那这个项目就 **不适合**。

---

# 3. 当前目录结构

```text
github-mirror-template/
├── conf.d/
├── snippets/
├── html/errors/
├── README.md
├── INSTALL.md
├── OPERATIONS.md
├── FAQ.md
├── CHANGELOG.md
├── LICENSE
├── RELEASE-NOTES.md
├── BT-PANEL-DEPLOYMENT-v1.md
├── DEPLOY-CHECKLIST.md
├── DOMAIN-PLAN.md
├── TEMPLATE-VARIABLES.md
├── REDIRECT-WHITELIST-DESIGN.md
├── REDIRECT-WHITELIST-CONFIG-SKETCH.md
├── deploy.example.yaml
├── V0.2-SIMPLIFIED-DEPLOYMENT-DESIGN.md
├── generate-from-config.sh
├── render-from-base-domain.sh
└── validate-rendered-config.sh
```

---

# 4. 域名模型

当前模板支持两种域名模式：

- `nested`
- `flat-siblings`

## 4.1 nested

示例：

- `BASE_DOMAIN=github.example.com`
- 派生：
  - `raw.github.example.com`
  - `gist.github.example.com`
  - `assets.github.example.com`
  - `archive.github.example.com`
  - `download.github.example.com`

## 4.2 flat-siblings

示例：

- `BASE_DOMAIN=github.example.com`
- 派生：
  - `github.example.com`
  - `raw.example.com`
  - `gist.example.com`
  - `assets.example.com`
  - `archive.example.com`
  - `download.example.com`

这个模式适合：

- 复用已有 `*.example.com` 通配符证书
- 避免再申请 `*.github.example.com` 这一层通配符
- 在宝塔中按 6 个兄弟子域独立建站

---

# 5. 模板包含的内容

模板包包含：

- hub/raw/gist/assets/archive/download 六类站点模板
- `render-from-base-domain.sh` 渲染脚本
- `validate-rendered-config.sh` 渲染结果静态自检脚本
- redirect whitelist 配置骨架
- 只读方法限制
- 高危/账号态路径拦截
- 两类自定义错误页：
  - 登录/授权已禁用
  - 只读镜像限制
- 宝塔/Nginx 手工部署文档
- 部署检查清单

---

# 6. 交付形态与使用方式

它目前的定位是：

> 一套以“手工审计部署”为主的模板包。

它还不是：

> 任意服务器上一条命令自动装完的成熟安装器。

上线前仍然需要人工确认：

- 证书路径
- 宝塔 vhost 目录布局
- snippets 最终 include 路径
- `http {}` 范围的 redirect whitelist map 接入
- DNS 解析
- `nginx -t` 检查
- 实站联调与抽样验收

---

# 7. 安全边界

这个项目的安全边界非常明确：

## 7.1 只读

- 非 `GET/HEAD/OPTIONS` 请求会被拒绝

## 7.2 账号态禁用

登录/账号/授权相关路径会进入单独提示页，例如：

- `/login`
- `/session`
- `/signup`
- `/settings/`
- `/account/`
- `/notifications`
- `/dashboard`

## 7.3 写操作禁用

只读镜像下不支持的交互路径会进入只读限制提示页，例如：

- `/fork`
- `/issues/new`
- `/pull/new`
- `/compare`
- `/releases/new`
- `/star`
- `/watching`
- `/sponsors`

## 7.4 不盲跟上游跳转

`archive` / `download` 下载链路必须通过 redirect whitelist 收口，不能无条件跟随任意上游 `Location`。

---

# 8. 最短使用路径

## 8.1 渲染模板

```bash
./render-from-base-domain.sh \
  --base-domain github.example.com \
  --domain-mode flat-siblings \
  --ssl-cert /path/to/fullchain.pem \
  --ssl-key /path/to/privkey.pem \
  --error-root /www/wwwroot/github-mirror-errors \
  --log-dir /www/wwwlogs \
  --output-dir ./rendered/github.example.com
```

## 8.2 运行静态自检

```bash
./validate-rendered-config.sh \
  --rendered-dir ./rendered/github.example.com
```

## 8.3 按部署文档落地

优先阅读：

1. `INSTALL.md`
2. `BT-PANEL-DEPLOYMENT-v1.md`
3. `DEPLOY-CHECKLIST.md`
4. `OPERATIONS.md`
5. `FAQ.md`

---

# 9. 文档导航

## 快速了解

- `README.md`
- `DOMAIN-PLAN.md`
- `TEMPLATE-VARIABLES.md`

## 开始安装

- `INSTALL.md`
- `BT-PANEL-DEPLOYMENT-v1.md`
- `DEPLOY-CHECKLIST.md`

## 理解下载链路收口

- `REDIRECT-WHITELIST-DESIGN.md`
- `REDIRECT-WHITELIST-CONFIG-SKETCH.md`

## 理解运维与回滚

- `OPERATIONS.md`
- `FAQ.md`

## 发布相关

- `CHANGELOG.md`
- `LICENSE`
- `RELEASE-NOTES.md`
- `PUBLIC-RELEASE-CHECKLIST.md`
- `REPO-METADATA-SUGGESTIONS.md`

---

# 10. 部署原则

部署时始终遵守：

1. 不覆盖现有站点 conf
2. 不修改现有业务域名逻辑
3. 所有镜像服务使用新域名增量接入
4. 先备份
5. 先写磁盘
6. 先 `nginx -t`
7. 通过后再 reload
8. 失败立即回滚新增配置

---

# 11. 推荐阅读顺序

如果你第一次接触这个项目，建议按顺序读：

1. `README.md`
2. `INSTALL.md`
3. `BT-PANEL-DEPLOYMENT-v1.md`
4. `DEPLOY-CHECKLIST.md`
5. `OPERATIONS.md`
6. `FAQ.md`
7. `RELEASE-NOTES.md`
8. `PUBLIC-RELEASE-CHECKLIST.md`


