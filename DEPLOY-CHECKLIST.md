# DEPLOY-CHECKLIST

GitHub 公共只读镜像：部署执行清单（宝塔/Nginx）

> 用法：按顺序逐项确认。长文档见 `INSTALL.md` 和 `BT-PANEL-DEPLOYMENT-v1.md`。

---

## 0. 前提确认

- [ ] 目标服务器已安装 Nginx
- [ ] 宝塔面板可正常使用
- [ ] 我有新增 DNS 解析权限
- [ ] 我能修改 Nginx 配置并 reload
- [ ] 计划使用的新域名 **不与现有网站冲突**

---

## 1. 确定域名模式

- [ ] 已确定 `BASE_DOMAIN`
- [ ] 已确定 `DOMAIN_MODE`：`nested` 或 `flat-siblings`

### 如果是 nested

- [ ] `${BASE_DOMAIN}`
- [ ] `raw.${BASE_DOMAIN}`
- [ ] `gist.${BASE_DOMAIN}`
- [ ] `assets.${BASE_DOMAIN}`
- [ ] `archive.${BASE_DOMAIN}`
- [ ] `download.${BASE_DOMAIN}`

### 如果是 flat-siblings

假设：

```text
BASE_DOMAIN=github.example.com
```

则应为：

- [ ] `github.example.com`
- [ ] `raw.example.com`
- [ ] `gist.example.com`
- [ ] `assets.example.com`
- [ ] `archive.example.com`
- [ ] `download.example.com`

---

## 2. 准备路径信息

- [ ] 已确认目标证书路径 `SSL_CERT`
- [ ] 已确认目标私钥路径 `SSL_KEY`
- [ ] 已确定错误页目录 `ERROR_ROOT`
- [ ] 已确认日志目录 `LOG_DIR`
- [ ] 已确认 Nginx 主配置路径
- [ ] 已确认宝塔站点 conf 目录
- [ ] 已确认 snippets 最终放置目录

---

## 3. 先渲染模板

运行：

```bash
./render-from-base-domain.sh \
  --base-domain <BASE_DOMAIN> \
  --domain-mode <nested|flat-siblings> \
  --ssl-cert <SSL_CERT> \
  --ssl-key <SSL_KEY> \
  --error-root <ERROR_ROOT> \
  --log-dir <LOG_DIR> \
  --output-dir <OUTPUT_DIR>
```

- [ ] 渲染脚本运行成功
- [ ] 输出目录已生成
- [ ] `RENDERED-VALUES.env` 已生成

---

## 4. 运行自检

运行：

```bash
./validate-rendered-config.sh --rendered-dir <OUTPUT_DIR>
```

- [ ] 自检通过
- [ ] 没有残留占位符
- [ ] 关键 conf/snippets/errors 文件齐全
- [ ] 域名引用正确
- [ ] BaoTa vhost anchors 存在：`#SSL-START` 与 `#error_page 404/404.html;`
- [ ] 没有未处理 TODO

---

## 4.5 用半自动部署脚本预演（推荐）

运行：

```bash
./deploy-rendered-to-bt-panel.sh \
  --rendered-dir <OUTPUT_DIR>
```

如需实际落盘但先不 reload：

```bash
./deploy-rendered-to-bt-panel.sh \
  --rendered-dir <OUTPUT_DIR> \
  --apply
```

说明：

- [ ] 默认是 dry-run，只打印计划、不改文件
- [ ] 会先复用 `validate-rendered-config.sh` 做结构校验
- [ ] 会按 `RENDERED-VALUES.env` 推导 6 个 BaoTa vhost conf 目标文件名
- [ ] 会校验 `RENDERED-VALUES.env` 的关键 hostname 值是否安全
- [ ] 会在覆盖前备份已存在文件
- [ ] 会保守检查 `http-redirect-whitelist-map.conf` 是否已接入 `nginx.conf` 的 `http {}`
- [ ] 当前脚本假定 snippets 目录就是 `nginx.conf` 同级 `snippets/`
- [ ] 如需改 `ERROR_ROOT`，应先重新 render，而不是在 deploy 阶段临时覆盖
- [ ] 如需一条链路完成“检查/建站/部署”，可使用 `ensure-bt-panel-mirror-stack.sh`
- [ ] 只有 `--apply` 时才真实复制文件
- [ ] 只有 `--apply --reload` 且 `nginx -t` 通过时才 reload

