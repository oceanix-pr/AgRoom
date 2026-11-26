# 阿吉屋（AgRoom）AI Coding 入口

本仓库的应用工程位于 `AgRoom/`，项目文档统一维护在 `docs/wiki/`。

## 开始工作

1. 先阅读 `docs/wiki/Home.md`。
2. 所有代码任务都阅读 `docs/wiki/00-AI-Coding指引.md`。
3. 再按任务类型读取 Home 中列出的领域文档；不要一次加载整个 Wiki。
4. 文档与实现冲突时，以源码、`AgRoom/project.yml` 和 `AgRoom/Package.swift` 为准，并在同一变更中修正文档。

## 必守约束

- `personal` 与 `work` 的会话、智体、技能、记忆和知识数据必须物理隔离；禁止新增跨空间读写捷径。
- `Hub` 不缓存空间内服务。空间服务必须从当前空间的数据库连接现取现建。
- `AgRoomCore` 不依赖 UI；需要 WKWebView 等平台 UI 能力的工具由 UI 层通过注入接入。
- API Key 只存 Keychain；远程端点必须使用 HTTPS，本机回环地址除外。
- 用户可见文案必须走三语本地化；面向模型的提示词不本地化。
- 生产代码使用 `HubLogger`，不得使用 `print`；日志不得包含密钥或未脱敏隐私。
- 写入、删除、执行代码和其他有副作用的工具必须遵守既有确认策略，不能通过新入口绕过。
- Swift 6 严格并发开启。共享状态要有明确 actor 或锁归属，锁内不得执行 I/O、回调或跨 suspension。
- 新增、删除或移动源码后，检查 `Package.swift` 与 `project.yml` 是否同步，并重新生成 Xcode 工程。

## 验证

在 `AgRoom/` 下运行与改动相称的检查。核心逻辑优先运行：

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

涉及 App target、资源、签名、entitlements 或 XcodeGen 配置时，再运行 Xcode 构建。不要把测试数量、代码行数或当前版本号写进长期文档。

