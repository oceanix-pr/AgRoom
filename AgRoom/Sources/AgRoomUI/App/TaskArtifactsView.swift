import AppKit
import Combine
import SwiftUI
import AgRoomCore

enum ArtifactExportChoice: Sendable {
    case selected(URL), cancelled, failed

    @MainActor static func choose(_ panel: NSSavePanel) async -> Self {
        let response = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        if response == .OK, let url = panel.url { return .selected(url) }
        return response == .cancel ? .cancelled : .failed
    }
}

/// Group receipts only within the supplied result, never by filename or by a
/// newer version from another run. Grouping does not authorize file access.
struct TaskArtifactGroup: Identifiable, Sendable {
    struct ID: Hashable, Sendable {
        let space: AppSpace?
        let path: String
    }

    let id: ID
    let revisions: [TaskArtifact]
    var newest: TaskArtifact { revisions[0] }

    static func collect(_ artifacts: [TaskArtifact]) -> [Self] {
        var order: [ID] = []
        var members: [ID: [TaskArtifact]] = [:]
        var positions: [ID: [String: Int]] = [:]
        for artifact in artifacts {
            let key = ID(space: artifact.sourceSpace, path: URL(fileURLWithPath: artifact.path).standardizedFileURL.path)
            if members[key] == nil { order.append(key) }
            if let index = positions[key]?[artifact.id] {
                members[key]?[index] = artifact
            } else {
                positions[key, default: [:]][artifact.id] = members[key, default: []].count
                members[key, default: []].append(artifact)
            }
        }
        return order.map { Self(id: $0, revisions: ordered(members[$0] ?? [])) }
    }

    static func ordered(_ artifacts: [TaskArtifact]) -> [TaskArtifact] {
        let numbered = artifacts.allSatisfy { $0.version != nil }
        let dated = artifacts.allSatisfy { $0.createdAt != nil }
        return artifacts.enumerated().sorted { lhs, rhs in
            if numbered, lhs.element.version != rhs.element.version {
                return (lhs.element.version ?? 0) > (rhs.element.version ?? 0)
            }
            if dated, lhs.element.createdAt != rhs.element.createdAt {
                return (lhs.element.createdAt ?? .distantPast) > (rhs.element.createdAt ?? .distantPast)
            }
            // Legacy and failed recordings have no ordinal/date. Preserve the
            // receipt order so an unsaved final edit cannot look like success.
            return lhs.offset > rhs.offset
        }.map(\.element)
    }

    static func displayPaths(_ groups: [Self], roots: [URL]) -> [ID: String] {
        let roots = roots.map { $0.standardizedFileURL.path }.sorted { $0.count > $1.count }
        let paths = groups.map { group in
            let path = group.id.path
            return roots.first(where: { path.hasPrefix($0 + "/") }).map { String(path.dropFirst($0.count + 1)) } ?? path
        }
        let counts = Dictionary(grouping: paths, by: { $0 }).mapValues(\.count)
        return Dictionary(uniqueKeysWithValues: zip(groups, paths).map { group, path in
            (group.id, counts[path] == 1 ? path : group.id.path)
        })
    }
}

