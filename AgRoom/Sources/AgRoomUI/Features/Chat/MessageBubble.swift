import SwiftUI
import AgRoomCore

// MARK: - Thought Section

/// 思维链区块：工具循环各轮中间叙述的可收起展示。
/// 展开/收起三态：nil = 默认折叠（不跟随流式状态），用户手动切换后固定
struct ThoughtSection: View {
    let text: String
    let isStreaming: Bool
    /// nil = 默认折叠；true/false = 用户手动固定
    @State private var expanded: Bool?

    private var isExpanded: Bool {
        expanded ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { expanded = !isExpanded }) {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Label(L.string("chat.thoughts"), systemImage: "brain.head.profile")
                        .font(MeetTypography.secondary)
                    if isStreaming {
                        // 正在思考：闪烁指示
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
                .foregroundColor(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L.string("chat.thoughts.hint"))

            if isExpanded {
                // 展开区高度封顶（固定上限 300pt）：超长思考过程在区块内滚动查看，
                // 不再无限撑长对话区
                ScrollView(.vertical) {
                    Text(text)
                        .readingBodyFont()
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)
                .background(Color.secondary.opacity(0.07))
                .cornerRadius(8)
                .overlay(
                    // 浅描边区分思考区块与正式回答
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
                )
            }
        }
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: ChatMessage
    let space: AppSpace
    var isRunning: Bool = false
    /// 流式输出使用同一 Markdown 解析链路，后台解析完整累计快照
    var isStreaming: Bool = false
    /// 本轮测速：流式中为实时速率，本轮结束后为本轮加权平均（无有效流式区间时为空）
    var generationRate: (rate: TokenGenerationRate, isAverage: Bool)? = nil
    var markdownContext = MarkdownSourceContext()
    /// 会话内搜索命中：气泡黄色描边高亮
    var isSearchHit: Bool = false
    /// 引擎运行中（禁用重试/编辑等操作）
    var isBusy: Bool = false
    /// 问句显示覆盖：显示激活版本对应的问句原文（编辑重发场景各版本问句不同）
    var questionOverride: String? = nil
    /// 技能 alias 查找闭包（ChatView 注入 viewModel 查询）：参与方徽章 alias 优先显示
    var skillAliasProvider: ((String) -> String?)? = nil
    /// 智体显示名查找闭包（ChatView 注入 viewModel 查询）：参与方徽章显示昵称
    var agentDisplayNameProvider: ((String) -> String?)? = nil
    /// 打开轨迹面板：携带消息 ID 与该版本工具轨迹（纯文本轮次轨迹为空，仅展示参考内容）
    var onOpenTrace: ((UUID, [DispatcherTraceEntry]) -> Void)? = nil
    var onRetryAnswer: ((UUID) -> Void)? = nil
    var onResendEdited: ((UUID, String) -> Void)? = nil
    /// 切换回答版本（‹ 1/2 ›）
    var onSwitchVariation: ((UUID, Int) -> Void)? = nil
    @AppStorage(ReadingTypography.preferenceKey) private var readingPointSize = ReadingTypography.defaultSize

    private var typography: ReadingTypography { ReadingTypography(pointSize: readingPointSize) }

    /// 问句气泡实际显示文本（覆盖优先，与复制行为一致）
    private var displayedQuestion: String {
        questionOverride ?? message.content
    }

    /// 图片浏览器当前展示的附件
    @State private var viewingAttachment: ChatAttachment?
    /// 参与方（智体/技能）超过 3 个时的「+N」浮窗
    @State private var showingAllParties = false
    /// 问句编辑模式（编辑后重试）
    @State private var isEditing = false
    @State private var editText = ""

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: MeetSpacing.xs) {
                contentBubble
                if message.role == .assistant, let completion = message.completion,
                   [.codeUnverified, .codeRevisionChanged, .codeVerificationFailed, .codeChecksPassed].contains(completion.code) {
                    Label(ChatViewModel.localizedCompletionReason(completion),
                        systemImage: completion.code == .codeChecksPassed ? "checkmark.seal" : "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(completion.code == .codeChecksPassed ? Color.green : Color.orange)
                }
                if !isEditing {
                    involvedPartiesRow
                    actionBar
                }
            }

            if message.role != .user { Spacer(minLength: 60) }
        }
        .sheet(item: $viewingAttachment) { attachment in
            ImageViewerSheet(attachment: attachment)
        }
        // 悬停显示消息时间戳（格式化结果按消息缓存，body 重算不再重复格式化）
        .help(Self.cachedTimestamp(message.id, message.timestamp))
    }

    /// 时间戳格式化缓存（主线程访问）：key = 消息 id
    private static nonisolated(unsafe) var timestampCache: [UUID: (Date, String)] = [:]

    @MainActor private static func cachedTimestamp(_ id: UUID, _ date: Date) -> String {
        if let cached = timestampCache[id], cached.0 == date {
            return cached.1
        }
        let text = AppDate.string(from: date)
        if timestampCache.count > 512 { timestampCache.removeAll() }
        timestampCache[id] = (date, text)
        return text
    }

    // MARK: - Content

    /// 是否渲染气泡主体：无输出内容时不画空白气泡（如中止后只有思考、没有回答的轮次）。
    /// 思维链区块独立于气泡主体，照常显示
    private var shouldShowBubble: Bool {
        // 调度中占位（旋转指示器）需要气泡
        if isRunning && message.content.isEmpty { return true }
        if message.role == .user {
            return !displayedQuestion.isEmpty || !(message.attachments ?? []).isEmpty
        }
        return !message.content.isEmpty || !(message.attachments ?? []).isEmpty
    }

    @ViewBuilder
    private var contentBubble: some View {
        if isEditing {
            editEditor
        } else {
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: MeetSpacing.sm) {
                // 模型返回的推理文本与工具轮叙述可展开；没有文本时不显示空区块。
                if let thoughts = message.thoughts, !thoughts.isEmpty {
                    ThoughtSection(text: thoughts, isStreaming: isStreaming)
                }
                if shouldShowBubble {
                    if message.role == .user {
                        userContent
                    } else {
                        bubbleSurface {
                            if message.content.isEmpty && isRunning {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text(L.format("chat.dispatching", L.dispatcherName()))
                                        .font(MeetTypography.secondary)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 2)
                            } else if message.role == .assistant {
                                // 同一个视图身份贯穿流式与终态，保留文档上下文和测量缓存。
                                MarkdownView(text: message.content, streaming: isStreaming, documentID: message.id.uuidString, sourceContext: markdownContext)
                                if let attachments = message.attachments, !attachments.isEmpty {
                                    attachmentRow(attachments)
                                }
                            } else {
                                if !displayedQuestion.isEmpty {
                                    Text(displayedQuestion)
                                        .font(.system(size: typography.bodySize))
                                }
                                if let attachments = message.attachments, !attachments.isEmpty {
                                    attachmentRow(attachments)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// 用户消息按图片、文字、普通文件排列；图片独立于文字气泡，整组靠右对齐。
    private var userContent: some View {
        let attachments = message.attachments ?? []
        let images = attachments.filter(\.isImage)
        let files = attachments.filter { !$0.isImage }
        let imageRowMaxWidth: CGFloat = images.count == 1
            ? 160
            : CGFloat(images.count) * 108 + CGFloat(images.count - 1) * MeetSpacing.sm
        return VStack(alignment: .trailing, spacing: MeetSpacing.sm) {
            if !images.isEmpty {
                imageAttachmentRow(images)
                    // 宫格宽度不超过实际图片所需宽度，避免少量图片占满一行后偏左。
                    .frame(maxWidth: imageRowMaxWidth, alignment: .trailing)
                    .overlay(searchHighlight)
            }
            if !displayedQuestion.isEmpty {
                bubbleSurface {
                    Text(displayedQuestion)
                        .font(.system(size: typography.bodySize))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !files.isEmpty {
                bubbleSurface {
                    fileAttachmentRow(files)
                }
            }
        }
    }

    private func bubbleSurface<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            // 用户问句和附件名开启选取；助手正文沿用原生富文本的选取能力。
            .textSelection(.enabled)
            .padding(10)
            .background(background)
            .cornerRadius(MeetRadius.message)
            .overlay(searchHighlight)
            .foregroundColor(message.role == .error ? .red : .primary)
    }

    private var searchHighlight: some View {
        RoundedRectangle(cornerRadius: MeetRadius.message)
            .stroke(Color.yellow.opacity(isSearchHit ? 0.9 : 0), lineWidth: 2)
    }

    // MARK: - Involved Parties（智体/技能调用徽章）

    /// 参与方类型：委派的智体 / 加载的技能
    @MainActor enum InvolvedParty: Hashable {
        /// 智体工具名（保留子代理内层工具后缀，如 agent_x > skill_load）
        case agent(toolName: String)
        case skill(name: String)
    }

    /// 参与方显示名：技能 alias 优先（无 alias 回退技术名）；智体昵称优先（无昵称回退名称）
    private func partyDisplayText(_ party: InvolvedParty) -> String {
        switch party {
        case .agent(let toolName):
            return L.format(
                "chat.trace.agent_format",
                ChatView.agentDisplayText(toolName, displayName: agentDisplayNameProvider)
            )
        case .skill(let name):
            if let alias = skillAliasProvider?(name), !alias.isEmpty {
                return L.format("chat.party.skill_format", alias)
            }
            return L.format("chat.party.skill_format", name.replacingOccurrences(of: "_", with: " "))
        }
    }

    /// 从轨迹提取本轮调用的智体与技能（按首次出现顺序去重；失败的调用不计）。
    /// 结果按消息 id 记忆化（trace 终态写入后不可变，条数一致即命中）：
    /// 避免每次 body 都重扫 trace + JSON 解析 skill_load 参数
    private var involvedParties: [InvolvedParty] {
        guard message.role == .assistant, let trace = message.trace else { return [] }
        if let cached = Self.partiesCache[message.id], cached.count == trace.count {
            return cached.parties
        }
        var result: [InvolvedParty] = []
        for entry in trace where entry.succeeded {
            if entry.toolName.hasPrefix("agent_") {
                let party = InvolvedParty.agent(toolName: entry.toolName)
                if !result.contains(party) { result.append(party) }
            } else if entry.toolName == "skill_load" {
                // 从完整参数（旧数据回退预览）解析 {"name": "..."}
                let args = entry.argumentsFull ?? entry.argumentsPreview
                guard let data = args.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let name = json["name"] as? String, !name.isEmpty else { continue }
                let party = InvolvedParty.skill(name: name)
                if !result.contains(party) { result.append(party) }
            }
        }
        if Self.partiesCache.count > 256 { Self.partiesCache.removeAll() }
        Self.partiesCache[message.id] = (trace.count, result)
        return result
    }

    /// 参与方缓存（主线程访问，无需加锁）：key = 消息 id，value = (trace 条数, 结果)
    private static nonisolated(unsafe) var partiesCache: [UUID: (count: Int, parties: [InvolvedParty])] = [:]

    /// 参与方徽章行：最多 3 个，超出显示「+N」按钮，点击浮窗列出全部
    @ViewBuilder
    private var involvedPartiesRow: some View {
        let parties = involvedParties
        if !parties.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "person.2.crop.square.stack")
                    .font(MeetTypography.secondary)
                    .foregroundColor(.secondary)
                ForEach(parties.prefix(3), id: \.self) { party in
                    partyChip(party)
                }
                if parties.count > 3 {
                    Button(action: { showingAllParties = true }) {
                        Text(L.format("chat.party.more", parties.count - 3))
                            .font(MeetTypography.secondary)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(HoverHighlightButtonStyle())
                    .popover(isPresented: $showingAllParties, arrowEdge: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L.string("chat.party.all"))
                                .font(.caption.bold())
                                .foregroundColor(.secondary)
                            ForEach(parties, id: \.self) { party in
                                HStack(spacing: 6) {
                                    Image(systemName: partyChipIcon(party))
                                        .font(MeetTypography.secondary)
                                        .foregroundColor(.accentColor)
                                    Text(partyDisplayText(party))
                                        .font(MeetTypography.secondary)
                                }
                            }
                        }
                        .padding(12)
                        .frame(minWidth: 160, alignment: .leading)
                    }
                }
            }
        }
    }

    private func partyChipIcon(_ party: InvolvedParty) -> String {
        switch party {
        case .agent: return "person.crop.circle"
        case .skill: return "wand.and.stars"
        }
    }

    private func partyChip(_ party: InvolvedParty) -> some View {
        HStack(spacing: 3) {
            Image(systemName: partyChipIcon(party))
                .font(MeetTypography.secondary)
            Text(partyDisplayText(party))
                .font(MeetTypography.secondary)
                .lineLimit(1)
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.primary.opacity(0.06))
        .clipShape(Capsule())
    }

    // MARK: - Action Bar

    /// 消息操作栏仅显示图标和数字，操作名称放在悬停提示与辅助功能标签中。
    /// 无输出但带思考/轨迹的轮次（中止场景）同样显示：用量、轨迹、重试均可用
    @ViewBuilder
    private var actionBar: some View {
        if !message.content.isEmpty
            || !(message.attachments ?? []).isEmpty
            || (message.role == .assistant
                && (!(message.thoughts ?? "").isEmpty || !(message.trace ?? []).isEmpty)) {
            HStack(spacing: 12) {
                if message.role == .assistant {
                    variationSwitcher
                    if let trace = message.trace, !trace.isEmpty {
                        Button(action: { onOpenTrace?(message.id, trace) }) {
                            Label("\(trace.count)", systemImage: "list.bullet.rectangle")
                        }
                        .help(L.format("chat.trace.label", trace.count))
                        .accessibilityLabel(Text(L.format("chat.trace.label", trace.count)))
                    } else if message.contextReport != nil {
                        Button(action: { onOpenTrace?(message.id, []) }) {
                            Label(L.string("chat.trace.context"), systemImage: "list.bullet.rectangle")
                        }
                        .labelStyle(.iconOnly)
                        .help(L.string("chat.trace.context"))
                    }
                    answerCopyButton
                    Button(action: { onRetryAnswer?(message.id) }) {
                        Label(L.string("chat.action.retry"), systemImage: "arrow.clockwise")
                    }
                    .labelStyle(.iconOnly)
                    .help(L.string("chat.action.retry"))
                    .disabled(isBusy)
                    // 复制、重试右侧：本轮生成速率与本轮输入/输出 Token
                    generationUsage
                } else if message.role == .user {
                    copyButton(displayedQuestion)
                    Button(action: startEditing) {
                        Label(L.string("chat.action.edit"), systemImage: "pencil")
                    }
                    .labelStyle(.iconOnly)
                    .help(L.string("chat.action.edit"))
                    .disabled(isBusy)
                } else if message.role == .error {
                    variationSwitcher
                    copyButton(message.content)
                    Button(action: { onRetryAnswer?(message.id) }) {
                        Label(L.string("chat.action.retry"), systemImage: "arrow.clockwise")
                    }
                    .labelStyle(.iconOnly)
                    .help(L.string("chat.action.retry"))
                    .disabled(isBusy)
                }
            }
            .font(MeetTypography.secondary)
            .foregroundColor(.secondary)
            .buttonStyle(HoverHighlightButtonStyle())
        }
    }

    // MARK: Generation Usage

    /// 复制、重试右侧的生成指标：流式输出期间显示实时速率，
    /// 本轮结束后显示本轮平均速率，其后跟随本轮输入/输出 Token；两项都为空时不占位。
    @ViewBuilder
    private var generationUsage: some View {
        if let rate = generationRate?.rate {
            generationRateLabel(rate, isAverage: generationRate?.isAverage ?? false)
        }
        tokenUsageLabel
    }

    /// 测速标签仅显示图标与速率；悬停提示和辅助功能名称区分实时与本轮平均。
    private func generationRateLabel(_ rate: TokenGenerationRate, isAverage: Bool) -> some View {
        let number = rate.tokensPerSecond.formatted(.number.precision(.fractionLength(1)))
        let speed = (rate.isEstimated ? "≈" : "") + number
        let description = L.format(isAverage ? "chat.generation.average" : "chat.generation.speed", speed)
        return Label(speed, systemImage: "bolt.fill")
        .monospacedDigit()
        .help(description + "\n" + L.string("chat.generation.help"))
        .accessibilityLabel(Text(description))
        .accessibilityIdentifier("chat.generation.speed")
    }

    /// 本轮输入/输出 Token；仅有总数（旧数据或提供方未返回用量拆分）时回退到总量。
    @ViewBuilder
    private var tokenUsageLabel: some View {
        if let input = message.inputTokens, let output = message.outputTokens {
            ChatTokenUsageLabel(input: input, output: output)
        } else if let tokens = message.tokenCount {
            let count = compactTokenCount(tokens)
            let description = L.format("chat.tokens", count)
            Label(count, systemImage: "number")
                .monospacedDigit()
                .help(description)
                .accessibilityLabel(Text(description))
        }
    }

    // MARK: Variation Switcher

    /// 版本切换器（‹ 1/2 ›）：重试/编辑重发产生多个版本时显示，
    /// 左右箭头切换查看不同尝试的问答
    @ViewBuilder
    private var variationSwitcher: some View {
        if let variations = message.variations, variations.count > 1 {
            let active = min(max(message.activeVariationIndex, 0), variations.count - 1)
            HStack(spacing: 2) {
                Button(action: { onSwitchVariation?(message.id, active - 1) }) {
                    Image(systemName: "chevron.left")
                }
                .disabled(active <= 0 || isBusy)
                Text("\(active + 1)/\(variations.count)")
                    .font(MeetTypography.secondary.monospaced())
                    .foregroundStyle(.secondary)
                Button(action: { onSwitchVariation?(message.id, active + 1) }) {
                    Image(systemName: "chevron.right")
                }
                .disabled(active >= variations.count - 1 || isBusy)
            }
            .help(L.string("chat.variation.hint"))
        }
    }

    private func copyButton(_ text: String) -> some View {
        Button(action: {
            copyText(text)
        }) {
            Label(L.string("common.copy"), systemImage: "doc.on.doc")
        }
        .labelStyle(.iconOnly)
        .help(L.string("common.copy"))
    }

    /// 与参考入口共用普通按钮样式，复制当前回答版本的 Markdown 原文。
    private var answerCopyButton: some View {
        copyButton(message.content)
    }

    private func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Edit Mode

    private var editEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $editText)
                .font(.system(size: typography.bodySize))
                .frame(minHeight: 60)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                )
            HStack {
                Text(L.string("chat.action.edit.hint"))
                    .font(MeetTypography.secondary)
                    .foregroundColor(.secondary)
                Spacer()
                Button(L.string("common.cancel")) {
                    isEditing = false
                }
                Button(action: submitEdit) {
                    Label(L.string("chat.action.resend"), systemImage: "arrow.up.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .frame(maxWidth: 420)
    }

    private func startEditing() {
        editText = message.content
        isEditing = true
    }

    private func submitEdit() {
        let newText = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newText.isEmpty else { return }
        isEditing = false
        onResendEdited?(message.id, newText)
    }

    // MARK: - Attachments

    /// 附件区：图片和普通文件分别布局。
    private func attachmentRow(_ attachments: [ChatAttachment]) -> some View {
        let images = attachments.filter(\.isImage)
        let others = attachments.filter { !$0.isImage }
        return VStack(alignment: .leading, spacing: MeetSpacing.sm) {
            imageAttachmentRow(images)
            if !others.isEmpty {
                fileAttachmentRow(others)
            }
        }
    }

    /// 多图沿用自适应宫格；单图保留紧凑缩略图与点击浏览入口。
    @ViewBuilder
    private func imageAttachmentRow(_ images: [ChatAttachment]) -> some View {
        if images.count >= 2 {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 108), spacing: MeetSpacing.sm,
                                   alignment: message.role == .user ? .trailing : .leading)],
                alignment: message.role == .user ? .trailing : .leading,
                spacing: MeetSpacing.sm
            ) {
                ForEach(images) { attachment in
                    imageThumb(attachment, side: 108)
                }
            }
        } else {
            ForEach(images) { attachment in
                imageThumb(attachment, side: 160)
            }
        }
    }

    private func fileAttachmentRow(_ files: [ChatAttachment]) -> some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: MeetSpacing.sm) {
            ForEach(files.filter { [.video, .audio].contains($0.mediaKind) }) { attachment in
                ConversationMediaCard(attachment: attachment)
            }
            let documents = files.filter { ![.video, .audio].contains($0.mediaKind) }
            if !documents.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: MeetSpacing.sm) {
                        ForEach(documents) { attachment in fileChip(attachment) }
                    }
                }
            }
        }
    }

    /// 图片缩略图（点击进图片浏览器）
    private func imageThumb(_ attachment: ChatAttachment, side: CGFloat) -> some View {
        Button(action: { viewingAttachment = attachment }) {
            AttachmentThumbnail(space: space, path: attachment.path, side: side)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help(attachment.name)
    }

    /// 非图片附件 chip：图标 + 文件名
    private func fileChip(_ attachment: ChatAttachment) -> some View {
        HStack(spacing: 4) {
            Image(systemName: AttachmentService.isAudio(url: URL(fileURLWithPath: attachment.path))
                ? "waveform" : "doc")
                .font(MeetTypography.secondary)
            Text(attachment.name)
                .font(MeetTypography.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.12))
        .cornerRadius(6)
    }

    private var background: Color {
        switch message.role {
        case .user: return Color.accentColor.opacity(0.15)
        case .assistant: return Color.gray.opacity(0.1)
        case .error: return Color.red.opacity(0.1)
        }
    }
}

struct ChatTokenUsageLabel: View {
    let input: Int
    let output: Int
    var isSessionTotal = false

    var body: some View {
        let inputText = compactTokenCount(input)
        let outputText = compactTokenCount(output)
        let usage = L.format("chat.tokens.io", inputText, outputText)
        HStack(spacing: 8) {
            Label(inputText, systemImage: "arrow.up")
            Label(outputText, systemImage: "arrow.down")
        }
        .monospacedDigit()
        .help(isSessionTotal ? L.string("chat.session.tokens.io.help") : usage)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(isSessionTotal ? L.string("product.usage.total") + " " + usage : usage))
    }
}

private func compactTokenCount(_ value: Int) -> String {
    if value >= 1000 {
        return String(format: "%.1fk", Double(value) / 1000)
    }
    return "\(value)"
}
