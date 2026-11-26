import SwiftUI
import AgRoomCore

// MARK: - Python View

/// Python 页：独立运行时下载、代码执行面板、当前空间 pip 包管理
public struct PythonView: View {
    let hub: Hub

    private let runtimeManager = PythonRuntimeManager.shared

    @State private var status: PythonRuntimeStatus = .notInstalled
    @State private var isInstalling = false
    @State private var installMessage = ""
    @State private var installProgress: Double = 0
    @State private var installError: String?

    @State private var code = "print('Hello from AgRoom')\n"
    @State private var isRunning = false
    @State private var output = ""
    @State private var runSummary = ""

    @State private var packageName = ""
    @State private var isPipRunning = false
    @State private var pipOutput = ""

    public init(hub: Hub) {
        self.hub = hub
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                runtimeSection
                Divider()
                executorSection
                Divider()
                pipSection
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            status = runtimeManager.status()
        }
    }

    // MARK: - Runtime Section

    private var runtimeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.string("python.runtime.title"))
                .font(.headline)

            HStack(spacing: 8) {
                statusBadge
                if let path = status.pythonPath {
                    Text(path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if case .notInstalled = status {
                Text(L.format("settings.python.status.none.detail", runtimeManager.managedPythonPath))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(L.format("settings.python.runtime.footer", runtimeManager.environmentRoot.path))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button(action: installRuntime) {
                    if isInstalling {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(L.string("python.runtime.install"), systemImage: "arrow.down.circle")
                    }
                }
                .disabled(isInstalling || isManagedInstalled)

                Button(action: { status = runtimeManager.status() }) {
                    Label(L.string("python.runtime.recheck"), systemImage: "arrow.clockwise")
                }
                .disabled(isInstalling)
            }

            if isInstalling {
                VStack(alignment: .leading, spacing: 4) {
                    if installProgress >= 0 {
                        ProgressView(value: installProgress)
                    } else {
                        ProgressView()
                    }
                    Text(installMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            if let error = installError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding(14)
        .meetCard()
    }

    private var isManagedInstalled: Bool {
        if case .managed = status { return true }
        return false
    }

    private var statusBadge: some View {
        Group {
            switch status {
            case .managed:
                Label(L.string("python.runtime.managed"), systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            case .notInstalled:
                Label(L.string("python.runtime.none"), systemImage: "xmark.circle")
                    .foregroundColor(.red)
            }
        }
        .font(.caption)
    }

    private func installRuntime() {
        isInstalling = true
        installError = nil
        installMessage = ""
        Task {
            do {
                try await runtimeManager.installManagedRuntime { value, _ in
                    Task { @MainActor in
                        installProgress = value
                        installMessage = L.string(value < 0 ? "python.runtime.installing" : "python.runtime.downloading")
                    }
                }
                await MainActor.run {
                    isInstalling = false
                    status = runtimeManager.status()
                }
            } catch {
                await MainActor.run {
                    isInstalling = false
                    installError = L.errorDescription(error)
                }
            }
        }
    }

    // MARK: - Executor Section

    private var executorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.string("python.executor.title"))
                .font(.headline)

            Text(L.format("python.executor.notice", L.dispatcherName()))
                .font(.caption)
                .foregroundColor(.secondary)

            TextEditor(text: $code)
                .font(.system(size: 13, design: .monospaced))
                .frame(minHeight: 140)
                .border(Color.secondary.opacity(0.2))

            HStack(spacing: 10) {
                Button(action: runCode) {
                    if isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(L.string("python.executor.run"), systemImage: "play.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning || status.pythonPath == nil)

                if !runSummary.isEmpty {
                    Text(runSummary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if !output.isEmpty {
                ScrollView {
                    Text(output)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 220)
                .background(Color(nsColor: .textBackgroundColor))
                .border(Color.secondary.opacity(0.2))
            }
        }
    }

    private func runCode() {
        guard !isRunning else { return }
        let space = hub.spaceStore.current
        let executor = PythonExecutor(space: space, workspaceName: "playground")
        let source = code
        isRunning = true
        output = ""
        runSummary = ""
        Task {
            do {
                let result = try await executor.execute(code: source)
                await MainActor.run {
                    guard hub.spaceStore.current == space else { return }
                    isRunning = false
                    output = result.displayOutput.isEmpty ? "(no output)" : result.displayOutput
                    runSummary = "exit=\(result.exitCode) · \(String(format: "%.2f", result.duration))s"
                }
            } catch {
                await MainActor.run {
                    guard hub.spaceStore.current == space else { return }
                    isRunning = false
                    output = L.errorDescription(error)
                }
            }
        }
    }

    // MARK: - Pip Section

    private var pipSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.string("python.pip.title"))
                .font(.headline)

            HStack(spacing: 8) {
                TextField(L.string("python.pip.placeholder"), text: $packageName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .onSubmit { installPackage() }

                Button(L.string("python.pip.install")) { installPackage() }
                    .disabled(isPipRunning || packageName.trimmingCharacters(in: .whitespaces).isEmpty || status.pythonPath == nil)
            }

            if isPipRunning {
                ProgressView()
                    .controlSize(.small)
            }
            if !pipOutput.isEmpty {
                ScrollView {
                    Text(pipOutput)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 160)
                .background(Color(nsColor: .textBackgroundColor))
                .border(Color.secondary.opacity(0.2))
            }
        }
    }

    private func installPackage() {
        let package = packageName.trimmingCharacters(in: .whitespaces)
        guard !isPipRunning, !package.isEmpty, status.pythonPath != nil else { return }
        let space = hub.spaceStore.current
        let executor = PythonExecutor(space: space, workspaceName: "playground")
        // 包名白名单校验：仅允许常见合法字符，防命令注入
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.[]>=<"))
        guard package.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            pipOutput = "Invalid package name."
            return
        }
        isPipRunning = true
        pipOutput = ""
        Task {
            do {
                let result = try await executor.runPip(arguments: ["install", package])
                await MainActor.run {
                    guard hub.spaceStore.current == space else { return }
                    isPipRunning = false
                    pipOutput = result.displayOutput.isEmpty ? "(done)" : result.displayOutput
                }
            } catch {
                await MainActor.run {
                    guard hub.spaceStore.current == space else { return }
                    isPipRunning = false
                    pipOutput = L.errorDescription(error)
                }
            }
        }
    }
}
