import Foundation

// MARK: - System Bridge Tools（系统桥层：提醒事项 + 通知）

/// 桥层工具组：把宿主持有的系统能力（EventKit 提醒事项、UserNotifications）
/// 以受治理的工具面下放给调度 Agent。治理对齐三级门槛：
/// 读类（list）免确认；写类（create/complete/delete）与用户可见副作用（notify）走确认流

// MARK: - Reminders Create Tool

/// 新建提醒事项（写系统数据，需确认）
struct RemindersCreateTool: DispatcherTool {
    let service = RemindersService()

    var definition: ToolDefinition {
        ToolDefinition(
            name: "reminders_create",
            description: "Create a reminder in the system Reminders app. Use for actionable todos "
                + "the user asks to track (with or without a due date). "
                + "Priority: high/medium/low. Returns the new reminder id.",
            parametersSchemaJSON: #"{"type":"object","properties":{"title":{"type":"string","description":"Short actionable title, e.g. 'Reply to the design review email'"},"notes":{"type":"string","description":"Optional details or context"},"due_date":{"type":"string","description":"Optional due date/time, ISO 8601 (yyyy-MM-ddTHH:mm:ss) or yyyy-MM-dd HH:mm or yyyy-MM-dd. Compute it from the current time."},"priority":{"type":"string","enum":["high","medium","low"],"description":"Optional priority"}},"required":["title"]}"#
        )
    }
    let requiresConfirmation = true

    func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        let title = ToolArguments.string(args, "title").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw LLMError.configurationError(reason: "reminders_create requires a non-empty title")
        }
        let rawNotes = ToolArguments.string(args, "notes").trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = rawNotes.isEmpty ? nil : rawNotes
        var dueDate: Date?
        let dueRaw = ToolArguments.string(args, "due_date").trimmingCharacters(in: .whitespaces)
        if !dueRaw.isEmpty {
            guard let parsed = RemindersService.parseDueDate(dueRaw) else {
                throw RemindersService.RemindersError.invalidDate(dueRaw)
            }
            dueDate = parsed
        }
        let priority = RemindersService.priorityValue(for: ToolArguments.string(args, "priority"))
        do {
            let id = try await service.create(
                title: title,
                notes: notes,
                dueDate: dueDate,
                priority: priority
            )
            return "Reminder created (id: \(id)): \(title)"
        } catch let error as RemindersService.RemindersError where error == .notAuthorized || error == .denied {
            return RemindersService.denialGuidance()
        }
    }
}

// MARK: - Reminders List Tool

/// 查询提醒事项（只读，免确认）
struct RemindersListTool: DispatcherTool {
    let service = RemindersService()

    var definition: ToolDefinition {
        ToolDefinition(
            name: "reminders_list",
            description: "List open (incomplete) reminders from the system Reminders app, "
                + "soonest due first. Optionally filter by keyword.",
            parametersSchemaJSON: #"{"type":"object","properties":{"keyword":{"type":"string","description":"Optional keyword matched against titles and notes"},"limit":{"type":"integer","description":"Max results, 1-100. Default 20."}}}"#
        )
    }
    let requiresConfirmation = false
    /// 只读查询：不入副作用日志，可安全重试
    let sideEffectClass = ToolSideEffectClass.readOnly

    func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        let keyword = ToolArguments.string(args, "keyword").trimmingCharacters(in: .whitespaces)
        let limit = (args["limit"] as? Int) ?? 20
        do {
            let items = try await service.list(keyword: keyword.isEmpty ? nil : keyword, limit: limit)
            if items.isEmpty {
                return "No open reminders\(keyword.isEmpty ? "" : " matching '\(keyword)'")."
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate, .withTime]
            let lines = items.map { item -> String in
                var parts = ["\(item.id) | \(item.title)"]
                if let due = item.dueDate {
                    parts.append("due \(formatter.string(from: due))")
                }
                if item.priority > 0 {
                    parts.append("priority \(item.priority)")
                }
                if let list = item.listName {
                    parts.append("in \(list)")
                }
                return parts.joined(separator: " | ")
            }
            return "Open reminders (soonest first):\n" + lines.joined(separator: "\n")
        } catch let error as RemindersService.RemindersError where error == .notAuthorized || error == .denied {
            return RemindersService.denialGuidance()
        }
    }
}

