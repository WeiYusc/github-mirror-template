# DEPLOY-CONFIG.md

`deploy.yaml` 是 `github-mirror-template` v0.2 生成流程的主配置入口。

如果你准备使用：

```bash
./generate-from-config.sh --config ./deploy.yaml
```

建议先读完这份说明，再修改 `deploy.example.yaml`。

---

# 1. 最短使用方式

```bash
cp deploy.example.yaml deploy.yaml
./generate-from-config.sh --config ./deploy.yaml
```

如果你只想覆盖输出目录，而不改配置文件，可以：

```bash
./generate-from-config.sh --config ./deploy.yaml --output-dir ./dist/github-mirror-test
```

如果你只想先看派生域名和关键值，而不生成部署包，可以：

```bash
./generate-from-config.sh --config ./deploy.yaml --print-derived
```

如果你想做一次生成前预演、确认本次会做什么，但仍不写部署包，可以：

```bash
./generate-from-config.sh --config ./deploy.yaml --dry-run
```

`--dry-run` 当前除了显示计划步骤，也会补充一些非阻断的静态提示，例如路径是否像生产目录、证书/错误页路径是否是绝对路径、`deployment_name` / `base_domain` / `output_dir` 的基本形态是否合理，以及 `output_dir` 是否已存在、是否非空。对于域名 label 形态、`tls.cert` / `tls.key` 是否看起来像常见证书路径，以及 `platform` 与 `nginx target hints` / `deployment_name` 与 `output_dir` 是否明显不一致，也会给出基础提示。进一步地，如果 `deployment_name`、`base_domain`、`output_dir` 呈现出明显不同的环境命名信号（如 `prod` / `staging` / `dev`）或看起来像另一个 deployment 的残留路径，也会给出一致性提醒。

然后：

1. 检查 `dist/<deployment_name>/`
2. 阅读生成出来的 `DEPLOY-STEPS.md` / `DNS-CHECKLIST.md`
3. 再决定是否手工落地到目标 Nginx / 宝塔环境

---

# 2. 配置结构总览

当前支持的主结构如下：

```yaml
deployment_name: github-mirror-prod

domain:
  base_domain: github.example.com
  mode: flat-siblings

tls:
  cert: /etc/ssl/example/fullchain.pem
  key: /etc/ssl/example/privkey.pem

paths:
  error_root: /www/wwwroot/github-mirror-errors
  log_dir: /www/wwwlogs
  output_dir: ./dist/github-mirror-prod

nginx:
  snippets_target_hint: /www/server/nginx/snippets
  vhost_target_hint: /www/server/panel/vhost/nginx
  include_redirect_whitelist_map: true

deployment:
  platform: bt-panel-nginx
  dns_provider: manual
  review_before_apply: true
  generate_checklists: true

docs:
  language: zh-CN
  audience: operator
```

---

# 3. 必填字段

当前生成器会实际校验以下字段：

- `deployment_name`
- `domain.base_domain`
- `tls.cert`
- `tls.key`
- `paths.error_root`
- `paths.output_dir`

此外这些字段虽然目前有默认值或不强校验，但在真实部署里通常也应明确填写：

- `domain.mode`
- `paths.log_dir`
- `deployment.platform`

---

# 4. 字段逐项说明

## 4.1 `deployment_name`

作用：

- 标识这次部署包的名字
- 帮助你区分多套输出
- 便于后续归档和交付

示例：

```yaml
deployment_name: github-mirror-prod
```

建议：

- 用简短、稳定、可辨认的名字
- 不要带空格

---

## 4.2 `domain.base_domain`

作用：

- 作为镜像域名派生的基础入口
- 会进一步派生出 hub/raw/gist/assets/archive/download 这些域名

示例：

```yaml
domain:
  base_domain: github.example.com
```

---

## 4.3 `domain.mode`

当前支持：

- `nested`
- `flat-siblings`

### `nested`

示例：

```yaml
domain:
  base_domain: github.example.com
  mode: nested
```

派生效果：

- `github.example.com`
- `raw.github.example.com`
- `gist.github.example.com`
- `assets.github.example.com`
- `archive.github.example.com`
- `download.github.example.com`

### `flat-siblings`

示例：

```yaml
domain:
  base_domain: github.example.com
  mode: flat-siblings
```

派生效果：

- `github.example.com`
- `raw.example.com`
- `gist.example.com`
- `assets.example.com`
- `archive.example.com`
- `download.example.com`

推荐：

- 如果你已有 `*.example.com` 通配符证书，优先用 `flat-siblings`

---

## 4.4 `tls.cert` / `tls.key`

作用：

- 指定 TLS 证书与私钥路径

示例：