---

## 5. 配 DNS

- [ ] hub 域名已解析到目标服务器
- [ ] raw 域名已解析到目标服务器
- [ ] gist 域名已解析到目标服务器
- [ ] assets 域名已解析到目标服务器
- [ ] archive 域名已解析到目标服务器
- [ ] download 域名已解析到目标服务器

---

## 6. 宝塔建站

- [ ] 已为镜像域名建站
- [ ] 已为镜像域名绑定 HTTPS 证书
- [ ] 已确认不会复用现有业务站点配置
- [ ] 已明确本次 BaoTa 主线以站点级证书绑定为准，而不是继续依赖 shared `tls-common.conf`

---

## 7. 放置文件

- [ ] 已备份原有 `nginx.conf`
- [ ] 已备份将要修改的宝塔站点 conf
- [ ] 已复制渲染后的 `snippets/` 到目标 snippets 目录
- [ ] 已复制渲染后的 `html/errors/` 到 `ERROR_ROOT`
- [ ] 已将渲染后的 `conf.d/*` 调整为目标服务器实际 conf 布局
- [ ] 已按实际环境修正 conf 中的 `include` 路径
- [ ] 已确认每个 BaoTa vhost 仍保留 `#SSL-START` 与 `#error_page 404/404.html;`
- [ ] 已确认没有把共享 `tls-common.conf` 继续留在 BaoTa 站点 vhost 里做长期 SSL 主承载

---

## 8. 接入 redirect whitelist（必须）

- [ ] 已找到渲染输出中的 `snippets/http-redirect-whitelist-map.conf`
- [ ] 已将其 include 到 Nginx 主配置的 `http {}` 作用域
- [ ] **确认没有把它 include 到 `server {}` 中**

---

## 9. 上线前检查

- [ ] 已确认新增配置只作用于新镜像域名
- [ ] 未覆盖原有站点 conf
- [ ] 未修改原有 server_name
- [ ] 未改动原有证书绑定
- [ ] 未复用现有站点域名
- [ ] 错误页路径真实存在
- [ ] 登录禁用页与只读限制页都已落盘

---

## 10. Nginx 检查与重载

- [ ] 已执行 `nginx -t`
- [ ] `nginx -t` 通过
- [ ] 已确认无重复 `ssl_certificate` / `ssl_certificate_key` / `ssl_protocols` / `ssl_ciphers` 冲突
- [ ] 通过后才执行 reload

命令：

```bash
nginx -t
nginx -s reload
```

---

## 11. 第一轮验证

### 安全边界
- [ ] `/login` 命中登录禁用提示页
- [ ] `/settings/profile` 命中登录禁用提示页或被拒绝
- [ ] POST 到主站任意路径返回只读限制
- [ ] gist 登录路径命中登录禁用提示页
- [ ] `/<owner>/<repo>/fork` 命中只读限制提示页

### 页面
- [ ] 公共仓库首页正常
- [ ] README 正常
- [ ] 文件树正常
- [ ] blob 页面正常
- [ ] releases 页面正常
- [ ] issue/PR 列表页面正常

### 内容
- [ ] raw 文件访问正常
- [ ] gist raw 正常
- [ ] archive 下载正常
- [ ] release 下载正常

### 资源
- [ ] CSS 正常
- [ ] JS 正常
- [ ] 页面未明显跳回官方域

---

## 12. 确认未影响现有网站

- [ ] 现有网站首页正常
- [ ] 现有网站 HTTPS 正常
- [ ] 原有反代/重写规则正常
- [ ] 原有业务域名未受影响

---

## 13. 如需回滚

- [ ] 删除或禁用新增镜像站 conf
- [ ] 恢复备份的 `nginx.conf`（如果改过 `http {}`）
- [ ] 再次执行 `nginx -t`
- [ ] reload Nginx

---

## 14. 还没做的增强项（可后续）

- [ ] 补充 `avatars/objects/camo` 等资源域
- [ ] 增加更细的宝塔截图版文档
- [ ] 增加更强的校验脚本
- [ ] 以后再考虑交互式安装脚本
