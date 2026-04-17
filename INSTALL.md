# INSTALL.md

这份文档面向：

- 第一次部署这套 GitHub 公共只读镜像的人
- 准备把模板仓库整理成可发布项目的人
- 需要按步骤落地、而不是只看原理说明的人

本文尽量用“从零到可验收”的顺序来写。

---

# 1. 你要先接受的边界

在继续之前，先确认你部署的是：

- GitHub **公共只读镜像**
- 不是完整 GitHub 替代品
- 不是登录代理
- 不是私有仓库网关

如果你的目标是登录、写入、私有仓库、账号态交互，这套东西不适合。

---

# 2. 依赖与环境要求

至少需要：

- Linux 服务器
- Nginx
- 域名 DNS 控制权
- 可用 TLS 证书
- 可修改 Nginx 配置并 reload 的权限
- `python3`（使用 v0.2 生成器时需要）
- Python `PyYAML`（使用 v0.2 生成器时需要）

推荐环境：

- 宝塔面板 + Nginx
- 有独立镜像域名
- 能复用通配符证书

---

# 3. 选择域名模式

模板支持两种：

- `nested`
- `flat-siblings`

## 推荐：flat-siblings

如果你已有类似 `*.example.com` 的通配符证书，推荐：

```text
BASE_DOMAIN=github.example.com
DOMAIN_MODE=flat-siblings
```

这样实际域名会是：

- `github.example.com`
- `raw.example.com`
- `gist.example.com`
- `assets.example.com`
- `archive.example.com`
- `download.example.com`

## 什么时候用 nested

如果你就是想把镜像整组收在同一主域下面，可以用：

```text
BASE_DOMAIN=github.example.com
DOMAIN_MODE=nested
```

派生为：

- `github.example.com`
- `raw.github.example.com`
- `gist.github.example.com`
- `assets.github.example.com`
- `archive.github.example.com`
- `download.github.example.com`

---

# 4. 准备证书与错误页目录

你需要提前确认：

- `SSL_CERT`
- `SSL_KEY`
- `ERROR_ROOT`
- `LOG_DIR`

例如：

```text
SSL_CERT=/etc/ssl/example/fullchain.pem
SSL_KEY=/etc/ssl/example/privkey.pem
ERROR_ROOT=/www/wwwroot/github-mirror-errors
LOG_DIR=/www/wwwlogs
```

---

# 5. 推荐入口：v0.2 声明式生成

如果你不想手工拼一长串参数，推荐优先使用：

- `deploy.example.yaml`
- `DEPLOY-CONFIG.md`
- `generate-from-config.sh`

## 5.1 最短路径

```bash
cp deploy.example.yaml deploy.yaml

./generate-from-config.sh --config ./deploy.yaml
```

> 说明：`generate-from-config.sh` 当前依赖 `python3` 和 Python `PyYAML`。

执行后会在 `dist/<deployment_name>/` 下生成：

- 渲染后的 `conf.d/`
- 渲染后的 `snippets/`
- `html/errors/`
- `RENDERED-VALUES.env`
- `deploy.resolved.yaml`
- `DEPLOY-STEPS.md`
- `DNS-CHECKLIST.md`
- `RISK-NOTES.md`
- `SUMMARY.md`

## 5.2 这一入口的边界

它会：

- 读取 YAML 配置
- 调用底层渲染器
- 调用底层静态校验器
- 生成中文部署说明文档

建议搭配阅读：

- `DEPLOY-CONFIG.md`
- `TEMPLATE-VARIABLES.md`

它不会：

- 自动改线上 Nginx 配置
- 自动 reload
- 自动改 DNS
- 自动上线

---

# 6. 底层渲染模板

如果你仍然想直接使用原始脚本，也可以继续走底层渲染路径。

示例：

