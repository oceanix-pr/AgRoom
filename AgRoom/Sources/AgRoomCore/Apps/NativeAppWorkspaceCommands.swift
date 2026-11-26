import Foundation

extension NativeAppWorkspace {
    public func makeSaveRecordCommand(space: AppSpace, id: UUID, collection: String, title: String, content: String,
                                      fields: [String: NativeAppValue] = [:], replacing revision: Int?) throws -> (DispatcherEngine, ToolCallRaw) {
        try NativeAppDisk.validateRecord(collection: collection, title: title, content: content, fields: fields)
        guard revision == nil || (revision! > 0 && revision! < NativeAppRecord.maximumRevision) else { throw NativeAppError(.capacity) }
        let arguments: [String: String] = ["id": id.uuidString, "collection": collection,
            "title": title, "content": content, "fields": String(decoding: try JSONEncoder().encode(fields), as: UTF8.self),
            "revision": revision.map(String.init) ?? "new"]
        return try command(space: space, name: "nativeapp_record_save", arguments: arguments) {
            try await saveRecord(id: id, collection: collection, title: title, content: content, fields: fields, replacing: revision)
            return id.uuidString
        }
    }

    public func makeDeleteRecordCommand(space: AppSpace, record: NativeAppRecord) throws -> (DispatcherEngine, ToolCallRaw) {
        try command(space: space, name: "nativeapp_record_delete",
            arguments: ["id": record.id.uuidString, "title": record.title, "revision": String(record.revision)]) {
                try await deleteRecord(id: record.id, revision: record.revision)
                return record.id.uuidString
            }
    }

    public func makeSaveFileCommand(space: AppSpace, name: String, data: Data, recordID: UUID? = nil) throws -> (DispatcherEngine, ToolCallRaw) {
        let id = UUID()
        return try command(space: space, name: "nativeapp_file_create",
            arguments: ["id": id.uuidString, "name": name, "bytes": String(data.count), "sha256": NativeAppDisk.digest(data),
                "recordID": recordID?.uuidString ?? ""]) {
                try await saveFile(id: id, name: name, data: data, recordID: recordID)
                return id.uuidString
            }
    }

    public func makeDeleteFileCommand(space: AppSpace, file: NativeAppFile) throws -> (DispatcherEngine, ToolCallRaw) {
        try command(space: space, name: "nativeapp_file_delete",
            arguments: ["id": file.id.uuidString, "name": file.name, "sha256": file.sha256]) {
                try await deleteFile(file)
                return file.id.uuidString
            }
    }

    private func command(space: AppSpace, name: String, arguments: [String: String],
                         execute: @escaping @Sendable () async throws -> String) throws -> (DispatcherEngine, ToolCallRaw) {
        guard space == self.space else { throw NativeAppError(.spaceMismatch) }
        let data = try JSONEncoder().encode(arguments)
        let json = String(decoding: data, as: UTF8.self)
        let policy = PermissionPolicy(mode: .workspaceWrite, fileAreaPolicy: nil)
        let context = ExecutionContext(space: space, permissionPolicy: policy, deadline: Date().addingTimeInterval(300))
        let tool = NativeAppWorkspaceTool(name: name, expectedArguments: arguments, operation: execute)
        return (DispatcherEngine(tools: [tool], systemPrompt: "", permissionPolicy: policy, executionContext: context),
            ToolCallRaw(id: UUID().uuidString, name: name, argumentsJSON: json))
    }
}

private struct NativeAppWorkspaceTool: DispatcherTool {
    let name: String
    let expectedArguments: [String: String]
    let operation: @Sendable () async throws -> String
    var requiresConfirmation: Bool { true }
    var definition: ToolDefinition {
        ToolDefinition(name: name, description: "Perform one captured, revision-bound operation in this app's private workspace.",
            parametersSchemaJSON: #"{"type":"object","additionalProperties":{"type":"string"}}"#)
    }
    func execute(argumentsJSON: String) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              try JSONDecoder().decode([String: String].self, from: data) == expectedArguments else { throw NativeAppError(.conflict) }
        try Task.checkCancellation()
        return try await operation()
    }
}
