import Foundation

/// Text fallback never starts a process. Semantic queries are host operations because
/// loading project build settings can evaluate manifests, plugins or a build server.
struct RepositorySymbolsTool: DispatcherTool {
    let reader: RepositoryReader
    let space: AppSpace
    var query: @Sendable (SourceKitLSPTransport.Request) async throws -> Data = { try await SourceKitLSPTransport.query($0) }

    var requiresConfirmation: Bool { true }
    func requiresConfirmation(argumentsJSON: String) -> Bool { native(argumentsJSON) }
    func permissionClass(argumentsJSON: String) -> PermissionClass { native(argumentsJSON) ? .codeExecution : .readOnly }
    func sideEffectClass(argumentsJSON: String) -> ToolSideEffectClass { native(argumentsJSON) ? .nonIdempotentWrite : .readOnly }
    func requiresHardConfirmation(argumentsJSON: String) -> Bool { native(argumentsJSON) }
    func hardConfirmationReason(argumentsJSON: String) -> ConfirmationRequirement.HardReason { .hostExecution }
    func writeTargets(argumentsJSON: String) -> [String] { native(argumentsJSON) ? [reader.root.path] : [] }
    private func native(_ raw: String) -> Bool { ToolArguments.parse(raw)["backend"] as? String == "sourcekit_lsp" }

