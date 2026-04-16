# OPERATIONS.md

这份文档写的是上线后的事：

- 怎么验收
- 怎么看日志
- 怎么升级
- 怎么回滚
- 出问题先查哪里

---

# 1. 日常验收建议

每次部署或改配置后，至少抽查：

## 主链路

- 仓库主页
- README
- 文件树
- raw 文件
- gist 页面
- archive 下载
- release download

## 安全边界

- `/login`
- `/settings/profile`
- `/account/`
- `/<owner>/<repo>/fork`
- `/<owner>/<repo>/issues/new`
- POST 任意路径

如果这些都符合预期，再算这一轮改动基本过关。

---

# 2. 日志建议

当前阶段 **不要关闭日志**。

至少保留：

- hub 站点 access/error
- raw 站点 access/error
- gist 站点 access/error
- assets 站点 access/error
- archive 站点 access/error
- download 站点 access/error

重点关注：

- 403 / 404 / 418 命中情况
- 301 / 302 / 307 跳转链路
- upstream 超时
- TLS/SNI 问题
- 下载链路被 whitelist 拦截的情况

---

# 3. 常见维护动作

## 3.1 修改模板后的更新流程

建议顺序：

1. 先改模板
2. 重新渲染
3. 对比目标配置差异
4. 小步落地到目标环境
5. `nginx -t`
6. reload
7. 验收

## 3.2 新增规则

如果要新增：

- 被拦截路径
- sub_filter 规则
- 下载白名单域
- 资源域

优先做法是：

- 先改模板
- 再同步到目标环境
- 不要只临时热修目标环境而忘记回写模板

---

# 4. 升级建议

这个项目没有“统一安装器版本升级”那种流程，升级更接近：

- 调整模板
- 重新渲染
- 做差异审查
- 增量替换配置

升级时特别注意：

- 不要误覆盖现有业务站点 conf
- 不要让新模板回退掉已修过的 warning
- 不要丢失错误页分流逻辑
- 不要丢失 redirect whitelist

---

# 5. 回滚策略

最稳的回滚方式是：

## 5.1 vhost 回滚

- 恢复上一版镜像站 vhost conf
- 保持其他站点不动

## 5.2 snippets 回滚

- 恢复上一版 snippets
- 注意和 vhost include 保持一致

## 5.3 主配置回滚

如果你改过 `nginx.conf` 的 `http {}` include：

- 恢复上一版主配置
- 再做 `nginx -t`
- 再 reload

---

# 6. 典型排障入口

## 6.1 登录页没落到登录禁用提示页

先查：

- `mirror-block-sensitive-paths.conf` 是否已更新
- 对应 vhost 是否 include 了这个 snippet
- `error_page 418 /errors/403-login-disabled.html;` 是否存在
- reload 是否成功

## 6.2 fork/new issue 还在裸 403/404

先查：

- 对应路径是否已在 `mirror-block-sensitive-paths.conf`
- `error_page 403 /errors/403-readonly.html;` 是否存在
- 错误页 alias/root 是否正确

## 6.3 assets 站点异常

重点查：

- `proxy_pass` 是否直接指向 `https://github.githubassets.com`
- `proxy_ssl_server_name on;`
- `proxy_ssl_name github.githubassets.com;`
- `resolver` 是否可用
- 是否被 IPv6 连通性坑住

## 6.4 archive / download 下载失败

重点查：

- redirect whitelist 是否已 include 到 `http {}`
- 是否误放进 `server {}`
- 上游 `Location` 是否命中 allowlist
- `proxy_ssl_name $proxy_host;` 是否存在

## 6.5 `nginx -t` warning 又回来了

重点查：

- 是否又写回了旧式 `listen 443 ssl http2;`
- 是否重复 include 了 `sub_filter_types text/html;`
- 多站点 443 监听写法是否一致

---

# 7. 建议保留的验收命令

你可以维护自己的一套 smoke test，例如：

- hub 首页 HEAD/GET
- raw 文件 GET
- gist 根路径 GET
- login 页面 GET
- fork 页面 GET

重点不是命令形式，而是每次改完都要有一套固定抽样。

---

# 8. 发布前建议

如果准备对外发布这个模板仓库，建议至少补齐：

- 一份明确的安装文档
- 一份运维/回滚文档
- 一份 FAQ / 已知限制文档
- 一份版本变更记录（后续可加）

---

# 9. 原则总结

运维这套东西最重要的不是“炫技”，而是：

- 改动可审计
- 上线可验证
- 出错可回滚
- 模板和现网不脱节
