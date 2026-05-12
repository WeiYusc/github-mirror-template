# BaoTa / 宝塔 UI 部署手册（GitHub 公共只读镜像）

> 适用对象：以 **宝塔面板 UI** 为主做建站、绑证书、检查站点状态的服务器管理员。
>
> 如果你更习惯 SSH / 命令行，请改看：`DEPLOY-BT-PANEL-CLI-ZH.md`

---

## 1. 这份手册解决什么问题

目标是把当前仓库生成的 GitHub 公共只读镜像部署到 **BaoTa/Nginx** 环境里，并满足两个要求：

1. 站点能访问
2. 站点能被 **宝塔识别和继续管理**

这里的“宝塔识别”不是只看 nginx 能不能响应，而是要满足：

- 宝塔站点列表里能看到站点
- 宝塔能打开对应站点设置
- 宝塔已为站点生成 vhost / 站点目录 / 证书绑定状态

---

## 2. 部署边界

本项目部署的是：

- GitHub 公共仓库页面只读浏览
- raw 文件访问
- gist 页面与 gist raw
- archive 源码包下载
- release 下载链路
- GitHub 静态资源镜像

明确不支持：

- GitHub 登录
- OAuth 授权
- 私有仓库
- 写操作（star / fork / issue / PR / push 等）
- 账号态功能

---

## 3. 前提条件

至少需要：

- 一台已安装 **BaoTa + Nginx** 的 Linux 服务器
- 你有宝塔管理员权限
- 你有域名 DNS 管理权限
- 你能登录服务器执行 shell 命令
- 你有一份可用 TLS 证书

当前最稳主线建议：

- `DOMAIN_MODE=flat-siblings`
- 使用现成通配符证书，例如 `*.example.com`
- `tls.mode=existing`

---

## 4. 域名规划：一定是 6 个域名

如果使用 `flat-siblings`，并且你的基础域名是：

```text
github.example.com
```

那么完整镜像域名是：

- `github.example.com`
- `raw.example.com`
- `gist.example.com`
- `assets.example.com`
- `archive.example.com`
- `download.example.com`

> 注意：`assets` 不是可选项。它负责 HTML 页面依赖的 CSS/JS/字体等资源。

---

## 5. 先做 DNS

在开始建站前，先把上面 6 个域名都解析到目标服务器。

建议：

- 先确认 `A` 记录正确
- 若你的服务器没有可用 IPv6，不要误配 AAAA
- 等待解析生效后再继续

---

## 6. 在宝塔 UI 中创建 6 个站点

在宝塔站点管理里，分别为这 6 个域名建站：

1. `github.example.com`
2. `raw.example.com`
3. `gist.example.com`
4. `assets.example.com`
5. `archive.example.com`
6. `download.example.com`

推荐做法：

- 每个域名单独一个站点
- 让宝塔先生成默认站点目录与 vhost
- 站点类型用最简单的静态站即可

这样做的原因：

- 宝塔会把站点写入自己的数据库和配置体系
- 后续仍可在宝塔中看见和维护这些站点
- 回滚时影响面最小

---

## 7. 在宝塔中绑定证书

### 推荐方式
对这 6 个站点都绑定同一套通配符证书（如果证书覆盖这些域名）。

例如：

- `*.example.com`

### 你至少要确认

- 宝塔 UI 中 HTTPS 已启用
- 证书确实覆盖这 6 个域名
- 不要只给 `github.example.com` 绑证书，其他 5 个站也要能走 HTTPS

---

## 8. 在服务器上生成部署包

在仓库目录执行：

```bash
cp deploy.example.yaml deploy.yaml
./generate-from-config.sh --config ./deploy.yaml
```

或者直接走底层渲染：

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

然后做静态检查：

```bash
./validate-rendered-config.sh --rendered-dir ./rendered/github-mirror
```

如果你走的是 `generate-from-config.sh`，重点看：

- `dist/<deployment_name>/DEPLOY-STEPS.md`
- `dist/<deployment_name>/DNS-CHECKLIST.md`
- `dist/<deployment_name>/SUMMARY.md`

---

## 9. 推荐目标路径

对当前 BaoTa/Nginx 主线，推荐使用：

