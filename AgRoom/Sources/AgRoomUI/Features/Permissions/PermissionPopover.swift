import SwiftUI
import AgRoomCore

/// One preset selector shared by the composer, session page and defaults.
/// The host owns persistence; this view only submits a confirmed catalog entry.
struct PermissionControl: View {
    let configuration: PermissionConfiguration
    var isReviewing = false
    var isSaving = false
    var canSwitch = true
    var options: [PermissionPreset] = PermissionPreset.sessionOptions
    let onSelectPreset: (PermissionPreset) -> Void
    var onOpenPermissions: (() -> Void)?
    var dataPolicy: TaskDataPolicy?
    var hasConversationHistory = false
    var onSelectDataPolicy: ((TaskDataPolicy) -> Void)?
    var allowsHostExecution: Bool?
    var onSelectHostExecution: ((Bool) -> Void)?

    @State private var showingPopover = false
    @State private var pendingPreset: PermissionPreset?
    @State private var pendingDataPolicy: TaskDataPolicy?

    private var preset: PermissionPreset { configuration.preset }
    private var locked: Bool { !canSwitch || isSaving }

    var body: some View {
        Button {
            showingPopover.toggle()
        } label: {
            HStack(spacing: 5) {
                if isSaving || isReviewing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: preset.iconName)
                }
                if dataPolicy == .localOnly {
                    Image(systemName: "network.slash").accessibilityLabel(L.string("permissions.data.localOnly"))
                }
                Text(L.string(preset.nameKey))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .disabled(locked)
        .help(L.string(isSaving ? "chat.permission.preset.saving"
            : (!canSwitch ? "chat.permission.locked" : preset.descriptionKey)))
        .accessibilityLabel(L.format("chat.permission.a11y", L.string(preset.nameKey)))
        .popover(isPresented: $showingPopover, arrowEdge: .top) {
            PermissionPopover(
                selected: preset,
                options: options,
                onSelect: choose,
                onOpenPermissions: onOpenPermissions.map { action in
                    { showingPopover = false; action() }
                }, dataPolicy: dataPolicy, onSelectDataPolicy: onSelectDataPolicy.map { select in
                    { policy in
                        showingPopover = false
                        if hasConversationHistory, dataPolicy?.constraints.isStrictSuperset(of: policy.constraints) == true {
                            pendingDataPolicy = policy
                        } else {
                            select(policy)
                        }
                    }
                }, allowsHostExecution: configuration.mode == .dangerFullAccess ? allowsHostExecution : nil,
                onSelectHostExecution: onSelectHostExecution
            )
        }
        .alert(L.string("permissions.data.expand.title"), isPresented: Binding(
            get: { pendingDataPolicy != nil },
            set: { if !$0 { pendingDataPolicy = nil } }
        ), presenting: pendingDataPolicy) { policy in
            Button(L.string("permissions.data.expand.confirm")) {
                if !locked { onSelectDataPolicy?(policy) }
            }
            Button(L.string("common.cancel"), role: .cancel) {}
        } message: { policy in
            Text(L.string(policy == .configuredServices ? "permissions.data.expand.services" : "permissions.data.expand.model"))
        }
        .sheet(isPresented: Binding(
            get: { pendingPreset != nil },
            set: { if !$0 { pendingPreset = nil } }
        )) {
            if let pendingPreset {
                PermissionPresetConfirmation(preset: pendingPreset, disabled: locked) {
                    guard !locked, options.contains(pendingPreset) else { return }
                    self.pendingPreset = nil
                    onSelectPreset(pendingPreset)
                } onCancel: {
                    self.pendingPreset = nil
                }
            }
        }
        .onChange(of: locked) { _, value in
            if value { showingPopover = false; pendingPreset = nil }
        }
        .onChange(of: configuration) { _, _ in
            showingPopover = false
            pendingPreset = nil
        }
    }

    private func choose(_ candidate: PermissionPreset) {
        guard !locked, options.contains(candidate), candidate != preset else { return }
        showingPopover = false
        if candidate.requiresAcknowledgement {
            pendingPreset = candidate
        } else {
            onSelectPreset(candidate)
        }
    }
}

/// A compact catalog, matching Harness's single permission menu. Descriptions
/// live in tooltips and the full page; execution boundaries are not menu rows.
struct PermissionPopover: View {
    let selected: PermissionPreset
    var options: [PermissionPreset] = PermissionPreset.sessionOptions
    let onSelect: (PermissionPreset) -> Void
    var onOpenPermissions: (() -> Void)?
    var dataPolicy: TaskDataPolicy?
    var onSelectDataPolicy: ((TaskDataPolicy) -> Void)?
    var allowsHostExecution: Bool?
    var onSelectHostExecution: ((Bool) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L.string("chat.permission.preset.title"))
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)

            ForEach(options, id: \.self) { candidate in
                Button { onSelect(candidate) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: candidate.iconName)
                            .frame(width: 18)
                        Text(L.string(candidate.nameKey))
                        if candidate == .autoReview {
                            Text(L.string("chat.permission.preset.experimental"))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                        Spacer(minLength: 12)
                        if candidate == selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 10)
                    .frame(minHeight: 34)
                    .contentShape(Rectangle())
                    .background(candidate == selected ? Color.accentColor.opacity(0.1) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(L.string(candidate.descriptionKey))
                .accessibilityAddTraits(candidate == selected ? [.isSelected] : [])
            }

            if selected == .custom {
                Label(L.string(selected.nameKey), systemImage: selected.iconName)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(10)
                    .help(L.string(selected.descriptionKey))
            }

            if let dataPolicy, let onSelectDataPolicy {
                Divider()
                Picker(L.string("permissions.data.title"), selection: Binding(get: { dataPolicy }, set: { onSelectDataPolicy($0) })) {
                    ForEach(TaskDataPolicy.allCases, id: \.self) { policy in
                        Text(L.string("permissions.data." + policy.rawValue)).tag(policy)
                    }
                }
                .pickerStyle(.menu)
                .padding(.horizontal, 10)
            }

            if let allowsHostExecution, let onSelectHostExecution, dataPolicy == .configuredServices {
                Toggle(L.string("permissions.host.requests"), isOn: Binding(get: { allowsHostExecution }, set: { onSelectHostExecution($0) }))
                    .padding(.horizontal, 10)
            }

            if let onOpenPermissions {
                Divider().padding(.vertical, 4)
                Button(action: onOpenPermissions) {
                    HStack {
                        Text(L.string("chat.permission.popover.open"))
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(width: 280)
    }
}

/// Both Auto and extended access require an explicit acknowledgement on every
/// switch, including from settings. Cancel and Return never grant permission.
struct PermissionPresetConfirmation: View {
    let preset: PermissionPreset
    var disabled = false
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @State private var acknowledged = false

    private var key: String {
        preset == .autoReview ? "chat.permission.preset.auto.confirm" : "chat.permission.preset.extended.confirm"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: preset.iconName)
                .font(.system(size: 26))
                .foregroundColor(.orange)
            Text(L.string("\(key).title"))
                .font(.title3.weight(.semibold))
            Text(L.string("\(key).message"))
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(L.string("\(key).acknowledge"), isOn: $acknowledged)
                .toggleStyle(.checkbox)
                .font(.callout)
            HStack {
                Spacer()
                Button(L.string("common.cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(L.string("\(key).enable")) {
                    guard acknowledged, !disabled else { return }
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(!acknowledged || disabled)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
