import AppKit
import SwiftUI
import AgRoomCore

struct WorkspaceFoldersView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var workspace: ChatWorkspace
    @State private var errorMessage: String?
    let allowsChanges: Bool
    let onChanged: () -> Void

    init(workspace: ChatWorkspace, allowsChanges: Bool, onChanged: @escaping () -> Void) {
        _workspace = State(initialValue: workspace)
        self.allowsChanges = allowsChanges
        self.onChanged = onChanged
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L.string("workspace.folders.title")).font(.headline)
                Spacer()
                Button(L.string("common.done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text(L.string("workspace.folders.scope")).font(.callout).foregroundStyle(.secondary)
            if !allowsChanges { Text(L.string("workspace.folders.busy")).font(.callout).foregroundStyle(.orange) }
            if let errorMessage { Text(errorMessage).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    folderRow(workspace.url, primary: true)
                    ForEach(workspace.referencedFolders) { folder in
                        HStack {
                            folderRow(folder.url, primary: false)
                            Spacer()
                            Button(role: .destructive) { remove(folder) } label: {
                                Image(systemName: "minus.circle")
                            }
                            .help(L.string("workspace.folders.remove"))
                            .disabled(!allowsChanges)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button { addFolders() } label: {
                Label(L.string("workspace.folders.add"), systemImage: "folder.badge.plus")
            }
            .disabled(!allowsChanges)
        }
        .padding(20)
        .frame(width: 620, height: 400)
    }

    private func folderRow(_ url: URL, primary: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(primary ? L.string("workspace.folders.primary") : url.lastPathComponent).fontWeight(.medium)
                Text(url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = L.string("workspace.folders.choose")
        guard panel.runModal() == .OK else { return }
        do {
            try WorkspaceRegistry.shared.addReferencedFolders(panel.urls, to: workspace.id, in: workspace.space)
            reload()
        } catch { errorMessage = L.errorDescription(error) }
    }

    private func remove(_ folder: WorkspaceFolderReference) {
        do {
            try WorkspaceRegistry.shared.removeReferencedFolder(folder.id, from: workspace.id, in: workspace.space)
            reload()
        } catch { errorMessage = L.errorDescription(error) }
    }

    private func reload() {
        if let updated = WorkspaceRegistry.shared.workspaces(for: workspace.space).first(where: { $0.id == workspace.id }) {
            workspace = updated
        }
        errorMessage = nil
        onChanged()
    }
}
