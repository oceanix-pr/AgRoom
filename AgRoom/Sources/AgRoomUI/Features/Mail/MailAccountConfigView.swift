import SwiftUI
import AgRoomCore

// MARK: - Mail Account Config

/// 账号配置 Sheet：新增/编辑邮箱账号（IMAP 收信 + SMTP 发信），支持「测试连接」。
/// 密码/授权码只写 Keychain；编辑时留空表示沿用已保存的密码。
struct MailAccountConfigView: View {
    let account: MailAccount?
    /// Keychain 中是否已有该账号的密码（编辑时密码留空即沿用）。
    let hasStoredPassword: Bool
    /// 连接测试（IMAP 登录 + SMTP 连通性探测）。
    let onTest: (MailAccount, String) async -> Result<MailConnectionProbe, Error>
    /// 保存；返回是否成功。
    let onSave: (MailAccount, String?) async -> Bool

    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var emailAddress = ""
    @State private var username = ""
    @State private var password = ""

    @State private var imapHost = ""
    @State private var imapPort = "993"
    @State private var imapSecurity: MailSecurity = .tls

    @State private var smtpHost = ""
    @State private var smtpPort = "587"
    @State private var smtpSecurity: MailSecurity = .startTLS

    @State private var isSaving = false
    @State private var isTesting = false
    @State private var testOutcome: TestOutcome?
    @State private var testTask: Task<Void, Never>?

    init(
        account: MailAccount?,
        hasStoredPassword: Bool,
        onTest: @escaping (MailAccount, String) async -> Result<MailConnectionProbe, Error>,
        onSave: @escaping (MailAccount, String?) async -> Bool
    ) {
        self.account = account
        self.hasStoredPassword = hasStoredPassword
        self.onTest = onTest
        self.onSave = onSave
        if let account {
            _displayName = State(initialValue: account.displayName)
            _emailAddress = State(initialValue: account.emailAddress)
            _username = State(initialValue: account.username)
            _imapHost = State(initialValue: account.imapHost)
            _imapPort = State(initialValue: String(account.imapPort))
            _imapSecurity = State(initialValue: account.imapSecurity)
            _smtpHost = State(initialValue: account.smtpHost)
            _smtpPort = State(initialValue: String(account.smtpPort))
            _smtpSecurity = State(initialValue: account.smtpSecurity)
        }
    }

    private var isEditing: Bool { account != nil }

