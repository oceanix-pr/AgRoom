import SwiftUI
import AgRoomCore

// MARK: - Python Environment Tab

/// 设置 → 工具与自动化中的「Python 环境」子页：
/// - 固定受管目录内的运行时状态与下载提示
/// - 托管运行时安装（Miniforge 下载安装，进度展示）
/// - Python 包管理（pip list / install / uninstall，输出实时展示）
struct PythonEnvironmentTab: View {
    let hub: Hub

    private let manager = PythonRuntimeManager.shared
    @State private var status: PythonRuntimeStatus = .notInstalled
    /// pip 列表解析出的已安装包（name, version）
    @State private var packages: [PythonPackageInfo] = []
    @State private var loadingPackages = false
    @State private var environmentReady = false
    @State private var preparingEnvironment = false
    /// 安装/卸载/安装托管运行时的进行中状态与输出日志
    @State private var pipBusy = false
    @State private var pipLog = ""
    @State private var installingRuntime = false
    @State private var installProgress: Double = 0
    @State private var installStage = ""
    /// 安装包名输入
    @State private var packageQuery = ""
    @State private var errorMessage: String?
    @State private var showErrorAlert = false
    @State private var packagePendingRemoval: PythonPackageInfo?

    struct PythonPackageInfo: Identifiable, Equatable {
        let name: String
        let version: String
        var id: String { name }
    }

