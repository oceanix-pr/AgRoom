import SwiftUI
import AgRoomCore

// MARK: - Agents View

/// 智体页：两栏布局 — 智体列表 | 详情编辑（基本信息 + 技能）。
/// 智体会被注册为调度 Agent 的可委托工具。
public struct AgentsView: View {
    let hub: Hub
    private let space: AppSpace
    private let sourceID: UUID?
    /// 工具栏搜索词：过滤智体列表（名称 + 昵称 + 描述）
    @Environment(\.globalSearchText) private var searchText

    @State private var agents: [Agent] = []
    @State private var selectedAgentID: Agent.ID?
    @State private var agentPendingDeletion: Agent?
    @State private var errorMessage: String?
    @State private var showErrorAlert = false
    /// 悬停行（列表 hover 高亮）
    @State private var hoveredAgentID: Agent.ID?
    /// 列表栏显示宽度：拖动期间只改这里，拖动结束才写偏好。
    /// 依据与崩溃栈见 `SplitColumnWidth`：布局回调里写观察态会让窗口 abort。
    @State private var listWidth: Double
    private static let listWidthKey = "agroom.agents.listWidth"

    public init(hub: Hub, sourceID: UUID? = nil) {
        self.space = hub.spaceStore.current; self.sourceID = sourceID
        self.hub = hub
        self._listWidth = State(
            initialValue: SplitColumnWidth.snapshot(
                key: Self.listWidthKey, defaultValue: 300, range: 220...480
            )
        )
    }