struct TaskArtifactsView: View {
    let artifacts: [TaskArtifact]
    let roots: [URL]
    var store: TaskArtifactStore? = nil
    var reviewStart: TaskArtifactGroup.ID? = nil
    var fullResultForExport: [TaskArtifact]? = nil
    var onUse: (TaskArtifact) -> Void = { _ in }
    var onContinueSnapshot: ((TaskArtifact, URL) -> Void)? = nil
    var onSelectVersion: ((TaskArtifactVersion) -> Void)? = nil
    var makeSavePanel: () -> NSSavePanel = { NSSavePanel() }
    var makeFolderPanel: () -> NSOpenPanel = { NSOpenPanel() }
    var chooseExportDestination: @MainActor (NSSavePanel) async -> ArtifactExportChoice = { await ArtifactExportChoice.choose($0) }
    let onContinue: (TaskArtifact) -> Void
    @State private var previewURL: URL?
    @State private var previewPin: TaskArtifactPreviewPin?
    @State private var errorText: String?
    @State private var busy = false
    @State private var histories: [TaskArtifactGroup.ID: [TaskArtifactVersion]] = [:]
    @State private var inputs: [String: [TaskArtifactVersion]] = [:]
    @State private var selected: [TaskArtifactGroup.ID: TaskArtifact] = [:]
    @State private var expanded: Set<TaskArtifactGroup.ID> = []
    @State private var expandedDiffs: Set<TaskArtifactGroup.ID> = []
    @State private var comparisons: [String: TaskArtifactComparison] = [:]
    @State private var comparisonErrors: Set<String> = []
    @State private var diffTarget: DiffTarget?
    @State private var diffPins: [TaskArtifactGroup.ID: TaskArtifactPreviewPin] = [:]
    @State private var diffSheetPin: TaskArtifactPreviewPin?
    @State private var latest: [String: TaskArtifact] = [:]
    @State private var unavailable: Set<String> = []
    @State private var metadataGeneration = UUID()
    @State private var visibleCount = 5
    @State private var presentationID = UUID()
    @State private var isVisible = false
    @State private var exportReceipt: ExportReceipt?
    @State private var activeExportPanel: NSSavePanel?
    @State private var reviewedFile: TaskArtifactGroup.ID?
    @Environment(\.dismiss) private var dismiss
    private struct ExportReceipt {
        let destination: URL
        let count: Int
    }
    private struct DiffTarget: Identifiable {
        let artifact: TaskArtifact
        let comparison: TaskArtifactComparison
        var id: String { artifact.id }
    }

    private var groups: [TaskArtifactGroup] { TaskArtifactGroup.collect(artifacts) }

