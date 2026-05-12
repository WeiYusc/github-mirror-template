# BaoTa / 宝塔镜像部署故障排查手册

> 用途：当站点已部署但行为异常时，快速定位是 **BaoTa 建站问题、nginx include 问题、TLS/SNI 问题，还是上游访问问题**。

---

## 1. 通用排查顺序

遇到问题时，建议先按这个顺序走：

1. 看 `nginx -t`
2. 看对应站点 error log
3. 看 BaoTa 站点列表和站点设置页
4. 看目标 conf / snippets 是否真的落到了预期目录
5. 再看具体业务链路（gist / assets / download 等）

---

## 2. gist 首页返回 502

### 现象

- `https://gist.example.com/` 返回 502

### 典型原因

- upstream TLS/SNI 不匹配
- 缺少正确的 `proxy_ssl_name`

### 优先检查

- 对应站点 error log
- gist 相关 vhost 配置

### 修复方向

确认 gist 页面主 location 使用正确的 upstream SNI，例如对不同 upstream 分别设置合适的 `proxy_ssl_name`。

### 修复后验收

- gist 首页返回 200
- gist raw 路径也能返回成功

---

## 3. assets 域返回 502

### 现象

- `https://assets.example.com/...` 返回 502

### 典型原因

- upstream 解析后优先走了不可达 IPv6
- resolver / variable-based proxy_pass 配置不对

### 优先检查

- assets 站点 error log
- 是否存在 IPv6 `Network is unreachable`
- assets vhost 是否使用了 resolver 与变量形式的 `proxy_pass`

### 修复方向

- 使用有效 resolver
- 必要时使用变量形式 `proxy_pass`
- 明确关闭不需要的 IPv6 路径偏好（视实际配置而定）

### 修复后验收

- 用一个真实 CSS/JS/字体 URL 测试返回 200
- 不要只用 `/` 做唯一判断

---

## 4. assets 根路径 `/` 返回 404

### 现象

- `https://assets.example.com/` 返回 404

### 这可能不是故障

`assets` 是资源域，不是首页域。

### 正确做法

改用一个真实资源路径验证，例如：

- CSS
- JS
- 字体文件

如果资源路径能返回 200，而 `/` 返回 404，可以视为可接受行为。

---

## 5. archive / download 链路异常

### 现象

- archive 下载不正常
- release download 跳转异常

### 典型原因

- `http-redirect-whitelist-map.conf` 没有接到 `http {}`
- 被错误 include 到某个 `server {}`

### 优先检查

- 主 nginx 配置
- `http {}` 作用域内的 include
- whitelist map 文件是否存在于 snippets 目录

### 修复方向

确保：

```nginx
http {
    include /www/server/nginx/conf/snippets/http-redirect-whitelist-map.conf;
}
```

### 修复后验收

- archive URL 可正常下载
- download URL 使用一个**确认存在**的 release asset 测试

---

## 6. `nginx -t` 失败，提示 snippets include 找不到

### 现象

- `nginx -t` 提示 include 文件不存在

### 典型原因

- snippets 放错目录
- 当前 conf 引用的 snippets 路径与实际复制路径不一致

### 当前推荐主线目录

```text
/www/server/nginx/conf/snippets
```

### 修复方向

确认三件事一致：

1. 渲染结果中的 include 路径
2. `--snippets-target` 实际部署目录
3. 主机上的 snippets 文件落点

---

## 7. 页面能开，但样式/脚本明显异常

### 现象

- hub 页面能开
- 但 CSS/JS 丢失，页面像裸 HTML

### 典型原因

- `assets` 域没有部署完整
- `assets` DNS / vhost / resolver 有问题
- 漏掉了 `assets` 站点本身

### 修复方向

先检查：

- 是否真的部署了 6 个域名，而不是 5 个
- `assets` 域资源 URL 是否能返回 200

---

## 8. download 链路返回 404

### 现象

- download URL 返回 404

### 不要先下结论

download 链路最容易因为“测试 URL 本身不存在”而误判。

### 正确做法

使用一个你确认存在的 release asset URL 再测试。

只有在已知有效 URL 仍失败时，才进入配置层排查。

---

## 9. BaoTa UI 看不到站点 / 不能管理站点

### 现象

- nginx 能访问
- 但 BaoTa UI 里没有站点，或站点异常

### 典型原因

- 你只是手写/替换了 nginx 配置
- 但没有让 BaoTa 真正创建站点

### 正确理解

“BaoTa 识别网站”不是只看 vhost 文件存在。

### 修复方向

- 先通过 BaoTa UI 建站，或
- 用支持 BaoTa 创建站点的 helper create-if-missing
- 再把镜像模板接入这些站点

---

## 10. 修改后旧站点也异常

### 现象

- 新镜像部署后，旧业务站点受影响

### 典型原因

- 误覆盖了旧站点 vhost
- 主 nginx 配置改错
- include 放错范围，影响到全局解析

### 修复方向

- 先恢复本次变更前的备份
- 再重新检查哪些文件是镜像专属、哪些是全局修改

---

## 11. 一句话记忆版

- **gist 502**：先查 SNI / `proxy_ssl_name`
- **assets 502**：先查 IPv6 / resolver / variable proxy_pass
- **assets `/` 404**：可能正常，用真实资源 URL 测
- **archive / download 异常**：先查 whitelist map 是否进了 `http {}`
- **`nginx -t` include 报错**：先查 snippets 目录是否统一到 `/www/server/nginx/conf/snippets`
- **BaoTa 不识别站点**：说明只是 nginx 改了，BaoTa 建站链路没走通