    public var body: some View {
        // 两栏常驻（可拖拽分隔）：智体列表 | 详情编辑（基本信息 + 技能统一在右栏）
        // 空间不足时只压缩显示，拖动结束才写偏好
        GeometryReader { geo in
            let layout = SplitWidths.resolve(
                available: Double(geo.size.width),
                dividers: 1,
                columns: [
                    SplitWidths.Column(width: listWidth, range: 220...480),
                    SplitWidths.Column(width: 0, range: 320...(.infinity), flexible: true)
                ]
            )
            HStack(spacing: 0) {
                agentList
                    .frame(width: CGFloat(layout[0]))

                SplitDivider(
                    columnWidth: $listWidth,
                    range: 220...480,
                    persistKey: Self.listWidthKey,
                    direction: 1
                )

                detailColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: sourceID) {
            await load()
            guard !Task.isCancelled, hub.spaceStore.current == space, let sourceID else { return }
            if agents.contains(where: { $0.id == sourceID }) { selectedAgentID = sourceID }
            else { errorMessage = L.errorDescription(SpaceSearchError.missing); showErrorAlert = true }
        }
        .confirmationDialog(
            L.string("chat.delete_confirm.title"),
            isPresented: Binding(
                get: { agentPendingDeletion != nil },
                set: { if !$0 { agentPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L.string("common.delete"), role: .destructive) {
                if let agent = agentPendingDeletion { delete(agent) }
                agentPendingDeletion = nil
            }
            Button(L.string("common.cancel"), role: .cancel) {}
        } message: {
            if let agent = agentPendingDeletion {
                Text(L.format("agents.delete_confirm.message", agent.name, L.dispatcherName()))
            }
        }
        .alert(L.string("common.error"), isPresented: $showErrorAlert) {
            Button(L.string("common.ok"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Selected Agent

    private var selectedAgent: Agent? {
        agents.first { $0.id == selectedAgentID }
    }

    // MARK: - Agent List (左栏：标题头 + 分隔线 + 列表)

    /// 搜索过滤后的智体（名称/昵称/描述命中，大小写不敏感）
    private var filteredAgents: [Agent] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return agents }
        return agents.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.nickname.localizedCaseInsensitiveContains(query)
                || $0.description.localizedCaseInsensitiveContains(query)
        }
    }

    private var agentList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L.string("nav.agents"))
                    .font(MeetTypography.sectionTitle)
                Spacer()
                Button(action: { createAgent() }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help(L.string("agents.add"))
            }
            .padding(.horizontal, 12)
            .columnHeader()

            Divider()

            if filteredAgents.isEmpty {
                VStack(spacing: 8) {
                    Text(L.string("agents.empty"))
                        .font(MeetTypography.control)
                    Text(L.format("agents.empty.desc", L.dispatcherName()))
                        .font(MeetTypography.secondary)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button(L.string("agents.add")) { createAgent() }
                        .buttonStyle(.borderedProminent)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(filteredAgents) { agent in
                            row(agent)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func row(_ agent: Agent) -> some View {
        let isSelected = selectedAgentID == agent.id
        let isHovered = hoveredAgentID == agent.id
        return HStack(spacing: 10) {
            Text(agent.icon)
                .font(MeetTypography.control)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(agent.displayName)
                        .font(MeetTypography.listTitle)
                        .lineLimit(1)
                        .help(agent.displayName)
                    if agent.nickname != agent.name && !agent.nickname.isEmpty {
                        Text(agent.name)
                            .font(MeetTypography.secondary)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if !agent.isEnabled {
                        StatusBadge(text: L.string("agents.disabled"), color: .secondary)
                    }
                }
                if !agent.description.isEmpty {
                    Text(agent.description)
                        .font(MeetTypography.secondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(agent.modelName.isEmpty ? L.string(agent.providerID == nil ? "agents.model.inherit" : "agents.model.provider_default") : agent.modelName)
                    .font(MeetTypography.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(role: .destructive, action: { agentPendingDeletion = agent }) {
                Image(systemName: "trash")
                    .frame(width: MeetLayout.rowActionSize, height: MeetLayout.rowActionSize)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(isHovered || isSelected ? 1 : 0.55)
            .help(L.string("common.delete"))
        }
        .padding(.vertical, MeetSpacing.sm)
        .padding(.horizontal, MeetSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(0.12)
                        : (isHovered ? Color.primary.opacity(0.05) : Color.clear)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedAgentID = agent.id
        }
        .onHover { hovering in
            hoveredAgentID = hovering ? agent.id : nil
        }
        .contextMenu {
            Button(action: { selectedAgentID = agent.id }) {
                Label(L.string("common.open"), systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive, action: { agentPendingDeletion = agent }) {
                Label(L.string("common.delete"), systemImage: "trash")
            }
        }
    }

    // MARK: - Detail Column (右栏：基本信息 + 技能 统一编辑)

    @ViewBuilder
    private var detailColumn: some View {
        if let agent = selectedAgent {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(agent.icon)
                        .font(MeetTypography.control)
                    Text(agent.displayName)
                        .font(MeetTypography.sectionTitle)
                        .lineLimit(1)
                    Spacer()
                    if !agent.isEnabled {
                        StatusBadge(text: L.string("agents.disabled"), color: .secondary)
                    }
                }
                .padding(.horizontal, 12)
                .columnHeader()

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        AgentInfoEditor(agent: agent, hub: hub, space: space) { updated in
                            save(updated)
                        }
                        .id(agent.id)

                        Divider()

                        AgentSkillsEditor(hub: hub, agent: agent, space: space) { updated in
                            save(updated)
                        }
                        .id(agent.id)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        } else {
            ContentUnavailableView {
                Label(L.string("agents.empty"), systemImage: "person.2")
            } description: {
                Text(L.format("agents.empty.desc", L.dispatcherName()))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Actions

    private func load() async {
        guard let service = hub.makeAgentService(for: space) else {
            errorMessage = L.string("error.database")
            showErrorAlert = true
            return
        }
        do {
            let loaded = try await service.getAll()
            guard !Task.isCancelled, hub.spaceStore.current == space else { return }
            agents = loaded
            // 选中项被外部删除时回落到首个智体
            if selectedAgentID == nil || !agents.contains(where: { $0.id == selectedAgentID }) {
                selectedAgentID = agents.first?.id
            }
        } catch {
            errorMessage = L.actionableError(error, fallbackKey: "error.actionable.agents_load")
            showErrorAlert = true
        }
    }

    /// 新建智体：立即落库（默认名），选中后右栏直接编辑
    private func createAgent() {
        let agent = Agent(name: uniqueDefaultName())
        Task {
            do {
                try await hub.makeAgentService(for: space)?.save(agent)
                await load()
                selectedAgentID = agent.id
            } catch {
                errorMessage = L.actionableError(error, fallbackKey: "error.actionable.agents_change")
                showErrorAlert = true
            }
        }
    }

    /// 默认名去重：新智体 / 新智体 2 / 新智体 3 …
    private func uniqueDefaultName() -> String {
        let base = L.string("agents.default_name")
        guard agents.contains(where: { $0.name == base }) else { return base }
        var index = 2
        while agents.contains(where: { $0.name == "\(base) \(index)" }) {
            index += 1
        }
        return "\(base) \(index)"
    }

    private func save(_ agent: Agent) {
        Task {
            do {
                try await hub.makeAgentService(for: space)?.save(agent)
                await load()
            } catch {
                errorMessage = L.actionableError(error, fallbackKey: "error.actionable.agents_change")
                showErrorAlert = true
            }
        }
    }

    private func delete(_ agent: Agent) {
        Task {
            do {
                try await hub.makeAgentService(for: space)?.delete(id: agent.id)
                if selectedAgentID == agent.id { selectedAgentID = nil }
                await load()
            } catch {
                errorMessage = L.actionableError(error, fallbackKey: "error.actionable.agents_change")
                showErrorAlert = true
            }
        }
    }
}

// MARK: - Agent Info Editor (右栏 · 基本信息)

/// 基本信息编辑：名称（必填）、昵称（选填）、描述（必填）、简介（必填）、图标，
/// 另含模型覆盖 / 知识库开关 / 启用开关
struct AgentInfoEditor: View {
    let agent: Agent
    let hub: Hub
    let space: AppSpace
    let onSave: (Agent) -> Void

    @State private var name = ""
    @State private var nickname = ""
    @State private var icon = "🤖"
    @State private var description = ""
    @State private var intro = ""
    @State private var personality = ""
    @State private var speakingStyle = ""
    @State private var modelName = ""
    @State private var providerID = ""
    @State private var providers: [LLMProviderConfig] = []
    @State private var providerLoadFailed = false
    @AppStorage("agroom.chat.providerId") private var inheritedProviderID = ""
    @State private var knowledgeEnabled = true
    @State private var isEnabled = true

    // AI 人设生成：一句话需求 → 六字段草稿填充表单（用户审阅后手动保存）
    @State private var aiRequirement = ""
    @State private var isGeneratingPersona = false
    @State private var personaText = ""
    @State private var personaError: String?
    @State private var showPersonaError = false

    /// 图标下拉目录：按主题分类的常用 emoji（覆盖智体典型场景：助手/效率/知识/生活/情感等）
    static let emojiCatalog: [(category: String, emojis: [String])] = [
        ("助手", ["🤖", "🦾", "🧠", "👾", "🎧", "🗣️", "💬", "🔮"]),
        ("表情", ["😀", "😃", "😄", "😁", "🙂", "😊", "😍", "🤩", "😎", "🤓", "🧐", "🤔", "🤗", "🤭", "😴", "🥳", "😇", "🤠", "😌", "🙃"]),
        ("手势", ["👍", "👎", "👏", "🙌", "🤝", "✌️", "🤞", "👉", "💪", "🙏", "🫡", "🫶"]),
        ("爱心", ["❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "💖", "💕", "❣️", "💝"]),
        ("动物", ["🐶", "🐱", "🐭", "🐹", "🐰", "🦊", "🐻", "🐼", "🐨", "🐯", "🦁", "🐮", "🐷", "🐸", "🐵", "🐔", "🐧", "🦄", "🐝", "🦋", "🐢", "🐙", "🦈", "🐬", "🐳"]),
        ("植物", ["🌱", "🌿", "🍀", "🌳", "🌸", "🌺", "🌻", "🌹", "🌵", "🍁"]),
        ("食物", ["🍎", "🍐", "🍊", "🍋", "🍌", "🍉", "🍇", "🍓", "🫐", "🍒", "🥑", "🌽", "🥕", "🍞", "🧀", "🍗", "🍜", "🍣", "🍩", "🍰", "☕", "🍵", "🧋", "🍺"]),
        ("活动", ["⚽", "🏀", "🏈", "⚾", "🎾", "🏐", "🏓", "🏸", "🥊", "🎯", "🎮", "🎲", "🎸", "🎹", "🎻", "🎨", "🎤", "🎧", "🏆", "🥇"]),
        ("旅行", ["🚗", "🚕", "🚌", "🚲", "✈️", "🚀", "⛵", "🚂", "🗺️", "🧭", "🏔️", "🌋", "🏖️", "🏕️"]),
        ("物品", ["⌚", "📱", "💻", "🖥️", "⌨️", "🖨️", "📷", "🎥", "📞", "🔋", "💡", "🔦", "🕯️", "🧲", "🔬", "🔭", "📡", "💊", "🔧", "🔨", "⚙️", "🧰", "🧲"]),
        ("符号", ["✅", "❌", "❓", "❗", "⭐", "🌟", "✨", "⚡", "🔥", "💧", "🌈", "☀️", "🌙", "⛅", "❄️", "🎉", "🎊", "🎁", "🏆", "🔒", "🔑", "♻️", "☮️"]),
        ("办公", ["📝", "📖", "📚", "📰", "🗂️", "📁", "📂", "📅", "📆", "📇", "📋", "📌", "📎", "🖇️", "✂️", "📏", "📐", "🔖", "🏷️", "💰", "💳", "🧾", "📊", "📈", "📉"])
    ]

    /// 必填校验：名称 / 描述 / 简介
    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !description.trimmingCharacters(in: .whitespaces).isEmpty
            && !intro.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L.string("agents.form.info"))
                    .font(MeetTypography.sectionTitle)
                Spacer()
                Button(L.string("common.save")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }

            aiPersonaSection
            fieldHelp("agents.role.help")

            fieldLabel("agents.form.name", required: true)
            TextField(L.string("agents.form.name"), text: $name)
                .textFieldStyle(.roundedBorder)

            fieldLabel("agents.form.nickname")
            TextField(L.string("agents.form.nickname.placeholder"), text: $nickname)
                .textFieldStyle(.roundedBorder)
            fieldHelp("agents.form.nickname.help")

            fieldLabel("agents.form.description", required: true)
            TextField(L.string("agents.form.description"), text: $description, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
            fieldHelpText(L.format("agents.form.description.help", L.dispatcherName()))

            fieldLabel("agents.form.intro", required: true)
            TextEditor(text: $intro)
                .font(MeetTypography.listTitle)
                .frame(minHeight: 140)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
            fieldHelp("agents.form.intro.help")

            // 人设：性格 + 说话风格（选填；设置后每次回答带贴合性格的「XX来帮您」开场）
            fieldLabel("agents.form.personality")
            Picker(selection: $personality) {
                Text(L.string("agents.form.personality.none")).tag("")
                ForEach(Agent.personalities, id: \.self) { option in
                    Text(option).tag(option)
                }
            } label: { EmptyView() }
            .pickerStyle(.menu)

            fieldLabel("agents.form.speakingStyle")
            Picker(selection: $speakingStyle) {
                Text(L.string("agents.form.personality.none")).tag("")
                ForEach(Agent.speakingStyles, id: \.self) { option in
                    Text(option).tag(option)
                }
            } label: { EmptyView() }
            .pickerStyle(.menu)
            fieldHelp("agents.form.persona.help")

            fieldLabel("agents.form.icon")
            // 图标只可下拉选择（不可自由输入）：分类 emoji 目录 + 当前值兜底（旧数据可能不在目录内）
            Picker(selection: $icon) {
                if !icon.isEmpty && !Self.emojiCatalog.flatMap(\.emojis).contains(icon) {
                    Text(icon).tag(icon)
                }
                ForEach(Self.emojiCatalog, id: \.category) { group in
                    Section(group.category) {
                        ForEach(group.emojis, id: \.self) { emoji in
                            Text(emoji).tag(emoji)
                        }
                    }
                }
            } label: { EmptyView() }
            .pickerStyle(.menu)
            .frame(width: 120)

            Divider()

            fieldLabel("agents.form.provider")
            Picker(L.string("agents.form.provider"), selection: Binding(get: { providerID }, set: { providerID = $0; modelName = "" })) {
                Text(L.string("agents.model.inherit")).tag("")
                if !providerID.isEmpty, !providers.contains(where: { $0.id.uuidString == providerID }) {
                    Text(L.string("agents.model.unavailable")).tag(providerID)
                }
                ForEach(providers) { provider in
                    Text(provider.name + " · " + provider.model + (provider.isEnabled ? "" : " · " + L.string("agents.disabled")))
                        .tag(provider.id.uuidString).disabled(!provider.isEnabled)
                }
            }
            .labelsHidden()
            if providerLoadFailed || (!providerID.isEmpty && !providers.contains(where: { $0.id.uuidString == providerID && $0.isEnabled })) {
                Text(L.string("agents.model.unavailable.help")).font(MeetTypography.secondary).foregroundStyle(.orange)
            }
            fieldLabel("agents.form.model")
            HStack {
                TextField(L.string("agents.form.model.placeholder"), text: $modelName)
                    .textFieldStyle(.roundedBorder)
                Menu(L.string("agents.model.choose")) {
                    Button(L.string("agents.model.provider_default")) { modelName = "" }
                    ForEach(modelSuggestions, id: \.self) { model in Button(model) { modelName = model } }
                }
            }
            fieldHelp("agents.form.model.help")

            Toggle(L.string("agents.form.knowledge"), isOn: $knowledgeEnabled)
                .help(L.string("agents.form.knowledge.help"))

            Toggle(L.string("common.enabled"), isOn: $isEnabled)
        }
        .onAppear {
            name = agent.name
            nickname = agent.nickname
            icon = agent.icon
            description = agent.description
            intro = agent.systemPrompt
            personality = agent.personality
            speakingStyle = agent.speakingStyle
            modelName = agent.modelName
            providerID = agent.providerID?.uuidString ?? ""
            knowledgeEnabled = agent.knowledgeEnabled
            isEnabled = agent.isEnabled
        }
        .task {
            do { providers = try await hub.providerService?.getAll() ?? []; providerLoadFailed = false }
            catch { providerLoadFailed = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: ProviderConfigService.configurationDidChange)) { _ in
            Task {
                do { providers = try await hub.providerService?.getAll() ?? []; providerLoadFailed = false }
                catch { providerLoadFailed = true }
            }
        }
    }

    private var modelSuggestions: [String] {
        let enabled = providers.filter(\.isEnabled)
        let selected = providerID.isEmpty
            ? (enabled.first { $0.id.uuidString == inheritedProviderID } ?? enabled.first)
            : enabled.first { $0.id.uuidString == providerID }
        guard let selected else { return [] }
        return Array(Set(enabled.filter { $0.endpoint == selected.endpoint }
            .map(\.model).filter { !$0.isEmpty })).sorted()
    }

    // MARK: - AI Persona Generation（人设一键生成）

    /// AI 人设生成区：一句话需求 → 六字段草稿填充下方表单（不直接保存，用户审阅后手动保存）
    private var aiPersonaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField(L.string("agents.form.ai.placeholder"), text: $aiRequirement, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...2)
                    .onSubmit { startAIGeneration() }
                    .disabled(isGeneratingPersona)
                Button {
                    startAIGeneration()
                } label: {
                    if isGeneratingPersona {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(L.string("agents.form.ai.generate"), systemImage: "sparkles")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isGeneratingPersona || aiRequirement.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !personaText.isEmpty {
                ScrollView {
                    Text(personaText)
                        .font(MeetTypography.secondary.monospaced())
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                }
                .frame(maxHeight: 120)
                .background(Color.secondary.opacity(0.06))
                .cornerRadius(6)
            }
            fieldHelp("agents.form.ai.help")
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
        .alert(L.string("common.error"), isPresented: $showPersonaError) {
            Button(L.string("common.ok"), role: .cancel) {}
        } message: {
            Text(personaError ?? "")
        }
    }

    /// 生成并填充表单字段（草稿只进表单，保存仍由用户确认）
    private func startAIGeneration() {
        let requirement = aiRequirement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requirement.isEmpty, !isGeneratingPersona else { return }
        isGeneratingPersona = true
        personaText = ""
        Task { @MainActor in
            do {
                guard let provider = try await hub.makeActiveProvider(for: space, source: "agent-design") else {
                    throw LLMError.providerUnavailable
                }
                let draft = try await AgentGenerator(provider: provider).generate(requirement: requirement) { delta in
                    Task { @MainActor in personaText += delta }
                }
                // 填充表单（草稿可继续手改；性格/风格未命中枚举时保持"未设置"）
                name = draft.name
                nickname = draft.nickname
                icon = draft.icon
                personality = draft.personality
                speakingStyle = draft.speakingStyle
                description = String(draft.systemPrompt.prefix(200))
                intro = draft.systemPrompt
            } catch {
                personaError = L.actionableError(error, fallbackKey: "error.actionable.agents_generate")
                showPersonaError = true
            }
            isGeneratingPersona = false
        }
    }

    // MARK: - Field Helpers

    private func fieldLabel(_ key: String, required: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(L.string(key))
                .font(MeetTypography.control)
                .fontWeight(.medium)
            if required {
                Text(L.string("agents.required"))
                    .font(MeetTypography.secondary)
                    .foregroundStyle(MeetStatusColor.negative)
            }
        }
    }

    private func fieldHelp(_ key: String) -> some View {
        fieldHelpText(L.string(key))
    }

    private func fieldHelpText(_ text: String) -> some View {
        Text(text)
            .font(MeetTypography.secondary)
            .foregroundStyle(.tertiary)
    }

    private func save() {
        guard isValid else { return }
        var updated = agent
        updated.name = name.trimmingCharacters(in: .whitespaces)
        updated.nickname = nickname.trimmingCharacters(in: .whitespaces)
        updated.icon = icon.isEmpty ? "🤖" : icon
        updated.description = description
        updated.systemPrompt = intro
        updated.personality = personality
        updated.speakingStyle = speakingStyle
        updated.modelName = modelName.trimmingCharacters(in: .whitespaces)
        updated.providerID = UUID(uuidString: providerID)
        updated.knowledgeEnabled = knowledgeEnabled
        updated.isEnabled = isEnabled
        updated.updatedAt = Date()
        onSave(updated)
    }
}

// MARK: - Agent Skills Editor (右栏 · 技能)

/// 技能挂载编辑：勾选技能库中的技能挂载给智体。
/// 不勾选任何技能 = 全部已启用技能可用；勾选后仅所勾选技能对智体开放。
/// 勾选变更即时保存。
struct AgentSkillsEditor: View {
    let hub: Hub
    let agent: Agent
    let space: AppSpace
    let onSave: (Agent) -> Void

    @State private var skills: [Skill] = []
    @State private var mounted: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L.string("agents.tab.skills"))
                    .font(MeetTypography.sectionTitle)
                Spacer()
                Text(mounted.isEmpty
                    ? L.string("agents.skills.all_available")
                    : L.format("agents.skills.mounted_count", mounted.count))
                    .font(MeetTypography.secondary)
                    .foregroundStyle(.tertiary)
            }

            Text(L.string("agents.skills.hint"))
                .font(MeetTypography.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if skills.isEmpty {
                Text(L.string("agents.skills.empty"))
                    .font(MeetTypography.control)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 2) {
                    ForEach(skills) { skill in
                        skillRow(skill)
                    }
                }
            }
        }
        .onAppear {
            if let store = hub.makeSkillStore(for: space) {
                skills = (try? store.list()) ?? []
            }
            mounted = Set(agent.skillNames)
        }
    }

    private func skillRow(_ skill: Skill) -> some View {
        let isMounted = mounted.contains(skill.name)
        return HStack(spacing: 10) {
            Image(systemName: isMounted ? "checkmark.circle.fill" : "circle")
                .font(MeetTypography.control)
                .foregroundStyle(isMounted ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(skill.displayName)
                        .font(MeetTypography.control)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if !skill.isEnabled {
                        StatusBadge(text: L.string("agents.disabled"), color: .secondary)
                    }
                }
                if !skill.description.isEmpty {
                    Text(skill.description)
                        .font(MeetTypography.secondary)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isMounted ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { toggle(skill) }
    }

    /// 勾选/取消挂载：即时保存到智体
    private func toggle(_ skill: Skill) {
        var updated = agent
        if mounted.contains(skill.name) {
            mounted.remove(skill.name)
        } else {
            mounted.insert(skill.name)
        }
        updated.skillNames = skills
            .filter { mounted.contains($0.name) }
            .map(\.name)
        updated.updatedAt = Date()
        onSave(updated)
    }
}
