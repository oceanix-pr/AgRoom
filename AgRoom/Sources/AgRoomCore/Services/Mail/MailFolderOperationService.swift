import CryptoKit
import Foundation
import GRDB

public struct MailFolderOperationReview: Sendable, Identifiable {
    public var id: UUID { plan.mutation.id }
    public let plan: MailFolderMutationPlan
    public let serverStatuses: [UUID: RemoteFolderStatus]
    public var mutation: MailFolderMutation { plan.mutation }
    public var serverMessageCount: Int? { mutation.account.isLocalArchive ? nil : serverStatuses.values.reduce(0) { count, item in let sum = count.addingReportingOverflow(item.messageCount); return sum.overflow ? Int.max : sum.partialValue } }
}

public struct MailFolderRecoveryReview: Sendable, Identifiable {
    public enum Disposition: String, Sendable { case keepOriginal, applyObserved, resetCache, unavailable }
    public var id: UUID { record.id }
    fileprivate let originQueue: DatabaseQueue
    public let record: MailFolderMutationRecord
    public let disposition: Disposition
    public let resolvedAfter: [MailFolder]?
    public let resetInventories: [UUID: MailFolderInventory]
    fileprivate let fingerprint: String
    public var resetMessageCount: Int { resetInventories.values.reduce(0) { $0 + $1.count } }
}

