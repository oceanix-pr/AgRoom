import Foundation
import GRDB
import CryptoKit
import Darwin

public enum MaintenanceError: Error, Sendable { case busy, unavailable }

public extension Notification.Name {
    static let agroomSpaceRestored = Notification.Name("agroom.space.restored")
}

/// OS leases cover all instances and processes. Task-local ownership permits nested service calls.
enum ResourceMaintenance {
    @TaskLocal static var owned: Set<String> = []
    static func directoryKey(_ url: URL) -> String { "directory:" + url.standardizedFileURL.resolvingSymlinksInPath().path }
    final class Lease: @unchecked Sendable {
        private let fd: Int32
        init(key: String, exclusive: Bool) throws {
            let url: URL
            if key.hasPrefix("memory:") || key.hasPrefix("directory:") {
                let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
                url = FileManager.default.temporaryDirectory.appendingPathComponent("agroom-maintenance-\(digest).lock")
            } else { url = URL(fileURLWithPath: key + ".maintenance.lock") }
            let handle = Darwin.open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard handle >= 0 else { throw MaintenanceError.unavailable }
            guard flock(handle, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
                Darwin.close(handle)
                throw MaintenanceError.busy
            }
            fd = handle
        }
        deinit { flock(fd, LOCK_UN); Darwin.close(fd) }
    }
    static func withExclusive<T: Sendable>(_ keys: [String], operation: () async throws -> T) async throws -> T {
        let keys = Set(keys)
        let leases = try keys.subtracting(owned).sorted().map { try Lease(key: $0, exclusive: true) }
        defer { withExtendedLifetime(leases) {} }
        return try await $owned.withValue(owned.union(keys)) { try await operation() }
    }
    static func withAccess<T>(_ key: String, operation: () throws -> T) throws -> T {
        let lease = owned.contains(key) ? nil : try Lease(key: key, exclusive: false)
        defer { withExtendedLifetime(lease) {} }
        return try operation()
    }
    static func withAsyncAccess<T: Sendable>(_ key: String, operation: () async throws -> T) async throws -> T {
        let lease = owned.contains(key) ? nil : try Lease(key: key, exclusive: false)
        defer { withExtendedLifetime(lease) {} }
        return try await operation()
    }
}

extension DatabaseQueue {
    var maintenanceKey: String { path == ":memory:" ? "memory:\(ObjectIdentifier(self))" : path }
    func maintenanceWrite<T: Sendable>(_ updates: @Sendable (Database) throws -> T) async throws -> T {
        let lease = ResourceMaintenance.owned.contains(maintenanceKey) ? nil : try ResourceMaintenance.Lease(key: maintenanceKey, exclusive: false)
        defer { withExtendedLifetime(lease) {} }
        return try await write(updates)
    }
}
