# BaoTa / 宝塔 CLI 部署手册（GitHub 公共只读镜像）

> 适用对象：愿意通过 **SSH / shell 命令** 部署 BaoTa 站点的管理员。
>
> 如果你更倾向在宝塔 UI 中逐步操作，请改看：`DEPLOY-BT-PANEL-UI-ZH.md`

---

## 1. 这份手册适合谁

这份文档适合：

- 已能 SSH 登录目标服务器
- 希望尽量脚本化部署
- 希望先 dry-run，再 apply
- 能接受当前主线仍是 **review-first / controlled apply**

当前最稳主线是：

- `DOMAIN_MODE=flat-siblings`
- `tls.mode=existing`
- 6 个域名都已解析
- 宝塔站点可由 UI 预建，或由 helper create-if-missing

---

## 2. 当前支持的 3 条命令入口

### 入口 A：generator 主线
适合：先生成部署包，再人工审查和落地。

- `generate-from-config.sh`

### 入口 B：experimental installer
适合：希望用中文交互或最小 flags 组织一次 controlled apply。

- `install-interactive.sh`
- `apply-generated-package.sh`

### 入口 C：BaoTa mirror helper
适合：你已经明确是 BaoTa 环境，希望用更贴近实际部署的 helper。

- `ensure-bt-panel-mirror-stack.sh`
- `deploy-rendered-to-bt-panel.sh`

> 如果你的目标是“当前最接近 agent 代工的本机执行入口”，优先看入口 C。

---

## 3. 当前命令行主线的边界

当前 CLI 路线：

### 已支持
- 生成部署包
- 静态自检
- dry-run / apply 规划
- BaoTa 识别站点的本机检查
- 在 apply 模式下 create-if-missing + deploy apply（repo 默认自带 BaoTa 建站客户端）
- nginx -t 后再选择 reload

### 当前不支持或不承诺闭环
- 自动改 DNS
- 真正完整 ACME 自动签发闭环
- 无人工判断的自动回滚
- 把 experimental installer 当黑盒一键安装器

当前最稳妥建议仍然是：

- 域名已解析
- 证书现成可用
- 用 `tls.mode=existing`

如果你希望替换 repo 默认建站客户端，仍可显式传：

- `--bt-create-script <path>`

---

## 4. 6 个域名必须完整

如果你使用：

```text
BASE_DOMAIN=github.example.com
DOMAIN_MODE=flat-siblings
```

则完整域名组为：

- `github.example.com`
- `raw.example.com`
- `gist.example.com`
- `assets.example.com`
- `archive.example.com`
- `download.example.com`

> `assets` 必须保留，否则 HTML 页面资源链路不完整。

---

## 5. 推荐目标路径

对当前 BaoTa/Nginx 主线，推荐：

- `nginx.conf`: `/www/server/nginx/conf/nginx.conf`
- snippets: `/www/server/nginx/conf/snippets`
- BaoTa vhost: `/www/server/panel/vhost/nginx`
- error root: `/www/wwwroot/github-mirror-errors`
- logs: `/www/wwwlogs`

---

## 6. 最小 happy path：generator -> helper apply

### Step 1：准备 deploy.yaml

```bash
cp deploy.example.yaml deploy.yaml
```

按你的真实域名与证书路径修改。

### Step 2：生成部署包

```bash
./generate-from-config.sh --config ./deploy.yaml
```

### Step 3：先看生成结果

重点看：

- `dist/<deployment_name>/DEPLOY-STEPS.md`
- `dist/<deployment_name>/DNS-CHECKLIST.md`
- `dist/<deployment_name>/SUMMARY.md`

### Step 4：执行 BaoTa helper dry-run

```bash
./ensure-bt-panel-mirror-stack.sh \
  --base-domain github.example.com \
  --domain-mode flat-siblings \
  --rendered-dir ./dist/github-mirror-prod \
  --snippets-target /www/server/nginx/conf/snippets \
  --vhost-target /www/server/panel/vhost/nginx \
  --error-root /www/wwwroot/github-mirror-errors
```

这一步默认是 dry-run，不会修改线上文件。

### Step 5：确认后 apply

```bash
./ensure-bt-panel-mirror-stack.sh \
  --base-domain github.example.com \
  --domain-mode flat-siblings \
  --rendered-dir ./dist/github-mirror-prod \
  --snippets-target /www/server/nginx/conf/snippets \
  --vhost-target /www/server/panel/vhost/nginx \
  --error-root /www/wwwroot/github-mirror-errors \
  --panel https://panel.example.com:37913 \
  --entry /your-entry \
  --username admin \
  --password-env BT_PANEL_PASSWORD \
  --apply
```

### Step 6：确认 nginx 检查后 reload

