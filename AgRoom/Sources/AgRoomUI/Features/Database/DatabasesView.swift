import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AgRoomCore

// MARK: - Databases View

/// Local SQLite databases and remote MySQL connections have independent workspaces and lifecycles.
public struct DatabasesView: View {
    let hub: Hub
    private let space: AppSpace
    @State private var location: Location = .local
    @State private var mysqlService: MySQLConnectorService?

    private enum Location: String, CaseIterable {
        case local, remote
        @MainActor var title: String { L.string("db.location." + rawValue) }
    }

    public init(hub: Hub) {
        self.hub = hub
        self.space = hub.spaceStore.current
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker(L.string("db.location"), selection: $location) {
                    ForEach(Location.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 380)
                Spacer()
                Text(L.string(space.nameKey)).font(.caption).foregroundStyle(.secondary)
            }.padding(12)
            Divider()
            switch location {
            case .local:
                LocalDatabasesView(hub: hub, space: space)
            case .remote:
                if let mysqlService {
                    MySQLConnectionsView(service: mysqlService, showsCloseButton: false)
                } else {
                    ContentUnavailableView(L.string("error.database"), systemImage: "externaldrive.badge.exclamationmark")
                }
            }
        }
        .task { mysqlService = hub.makeMySQLConnectorService(for: space) }
    }
}

private struct LocalDatabasesView: View {
    let hub: Hub
    private let space: AppSpace
    /// 工具栏搜索词：过滤数据库列表（名称命中）
    @Environment(\.globalSearchText) private var searchText

    @State private var workbench = DatabaseWorkbench()
    @State private var queryTask: Task<Void, Never>?
    @State private var metadataTask: Task<Void, Never>?
    @State private var previewTask: Task<Void, Never>?
    @State private var generationTask: Task<Void, Never>?
    @State private var queryID = UUID()
    @State private var metadataID = UUID()
    @State private var previewID = UUID()
    @State private var generationID = UUID()
    @State private var isRunning = false

    struct DatabaseEntry: Identifiable, Hashable {
        let id: String      // 文件路径
        let name: String    // 展示名
        let isSpaceDB: Bool
    }

    @State private var databases: [DatabaseEntry] = []
    @State private var selectedDatabaseId: String?
    @State private var tables: [String] = []
    @State private var selectedTable: String?
    @State private var tableResult: SQLResult?
    @State private var sqlText = ""
    /// 自然语言转 SQL：查询描述与生成中状态
    @State private var nlQuery = ""
    @State private var isGeneratingSQL = false
    @State private var sqlResult: SQLResult?
    @State private var sqlMessage: String?
    @State private var readOnly = false
    @State private var isLoadingTables = false
    @State private var isDeleting = false
    @State private var removing: DatabaseEntry?
    @State private var showingNewDB = false
    @State private var newDBName = ""
    @State private var errorMessage: String?
    @State private var showErrorAlert = false

    init(hub: Hub, space: AppSpace) {
        self.hub = hub
        self.space = space
    }