    private var canSubmit: Bool {
        guard !imapHost.trimmingCharacters(in: .whitespaces).isEmpty,
              !username.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return configurationError == nil && (isEditing || !password.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L.string(isEditing ? "mail.account.edit" : "mail.account.add"))
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            Form {
                Section(L.string("mail.form.account")) {
                    TextField(L.string("mail.form.displayName"), text: $displayName)
                    TextField(L.string("mail.form.email"), text: $emailAddress)
                    TextField(L.string("mail.form.username"), text: $username)
                    Text(L.string("mail.form.username.help")).font(.caption).foregroundStyle(.secondary)
                    if !username.contains("@"), MailAddress(name: "", address: emailAddress.trimmingCharacters(in: .whitespacesAndNewlines)).isValid {
                        Button(L.string("mail.form.username.useEmail")) { username = emailAddress.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .buttonStyle(.link)
                    }
                    SecureField(L.string("mail.form.password"), text: $password)
                    if isEditing, hasStoredPassword, password.isEmpty {
                        Text(L.string("mail.form.password.keep"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Section(L.string("mail.form.imap")) {
                    TextField(L.string("mail.form.host"), text: $imapHost)
                    TextField(L.string("mail.form.port"), text: $imapPort)
                    securityPicker(selection: $imapSecurity, options: MailSecurity.allCases)
                    if imapSecurity == .none {
                        securityWarning(L.string("mail.form.security.noneWarning"))
                    }
                }

                Section(L.string("mail.form.smtp")) {
                    TextField(L.string("mail.form.host"), text: $smtpHost)
                    TextField(L.string("mail.form.port"), text: $smtpPort)
                    securityPicker(selection: $smtpSecurity, options: MailSecurity.allCases)
                    if Int(smtpPort.trimmingCharacters(in: .whitespacesAndNewlines)) == 465, smtpSecurity != .tls {
                        Button(L.string("mail.config.useTLS")) { smtpSecurity = .tls }
                            .buttonStyle(.link)
                    }
                    if smtpSecurity == .none {
                        securityWarning(L.string("mail.form.security.noneWarning"))
                    }
                    Text(L.string("mail.form.smtp.help"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .disabled(isTesting || isSaving)

            Divider()

            // 测试结果放在按钮行上方（表单区可滚动，放在表单末尾会落到可视区之外，
            // 表现为「点了测试没反应」）
            if let error = configurationError {
                securityWarning(MailErrorText.message(for: error)).padding(.horizontal, 16).padding(.top, 10)
            }
            if let testOutcome {
                testOutcomeView(testOutcome)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }

            HStack(spacing: 10) {
                Button(L.string("mail.account.test")) {
                    testTask = Task { await runTest() }
                }
                .disabled(isTesting || isSaving || !canSubmit)
                if isTesting {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button(L.string("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L.string(isEditing ? "common.save" : "common.add")) {
                    Task { await submit() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || isTesting || !canSubmit)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 460, height: 520)
        .onDisappear { testTask?.cancel() }
        .onChange(of: emailAddress) { oldValue, newValue in
            if username.isEmpty || username == oldValue { username = newValue.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        .onChange(of: [username, imapHost, imapPort, imapSecurity.rawValue, smtpHost, smtpPort, smtpSecurity.rawValue]) { _, _ in testOutcome = nil }
        .onChange(of: password) { _, _ in testOutcome = nil }
    }

    private var configurationError: MailConfigurationError? {
        guard let imapPort = Int(imapPort.trimmingCharacters(in: .whitespacesAndNewlines)) else { return .invalidPort(.imap) }
        do {
            try MailServerConfiguration.validate(port: imapPort, security: imapSecurity, protocolKind: .imap)
            if !smtpHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let smtpPort = Int(smtpPort.trimmingCharacters(in: .whitespacesAndNewlines)) else { return .invalidPort(.smtp) }
                try MailServerConfiguration.validate(port: smtpPort, security: smtpSecurity, protocolKind: .smtp)
            }
            return nil
        } catch { return error as? MailConfigurationError }
    }

    private func securityPicker(
        selection: Binding<MailSecurity>,
        options: [MailSecurity]
    ) -> some View {
        Picker(L.string("mail.form.security"), selection: selection) {
            ForEach(options, id: \.self) { value in
                Text(L.string(value.labelKey)).tag(value)
            }
        }
    }

    /// 加密方式与端口配置的可操作提示。
    private func securityWarning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11))
            .foregroundStyle(.orange)
    }

    // MARK: - Actions

    /// 用当前表单值构造账号（编辑时保留原 id 与创建时间）。
    private func composedAccount() -> MailAccount {
        var value = account ?? MailAccount(
            displayName: displayName,
            emailAddress: emailAddress,
            imapHost: imapHost,
            imapPort: Int(imapPort) ?? 993,
            imapSecurity: imapSecurity,
            smtpHost: smtpHost,
            smtpPort: Int(smtpPort) ?? 587,
            smtpSecurity: smtpSecurity,
            username: username
        )
        value.displayName = displayName
        value.emailAddress = emailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        value.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        value.imapHost = imapHost.trimmingCharacters(in: .whitespaces)
        value.imapPort = Int(imapPort.trimmingCharacters(in: .whitespacesAndNewlines)) ?? (imapSecurity == .tls ? 993 : 143)
        value.imapSecurity = imapSecurity
        value.smtpHost = smtpHost.trimmingCharacters(in: .whitespaces)
        value.smtpPort = Int(smtpPort.trimmingCharacters(in: .whitespacesAndNewlines)) ?? (smtpSecurity == .tls ? 465 : 587)
        value.smtpSecurity = smtpSecurity
        value.updatedAt = Date()
        return value
    }

    private func runTest() async {
        let candidate = composedAccount()
        isTesting = true
        testOutcome = nil
        defer { isTesting = false }
        let result = await onTest(candidate, password)
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let probe):
            testOutcome = .success(probe)
        case .failure(let error):
            testOutcome = .failure(MailErrorText.message(for: error))
        }
    }

    private func submit() async {
        isSaving = true
        defer { isSaving = false }
        let saved = await onSave(composedAccount(), password.isEmpty ? nil : password)
        if saved { dismiss() }
    }

    // MARK: - Test Outcome

    /// 测试结果的展示：成功给绿色勾选（含文件夹数，SMTP 未探测时附提示），
    /// 失败给红色叉号 + 具体原因。放独立 ViewBuilder 便于一次渲染整行。
    @ViewBuilder
    private func testOutcomeView(_ outcome: TestOutcome) -> some View {
        switch outcome {
        case .success(let probe):
            Label(
                L.format("mail.account.testSuccess", probe.folderCount),
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
            if !probe.smtpReachable {
                Text(L.string("mail.account.testSmtpSkipped"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        case .failure(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private enum TestOutcome {
        case success(MailConnectionProbe)
        case failure(String)
    }
}