// MARK: - Reminders Complete Tool

/// 标记提醒事项完成（写系统数据，需确认）
struct RemindersCompleteTool: DispatcherTool {
    let service = RemindersService()

    var definition: ToolDefinition {
        ToolDefinition(
            name: "reminders_complete",
            description: "Mark a reminder as completed in the system Reminders app. "
                + "Get the id from reminders_list first.",
            parametersSchemaJSON: #"{"type":"object","properties":{"id":{"type":"string","description":"Reminder id from reminders_list"}},"required":["id"]}"#
        )
    }
    let requiresConfirmation = true

    func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        let id = ToolArguments.string(args, "id").trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else {
            throw LLMError.configurationError(reason: "reminders_complete requires an id")
        }
        do {
            try await service.complete(id: id)
            return "Reminder \(id) marked completed."
        } catch let error as RemindersService.RemindersError where error == .notAuthorized || error == .denied {
            return RemindersService.denialGuidance()
        }
    }
}

// MARK: - Reminders Delete Tool

/// 删除提醒事项（不可恢复，需确认）
struct RemindersDeleteTool: DispatcherTool {
    let service = RemindersService()

    var definition: ToolDefinition {
        ToolDefinition(
            name: "reminders_delete",
            description: "Permanently delete a reminder from the system Reminders app (irreversible). "
                + "Get the id from reminders_list first. Prefer reminders_complete for finished items.",
            parametersSchemaJSON: #"{"type":"object","properties":{"id":{"type":"string","description":"Reminder id from reminders_list"}},"required":["id"]}"#
        )
    }
    let requiresConfirmation = true

    func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        let id = ToolArguments.string(args, "id").trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else {
            throw LLMError.configurationError(reason: "reminders_delete requires an id")
        }
        do {
            try await service.delete(id: id)
            return "Reminder \(id) deleted."
        } catch let error as RemindersService.RemindersError where error == .notAuthorized || error == .denied {
            return RemindersService.denialGuidance()
        }
    }
}

// MARK: - Notify User Tool

/// 发送系统通知（用户可见副作用，需确认）；
/// delay_minutes 走系统级定时触发——App 退出后依然送达（「X 分钟后提醒我」场景）
struct NotifyUserTool: DispatcherTool {
    let service = NotificationService()

    var definition: ToolDefinition {
        ToolDefinition(
            name: "notify_user",
            description: "Send the user a macOS system notification (visible even when the app is in the background). "
                + "With delay_minutes, schedules it at system level (fires even if the app has quit) — "
                + "use for 'remind me in N minutes' style requests (1 minute to 14 days). "
                + "For todos with a due date, prefer reminders_create.",
            parametersSchemaJSON: #"{"type":"object","properties":{"title":{"type":"string","description":"Short notification title"},"body":{"type":"string","description":"Notification body text"},"delay_minutes":{"type":"number","description":"Optional delay in minutes (min 1, max 20160). Omit to notify immediately."}},"required":["title","body"]}"#
        )
    }
    let requiresConfirmation = true

    func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        let title = ToolArguments.string(args, "title").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw LLMError.configurationError(reason: "notify_user requires a non-empty title")
        }
        let body = ToolArguments.string(args, "body").trimmingCharacters(in: .whitespacesAndNewlines)
        var delay: Double?
        if let minutes = args["delay_minutes"] as? Double {
            delay = minutes
        } else if let minutes = args["delay_minutes"] as? Int {
            delay = Double(minutes)
        }
        do {
            let id = try await service.send(title: title, body: body, delayMinutes: delay)
            if delay != nil {
                return "Notification scheduled (id: \(id)): will fire in \(Int(delay!)) minutes."
            }
            return "Notification sent (id: \(id))."
        } catch let error as NotificationService.NotificationError
            where error == .notAuthorized || error == .denied {
            return NotificationService.denialGuidance()
        }
    }
}
