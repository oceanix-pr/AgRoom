import CryptoKit
import Foundation
import Observation
import SwiftUI
import UserNotifications
import AgRoomCore

/// Immutable delegate: only mailbox requests opt into foreground presentation.
/// Other notification categories retain the default presentation behavior.
private final class MailForegroundNotifications: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = MailForegroundNotifications()
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        notification.request.identifier.hasPrefix("agroom.mail.") ? [.banner, .sound] : []
    }
}

@MainActor @Observable
final class MailAutoSyncController {
    private static var monitorOwners: [ObjectIdentifier: UUID] = [:]
    private let hub: Hub
    private let space: AppSpace
    private(set) var settings = MailAutoSyncSettings()
    private(set) var isSaving = false
    private(set) var isSyncing = false
    private(set) var lastSynced: Date?
    private(set) var nextAttempt: Date?
    private(set) var error: String?
    private(set) var failures: [UUID: String] = [:]
    private var generation = UUID()
    private var monitorID: UUID?
    private var settingsRevision = UUID()
    private var settingsValid = false
    private var transfer: Task<Void, Never>?
    var makeSyncService: @MainActor () -> MailSyncService?
    var notificationSink: (@MainActor (Int) async -> Void)?

    init(hub: Hub, space: AppSpace) {
        self.hub = hub; self.space = space; makeSyncService = { hub.makeMailSyncService(for: space) }
    }

    func load() async {
        let revision = settingsRevision
        do {
            let value = try await hub.makeProductPreferencesService(for: space)?.load(MailAutoSyncSettings.self, key: "mail.autoSync") ?? .init()
            try value.validate()
            guard settingsRevision == revision else { return }
            if value != settings {
                generation = UUID(); transfer?.cancel(); transfer = nil; isSyncing = false; nextAttempt = nil
            }
            settings = value
            settingsValid = true
        } catch {
            if settingsRevision == revision {
                settingsValid = false; settings.enabled = false
                generation = UUID(); transfer?.cancel(); transfer = nil; isSyncing = false
                self.error = MailErrorText.message(for: error)
            }
        }
    }

    func save(_ value: MailAutoSyncSettings) async {
        guard !isSaving else { return }
        let old = settings, revision = UUID(); settingsRevision = revision
        isSaving = true; error = nil
        defer { isSaving = false }
        do {
            try value.validate()
            var updated = value
            if updated.notifications && !old.notifications {
                let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                if !allowed { updated.notifications = false; error = L.string("mail.autoSync.notificationDenied") }
            }
            guard hub.spaceStore.current == space, !Task.isCancelled else { return }
            guard let prefs = hub.makeProductPreferencesService(for: space) else { throw MailSearchError.unavailable }
            if updated.enabled && !old.enabled { try await prefs.save(MailAutoSyncBaseline(), key: "mail.autoSync.baseline") }
            try await prefs.save(updated, key: "mail.autoSync")
            generation = UUID(); transfer?.cancel(); transfer = nil; isSyncing = false
            settings = updated; settingsValid = true; nextAttempt = nil
        } catch { self.error = MailErrorText.message(for: error) }
    }