```bash
./ensure-bt-panel-mirror-stack.sh \
  --base-domain github.example.com \
  --domain-mode flat-siblings \
  --rendered-dir ./dist/github-mirror-prod \
  --snippets-target /www/server/nginx/conf/snippets \
  --vhost-target /www/server/panel/vhost/nginx \
  --error-root /www/wwwroot/github-mirror-errors \
  --panel https://panel.example.com:37913 \
  --entry /your-entry \
  --username admin \
  --password-env BT_PANEL_PASSWORD \
  --apply --reload
```

> 只有在 `nginx -t` 通过的前提下才应该 reload。

---

## 7. 什么时候使用 install-interactive

如果你希望：

- 中文交互收集参数
- 保留 run_id / doctor / resume / repair / rollback 轨迹
- 先生成计划再决定 apply

可以改用：

```bash
./install-interactive.sh
```

或最小 flags：

```bash
./install-interactive.sh \
  --deployment-name github-mirror-prod \
  --base-domain github.example.com \
  --domain-mode flat-siblings \
  --platform bt-panel-nginx \
  --tls-cert /etc/ssl/example/fullchain.pem \
  --tls-key /etc/ssl/example/privkey.pem \
  --input-mode basic \
  --run-apply-dry-run \
  --yes
```

但请记住：

- 它不是黑盒一键安装器
- 它不会自动改 DNS
- 它不会在失败后自动回滚

---

## 8. 什么时候使用 deploy-rendered-to-bt-panel.sh

如果你已经：

- 手工建好了宝塔站点
- 已经有现成 rendered package
- 只想专注于 deploy 这一步

可以直接用：

```bash
./deploy-rendered-to-bt-panel.sh \
  --rendered-dir ./dist/github-mirror-prod \
  --snippets-target /www/server/nginx/conf/snippets \
  --vhost-target /www/server/panel/vhost/nginx \
  --error-root /www/wwwroot/github-mirror-errors
```

apply 模式：

```bash
./deploy-rendered-to-bt-panel.sh \
  --rendered-dir ./dist/github-mirror-prod \
  --snippets-target /www/server/nginx/conf/snippets \
  --vhost-target /www/server/panel/vhost/nginx \
  --error-root /www/wwwroot/github-mirror-errors \
  --apply
```

reload 模式：

```bash
./deploy-rendered-to-bt-panel.sh \
  --rendered-dir ./dist/github-mirror-prod \
  --snippets-target /www/server/nginx/conf/snippets \
  --vhost-target /www/server/panel/vhost/nginx \
  --error-root /www/wwwroot/github-mirror-errors \
  --apply --reload
```

---

## 9. 关键部署原则

### 1) 先 dry-run，再 apply
不要一上来就真写线上文件。

### 2) 先让 BaoTa 识别站点
无论是手工建站还是 helper create-if-missing，目标都应是 BaoTa 站点体系里存在这些域名。

### 3) snippets 路径要统一
当前推荐主线是：

```text
/www/server/nginx/conf/snippets
```

### 4) whitelist map 一定在 `http {}` 里
不要放到 `server {}`。

---

## 10. CLI 路线首轮验收

至少验证：

- `https://github.example.com/`
- 仓库 README 页面
- `https://raw.example.com/...`
- `https://gist.example.com/`
- archive 下载
- release 下载
- assets 资源能加载

并检查：

- `nginx -t` 通过
- BaoTa UI 中能看到这 6 个站点

完整验收清单见：

- `BT-PANEL-ACCEPTANCE-CHECKLIST-ZH.md`

---

## 11. 常见误区

### 1) 只部署 5 个域名
错。当前完整 flat-siblings 主线是 6 个域名。

### 2) 误把 `assets /` 的 404 当故障
`assets` 是资源域，根路径 404 可以是预期。

### 3) 用了 `acme-http01` 就以为会自动签证书
当前不是完整自动签发闭环，仍偏 review-first scaffolding。

### 4) 把 installer 当成黑盒安装器
当前不是。

完整排查见：

- `BT-PANEL-TROUBLESHOOTING-ZH.md`

---

## 12. 如果你要走更自动化的代工入口

当前仓库正在往“agent 代工标准入口”收口，但在现阶段：

- CLI helper 是最接近代工的本机执行主线
- 最稳妥的前提仍是：DNS 已解析、证书已准备好

如果你希望进一步减少手工步骤，优先组合：

- `ensure-bt-panel-mirror-stack.sh`
- `deploy-rendered-to-bt-panel.sh`

---

## 13. 建议阅读顺序

1. `../INSTALL.md`
2. 本文
3. `BT-PANEL-ACCEPTANCE-CHECKLIST-ZH.md`
4. `BT-PANEL-TROUBLESHOOTING-ZH.md`
5. `../BT-PANEL-DEPLOYMENT-v1.md`（背景说明）
