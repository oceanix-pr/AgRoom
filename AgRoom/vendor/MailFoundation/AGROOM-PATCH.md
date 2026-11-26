# MailFoundation 固定副本

- 上游：<https://github.com/migueldeicaza/MailFoundation>
- 来源 revision：`c8da372a0fdf8c8b8e8323925481ba56d2dbd64b`
- 许可证：MIT，完整声明见 `LICENSE`；源码内原有版权声明全部保留。
- 纳入上游 `Sources/`、`Tests/`、`README.md` 与 `Package.swift`。

## 本地补丁

依赖声明补丁集中在 `Package.swift`：

- Apple 平台使用 Network.framework，不声明 `COpenSSL` / `COpenSSLMac`，也不提供 macOS `OpenSSL` trait。
- Linux 仍声明并依赖 `COpenSSL`。Linux 构建未在本项目验证。
- 移除未被任何 target 使用的 `swift-docc-plugin` 依赖；本地副本不单独生成上游文档，避免 Xcode 为此新增文档插件依赖。
- `MimeFoundation` 固定到应用清单和 XcodeGen 共同使用的 revision，避免解析工程时为 `main` 分支拉取更新。升级时同步修改这三处声明和两份 `Package.resolved`。
- 保留所有上游源码，包括当前 Apple 构建不使用的 OpenSSL 实现和头文件。

另外，移除 `AsyncSmtpClient.start()` 与 `AsyncPop3Client.start()` 内对 `self.setDisconnected()` 的两处冗余 `await`：读取任务继承当前 actor 的隔离，该同步方法无需跨 actor 等待。协议行为不变，避免新工具链的 `UnnecessaryEffectMarker` 警告。

上游在默认关闭 OpenSSL trait 时仍声明两个 system-library target，SwiftPM / Xcode 会探测它们的 pkg-config 信息并产生未使用依赖的安装警告。补丁从包图中移除 Apple 平台不需要的目标，不屏蔽诊断，也不安装额外系统库。

上游 `README.md` 原样保留，其中启用 macOS OpenSSL trait 的说明不适用于本副本。

另外，`AsyncImapSession.appendDraft(mailbox:bytes:)` 提供草稿专用 APPEND：持有独占命令访问、验证输入和容量、使用 Modified UTF-7 名称及同步 literal，收到 continuation 后才发送原始二进制字节；沿用现有超时与断线机制。APPENDUID 解析、UIDPLUS 门禁、写前凭证、逐步核验和未知结果恢复在阿吉屋适配器与空间服务中处理，不增加任意协议命令入口。协议回放覆盖同步 literal、二进制字节、路径编码、服务器拒绝及缺失 APPENDUID；完整 App 构建继续使用此固定副本。

## 升级

从明确 revision 重新导入上述上游文件，保留许可证，重新应用本清单补丁，并更新本文件中的来源。SPM 与 XcodeGen 都必须继续指向同一目录；同步检查 MimeFoundation 的锁定结果，运行核心测试与 App 构建。若上游已修复未使用 OpenSSL 目标的探测警告，可评估恢复远程依赖。