    var definition: ToolDefinition {
        .init(name: "repo_symbols", description: "Navigate Swift definitions, references, or read a complete named symbol. Default backend=text returns literal candidates only, with no index/completeness claim. Optional sourcekit_lsp uses the selected Xcode toolchain and existing project build settings/index. It is a HOST operation: danger-full-access and fresh hard confirmation on every query, because manifests/build servers may execute code. No automatic switch from text or sandbox failure. Background indexing is disabled; index freshness is unknown, so empty references never prove absence. Positions are one-based lines and UTF-16 columns. Results stay within the bound repository. Use read_symbol with an exact symbol name or position; use files_read_range for more source.",
            parametersSchemaJSON: #"{"type":"object","properties":{"action":{"type":"string","enum":["definitions","references","read_symbol"]},"backend":{"type":"string","enum":["text","sourcekit_lsp"]},"path":{"type":"string"},"symbol":{"type":"string","maxLength":128},"line":{"type":"integer","minimum":1},"column":{"type":"integer","minimum":1}},"required":["action","path"],"additionalProperties":false}"#)
    }

    func approvalPresentation(argumentsJSON: String) -> ToolApprovalPresentation? {
        guard native(argumentsJSON) else { return nil }
        return .init(executionKind: .hostLanguageService, startingDirectory: reader.root.path,
            resourceAccess: .host,
            network: .init(allowed: true, detail: "host_network"), childProcesses: .init(allowed: true, detail: "host_processes"),
            reasonCode: "host_language_service", constraintSources: ["space", "sessionWorkspace", "mode"],
            executionDetails: ["program=xcrun sourcekit-lsp", "backgroundIndexing=false", "workspace=\(reader.root.path)"])
    }

    func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        guard Set(args.keys).isSubset(of: ["action", "backend", "path", "symbol", "line", "column"]),
              let action = args["action"] as? String, ["definitions", "references", "read_symbol"].contains(action),
              let path = args["path"] as? String,
              args["backend"] == nil || ["text", "sourcekit_lsp"].contains(args["backend"] as? String ?? ""),
              args["symbol"] == nil || ((args["symbol"] as? String).map { !$0.isEmpty && $0.count <= 128 && !$0.contains("\n") && !$0.contains("\0") } == true),
              args["line"] == nil || args["line"] is Int, args["column"] == nil || args["column"] is Int else {
            throw ToolExecutionFailure(message: "Invalid symbol navigation arguments.")
        }
        let url = try reader.resolve(path)
        let data = try reader.read(url.path, limit: 1024 * 1024)
        guard let text = String(data: data, encoding: .utf8) else { throw ToolExecutionFailure(message: "Symbol navigation requires UTF-8 source.") }
        let lines = text.components(separatedBy: "\n")
        let line = args["line"] as? Int ?? 1, column = args["column"] as? Int ?? 1
        guard line > 0, line <= lines.count, column > 0, column <= lines[line - 1].utf16.count + 1 else {
            throw ToolExecutionFailure(message: "Symbol position is outside the source. Columns count UTF-16 code units.")
        }
        let symbol = args["symbol"] as? String ?? word(at: column - 1, in: lines[line - 1])
        guard action == "read_symbol" && args["symbol"] != nil || args["line"] != nil else {
            throw ToolExecutionFailure(message: "Provide an exact symbol for read_symbol, or a source line and optional UTF-16 column.")
        }
        if !native(argumentsJSON) { return try await fallback(symbol: symbol, path: path, action: action, reason: "text_requested") }
        guard url.pathExtension == "swift" else { return try await fallback(symbol: symbol, path: path, action: action, reason: "unsupported_language") }
        // Internal run storage is fixed by space, separate from the model's scoped readers.
        let storage = FileAreaService(baseDirectory: reader.service.baseDirectory)
        let requestedTemporary = storage.defaultChatRoot(for: space).appendingPathComponent(".agroom-lsp/\(UUID().uuidString)")
        let temporary = try storage.resolveManaged(requestedTemporary.path)
        guard temporary.path == requestedTemporary.standardizedFileURL.path else { throw FileAreaService.AreaError.unsafePath }
        for directory in [temporary.appendingPathComponent("home"), temporary.appendingPathComponent("tmp")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let method = action == "read_symbol" ? "textDocument/documentSymbol" : action == "definitions" ? "textDocument/definition" : "textDocument/references"
        let raw: Data
        do { raw = try await query(.init(root: reader.root, file: url, text: text, method: method,
            line: line - 1, character: column - 1, temporary: temporary)) }
        catch is CancellationError { throw CancellationError() }
        catch { return try await fallback(symbol: symbol, path: path, action: action, reason: "language_service_unavailable") }
        try Task.checkCancellation()
        guard try reader.read(url.path, limit: 1024 * 1024) == data else {
            throw ToolExecutionFailure(message: "Source changed during symbol navigation; obtain the current source before retrying.")
        }
        let value = try JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed])
        let index: [String: Any] = ["background_indexing": false, "freshness": "unknown", "complete": false]
        if action == "read_symbol" {
            let symbols = flatten(value as? [[String: Any]] ?? [])
            let selected = symbols.filter { item in
                guard let range = item["range"] as? [String: Any], let start = range["start"] as? [String: Int],
                      let end = range["end"] as? [String: Int], let first = start["line"], let last = end["line"] else { return false }
                if args["symbol"] != nil {
                    let name = item["name"] as? String ?? ""
                    return name == symbol || name.hasPrefix(symbol + "(")
                }
                return first <= line - 1 && line - 1 <= last
            }.sorted { rangeLength($0) < rangeLength($1) }
            guard selected.count == 1 || args["symbol"] == nil, let item = selected.first,
                  let range = item["range"] as? [String: Any], let start = range["start"] as? [String: Int],
                  let end = range["end"] as? [String: Int], let first = start["line"], let last = end["line"],
                  first >= 0, last >= first, last < lines.count else {
                return try await fallback(symbol: symbol, path: path, action: action, reason: "symbol_missing_or_ambiguous")
            }
            let readArgs = String(decoding: try JSONSerialization.data(withJSONObject: ["path": url.path,
                "start_line": first + 1, "end_line": min(last + 1, first + 500)]), as: UTF8.self)
            let page = try await FilesReadRangeTool(reader: reader).execute(argumentsJSON: readArgs)
            var result = try JSONSerialization.jsonObject(with: Data(page.utf8)) as? [String: Any] ?? [:]
            guard result["sha256"] as? String == ManagedTextSnapshot.digest(data) else {
                throw ToolExecutionFailure(message: "Source changed after symbol lookup; re-read before editing.")
            }
            result["backend"] = "sourcekit_lsp"; result["index_status"] = index
            result["symbol"] = String((item["name"] as? String ?? "").prefix(256)); result["symbol_end_line"] = last + 1
            return String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self)
        }
        let locations = (value as? [[String: Any]]) ?? (value as? [String: Any]).map { [$0] } ?? []
        var results: [[String: Any]] = [], excluded = 0
        for location in locations.prefix(256) {
            guard let uri = (location["uri"] ?? location["targetUri"]) as? String, let target = URL(string: uri),
                  target.isFileURL, let safe = try? reader.resolve(target.path),
                  let range = (location["range"] ?? location["targetSelectionRange"] ?? location["targetRange"]) as? [String: Any],
                  let start = range["start"] as? [String: Int], let end = range["end"] as? [String: Int],
                  let line = start["line"], let column = start["character"], line >= 0, column >= 0,
                  let endLine = end["line"], let endColumn = end["character"], endLine >= line, endColumn >= 0,
                  endLine != line || endColumn >= column,
                  line < 10_000_000, column < 10_000_000, endLine < 10_000_000, endColumn < 10_000_000 else { excluded += 1; continue }
            if results.count < 24 { results.append(["path": safe.path, "line": line + 1, "column_utf16": column + 1, "range_zero_based": ["start": start, "end": end]]) }
        }
        func report() throws -> Data {
            try JSONSerialization.data(withJSONObject: ["backend": "sourcekit_lsp", "action": action,
                "index_status": index, "input_sha256": ManagedTextSnapshot.digest(data), "locations": results,
                "excluded_locations": excluded, "truncated": locations.count > results.count + excluded,
                "next_instruction": "Existing-index results may be incomplete or stale. Read current source before editing; use repo_search for additional candidates."], options: [.sortedKeys])
        }
        while try report().count > 5400, !results.isEmpty { results.removeLast() }
        return String(decoding: try report(), as: UTF8.self)
    }

    private func fallback(symbol: String, path: String, action: String, reason: String) async throws -> String {
        guard !symbol.isEmpty else { throw ToolExecutionFailure(message: "No symbol at that position. Supply an explicit symbol or use repo_search.") }
        var args: [String: Any] = ["query": symbol, "max_results": 12]
        if action == "read_symbol" { args["path"] = path }
        let search = try await RepositorySearchTool(reader: reader).execute(argumentsJSON:
            String(decoding: JSONSerialization.data(withJSONObject: args), as: UTF8.self))
        return String(decoding: try JSONSerialization.data(withJSONObject: ["backend": "text", "fallback_reason": reason,
            "complete": false, "semantic": false, "candidates": try JSONSerialization.jsonObject(with: Data(search.utf8)),
            "next_instruction": "Literal candidates are not resolved definitions or references. Use files_read_range to inspect bounded source; do not infer absence."], options: [.sortedKeys]), as: UTF8.self)
    }
    private func word(at position: Int, in text: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: #"[\p{L}_][\p{L}\p{N}_]*"#) else { return "" }
        let match = expression.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)).first {
            $0.range.location <= position && position < $0.range.location + $0.range.length
        }
        return match.flatMap { Range($0.range, in: text).map { String(text[$0]) } } ?? ""
    }
    private func flatten(_ symbols: [[String: Any]], depth: Int = 0) -> [[String: Any]] {
        guard depth < 32 else { return [] }
        return Array(symbols.prefix(2048)).flatMap { [$0] + flatten($0["children"] as? [[String: Any]] ?? [], depth: depth + 1) }
    }
    private func rangeLength(_ symbol: [String: Any]) -> Int {
        guard let range = symbol["range"] as? [String: [String: Int]] else { return Int.max }
        return max(0, (range["end"]?["line"] ?? 0) - (range["start"]?["line"] ?? 0))
    }
}
