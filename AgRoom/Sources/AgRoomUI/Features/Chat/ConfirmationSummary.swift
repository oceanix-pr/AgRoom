import Foundation
import AgRoomCore

@MainActor
enum ConfirmationSummary {
    static func text(tool: String, arguments: String, preview: FileChangePreview?) -> String {
        if let preview { return ConfirmationCard.previewSummary(preview) }
        if tool == "nativeapp_python_run" { return L.string("apps.script.approval.summary") }
        guard let data = arguments.data(using: .utf8),
              let args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return L.format("product.confirm.generic", tool)
        }
        func value(_ key: String) -> String { (args[key] as? String) ?? "" }
        switch tool {
        case "skill_create":
            return L.format("documentation.confirm.skill", value("alias"), value("description"))
        case "mail_send":
            return L.format("product.confirm.mail", [value("to"), value("cc"), value("bcc")].filter { !$0.isEmpty }.joined(separator: "; "), value("subject"))
        case "mail_save_draft": return L.format("product.confirm.draft", value("subject"))
        case "files_write", "file_write": return L.format("product.confirm.file", value("path"), value("content").count)
        case "files_edit": return L.format("product.confirm.file_edit", value("path"))
        case "project_build": return L.format("product.confirm.host_build", value("action"), value("directory").isEmpty ? L.string("product.confirm.current_workspace") : value("directory"))
        case "repo_symbols": return L.format("product.confirm.host_language_service", value("path"))
        case "files_delete": return L.format("product.confirm.delete", value("path"))
        case "files_mkdir": return L.format("product.confirm.folder", value("path"))
        case "shell_run":
            var lines = [L.string(value("execution_mode") == "host"
                ? "product.confirm.shell.host" : "product.confirm.shell.sandbox")]
            if !value("stdin_file").isEmpty { lines.append(L.format("product.confirm.shell.stdin", value("stdin_file"))) }
            let rawMode = ["overwrite", "append"].contains(value("output_mode")) ? value("output_mode") : "create"
            let mode = L.string("product.confirm.shell.mode." + rawMode)
            for key in ["stdout_file", "stderr_file"] where !value(key).isEmpty {
                lines.append(L.format("product.confirm.shell." + key, value(key), mode))
            }
            if !value("stdout_file").isEmpty || !value("stderr_file").isEmpty {
                lines.append(L.string("product.confirm.shell.publish"))
            }
            return lines.joined(separator: "\n")
        case "python_execute": return L.string("product.confirm.code.offline")
        case "skill_run_script": return L.format("product.confirm.skill.offline", value("name"), value("path"))
        case "sql_query": return L.string("product.confirm.sql")
        case "memory_update", "memory_save": return L.string("product.confirm.memory")
        case "knowledge_save": return L.format("product.confirm.knowledge", value("title"))
        case "backup_restore": return L.string("product.confirm.restore")
        default: return L.format("product.confirm.generic", tool)
        }
    }
}