```bash
./render-from-base-domain.sh \
  --base-domain github.example.com \
  --domain-mode flat-siblings \
  --ssl-cert /etc/ssl/example/fullchain.pem \
  --ssl-key /etc/ssl/example/privkey.pem \
  --error-root /www/wwwroot/github-mirror-errors \
  --log-dir /www/wwwlogs \
  --output-dir ./rendered/github.example.com
```

这个步骤只会：

- 生成渲染后的 conf/snippets/errors 文件
- 生成 `RENDERED-VALUES.env`

它不会：

- 修改目标环境中的 Nginx 配置
- 自动部署
- 自动 reload

---

# 7. 运行静态自检

```bash
./validate-rendered-config.sh \
  --rendered-dir ./rendered/github.example.com
```

检查点包括：

- 目录结构是否完整
- conf/snippet/error 文件是否齐全
- 是否残留未替换占位符
- `RENDERED-VALUES.env` 是否完整
- 关键域名是否已经落进对应 conf

---

# 7. DNS 解析

按你的域名模式，把以下域名都解析到目标服务器：

- hub
- raw
- gist
- assets
- archive
- download

如果是 `flat-siblings`，例如：

- `github.example.com`
- `raw.example.com`
- `gist.example.com`
- `assets.example.com`
- `archive.example.com`
- `download.example.com`

---

# 8. 在宝塔中建站

推荐做法：

- 为 6 个镜像域名分别建站
- 让宝塔先生成基础 vhost 与 SSL 绑定
- 再把模板逻辑接进去

这样做的好处是：

- 证书绑定更直观
- 站点拆分更清晰
- 回滚时影响面更小

---

# 9. 放置渲染结果

你通常需要做 3 类落地：

## 9.1 snippets

把渲染结果中的 `snippets/` 放到你的 Nginx snippets 目录。

## 9.2 errors

把 `html/errors/` 放到 `ERROR_ROOT`。

## 9.3 站点 conf

把 `conf.d/*.conf` 中的逻辑整理到你的宝塔 vhost 文件里。

> 注意：这里不是要求你机械覆盖，而是按目标环境路径修正 include 与日志位置后再落地。

---

# 10. redirect whitelist 接入

这是生产部署里最不能漏的一步。

你必须把：

- `snippets/http-redirect-whitelist-map.conf`

接入 Nginx 主配置的：

- `http {}` 作用域

不要把它 include 到 `server {}` 里。

否则 archive / download 的重定向收口会不对。

---

# 11. 上线前检查

在 reload 前至少确认：

- 没覆盖原有站点 conf
- 没改现有业务域名绑定
- 所有镜像域名都使用新增配置
- 错误页路径存在
- snippets include 路径真实有效
- redirect whitelist 已在 `http {}` 接入

---

# 12. Nginx 检查与重载

```bash
nginx -t
nginx -s reload
```

规则：

- `nginx -t` 不通过，绝不 reload
- 通过后再 reload
- reload 后立即做首轮验收

---

# 13. 首轮验收建议

至少测这些：

## 页面链路

- 仓库主页
- README
- 文件树
- blob 页面
- gist 页面

## 内容链路

- raw 文件
- archive 下载
- release download

## 安全边界

- `/login` 应进入登录禁用提示页
- `/settings/profile` 应进入登录禁用提示页或拒绝访问
- `/octocat/Hello-World/fork` 应进入只读限制提示页
- POST 请求应被拒绝

---

# 14. 回滚方法

如果本轮部署有问题：

1. 禁用新增镜像 vhost conf
2. 恢复被改过的 `nginx.conf` 或 include 配置
3. 再跑 `nginx -t`
4. 再 reload

目标是：

- 只回滚本次新增镜像配置
- 不碰原有业务站点

---

# 15. 你还应该继续看的文档

- `BT-PANEL-DEPLOYMENT-v1.md`：更偏宝塔落地
- `DEPLOY-CHECKLIST.md`：执行清单
- `OPERATIONS.md`：运维、升级、排障、回滚
- `FAQ.md`：限制与常见问题