    var body: some View {
        let groups = groups
        VStack(alignment: .leading, spacing: MeetSpacing.sm) {
            if let reviewStart {
                review(groups, startingAt: reviewStart)
            } else {
                artifactHeader(fileCount: groups.count)
                let repeatedNames = Set(Dictionary(grouping: groups, by: { $0.newest.name }).filter { $0.value.count > 1 }.keys)
                ForEach(Array(groups.prefix(visibleCount))) { group in
                    artifactCard(group, showParentPath: repeatedNames.contains(group.newest.name))
                }
                if groups.count > 5 {
                    HStack {
                        if groups.count > visibleCount {
                            Button(L.format("product.artifact.show_more", min(30, groups.count - visibleCount))) { visibleCount += 30 }
                        }
                        if visibleCount > 5 {
                            Button(L.string("product.artifact.show_less")) { visibleCount = 5 }
                        }
                    }.font(MeetTypography.secondary).buttonStyle(.link)
                }
            }
            if busy { ProgressView().controlSize(.small) }
            if let receipt = exportReceipt {
                VStack(alignment: .leading, spacing: MeetSpacing.xs) {
                    HStack {
                        Label {
                            Text(L.format("product.artifact.export.success", receipt.count))
                        } icon: {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }.font(MeetTypography.control)
                        Spacer(minLength: 0)
                        Button(L.string("files.reveal")) { NSWorkspace.shared.activateFileViewerSelecting([receipt.destination]) }
                            .controlSize(.small)
                    }
                    Text(receipt.destination.lastPathComponent).font(MeetTypography.secondary).foregroundStyle(.secondary)
                        .lineLimit(1).textSelection(.enabled).help(receipt.destination.path)
                        .fixedSize(horizontal: false, vertical: true)
                }.fixedSize(horizontal: false, vertical: true)
            }
            if let errorText { Text(errorText).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }.frame(maxWidth: reviewStart == nil ? MeetLayout.artifactListMaxWidth : .infinity, alignment: .leading)
        .sheet(isPresented: Binding(get: { previewURL != nil }, set: { if !$0 { closePreview() } }), onDismiss: closePreview) {
            if let url = previewURL { FilePreviewSheet(url: url, onClose: closePreview) }
        }
        .sheet(item: $diffTarget, onDismiss: closeDiffSheet) { target in
            ArtifactDiffSheet(artifact: target.artifact, comparison: target.comparison, onClose: closeDiffSheet)
        }
        .onAppear { isVisible = true; presentationID = UUID(); busy = false }
        .onDisappear {
            isVisible = false; presentationID = UUID(); busy = false; closePreview(); exportReceipt = nil
            for pin in diffPins.values { pin.release() }
            diffPins.removeAll(); expandedDiffs.removeAll(); closeDiffSheet(); comparisons.removeAll(); comparisonErrors.removeAll()
            if let panel = activeExportPanel, panel.isVisible { panel.cancel(nil) }
            activeExportPanel = nil
        }
        .task(id: presentationID.uuidString + metadataIDs.map(\.uuidString).sorted().joined()) { await refreshMetadata() }
        .onReceive(NotificationCenter.default.publisher(for: TaskArtifactStore.didChange).receive(on: RunLoop.main)) { notification in
            guard notification.object as? String == store?.space.rawValue, isVisible else { return }
            Task { await refreshMetadata() }
        }
    }

    private func review(_ groups: [TaskArtifactGroup], startingAt start: TaskArtifactGroup.ID) -> some View {
        let current = reviewedFile ?? start
        let paths = TaskArtifactGroup.displayPaths(groups, roots: roots)
        return VStack(alignment: .leading, spacing: MeetSpacing.md) {
            HStack {
                Text(L.string("product.edits.review")).font(.headline)
                Spacer()
                if groups.count > 1 || fullResultForExport != nil {
                    Button(L.string("product.artifact.exportAll")) { exportAll() }.disabled(busy)
                }
                Button(L.string("common.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HSplitView {
                List(groups, selection: Binding(get: { current as TaskArtifactGroup.ID? }, set: { reviewedFile = $0 })) { group in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.newest.name).lineLimit(1).truncationMode(.middle)
                        Text(paths[group.id] ?? group.id.path).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.middle)
                    }.tag(group.id).help(group.id.path)
                }.frame(minWidth: 145, idealWidth: 200, maxWidth: 280)
                if let group = groups.first(where: { $0.id == current }) {
                    ScrollView {
                        artifactCard(group, showParentPath: false).padding(.leading, MeetSpacing.sm)
                    }.frame(minWidth: 330, maxWidth: .infinity)
                    .id(group.id)
                }
            }
        }
    }

    private func displayedArtifact(in group: TaskArtifactGroup) -> TaskArtifact {
        let picked = selected[group.id] ?? group.newest
        return latest[picked.id] ?? picked
    }