    var body: some View {
        Form {
            runtimeSection
            packagesSection
        }
        .formStyle(.grouped)
        .task(id: hub.spaceStore.current) {
            refreshStatus()
            await loadPackages()
        }
        .alert(L.string("common.error"), isPresented: $showErrorAlert) {
            Button(L.string("common.ok"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            L.string("settings.python.remove_package.title"),
            isPresented: Binding(
                get: { packagePendingRemoval != nil },
                set: { if !$0 { packagePendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L.string("settings.python.remove_package.confirm"), role: .destructive) {
                if let package = packagePendingRemoval {
                    removePackage(package)
                }
                packagePendingRemoval = nil
            }
            Button(L.string("common.cancel"), role: .cancel) {}
        } message: {
            if let package = packagePendingRemoval {
                Text(L.format("settings.python.remove_package.message", package.name))
            }
        }
    }

    // MARK: - Runtime Status Section

    private var runtimeSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: statusIcon)
                    .font(.title3)
                    .foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text(statusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                if installingRuntime {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if installingRuntime {
                VStack(alignment: .leading, spacing: 4) {
                    if installProgress >= 0 {
                        ProgressView(value: installProgress)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(installStage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if case .notInstalled = status {
                Button(L.string("settings.python.install_runtime")) {
                    installRuntime()
                }
            }

            if status.pythonPath != nil, !environmentReady {
                Button(L.string("settings.python.prepare")) {
                    let space = hub.spaceStore.current
                    preparingEnvironment = true
                    Task {
                        defer { preparingEnvironment = false }
                        do {
                            _ = try await PythonEnvironmentService.shared.environment(for: space)
                            guard hub.spaceStore.current == space else { return }
                            refreshStatus()
                            await loadPackages()
                        } catch {
                            guard hub.spaceStore.current == space else { return }
                            errorMessage = L.errorDescription(error)
                            showErrorAlert = true
                        }
                    }
                }
                .disabled(preparingEnvironment)
            }

            Button(L.string("python.runtime.recheck")) {
                refreshStatus()
                Task { await loadPackages() }
            }
            .disabled(installingRuntime)
        } header: {
            Text(L.string("settings.python.runtime"))
        } footer: {
            Text(L.format("settings.python.runtime.footer", manager.environmentRoot.path)
                 + "\n" + L.string("settings.scope.global"))
        }
    }

    private var statusIcon: String {
        switch status {
        case .managed: return "checkmark.seal.fill"
        case .notInstalled: return "xmark.seal"
        }
    }

    private var statusColor: Color {
        switch status {
        case .managed: return .green
        case .notInstalled: return .secondary
        }
    }

    private var statusTitle: String {
        switch status {
        case .managed: return L.string("settings.python.status.managed")
        case .notInstalled: return L.string("settings.python.status.none")
        }
    }

    private var statusDetail: String {
        switch status {
        case .managed(let path):
            return path
        case .notInstalled:
            return L.format("settings.python.status.none.detail", manager.managedPythonPath)
        }
    }

    // MARK: - Packages Section

    private var packagesSection: some View {
        Section {
            // 安装行：包名输入 + 安装按钮
            HStack {
                TextField(L.string("settings.python.package.placeholder"), text: $packageQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { installPackage() }
                Button(L.string("settings.python.package.install"), action: installPackage)
                    .controlSize(.small)
                    .disabled(packageQuery.trimmingCharacters(in: .whitespaces).isEmpty || pipBusy || !environmentReady)
            }

            // 已安装包列表
            if loadingPackages {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L.string("settings.python.package.loading"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if packages.isEmpty {
                Text(L.string("settings.python.package.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(packages) { package in
                    HStack {
                        Text(package.name)
                            .font(.system(.caption, design: .monospaced))
                        Spacer()
                        Text(package.version)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            packagePendingRemoval = package
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .disabled(pipBusy)
                    }
                }
            }

            // pip 操作输出（安装/卸载/列表加载错误）
            if !pipLog.isEmpty {
                ScrollView {
                    Text(pipLog)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .background(Color.secondary.opacity(0.06))
                .cornerRadius(6)
            }

            HStack {
                Spacer()
                Button(L.string("settings.python.package.refresh"), action: { Task { await loadPackages() } })
                    .controlSize(.small)
                    .disabled(pipBusy || status.pythonPath == nil)
            }
        } header: {
            HStack {
                Text(L.string("settings.python.packages"))
                if pipBusy {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
        } footer: {
            Text(L.string("settings.python.packages.footer") + "\n"
                 + L.format("settings.scope.space", L.string(hub.spaceStore.current.nameKey)))
        }
    }

    // MARK: - Actions

    private func refreshStatus() {
        status = manager.status()
        environmentReady = status.pythonPath.flatMap { PythonEnvironmentService.existingEnvironment(for: hub.spaceStore.current, baseInterpreter: $0) } != nil
    }

    /// 安装托管运行时（Miniforge）
    private func installRuntime() {
        installingRuntime = true
        installProgress = 0
        installStage = ""
        Task {
            do {
                try await manager.installManagedRuntime { progress, _ in
                    Task { @MainActor in
                        installProgress = progress
                        installStage = L.string(progress < 0 ? "python.runtime.installing" : "python.runtime.downloading")
                    }
                }
                refreshStatus()
                await loadPackages()
            } catch {
                errorMessage = L.errorDescription(error)
                showErrorAlert = true
            }
            installingRuntime = false
        }
    }

    /// 解析 pip list 输出为包信息
    private func parsePackages(from output: String) -> [PythonPackageInfo] {
        var result: [PythonPackageInfo] = []
        for line in output.split(separator: "\n").dropFirst(2) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let version = String(parts[1]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.lowercased() != "package" else { continue }
            result.append(PythonPackageInfo(name: name, version: version))
        }
        return result.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// 加载已安装包列表（pip list）
    private func loadPackages() async {
        let space = hub.spaceStore.current
        guard environmentReady else {
            packages = []
            return
        }
        loadingPackages = true
        defer { loadingPackages = false }
        do {
            let result = try await PythonExecutor(space: space).runPip(arguments: ["list", "--format=columns"])
            guard hub.spaceStore.current == space, !Task.isCancelled else { return }
            if result.succeeded {
                packages = parsePackages(from: result.stdout)
            } else {
                packages = []
                if !result.displayOutput.isEmpty {
                    pipLog = result.displayOutput
                }
            }
        } catch {
            guard hub.spaceStore.current == space else { return }
            packages = []
        }
    }

    /// 安装包：pip install <query>
    private func installPackage() {
        let query = packageQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, !pipBusy, environmentReady else { return }
        let space = hub.spaceStore.current
        pipBusy = true
        pipLog = L.format("settings.python.pip.running", "install \(query)")
        Task {
            do {
                let result = try await PythonExecutor(space: space).runPip(arguments: ["install", query])
                guard hub.spaceStore.current == space else { return }
                pipLog = "$ pip install \(query)\n" + result.displayOutput
                await loadPackages()
                guard hub.spaceStore.current == space else { return }
                if !result.succeeded {
                    errorMessage = L.string("settings.python.pip.install_failed")
                    showErrorAlert = true
                } else {
                    packageQuery = ""
                }
            } catch {
                guard hub.spaceStore.current == space else { return }
                errorMessage = L.errorDescription(error)
                showErrorAlert = true
            }
            pipBusy = false
        }
    }

    /// 移除包：pip uninstall -y <name>
    private func removePackage(_ package: PythonPackageInfo) {
        guard !pipBusy, environmentReady else { return }
        let space = hub.spaceStore.current
        pipBusy = true
        pipLog = L.format("settings.python.pip.running", "uninstall \(package.name)")
        Task {
            do {
                let result = try await PythonExecutor(space: space).runPip(arguments: ["uninstall", "-y", package.name])
                guard hub.spaceStore.current == space else { return }
                pipLog = "$ pip uninstall -y \(package.name)\n" + result.displayOutput
                await loadPackages()
                guard hub.spaceStore.current == space else { return }
                if !result.succeeded {
                    errorMessage = L.string("settings.python.pip.uninstall_failed")
                    showErrorAlert = true
                }
            } catch {
                guard hub.spaceStore.current == space else { return }
                errorMessage = L.errorDescription(error)
                showErrorAlert = true
            }
            pipBusy = false
        }
    }
}
