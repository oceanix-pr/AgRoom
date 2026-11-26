import Foundation
import AgRoomCore

// MARK: - Mail Error Text

/// 邮件错误 → 用户可见文案。
///
/// `MailSyncError` / `MailProtocolError` 的 `errorDescription` 是 Core 层给日志与
/// 智体工具用的英文描述，**不能直接展示给用户**：项目要求用户可见文案走三语。
/// 这里为每个 case 提供本地化映射，两个 `switch` 都是穷举的——新增错误 case 时
/// 编译器会直接报错，避免漏翻译。
///
/// 服务器返回的诊断细节（如 SMTP 拒绝原因）无法翻译，作为参数并入文案，
/// 保留其可操作性。
@MainActor
enum MailErrorText {

    /// 面向用户的错误文案（未知错误回落到通用提示 + 原始描述）。
    static func message(for error: Error) -> String {
        switch error {
        case let error as MailSignatureImportError: return L.string("mail.signature." + error.rawValue)
        case is MailFormattingError: return L.string("mail.compose.format.error")
        case let error as MailServerDraftError: return L.string("mail.serverDraft.error." + error.rawValue)
        case let error as MailSourceReferenceError: return L.string("mail.reference.error." + error.rawValue)
        case let error as MailComposePresetError: return L.string("mail.presets.error." + error.rawValue)
        case let error as MailFolderMutationError: return L.string("mail.folder.edit.error." + error.rawValue)
        case let error as MailMoveReviewError: return L.string("mail.move.error." + error.rawValue)
        case let error as MailSearchError: return L.string("mail.search.error." + error.rawValue)
        case let error as MailImportError: return L.string("mail.import.error." + error.rawValue)
        case let error as MailAttachmentError:
            switch error {
            case .capacity: return L.string("mail.compose.attachments.error.capacity")
            case .invalidMetadata: return L.string("mail.compose.attachments.error.metadata")
            case .corrupt: return L.string("mail.compose.attachments.error.corrupt")
            case .sourceNotReady: return L.string("mail.compose.attachments.error.source")
            }
        case let error as MailExportError:
            switch error {
            case .incomplete: return L.string("mail.export.error.incomplete")
            case .changed: return L.string("mail.export.error.changed")
            case .unsafeDestination: return L.string("mail.export.error.destination")
            case .tooLarge: return L.string("mail.export.error.tooLarge")
            case .renderingFailed: return L.string("mail.export.error.pdf")
            case .mboxRequiresEML: return L.string("mail.export.error.mboxRequiresEML")
            case .invalidLayout: return L.string("mail.export.error.layout")
            case .nameConflict: return L.string("mail.export.error.nameConflict")
            }
        case is SecureFileWriter.WriteError: return L.string("mail.export.error.destination")
        case is NativeAppError: return L.string("mail.export.error.destination")
        case is CancellationError: return L.string("mail.export.cancelled")
        case let error as MailConfigurationError:
            switch error {
            case .invalidPort(let kind): return L.format("mail.config.invalidPort", kind.rawValue.uppercased())
            case .implicitTLSRequired(let kind, let port): return L.format("mail.config.implicitTLSRequired", kind.rawValue.uppercased(), port)
            }
        case let error as MailConnectionTestError:
            return L.format("mail.test.stage." + error.stage.rawValue, message(for: error.underlying))
        case let error as MailSyncError:
            return message(for: error)
        case let error as MailProtocolError:
            return message(for: error)
        case let error as MailServerDiagnostic:
            return message(for: error)
        case let error as MailDeliveredLocalSaveError:
            if error.serverDraftCleanup { return L.string("mail.serverDraft.deliveredCleanupFailed") }
            // 已投递：文案必须给出「不要重发」的结论，而不是一个失败原因
            if error.missingSentFolder { return L.string("mail.compose.attachments.error.sentFolder") }
            return L.format("mail.error.deliveredLocalSave", error.underlying)
        default:
            return L.format("mail.error.generic", error.localizedDescription)
        }
    }

    static func message(for error: MailSyncError) -> String {
        switch error {
        case .accountNotFound:
            return L.string("mail.error.accountNotFound")
        case .accountDisabled:
            return L.string("mail.error.accountDisabled")
        case .missingPassword:
            return L.string("mail.error.missingPassword")
        case .folderNotFound:
            return L.string("mail.error.folderNotFound")
        case .messageNotFound:
            return L.string("mail.error.messageNotFound")
        case .deletionWouldAffectOthers:
            return L.string("mail.error.deleteBlockedByOthers")
        case .deletionMarkedButNotRemoved(let detail):
            return L.format("mail.error.deleteMarkedButNotRemoved", detail)
        case .deletionIncomplete:
            return L.string("mail.error.deleteIncomplete")
        case .moveNotReconciled:
            return L.string("mail.error.moveNotReconciled")
        case .draftAlreadyDelivered:
            return L.string("mail.error.draftAlreadyDelivered")
        case .deliveryStateNotRetryable:
            return L.string("mail.error.deliveryNotRetryable")
        }
    }

    /// 结构化服务器诊断 → 可操作提示：操作阶段 + 失败类别（含服务器状态）+ 脱敏原文 + 下一步动作。
    ///
    /// 例：`读取文件夹状态（「已发送」文件夹）失败：服务器拒绝了请求（NO）。服务器说明：Mailbox does not exist 请确认该文件夹是否存在…`
    static func message(for error: MailServerDiagnostic) -> String {
        let operation = L.string("mail.diag.op." + error.stage.rawValue)
        let folderPart = error.folder.map { L.format("mail.diag.folderPart", $0) } ?? ""
        var failure = L.string("mail.diag.kind." + error.kind.rawValue)
        if let status = error.status {
            failure += L.format("mail.diag.status", status)
        }
        if !error.detail.isEmpty {
            failure += L.format("mail.diag.detail", error.detail)
        }
        let summary = L.format("mail.diag.summary", operation, folderPart, failure)
        // BAD 是命令级协议错误，不能一律引导用户检查文件夹是否存在。
        let actionKey = error.kind == .serverRejected && error.status == "BAD"
            ? "mail.diag.action.invalidCommand"
            : "mail.diag.action." + error.kind.rawValue
        return summary + " " + L.string(actionKey)
    }

    static func message(for error: MailProtocolError) -> String {
        switch error {
        case .notConnected:
            return L.string("mail.error.notConnected")
        case .authenticationFailed(let detail):
            return L.format("mail.error.authentication", detail)
        case .connectionFailed(let detail):
            return L.format("mail.error.connection", detail)
        case .tlsUnsupported:
            return L.string("mail.error.tlsUnsupported")
        case .invalidResponse(let detail):
            return L.format("mail.error.serverResponse", detail)
        case .sendFailed(let detail):
            return L.format("mail.error.send", detail)
        case .timedOut:
            // 操作名（label）只进日志，不展示给用户
            return L.string("mail.error.timedOut")
        case .sendResultUnknown:
            return L.string("mail.error.sendResultUnknown")
        case .messageTooLarge(let detail):
            return L.format("mail.error.messageTooLarge", detail)
        }
    }
}
