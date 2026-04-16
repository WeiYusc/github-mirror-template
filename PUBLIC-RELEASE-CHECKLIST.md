# PUBLIC-RELEASE-CHECKLIST.md

GitHub Mirror Template Pack：公开发布前最后检查清单

---

# 1. 仓库内容完整性

确认以下文件已存在且内容可读：

- `README.md`
- `INSTALL.md`
- `OPERATIONS.md`
- `FAQ.md`
- `CHANGELOG.md`
- `LICENSE`
- `RELEASE-NOTES.md`
- `FINAL-HANDOFF.md`
- `BT-PANEL-DEPLOYMENT-v1.md`
- `DEPLOY-CHECKLIST.md`
- `DOMAIN-PLAN.md`
- `TEMPLATE-VARIABLES.md`
- `REDIRECT-WHITELIST-DESIGN.md`
- `REDIRECT-WHITELIST-CONFIG-SKETCH.md`
- `render-from-base-domain.sh`
- `validate-rendered-config.sh`
- `conf.d/*`
- `snippets/*`
- `html/errors/*`

---

# 2. 项目定位口径

确认全仓口径一致：

- 这是 **GitHub 公共只读镜像模板**
- 不是 GitHub 官方项目
- 不支持登录
- 不支持 OAuth
- 不支持私有仓库
- 不支持写操作
- 不支持账号态会话代理
- 只允许 `GET / HEAD / OPTIONS`

如果某处还残留“完整镜像”“接近无差别登录代理”“支持私有仓库”等表述，发布前应全部移除。

---

# 3. README 首屏检查

确认 README 首屏已经清楚回答这几个问题：

- 这是什么
- 这不是什么
- 最快怎么开始
- 适合谁用
- 不适合谁用
- 主要文档看哪里

---

# 4. 文档导航一致性

确认 README 与各主文档之间没有明显断链：

- README 提到的文件确实存在
- 文档推荐阅读顺序合理
- Quick Start 所引用的脚本名、参数名与实际一致
- `flat-siblings` / `nested` 表述一致

---

# 5. 模板与文档一致性

确认文档没有脱离模板真实行为：

- 自定义错误页说明与实际文件一致
- 账号态/写操作拦截说明与 conf/snippets 一致
- 渲染脚本参数与变量说明一致
- `http {}` 级 redirect whitelist 说明准确
- `listen 443 ssl;` + `http2 on;` 写法与文档一致

---

# 6. 敏感/误导内容检查

发布前确认没有以下问题：

- 没有泄露真实生产证书路径
- 没有泄露真实私钥内容
- 没有泄露无关的服务器内部路径/密钥/凭据
- 没有误导读者以为支持私有仓库或登录态
- 没有把“仅验证过当前环境”写成“所有环境通用结论”

---

# 7. 可执行性检查

确认一个新读者能按文档完成基本试跑：

- 能理解需要准备哪些输入
- 能运行渲染脚本
- 能运行校验脚本
- 能看懂部署顺序
- 能看懂失败后如何回滚
- 能看懂上线后如何验证

---

# 8. 发布包装检查

确认以下内容已经准备好：

- `CHANGELOG.md`
- `LICENSE`
- `RELEASE-NOTES.md`
- 仓库简介文案
- 仓库 topics/tags 建议

---

# 9. 建议的最终人工验收

在点击公开发布前，再人工过一遍：

1. README 首屏
2. Quick Start
3. 安装文档
4. 运维文档
5. FAQ
6. 发布说明
7. LICENSE
8. CHANGELOG

如果这 8 项读下来没有明显冲突、误导、断链，就基本可以发了。

---

# 10. 发布判断标准

如果满足以下条件，可认为“适合公开发布”：

- 仓库定位清楚
- 功能边界清楚
- 目录结构清楚
- 文档入口清楚
- 风险边界清楚
- 脚本入口清楚
- 免责声明清楚

如果其中任何一项还模糊，优先补说明，不要硬发。
