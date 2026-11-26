import Foundation
import CryptoKit

public struct HostDataRow: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let content: String
    public let fields: [String: NativeAppValue]
    public init(id: String, title: String, content: String, fields: [String: NativeAppValue] = [:]) {
        self.id = id; self.title = title; self.content = content; self.fields = fields
    }
    public var stableUUID: UUID {
        let bytes = Array(SHA256.hash(data: Data(id.utf8)).prefix(16))
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],
                           bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
}

/// Complete, transient data. Oversized results fail rather than silently calculate on truncated rows.
public struct HostDataTable: Codable, Equatable, Sendable {
    public let columns: [String]
    public let rows: [HostDataRow]
    public let hasMore: Bool
    public let isComplete: Bool
    public init(columns: [String], rows: [HostDataRow], hasMore: Bool = false, isComplete: Bool = true) {
        self.columns = columns; self.rows = rows; self.hasMore = hasMore; self.isComplete = isComplete && !hasMore
    }
    public func validate() throws {
        guard columns.count <= 32, Set(columns).count == columns.count, columns.allSatisfy(NativeAppDefinition.validID),
              rows.count <= 1000, Set(rows.map(\.id)).count == rows.count,
              rows.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 512 && $0.title.utf8.count <= 512
                  && $0.content.utf8.count <= 32 * 1024 && $0.fields.count <= 32
                  && $0.fields.keys.allSatisfy(columns.contains) && $0.fields.values.allSatisfy(\.isBounded) }),
              try JSONEncoder().encode(self).count <= 4 * 1024 * 1024 else { throw NativeAppError(.tooLarge) }
    }
}

public struct HostCapabilityResult: Sendable {
    public let values: [String: NativeAppValue]
    public let table: HostDataTable?
    public init(values: [String: NativeAppValue] = [:], table: HostDataTable? = nil) { self.values = values; self.table = table }
}

public actor HostCapabilityReceipt {
    private var outcome: Result<HostCapabilityResult, any Error>?
    func complete(_ result: Result<HostCapabilityResult, any Error>) { if outcome == nil { outcome = result } }
    public func result() throws -> HostCapabilityResult {
        guard let outcome else { throw NativeAppError(.unavailable) }
        return try outcome.get()
    }
}
