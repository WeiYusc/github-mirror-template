# 宝塔环境部署文档 v1（GitHub 公共只读镜像）

> 目标：在 **不影响服务器现有网站运行** 的前提下，在宝塔/Nginx 环境中部署 GitHub 公共只读镜像。
>
> 本文档适用于当前项目目录结构。

---

# 1. 方案边界

本方案部署的是：

- GitHub 公共仓库页面只读浏览
- raw 文件访问
- gist 页面与 gist raw
- archive 源码包下载
- release / artifacts 下载
- 静态资源镜像

**明确不支持：**

- GitHub 登录
- OAuth 授权
- 私有仓库
- 写操作（star / fork / issue / PR / push 等）
- 账号设置、通知、用户态交互

---

# 2. 设计原则

## 2.1 不影响现有网站

部署时必须遵守：

1. **不覆盖现有站点配置文件**
2. **不修改现有站点的 server_name / 证书 / 反代规则**
3. **所有镜像站使用独立域名**
4. **所有镜像配置写入新的 conf 文件**
5. **改动前先备份**
6. **每次改完先执行 `nginx -t`，通过后再 reload**

## 2.2 宝塔友好

优先使用：

- 宝塔建站/绑域名/申请证书
- 手工放置 snippets 与自定义 conf
- 少量、可审计的 Nginx 配置变更

## 2.3 域名模型

当前模板支持两种模式：

- `nested`
- `flat-siblings`

### nested 示例

```text
BASE_DOMAIN=github.example.com
```

派生：

- `github.example.com`
- `raw.github.example.com`
- `gist.github.example.com`
- `assets.github.example.com`
- `archive.github.example.com`
- `download.github.example.com`

### flat-siblings 示例

```text
BASE_DOMAIN=github.example.com
```

派生：

- `github.example.com`
- `raw.example.com`
- `gist.example.com`
- `assets.example.com`
- `archive.example.com`
- `download.example.com`

> 如果已持有 `*.example.com` 通配符证书，通常更推荐 `flat-siblings`。

---

# 3. 当前模板包内容

当前模板目录中已经包含三层内容：

## 3.1 模板文件

- `conf.d/*`
- `snippets/*`
- `html/errors/*`

## 3.2 说明文档

- `README.md`
- `INSTALL.md`
- `OPERATIONS.md`
- `FAQ.md`
- `DOMAIN-PLAN.md`
- `TEMPLATE-VARIABLES.md`
- `REDIRECT-WHITELIST-DESIGN.md`
- `REDIRECT-WHITELIST-CONFIG-SKETCH.md`

## 3.3 工具脚本

- `render-from-base-domain.sh`
- `validate-rendered-config.sh`

---

# 4. 部署前检查

在动手前先确认以下事项。

## 4.1 环境检查

确认服务器满足：

- 已安装 Nginx
- 宝塔面板可正常管理站点
- 你有新增域名解析权限
- 你能修改 Nginx 配置并 reload
- 不存在与计划镜像域冲突的现有站点

## 4.2 配置目录确认

不同环境路径可能不同，先确认：

- Nginx 主配置：
  - 常见：`/www/server/nginx/conf/nginx.conf`
- 宝塔站点 vhost 目录：
  - 常见：`/www/server/panel/vhost/nginx/`
- 证书目录：
  - 常见：`/www/server/panel/vhost/cert/<domain>/`
- 错误页目录：
  - 常见：`/www/wwwroot/github-mirror-errors`
- 日志目录：
  - 常见：`/www/wwwlogs`

---

# 5. 推荐先用渲染脚本生成副本

不要直接在模板目录里手工逐个替换。

## flat-siblings 示例

```bash
./render-from-base-domain.sh \
  --base-domain github.example.com \
  --domain-mode flat-siblings \
  --ssl-cert /etc/ssl/example/fullchain.pem \
  --ssl-key /etc/ssl/example/privkey.pem \
  --error-root /www/wwwroot/github-mirror-errors \
  --log-dir /www/wwwlogs \
  --output-dir ./rendered/github-mirror
```

这一步只会：

- 渲染模板副本
- 生成实际域名版 conf/snippets/errors
- 输出 `RENDERED-VALUES.env`

**不会：**

- 修改 Nginx
- reload 服务
- 影响现有网站

## 渲染后建议马上自检

```bash
./validate-rendered-config.sh \
  --rendered-dir ./rendered/github-mirror
```

---

# 6. snippets 放置建议

建议为本项目单独建立一个 snippets 目录，例如：

```text
/www/server/nginx/conf/github-mirror-snippets/
```

把渲染输出中的：

```text
snippets/*
```

复制到这里。

---

# 7. 错误页放置建议

建议放到独立目录：

```text
/www/wwwroot/github-mirror-errors/
```

把渲染输出中的：

```text
html/errors/*
```

复制到该目录。

当前模板包含至少三类错误页：

