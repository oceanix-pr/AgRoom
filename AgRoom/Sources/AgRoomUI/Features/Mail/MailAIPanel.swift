import SwiftUI
import AgRoomCore

// MARK: - Mail AI Panel

/// 撰写窗口内的 AI 面板：要求输入、模型与输出选项、上下文状态、流式候选与结果操作。
///
/// 面板只负责展示与触发，全部状态与任务都由 `MailComposeViewModel` 持有——因此缩放、
/// 折叠面板或切换语言都不会中断生成或丢失候选。
struct MailAIPanel: View {
    @Bindable var viewModel: MailComposeViewModel

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(16)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        requirementSection
                        optionsSection
                        contextSection
                        generateButton
                        Divider()
                        candidateSection(height: min(380, max(140, geometry.size.height - 510)))
                    }
                    .padding(16)
                }
                Divider()
                actionBar
                    .padding(16)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Label(L.string("mail.ai.title"), systemImage: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .lineLimit(1)
            Spacer(minLength: 0)
            Picker("", selection: $viewModel.aiMode) {
                Text(L.string("mail.ai.mode.generate")).tag(MailAIPanelMode.generate)
                Text(L.string("mail.ai.mode.polish")).tag(MailAIPanelMode.polish)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 148)
            .disabled(viewModel.isGeneratingAI)
            .accessibilityLabel(L.string("mail.ai.title"))
        }
    }

    // MARK: - Requirement

    private var requirementSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L.string(requirementLabelKey))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextEditor(text: $viewModel.aiRequirement)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 88)
                .meetCard()
                .accessibilityLabel(L.string(requirementLabelKey))
        }
    }

    private var requirementLabelKey: String {
        switch viewModel.activeAIKind {
        case .compose: return "mail.ai.requirement.compose"
        case .reply: return "mail.ai.requirement.reply"
        case .polish: return "mail.ai.requirement.polish"
        }
    }

    // MARK: - Options

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(L.string("mail.ai.model"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Menu {
                    if viewModel.availableProviders.isEmpty {
                        Text(L.string("mail.ai.error.noProvider"))
                    }
                    ForEach(viewModel.availableProviders) { provider in
                        Button(provider.model.isEmpty ? provider.name : provider.model) {
                            viewModel.selectProvider(provider.id)
                        }
                    }
                } label: {
                    Text(viewModel.aiModelLabel.isEmpty ? L.string("mail.ai.model.none") : viewModel.aiModelLabel)
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .disabled(viewModel.isGeneratingAI)
                Spacer(minLength: 0)
            }

            HStack(alignment: .top, spacing: 12) {
                optionMenu(L.string("mail.ai.language"), selection: $viewModel.aiLanguage, options: [
                    (.auto, L.string("mail.ai.option.auto")),
                    (.simplifiedChinese, L.string("mail.ai.lang.zhHans")),
                    (.traditionalChinese, L.string("mail.ai.lang.zhHant")),
                    (.english, L.string("mail.ai.lang.en")),
                    (.spanish, "Español"),
                    (.french, "Français"),
                    (.arabic, "العربية"),
                    (.russian, "Русский")
                ])
                optionMenu(L.string("mail.ai.tone"), selection: $viewModel.aiTone, options: [
                    (.auto, L.string("mail.ai.option.auto")),
                    (.formal, L.string("mail.ai.tone.formal")),
                    (.friendly, L.string("mail.ai.tone.friendly")),
                    (.concise, L.string("mail.ai.tone.concise"))
                ])
                optionMenu(L.string("mail.ai.length"), selection: $viewModel.aiLength, options: [
                    (.auto, L.string("mail.ai.option.auto")),
                    (.short, L.string("mail.ai.length.short")),
                    (.medium, L.string("mail.ai.length.medium")),
                    (.long, L.string("mail.ai.length.long"))
                ])
            }

            if viewModel.composeKind.hasSource {
                Toggle(L.string("mail.ai.includeThread"), isOn: $viewModel.includeThread)
                    .font(.system(size: 11))
                    .toggleStyle(.checkbox)
            }
        }
    }

    /// 泛型选项菜单：`MailAILanguage` / `MailAITone` / `MailAILength` 共用。
    private func optionMenu<Value: Hashable>(
        _ title: String,
        selection: Binding<Value>,
        options: [(Value, String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Menu {
                ForEach(options.indices, id: \.self) { index in
                    Button(options[index].1) { selection.wrappedValue = options[index].0 }
                }
            } label: {
                Text(options.first { $0.0 == selection.wrappedValue }?.1 ?? "")
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel(title)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Context

    @ViewBuilder
    private var contextSection: some View {
        if viewModel.composeKind.hasSource {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(contextText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if case .failed = viewModel.sourceStatus {
                        Button(L.string("mail.ai.context.retry")) {
                            Task { await viewModel.retrySource() }
                        }
                        .font(.system(size: 11))
                    }
                }
                if let original = viewModel.sourceContext, original.isTruncated {
                    Text(L.string("mail.ai.context.truncated"))
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var contextText: String {
        switch viewModel.sourceStatus {
        case .none: return L.string("mail.ai.context.idle")
        case .loading: return L.string("mail.ai.context.loading")
        case .ready:
            guard let original = viewModel.sourceContext else { return L.string("mail.ai.context.ready") }
            let subject = original.subject.isEmpty ? L.string("mail.noSubject") : original.subject
            if original.attachments.isEmpty {
                return L.format("mail.ai.context.ready", original.from, subject)
            }
            return L.format(
                "mail.ai.context.readyWithAttachments",
                original.from,
                subject,
                original.attachments.count
            )
        case .failed(let message): return message
        }
    }

    // MARK: - Candidate

    @ViewBuilder
    private func candidateSection(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(L.string("mail.ai.candidate"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let state = stateLabel {
                    Text(state)
                        .font(.system(size: 10))
                        .foregroundStyle(stateColor)
                }
            }
            if case .failed(let message) = viewModel.aiState {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if viewModel.aiMode == .generate,
               viewModel.composeKind == .new,
               let suggestion = viewModel.aiSubjectSuggestion,
               !suggestion.isEmpty {
                HStack(spacing: 6) {
                    Text(L.format("mail.ai.subject.suggestion", suggestion))
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Button(L.string("mail.ai.subject.apply")) { viewModel.applyAISubject() }
                        .font(.system(size: 11))
                    Spacer(minLength: 0)
                }
            }
            if viewModel.candidate.body.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "text.badge.plus")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(L.string("mail.ai.candidate.empty"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .meetCard()
            } else {
                ScrollView {
                    Text(viewModel.candidate.body)
                        .font(.system(size: 13))
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(height: height)
                .meetCard()
            }
        }
    }

    private var stateLabel: String? {
        switch viewModel.aiState {
        case .idle: return nil
        case .preparing: return L.string("mail.ai.state.preparing")
        case .generating: return L.string("mail.ai.state.generating")
        case .done: return L.string("mail.ai.state.done")
        case .stopped: return L.string("mail.ai.state.stopped")
        case .failed: return nil
        }
    }

    private var stateColor: Color {
        switch viewModel.aiState {
        case .failed: return .red
        case .stopped: return .orange
        default: return .secondary
        }
    }

    // MARK: - Actions

    private var generateButton: some View {
        Group {
            if viewModel.isGeneratingAI {
                Button { viewModel.stopAI() } label: {
                    Label(L.string("mail.ai.stop"), systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
            } else {
                Button {
                    Task { await viewModel.generateAI() }
                } label: {
                    Label(L.string(viewModel.aiRaw.isEmpty ? "mail.ai.generate" : "mail.ai.regenerate"),
                          systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!canGenerate)
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { viewModel.applyAIBody(replace: true) } label: {
                Label(L.string("mail.ai.apply.replace"), systemImage: "arrow.left.to.line")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!viewModel.canApplyAI || viewModel.isGeneratingAI)

            HStack(spacing: 12) {
                Button(L.string("mail.ai.apply.insert")) { viewModel.applyAIBody(replace: false) }
                    .disabled(!viewModel.canApplyAI || viewModel.isGeneratingAI)
                Spacer(minLength: 0)
                if viewModel.undoBodySnapshot != nil {
                    Button(L.string("mail.ai.undo")) { viewModel.undoAIApply() }
                        .disabled(viewModel.isBusy || viewModel.isSendLocked)
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
            .fixedSize(horizontal: false, vertical: true)

            Text(L.string("mail.ai.privacy"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var canGenerate: Bool {
        guard !viewModel.aiRequirement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !viewModel.isSendLocked,
              !viewModel.isBusy else { return false }
        if viewModel.activeAIKind == .polish {
            return !viewModel.bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }
}