/// A fresh operation service shares the existing account and maintenance leases.
/// No connection survives an operation and no external write is ever replayed by
/// recovery: recovery only reads server state and commits an explicit local choice.
public actor MailFolderOperationService {
    private let mail: MailService
    private let accounts: MailAccountService
    private let space: AppSpace
    private let coordinator: MailAccountCoordinator
    private let clientFactory: @Sendable (MailAccount) -> MailProtocolClient
    private let passwordProvider: @Sendable (UUID) -> String?
    private let budget: MailTimeoutBudget

    init(mail: MailService, accounts: MailAccountService, space: AppSpace, coordinator: MailAccountCoordinator,
         clientFactory: @escaping @Sendable (MailAccount) -> MailProtocolClient,
         passwordProvider: @escaping @Sendable (UUID) -> String?, budget: MailTimeoutBudget) {
        self.mail = mail; self.accounts = accounts; self.space = space; self.coordinator = coordinator
        self.clientFactory = clientFactory; self.passwordProvider = passwordProvider; self.budget = budget
    }

    public func review(accountID: UUID, kind: MailFolderMutationKind, folderID: UUID? = nil, parentID: UUID? = nil, name: String = "",
                       progress: @escaping @Sendable (Int, Int) async -> Void = { _, _ in }) async throws -> MailFolderOperationReview {
        try await coordinator.withLease(space: space, accountId: accountID, maintenanceKey: mail.databaseQueue.maintenanceKey) {
            try await self.prepareReview(accountID: accountID, kind: kind, folderID: folderID, parentID: parentID, name: name, progress: progress)
        }
    }

    private func prepareReview(accountID: UUID, kind: MailFolderMutationKind, folderID: UUID?, parentID: UUID?, name: String,
                               progress: @escaping @Sendable (Int, Int) async -> Void) async throws -> MailFolderOperationReview {
        let plan = try await mail.reviewFolderMutation(accountID: accountID, kind: kind, folderID: folderID, parentID: parentID, name: name)
        if plan.mutation.account.isLocalArchive { return .init(plan: plan, serverStatuses: [:]) }
        let context = try await context(plan.mutation.account, allowPending: false), client = clientFactory(context.account)
        do {
            try await open(client, context)
            let statuses = try await verifyBefore(plan.mutation, client: client, expected: nil, progress: progress)
            try await mail.validateFolderMutationPlan(plan)
            let prospective = MailFolderMutationRecord(mutation: plan.mutation, serverStatuses: statuses, resolvedAfter: plan.mutation.kind == .delete ? nil : plan.mutation.after)
            guard try JSONEncoder().encode(prospective).count <= MailService.folderMutationByteLimit else { throw MailFolderMutationError.capacity }
            await client.disconnect(); return .init(plan: plan, serverStatuses: statuses)
        } catch { await client.disconnect(); throw error }
    }

    public func execute(_ review: MailFolderOperationReview,
                        progress: @escaping @Sendable (Int, Int) async -> Void = { _, _ in }) async throws -> MailFolderMutationRecord {
        try await coordinator.withLease(space: space, accountId: review.mutation.account.id, maintenanceKey: mail.databaseQueue.maintenanceKey) {
            try await self.perform(review, progress: progress)
        }
    }

    private func perform(_ review: MailFolderOperationReview, progress: @escaping @Sendable (Int, Int) async -> Void) async throws -> MailFolderMutationRecord {
        try await mail.validateFolderMutationPlan(review.plan)
        if review.mutation.account.isLocalArchive {
            let result = try await mail.applyLocalFolderMutation(review.plan)
            await progress(result.completedFolderIDs.count, result.mutation.completionIDs.count); return result
        }
        let context = try await context(review.mutation.account, allowPending: false), client = clientFactory(context.account)
        var started: MailFolderMutationRecord?
        do {
            try await open(client, context)
            _ = try await verifyBefore(review.mutation, client: client, expected: review.serverStatuses, progress: { _, _ in })
            var record = try await mail.beginFolderMutation(review.plan, serverStatuses: review.serverStatuses)
            started = record
            await progress(0, record.mutation.completionIDs.count)
            while let next = record.nextFolderID {
                try Task.checkCancellation()
                let before = record.mutation.before.first { $0.id == next }
                var skipVirtualDeletion = false
                if record.mutation.kind == .delete, let before {
                    let hierarchy = try await hierarchy(client, accountID: record.mutation.account.id)
                    try verifyRemainingTree(record, hierarchy: hierarchy)
                    if let current = hierarchy.first(where: { $0.path == before.path }) {
                        guard sameMetadata(before, current) else { throw MailFolderMutationError.changed }
                        if !before.isContainer {
                            let status = try await status(before.path, client: client)
                            guard let expected = review.serverStatuses[before.id], sameIncarnation(status, expected) else { throw MailFolderMutationError.changed }
                        }
                    } else {
                        guard before.isContainer, record.mutation.inventories[before.id]?.count == 0 else { throw MailFolderMutationError.changed }
                        skipVirtualDeletion = true
                    }
                }
                record = try await mail.markFolderMutationSent(id: record.id, folderID: next)
                if !skipVirtualDeletion {
                    let mutation = record.mutation
                    try await MailDeadline.call(budget.write, label: "folderMutation", client: client) {
                        switch mutation.kind {
                        case .create:
                            guard let target = mutation.after.first else { throw MailFolderMutationError.changed }
                            try await client.createFolder(path: target.path)
                        case .rename:
                            guard let source = mutation.before.first(where: { $0.id == mutation.rootID }), let target = mutation.after.first(where: { $0.id == mutation.rootID }) else { throw MailFolderMutationError.changed }
                            try await client.renameFolder(path: source.path, toPath: target.path)
                        case .delete:
                            guard let before else { throw MailFolderMutationError.changed }
                            try await client.deleteFolder(path: before.path)
                        }
                    }
                }
                record = try await mail.acknowledgeFolderMutation(id: record.id, proof: skipVirtualDeletion ? .reviewed : .server)
                if record.mutation.kind != .delete {
                    let observed = try await observe(record, client: client)
                    guard observed.disposition == .applyObserved, let resolved = observed.resolvedAfter else {
                        throw MailFolderMutationError.identityUnavailable
                    }
                    record = try await mail.acknowledgeFolderMutation(id: record.id, resolvedAfter: resolved)
                }
                record = try await mail.commitFolderMutationStep(id: record.id)
                started = record
                await progress(record.completedFolderIDs.count, record.mutation.completionIDs.count)
            }
            await client.disconnect(); return record
        } catch {
            await client.disconnect()
            if let started {
                let rejected = (error as? MailServerDiagnostic)?.kind == .serverRejected || error as? MailFolderMutationError == .unsupported
                // A cancellation must still leave a durable known/unknown result.
                do {
                    _ = try await Task { try await self.mail.failFolderMutation(id: started.id, definitelyRejected: rejected, cancelled: error is CancellationError) }.value
                } catch {
                    HubLogger.shared.error("Mail folder receipt finalization failed: \(HubLogger.safeErrorSummary(error))")
                }
            }
            throw error
        }
    }

    /// Metadata refresh is explicit and cannot erase cache protected by an intent.
    public func refresh(accountID: UUID) async throws {
        try await coordinator.withLease(space: space, accountId: accountID, maintenanceKey: mail.databaseQueue.maintenanceKey) {
            guard let account = try await self.accounts.account(id: accountID) else { throw MailFolderMutationError.unavailable }
            if account.isLocalArchive { return }
            let context = try await self.context(account, allowPending: false), client = self.clientFactory(context.account)
            do {
                try await self.open(client, context)
                let folders = try await self.hierarchy(client, accountID: accountID)
                try await self.mail.upsertFolders(folders)
                try await self.mail.deleteFolders(accountId: accountID, keeping: folders.map(\.path))
                await client.disconnect()
            } catch { await client.disconnect(); throw error }
        }
    }

    public func inspectPending(accountID: UUID) async throws -> MailFolderRecoveryReview {
        try await coordinator.withLease(space: space, accountId: accountID, maintenanceKey: mail.databaseQueue.maintenanceKey) {
            guard let record = try await self.mail.pendingFolderMutation(accountID: accountID) else { throw MailFolderMutationError.unavailable }
            return try await self.inspect(record)
        }
    }

    public func finishRecovery(_ review: MailFolderRecoveryReview, resetCacheConfirmed: Bool = false) async throws -> MailFolderMutationRecord {
        guard review.originQueue === mail.databaseQueue else { throw MailFolderMutationError.changed }
        return try await coordinator.withLease(space: space, accountId: review.record.mutation.account.id, maintenanceKey: mail.databaseQueue.maintenanceKey) {
            try await self.finishRecoveryUnderLease(review, resetCacheConfirmed: resetCacheConfirmed)
        }
    }

    private func finishRecoveryUnderLease(_ review: MailFolderRecoveryReview, resetCacheConfirmed: Bool) async throws -> MailFolderMutationRecord {
        let current = try await inspect(review.record)
        try Task.checkCancellation()
        guard current.record == review.record, current.disposition == review.disposition, current.fingerprint == review.fingerprint,
              current.resetInventories == review.resetInventories else { throw MailFolderMutationError.changed }
        switch current.disposition {
        case .keepOriginal: return try await mail.endFolderMutationReview(current.record)
        case .unavailable: throw MailFolderMutationError.identityUnavailable
        case .resetCache: guard resetCacheConfirmed else { throw MailFolderMutationError.changed }
        case .applyObserved: break
        }
        let record = current.record
        if record.state == .prepared { throw MailFolderMutationError.changed }
        _ = try await mail.acknowledgeFolderMutation(id: record.id, resolvedAfter: current.resolvedAfter,
            proof: record.state == .acknowledged && record.activeProof == .server ? .server : .reviewed)
        let finished = try await mail.commitFolderMutationStep(id: record.id, resetInventories: current.disposition == .resetCache ? current.resetInventories : [:])
        // Recovery settles the reviewed step only. Remaining deletions need a new
        // preview and confirmation, never continuation of a recovered remote job.
        return finished.state == .prepared ? try await mail.endFolderMutationReview(finished) : finished
    }

    private func inspect(_ record: MailFolderMutationRecord) async throws -> MailFolderRecoveryReview {
        try await mail.validateFolderMutationRecordCurrent(record)
        if record.state == .prepared {
            return .init(originQueue: mail.databaseQueue, record: record, disposition: .keepOriginal, resolvedAfter: nil, resetInventories: [:], fingerprint: "not-submitted")
        }
        let context = try await context(record.mutation.account, allowPending: true), client = clientFactory(context.account)
        do {
            try await open(client, context)
            let result = try await observe(record, client: client)
            await client.disconnect(); return result
        } catch { await client.disconnect(); throw error }
    }

    private struct Observation: Codable {
        let path: String
        let role: MailFolderRole
        let container: Bool
        let parent: String?
        let uidValidity: UInt32?
    }

    private func observe(_ record: MailFolderMutationRecord, client: MailProtocolClient) async throws -> MailFolderRecoveryReview {
        let mutation = record.mutation, hierarchy = try await hierarchy(client, accountID: mutation.account.id)
        let paths = Set((mutation.before + mutation.after).map { MailFolderPath.display($0, isLocalArchive: false) })
        var observations: [Observation] = [], statuses: [UUID: RemoteFolderStatus] = [:]
        for folder in hierarchy where paths.contains(MailFolderPath.display(folder, isLocalArchive: false)) {
            let remoteStatus: RemoteFolderStatus?
            if folder.isContainer { remoteStatus = nil } else { remoteStatus = try await status(folder.path, client: client) }
            observations.append(.init(path: folder.path, role: folder.role, container: folder.isContainer, parent: folder.parentPath, uidValidity: remoteStatus?.uidValidity))
            for old in mutation.before where MailFolderPath.display(old, isLocalArchive: false) == MailFolderPath.display(folder, isLocalArchive: false) {
                if let remoteStatus { statuses[old.id] = remoteStatus }
            }
        }
        // Key order is not mailbox state. A fresh encoder may otherwise produce
        // different bytes for identical observations and reject a valid review.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let fingerprint = SHA256.hash(data: try encoder.encode(observations.sorted { $0.path < $1.path })).map { String(format: "%02x", $0) }.joined()
        let make: (MailFolderRecoveryReview.Disposition, [MailFolder]?, [UUID: MailFolderInventory]) -> MailFolderRecoveryReview = { disposition, after, inventories in
            .init(originQueue: self.mail.databaseQueue, record: record, disposition: disposition, resolvedAfter: after, resetInventories: inventories, fingerprint: fingerprint)
        }
        switch mutation.kind {
        case .create:
            guard let after = resolvedFolders(mutation, hierarchy: hierarchy) else {
                return make(.keepOriginal, nil, [:])
            }
            return make(.applyObserved, after, [:])
        case .delete:
            guard let active = record.activeFolderID, let source = mutation.before.first(where: { $0.id == active }) else { return make(.unavailable, nil, [:]) }
            guard let current = hierarchy.first(where: { $0.path == source.path }) else { return make(.applyObserved, nil, [:]) }
            if let previous = record.serverStatuses?[active]?.uidValidity, let now = statuses[active]?.uidValidity, previous != now {
                // The old incarnation is gone; never DELETE the replacement.
                return make(.applyObserved, nil, [:])
            }
            if sameMetadata(source, current), source.isContainer || sameIncarnation(statuses[active], record.serverStatuses?[active]) { return make(.keepOriginal, nil, [:]) }
            return make(.unavailable, nil, [:])
        case .rename:
            guard let resolved = resolvedFolders(mutation, hierarchy: hierarchy) else {
                let remaining = mutation.before.filter { !record.completedFolderIDs.contains($0.id) }
                let unchanged = remaining.allSatisfy { old in
                    hierarchy.contains { sameMetadata(old, $0) } && (old.isContainer || sameIncarnation(statuses[old.id], record.serverStatuses?[old.id]))
                }
                let targetAbsent = mutation.after.allSatisfy { target in !hierarchy.contains { MailFolderPath.display(target, isLocalArchive: false) == MailFolderPath.display($0, isLocalArchive: false) } }
                return make(unchanged && targetAbsent ? .keepOriginal : .unavailable, nil, [:])
            }
            // With no tagged OK, mailbox names and UIDVALIDITY alone do not prove
            // that cached UIDs belong to a renamed mailbox. Cache reset is an
            // explicit destructive recovery choice; local original copies survive.
            let inventories = try await mail.folderMutationInventories(mutation.before.map(\.id), serverOnly: true)
            if record.state != .acknowledged || record.activeProof != .server {
                let sourcePresent = mutation.before.contains { old in
                    !old.isContainer && hierarchy.contains { sameMetadata(old, $0) } && sameIncarnation(statuses[old.id], record.serverStatuses?[old.id])
                }
                if sourcePresent {
                    let allPresent = mutation.before.allSatisfy { old in hierarchy.contains { sameMetadata(old, $0) } && (old.isContainer || sameIncarnation(statuses[old.id], record.serverStatuses?[old.id])) }
                    return make(allPresent ? .keepOriginal : .unavailable, nil, [:])
                }
            }
            var reset = record.state != .acknowledged || record.activeProof != .server
            for old in mutation.before where !old.isContainer {
                guard let target = resolved.first(where: { $0.id == old.id }) else { return make(.unavailable, nil, [:]) }
                let current = try await status(target.path, client: client)
                if !sameIncarnation(current, record.serverStatuses?[old.id]) { reset = true }
            }
            if reset {
                for old in mutation.before where !old.isContainer {
                    if try await !mail.cachedServerUIDs(folderID: old.id).isEmpty { return make(.resetCache, resolved, inventories) }
                }
            }
            return make(.applyObserved, resolved, [:])
        }
    }

    private func verifyBefore(_ mutation: MailFolderMutation, client: MailProtocolClient, expected: [UUID: RemoteFolderStatus]?,
                              progress: @escaping @Sendable (Int, Int) async -> Void) async throws -> [UUID: RemoteFolderStatus] {
        let folders = try await hierarchy(client, accountID: mutation.account.id)
        if let parent = mutation.parent, !folders.contains(where: { sameMetadata(parent, $0) }) { throw MailFolderMutationError.changed }
        if mutation.kind != .create {
            guard let root = mutation.before.last else { throw MailFolderMutationError.changed }
            let actual = descendants(root.path, folders: folders)
            guard Set(actual.map(\.path)) == Set(mutation.before.map(\.path)), mutation.before.allSatisfy({ old in actual.contains { sameMetadata(old, $0) } }) else { throw MailFolderMutationError.changed }
        }
        let ignored = Set(mutation.before.map { MailFolderPath.display($0, isLocalArchive: false) })
        if mutation.after.contains(where: { target in folders.contains { actual in !ignored.contains(MailFolderPath.display(actual, isLocalArchive: false)) && MailFolderPath.display(actual, isLocalArchive: false) == MailFolderPath.display(target, isLocalArchive: false) } }) { throw MailFolderMutationError.duplicate }
        var result: [UUID: RemoteFolderStatus] = [:]
        var total = 0
        let selectable = mutation.before.filter { !$0.isContainer }
        for (index, folder) in selectable.enumerated() {
            try Task.checkCancellation()
            let current = try await status(folder.path, client: client)
            let sum = total.addingReportingOverflow(current.messageCount)
            guard !sum.overflow else { throw MailFolderMutationError.capacity }; total = sum.partialValue
            guard let validity = current.uidValidity, validity > 0 else { throw MailFolderMutationError.identityUnavailable }
            if let cached = folder.uidValidity, cached != validity { throw MailFolderMutationError.changed }
            if folder.uidValidity == nil, try await !mail.cachedServerUIDs(folderID: folder.id).isEmpty { throw MailFolderMutationError.changed }
            if let expected, !sameIncarnation(current, expected[folder.id]) { throw MailFolderMutationError.changed }
            result[folder.id] = current; await progress(index + 1, selectable.count)
        }
        return result
    }

    private func verifyRemainingTree(_ record: MailFolderMutationRecord, hierarchy: [MailFolder]) throws {
        guard let root = record.mutation.before.last else { throw MailFolderMutationError.changed }
        let remaining = Set(record.mutation.before.filter { !record.completedFolderIDs.contains($0.id) }.map(\.path))
        let actual = descendants(root.path, folders: hierarchy)
        guard Set(actual.map(\.path)).isSubset(of: remaining) else { throw MailFolderMutationError.changed }
    }

    private func resolvedFolders(_ mutation: MailFolderMutation, hierarchy: [MailFolder]) -> [MailFolder]? {
        var result: [MailFolder] = []
        for expected in mutation.after {
            let matches = hierarchy.filter { MailFolderPath.display(expected, isLocalArchive: false) == MailFolderPath.display($0, isLocalArchive: false) }
            guard matches.count == 1, let actual = matches.first, actual.isContainer == expected.isContainer else { return nil }
            let actualParent = actual.parentPath.map { MailFolderPath.display(.init(accountId: expected.accountId, path: $0, name: ""), isLocalArchive: false) }
            let expectedParent = expected.parentPath.map { MailFolderPath.display(.init(accountId: expected.accountId, path: $0, name: ""), isLocalArchive: false) }
            guard actualParent == expectedParent else { return nil }
            var resolved = expected; resolved.path = actual.path; resolved.parentPath = actual.parentPath
            result.append(resolved)
        }
        return result
    }

    private func descendants(_ path: String, folders: [MailFolder]) -> [MailFolder] {
        guard let root = folders.first(where: { $0.path == path }) else { return [] }
        var result = [root], seen: Set<String> = [root.path], index = 0
        let children = Dictionary(grouping: folders) { $0.parentPath }
        while index < result.count {
            for child in children[result[index].path] ?? [] where seen.insert(child.path).inserted { result.append(child) }
            index += 1
        }
        return result
    }

    private func sameMetadata(_ expected: MailFolder, _ actual: MailFolder) -> Bool {
        expected.path == actual.path && expected.name == actual.name && expected.parentPath == actual.parentPath
            && expected.delimiter == actual.delimiter && expected.role == actual.role && expected.isContainer == actual.isContainer
    }
    private func sameIncarnation(_ lhs: RemoteFolderStatus?, _ rhs: RemoteFolderStatus?) -> Bool {
        guard let first = lhs?.uidValidity, first > 0, let second = rhs?.uidValidity, first == second else { return false }
        return true
    }
    private func hierarchy(_ client: MailProtocolClient, accountID: UUID) async throws -> [MailFolder] {
        let folders = try await MailDeadline.call(budget.listFolders, label: "listFolders", client: client) { try await client.listFolders() }
        return MailSyncService.buildHierarchy(accountId: accountID, from: folders)
    }
    private func status(_ path: String, client: MailProtocolClient) async throws -> RemoteFolderStatus {
        let value = try await MailDeadline.call(budget.folderStatus, label: "folderStatus", client: client) { try await client.folderStatus(path: path) }
        guard value.messageCount >= 0, value.unreadCount >= 0 else { throw MailFolderMutationError.identityUnavailable }
        return value
    }
    private func open(_ client: MailProtocolClient, _ context: (account: MailAccount, password: String)) async throws {
        try await MailDeadline.openSession(client, username: context.account.username, password: context.password, budget: budget)
    }
    private func context(_ expected: MailAccount, allowPending: Bool) async throws -> (account: MailAccount, password: String) {
        guard let account = try await accounts.account(id: expected.id), MailService.sameFolderMutationAccount(account, expected), !account.isLocalArchive else { throw MailFolderMutationError.changed }
        guard account.isEnabled else { throw MailSyncError.accountDisabled }
        if !allowPending { try await mail.requireNoPendingFolderMutation(account.id) }
        guard let password = passwordProvider(account.id), !password.isEmpty else { throw MailSyncError.missingPassword }
        return (account, password)
    }
}
