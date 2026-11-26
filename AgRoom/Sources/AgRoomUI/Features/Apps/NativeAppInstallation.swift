import Foundation
import Observation
import AgRoomCore

/// Preview is read-only. Only the user's install button calls confirmInstallation().
@MainActor @Observable
final class NativeAppInstallation {
    let definition: NativeAppDefinition
    private let store: NativeAppStore?
    private(set) var current: NativeAppSnapshot?
    private(set) var ready = false
    private(set) var saving = false
    private(set) var error: String?
    private(set) var diff: String?
    private(set) var oldDefinitionJSON: String?
    var unchanged: Bool { current?.isInstalled == true && current?.definition == definition }

    init(definition: NativeAppDefinition, store: NativeAppStore?) { self.definition = definition; self.store = store }

    func load() async {
        ready = false; error = nil
        guard let store else { error = L.string("apps.error.unavailable"); return }
        do {
            try definition.validate()
            try await NativeAppScriptService.validateSyntax(definition, space: store.space)
            current = try await store.loadIncludingRetained(id: definition.id)
            if let current, current.definition != definition {
                guard definition.acceptsStateSchema(of: current.definition),
                      current.definition.dataVersion == definition.dataVersion else { throw NativeAppError(.incompatibleState) }
                guard !current.isInstalled || definition.manifest.version > current.definition.manifest.version else { throw NativeAppError(.conflict) }
                let definition = definition
                let comparison = try await Task.detached {
                    let old = String(decoding: try current.definition.encoded(), as: UTF8.self)
                    let new = String(decoding: try definition.encoded(), as: UTF8.self)
                    return (old, FileChangePreviewBuilder.textDiff(old: old, new: new))
                }.value
                oldDefinitionJSON = comparison.0; diff = comparison.1
            }
            ready = !Task.isCancelled
        } catch let issue as NativeAppError where issue.code == .missing { ready = !Task.isCancelled }
        catch { if !Task.isCancelled { self.error = L.errorDescription(error) } }
    }

    func confirmInstallation() async throws -> NativeAppSnapshot {
        guard ready, !saving, error == nil, let store else { throw NativeAppError(.unavailable) }
        saving = true
        defer { saving = false }
        do {
            try Task.checkCancellation()
            if !unchanged { try await store.install(definition, replacing: current?.revision) }
            let installed = try await store.load(id: definition.id)
            current = installed
            return installed
        } catch {
            self.error = L.errorDescription(error)
            throw error
        }
    }
}
