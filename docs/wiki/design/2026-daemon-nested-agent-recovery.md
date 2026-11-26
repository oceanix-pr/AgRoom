# Daemon 子代理检查点与安全恢复设计

> 状态：已实现顶层失败关闭、App 交接所有权门禁、空间分区、按父调用持久化的子快照，以及正常结束的单委派结果对账。审计未完成子步骤的独立日志、重建子引擎和跨进程审批仍处于设计阶段。旧根证据尚未整体迁移，READY relay 只证明当次进程待命。本文不表示子代理细粒度恢复已经可用；故障注入与实窗验证以最终 QC 记录为准。实现事实以源码及 [01-项目与架构](../01-项目与架构.md)、[02-调度引擎](../02-调度引擎.md)、[03-工具系统](../03-工具系统.md) 为准。

## 目标与边界

让 Daemon 在进程中断后，凭可核实的父子调用身份和持久回执继续**尚无未知副作用**的子代理步骤。写入结果未知、批准状态不可重建或身份不匹配时保留现场，进入 `recoveryRequired`，等待用户核实；不生成新工具调用 ID 来代替原调用，不盲目重放写入。

本设计只覆盖 `AgentTool` 的单次嵌套 `DispatcherEngine`。`team_run`、远程 MCP 和跨进程审批收件箱另有契约；此设计不扩大它们的可用范围。Core 不依赖 UI，子代理仍继承父任务的空间、会话、工作区、工具面上限、权限和预算，不获得新的目录或跨空间服务。

## 审查时的风险与仍存边界

- `AgentTool.execute` 创建内层引擎时调用 `ExecutionContext.child(subtaskID: UUID(), …)`；`child` 再生成随机 `runID`，`TaskExecutionScope.child` 也生成新的范围 `id`。这些身份重启后不能凭当前参数重算。内层 `EngineRunSnapshot` 随父快照原子保存。内层仍无独立 `OperationJournal`，`ToolSuspension` 的内存闭包会随进程退出消失。
- `AgentTool` 外层调用沿用工具默认的保守 `.nonIdempotentWrite` 副作用分类，Daemon 会先写**父层** intent。内层可运行 `skill_run_script` 等具有副作用的工具，不能因为委派工具的 `permissionClass` 是 `.readOnly` 就认定内层纯只读。父层日志目前不能说明内层哪个调用已执行。
- 原先 `DispatcherEngine.executeToolBatch` 在免确认子集 `writeBack` 后先清批标记、再建立挂起队列，暴露占位结果的虚假干净边界。阶段 A 已把两个状态在同一锁内更新，并用消息配对与占位检查拒绝旧快照；`EngineRunSnapshot` 仍不保存可执行的 `PendingCall` 或闭包。
- 原先 `onCheckpoint` 只返回 `Void`，写失败无法在下一次副作用前同步停止；`finishSuspendedCall` 不补父层 receipt。阶段 A 已将检查点回调改为布尔屏障，并在内层最终结果后补父层 receipt。父层 receipt 仍不能证明内层每一步的执行状态，子日志仍待设计实施。
- 当前 `OperationJournal` 已对顶层调用绑定运行、空间、模型轮次、工具名及原始参数 SHA-256，并在写入前先落 intent。其 receipt 最多保存 4096 字符；若不能恢复**完整的模型可见结果**，不可把截断回执当成完整 toolResult 自动续跑。Daemon 已对未决 intent、日志异常和非空批检查点失败关闭。这些顶层保护应保留。

占位窗口已失败关闭；后续必须引入可恢复的内层记录，不能仅凭父层 receipt 自动续跑子代理。

## 身份与记录契约

父运行的权威身份沿用 `DaemonRunRecord.id` 及 `settings.taskAuthorization?.runID ?? record.id`，并核对 `restorationToken`。子记录由**引擎的可信调用上下文**创建；模型的 `message`、`context` 和任何自述都不能指定归属、批准或路径。建议在实际执行 `AgentTool` 时通过 TaskLocal 或等价内部参数传递父调用身份，不扩展模型 Schema。

