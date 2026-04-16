# GitHub Mirror Template Variables

本文说明这套模板的输入变量、派生变量，以及它们在两种域名模式下的含义。

---

# 1. 主输入变量

核心输入只有几个：

- `BASE_DOMAIN`
- `DOMAIN_MODE`
- `SSL_CERT`
- `SSL_KEY`
- `ERROR_ROOT`
- `LOG_DIR`

其中最核心的是：

- `BASE_DOMAIN`
- `DOMAIN_MODE`

---

# 2. DOMAIN_MODE

支持两种取值：

- `nested`
- `flat-siblings`

---

# 3. nested 模式下的派生关系

假设：

```text
BASE_DOMAIN=github.example.com
DOMAIN_MODE=nested
```

则派生为：

```text
HUB_DOMAIN=github.example.com
RAW_DOMAIN=raw.github.example.com
GIST_DOMAIN=gist.github.example.com
ASSETS_DOMAIN=assets.github.example.com
ARCHIVE_DOMAIN=archive.github.example.com
DOWNLOAD_DOMAIN=download.github.example.com
```

对应 URL：

```text
HUB_URL=https://github.example.com
RAW_URL=https://raw.github.example.com
GIST_URL=https://gist.github.example.com
ASSETS_URL=https://assets.github.example.com
ARCHIVE_URL=https://archive.github.example.com
DOWNLOAD_URL=https://download.github.example.com
```

---

# 4. flat-siblings 模式下的派生关系

假设：

```text
BASE_DOMAIN=github.example.com
DOMAIN_MODE=flat-siblings
```

则派生为：

```text
HUB_DOMAIN=github.example.com
RAW_DOMAIN=raw.example.com
GIST_DOMAIN=gist.example.com
ASSETS_DOMAIN=assets.example.com
ARCHIVE_DOMAIN=archive.example.com
DOWNLOAD_DOMAIN=download.example.com
```

对应 URL：

```text
HUB_URL=https://github.example.com
RAW_URL=https://raw.example.com
GIST_URL=https://gist.example.com
ASSETS_URL=https://assets.example.com
ARCHIVE_URL=https://archive.example.com
DOWNLOAD_URL=https://download.example.com
```

---

# 5. 模板占位符映射

当前模板文件中的主要占位符映射如下：

- `__HUB_DOMAIN__` -> `HUB_DOMAIN`
- `__RAW_DOMAIN__` -> `RAW_DOMAIN`
- `__GIST_DOMAIN__` -> `GIST_DOMAIN`
- `__ASSETS_DOMAIN__` -> `ASSETS_DOMAIN`
- `__ARCHIVE_DOMAIN__` -> `ARCHIVE_DOMAIN`
- `__DOWNLOAD_DOMAIN__` -> `DOWNLOAD_DOMAIN`

- `__HUB_URL__` -> `HUB_URL`
- `__RAW_URL__` -> `RAW_URL`
- `__GIST_URL__` -> `GIST_URL`
- `__ASSETS_URL__` -> `ASSETS_URL`
- `__ARCHIVE_URL__` -> `ARCHIVE_URL`
- `__DOWNLOAD_URL__` -> `DOWNLOAD_URL`

部署相关占位符：

- `__SSL_CERT__` -> `SSL_CERT`
- `__SSL_KEY__` -> `SSL_KEY`
- `__ERROR_ROOT__` -> `ERROR_ROOT`
- `__LOG_DIR__` -> `LOG_DIR`

---

# 6. 这些变量分别影响什么

## 域名 / URL 变量

主要影响：

- `server_name`
- 页面内替换后的链接目标
- 各子服务之间的跳转目标
- 某些 rewrite / sub_filter 中的镜像域引用

## 证书变量

主要影响：

- `ssl_certificate`
- `ssl_certificate_key`

## 错误页目录

主要影响：

- 自定义错误页的 alias/root 指向

## 日志目录

主要影响：

- 各 vhost 的 access/error log 输出路径

---

# 7. 推荐使用方式

不要手工逐个替换模板文件。

推荐流程：

1. 选定 `BASE_DOMAIN`
2. 选定 `DOMAIN_MODE`
3. 准备好 `SSL_CERT` / `SSL_KEY`
4. 准备好 `ERROR_ROOT` / `LOG_DIR`
5. 运行 `render-from-base-domain.sh`
6. 检查 `RENDERED-VALUES.env`
7. 运行 `validate-rendered-config.sh`

---

# 8. 部署经验补充

如果你的场景更接近下面这些条件：

- 已有 `*.example.com` 通配符证书
- 站点通过宝塔按子域拆开管理
- 想尽量少动现有证书与业务域

通常优先考虑：

```text
DOMAIN_MODE=flat-siblings
```

---

# 9. 注意事项

- `DOMAIN_MODE=flat-siblings` 时，`raw/gist/assets/archive/download` 会从 `BASE_DOMAIN` 去掉首个标签后派生，不是简单拼成 `raw.<BASE_DOMAIN>`。
- 改变量后应重新渲染，不要直接在已渲染结果里混改。
- 渲染完成后要继续跑自检，而不是直接投入部署环境。
