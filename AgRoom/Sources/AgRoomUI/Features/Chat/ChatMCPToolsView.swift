import SwiftUI
import AgRoomCore

/// 项目说明与资料中的工具页签；打开此面板不会发起远端发现或业务调用。
struct ChatMCPToolsView: View {
    let service: MCPServerConfigService?
    let space: AppSpace
    let report: RequestContextReport?
    let permissionMode: PermissionMode
    let isRunning: Bool
    @State private var configured: [MCPServerToolSummary] = []
    @State private var errorMessage: String?
    @State private var showingSettings = false
    @State private var showsSnapshot = true
    @State private var hasLoadedConfiguration = false
    @State private var search = ""
    @State private var selectedOnly = false

    private func visibleTools(_ server: MCPServerToolSummary) -> [MCPConversationTool] {
        server.tools.filter { tool in
            (!selectedOnly || tool.isSelected) && (search.isEmpty || server.name.localizedCaseInsensitiveContains(search)
                || tool.name.localizedCaseInsensitiveContains(search) || tool.description.localizedCaseInsensitiveContains(search))
        }
    }

    private var snapshot: [MCPServerToolSummary]? { showsSnapshot ? report?.mcpServers : nil }
    private var servers: [MCPServerToolSummary] { snapshot ?? configured }
    private var mode: PermissionMode { snapshot == nil ? permissionMode : (report?.permissionMode ?? permissionMode) }
    private var exposedNames: Set<String>? { snapshot == nil ? nil : Set(report?.mcpToolNames ?? report?.toolNames ?? []) }
    private func availability(_ tool: MCPConversationTool, from server: MCPServerToolSummary) -> MCPToolAvailability {
        server.availability(of: tool, exposedNames: exposedNames, mode: mode,
            configuredServers: isRunning && snapshot != nil && hasLoadedConfiguration ? configured : nil)
    }
    private var availableCount: Int {
        servers.reduce(0) { count, server in
            count + server.tools.filter { availability($0, from: server) == .available }.count
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(L.string("chat.mcp.title"), systemImage: "bolt.fill").font(.headline)
                Spacer()
                Text(L.format("chat.mcp.available.count", availableCount)).foregroundStyle(.secondary)
            }
            if report?.mcpServers != nil {
                Picker(L.string("chat.mcp.scope"), selection: $showsSnapshot) {
                    Text(L.string(isRunning ? "chat.mcp.current_tab" : "chat.mcp.last_tab")).tag(true)
                    Text(L.string("chat.mcp.next_tab")).tag(false)
                }
                .pickerStyle(.segmented)
            }
            Text(L.string(snapshot == nil ? "chat.mcp.preview" : (isRunning ? "chat.mcp.current" : "chat.mcp.last")))
                .font(.callout).foregroundStyle(.secondary)
            if mode == .readOnly {
                Label(L.string("chat.mcp.read_only"), systemImage: "lock.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
            if let errorMessage { Text(errorMessage).font(.callout).foregroundStyle(.red) }
            TextField(L.string("mcp.tools.search"), text: $search).textFieldStyle(.roundedBorder)
            Toggle(L.string("mcp.tools.selected_only"), isOn: $selectedOnly).toggleStyle(.checkbox)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if servers.isEmpty {
                        Text(L.string("chat.mcp.empty")).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 20)
                    }
                    if !servers.isEmpty, servers.allSatisfy({ visibleTools($0).isEmpty }), !search.isEmpty || selectedOnly {
                        Text(L.string("mcp.tools.no_matches")).foregroundStyle(.secondary)
                    }
                    ForEach(servers.filter { !visibleTools($0).isEmpty || (search.isEmpty && !selectedOnly) }) { server in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(server.name).fontWeight(.semibold)
                                Spacer()
                                if !server.isEnabled { Text(L.string("mcp.disabled")).foregroundStyle(.secondary) }
                            }
                            Text(server.endpoint).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            if server.isEnabled && !server.tools.contains(where: \.isSelected) {
                                Label(L.string("chat.mcp.none_selected"), systemImage: "exclamationmark.triangle")
                                    .font(.callout).foregroundStyle(.orange)
                            }
                            if server.tools.isEmpty { Text(L.string("mcp.tools.empty")).font(.callout).foregroundStyle(.secondary) }
                            ForEach(visibleTools(server)) { tool in
                                let status = availability(tool, from: server)
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: status == .available ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(status == .available ? Color.green : Color.secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(tool.name).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                                        if !tool.description.isEmpty {
                                            Text(tool.description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                        }
                                    }
                                    Spacer(minLength: 4)
                                    Text(L.string("chat.mcp.status." + status.rawValue)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Divider()
                    }
                }
            }
            .frame(maxHeight: .infinity)
            if snapshot != nil, hasLoadedConfiguration, servers != configured {
                Text(L.string("chat.mcp.changed")).font(.callout).foregroundStyle(.orange)
            }
            Text(L.string("chat.mcp.next_turn")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L.string("mcp.manage")) { showingSettings = true }.disabled(service == nil)
                Spacer()
                Button(L.string("mcp.reload")) { Task { await reload() } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await reload() }
        .sheet(isPresented: $showingSettings, onDismiss: {
            if !isRunning { showsSnapshot = false }
            Task { await reload() }
        }) {
            MCPSettingsView(service: service, space: space)
        }
    }

    @MainActor
    private func reload() async {
        guard let service else { errorMessage = L.string("mcp.error.storage"); return }
        do {
            configured = try await service.getAll().map(MCPServerToolSummary.init(config:))
            hasLoadedConfiguration = true
            errorMessage = nil
        } catch { errorMessage = L.errorDescription(error) }
    }
}
