import Foundation
import AgRoomCore

/// Load the finite DSL on demand. Generation stays in the visible, cancellable conversation.
struct NativeAppSchemaTool: DispatcherTool {
    let space: AppSpace
    private let makeStore: @MainActor @Sendable () -> NativeAppStore?
    init(hub: Hub, space: AppSpace) { self.init(space: space, makeStore: { hub.makeNativeAppStore(for: space) }) }
    init(space: AppSpace, makeStore: @escaping @MainActor @Sendable () -> NativeAppStore?) {
        self.space = space; self.makeStore = makeStore
    }
    var requiresConfirmation: Bool { false }
    var sideEffectClass: ToolSideEffectClass { .readOnly }
    var definition: ToolDefinition {
        ToolDefinition(name: "apps_schema", description: "Read the supported AgRoom native app DSL before creating an app. Start with section=core (default). "
            + "Read section=example for note, calculator, python, database or slidingPuzzle; section=python for scripts; section=capabilities for DSL v3 host tools and MySQL; section=boards for DSL v4 interactive sliding-block games. "
            + "For an update, use section=current with app_id to read its full current definition and preserve persistent state. "
            + "Results are paged; follow next_offset until complete, then stop reading that section. "
            + "Then author the complete definition in this conversation and submit it to apps_prepare as definition_json. "
            + "Do not create Swift code or a standalone macOS app.",
            parametersSchemaJSON: #"{"type":"object","properties":{"section":{"type":"string","enum":["core","python","capabilities","boards","example","current"],"description":"Defaults to core"},"example":{"type":"string","enum":["note","calculator","python","database","slidingPuzzle"]},"app_id":{"type":"string","description":"Required for section=current"},"offset":{"type":"integer","minimum":0,"description":"Use the previous response's next_offset; defaults to 0"}},"additionalProperties":false}"#)
    }

    func execute(argumentsJSON: String) async throws -> String {
        try Task.checkCancellation()
        let args = ToolArguments.parse(argumentsJSON)
        let id = ToolArguments.string(args, "app_id")
        let section = args["section"] == nil ? "core" : ToolArguments.string(args, "section")
        let result: String
        switch section {
        case "core": result = NativeAppGenerator.designInstructions
        case "python": result = NativeAppGenerator.pythonInstructions
        case "boards": result = NativeAppGenerator.boardInstructions
        case "capabilities":
            result = NativeAppGenerator.capabilityInstructions + "\nCatalog:\n" + String(decoding: try JSONEncoder().encode(NativeAppCapabilityCatalog.all), as: UTF8.self)
        case "example":
            let example: NativeAppDefinition
            switch args["example"] == nil ? "note" : ToolArguments.string(args, "example") {
            case "note": example = try NativeAppTemplates.note()
            case "calculator": example = try NativeAppTemplates.calculator()
            case "python": example = try NativeAppTemplates.textStatistics()
            case "database": example = try NativeAppTemplates.databaseMetadata()
            case "slidingPuzzle": example = try NativeAppTemplates.slidingPuzzle()
            default: throw ToolExecutionFailure(message: "Choose example=note, calculator, python, database or slidingPuzzle.")
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            result = String(decoding: try encoder.encode(example), as: UTF8.self)
        case "current":
            guard !id.isEmpty else { throw ToolExecutionFailure(message: "section=current requires app_id.") }
            guard let store = await makeStore() else {
                throw NativeAppError(.unavailable)
            }
            let existing = try await store.load(id: id).definition
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            result = String(decoding: try encoder.encode(existing), as: UTF8.self)
        default: throw ToolExecutionFailure(message: "Choose section=core, python, capabilities, boards, example or current.")
        }
        let number = args["offset"] as? NSNumber
        let offset = number?.intValue ?? 0
        guard args["offset"] == nil || (number != nil && CFGetTypeID(number) != CFBooleanGetTypeID()
              && number?.doubleValue == Double(offset)), (0...result.count).contains(offset) else {
            throw ToolExecutionFailure(message: "offset must be a valid character offset from the previous response.")
        }
        let page = String(result.dropFirst(offset).prefix(4500))
        let end = offset + page.count
        return "section=\(section); offset=\(offset); total_chars=\(result.count); next_offset=\(end < result.count ? String(end) : "none")\n"
            + page + "\n[end of page]"
    }
}

/// Validates model-authored data and saves internal draft state. Installation remains explicit.
struct NativeAppPrepareTool: DispatcherTool {
    let space: AppSpace
    private let makeStore: @MainActor @Sendable () -> NativeAppStore?
    private let publish: @MainActor @Sendable (NativeAppDefinition, String?) async throws -> Void

    init(hub: Hub, space: AppSpace, sourceSessionID: UUID? = nil) {
        self.init(space: space, makeStore: { hub.makeNativeAppStore(for: space) }, publish: { definition, updating in
            guard let store = hub.makeNativeAppDraftStore(for: space) else { throw NativeAppError(.unavailable) }
            let draft = try await store.save(definition, sourceSessionID: sourceSessionID, updatingAppID: updating)
            guard !Task.isCancelled else { return }
            NativeAppDraftCenter.shared.requestPreview(id: draft.id, space: space)
            if hub.spaceStore.current == space { AppNavigation.shared.open(page: .apps) }
        })
    }

    init(space: AppSpace, makeStore: @escaping @MainActor @Sendable () -> NativeAppStore?,
         publish: @escaping @MainActor @Sendable (NativeAppDefinition, String?) async throws -> Void) {
        self.space = space
        self.makeStore = makeStore
        self.publish = publish
    }

    var requiresConfirmation: Bool { false }
    // Like coding task notes, this is internal task state, not a user business mutation.
    var permissionClass: PermissionClass { .readOnly }
    var sideEffectClass: ToolSideEffectClass { .idempotentWrite }
    var definition: ToolDefinition {
        ToolDefinition(name: "apps_prepare", description: "Validate a complete native AgRoom app definition authored in this conversation. "
            + "First call apps_schema to learn the finite DSL. Pass the full JSON string in definition_json; a requirement alone is not a definition. "
            + "For updates also pass app_id, preserving its id, dataVersion and persistent state schema and increasing its version. "
            + "Saves a recoverable pending draft in the originating space and opens its preview in Applications. The user must explicitly install it. "
            + "No LLM call, installation, arbitrary code or SQL is executed by this tool. Correct any validation errors and resubmit.",
            parametersSchemaJSON: #"{"type":"object","properties":{"definition_json":{"type":"string","description":"Complete app JSON matching apps_schema, not a description or file path"},"app_id":{"type":"string","description":"Existing app id to update; omit to create"}},"required":["definition_json"]}"#)
    }

    func execute(argumentsJSON: String) async throws -> String {
        try Task.checkCancellation()
        let args = ToolArguments.parse(argumentsJSON)
        let json = ToolArguments.string(args, "definition_json")
        guard !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.configurationError(reason: "apps_prepare requires definition_json. Read apps_schema, author the app JSON in this conversation, then resubmit. No separate model generation is started.")
        }
        let id = ToolArguments.string(args, "app_id")
        var existing: NativeAppDefinition?
        if !id.isEmpty {
            guard let store = await makeStore() else { throw NativeAppError(.unavailable) }
            existing = try await store.load(id: id).definition
        }
        let definition = try NativeAppGenerator.validateOutput(json, updating: existing)
        do { try await NativeAppScriptService.validateSyntax(definition, space: space) }
        catch let error as ScriptIsolationError {
            throw ToolExecutionFailure(message: "App syntax-check isolation failed before parsing the Python source. "
                + "This check does not read the conversation workspace, so do not attribute it to that workspace or request rebinding without evidence. "
                + error.localizedDescription)
        }
        try Task.checkCancellation()
        try await publish(definition, existing?.id)
        return "Validated app draft '\(definition.id)' was saved in Applications in its originating space (\(space.rawValue)) and can be reopened after restart. The user must preview and explicitly install it. Nothing was installed."
    }
}