| 字段 | 来源及用途 |
|---|---|
| `schemaVersion`、`parentRecordID`、`parentRunID` | 子记录格式与唯一父交接记录；未知版本失败关闭。 |
| `space`、`sessionID`、`assistantMessageID`、`restorationToken`、`workspaceID` | 父运行冻结的归属；恢复时与当前记录、会话恢复世代和工作区逐项核对。 |
| `parentModelStep`、`outerCallID`、`outerToolName`、`outerArgumentsSHA256` | 外层 `AgentTool` 调用的不可变身份；重复 ID、名称或参数变化不得复用子记录。 |
| `agentID`、`agentConfigDigest`、`providerID/configRevision/modelName`、`toolSurfaceDigest` | 冻结内层构造输入。提供商凭据只在 Keychain，记录只存非敏感身份和摘要；无法按原配置重建时转人工。 |
| `childRunID`、`subtaskID`、`childScopeID/digest`、`resourceContextDigest` | 在内层开始前生成并持久化，重启后复用同一身份；`TaskExecutionScope.digest` 含随机 scope ID，不能重新派生后假装相同。 |
| `childModelStep`、`childCallID`、`childToolName`、`childArgumentsSHA256` | 每条内层调用的日志身份；子 `OperationJournal` 以 `childRunID + space` 绑定，原始参数随快照保留，摘要用于核对。 |
| `checkpointSequence`、`phase`、`budgetCheckpoint`、`recoveryAttempts` | 判断持久顺序、收敛状态和恢复上限；恢复不得补充已耗预算或延长原 deadline。 |

子记录使用 `prepared → running → awaitingHuman / completed / recoveryRequired`。`phase` 只表示已经确认落盘的边界，不根据内存回调或模型文字推断完成。父、子调用各自使用独立 journal，不能把两者同名 `call.id` 混进一个以 ID 为键的日志。manifest 不重复保存参数原文、密钥、书签或完整提示词；必须持久化的内层消息由所属空间的受保护快照保存并设大小上限。

建议运行内存储布局（名称可按实现调整，但父子映射必须唯一）；整组须位于 [所属空间的 Daemon 分区](2026-daemon-space-storage-migration.md)，下图省略上层 `personal/` 或 `work/` 路径段：

```text
daemon/
  run-<parentRecordID>.json
  run-<parentRecordID>/
    operations.json                 # 现有父层 journal
    children/
      <parent-call-key>/            # SHA-256(父运行/轮次/调用 ID/工具/参数摘要)
        manifest.json               # 父子绑定与阶段，原子替换
        snapshot.json               # 子消息、轨迹、待处理调用、预算，原子替换
        operations.json             # 仅此 childRunID + space 的子 journal
        final-result.json           # 完整、有界的模型可见外层结果及摘要
```

父记录和子记录不可能跨多个 JSON 文件形成真正的单次事务。实现应使用同一运行的串行持久化协调器、每个文件的临时文件加原子替换，以及下述写入顺序和重启对账。任何写失败都不能把内存阶段当成已提交。已有父记录目录属于该父任务；子读取必须从父记录定位并校验 `space`，禁止按另一空间的路径或同名 ID 猜找。

## App→Daemon 执行权交接

阶段 A 之前，聊天移交先查询 `isAtRecoverableBoundary`，随后另取 `takeSnapshot()` 并写交接记录，二者没有共同的执行权屏障。现有 `claimHandoffSnapshot()` 在引擎短锁内核对批中、挂起与占位状态，并冻结快照；锁内不做磁盘 I/O。App 将任务范围、资源上下文及预算写入交接记录，成功后立即停止本地运行，屏蔽迟到回调与旧世代保存。更严格的父子运行世代和 Daemon 领取身份仍属后续阶段。

App 在 claim 存续时只在所属空间创建 `DaemonRunRecord`。仅当目录可读且目标文件可证明不存在时，才释放**同一** claim，让本地运行继续；写 API 报错但完整记录与预期快照一致时按成功交接处理。文件存在而损坏、或存储状态不可判定时保留 claim、停止本地并保全原文件，不用新记录覆盖未知证据。写入成功后即把本地状态单向转为 `transferred`：即使取消回调尚未送达，本地也不能再执行工具、提交最终正文或覆盖会话状态。App 崩溃于“记录成功→本地取消”窗口时，持久记录给 Daemon 执行权。退出时 App 等待新 Daemon 的随机 token READY；它只证明新进程已打开全局锁并准备等待旧进程，不保证随后取得锁或完成运行。后续仍需将 claim 世代持久绑定到 Daemon 领取协议，并用真实进程故障注入验证；介质本身不可写时无法保证新人工恢复凭证落盘。

## 落盘与执行顺序