    public var body: some View {
        HStack(spacing: 0) {
            databaseList
                .frame(width: 220)
            Color(nsColor: .separatorColor)
                .frame(width: 1)
            workbenchArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .disabled(isDeleting)
        }
        .onAppear { reloadDatabases() }
        .sheet(isPresented: $showingNewDB) {
            newDatabaseSheet
        }
        .onDisappear { queryTask?.cancel(); metadataTask?.cancel(); previewTask?.cancel(); generationTask?.cancel() }
        .alert(L.string("db.delete.title"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(L.string("common.cancel"), role: .cancel) { removing = nil }
            Button(L.string("common.delete"), role: .destructive) {
                guard let entry = removing else { return }
                removing = nil
                deleteDatabase(entry)
            }
        } message: {
            Text(L.format("db.delete.message", removing?.name ?? ""))
        }
        .alert(L.string("common.error"), isPresented: $showErrorAlert) {
            Button(L.string("common.ok"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Database List

    /// 搜索过滤后的数据库（名称命中，大小写不敏感）
    private var filteredDatabases: [DatabaseEntry] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return databases }
        return databases.filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    private var databaseList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L.string("db.location.local"))
                    .font(MeetTypography.sectionTitle)
                Spacer()
                Button(action: { showingNewDB = true }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help(L.string("db.local.new")).disabled(isDeleting)
                Button(action: importDatabase) { Image(systemName: "square.and.arrow.down") }
                    .buttonStyle(.plain).help(L.string("db.import")).disabled(isDeleting)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            Text(L.string("db.local.description")).font(.caption).foregroundStyle(.secondary)
                .padding(12)

            if FileManager.default.fileExists(atPath: DatabaseWorkbench.legacyUserDatabasesDir.path) {
                Text(L.string("db.legacy.help")).font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }

            List(selection: $selectedDatabaseId) {
                ForEach(filteredDatabases) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.name).font(MeetTypography.listTitle)
                            Spacer(minLength: 4)
                            if entry.isSpaceDB {
                                Image(systemName: "lock").foregroundStyle(.secondary)
                                    .help(L.string("db.local.protected"))
                            } else {
                                Button(role: .destructive) { removing = entry } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless).help(L.string("db.delete.title"))
                                    .disabled(isDeleting)
                            }
                        }
                        if entry.isSpaceDB {
                            Text(L.string("db.space_badge"))
                                .font(MeetTypography.secondary)
                                .foregroundColor(.secondary)
                        }
                    }
                    .tag(entry.id)
                    .contextMenu {
                        if !entry.isSpaceDB {
                            Button(L.string("db.delete.title"), role: .destructive) { removing = entry }.disabled(isDeleting)
                        }
                    }
                }
            }
            .disabled(isDeleting)
            .onChange(of: selectedDatabaseId) { _, _ in
                sqlText = ""
                nlQuery = ""
                reloadTables()
            }
        }
    }

    private var newDatabaseSheet: some View {
        VStack(spacing: 14) {
            Text(L.string("db.local.new"))
                .font(MeetTypography.pageTitle)
                .fontWeight(.bold)
            TextField(L.string("db.new.placeholder"), text: $newDBName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
            HStack {
                Button(L.string("common.cancel")) { showingNewDB = false }
                    .keyboardShortcut(.cancelAction)
                Button(L.string("common.save")) {
                    createDatabase()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(newDBName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
    }

    // MARK: - Workbench Area

    private var workbenchArea: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 工具条：表选择 + 只读开关
            HStack(spacing: 10) {
                Picker(L.string("db.tables"), selection: $selectedTable) {
                    Text(L.string("db.tables.empty")).tag(String?.none)
                    ForEach(tables, id: \.self) { table in
                        Text(table).tag(String?.some(table))
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 240)
                .onChange(of: selectedTable) { _, _ in
                    previewTable()
                }

                Button(action: { reloadTables(preservingSelection: true) }) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(selectedDatabaseId == nil || isDeleting)
                .help(L.string("db.tables.refresh"))
                if isLoadingTables { ProgressView().controlSize(.small) }

                Spacer()

                Toggle(L.string("db.readonly"), isOn: Binding(
                    get: { readOnly },
                    set: { newValue in
                        readOnly = newValue
                        workbench.readOnly = newValue
                    }
                ))
                .toggleStyle(.checkbox)
                .font(MeetTypography.secondary)
                .help(L.string("db.readonly.help"))
                .disabled(isRunning)
            }
            .disabled(isDeleting)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if !isLoadingTables && tables.isEmpty && selectedDatabaseId != nil {
                Label(L.string("db.tables.none"), systemImage: "tablecells")
                    .font(.callout).foregroundStyle(.secondary).padding(16)
            }

            // 表数据预览
            if let result = tableResult {
                resultTable(result)
                    .frame(maxHeight: 240)
                Divider()
            }

            // SQL 编辑器
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L.string("db.sql.title"))
                        .font(MeetTypography.control)
                        .fontWeight(.semibold)
                    Spacer()
                    if isRunning {
                        ProgressView().controlSize(.small)
                        Button(L.string("common.cancel")) { queryTask?.cancel() }
                    }
                    Button(L.string("db.sql.run")) { runSQL() }
                        .buttonStyle(.borderedProminent)
                        .disabled(isRunning || isDeleting || sqlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedDatabaseId == nil)
                }
                TextEditor(text: $sqlText)
                    .readingBodyFont(monospaced: true)
                    .frame(minHeight: 80)
                    .border(Color.secondary.opacity(0.2))

                // 自然语言转 SQL：描述查询 → AI 生成 SQL 填入编辑器（用户可改后手动执行）
                HStack(spacing: 8) {
                    TextField(L.string("db.nlsql.placeholder"), text: $nlQuery)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { generateSQL() }
                        .disabled(isGeneratingSQL || selectedDatabaseId == nil)
                    Button {
                        generateSQL()
                    } label: {
                        if isGeneratingSQL {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(L.string("db.nlsql.generate"), systemImage: "sparkles")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isGeneratingSQL || nlQuery.trimmingCharacters(in: .whitespaces).isEmpty || selectedDatabaseId == nil)
                }

                if let message = sqlMessage {
                    Text(message)
                        .font(MeetTypography.secondary)
                        .foregroundColor(.secondary)
                }
                if let result = sqlResult {
                    if result.isRead {
                        resultTable(result)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Spacer(minLength: 0)
        }
    }

    /// 结果表格（横向滚动）
    private func resultTable(_ result: SQLResult) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(result.columns.enumerated()), id: \.offset) { _, column in
                        Text(column)
                            .font(MeetTypography.secondary.weight(.semibold).monospaced())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.secondary.opacity(0.12))
                    }
                }
                ForEach(Array(result.rows.prefix(200).enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                            Text(value)
                                .font(MeetTypography.secondary.monospaced())
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                        }
                    }
                    Divider()
                }
            }
        }
        .border(Color.secondary.opacity(0.15))
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: - Actions

    private func reloadDatabases(selecting preferredPath: String? = nil) {
        var entries: [DatabaseEntry] = []
        if let spacePath = hub.spaceStore.databasePath(for: space) {
            entries.append(DatabaseEntry(
                id: spacePath,
                name: L.string("db.space_name"),
                isSpaceDB: true
            ))
        }
        for url in DatabaseWorkbench.listUserDatabases(space: space) {
            entries.append(DatabaseEntry(
                id: url.path,
                name: url.deletingPathExtension().lastPathComponent,
                isSpaceDB: false
            ))
        }
        databases = entries
        let selection = preferredPath ?? selectedDatabaseId
        let next = entries.contains(where: { $0.id == selection }) ? selection : entries.first?.id
        if selectedDatabaseId != next { selectedDatabaseId = next }
        else { reloadTables() }
    }

    private func reloadTables(preservingSelection: Bool = false) {
        if !preservingSelection {
            queryTask?.cancel()
            queryID = UUID()
            isRunning = false
            sqlResult = nil
            sqlMessage = nil
        }
        metadataTask?.cancel()
        previewTask?.cancel()
        previewID = UUID()
        generationTask?.cancel()
        generationID = UUID()
        isGeneratingSQL = false
        let id = UUID()
        metadataID = id
        let previousTable = preservingSelection ? selectedTable : nil
        if !preservingSelection { tables = []; selectedTable = nil }
        tableResult = nil
        isLoadingTables = false
        guard let path = selectedDatabaseId else { return }
        isLoadingTables = true
        metadataTask = Task {
            defer { if metadataID == id { isLoadingTables = false } }
            do {
                let values = try await workbench.tablesAsync(at: path)
                try Task.checkCancellation()
                guard metadataID == id, selectedDatabaseId == path else { return }
                tables = values
                let next = previousTable.flatMap { values.contains($0) ? $0 : nil } ?? values.first
                if selectedTable == next { previewTable() }
                else { selectedTable = next }
            } catch is CancellationError {
            } catch {
                guard metadataID == id else { return }
                errorMessage = L.errorDescription(error)
                showErrorAlert = true
            }
        }
    }

    private func previewTable() {
        tableResult = nil
        previewTask?.cancel()
        let id = UUID()
        previewID = id
        guard let path = selectedDatabaseId, let table = selectedTable else { return }
        previewTask = Task {
            do {
                let result = try await workbench.rowsAsync(at: path, table: table)
                try Task.checkCancellation()
                guard previewID == id, selectedDatabaseId == path, selectedTable == table else { return }
                tableResult = result
            } catch is CancellationError {
            } catch {
                guard previewID == id else { return }
                errorMessage = L.errorDescription(error)
                showErrorAlert = true
            }
        }
    }

    /// 自然语言转 SQL：表名清单 + 描述 → AI 生成 SQL 填入编辑器（可改后手动执行，不自动跑）
    private func generateSQL() {
        let query = nlQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isGeneratingSQL, selectedDatabaseId != nil else { return }
        isGeneratingSQL = true
        let path = selectedDatabaseId
        let id = UUID()
        generationID = id
        let tableList = tables.isEmpty ? "(unknown — ask the user to preview a table first)" : tables.joined(separator: ", ")
        let table = selectedTable ?? "none"
        generationTask = Task { @MainActor in
            defer { if generationID == id { isGeneratingSQL = false } }
            do {
                guard let provider = try await hub.makeActiveProvider(for: space, source: "database-design") else {
                    throw LLMError.providerUnavailable
                }
                let generator = AIAssistGenerator(provider: provider)
                let sql = try await generator.text(
                    system: """
                    You are a SQLite expert. Translate a natural-language query request into ONE SQL statement.
                    Database tables: \(tableList). Current selected table: \(table).
                    Rules: SQLite dialect only; SELECT-only unless the request clearly asks for a write;
                    prefer explicit column lists over *; no commentary, no markdown fences.
                    Output ONLY the SQL statement.
                    """,
                    user: query,
                    config: LLMConfig(maxTokens: 2048, temperature: 0.2)
                )
                try Task.checkCancellation()
                guard generationID == id, selectedDatabaseId == path else { return }
                sqlText = sql
            } catch is CancellationError {
            } catch {
                guard generationID == id, selectedDatabaseId == path else { return }
                errorMessage = L.errorDescription(error)
                showErrorAlert = true
            }
        }
    }

    private func runSQL() {
        guard let path = selectedDatabaseId, !isRunning else { return }
        let sql = sqlText
        let id = UUID()
        queryID = id
        isRunning = true
        sqlResult = nil
        sqlMessage = nil
        queryTask = Task {
            defer { if queryID == id { isRunning = false } }
            do {
                let result = try await workbench.executeAsync(at: path, sql: sql)
                guard queryID == id, selectedDatabaseId == path else { return }
                sqlResult = result
                if result.isRead {
                    sqlMessage = L.format("db.sql.rows", result.rows.count, result.duration)
                        + (result.truncated ? " · " + L.string("database.sql.truncated") : "")
                } else {
                    sqlMessage = L.format("db.sql.affected", result.rowsAffected, result.duration)
                    reloadTables(preservingSelection: true)
                }
            } catch is CancellationError {
                if queryID == id { sqlMessage = L.string("db.sql.cancelled") }
            } catch {
                if queryID == id { sqlMessage = L.errorDescription(error) }
            }
        }
    }

    private func createDatabase() {
        do {
            let destination = try DatabaseWorkbench.createDatabase(name: newDBName, space: space)
            newDBName = ""
            showingNewDB = false
            reloadDatabases(selecting: destination.path)
        } catch {
            errorMessage = L.errorDescription(error)
            showErrorAlert = true
        }
    }

    private func importDatabase() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["sqlite", "db", "sqlite3"].compactMap { UTType(filenameExtension: $0) }
        panel.message = L.string("db.import.help")
        if FileManager.default.fileExists(atPath: DatabaseWorkbench.legacyUserDatabasesDir.path) {
            panel.directoryURL = DatabaseWorkbench.legacyUserDatabasesDir
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        Task {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let destination = try await Task.detached {
                    try DatabaseWorkbench.importDatabase(from: url, space: space)
                }.value
                guard hub.spaceStore.current == space else { return }
                reloadDatabases(selecting: destination.path)
            } catch {
                guard hub.spaceStore.current == space else { return }
                errorMessage = L.errorDescription(error)
                showErrorAlert = true
            }
        }
    }

    private func deleteDatabase(_ entry: DatabaseEntry) {
        guard !entry.isSpaceDB, !isDeleting else { return }
        isDeleting = true
        let pending = [queryTask, metadataTask, previewTask, generationTask].compactMap { $0 }
        pending.forEach { $0.cancel() }
        queryID = UUID(); metadataID = UUID(); previewID = UUID(); generationID = UUID()
        isRunning = false; isLoadingTables = false; isGeneratingSQL = false
        let workbench = workbench
        Task {
            defer { isDeleting = false }
            // Wait for cancelled SQLite work to release its shared maintenance leases.
            for task in pending { await task.value }
            do {
                try await Task.detached {
                    try workbench.deleteDatabase(at: URL(fileURLWithPath: entry.id), space: space)
                }.value
                guard hub.spaceStore.current == space else { return }
                reloadDatabases()
            } catch {
                guard hub.spaceStore.current == space else { return }
                errorMessage = L.errorDescription(error)
                showErrorAlert = true
                reloadTables(preservingSelection: true)
            }
        }
    }
}