- 主 nginx 配置：`/www/server/nginx/conf/nginx.conf`
- 宝塔 vhost 目录：`/www/server/panel/vhost/nginx/`
- snippets 目录：`/www/server/nginx/conf/snippets`
- 错误页目录：`/www/wwwroot/github-mirror-errors`
- 日志目录：`/www/wwwlogs`

> `snippets` 当前推荐放在 `nginx.conf` 同级目录：`/www/server/nginx/conf/snippets`。

---

## 10. 放置 snippets 和错误页

把渲染结果中的：

- `snippets/*`
- `html/errors/*`

复制到：

- `/www/server/nginx/conf/snippets`
- `/www/wwwroot/github-mirror-errors`

如果目标目录不存在，先创建。

---

## 11. 替换宝塔生成的 vhost 配置

把渲染结果里的 `conf.d/*.conf` 对应到宝塔 vhost：

- `github.example.com.conf`
- `raw.example.com.conf`
- `gist.example.com.conf`
- `assets.example.com.conf`
- `archive.example.com.conf`
- `download.example.com.conf`

目标目录通常是：

```text
/www/server/panel/vhost/nginx/
```

操作原则：

- 先备份宝塔生成的原始 conf
- 再用渲染后的 conf 替换
- 不要去改与镜像无关的旧站点配置

---

## 12. 把 redirect whitelist map 接进 `http {}`

这一步非常关键。

渲染结果里会有：

```text
snippets/http-redirect-whitelist-map.conf
```

它必须被 include 到：

```nginx
http {
    include /www/server/nginx/conf/snippets/http-redirect-whitelist-map.conf;
}
```

### 不要做错的事

不要把这个文件 include 到任意 `server {}` 里。

如果放错位置，`archive` / `download` 的跳转控制会异常。

---

## 13. nginx 检查与重载

修改完成后执行：

```bash
nginx -t
```

只有在 `nginx -t` 成功时，才继续：

```bash
nginx -s reload
```

或者在宝塔面板里执行 reload。

---

## 14. 首轮验收

请至少检查以下项目：

### 14.1 页面链路

- `https://github.example.com/`
- 仓库 README 页面
- 文件树页面
- blob 页面
- `https://gist.example.com/`

### 14.2 内容链路

- raw 文件
- archive 下载
- release 下载
- gist raw

### 14.3 资源链路

- 页面 CSS/JS 正常
- 页面没有明显样式缺失
- `assets` 域资源可以成功加载

### 14.4 只读边界

- `/login` 进入登录禁用页
- `/settings/profile` 被拒绝或进入禁用页
- POST 请求被拒绝

---

## 15. 如何确认“宝塔已经识别这些站点”

请逐项确认：

1. 宝塔站点列表中存在这 6 个域名站点
2. 每个站点都能在宝塔 UI 中打开设置页
3. `/www/server/panel/vhost/nginx/` 下存在对应 conf
4. 宝塔 UI 中 HTTPS 状态正常
5. 若你查看本地面板数据，站点记录已经存在

完整验收清单请看：

- `BT-PANEL-ACCEPTANCE-CHECKLIST-ZH.md`

---

## 16. 常见错误提醒

### 1) 漏了 `assets`
症状：主页能开，但样式/脚本异常。

### 2) 把 whitelist map include 到 `server {}`
症状：archive / download 重定向异常。

### 3) snippets 放错目录
症状：vhost include 找不到文件，`nginx -t` 失败。

### 4) 误把 `assets /` 返回 404 当成故障
说明：`assets` 域是资源域，根路径返回 404 可以是预期。

完整故障排查请看：

- `BT-PANEL-TROUBLESHOOTING-ZH.md`

---

## 17. 最后建议

如果你是第一次落地，建议阅读顺序：

1. `../INSTALL.md`
2. 本文
3. `BT-PANEL-ACCEPTANCE-CHECKLIST-ZH.md`
4. `BT-PANEL-TROUBLESHOOTING-ZH.md`

如果你希望更多依赖脚本而不是宝塔 UI 手工操作，请改看：

- `DEPLOY-BT-PANEL-CLI-ZH.md`
