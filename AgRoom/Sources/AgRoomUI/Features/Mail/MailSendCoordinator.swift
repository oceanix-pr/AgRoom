import Foundation
import Observation
import AgRoomCore

// MARK: - Send Outcome

/// 发送结果四态。
///
/// 之所以不是 Bool：SMTP 投递超时的语义是**二义**的——服务器可能已经收下这封邮件，
/// 也可能没有。必须与「明确失败」区分开，否则界面会引导用户直接重发，造成重复投递
/// （见 `MailProtocolError.sendResultUnknown`）。
enum MailSendOutcome: Equatable {
    /// 已投递且本地副本已落盘。
    case sent
    /// 明确失败：未投递，修正后可以重试。
    case failed(String)
    /// 结果未知：可能已投递。草稿保留，需用户到服务器核实后再决定。
    case resultUnknown(String)
    /// **已投递**，但本地「已发送」副本或草稿清理失败。
    ///
    /// 与 `failed` 的区别是决定性的：邮件真的发出去了，重发会造成重复投递。
    /// 草稿连同投递凭证仍在本地，界面必须禁止在原文上重发。
    case deliveredLocalSaveFailed(String)
}

// MARK: - Mail Data Change

extension Notification.Name {
    /// 邮件本地数据发生变化（发送完成、草稿保存等）：邮箱页据此刷新列表与草稿菜单。
    static let mailDataChanged = Notification.Name("agroom.mail.dataChanged")
}

// MARK: - Mail Send Coordinator

/// 发送协调对象：持有进行中的发送任务与**固定的空间上下文**。
///
/// 存在理由：撰写窗口可以在发送中被关闭，而 SMTP 投递已经开始——不能因为界面消失就
/// 丢掉任务、也不能让发送生命周期绑在某个邮箱页的 ViewModel 上。协调对象独立持有
/// 任务，投递结果仍按既有策略落回**原空间**的数据库，邮箱页通过通知刷新列表。
@MainActor
@Observable
final class MailSendCoordinator {
    static let shared = MailSendCoordinator()

    /// 进行中的发送（草稿 ID）；用于界面提示与退出协调。
    private(set) var inFlightDraftIds: Set<UUID> = []

    private init() {}

    /// 是否有发送进行中（应用退出前需要处理）。
    var hasInFlightSends: Bool { !inFlightDraftIds.isEmpty }

    func isSending(draftID: UUID) -> Bool { inFlightDraftIds.contains(draftID) }

    /// 发送草稿：成功后刷新邮箱页列表；失败按四态返回，绝不把「已投递」报成失败。
    func send(_ draft: MailDraft, space: AppSpace, hub: Hub) async -> MailSendOutcome {
        guard let syncService = hub.makeMailSyncService(for: space) else {
            return .failed(L.string("mail.error.serviceUnavailable"))
        }
        inFlightDraftIds.insert(draft.id)
        defer {
            inFlightDraftIds.remove(draft.id)
            NotificationCenter.default.post(name: .mailDataChanged, object: nil)
        }
        do {
            _ = try await syncService.send(draft: draft)
            return .sent
        } catch {
            HubLogger.shared.warning("Mail UI operation failed: \(HubLogger.safeErrorSummary(error))")
            if error is MailDeliveredLocalSaveError {
                // 已投递：草稿连同投递凭证保留，提示核实而不是重发
                return .deliveredLocalSaveFailed(MailErrorText.message(for: error))
            }
            let message = MailErrorText.message(for: error)
            if let protocolError = error as? MailProtocolError, case .sendResultUnknown = protocolError {
                return .resultUnknown(message)
            }
            if let syncError = error as? MailSyncError, case .deliveryStateNotRetryable = syncError {
                // 草稿处于「发送中 / 结果未知」：无法确认没发出，锁住发送，绝不引导重发
                return .resultUnknown(message)
            }
            return .failed(message)
        }
    }
}
