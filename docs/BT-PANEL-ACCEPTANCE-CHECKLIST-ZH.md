# BaoTa / 宝塔镜像部署验收清单

> 用途：确认这次部署不仅“能访问”，而且已经形成 **BaoTa 可识别、Nginx 可维护、HTTP 链路基本完整** 的上线状态。

---

## 1. 部署前确认

在开始正式验收前，先确认：

- 已完成 DNS 解析
- 已完成 BaoTa 建站
- 已部署 snippets / errors / vhost
- 已将 redirect whitelist map 接入 `http {}`
- `nginx -t` 已通过
- 已执行 reload（若你本次变更需要 reload）

---

## 2. BaoTa 识别验收

### 2.1 站点列表

在 BaoTa 站点列表中，应该能看到这 6 个站：

- `github.example.com`
- `raw.example.com`
- `gist.example.com`
- `assets.example.com`
- `archive.example.com`
- `download.example.com`

### 2.2 站点可管理

逐个确认：

- 能打开站点设置页
- 不存在“未识别/配置丢失”的异常状态
- HTTPS 状态显示正常

### 2.3 本地配置文件存在

检查目标目录：

```text
/www/server/panel/vhost/nginx/
```

应能找到对应 conf 文件。

### 2.3.1 BaoTa SSL anchors 仍存在

对每个镜像站点的 vhost，至少确认：

- `#SSL-START` 仍在
- `#error_page 404/404.html;` 仍在

如果这两个锚点被替换掉，后续 BaoTa 站点级 SSL 管理容易失效或不可预测。

### 2.3.2 站点级证书路径正确

对每个镜像站点，至少确认其最终生效的 `ssl_certificate` / `ssl_certificate_key` 指向的是 BaoTa 站点级路径，例如：

```text
/www/server/panel/vhost/cert/<site>/fullchain.pem
/www/server/panel/vhost/cert/<site>/privkey.pem
```

### 2.4 本地站点数据存在（可选增强检查）

如果你要做更强验证，可以检查 BaoTa 本地站点数据库和记录是否存在。

目标不是必须手工查库，而是确认：

- 这些站点不是“纯手写 nginx 幽灵配置”
- 而是真正进入 BaoTa 管理体系

---

## 3. Nginx 结构验收

### 3.1 主配置路径

通常应为：

```text
/www/server/nginx/conf/nginx.conf
```

### 3.2 snippets 目录

当前推荐主线应为：

```text
/www/server/nginx/conf/snippets
```

### 3.3 redirect whitelist map

确认：

- `snippets/http-redirect-whitelist-map.conf` 已存在
- 该文件被 include 到 `http {}` 作用域
- 没有被错误 include 到 `server {}`

### 3.4 语法检查

执行：

```bash
nginx -t
```

要求：

- 返回成功
- 无 include 路径错误
- 无重复/冲突配置错误
- 无重复 `ssl_certificate` / `ssl_certificate_key` / `ssl_protocols` / `ssl_ciphers` 之类的 SSL directive 冲突

---

## 4. TLS / HTTPS 验收

逐个站点确认：

- HTTPS 能正常访问
- 证书主题与域名匹配
- 无明显浏览器证书错误
- 证书真相来源以站点 vhost 中实际生效的 `ssl_certificate` 为准，而不是共享 `tls-common.conf`

至少覆盖：

- hub
- raw
- gist
- assets
- archive
- download

> 当前最稳主线是已有证书（`tls.mode=existing`）。

---

## 5. HTTP 链路验收

### 5.1 hub

至少验证：

- 首页可打开
- README 页面可打开
- 文件树可打开
- blob 页面可打开

### 5.2 raw

至少验证一个真实 raw 文件 URL。

### 5.3 gist

至少验证：

- `https://gist.example.com/`
- 一个 gist raw URL

### 5.4 assets

至少验证一个真实 CSS/JS/字体资源路径。

> 注意：`assets` 域的 `/` 返回 404 可以是预期，不应单独据此判定失败。

### 5.5 archive

至少验证一个真实 tar.gz / zip 下载路径。

### 5.6 download

至少验证一个 **确认存在** 的 release asset URL。

> 不要用猜的 URL；猜错导致的 404 不能直接说明部署失败。

---

## 6. 只读边界验收

至少验证：

- `/login` 进入登录禁用页
- `/settings/profile` 被拒绝或进入禁用页
- POST 请求被拒绝
- fork / issue / PR 等写路径不应走成功流程

---

## 7. 不影响现网验收

确认：

- 旧站点域名访问正常
- 原有站点 SSL 正常
- 原有业务站点 conf 未被误覆盖
- 本次变更只影响镜像相关域名和新增 snippets/include

---

## 8. 出问题时优先看哪里

### 首选

- `nginx -t` 输出
- 对应站点 error log
- BaoTa 站点列表与站点设置页

### 常见重点

- gist 502：看 upstream TLS / `proxy_ssl_name`
- assets 502：看 upstream IPv6 / resolver
- archive / download 异常：看 whitelist map 是否放在 `http {}`
- 样式缺失：先查 `assets` 域资源加载

详细排查文档：

- `BT-PANEL-TROUBLESHOOTING-ZH.md`

---

## 9. 通过标准

可以认为这次部署已基本通过，当且仅当：

- BaoTa UI 中存在并可管理 6 个站点
- `nginx -t` 通过
- HTTPS 正常
- `./scripts/check-bt-panel-nginx-quick.sh --base-domain <主域名>` 无硬失败
- 如需完整验收，`./scripts/check-live-mirror.sh --base-domain <主域名>` 通过核心检查
- hub/raw/gist/assets/archive/download 的最小链路都可验证
- 只读边界正常
- 未影响旧站点