    private func artifactHeader(fileCount: Int) -> some View {
        let canExportAll = fileCount > 1 || fullResultForExport != nil
        let heading = HStack(spacing: MeetSpacing.sm) {
            Label(L.string("product.artifact.results"), systemImage: "doc.on.doc").font(MeetTypography.listTitle)
            Text(fileCount == 1 ? L.string("product.artifact.file_count.one") : L.format("product.artifact.file_count", fileCount))
                .font(MeetTypography.secondary).foregroundStyle(.secondary)
        }.fixedSize()
        let export = Button(L.string("product.artifact.exportAll")) { exportAll() }
            .font(MeetTypography.secondary).buttonStyle(.link).disabled(busy)
            .help(L.string("product.artifact.exportAll.help")).fixedSize()
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: MeetSpacing.sm) {
                heading
                Spacer(minLength: 0)
                if canExportAll { export }
            }
            VStack(alignment: .leading, spacing: MeetSpacing.sm) {
                heading
                if canExportAll { export }
            }
        }
    }

    private func artifactCard(_ group: TaskArtifactGroup, showParentPath: Bool) -> some View {
        let artifact = displayedArtifact(in: group)
        let current = currentURL(artifact)
        let readable = canResolve(artifact, current: current)
        return VStack(alignment: .leading, spacing: MeetSpacing.sm) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: MeetSpacing.md) {
                    artifactIdentity(artifact, group: group, showParentPath: showParentPath).frame(minWidth: 220, alignment: .leading)
                    Spacer(minLength: 0)
                    artifactActions(artifact, group: group, current: current, readable: readable).fixedSize()
                }
                VStack(alignment: .leading, spacing: MeetSpacing.sm) {
                    artifactIdentity(artifact, group: group, showParentPath: showParentPath)
                    artifactActions(artifact, group: group, current: current, readable: readable)
                }
            }
            changeSummary(artifact)
            artifactNotice(artifact, readable: readable)
            if expandedDiffs.contains(group.id), store != nil {
                Divider()
                if let comparison = comparisons[artifact.id] {
                    ArtifactDiffView(comparison: comparison) {
                        openDiffSheet(artifact, comparison: comparison)
                    }.id(artifact.id)
                } else if comparisonErrors.contains(artifact.id) {
                    Text(L.string("product.artifact.diff.load_failed")).font(MeetTypography.secondary).foregroundStyle(.secondary)
                    Button(L.string("common.retry")) { Task { await loadComparison(artifact) } }.buttonStyle(.link)
                } else { ProgressView().controlSize(.small) }
            }
            if expanded.contains(group.id) {
                artifactDetails(artifact, group: group)
            }
        }
        .padding(MeetSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .meetCard()
        .task(id: artifact.id + String(describing: artifact.contentRetained)) {
            if reviewStart != nil, !expandedDiffs.contains(group.id), let store {
                do { diffPins[group.id] = try store.pinComparison(); expandedDiffs.insert(group.id) }
                catch { errorText = L.errorDescription(error) }
            }
            await loadComparison(artifact)
        }
        .onDisappear { closeInlineDiff(group.id) }
    }

    private func artifactIdentity(_ artifact: TaskArtifact, group: TaskArtifactGroup, showParentPath: Bool) -> some View {
        HStack(alignment: .top, spacing: MeetSpacing.sm) {
            Image(systemName: "doc.text").font(.title3).foregroundStyle(.secondary)
                .padding(.top, MeetSpacing.xs)
            VStack(alignment: .leading, spacing: MeetSpacing.xs) {
                Text(artifact.name).font(MeetTypography.listTitle).lineLimit(1).truncationMode(.middle)
                    .help(artifact.path)
                if showParentPath {
                    Text(URL(fileURLWithPath: artifact.path).deletingLastPathComponent().path)
                        .font(MeetTypography.secondary).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                } else if relativePath(artifact).contains("/") {
                    Text(relativePath(artifact))
                        .font(MeetTypography.secondary).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: MeetSpacing.sm) {
                    Button {
                        if !expanded.insert(group.id).inserted { expanded.remove(group.id) }
                    } label: {
                        HStack(spacing: MeetSpacing.xs) {
                            Text(artifact.version.map { L.format("product.artifact.version", $0) } ?? L.string("product.artifact.details"))
                            if group.revisions.count > 1 {
                                Text("·")
                                Text(L.format("product.artifact.version_count", group.revisions.count))
                            }
                            Image(systemName: expanded.contains(group.id) ? "chevron.up" : "chevron.down").imageScale(.small)
                        }
                    }
                    .buttonStyle(.plain).help(L.string("product.artifact.details"))
                    .accessibilityLabel(L.string("product.artifact.versions"))
                    .accessibilityValue(artifact.version.map { L.format("product.artifact.version", $0) } ?? "")
                    if let bytes = artifact.byteCount { Text(sizeLabel(bytes)) }
                    if let source = artifact.sourceTool { Text(sourceLabel(source)) }
                }.font(MeetTypography.secondary).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func artifactActions(_ artifact: TaskArtifact, group: TaskArtifactGroup, current: URL?, readable: Bool) -> some View {
        let diff = Button(L.string(expandedDiffs.contains(group.id) ? "product.artifact.diff.hide" : "product.artifact.diff.show")) {
            if expandedDiffs.contains(group.id) { closeInlineDiff(group.id) }
            else if let store {
                do { diffPins[group.id] = try store.pinComparison(); expandedDiffs.insert(group.id) }
                catch { errorText = L.errorDescription(error) }
            }
        }.buttonStyle(.borderedProminent)
        let preview = Button(L.string("product.artifact.preview")) { perform(artifact) { showPreview($0, artifact: artifact) } }
        let export = Button(L.string("product.artifact.export")) { perform(artifact) { export($0, artifact: artifact) } }
        let continueEditing = Button(L.string("product.artifact.continue")) {
            perform(artifact) { url in
                onUse(artifact)
                if reviewStart != nil { dismiss() }
                if artifact.versionID != nil, let onContinueSnapshot { onContinueSnapshot(artifact, url) }
                else { onContinue(artifact) }
            }
        }
        let more = Menu {
            if readable {
                Button(L.string(artifact.versionID == nil ? "files.open" : "product.artifact.open_copy")) {
                    perform(artifact) { url in if NSWorkspace.shared.open(url) { onUse(artifact) } }
                }
            }
            if let current {
                Button(L.string("files.reveal")) { NSWorkspace.shared.activateFileViewerSelecting([current]) }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(L.string("product.artifact.more_actions"))
        .help(L.string("product.artifact.more_actions"))
        .disabled(!readable && current == nil)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: MeetSpacing.sm) {
                if artifact.versionID != nil, store != nil { diff }
                if readable { preview; export; continueEditing }
                more
            }.fixedSize()
            VStack(alignment: .leading, spacing: MeetSpacing.sm) {
                HStack(spacing: MeetSpacing.sm) {
                    if artifact.versionID != nil, store != nil { diff }
                    if readable { preview; export }
                    more
                }
                if readable { continueEditing }
            }
        }.font(MeetTypography.control).controlSize(.small).disabled(busy)
    }

    private func closeInlineDiff(_ id: TaskArtifactGroup.ID) {
        diffPins.removeValue(forKey: id)?.release()
        expandedDiffs.remove(id)
    }

    private func openDiffSheet(_ artifact: TaskArtifact, comparison: TaskArtifactComparison) {
        guard let store else { return }
        do {
            diffSheetPin?.release()
            diffSheetPin = try store.pinComparison()
            diffTarget = DiffTarget(artifact: artifact, comparison: comparison)
        } catch { errorText = L.errorDescription(error) }
    }

    private func closeDiffSheet() {
        diffSheetPin?.release(); diffSheetPin = nil; diffTarget = nil
    }

    @ViewBuilder private func changeSummary(_ artifact: TaskArtifact) -> some View {
        let comparison = comparisons[artifact.id]
        if let kind = comparison?.kind ?? artifact.change?.kind {
            HStack(spacing: MeetSpacing.sm) {
                Text(L.string(kind == .created ? "product.artifact.diff.created" : "product.artifact.diff.modified"))
                    .foregroundStyle(.secondary)
                if let added = comparison?.added { Text("+\(added)").foregroundStyle(.green).monospacedDigit() }
                if let removed = comparison?.removed { Text("−\(removed)").foregroundStyle(.red).monospacedDigit() }
                if comparison?.state == .unchanged { Text(L.string("product.artifact.diff.unchanged")).foregroundStyle(.secondary) }
            }.font(MeetTypography.secondary)
        }
    }

    private func relativePath(_ artifact: TaskArtifact) -> String {
        let path = URL(fileURLWithPath: artifact.path).standardizedFileURL.path
        if let root = roots.map({ $0.standardizedFileURL.path }).filter({ path.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) {
            return String(path.dropFirst(root.count + 1))
        }
        return artifact.name
    }

    @MainActor private func loadComparison(_ artifact: TaskArtifact) async {
        guard let store, artifact.versionID != nil else { return }
        let ticket = presentationID
        comparisons[artifact.id] = nil; comparisonErrors.remove(artifact.id)
        do {
            let value = try await store.comparison(of: artifact)
            guard isVisible, presentationID == ticket, !Task.isCancelled else { return }
            comparisons[artifact.id] = value
        } catch {
            if isVisible, presentationID == ticket, !Task.isCancelled { comparisonErrors.insert(artifact.id) }
        }
    }

    @ViewBuilder private func artifactNotice(_ artifact: TaskArtifact, readable: Bool) -> some View {
        if artifact.observedChange == true {
            Text(L.string("product.artifact.observed_change")).font(MeetTypography.secondary).foregroundStyle(.secondary)
        }
        if artifact.recordingFailed == true {
            Text(L.string("product.artifact.recording_failed")).font(MeetTypography.secondary).foregroundStyle(.orange)
        } else if artifact.versionID == nil {
            Text(L.string("product.artifact.legacy")).font(MeetTypography.secondary).foregroundStyle(.secondary)
        } else if artifact.contentRetained == false {
            Text(artifact.retentionReason == .removedByUser ? L.string("product.artifact.removed") : artifact.retentionReason == .operationLimit
                ? L.format("product.artifact.operation_limit", sizeLabel(TaskArtifactStore.maximumOperationSnapshotBytes))
                : L.format("product.artifact.too_large", sizeLabel(TaskArtifactStore.maximumSnapshotBytes)))
                .font(MeetTypography.secondary).foregroundStyle(.orange)
        }
        if !readable, artifact.contentRetained != false {
            Text(L.string(artifact.versionID == nil ? "product.artifact.unavailable" : "product.artifact.error.unavailable"))
                .font(MeetTypography.secondary).foregroundStyle(.secondary)
        }
    }

    private func artifactDetails(_ artifact: TaskArtifact, group: TaskArtifactGroup) -> some View {
        VStack(alignment: .leading, spacing: MeetSpacing.sm) {
            Divider()
            Text(artifact.path).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            if let date = artifact.createdAt { Text(date, format: .dateTime.year().month().day().hour().minute()).foregroundStyle(.secondary) }
            ForEach(knownVersions(in: group)) { revision in
                Button {
                    if let onSelectVersion, let version = histories[group.id]?.first(where: { $0.artifact.id == revision.id }) {
                        onSelectVersion(version)
                    } else { selected[group.id] = revision }
                } label: {
                    HStack(spacing: MeetSpacing.sm) {
                        Image(systemName: revision.id == artifact.id ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(revision.id == artifact.id ? Color.accentColor : .secondary)
                        Text(revision.version.map { L.format("product.artifact.version", $0) } ?? revision.name)
                        if revision.id == group.newest.id {
                            Text(L.string("product.artifact.latest_in_task")).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if let bytes = revision.byteCount { Text(sizeLabel(bytes)).foregroundStyle(.secondary) }
                        if let date = revision.createdAt { Text(date, format: .dateTime.month().day().hour().minute()).foregroundStyle(.secondary) }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(busy)
            }
            if let ids = artifact.inputVersionIDs, !ids.isEmpty, let store {
                DisclosureGroup(L.string("product.artifact.inputs")) {
                    if inputs[artifact.id]?.isEmpty == true {
                        Text(L.string("product.artifact.inputs_unavailable")).foregroundStyle(.secondary)
                    }
                    ForEach(inputs[artifact.id] ?? []) { input in
                        Button {
                            perform(input.artifact) { showPreview($0, artifact: input.artifact) }
                        } label: {
                            Text(input.artifact.name + " · " + L.format("product.artifact.version", input.artifact.version ?? 1))
                        }.buttonStyle(.link).disabled(busy || input.artifact.contentRetained != true)
                    }
                }
                .task(id: artifact.id) {
                    let ticket = presentationID
                    do {
                        let values = try await store.inputs(of: artifact)
                        guard isVisible, presentationID == ticket, !Task.isCancelled else { return }
                        inputs[artifact.id] = values
                    } catch { if isVisible, presentationID == ticket, !Task.isCancelled { errorText = L.errorDescription(error) } }
                }
            }
        }.font(MeetTypography.secondary)
        .task(id: group.newest.id) {
            guard let store, let source = group.revisions.first(where: { $0.versionID != nil }) else { return }
            let ticket = presentationID
            do {
                let values = try await store.versions(of: source)
                guard isVisible, presentationID == ticket, !Task.isCancelled else { return }
                histories[group.id] = values
            } catch { if isVisible, presentationID == ticket, !Task.isCancelled { errorText = L.errorDescription(error) } }
        }
    }

    private func knownVersions(in group: TaskArtifactGroup) -> [TaskArtifact] {
        var seen: Set<String> = []
        return TaskArtifactGroup.ordered((group.revisions + (histories[group.id] ?? []).map(\.artifact)).filter { seen.insert($0.id).inserted })
    }

    private func sourceLabel(_ tool: String) -> String {
        if tool.contains("python") || tool == "skill_run_script" { return L.string("product.artifact.source.python") }
        return L.string(tool == "shell_run" ? "product.artifact.source.shell" : "product.artifact.source.file")
    }

    private func sizeLabel(_ bytes: Int) -> String {
        TaskArtifactFormatting.size(Int64(bytes))
    }

    private func pin(_ artifact: TaskArtifact, at url: URL) throws -> TaskArtifactPreviewPin? {
        guard artifact.versionID != nil else { return nil }
        guard let store else { throw TaskArtifactError.unavailable }
        return try store.pinPreview(artifact, at: url)
    }

    private func showPreview(_ url: URL, artifact: TaskArtifact) {
        do { previewPin = try pin(artifact, at: url); previewURL = url; onUse(artifact) }
        catch { errorText = L.errorDescription(error) }
    }

    private func closePreview() {
        previewPin?.release(); previewPin = nil; previewURL = nil
    }

    private func exportDestination(_ panel: NSSavePanel, ticket: UUID) async -> URL? {
        let choice = await chooseExportDestination(panel)
        guard isVisible, ticket == presentationID, !Task.isCancelled else { return nil }
        switch choice {
        case .selected(let url): return url
        case .cancelled: return nil
        case .failed: errorText = L.string("product.artifact.export.failed"); return nil
        }
    }

    private func currentURL(_ artifact: TaskArtifact) -> URL? {
        let url = URL(fileURLWithPath: artifact.path).standardizedFileURL.resolvingSymlinksInPath()
        guard roots.contains(where: { FileAreaService.isInside(url, root: $0.standardizedFileURL.resolvingSymlinksInPath()) }),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        return url
    }

    private func canResolve(_ artifact: TaskArtifact, current: URL?) -> Bool {
        if unavailable.contains(artifact.id) { return false }
        if artifact.versionID != nil { return store != nil && artifact.contentRetained == true }
        return current != nil
    }

    private var metadataIDs: [UUID] {
        if let file = reviewedFile ?? reviewStart, let group = groups.first(where: { $0.id == file }) {
            return [(selected[file] ?? group.newest).versionID].compactMap { $0 }
        }
        return Array(Set(groups.prefix(visibleCount).compactMap { (selected[$0.id] ?? $0.newest).versionID }))
    }

    private func refreshMetadata() async {
        guard let store, isVisible else { return }
        let ticket = presentationID, ids = metadataIDs
        let request = UUID(); metadataGeneration = request
        do {
            var fresh: [TaskArtifact] = []
            for offset in stride(from: 0, to: ids.count, by: 100) {
                fresh += try await store.currentArtifacts(Array(ids[offset..<min(ids.count, offset + 100)]))
            }
            guard isVisible, presentationID == ticket, metadataGeneration == request, !Task.isCancelled else { return }
            for artifact in fresh { latest[artifact.id] = artifact }
            let found = Set(fresh.map(\.id))
            for id in ids.map(\.uuidString) {
                if found.contains(id) { unavailable.remove(id) } else { unavailable.insert(id) }
            }
        } catch { if presentationID == ticket, metadataGeneration == request { errorText = L.errorDescription(error) } }
    }

    private func resolve(_ artifact: TaskArtifact) async throws -> URL {
        if artifact.versionID != nil {
            guard let store else { throw TaskArtifactError.unavailable }
            return try await store.materialize(artifact)
        }
        guard let url = currentURL(artifact) else { throw TaskArtifactError.unavailable }
        return url
    }

    private func perform(_ artifact: TaskArtifact, action: @escaping (URL) -> Void) {
        guard isVisible else { return }
        let ticket = presentationID
        busy = true; errorText = nil
        Task {
            do {
                let url = try await resolve(artifact)
                guard isVisible, presentationID == ticket, !Task.isCancelled else {
                    if presentationID == ticket { busy = false }
                    return
                }
                busy = false
                action(url)
            } catch { if presentationID == ticket { busy = false; errorText = L.errorDescription(error) } }
        }
    }

    private func export(_ source: URL, artifact: TaskArtifact) {
        let pin: TaskArtifactPreviewPin?
        do { pin = try self.pin(artifact, at: source) }
        catch { errorText = L.errorDescription(error); return }
        let ticket = presentationID
        let panel = makeSavePanel(); panel.nameFieldStringValue = artifact.name; panel.title = L.string("product.artifact.export")
        busy = true; activeExportPanel = panel
        Task {
            defer { pin?.release() }
            defer { if ticket == presentationID { busy = false; activeExportPanel = nil } }
            guard isVisible, ticket == presentationID, !Task.isCancelled else { return }
            guard let target = await exportDestination(panel, ticket: ticket) else { return }
            busy = true; exportReceipt = nil
            do {
                try await Task.detached {
                    let fm = FileManager.default
                    let staging = target.deletingLastPathComponent().appendingPathComponent(".export-" + UUID().uuidString)
                    defer { try? fm.removeItem(at: staging) }
                    try fm.copyItem(at: source, to: staging)
                    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
                    if fm.fileExists(atPath: target.path) { _ = try fm.replaceItemAt(target, withItemAt: staging) }
                    else { try fm.moveItem(at: staging, to: target) }
                }.value
                if isVisible, ticket == presentationID { exportReceipt = .init(destination: target, count: 1) }
                onUse(artifact)
            } catch { if ticket == presentationID { errorText = L.string("product.artifact.export.failed") } }
        }
    }

    private func exportAll() {
        let ticket = presentationID
        let panel = makeFolderPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.title = L.string("product.artifact.exportAll")
        busy = true; activeExportPanel = panel
        Task {
            defer { if ticket == presentationID { busy = false; activeExportPanel = nil } }
            guard isVisible, ticket == presentationID, !Task.isCancelled else { return }
            guard let destination = await exportDestination(panel, ticket: ticket) else { return }
            busy = true; errorText = nil; exportReceipt = nil
            do {
                var urls: [URL] = []
                var pins: [TaskArtifactPreviewPin] = []
                defer { for pin in pins { pin.release() } }
                let exportGroups = fullResultForExport.map(TaskArtifactGroup.collect) ?? groups
                let chosen = exportGroups.map { displayedArtifact(in: $0) }
                for artifact in chosen {
                    let url = try await resolve(artifact)
                    if let pin = try pin(artifact, at: url) { pins.append(pin) }
                    urls.append(url)
                }
                let sources = urls
                let folder = destination.appendingPathComponent("AgRoom-" + UUID().uuidString, isDirectory: true)
                try await Task.detached {
                    let fm = FileManager.default
                    try fm.createDirectory(at: folder, withIntermediateDirectories: false)
                    do {
                        for (index, source) in sources.enumerated() {
                            let target = folder.appendingPathComponent("\(index + 1)-" + source.lastPathComponent)
                            try fm.copyItem(at: source, to: target)
                            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                        }
                    } catch { try? fm.removeItem(at: folder); throw error }
                }.value
                if isVisible, ticket == presentationID { exportReceipt = .init(destination: folder, count: sources.count) }
                for artifact in chosen { onUse(artifact) }
            } catch { if ticket == presentationID { errorText = L.string("product.artifact.export.failed") } }
        }
    }
}