    /// Owned by the main window, rather than the mailbox page. Every pass builds
    /// fresh services for this fixed space and uses the existing account leases.
    func monitor() async {
        while monitorID != nil, !Task.isCancelled, hub.spaceStore.current == space {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
        guard !Task.isCancelled, hub.spaceStore.current == space else { return }
        let id = UUID(); monitorID = id
        guard let queue = hub.spaceStore.queue(for: space) else { monitorID = nil; return }
        let owner = ObjectIdentifier(queue)
        defer {
            if Self.monitorOwners[owner] == id { Self.monitorOwners[owner] = nil }
            if monitorID == id { stop(); monitorID = nil }
        }
        while Self.monitorOwners[owner] != nil, !Task.isCancelled, hub.spaceStore.current == space {
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
        }
        guard !Task.isCancelled, hub.spaceStore.current == space else { return }
        Self.monitorOwners[owner] = id
        await load()
        while !Task.isCancelled, hub.spaceStore.current == space, monitorID == id {
            await load()
            if settingsValid, settings.enabled, !isSaving, !isSyncing, (nextAttempt ?? .distantPast) <= Date() {
                let epoch = generation
                let work = Task { await self.poll(epoch: epoch) }; transfer = work
                await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
                if generation == epoch { transfer = nil }
            }
            do { try await Task.sleep(for: .seconds(10)) } catch { break }
        }
    }

    func stop() { generation = UUID(); transfer?.cancel(); transfer = nil; isSyncing = false }

    private func poll(epoch: UUID) async {
        isSyncing = true; failures = [:]
        defer { if generation == epoch { isSyncing = false } }
        do {
            guard let prefs = hub.makeProductPreferencesService(for: space), let accounts = hub.makeMailAccountService(for: space),
                  let mail = hub.makeMailService(for: space) else { throw MailSearchError.unavailable }
            let owners = try await accounts.getAll().filter { !$0.isLocalArchive && $0.isEnabled }
            var baseline = try await prefs.load(MailAutoSyncBaseline.self, key: "mail.autoSync.baseline") ?? .init()
            guard baseline.stamps.count <= 10_000 else { throw MailSearchError.capacity }
            let prefixes = Set(owners.map { $0.id.uuidString })
            baseline.stamps = baseline.stamps.filter { prefixes.contains(String($0.key.prefix(36))) }
            var newUnread = 0
            for account in owners {
                try Task.checkCancellation()
                guard generation == epoch, hub.spaceStore.current == space, settings.enabled else { return }
                do {
                    let fingerprint = try Self.fingerprint(account)
                    let old = try await mail.observeInbox(accountID: account.id, since: [:])
                    let known = Dictionary(uniqueKeysWithValues: old.compactMap { observation -> (UUID, UInt32)? in
                        let key = account.id.uuidString + "/" + observation.folderID.uuidString
                        guard let previous = baseline.stamps[key], previous.endpointFingerprint == fingerprint,
                              previous.uidValidity != nil, previous.uidValidity == observation.uidValidity else { return nil }
                        return (observation.folderID, previous.highestUID)
                    })
                    guard let sync = makeSyncService() else { throw MailSearchError.unavailable }
                    _ = try await sync.syncAccount(accountId: account.id, onlyRole: .inbox, expectedAccount: account)
                    guard let current = try await accounts.account(id: account.id), current.isEnabled,
                          try Self.fingerprint(current) == fingerprint else { throw MailExportError.changed }
                    let latest = try await mail.observeInbox(accountID: account.id, since: known)
                    for observation in latest {
                        let key = account.id.uuidString + "/" + observation.folderID.uuidString
                        let previous = baseline.stamps[key]
                        if previous?.endpointFingerprint == fingerprint, let validity = observation.uidValidity,
                           previous?.uidValidity == validity, known[observation.folderID] != nil { newUnread += observation.newUnreadCount }
                        baseline.stamps[key] = .init(endpointFingerprint: fingerprint, uidValidity: observation.uidValidity,
                            highestUID: max(observation.highestUID, previous?.uidValidity == observation.uidValidity && previous?.endpointFingerprint == fingerprint ? previous?.highestUID ?? 0 : 0))
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { if generation == epoch { failures[account.id] = MailErrorText.message(for: error) } }
            }
            try Task.checkCancellation()
            guard generation == epoch, hub.spaceStore.current == space else { return }
            guard baseline.stamps.count <= 10_000 else { throw MailSearchError.capacity }
            // Save watermarks before notifying: a transient notification failure
            // must not repeatedly announce the same already observed mail.
            try await prefs.save(baseline, key: "mail.autoSync.baseline")
            guard generation == epoch, hub.spaceStore.current == space, !Task.isCancelled else { return }
            lastSynced = Date(); nextAttempt = Date().addingTimeInterval(Double(settings.intervalMinutes * 60))
            NotificationCenter.default.post(name: .mailDataChanged, object: nil)
            if newUnread > 0, settings.notifications { await notify(newUnread, epoch: epoch) }
        } catch is CancellationError { }
        catch {
            if generation == epoch {
                self.error = MailErrorText.message(for: error)
                nextAttempt = Date().addingTimeInterval(Double(settings.intervalMinutes * 60))
            }
        }
    }

    private func notify(_ count: Int, epoch: UUID) async {
        guard generation == epoch, settings.notifications, hub.spaceStore.current == space, !Task.isCancelled else { return }
        if let notificationSink { await notificationSink(count); return }
        let center = UNUserNotificationCenter.current()
        let authorization = await center.notificationSettings().authorizationStatus
        guard authorization == .authorized || authorization == .provisional else {
            if generation == epoch { error = L.string("mail.autoSync.notificationDenied") }; return
        }
        guard generation == epoch, settings.notifications, hub.spaceStore.current == space, !Task.isCancelled else { return }
        let content = UNMutableNotificationContent()
        content.title = L.string("mail.autoSync.notificationTitle")
        content.subtitle = L.string(space.nameKey)
        content.body = L.format("mail.autoSync.notificationBody", count)
        content.sound = .default
        if center.delegate == nil { center.delegate = MailForegroundNotifications.shared }
        do { try await center.add(UNNotificationRequest(identifier: "agroom.mail." + space.rawValue, content: content, trigger: nil)) }
        catch { if generation == epoch { self.error = L.string("mail.autoSync.notificationFailed") } }
    }

    private static func fingerprint(_ account: MailAccount) throws -> String {
        let data = try JSONEncoder().encode([account.id.uuidString, account.imapHost, String(account.imapPort), account.imapSecurity.rawValue, account.username, account.authKind.rawValue])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct MailAutoSyncSettingsView: View {
    @Bindable var model: MailAutoSyncController
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.string("mail.autoSync.title")).font(.headline)
            Toggle(L.string("mail.autoSync.enabled"), isOn: binding(\.enabled))
            Picker(L.string("mail.autoSync.interval"), selection: binding(\.intervalMinutes)) {
                ForEach([1, 5, 15, 30, 60], id: \.self) { Text(L.format("mail.autoSync.minutes", $0)).tag($0) }
            }
            Toggle(L.string("mail.autoSync.notifications"), isOn: binding(\.notifications))
            Text(L.string("mail.autoSync.hint")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.isSyncing { HStack { ProgressView().controlSize(.small); Text(L.string("mail.autoSync.running")) } }
            if let date = model.lastSynced { Text(L.format("mail.autoSync.last", AppDate.string(from: date))).font(.caption) }
            if let date = model.nextAttempt, model.settings.enabled { Text(L.format("mail.autoSync.next", AppDate.string(from: date))).font(.caption) }
            if !model.failures.isEmpty { Text(L.format("mail.autoSync.failures", model.failures.count)).foregroundStyle(.red) }
            ForEach(model.failures.keys.sorted { $0.uuidString < $1.uuidString }, id: \.self) { key in
                Text(model.failures[key] ?? "").font(.caption).foregroundStyle(.red)
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(16).frame(width: 430).disabled(model.isSaving).task { await model.load() }
    }
    private func binding<Value>(_ key: WritableKeyPath<MailAutoSyncSettings, Value>) -> Binding<Value> {
        Binding(get: { model.settings[keyPath: key] }, set: { value in
            var settings = model.settings; settings[keyPath: key] = value
            Task { await model.save(settings) }
        })
    }
}