1. 父引擎先持久化含稳定外层 tool call 的助手消息和**非空批标记**；检查点回调改为可确认成功或失败的屏障。批标记在外层调用完成前不得提前清除。App 前台尚无 Daemon 记录时，也须保持内存批标记，阻止退出移交。
2. 父 `OperationJournal` 以完整 `CallIdentity` 原子写下外层 intent，确认成功后才允许创建子记录。写失败不启动内层。创建并确认写下绑定父调用的 child manifest，固定 `childRunID/subtaskID/scopeID`、配置和预算；崩溃在父 intent 与 child manifest 之间时保守转人工。
3. 子模型返回工具调用时，先原子写子快照：助手消息包含原始稳定 `childCallID`、参数和 pending 标记。检查点落盘成功后才进入任何内层工具。批内重复或空 ID、旧 ID 身份冲突在并发前整批失败关闭。
4. 内层非只读调用先写子 journal intent，再执行一次，最后立刻写子 receipt。**只有 intent 无 receipt 表示结果未知**，包括工具报告错误、超时或取消而无法证明未执行；不因“幂等”标签自动重放。receipt 应保存完整的模型可见有界结果、成败和摘要；若仍使用当前截断格式且结果不完整，停止自动恢复。已确认 receipt 后才写子 toolResult/轨迹快照并清对应 pending 标记。
5. 内层挂起时先持久化子快照和待审调用身份，再返回外层 `ToolSuspension`；外层仍标记 pending。待审记录包含 `childCallID`、轮次、工具/参数摘要、`planDigest`、执行授权摘要、范围 ID/digest、权限模式、hard 原因与审核世代。**不持久化“已批准”凭证**。旧 `approvalID` 与本轮授权池不跨重启复用。
6. 内层结束后先保存完整、有界、可核对的最终结果及最终快照，再为外层调用写父 receipt；随后把父占位 toolResult 换成真实结果、保存父快照并清外层批标记。`finishSuspendedCall` 也须经过这条收尾顺序；不能仅改消息和轨迹。
7. Daemon 在 `committing`、普通失败收尾和删除交接记录前，同时核对父/子日志、检查点写入状态及所有活动子记录。任何未知结果保留记录与子目录，进入 `recoveryRequired`。

## 重启对账与批准语义

Daemon 先读取父记录，再只按父调用键定位子记录。核对版本、父/子运行与空间、会话和恢复世代、工作区与资源上下文、外层调用轮次/名称/参数摘要、智体及 Provider 配置、工具面、任务范围和剩余预算；任一缺失、变化或损坏均保留原文件并转人工。不能只因 `pendingToolCallIds` 为空或父层已有占位 toolResult 就向模型发送下一步请求。

恢复判断按已确认的最远持久阶段进行：

| 已持久状态 | 允许的动作 |
|---|---|
| 父 intent 存在但无匹配 child manifest | 保留记录、人工核实；不重新创建子运行。 |
| 子调用尚无 intent，且是可核验的纯只读调用 | 在原 `childCallID` 和预算下有限续跑；不让模型生成替代 ID。 |
| 子写入 intent 无 receipt，或 receipt/快照损坏 | 结果未知，人工核实；不重放该调用及后续步骤。 |
| 子 receipt 完整但结果快照未完成 | 只在身份完全匹配且能恢复完整模型可见结果时补子 toolResult；不执行工具。 |
| 子最终结果已持久、父 receipt 缺失 | 核对 AgentTool 协议版本后只补父 receipt，不重跑子运行。 |
| 父 receipt 已持久、父 toolResult 快照未完成 | 核对完整结果后只补父消息与轨迹，再继续；不得重新执行外层工具。 |
| 等待内层确认或提问 | Daemon 不自动批准。可重建待审卡时分配新的内存批准 ID，并在用户明确操作后重新核对调用、范围和计划；无法重建时人工恢复。 |

首个自动续跑切片仅允许经专门 allowlist 审计过的**纯本地读取**（例如当前空间的记忆/知识检索），以及尚未发出任何工具调用的模型请求。`web_fetch`、脚本、OCR/转写、外部系统读取和仅凭工具声明为 `readOnly` 的其他调用暂不进入 allowlist。每条只读调用在重启后最多重试一次，每个子运行最多自动恢复两次；次数与原预算、调用数和 deadline 一起持久化，达到上限转人工。已保存的只读结果优先复用快照，不重复读取。实现不能把这一限制解释成对其他只读工具的永久禁止，扩充名单需先逐项审计并补故障注入。