- `403-login-disabled.html`
- `403-readonly.html`
- `404.html`

其中：

- 登录/授权/账号态路径会走 **登录禁用提示页**
- 写操作/只读范围外交互会走 **只读限制提示页**

---

# 8. `map` 白名单放置位置（非常重要）

`archive` 和 `download` 的跳转白名单，不能放在 `server {}` 里，必须放在：

```nginx
http {
    ...
}
```

作用域下。

渲染输出里会包含：

```text
snippets/http-redirect-whitelist-map.conf
```

这个文件应该被 include 到主 nginx `http {}` 作用域中。

---

# 9. 推荐部署顺序

## 第一阶段：最小可用集

先部署：

1. hub
2. raw
3. assets

验证：

- 公共仓库首页可打开
- README 页面可正常显示
- 样式/JS 基本正常
- raw 文件可访问

## 第二阶段：补下载链路

再部署：

4. archive
5. download

验证：

- archive zip/tar.gz 可下载
- release 下载可走镜像域

## 第三阶段：补 gist

最后部署：

6. gist

验证：

- gist 页面正常
- gist raw 正常

---

# 10. 推荐部署步骤

## Step 1：备份现有配置

至少备份：

- `/www/server/nginx/conf/nginx.conf`
- `/www/server/panel/vhost/nginx/` 中将要修改的站点 conf

## Step 2：在宝塔中创建镜像站点

按计划域名建站。

## Step 3：申请或绑定证书

确保每个新站点都已有 HTTPS 可用证书。

## Step 4：先渲染模板副本

运行渲染脚本，生成一份可审查的实际域名版配置副本。

## Step 5：运行自检脚本

确认没有残留占位符、缺文件、变量缺失等问题。

## Step 6：复制 snippets 和错误页

把渲染后的：

- `snippets/`
- `html/errors/`

复制到服务器目标目录。

## Step 7：放置并调整站点 conf

把渲染后的 `conf.d/*` 调整成适合宝塔站点目录的 conf 文件，必要时修正 include 路径。

## Step 8：加入 `http {}` 白名单 map

修改 nginx 主配置，在 `http {}` 里 include：

```nginx
http-redirect-whitelist-map.conf
```

## Step 9：语法检查

```bash
nginx -t
```

如果不通过，不要 reload。

## Step 10：重载 Nginx

```bash
nginx -s reload
```

或使用宝塔重载。

---

# 11. 第一轮验证清单

## 11.1 安全边界验证

- `/login` 返回 **登录禁用提示页**
- `/settings/profile` 返回 **登录禁用提示页** 或被拒绝
- POST 到主站任意路径返回 **只读限制**
- gist 登录路径返回 **登录禁用提示页**
- `/<owner>/<repo>/fork` 返回 **只读限制提示页**

## 11.2 页面验证

- 公共仓库首页
- README
- 文件树
- blob 页面
- releases 页面
- issue/PR 列表页面

## 11.3 内容验证

- raw 文件访问正常
- gist raw 正常
- archive 下载正常
- release 下载正常

## 11.4 资源验证

- CSS/JS 是否正常加载
- 页面是否掉到 GitHub 官方域
- 是否仍有缺失资源需要补 `avatars/objects/camo`

---

# 12. 如何确认“不影响现有网站”

上线后必须检查：

1. 现有网站域名访问是否正常
2. 宝塔原有站点 SSL 是否正常
3. 现有反代/重写规则是否未变化
4. 新增配置是否仅作用于新镜像域名
5. `nginx -t` 是否仍然通过

---

# 13. 回滚方案

如果新镜像站配置有问题：

1. 删除或禁用新镜像站相关 conf
2. 恢复备份的 nginx.conf（如果你改过 `http {}`）
3. 执行 `nginx -t`
4. reload Nginx

原则是：

- 只移除本项目新增文件
- 不动原有站点

---

# 14. 当前模板已知注意事项

部署前要注意：

1. include 路径需要按目标服务器实际目录替换
2. 证书路径需要按实际站点证书目录填写
3. 某些 GitHub 资源域可能要在联调时补充
4. `http-redirect-whitelist-map.conf` 必须放进 nginx `http {}` 作用域，而不是 `server {}`
5. 不要把旧式 `listen 443 ssl http2;` 写法又带回来，推荐统一改为：

```nginx
listen 443 ssl;
http2 on;
```

---

# 15. 相关模板文件

建议重点参考：

- `README.md`
- `INSTALL.md`
- `OPERATIONS.md`
- `FAQ.md`
- `DEPLOY-CHECKLIST.md`
- `DOMAIN-PLAN.md`
- `TEMPLATE-VARIABLES.md`
- `REDIRECT-WHITELIST-DESIGN.md`
- `REDIRECT-WHITELIST-CONFIG-SKETCH.md`
- `render-from-base-domain.sh`
- `validate-rendered-config.sh`
