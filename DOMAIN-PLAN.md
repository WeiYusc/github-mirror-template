# GitHub Mirror Domain Plan

本文说明这套 GitHub 公共只读镜像模板的域名规划方式。

目标是两件事：

1. 域名职责边界清楚
2. 证书与部署方式可按现实环境灵活选型

---

# 1. 设计目标

这套模板不把所有流量都塞进一个域名，而是按 GitHub 实际流量类型拆成多个镜像入口：

- hub 页面
- raw 文件
- gist
- assets 静态资源
- archive 源码包
- download 下载链路

这样做的原因：

- 更接近 GitHub 原始站点结构
- 更容易按用途做规则隔离
- 更容易排障
- 更容易按域名做日志和限流
- 更适合后续扩展资源域

---

# 2. 支持的两种域名模式

模板支持两种模式：

- `nested`
- `flat-siblings`

这两种模式都由同一个输入驱动：

```text
BASE_DOMAIN=<your-main-mirror-domain>
```

---

# 3. nested 模式

## 3.1 示例

```text
BASE_DOMAIN=github.example.com
```

派生域名：

- `github.example.com`
- `raw.github.example.com`
- `gist.github.example.com`
- `assets.github.example.com`
- `archive.github.example.com`
- `download.github.example.com`

## 3.2 特点

优点：

- 所有镜像子服务都挂在同一个主域下
- 语义直观
- 对“一个镜像主域统领全组服务”的理解最自然

缺点：

- 如果你要用通配符证书，常常需要 `*.github.example.com` 这一层
- 某些现有证书体系不方便直接复用

---

# 4. flat-siblings 模式

## 4.1 示例

```text
BASE_DOMAIN=github.example.com
```

派生域名：

- `github.example.com`
- `raw.example.com`
- `gist.example.com`
- `assets.example.com`
- `archive.example.com`
- `download.example.com`

## 4.2 特点

优点：

- 更容易复用已有 `*.example.com` 通配符证书
- 域名更短
- 在宝塔中按 6 个兄弟子域分别建站更直接
- 现实部署里常常更省事

缺点：

- 从“层级语义”上看，不如 nested 那么整组归属明确

## 4.3 当前推荐

如果你已经有：

- `*.example.com` 这类通配符证书
- 现成的兄弟子域管理方式
- 宝塔/Nginx 多站点拆分部署习惯

通常更推荐 `flat-siblings`。

> 常见部署选择会优先使用 `flat-siblings`。

---

# 5. 6 个核心域名的职责

## 5.1 HUB_DOMAIN

主页面入口，对应 GitHub 仓库浏览页。

主要承载：

- 仓库主页
- README
- 文件树
- blob 页面
- issues / pulls 列表等公开只读页面

## 5.2 RAW_DOMAIN

原始文件内容访问。

主要承载：

- raw 文件
- 文本内容直接取回

## 5.3 GIST_DOMAIN

gist 页面与 gist raw 相关访问。

## 5.4 ASSETS_DOMAIN

静态资源域。

主要承载：

- CSS
- JS
- 图片等静态资源

## 5.5 ARCHIVE_DOMAIN

源码归档下载入口。

主要承载：

- zip/tar.gz 源码包
- codeload 相关下载

## 5.6 DOWNLOAD_DOMAIN

release / artifact 下载链路。

主要承载：

- release 下载
- 其他受控下载跳转

---

# 6. DNS 要做什么

选定 `BASE_DOMAIN` 和 `DOMAIN_MODE` 后，你需要把派生出来的 6 个域名都解析到目标服务器。

如果后续联调发现还需要补资源域，可以再考虑：

- `avatars.*`
- `objects.*`
- `camo.*`

但这些不应该一开始就无脑加满，而应按实际缺口补。

---

# 7. 证书建议

## 如果你用 nested

你通常需要确认：

- 单独给每个域名签发
- 或能拿到更深一层的通配符能力

## 如果你用 flat-siblings

通常更容易复用：

- `*.example.com`

这也是它在现实部署里更常被优先考虑的原因。

---

# 8. 选择建议

## 选 nested，当你：

- 更看重层级语义统一
- 不介意多一层域名深度
- 证书体系也能配合

## 选 flat-siblings，当你：

- 更看重部署便利
- 想复用现有通配符证书
- 想在宝塔中一域一站地拆开管理

---

# 9. 不变的原则

无论选哪种模式，都不变的是：

- 这是 **GitHub 公共只读镜像**
- 不是登录代理
- 不是私有仓库代理
- 不是写操作代理
- 下载链路要做 redirect whitelist 收口
- 所有镜像域应通过新增配置增量接入，不要挤占现有业务域