批准必须绑定当前内层调用和当前任务世代。重启时原 `PendingCall.approvalID`、`RoundAuthorizationStore`、自动审核批准以及“本轮允许”都失效；旧展示卡或父层委派参数不能替代内层真实待审请求。用户重新批准后，执行前仍按当前工具实例复核参数、`planDigest`、执行身份、目录身份和策略；若批准已经被消费而该写入的结果没有 receipt，仍转人工，不能再次弹卡并重做。子代理只能取父权限交集，Daemon 继续使用 `.headless` 工具面和后台确认策略。

目前重启后只有持久展示快照、没有原引擎句柄的确认/提问卡采用**只读核对**：展示原请求和已保存轨迹，不提供旧调用的批准或作答，也不以卡片点击自动生成模型新轮。用户明确结束等待后可另发新任务；轨迹不能代替子工具 receipt。未来若实现可重建的内层待审协议，须通过新的持久调用身份与新批准动作验收，不能悄悄把现有核对卡升级成可执行按钮。

旧快照缺 child manifest、未知版本、旧 `len=N` 摘要、缺身份字段、跨空间条目、损坏或不可读文件都不得自动升级为“干净边界”。保留父记录和原始子文件；无法解码的记录移入可发现的隔离区并提供人工核实入口，不静默删除。人工核实后的继续执行需要单独设计明确的用户动作和新运行世代，本方案不以模型自述自动判定外部写入状态。

## 分阶段实施与验收矩阵

| 阶段 | 主要改动文件 | 必须通过的验收 |
|---|---|---|
| A：先失败关闭 | `Runtime/DispatcherEngine.swift`、`Runtime/EngineSnapshot.swift`、`Services/DaemonHandoff.swift`、`AgRoomDaemon/DaemonMain.swift`、聊天移交门禁 | 注入“父占位 toolResult 已写、`PendingCall` 尚未建立”崩溃点；快照仍带未决外层 ID，App 不移交，Daemon 不自动续跑。检查点写失败不启动随后副作用；旧占位快照转人工。另在边界判定与快照间送达模型回复、claim 后送达旧回复、交接记录写失败、记录写成功但本地取消未送达、重复 claim/Daemon 领取各处故障注入；断言任一时刻只有一个执行/提交者，失败释放 claim 后本地可继续，成功移交后本地不能再执行或写回。 |
| B：父子身份和持久日志 | `Runtime/DispatcherTools.swift`（`AgentTool`）、`Runtime/ExecutionContext.swift`、`Runtime/TaskExecutionScope.swift`、`Runtime/DispatcherEngine.swift`、`Services/DaemonHandoff.swift` | 同一父调用重启得到同一子 run/scope；换空间、会话、工作区、父轮次/ID、工具、参数、智体/Provider 配置或工具面均拒绝复用；子写工具未落 intent 不执行。 |
| C：只读子步骤恢复与结果对账 | `Runtime/EngineSnapshot.swift`、`Runtime/DispatcherEngine.swift`、`Runtime/DispatcherTools.swift`、`AgRoomDaemon/DaemonMain.swift` | 故障分别注入子 intent 前、子 receipt 前后、子快照前后、子最终结果与父 receipt 之间、父 receipt 与父快照之间；已确认结果只补消息或回执，未知写入执行次数始终不增加。纯只读重试受名单、次数和原预算限制。 |
| D：待审恢复与任务中心 | `Runtime/DispatcherEngine.swift`、`Runtime/DispatcherTools.swift`、`AgRoomDaemon/DaemonMain.swift`、对应 UI/任务中心 | 重启旧批准不能执行新或变更后的内层调用；新批准需要真实用户动作并重新核验 hard/范围/计划；确认后崩溃但写入结果未知转人工。任务中心能查看并明确处理保留记录。 |

各阶段至少覆盖：同批两个委派、父子各自重复 `call.id`、两空间同名智体与同名调用、恢复世代变化、Provider/技能配置变化、日志或快照写盘失败、取消与 deadline、重复启动 Daemon、最终写回失败与延迟进度交错。测试用计数工具断言每条真实写入最多执行一次，并检查每个 assistant tool call 均与相同 ID 的最终 toolResult 配对；只有已核实完整回执才允许继续模型循环。领域 Wiki 应在每一阶段实现后更新，不能提前把本提案写成既成能力。
