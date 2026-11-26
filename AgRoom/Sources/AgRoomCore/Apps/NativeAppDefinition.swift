import Foundation

/// A finite UI language with local state transforms and explicitly approved offline Python functions.
public struct NativeAppDefinition: Codable, Equatable, Sendable, Identifiable {
    public struct Manifest: Codable, Equatable, Sendable {
        public var id: String
        public var version: Int
        public var dslVersion: Int
        public var nameKey: String
        public var summaryKey: String
        public var icon: String
        public var width: Int?
        public var height: Int?
        public var dataVersion: Int?
    }

    public struct StateField: Codable, Equatable, Sendable {
        public var initial: NativeAppValue
        public var persistent: Bool
    }

    public struct DataSource: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case knowledge, records, result }
        public var kind: Kind
        public var searchKey: String?
        public var pageSize: Int
        public var collection: String?
    }

    public struct Binding: Codable, Equatable, Sendable {
        public var literal: NativeAppValue?
        public var state: String?
        /// sourceID.title / sourceID.content, resolved only from the selected record.
        public var selection: String?
        /// boardID.moves / won / canUndo / canRedo, derived from typed board progress.
        public var board: String?
    }

    public struct Script: Codable, Equatable, Sendable {
        public var source: String
        public var inputTypes: [String: NativeAppValue.ValueType]
        public var outputTypes: [String: NativeAppValue.ValueType]
        public var requirements: [String]?
        public var timeoutSeconds: Int?
    }

    public struct ScriptRecordInput: Codable, Equatable, Sendable {
        public var source: String
        /// Refuse oversized queries instead of silently analyzing a partial page.
        public var limit: Int
    }

    public struct Node: Codable, Equatable, Sendable, Identifiable {
        public enum Kind: String, Codable, Sendable {
            case vstack, hstack, text, textField, textEditor, toggle, picker, filePicker, button, list, divider, resourcePicker, table, board
        }
        public enum Style: String, Codable, Sendable { case title, headline, secondary }
        public var id: String
        public var type: Kind
        public var textKey: String?
        public var binding: Binding?
        public var stateKey: String?
        public var action: String?
        public var source: String?
        public var options: [String]?
        public var style: Style?
        public var children: [Node]?
        public var resource: String?
        public var board: String?
    }

    public struct Action: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case refresh, setState, transformState, saveKnowledge, saveRecord, deleteRecord, newRecord, editRecord, saveFile, runPython, callCapability, sequence, boardUndo, boardRedo, boardReset
        }
        public enum Operation: String, Codable, Sendable { case append, removeLast, calculate }
        public var type: Kind
        public var source: String?
        public var stateKey: String?
        public var value: Binding?
        /// saveKnowledge accepts title and content only; it always creates a new record.
        public var values: [String: Binding]?
        public var fields: [String: String]?
        public var script: String?
        public var inputs: [String: Binding]?
        /// State key -> returned output key. Only these destinations can change.
        public var resultBindings: [String: String]?
        public var recordInputs: [String: ScriptRecordInput]?
        /// Input name -> binding containing an app file UUID, never a disk path.
        public var fileInputs: [String: Binding]?
        /// Finite, host-implemented local state operations; never interpreted as code.
        public var operation: Operation?
        public var capability: String?
        public var steps: [String]?
        /// Input name -> complete transient result source, frozen by the host before Python execution.
        public var dataInputs: [String: String]?
        public var board: String?
    }

    public var manifest: Manifest
    public var i18n: [String: [String: String]]
    public var state: [String: StateField]
    public var dataSources: [String: DataSource]
    public var views: Node
    public var actions: [String: Action]
    public var scripts: [String: Script]?
    public var capabilities: [String: NativeAppCapability]?
    public var boards: [String: NativeAppBoard]?
    public var id: String { manifest.id }
    public var dataVersion: Int { manifest.dataVersion ?? 1 }

    public static let maximumBytes = 512 * 1024
    public static let maximumStateBytes = 64 * 1024

    public func text(_ key: String, language: String) -> String {
        i18n[language]?[key] ?? i18n["en"]?[key] ?? key
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw NativeAppError(.tooLarge) }
        do {
            // Check raw nesting before Codable recursively constructs the view tree.
            let json = try JSONSerialization.jsonObject(with: data)
            func checkDepth(_ value: Any, depth: Int) throws {
                guard depth <= 40 else { throw NativeAppError(.invalidDefinition, path: "views") }
                if let object = value as? [String: Any] {
                    for child in object.values { try checkDepth(child, depth: depth + 1) }
                } else if let array = value as? [Any] {
                    for child in array { try checkDepth(child, depth: depth + 1) }
                }
            }
            try checkDepth(json, depth: 0)
            try validateJSONShape(json)
            let definition = try JSONDecoder().decode(Self.self, from: data)
            try definition.validate()
            return definition
        } catch let error as NativeAppError {
            throw error
        } catch let error as DecodingError {
            let path: [any CodingKey]
            switch error {
            case .keyNotFound(let key, let context): path = context.codingPath + [key]
            case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
                path = context.codingPath
            @unknown default: path = []
            }
            throw NativeAppError(.invalidDefinition, path: path.map(\.stringValue).joined(separator: "."))
        } catch {
            throw NativeAppError(.invalidDefinition)
        }
    }

    /// Codable ignores unknown keys by default. Reject them so unsupported actions,
    /// capabilities and load hooks never appear to have been accepted by the host.
    private static func validateJSONShape(_ json: Any) throws {
        func object(_ value: Any, keys: Set<String>?, path: String) throws -> [String: Any] {
            guard let object = value as? [String: Any] else { throw NativeAppError(.invalidDefinition, path: path) }
            if let keys, let extra = Set(object.keys).subtracting(keys).sorted().first {
                throw NativeAppError(.invalidDefinition, path: path + "." + extra)
            }
            return object
        }
        func binding(_ value: Any, path: String) throws {
            _ = try object(value, keys: ["literal", "state", "selection", "board"], path: path)
        }
        func checkNode(_ value: Any, path: String) throws {
            let node = try object(value, keys: nil, path: path)
            let keys: Set<String>
            switch node["type"] as? String {
            case "vstack", "hstack": keys = ["id", "type", "children"]
            case "text": keys = ["id", "type", "textKey", "binding", "style"]
            case "textField", "textEditor", "toggle", "filePicker": keys = ["id", "type", "textKey", "stateKey"]
            case "picker": keys = ["id", "type", "textKey", "stateKey", "options"]
            case "button": keys = ["id", "type", "textKey", "action"]
            case "list": keys = ["id", "type", "source"]
            case "table": keys = ["id", "type", "source"]
            case "resourcePicker": keys = ["id", "type", "textKey", "resource"]
            case "board": keys = ["id", "type", "board"]
            case "divider": keys = ["id", "type"]
            default: throw NativeAppError(.invalidDefinition, path: path + ".type")
            }
            _ = try object(node, keys: keys, path: path)
            if let value = node["binding"] { try binding(value, path: path + ".binding") }
            if let value = node["children"] {
                guard let children = value as? [Any] else { throw NativeAppError(.invalidDefinition, path: path + ".children") }
                for (index, child) in children.enumerated() { try checkNode(child, path: path + ".children[\(index)]") }
            }
        }
        let top = try object(json, keys: ["manifest", "i18n", "state", "dataSources", "views", "actions", "scripts", "capabilities", "boards"], path: "definition")
        if let boards = top["boards"] {
            for (key, value) in try object(boards, keys: nil, path: "boards") {
                let path = "boards." + key
                let board = try object(value, keys: ["columns", "rows", "persistent", "pieces", "goal"], path: path)
                _ = try object(board["goal"] as Any, keys: ["piece", "x", "y"], path: path + ".goal")
                guard let pieces = board["pieces"] as? [Any] else { throw NativeAppError(.invalidDefinition, path: path + ".pieces") }
                for (index, piece) in pieces.enumerated() {
                    _ = try object(piece, keys: ["id", "labelKey", "x", "y", "width", "height", "axis"], path: path + ".pieces[\(index)]")
                }
            }
        }
        if let capabilities = top["capabilities"] {
            for (key, value) in try object(capabilities, keys: nil, path: "capabilities") {
                _ = try object(value, keys: ["name", "version", "resource"], path: "capabilities." + key)
            }
        }
        _ = try object(top["manifest"] as Any, keys: ["id", "version", "dslVersion", "nameKey", "summaryKey", "icon", "width", "height", "dataVersion"], path: "manifest")
        for (key, field) in try object(top["state"] as Any, keys: nil, path: "state") {
            _ = try object(field, keys: ["initial", "persistent"], path: "state.\(key)")
        }
        for (key, source) in try object(top["dataSources"] as Any, keys: nil, path: "dataSources") {
            _ = try object(source, keys: ["kind", "searchKey", "pageSize", "collection"], path: "dataSources.\(key)")
        }
        for (key, value) in try object(top["actions"] as Any, keys: nil, path: "actions") {
            let path = "actions.\(key)"
            let action = try object(value, keys: ["type", "source", "stateKey", "value", "values", "fields", "script", "inputs", "resultBindings", "recordInputs", "fileInputs", "operation", "capability", "steps", "dataInputs", "board"], path: path)
            if let value = action["value"] { try binding(value, path: path + ".value") }
            for field in ["values", "inputs", "fileInputs"] {
                if let values = action[field] {
                    for (key, value) in try object(values, keys: nil, path: path + "." + field) {
                        try binding(value, path: path + "." + field + "." + key)
                    }
                }
            }
            if let inputs = action["recordInputs"] {
                for (key, input) in try object(inputs, keys: nil, path: path + ".recordInputs") {
                    _ = try object(input, keys: ["source", "limit"], path: path + ".recordInputs." + key)
                }
            }
        }
        if let scripts = top["scripts"] {
            for (key, script) in try object(scripts, keys: nil, path: "scripts") {
                _ = try object(script, keys: ["source", "inputTypes", "outputTypes", "requirements", "timeoutSeconds"], path: "scripts." + key)
            }
        }
        try checkNode(top["views"] as Any, path: "views")
    }

    public static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64
            && value.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
            && value.first != "-" && value.last != "-"
    }

    public func validate() throws {
        func require(_ valid: Bool, _ path: String) throws {
            if !valid { throw NativeAppError(.invalidDefinition, path: path) }
        }
        try require(Self.validID(id), "manifest.id")
        try require((1...4).contains(manifest.dslVersion), "manifest.dslVersion")
        try require(manifest.dslVersion >= 2 || scripts == nil, "scripts")
        try require(manifest.dslVersion >= 3 || capabilities == nil, "capabilities")
        try require(manifest.dslVersion >= 4 || boards == nil, "boards")
        try require((boards?.count ?? 0) <= 4, "boards")
        try require((capabilities?.count ?? 0) <= 16, "capabilities")
        for (key, capability) in capabilities ?? [:] {
            guard let descriptor = NativeAppCapabilityCatalog.descriptor(capability) else {
                throw NativeAppError(.invalidDefinition, path: "capabilities." + key)
            }
            try require(Self.validID(key), "capabilities." + key)
            try require(descriptor.resourceKind == nil ? capability.resource == nil : Self.validID(capability.resource ?? ""), "capabilities." + key + ".resource")
        }
        try require(dataVersion == 1, "manifest.dataVersion")
        try require((1...1_000_000).contains(manifest.version), "manifest.version")
        try require((480...1600).contains(manifest.width ?? 800), "manifest.width")
        try require((360...1200).contains(manifest.height ?? 600), "manifest.height")
        try require(!manifest.icon.isEmpty && manifest.icon.utf8.count <= 80, "manifest.icon")
        try require(Set(i18n.keys) == ["en", "zh-Hans", "zh-Hant"], "i18n")
        try require(state.count <= 32 && dataSources.count <= 8 && actions.count <= 32, "state/dataSources/actions")
        func label(_ key: String) throws {
            for language in ["en", "zh-Hans", "zh-Hant"] {
                try require(!(i18n[language]?[key]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true), "i18n.\(language).\(key)")
            }
        }
        for dictionary in i18n.values {
            try require(dictionary.count <= 256 && dictionary.allSatisfy { $0.key.utf8.count <= 80 && $0.value.utf8.count <= 8192 }, "i18n")
        }
        try label(manifest.nameKey)
        try label(manifest.summaryKey)
        for (key, board) in boards ?? [:] {
            try require(Self.validID(key), "boards." + key)
            try board.validate(path: "boards." + key)
            for piece in board.pieces { try label(piece.labelKey) }
        }
        for (key, field) in state {
            try require(Self.validID(key) && field.initial.isBounded, "state.\(key)")
        }
        func bindingType(_ binding: Binding, _ path: String) throws -> NativeAppValue.ValueType {
            try require([binding.literal != nil, binding.state != nil, binding.selection != nil, binding.board != nil].filter { $0 }.count == 1, path)
            if let literal = binding.literal {
                try require(literal.isBounded, path)
                return literal.valueType
            }
            if let key = binding.state {
                guard let field = state[key] else { throw NativeAppError(.invalidDefinition, path: path) }
                return field.initial.valueType
            }
            if let reference = binding.board {
                let parts = reference.split(separator: ".").map(String.init)
                try require(manifest.dslVersion >= 4 && parts.count == 2 && boards?[parts[0]] != nil, path)
                try require(["moves", "won", "canUndo", "canRedo"].contains(parts[1]), path)
                return parts[1] == "moves" ? .number : .bool
            }
            let parts = (binding.selection ?? "").split(separator: ".").map(String.init)
            let source = parts.first ?? ""
            let field = parts.last ?? ""
            let columns = actions.values.compactMap { action -> [String]? in
                guard action.type == .callCapability, action.source == source,
                      let capability = capabilities?[action.capability ?? ""] else { return nil }
                return NativeAppCapabilityCatalog.descriptor(capability)?.tableColumns
            }.flatMap { $0 }
            try require(parts.count == 2 && dataSources[source] != nil
                        && (["title", "content"].contains(field) || (manifest.dslVersion >= 3 && columns.contains(field))), path)
            return .string
        }
        for (key, source) in dataSources {
            try require(source.kind != .result || manifest.dslVersion >= 3, "dataSources." + key)
            try require(Self.validID(key) && (1...50).contains(source.pageSize), "dataSources.\(key)")
            try require(source.kind == .records ? Self.validID(source.collection ?? key) : source.collection == nil, "dataSources.\(key).collection")
            if let search = source.searchKey {
                try require(state[search]?.initial.valueType == .string, "dataSources.\(key).searchKey")
            }
        }
        try require((scripts?.count ?? 0) <= 16, "scripts")
        for (key, script) in scripts ?? [:] {
            let path = "scripts." + key
            try require(Self.validID(key) && !script.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && script.source.utf8.count <= 64 * 1024, path + ".source")
            try require(script.inputTypes.count <= 32 && script.outputTypes.count <= 32
                        && script.inputTypes.keys.allSatisfy(Self.validID) && script.outputTypes.keys.allSatisfy(Self.validID), path)
            try require((1...120).contains(script.timeoutSeconds ?? 30), path + ".timeoutSeconds")
            let requirements = script.requirements ?? []
            try require(requirements.count <= 32 && requirements.allSatisfy {
                !$0.isEmpty && $0.utf8.count <= 200 && !$0.contains("\n") && !$0.contains("\r")
                    && SkillRequirements.parse($0).requirements.count == 1 && SkillRequirements.parse($0).rejected.isEmpty
            }, path + ".requirements")
        }
        for (key, action) in actions {
            let path = "actions.\(key)"
            try require(Self.validID(key), path)
            let isBoardAction = [.boardUndo, .boardRedo, .boardReset].contains(action.type)
            try require(isBoardAction || action.board == nil, path + ".board")
            try require(action.type == .transformState || action.operation == nil, path + ".operation")
            try require(action.type == .callCapability || action.capability == nil, path + ".capability")
            try require(action.type == .sequence || action.steps == nil, path + ".steps")
            try require(action.type == .runPython || action.dataInputs == nil, path + ".dataInputs")
            if action.type != .runPython && action.type != .callCapability {
                try require(action.script == nil && action.inputs == nil && action.resultBindings == nil
                            && action.recordInputs == nil && action.fileInputs == nil, path)
            }
            switch action.type {
            case .boardUndo, .boardRedo, .boardReset:
                try require(manifest.dslVersion >= 4 && boards?[action.board ?? ""] != nil, path + ".board")
                try require(action.source == nil && action.stateKey == nil && action.value == nil && action.values == nil && action.fields == nil, path)
            case .callCapability:
                guard manifest.dslVersion >= 3, let capability = capabilities?[action.capability ?? ""],
                      let descriptor = NativeAppCapabilityCatalog.descriptor(capability) else { throw NativeAppError(.invalidDefinition, path: path) }
                try require(action.script == nil && action.recordInputs == nil && action.fileInputs == nil
                    && action.stateKey == nil && action.value == nil && action.values == nil && action.fields == nil, path)
                try require(Set((action.inputs ?? [:]).keys) == Set(descriptor.inputs.keys), path + ".inputs")
                for (key, value) in action.inputs ?? [:] { try require(try bindingType(value, path) == descriptor.inputs[key], path + ".inputs." + key) }
                try require(descriptor.tableColumns == nil ? action.source == nil : dataSources[action.source ?? ""]?.kind == .result, path + ".source")
                for (key, output) in action.resultBindings ?? [:] {
                    try require(descriptor.outputs[output] != nil && state[key]?.initial.valueType == descriptor.outputs[output], path + ".resultBindings")
                }
            case .sequence:
                let steps = action.steps ?? []
                try require(manifest.dslVersion >= 3 && !steps.isEmpty && steps.count <= 16, path + ".steps")
                try require(action.source == nil && action.stateKey == nil && action.value == nil && action.values == nil && action.fields == nil, path)
                for step in steps {
                    guard let child = actions[step], [.callCapability, .runPython, .saveFile, .saveRecord, .saveKnowledge].contains(child.type) else {
                        throw NativeAppError(.invalidDefinition, path: path + ".steps")
                    }
                }
            case .transformState:
                try require(state[action.stateKey ?? ""]?.initial.valueType == .string && action.operation != nil, path)
                try require(action.source == nil && action.values == nil && action.fields == nil, path)
                if action.operation == .removeLast {
                    try require(action.value == nil, path + ".value")
                } else {
                    guard let binding = action.value else { throw NativeAppError(.invalidDefinition, path: path + ".value") }
                    try require(try bindingType(binding, path) == .string, path + ".value")
                }
            case .runPython:
                guard manifest.dslVersion >= 2, let script = scripts?[action.script ?? ""] else {
                    throw NativeAppError(.invalidDefinition, path: path + ".script")
                }
                try require(action.source == nil && action.stateKey == nil && action.value == nil
                            && action.values == nil && action.fields == nil, path)
                let inputs = action.inputs ?? [:]
                try require(Set(inputs.keys) == Set(script.inputTypes.keys), path + ".inputs")
                for (key, binding) in inputs {
                    try require(try bindingType(binding, path + ".inputs." + key) == script.inputTypes[key], path + ".inputs." + key)
                }
                try require((action.resultBindings?.count ?? 0) <= 32, path + ".resultBindings")
                for (key, output) in action.resultBindings ?? [:] {
                    guard let field = state[key], let type = script.outputTypes[output] else {
                        throw NativeAppError(.invalidDefinition, path: path + ".resultBindings." + key)
                    }
                    try require(field.initial.valueType == type, path + ".resultBindings." + key)
                }
                try require((action.recordInputs?.count ?? 0) <= 8 && (action.fileInputs?.count ?? 0) <= 8, path)
                for (key, input) in action.recordInputs ?? [:] {
                    try require(Self.validID(key) && dataSources[input.source]?.kind == .records
                                && (1...1000).contains(input.limit), path + ".recordInputs." + key)
                }
                for (key, binding) in action.fileInputs ?? [:] {
                    try require(Self.validID(key) && (try bindingType(binding, path)) == .string, path + ".fileInputs." + key)
                }
                try require(manifest.dslVersion >= 3 || action.dataInputs == nil, path + ".dataInputs")
                try require((action.dataInputs?.count ?? 0) <= 8, path + ".dataInputs")
                for (key, source) in action.dataInputs ?? [:] {
                    try require(Self.validID(key) && dataSources[source]?.kind == .result, path + ".dataInputs." + key)
                }
            case .refresh:
                try require(dataSources[action.source ?? ""] != nil && action.values == nil && action.value == nil && action.stateKey == nil && action.fields == nil, path)
            case .setState:
                guard let field = state[action.stateKey ?? ""], let binding = action.value else {
                    throw NativeAppError(.invalidDefinition, path: path)
                }
                try require(try bindingType(binding, path) == field.initial.valueType, path)
                try require(action.source == nil && action.values == nil && action.fields == nil, path)
            case .saveKnowledge:
                try require(Set(action.values?.keys.map { $0 } ?? []) == ["title", "content"], path)
                for binding in (action.values ?? [:]).values { try require(try bindingType(binding, path) == .string, path) }
                try require(action.source == nil && action.value == nil && action.stateKey == nil && action.fields == nil, path)
            case .saveRecord:
                try require(dataSources[action.source ?? ""]?.kind == .records, path + ".source")
                let values = action.values ?? [:]
                try require(values["title"] != nil && values["content"] != nil && values.count <= 32, path + ".values")
                for (key, binding) in values {
                    try require(Self.validID(key), path + ".values")
                    let type = try bindingType(binding, path)
                    if key == "title" || key == "content" { try require(type == .string, path) }
                }
                try require(action.value == nil && action.stateKey == nil && action.fields == nil, path)
            case .deleteRecord:
                try require(dataSources[action.source ?? ""]?.kind == .records && action.values == nil
                    && action.value == nil && action.stateKey == nil && action.fields == nil, path)
            case .newRecord, .editRecord:
                try require(dataSources[action.source ?? ""]?.kind == .records, path + ".source")
                let fields = action.fields ?? [:]
                try require(Set(fields.keys) == ["title", "content"] && Set(fields.values).count == 2, path + ".fields")
                for key in fields.values { try require(state[key]?.initial.valueType == .string, path + ".fields") }
                try require(action.values == nil && action.value == nil && action.stateKey == nil, path)
            case .saveFile:
                try require(Set(action.values?.keys.map { $0 } ?? []) == ["name", "content"], path)
                for binding in (action.values ?? [:]).values { try require(try bindingType(binding, path) == .string, path) }
                try require(action.source == nil && action.value == nil && action.stateKey == nil && action.fields == nil, path)
            }
        }
        var ids: Set<String> = []
        var nodeCount = 0
        func node(_ item: Node, depth: Int) throws {
            nodeCount += 1
            let path = "views.\(item.id)"
            try require(depth <= 12 && nodeCount <= 128 && Self.validID(item.id) && ids.insert(item.id).inserted, path)
            if let key = item.textKey { try label(key) }
            if let binding = item.binding { _ = try bindingType(binding, path + ".binding") }
            let isLayout = item.type == .vstack || item.type == .hstack
            try require(isLayout || (item.children ?? []).isEmpty, path + ".children")
            switch item.type {
            case .text:
                try require((item.textKey != nil) != (item.binding != nil), path)
            case .textField, .textEditor, .picker, .toggle, .filePicker:
                if item.type == .filePicker { try require(manifest.dslVersion >= 2, path + ".type") }
                try require(item.textKey != nil, path + ".textKey")
                let expected: NativeAppValue.ValueType = item.type == .toggle ? .bool : .string
                try require(state[item.stateKey ?? ""]?.initial.valueType == expected, path + ".stateKey")
                if item.type == .picker {
                    let options = item.options ?? []
                    try require(!options.isEmpty && options.count <= 32 && Set(options).count == options.count, path + ".options")
                    for option in options { try label(option) }
                    try require(options.contains(state[item.stateKey ?? ""]?.initial.string ?? ""), path + ".stateKey")
                }
            case .button:
                try require(item.textKey != nil && actions[item.action ?? ""] != nil, path)
            case .list:
                try require(dataSources[item.source ?? ""] != nil, path + ".source")
            case .table:
                try require(manifest.dslVersion >= 3 && dataSources[item.source ?? ""]?.kind == .result, path + ".source")
            case .resourcePicker:
                try require(manifest.dslVersion >= 3 && item.textKey != nil && capabilities?.values.contains(where: { $0.resource == item.resource && $0.resource != nil }) == true, path + ".resource")
            case .board:
                try require(manifest.dslVersion >= 4 && boards?[item.board ?? ""] != nil, path + ".board")
            case .vstack, .hstack, .divider: break
            }
            for child in item.children ?? [] { try node(child, depth: depth + 1) }
        }
        try node(views, depth: 0)
        try require(try NativeAppDraftState(values: state.mapValues(\.initial), boards: (boards ?? [:]).mapValues(\.initialProgress)).encoded().count <= Self.maximumStateBytes, "state")
        let data = try encoded()
        try require(data.count <= Self.maximumBytes, "definition")
        try Self.validateJSONShape(JSONSerialization.jsonObject(with: data))
    }

    public var persistentSchema: [String: NativeAppValue.ValueType] {
        state.filter { $0.value.persistent }.mapValues { $0.initial.valueType }
    }

    /// Adding persistent fields is compatible: their declared initial values are
    /// used until first save. Existing keys/types cannot disappear or change.
    public func acceptsStateSchema(of previous: NativeAppDefinition) -> Bool {
        previous.persistentSchema.allSatisfy { persistentSchema[$0.key] == $0.value }
            && (previous.boards ?? [:]).filter { $0.value.persistent }.allSatisfy { key, old in
                boards?[key]?.persistent == true && boards?[key]?.acceptsProgress(of: old) == true
            }
    }

    public func hasSamePersistentSchema(as other: NativeAppDefinition) -> Bool {
        acceptsStateSchema(of: other) && other.acceptsStateSchema(of: self)
    }

    public func validateSavedDraft(_ draft: NativeAppDraftState) throws {
        try validateSavedState(draft.values)
        for (key, progress) in draft.boards {
            guard let board = boards?[key], board.persistent else { throw NativeAppError(.incompatibleState, path: "boards." + key) }
            do { try board.validateProgress(progress) }
            catch { throw NativeAppError(.incompatibleState, path: "boards." + key) }
        }
    }

    public func validateRuntimeBoards(_ progress: [String: NativeAppBoardProgress]) throws {
        guard Set(progress.keys) == Set((boards ?? [:]).keys) else { throw NativeAppError(.incompatibleState) }
        for (key, value) in progress { try boards?[key]?.validateProgress(value) }
    }

    public func validateSavedState(_ values: [String: NativeAppValue]) throws {
        guard values.allSatisfy({ key, value in persistentSchema[key] == value.valueType && value.isBounded }) else {
            throw NativeAppError(.incompatibleState)
        }
        func check(_ node: Node) throws {
            if node.type == .picker, let key = node.stateKey, let value = values[key] {
                guard node.options?.contains(value.string) == true else { throw NativeAppError(.incompatibleState, path: "state.\(key)") }
            }
            for child in node.children ?? [] { try check(child) }
        }
        try check(views)
    }

    public func validateRuntimeState(_ values: [String: NativeAppValue]) throws {
        guard Set(values.keys) == Set(state.keys), values.allSatisfy({
            state[$0.key]?.initial.valueType == $0.value.valueType && $0.value.isBounded
        }) else { throw NativeAppError(.incompatibleState) }
        func check(_ node: Node) throws {
            if node.type == .picker, let key = node.stateKey, let value = values[key], node.options?.contains(value.string) != true {
                throw NativeAppError(.incompatibleState, path: "state." + key)
            }
            for child in node.children ?? [] { try check(child) }
        }
        try check(views)
    }
}

public enum NativeAppValue: Codable, Equatable, Sendable {
    public enum ValueType: String, Codable, Sendable { case string, bool, number }
    case string(String), bool(Bool), number(Double)
    public var valueType: ValueType {
        switch self { case .string: .string; case .bool: .bool; case .number: .number }
    }
    public var string: String {
        switch self { case .string(let value): value; case .bool(let value): String(value); case .number(let value): String(value) }
    }
    public var isBounded: Bool {
        switch self { case .string(let value): value.utf8.count <= 32 * 1024; case .number(let value): value.isFinite; case .bool: true }
    }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else { self = .number(try container.decode(Double.self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self { case .string(let value): try container.encode(value); case .bool(let value): try container.encode(value); case .number(let value): try container.encode(value) }
    }
}

public struct NativeAppError: Error, Sendable, Equatable {
    public enum Code: String, Sendable {
        case invalidDefinition, tooLarge, unsafePath, unavailable, conflict, incompatibleState, missing, capacity, storage, generation, corruptData, spaceMismatch
    }
    public let code: Code
    public let path: String
    public var localizationKey: String { "apps.error.\(code.rawValue)" }
    public init(_ code: Code, path: String = "") { self.code = code; self.path = path }
}
