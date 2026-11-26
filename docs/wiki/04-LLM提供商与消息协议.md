# LLM 提供商与消息协议

相关实现位于 `CloudProvider.swift`、`CloudProviderTools.swift`、`CloudProviderResponses.swift`、`CloudProviderImages.swift`、`ProviderCompatibility.swift` 和 `LLMModels.swift`。Core 对上提供统一消息模型，对下适配 OpenAI 兼容 Chat Completions、OpenAI Responses、Anthropic Messages 与独立 Images API。

## 配置与密钥

Provider 元数据保存在全局数据库，API Key 通过 `KeychainService` 按 Provider 身份读取。配置进入请求前必须经过 `EndpointSafety`：远程地址要求 HTTPS，本机回环地址可用于 HTTP 开发服务。

提供者可设置最多 20 个完整字符的可选别名，随元数据保存在全局库。对话与首次任务的模型选择统一优先显示别名，留空时沿用提供者名称与模型；保存配置后界面重新读取最新显示值。别名仅是显示标签，实际请求、路由和用量仍使用原提供者身份与模型标识。旧数据库通过独立迁移补空别名，旧配置 JSON 缺字段时兼容为空；中文、组合字符与 emoji 按完整字符计数，不按 UTF-8 字节截断。

提供者编辑表单从已保存配置初始化，匹配端点只选中预设标签，不重新填充模型。只有用户主动选择快捷预设时才应用其默认端点和模型；再次打开、保存未修改的表单或窗口重新出现都不能把自选模型覆盖为默认值。DeepSeek 新配置的快捷预设使用 `deepseek-flash`，已有配置的模型 ID 保持用户保存的值，不按显示别名推断或静默迁移。

提供者顺序由全局库的独立排序列保存，设置页可逐项上移、下移，所有配置列表沿用同一读取顺序。旧库迁移保持创建时间顺序及同时间的插入顺序；新增项追加末尾，编辑和启停保留位置。相邻移动在单个事务中读取最新列表并只更新排序列，失败整体回滚，过期条目不能覆盖其他配置。排序不修改已选提供者身份；没有有效选择时仍回退排序后的首个启用项。

不要把密钥写进模型配置 JSON、日志、错误提示、备份或测试夹具。

模型价格查询独立于推理请求，由 `ModelPricingService` 读取公开目录，不使用 Keychain、不发送空间业务数据或产生推理用量。OpenRouter 的 `pricing.prompt/completion` 是每 Token 美元价格，换算为每百万 Token；Models.dev 的 `cost.input/output` 已按每百万 Token 美元报价。提供商按 HTTPS 端点及服务路径匹配，地区端点分开，模型 ID 不做模糊或前缀匹配。缺项、动态价格标记、无效数值和无法表达的按请求收费均保留未知；目录查询有响应体上限、超时和取消边界，不接受跨主机或降级重定向。公开费率只用于普通费用估算，不冒充服务商账单。已核对的 OpenAI 官方图片型号使用带固定核对日期与官方链接的参考快照，按文字输入、图片输入、图片输出及缓存输入分别展示；快照不是实时刷新结果。只匹配官方 HTTPS 端点和精确型号，不推断别名、版本或转发价格。

