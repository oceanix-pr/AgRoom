import Foundation

/// Pure, internal preflight. A candidate never authorizes a file move, cleanup,
/// or Daemon resume: probe routing is supplied by the caller, and both files
/// and the space database must be revalidated under a future migration gate.
enum DaemonLegacyMigrationPlanner {
    struct SpaceProbe: Sendable {
        let declaredSpace: AppSpace
        /// Captured from the exact expectation passed to a space-bound
        /// SessionService. The planner rejects a result for another run.
        let expectation: LegacyDaemonRecordExpectation
        let result: LegacyDaemonRecordProbeResult

        init(space: AppSpace, expectation: LegacyDaemonRecordExpectation,
             result: LegacyDaemonRecordProbeResult) {
            declaredSpace = space
            self.expectation = expectation
            self.result = result
        }
    }

    struct Input: Sendable {
        let located: LocatedDaemonRecord
        let target: SpaceProbe

        init(located: LocatedDaemonRecord, target: SpaceProbe) {
            self.located = located
            self.target = target
        }
    }

    enum CandidateKind: Sendable, Equatable {
        /// A later executor must also prove the DB message is terminal and
        /// the journal has no unresolved intent before deleting old bytes.
        case completedReview
        /// Keep the same recovery-required state and execution block intact.
        case recoveryRetention
    }

    enum DeferralReason: Sendable, Equatable {
        case inventoryIncomplete, globalUnknownEvidence
        case duplicateInput, missingFileGroup, untrustedFileGroup
        case fileIdentityMismatch, bodyVersionMismatch, nonLegacyOrigin, unsupportedState
        case probeSpaceMismatch, probeExpectationMismatch, targetNotExact
    }

    enum Disposition: Sendable, Equatable {
        case preflightCandidate(CandidateKind)
        case deferred(DeferralReason)
    }

    struct Decision: Sendable, Equatable {
        let recordID: UUID
        let declaredSpace: AppSpace
        let disposition: Disposition
    }

    static func assess(report: DaemonLegacyInventory.Report, inputs: [Input]) -> [Decision] {
        let counts = Dictionary(grouping: inputs, by: { $0.located.record.id }).mapValues(\.count)
        let groups = Dictionary(grouping: report.groups, by: \.id)
        return inputs.map { input in
            let record = input.located.record
            let reason: DeferralReason?
            if !report.summary.isComplete {
                reason = .inventoryIncomplete
            } else if report.summary.hasUnknownEvidence {
                reason = .globalUnknownEvidence
            } else if counts[record.id] != 1 {
                reason = .duplicateInput
            } else if input.located.origin != .legacyRoot {
                reason = .nonLegacyOrigin
            } else if input.target.declaredSpace != record.space {
                reason = .probeSpaceMismatch
            } else if let matchingGroups = groups[record.id] {
                guard matchingGroups.count == 1, let group = matchingGroups.first else {
                    return Decision(recordID: record.id, declaredSpace: record.space,
                                    disposition: .deferred(.untrustedFileGroup))
                }
                switch group.ownership {
                case let .fileCorroborated(space, sessionID, messageID, taskRunID):
                    if space != record.space || sessionID != record.sessionId ||
                        messageID != record.assistantMessageId ||
                        taskRunID != record.settings.taskAuthorization?.runID {
                        reason = .fileIdentityMismatch
                    } else if group.bodySHA256 == nil ||
                                group.bodyState != DaemonLegacyInventory.bodyState(record.state) ||
                                group.restorationTokenSHA256 !=
                                    DaemonLegacyInventory.restorationTokenSHA256(record.restorationToken) ||
                                group.canonicalRunSHA256 == nil ||
                                group.canonicalRunSHA256 != DaemonLegacyInventory.canonicalRunSHA256(record) {
                        // The input record must be the same complete decoded
                        // body that Inventory hashed. A later executor must
                        // still reread raw source SHA-256 before any mutation.
                        reason = .bodyVersionMismatch
                    } else {
                        reason = nil
                    }
                case .unknown:
                    reason = .untrustedFileGroup
                }
            } else {
                reason = .missingFileGroup
            }
            if let reason {
                return Decision(recordID: record.id, declaredSpace: record.space,
                                disposition: .deferred(reason))
            }
            let expected = LegacyDaemonRecordExpectation(record: record)
            guard input.target.expectation == expected else {
                return Decision(recordID: record.id, declaredSpace: record.space,
                                disposition: .deferred(.probeExpectationMismatch))
            }
            let kind: CandidateKind
            switch groups[record.id]?.first?.bodyState {
            case .completed?: kind = .completedReview
            case .recoveryRequired?: kind = .recoveryRetention
            default:
                return Decision(recordID: record.id, declaredSpace: record.space,
                                disposition: .deferred(.unsupportedState))
            }
            guard input.target.result == .exact else {
                return Decision(recordID: record.id, declaredSpace: record.space,
                                disposition: .deferred(.targetNotExact))
            }
            // No other-space probe or fallback is part of this API. Equal
            // UUIDs in physically separate space databases remain independent.
            return Decision(recordID: record.id, declaredSpace: record.space,
                            disposition: .preflightCandidate(kind))
        }.sorted {
            ($0.declaredSpace.rawValue, $0.recordID.uuidString) <
                ($1.declaredSpace.rawValue, $1.recordID.uuidString)
        }
    }
}