```yaml
tls:
  cert: /etc/ssl/example/fullchain.pem
  key: /etc/ssl/example/privkey.pem
```

注意：

- 这里写的是目标环境里真实可用的路径
- 生成器不会帮你猜证书位置

---

## 4.5 `paths.error_root`

作用：

- 指向错误页落地目录
- 生成的 `html/errors/` 需要最终放到这里或等价位置

示例：

```yaml
paths:
  error_root: /www/wwwroot/github-mirror-errors
```

---

## 4.6 `paths.log_dir`

作用：

- 指定渲染配置中的日志目录变量

示例：

```yaml
paths:
  log_dir: /www/wwwlogs
```

默认值：

- `/www/wwwlogs`

---

## 4.7 `paths.output_dir`

作用：

- 指定本次生成结果输出到哪里
- 默认作为生成器的输出目录来源
- 可以被 CLI 参数 `--output-dir` 临时覆盖

示例：

```yaml
paths:
  output_dir: ./dist/github-mirror-prod
```

建议：

- 用相对路径放在仓库内部，便于检查与归档
- 不要直接指向线上 Nginx 目录
- 如果只是一次性改输出位置，优先用 `--output-dir` 覆盖，不必改配置文件

---

## 4.8 `deployment.platform`

当前支持：

- `bt-panel-nginx`
- `plain-nginx`

作用：

- 控制生成出来的 `DEPLOY-STEPS.md` 文案细节
- 让部署步骤更贴合目标环境

示例：

```yaml
deployment:
  platform: bt-panel-nginx
```

说明：

- 当前只影响部署说明文案
- 还不会改动核心渲染逻辑

---

## 4.9 `nginx.*_hint`

当前字段：

- `nginx.snippets_target_hint`
- `nginx.vhost_target_hint`
- `nginx.include_redirect_whitelist_map`

作用：

- 主要用于表达部署意图与后续扩展空间
- 当前生成器不会自动写入线上目录

因此这些字段现在更接近：

- 提示信息
- 未来增强点

而不是“执行指令”。

---

## 4.10 `docs.*`

当前字段：

- `docs.language`
- `docs.audience`

当前建议：

```yaml
docs:
  language: zh-CN
  audience: operator
```

说明：

- 当前主要是为中文输出文档保留配置位
- 后续可以继续扩展

---

# 5. 当前推荐配置

如果你现在只是想先走通一套可审查部署包，推荐直接基于下面这组思路：

```yaml
deployment_name: github-mirror-prod

domain:
  base_domain: github.example.com
  mode: flat-siblings

tls:
  cert: /etc/ssl/example/fullchain.pem
  key: /etc/ssl/example/privkey.pem

paths:
  error_root: /www/wwwroot/github-mirror-errors
  log_dir: /www/wwwlogs
  output_dir: ./dist/github-mirror-prod

deployment:
  platform: bt-panel-nginx
```

这是当前最稳的起点。

---

# 6. 当前不会发生什么

即使你配置好了 `deploy.yaml` 并运行生成器，当前也**不会**自动发生以下行为：

- 不会自动修改线上 Nginx 主配置
- 不会自动覆盖宝塔 vhost
- 不会自动 reload Nginx
- 不会自动改 DNS
- 不会自动申请证书
- 不会直接上线

当前模型仍然是：

> 先生成，再审查，再手工应用。

---

# 7. 常见错误

## 7.1 缺少 `python3`

你会看到类似：

```text
[generate-from-config] python3 is required for the v0.2 generator.
```

## 7.2 缺少 `PyYAML`

你会看到类似：

```text
[generate-from-config] Missing Python dependency: PyYAML
```

## 7.3 字段缺失

你会看到类似：

```text
[generate-from-config] Missing required field: BASE_DOMAIN
```

这时回头检查 `deploy.yaml` 即可。

---

# 8. 配置建议

如果你是第一次使用，建议遵守：

1. 先复制 `deploy.example.yaml`，不要从空白文件手写
2. 第一轮先不要改太多字段
3. 先跑通一套 `dist/` 输出
4. 先审查生成文档，再决定是否落地
5. 把“生成器配置”和“线上部署动作”分开思考

---

# 9. 相关文档

建议搭配阅读：

- `README.md`
- `INSTALL.md`
- `TEMPLATE-VARIABLES.md`
- `V0.2-SIMPLIFIED-DEPLOYMENT-DESIGN.md`
- `BT-PANEL-DEPLOYMENT-v1.md`

---

# 10. 当前结论

如果你问“现在该从哪里开始”，答案是：

1. 先看 `deploy.example.yaml`
2. 再看这份 `DEPLOY-CONFIG.md`
3. 然后运行 `./generate-from-config.sh --config ./deploy.yaml`

这样最顺。