账户余额通过 `CloudProvider.fetchBalance` 使用配置对应的 Keychain 凭据读取，当前适配 DeepSeek 与 Kimi。查询采用独立的短请求超时和有界读取，不产生推理回执或修改服务端余额。金额保留服务商返回精度；DeepSeek 沿用响应币种，Kimi 国内端点为 CNY，国际端点为 USD（见 [Kimi 余额接口](https://platform.kimi.ai/docs/api/balance)）。费用重计保存的仅是所属空间的查询快照和统计起点，不能把它解释为重置服务商账户。

## 按模型参数与能力

聊天输入区与模型设置共用 `ModelReasoningProfile`。档位由规范化端点、实际请求型号和该型号的能力记录决定。选择「默认」时省略力度字段。旧配置的「快速」和「深入」在读取时映射到可用档位。

| 配置 | 请求行为 |
|---|---|
| DeepSeek 官方 Chat Completions | Flash 和 V4 Pro 可选关闭、low、high、max。关闭时发送 `thinking.type=disabled`。思考开启时省略温度。能力目录缺少输入类型时，Flash 显示文本和图片，V4 Pro 显示文本。 |
| Kimi 官方 K3 / K3.1 Pro | 新配置使用账户模型列表选择可用型号。思考采用服务商默认 max，或显式 low、high、max。自动回复采用已知输出上限，缺少输出元数据时以 16,384 Token 为默认值，再按模型窗口收紧。 |
| OpenAI 官方 GPT Sol / Astra | Responses 提供 low、medium、high、xhigh、max。按请求保留输出项目顺序和阶段，`commentary` 进入过程记录，`final_answer` 进入回答。单独的进度消息不能完成任务。 |
| Qwen3.6，包括 35B-A3B | DashScope 使用顶层 `enable_thinking`。vLLM / SGLang 实例已声明模板能力或用户明确指定时使用 `chat_template_kwargs`。对包含匹配历史推理的追问按对应格式传 `preserve_thinking`。查询窗口时取实例所报 `max_model_len` 与其他已知上限中的较小值。 |

自托管 Qwen3.6 时，工具解析由推理服务负责。vLLM 的模型卡示例使用 `qwen3_coder` 工具解析器。阿吉屋消费服务返回的结构化调用；正文中的残缺工具标签会结束本次请求并报告解析问题。

服务商的参数说明见 [DeepSeek 思考模式](https://api-docs.deepseek.com/guides/thinking_mode/)、[Kimi 思考模型](https://platform.kimi.com/docs/guide/use-thinking-models)、[OpenAI 部署指南](https://developers.openai.com/api/docs/guides/deployment-checklist) 与 [Qwen 模型卡](https://huggingface.co/Qwen/Qwen3.6-35B-A3B)。

`ModelParameterService` 在全局库保存不含空间业务数据的模型偏好与能力缓存。偏好按提供商身份、规范化端点和精确模型 ID 保存，自动工作流共用同一份手动偏好；能力独立保存，刷新不能改写用户的手动值。切换模型或修改端点不会沿用另一模型/端点的参数。旧全局参数仅作为旧运行与专用任务的兼容配置，不自动把旧的超大输出值复制给每个模型。新偏好写入 automatic 记录；没有该记录时优先读取旧 chat 记录，仅无 chat 时采用旧 coding 记录，旧记录不删除。

文本模型的自动回复预算取当前端点和型号的已知输出上限，并受应用上限约束。输出能力未知时，普通聊天默认 8,192 Token，编码工作流和 Kimi 思考模型默认 16,384 Token。小窗口会收紧这些兼容值。发送前按本次输入、工具定义、协议余量和显式任务预算确定可用输出。思考档位按模型保存，自动温度省略参数。服务商声明的温度支持与当前推理模式共同决定温度能否发送，缺失时沿用模型规则与参数拒绝后的兼容兜底。工具步数、子代理步数和历史消息条数属于应用执行策略。

本地上下文输入预算在「模型服务 → 模型参数与运行预算」按同一模型保存，支持默认或手动值。选择历史时，自动模式按工作流原有的回复额度和协议余量留出空间，实际输入较短时可将空余窗口用于回复。手动模式按设定的有效回复上限预留。能力未知时仍使用有限的本地输入额度。手动值在能力刷新收紧时保留，界面同时显示实际生效额度。运行参数随快照移交，旧快照沿用原有上限和预留方式。

能力查询只发起有界的元数据 GET，不调用模型生成。配置端点的模型元数据优先；缺项可按精确服务端点和模型 ID 从 Models.dev 参考目录补齐，不能把官方限制套给同名未知转发。OpenRouter 查询实际模型端点，对自动路由使用可用端点的保守共同上限；任一端点缺少限制时该项仍未知，不以其他端点的最大值代替。能力同时保留服务商声明的 `supported_parameters`；OpenRouter 对各可用端点取交集，不把某一路由独有的字段当作通用支持。能力保留来源、获取时间、未知项及路由语义，正常缓存按天刷新，失败查询短暂退避并保留已有缓存；手动刷新可主动重试。元数据请求有总超时、响应体上限和同源重定向限制；只有配置端点收到自己的 Keychain 凭据，公共目录不接收凭据、提示词或空间内容。

前台每轮先建议内部工作流，再解析并冻结所选模型参数；历史按消息数量与 Token 预算共同裁剪，实际请求再计入系统提示、输入、图片、历史与工具 Schema，收紧输出至模型输出限制及剩余上下文。子代理和团队 Worker 按实际路由的模型应用生成参数，继承本轮内部工作流与父任务预算；定时等显式任务预算仍是上限。退出移交携带本轮参数快照，后台不得因全局设置变化而扩大运行预算。协议层的响应字节限制、工具审批和执行边界独立保留。

## 统一消息模型

- `EngineMessage` 表示 system、user、assistant 和 toolResult。
- `EngineImage` 表示多模态图片内容。
- `ToolCallRaw` 保存调用 ID、工具名和原始参数 JSON。
- `ToolDefinition` 保存工具名称、描述和参数 Schema。
- `ChatReply` 汇总正文、思考、工具调用、token 用量和结束原因（`finishReason`）。
- `EngineContinuation` 单独保留 Provider 续接数据：OpenAI 兼容协议的 `reasoning_content`，Anthropic 按顺序排列的完整内容块（含 `signature`、`redacted_thinking` 和工具输入），以及 Responses 有序输出项（含加密推理、assistant phase 与 function call）。普通/流式解析、工具往返与消息快照共用该数据；不能把推理回填文本重新当作 assistant 正文发送，也不能把不透明签名当作 UI 正文或写进日志。

适配器必须保持工具调用 ID 和结果 ID 的严格配对。裁剪历史、压缩上下文或恢复快照时，不能只保留其中一侧。

Anthropic thinking 块和 Responses 推理项可能依赖此前的消息和工具定义。首次收到这类续接数据时冻结实际请求的完整工具定义，随快照恢复；实际执行继续通过当前技能白名单、Schema、权限和确认守卫收窄。旧快照缺少工具定义时保留兼容回退。仅生成最终正文的请求保留绑定定义并发送协议对应的 `tool_choice=none`，返回意外工具调用则失败关闭。未启用 thinking 的内容块可沿用普通压缩策略。

按模型/模式可启用原生长上下文压缩；新编码参数默认启用，聊天默认关闭，旧运行快照缺字段时不追加控制。只向已识别支持的官方 HTTPS OpenAI Responses 模型发送 `context_management`，以有效本地输入预算的一半提前触发；保留 `store: false`。服务商返回的 `compaction.encrypted_content` 保持不透明，不显示为正文或思考。下一请求可裁去该轮之前的旧对话，保留系统规则、当前用户原始要求、完整规范输出轮次及之后的调用/结果，并追加真实任务检查点。快照保存当前请求摘要身份，旧快照缺身份时保守保留用户消息。不能从不透明压缩项推断检查通过；被裁掉的源码仍须按当前版本重新读取。其他服务商继续普通策略，签名前缀不可改写时超限明确失败。原生协议依据 [OpenAI Compaction](https://developers.openai.com/api/docs/guides/compaction)；当前实现使用 Responses 内置压缩，不调用独立 `/responses/compact`，也未接入 Anthropic 原生压缩。

## 协议适配

空间内的请求回执保存可选 `rootRunID`、`runID`、`parentRunID`、用途与分类 Token 估算。根身份贯穿普通委派、团队 Worker、审核与验证，即使中间任务节点没有 HTTP 回执，也能归入原任务。分类包括系统规则、工具定义、历史、当轮对话、源码工具结果、任务状态、其他工具结果、不透明续传、图片和协议开销；不保存提示词、路径或源码。估算与真实输入/输出/缓存/推理字段分开，缺失真实用量保持未知。身份通过任务局部上下文传播到 Provider 参数适配重试，不修改共享 Provider 的状态；旧回执与完整备份保持兼容。审核模型使用无工具 chat 返回真实 usage，缺失时才按预留量保守结算。

「模型参数与运行预算」按模型和模式保存提示缓存策略；编码模式的新参数快照默认优化可复用前缀，普通聊天默认服务商行为。旧快照缺字段时不追加缓存参数，避免修改已有签名续传。选择「默认」时，应用省略缓存控制字段，由服务商决定是否启用缓存。

优化仅用于已核实的官方 HTTPS 端点：OpenAI Responses 的缓存键按空间和提供商区分，GPT-5.6 及之后模型使用 `prompt_cache_options`，并在前两段稳定上下文放显式边界；旧模型保持隐式策略。Anthropic Messages 启用短时 `cache_control`。兼容网关和本机端点不因型号同名而接收厂商专属字段。Responses 继续 `store: false`；缓存命中不减少上下文占用。缓存写入可能收费，效果需同时核对读/写用量与总费用。协议依据 [OpenAI 提示缓存](https://developers.openai.com/api/docs/guides/prompt-caching) 和 [Anthropic 提示缓存](https://platform.claude.com/docs/en/build-with-claude/prompt-caching)。

`ProviderCompatibility` 统一选择端点协议、输出字段、推理力度和温度规则。显式 `/responses` 使用 Responses，显式 `/messages`（含自定义域名）使用 Anthropic；OpenAI 官方 Chat Completions 端点上的现代推理模型使用同源 Responses 路由，旧模型继续 Chat Completions。兼容网关、OpenRouter 与本地服务不会因为模型同名而被改写路由。实际请求 URL 仍经过端点安全校验，持久配置不被修改。

Chat Completions 使用 `messages`、嵌套 function tools 和 `tool_calls`，输出预算按端点能力选择 `max_tokens` 或 `max_completion_tokens`；Responses 使用 `input`、扁平 function tools 和 `max_output_tokens`；Anthropic 使用内容块和 `max_tokens`。Responses 使用 `strict: false` 保留既有工具参数的可选字段语义，仍执行相同的 Schema 校验。四个入口 `generate`、`stream`、`chat` 和 `chatStream` 共用请求构造与参数自适应，普通生成保留原有外部内容分隔符。

Responses 请求使用 `store: false`，有序保存输出项并在工具续接时重放，`function_call_output.call_id` 必须匹配原 `function_call.call_id`，不能使用输出项的 `id` 代替。加密推理只用于续接，不显示为正文。该适配依据 [Responses 工具调用](https://developers.openai.com/api/docs/guides/function-calling) 与 [无状态推理续接](https://developers.openai.com/api/docs/guides/reasoning)；GPT-6.1 Terra 的工具调用要求 Responses，见[模型文档](https://developers.openai.com/api/docs/models/gpt-6.1-terra)。差异收敛在 Provider 层，引擎只处理统一模型。

新增 Provider 或兼容网关时，优先扩展协议适配层，不在调度引擎中散布厂商判断。

对象类型的工具参数在发送时必须显式包含 `properties`，无参数工具使用空对象 `{}`。Provider 层为缺少该字段的对象 Schema 补齐空对象，以兼容 LM Studio 等会校验此字段的端点；保留已有属性、`required` 和 `additionalProperties` 等约束，三种协议的普通与流式请求共用此处理。

Provider 在 HTTP 发送前校验工具 Schema 的基础结构：JSON 必须是对象，根类型必须显式为 `object`，已有 `properties` 必须是对象。OpenAI 兼容协议额外拒绝根节点的 `oneOf`、`anyOf`、`allOf`、`enum`、`const` 和 `not`；该限制不递归套用于属性，也不用于改写 Anthropic 或 MCP 的原始约束。不兼容或损坏的定义抛出不可自动重试的 `invalidToolSchema`，界面通过三语提示标明工具与问题字段；不得静默删除约束、替换为空 Schema 或移除工具后继续发送。此检查覆盖已知的基础兼容要求，不代替完整 JSON Schema 校验。

正文与推理文本必须分开保留（`ChatReply.text` / `ChatReply.reasoning`）。推理是模型的内部计划，不能当作最终回答：解析器在正文为空且确有推理时仍会回填 `text` 以兼容「补全预算耗尽在思考上」的场景，但会记录 `textUsedReasoningBackfill`，让调度引擎能区分「模型真的回答了」与「只有内部计划」。集中式回复（非流式）与两个流式解析器（OpenAI 兼容 / Anthropic）都要维护这两个字段。

带工具的执行请求里，协议异常必须失败关闭，不能静默当成回答：

- 只有推理、没有正文与工具调用（`reasoningOnlyResponse`）——「我需要安装……」这类计划被当成最终回答的正是这种情形。
- 结束原因声称工具调用（`finish_reason = tool_calls`）却没有解析到任何工具调用（`toolCallFinishMismatch`）。
- 正文或推理里残留残缺工具标记（`unparsedToolCall`，已有检测保留）。

这些错误与 `unparsedToolCall` 同属确定性输出，不纳入自动重试。

采样参数不是所有模型都接受。自动温度省略参数；手动温度还必须满足服务商能力和当前推理模式。OpenAI 推理模型仅在明确选择其支持的 `none` 力度时考虑发送温度；不支持关闭推理的模型使用低档位表示快速。能力目录不能用一个温度布尔值覆盖推理模式限制。Anthropic 启用 thinking 时继续省略温度，自动思考预算给最终回答留出空间。DeepSeek 官方混合模型、GLM、DashScope 与 OpenRouter 保留各自的思考参数格式，「标准」保留服务商默认。

请求自适应只处理尚未开始生成的 HTTP 400/422 拒绝。字段名不支持、Token 数值超限、温度拒绝和 `stream_options` 不支持分别最多修正一次，组合错误也受总次数约束。Chat 的两种 Token 字段可以根据明确拒绝更正，字段不支持时不能降低数值冒充修复；数值超限必须有范围或超限语义才收紧预算。剩余不支持参数抛不可自动重试的 `unsupportedParameter`，通过三语提示协议不兼容，不再显示“Token 越界”。不通过删除工具或弱化 Schema 来规避拒绝。

## 图片模型

`CloudProviderImages` 为 `gpt-image-*` 与 `chatgpt-image-latest` 提供独立的 Images API 请求。前台聊天明确选择图片模型后，文生图发送本轮原始提示词到同源 `/images/generations`，显式附图使用 multipart `/images/edits`；保留网关前缀与查询参数，不切换服务主机。请求不发送聊天系统提示、旧历史、工具、温度或文本输出 Token 字段。普通生成、自动标题、编码、子代理和后台入口拒绝把图片模型作为文本模型使用；连接检查只验证凭据与模型列表，不能宣称出图容量可用。

图片响应只接受有界、有效的 PNG 内联数据，不自动下载远端返回的任意图片 URL。生成仍经过提供商并发闸门、单次用量回执、任务预算预留与实际用量结算、原截止时间和取消检查。图片接口没有文本 Token 上限字段，预算预留不等于服务商对单张图片费用的硬上限。只对明确收到的 HTTP 429/503 拒绝有限退避，断线或损坏响应不自动重新生成。图片请求不能移交或从旧快照重放，避免结果不明时重复生成与计费。503 容量错误单独通过三语说明等待或切换服务，不误报为 Token 数值或凭据问题。

## SSE 流式处理

流式解析需要处理：

- 文本和思考增量。
- 分片到达的工具名与参数 JSON。
- 多个并行工具调用的独立累积。
- usage 可能只在最终事件出现。
- 结束标记、空行、未知字段和兼容网关的轻微格式差异；`data:` / `event:` 后的空格可省略。
- 用户取消、连接结束和长时间无数据的停滞检测。

Chat Completions 流按空行组装完整 SSE 事件，多行 `data:` 以换行连接后再解析，并同时限制单行、事件合计与整条响应大小（见 [SSE 事件解释规则](https://html.spec.whatwg.org/multipage/server-sent-events.html#event-stream-interpretation)）。工具名与参数按调用索引累积，终态即使没有 `delta` 也保留 `finish_reason`。兼容网关在 SSE 中返回完整 `message` 时，只接受与已观察正文、推理和调用前缀一致的快照，补齐内容但不重复外发或累加工具参数；调用 ID 与结果 ID 保持原值。损坏事件、缺失或重复的调用身份、快照冲突会拒绝整批调用，不再静默跳过或生成替代 ID。真正声明工具结束却没有任何调用的响应仍失败关闭，不通过猜测参数或自动重放规避。相关回归位于 `ProviderCompatibilityTests` 与 `SSECompletionTests`。

Responses 流支持多行 SSE 数据，终态 response 对象是完整输出的校验依据；`output_item.done`、参数片段和 EOF 都不能独立授权工具执行。未完成、失败、损坏或重复调用 ID 的响应失败关闭；只有完成的完整 JSON 对象参数才进入引擎。Token 截断的纯文本可沿用有界续写，截断工具调用不能执行。SSE 内错误与异常 EOF 不触发参数自适应重放。

Provider 可以注入固定空间的 `ProviderUsageRecorder`，普通生成、流式生成与工具对话在实际 HTTP 尝试处保存请求回执；自适应重试会产生独立记录。用量不绑定当前显示的回答版本，不存请求正文或密钥，未返回的 Token 计为缺失而非零。`ProviderTokenUsage` 在普通与流式请求中统一保存缓存读写、普通输入、输出及服务商报告的模型；累计 usage 事件合并覆盖而非相加。请求模型与响应模型分别保留；缓存写入不是命中，缓存子项不得再次加到输入总数。Responses 的 `input_tokens/output_tokens` 及对应 details 与 Chat、Anthropic 的用量一并解析；失败终态中已报告的用量同样保留。图片生成回执另存文字输入、图片输入及图片输出 Token，随空间数据库迁移与备份恢复保留；输入分类合计和输出分类必须与总量一致，才可按分类普通费率估算。旧记录或转发缺少明细时费用保持未知，不将汇总输入全算成文字输入，也不从合计缓存计数推测分类折扣。

HTTP 普通响应和 SSE 在读入时共同限制总字节数，SSE 还限制单行；正文、推理、工具参数与调用数量各自有累计上限，超限主动取消网络并抛不可重试的 `responseTooLarge`。限制必须发生在无限缓冲之前，不能只截断最终显示内容。

流式请求在每次实际 HTTP 尝试结束时将合并后的用量快照交给引擎，断流也保留此前上报的推理明细。同一请求的累计 usage 覆盖合并，请求之间才求和。引擎独立保存 `reasoning_tokens` 及上报覆盖情况，思考区只展示可见文本，不显示推理用量；普通输出、工具参数、输入上下文和推理文本长度都不能代替缺失的推理计数，明确返回零与未返回仍需区分。

回调可能进入 UI，因此 Provider 不直接操作界面状态。调用方负责切回正确 actor，并对高频增量节流。

聊天的生成速率在每次实际 HTTP 尝试中使用单调时钟采样正文、推理与工具参数增量。实时 Token 按现有估算口径累计，结束时优先使用服务商上报的输出量；仅对有有效输出区间的请求按流式时长加权，不把工具与人工等待算作生成时间。单包或过短区间不计算，未知用量保留近似标记。引擎在锁内累计纯数值快照，锁外通知主 actor，并用递增修订号防止迟到事件覆盖新状态；测速不持久化正文或影响用量回执与审批。

## 超时、取消与重试

- 请求超时需要容纳思考模型较长的首 token 延迟，同时由流式停滞看门狗识别真实断连。
- 取消必须结束网络读取和后续解析，不再回调旧运行。
- 重试按 `URLError.Code`、HTTP 状态或明确的 `LLMError` 分类；本地化错误描述只能作为最后兜底。
- 429、部分 5xx 和短暂网络错误可以有限退避重试。
- 401、配置、Schema 和请求参数错误不重试。
- 一旦流式正文已经展示，不自动重放整次请求。
- 图片拒绝只在请求确实含图片、尚未流出正文且尚未降级时允许一次文本重试；该重试消耗现有次数预算，不能减回计数或无限重放。
- 执行上下文的绝对 deadline 覆盖在途模型请求，超时取消底层读取；父任务和团队 Worker、验证者共享原 deadline，不在重试时重置。

## 外部内容边界

用户输入、网页、文件、OCR、音频转写和工具结果都可能包含提示注入。它们进入消息时应被标记为数据，不能覆盖系统和工具策略。Provider 层的包裹是纵深防御，不能替代引擎执行边界的权限检查。

## JSON 生成任务

技能生成等内部能力会要求模型输出结构化 JSON。解析可以容忍代码围栏、常见尾逗号或兼容信封，但不能把无法验证的字段直接用于路径、命令或权限决策。解析失败应保留有限、脱敏的诊断信息，并向用户给出可操作错误。

## 修改检查

Provider 相关改动重点覆盖：三种协议的普通回复、thinking、单/多工具调用、参数跨 chunk、usage、取消、停滞、HTTP 分类、空响应和消息配对。`ProviderCompatibilityTests` 以端点/模型矩阵覆盖请求字段、全部生成入口、组合参数拒绝、工具往返、快照和确认边界，并与既有协议和 Schema 回归共同验证。测试使用确定性事件样本，不依赖真实网络服务。


## 网络资源生命周期

`CloudProvider` 释放时关闭自身创建的 `URLSession`；测试或宿主注入的 session 由调用者管理。旧式 `stream(prompt:)` 在响应校验失败、协议结束、读取失败和消费取消时均关闭实际网络任务。并发闸门由生产任务退出后释放，消费取消不提前腾出仍在使用的名额。SSE 单行解析在开始读取及长行的有界间隔检查取消，保留总字节和事件字节上限。
