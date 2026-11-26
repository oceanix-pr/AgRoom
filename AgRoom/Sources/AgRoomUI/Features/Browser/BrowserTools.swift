import Foundation
import AgRoomCore

// MARK: - Browser Tools

/// 调度 Agent 浏览器工具组：操作内置浏览器的标签页（与用户共用登录会话）。
/// BrowserService 在 AgRoomUI 层（WebKit 依赖），工具实现同层；
/// 通过闭包持有 service 引用（避免 Core 反向依赖 UI）。

// MARK: - Browser List Tool

/// 列出浏览器标签页：id、标题、URL、加载状态
public struct BrowserListTool: DispatcherTool {
    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_list",
            description: "List the tabs in the built-in browser. "
                + "Returns each tab's id (UUID), title, URL and loading state. "
                + "Use this to discover what the user already has open (e.g. a logged-in OA portal).",
            parametersSchemaJSON: #"{"type":"object","properties":{}}"#
        )
    }
    public let requiresConfirmation = false
    /// 只读：读取/导航/截图/滚动不改变页面数据或外部状态
    public let permissionClass = PermissionClass.readOnly
    /// 归属空间：工具只枚举/操作本空间的标签，不跨空间读写
    public let space: AppSpace
    public init(space: AppSpace) { self.space = space }

    public func execute(argumentsJSON: String) async throws -> String {
        let tabs = await MainActor.run { () -> [(id: String, title: String, url: String, loading: Bool)] in
            BrowserService.forSpace(space).tabs.map { tab in
                (
                    id: tab.id.uuidString,
                    title: tab.title,
                    url: tab.webView.url?.absoluteString ?? tab.urlText,
                    loading: tab.isLoading
                )
            }
        }
        guard !tabs.isEmpty else {
            return "No browser tabs open. Use browser_open to open a URL first."
        }
        let activeId = await MainActor.run { BrowserService.forSpace(space).activeTabId?.uuidString ?? "" }
        return tabs
            .map { tab in
                var line = "tab \(tab.id) | \(tab.title.isEmpty ? "(untitled)" : tab.title) | \(tab.url)"
                if tab.loading { line += " | loading" }
                if tab.id == activeId { line += " | ACTIVE" }
                return line
            }
            .joined(separator: "\n")
    }
}

// MARK: - Browser Open Tool

/// 打开（或复用）标签页并导航到 URL
public struct BrowserOpenTool: DispatcherTool {
    private static func url(argumentsJSON: String) -> URL? {
        let raw = ToolArguments.string(ToolArguments.parse(argumentsJSON), "url")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), BrowserInteractionSnapshot.origin(url) != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_open",
            description: "Open a URL in the built-in browser (reuses an existing tab on the same page). "
                + "Cookies persist between app launches, so pages the user logged into stay logged in. "
                + "Returns the tab id for subsequent browser_* calls. "
                + "For legacy IE-era enterprise systems (Dingjie EFGP, old OA portals) set legacy=true "
                + "to enable IE11 compatibility mode (UA spoofing); the domain is remembered afterwards.",
            parametersSchemaJSON: #"{"type":"object","properties":{"url":{"type":"string","description":"The http(s) URL to open"},"legacy":{"type":"boolean","description":"Enable IE11 compat mode for legacy enterprise systems (default false)"}},"required":["url"]}"#
        )
    }
    public let requiresConfirmation = false
    /// 只读：读取/导航/截图/滚动不改变页面数据或外部状态
    public let permissionClass = PermissionClass.readOnly
    /// 归属空间：只在本空间的标签池里打开/复用标签
    public let space: AppSpace
    public init(space: AppSpace) { self.space = space }

    public func validateArguments(argumentsJSON: String) throws {
        guard Self.url(argumentsJSON: argumentsJSON) != nil else {
            throw ToolExecutionFailure(message: "browser_open requires a valid http(s) URL without embedded credentials. Log in manually in the browser.")
        }
    }

    public func requiresHardConfirmation(argumentsJSON: String) -> Bool {
        guard let url = Self.url(argumentsJSON: argumentsJSON) else { return false }
        return BrowserNavigationPolicy.requiresActionApproval(url)
    }

    public func hardConfirmationReason(argumentsJSON: String) -> ConfirmationRequirement.HardReason { .browserAction }

    public func permissionClass(argumentsJSON: String) -> PermissionClass {
        requiresHardConfirmation(argumentsJSON: argumentsJSON) ? .externalEffect : .readOnly
    }

    public func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        let legacy = (args["legacy"] as? Bool) ?? false
        guard let url = Self.url(argumentsJSON: argumentsJSON) else {
            throw ToolExecutionFailure(message: "browser_open requires a valid http(s) URL without embedded credentials.")
        }
        let tabId = try await BrowserService.forSpace(space).open(url: url, legacy: legacy)

        return "Opened tab \(tabId.uuidString): \(url.absoluteString)"
    }
}

// MARK: - Browser Read Tool

/// 读取页面：标题、URL、正文文本、可交互元素清单（带 data-ah-id 编号）
public struct BrowserReadTool: DispatcherTool {
    private let documentationStore: DocumentationStore?
    public func modelResultCharacterLimit(argumentsJSON: String) -> Int {
        let args = ToolArguments.parse(argumentsJSON)
        return args["text_offset"] != nil || args["documentation_id"] != nil ? 32_000 : 6000
    }
    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_read",
            description: "Read a browser tab's page: title, URL, page text, and a numbered list of interactive elements. "
                + "Each element shows its [data-ah-id] number — use that number with browser_click or browser_fill. "
                + "Always read the page before clicking or filling to see the current state. "
                + "Includes link URLs, field values, form grouping, exact field names, disabled/read-only state and select option availability without running arbitrary JavaScript. "
                + "Use these observations to batch all same-form changes into one browser_fill plan; skip already-correct values and use wait_for_ready for dependent fields. Do not use browser_evaluate merely to inspect form readiness. Candidate labels are observations, not authorization. "
                + "Use element_id for a focused element/form inspection. After navigation or SPA re-rendering, pass wait_elements to wait for the page to settle. "
                + "For full documentation text, pass text_offset=0 and follow next_offset until null; this mode preserves code and supports long pages. "
                + "To fill a failed/dynamic chapter in a docs_collect collection, also pass documentation_id and documentation_page_id; the observed URL must match the chapter in this space. Read coverage is recorded and sources can then be bundled by skill_create.",
            parametersSchemaJSON: #"{"type":"object","properties":{"tab_id":{"type":"string","description":"Tab UUID from browser_open/browser_list"},"text_offset":{"type":"integer","minimum":0,"description":"Read rendered documentation as Markdown from this character offset, instead of the interactive-page summary."},"limit":{"type":"integer","minimum":1,"maximum":16000,"description":"Documentation chunk size, default 12000."},"documentation_id":{"type":"string","description":"Optional collection id from docs_collect; captures this observed chapter into the space-owned sources. After capture, use docs_read to continue the frozen text."},"documentation_page_id":{"type":"integer","description":"Observed page_id in that collection, required with documentation_id."},"element_id":{"type":"integer","description":"Optional: inspect one element and its form state in detail, using its observed data-ah-id"},"wait_elements":{"type":"integer","description":"Optional: wait until at least this many tagged elements exist (use after navigation/SPA re-render)"},"wait_timeout":{"type":"integer","description":"Optional wait timeout in seconds (1-30, default 10), only used with wait_elements"}},"required":["tab_id"]}"#
        )
    }
    public let requiresConfirmation = false
    /// 只读：读取/导航/截图/滚动不改变页面数据或外部状态
    public let permissionClass = PermissionClass.readOnly
    /// 归属空间：只读本空间的标签
    public let space: AppSpace
    public init(space: AppSpace, skillsDirectory: URL? = nil) {
        self.space = space
        self.documentationStore = skillsDirectory.map { DocumentationStore(skillsDirectory: $0) }
    }

    public func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        guard let tabId = UUID(uuidString: ToolArguments.string(args, "tab_id")) else {
            return "browser_read requires a valid 'tab_id' UUID."
        }
        // 可选等待：并入的原 browser_wait 能力（导航完成或元素出现再读，SPA 场景）
        if let minimum = args["wait_elements"] as? Int, minimum > 0 {
            var timeout: TimeInterval = 10
            if let seconds = args["wait_timeout"] as? Int {
                timeout = TimeInterval(min(max(seconds, 1), 30))
            }
            _ = try await BrowserService.forSpace(space).waitElements(
                tabId: tabId, minimum: minimum, timeout: timeout
            )
        }
        if args["text_offset"] != nil || args["documentation_id"] != nil {
            let doc = try await BrowserService.forSpace(space).readDocument(tabId: tabId)
            let offset = args["text_offset"] as? Int ?? 0
            let limit = args["limit"] as? Int ?? 12_000
            if args["documentation_id"] != nil {
                guard let documentationStore,
                      let id = UUID(uuidString: ToolArguments.string(args, "documentation_id")),
                      let pageID = args["documentation_page_id"] as? Int else {
                    throw ToolExecutionFailure(message: "Documentation capture requires a collection id and its observed documentation_page_id in this space.")
                }
                return try await documentationStore.capture(id, pageID: pageID, document: doc, offset: offset, limit: limit)
            }
            guard offset >= 0, offset < doc.markdown.count else { throw ToolExecutionFailure(message: "text_offset is outside the page. Start at 0 and follow next_offset.") }
            return try doc.readChunk(offset: offset, limit: limit).json
        }
        let content = try await BrowserService.forSpace(space).readPage(tabId: tabId, elementId: args["element_id"] as? Int)

        return content
    }
}

// MARK: - Browser Click Tool

/// Structured interactions have explicit task scopes; consequential/unknown actions stay one-shot.
public struct BrowserClickTool: DispatcherTool {
    private let service: @MainActor @Sendable () -> BrowserService
    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_click",
            description: "Click an interactive element on a browser page, identified by its data-ah-id number from browser_read. "
                + "Ordinary top-level links use native URL navigation, without running page click handlers. "
                + "The user may authorize same-origin navigation, structurally identified search forms or ARIA menu/tab controls for this task. These are candidates, not proof of server behavior. Submissions, script links and unknown actions require fresh approval. "
                + "Always read the page before acting and verify the result afterwards.",
            parametersSchemaJSON: #"{"type":"object","properties":{"tab_id":{"type":"string","description":"Tab UUID"},"element_id":{"type":"integer","description":"The data-ah-id number of the element to click"}},"required":["tab_id","element_id"]}"#
        )
    }
    public init(space: AppSpace) {
        self.space = space
        self.service = { BrowserService.forSpace(space) }
    }

    init(space: AppSpace, service: @escaping @MainActor @Sendable () -> BrowserService) {
        self.space = space
        self.service = service
    }

    /// 归属空间：只操作本空间的标签
    public let space: AppSpace

    public var requiresConfirmation: Bool { true }

    /// Only native navigation can receive this origin-scoped authority.
    public var confirmationScope: ConfirmationRequirement.Scope { .domain }

    public func validateArguments(argumentsJSON: String) throws {
        _ = try BrowserInteractionArguments.click(argumentsJSON, space: space)
    }

    public func requiresHardConfirmation(argumentsJSON: String) -> Bool {
        guard let action = try? BrowserInteractionArguments.click(argumentsJSON, space: space) else { return true }
        return action.element.repeatableKind == nil
    }

    public func hardConfirmationReason(argumentsJSON: String) -> ConfirmationRequirement.HardReason { .browserAction }

    public func roundAuthorizationKey(argumentsJSON: String) -> String? {
        guard let action = try? BrowserInteractionArguments.click(argumentsJSON, space: space) else { return nil }
        return action.snapshot.interactionKey(element: action.element)
    }

    public func approvalRoute(argumentsJSON: String) -> ApprovalRoute {
        guard let action = try? BrowserInteractionArguments.click(argumentsJSON, space: space),
              action.element.repeatableKind != nil else { return .manualOnly }
        return .modelReviewable
    }

    public func autoReviewEvidence(argumentsJSON: String) -> [String: String] {
        guard let action = try? BrowserInteractionArguments.click(argumentsJSON, space: space),
              let kind = action.element.repeatableKind,
              let origin = action.snapshot.url.flatMap(BrowserInteractionSnapshot.origin),
              let frame = URL(string: action.element.frameURL), BrowserInteractionSnapshot.origin(frame) == origin else { return [:] }
        return ["execution_profile": "browser_structured", "browser_policy": "structured/v1",
                "operation": kind, "space": space.rawValue, "origin": origin,
                "page_title": action.snapshot.title, "target": action.element.label,
                "form_contract": BrowserInteractionSnapshot.digest([action.element.formContract ?? ""]),
                "destination": action.element.navigationURL?.absoluteString ?? action.element.formAction ?? "",
                "form_fields": action.element.formFields.map { "\($0.label): \($0.value)" }.joined(separator: "\n"),
                "execution_identity": action.executionKey, "evidence_truncated": String(action.element.formTruncated)]
    }

    public func executionAuthorizationKey(argumentsJSON: String) -> String? {
        try? BrowserInteractionArguments.click(argumentsJSON, space: space).executionKey
    }

    public func approvalPresentation(argumentsJSON: String) -> ToolApprovalPresentation? {
        guard let action = try? BrowserInteractionArguments.click(argumentsJSON, space: space) else { return nil }
        return action.snapshot.presentation(
            kind: action.element.repeatableKind ?? "browser_action", targets: [action.element])
    }

    public func execute(argumentsJSON: String) async throws -> String {
        try await execute(argumentsJSON: argumentsJSON, authorizationKey: executionAuthorizationKey(argumentsJSON: argumentsJSON))
    }

    public func execute(argumentsJSON: String, authorizationKey: String?) async throws -> String {
        let action = try BrowserInteractionArguments.click(argumentsJSON, space: space)
        guard authorizationKey == action.executionKey else {
            throw ToolExecutionFailure(message: "The approved browser action changed. Read again and request fresh approval.")
        }
        let result = try await service().clickElement(
            tabId: action.snapshot.tabID, elementId: action.element.id,
            authorizationKey: action.snapshot.pageKey, expectedElement: action.element)

        return result
    }
}

// MARK: - Browser Fill Tool

/// One review covers an ordered form plan, including deferred fields; input events may save remotely.
public struct BrowserFillTool: DispatcherTool {
    private let service: @MainActor @Sendable () -> BrowserService
    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_fill",
            description: "Fill form fields on a browser page after confirmation. Input/change handlers may save data remotely. Sensitive fields require manual entry. "
                + "Pass an array of {element_id, value} pairs using data-ah-id numbers from browser_read. "
                + "Batch all independent fields of the same form in ONE call to avoid repeated approval. "
                + "One approval covers this whole ordered plan, including dependent fields; submission is separate. "
                + "For a dependent field pass wait_for_ready=true to wait for enabled state and select options. For a field that appears later, pass its exact field_name instead of element_id, with wait_for_ready=true and form_element_id identifying an observed element of the same form. Never replay completed fields after a partial failure.",
            parametersSchemaJSON: #"{"type":"object","properties":{"tab_id":{"type":"string","description":"Tab UUID"},"fields":{"type":"array","items":{"type":"object","properties":{"element_id":{"type":"integer"},"field_name":{"type":"string","description":"Exact name of a deferred field in the anchored form; exclusive with element_id"},"value":{"type":"string"},"wait_for_ready":{"type":"boolean","description":"Wait up to 10 seconds for this dependent field and its option"}},"required":["value"]},"description":"Ordered concrete fill plan"},"form_element_id":{"type":"integer","description":"Observed anchor in the same form; required for deferred field names"}},"required":["tab_id","fields"]}"#
        )
    }
    public let requiresConfirmation = true
    public init(space: AppSpace) {
        self.space = space
        self.service = { BrowserService.forSpace(space) }
    }

    init(space: AppSpace, service: @escaping @MainActor @Sendable () -> BrowserService) {
        self.space = space
        self.service = service
    }

    /// 归属空间：只填本空间的表单
    public let space: AppSpace

    public func validateArguments(argumentsJSON: String) throws {
        _ = try BrowserInteractionArguments.fill(argumentsJSON, space: space)
    }

    public func roundAuthorizationKey(argumentsJSON: String) -> String? {
        // Plans are consumed once; repeating a filled plan may repeat remote auto-save.
        return nil
    }

    public func executionAuthorizationKey(argumentsJSON: String) -> String? {
        try? BrowserInteractionArguments.fill(argumentsJSON, space: space).executionKey
    }

    public func approvalPresentation(argumentsJSON: String) -> ToolApprovalPresentation? {
        guard let action = try? BrowserInteractionArguments.fill(argumentsJSON, space: space) else { return nil }
        return action.presentation
    }

    public func execute(argumentsJSON: String) async throws -> String {
        try await execute(argumentsJSON: argumentsJSON, authorizationKey: executionAuthorizationKey(argumentsJSON: argumentsJSON))
    }

    public func execute(argumentsJSON: String, authorizationKey: String?) async throws -> String {
        let action = try BrowserInteractionArguments.fill(argumentsJSON, space: space)
        guard authorizationKey == action.executionKey else {
            throw ToolExecutionFailure(message: "The approved form changed. Read again and request fresh approval.")
        }
        return try await service().fillPlan(action)
    }
}

// MARK: - Browser Screenshot Tool

/// 截图：保存 PNG 到临时目录并返回路径
public struct BrowserScreenshotTool: DispatcherTool {
    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_screenshot",
            description: "Take a screenshot of a browser tab's visible area and save it as a PNG file. "
                + "Returns the file path. Useful for capturing visual state or results.",
            parametersSchemaJSON: #"{"type":"object","properties":{"tab_id":{"type":"string","description":"Tab UUID"}},"required":["tab_id"]}"#
        )
    }
    public let requiresConfirmation = false
    /// 只读：读取/导航/截图/滚动不改变页面数据或外部状态
    public let permissionClass = PermissionClass.readOnly
    /// 归属空间：只截本空间的标签
    public let space: AppSpace
    public init(space: AppSpace) { self.space = space }

    public func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        guard let tabId = UUID(uuidString: ToolArguments.string(args, "tab_id")) else {
            return "browser_screenshot requires a valid 'tab_id' UUID."
        }
        let path = try await BrowserService.forSpace(space).screenshot(tabId: tabId)
        return "Screenshot saved: \(path)"
    }
}

// MARK: - Browser Scroll Tool

/// 滚动页面：按方向翻页或滚动到指定元素；返回滚动后可视区的元素清单
public struct BrowserScrollTool: DispatcherTool {
    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_scroll",
            description: "Scroll a browser page: N screens up/down, or scroll a specific element into view. "
                + "Returns the scroll position and the interactive elements currently visible in the viewport. "
                + "Use for long or lazily-loaded pages where browser_read only shows the top.",
            parametersSchemaJSON: #"{"type":"object","properties":{"tab_id":{"type":"string","description":"Tab UUID"},"direction":{"type":"string","enum":["up","down"],"description":"Direction of screen-by-screen scrolling (default down)"},"pages":{"type":"integer","description":"Number of screens to scroll (1-10, default 1)"},"to_element_id":{"type":"integer","description":"Optional: scroll this data-ah-id element into view instead of direction scrolling"}},"required":["tab_id"]}"#
        )
    }
    public let requiresConfirmation = false
    /// 只读：读取/导航/截图/滚动不改变页面数据或外部状态
    public let permissionClass = PermissionClass.readOnly
    /// 归属空间：只滚动本空间的标签
    public let space: AppSpace
    public init(space: AppSpace) { self.space = space }

    public func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        guard let tabId = UUID(uuidString: ToolArguments.string(args, "tab_id")) else {
            return "browser_scroll requires a valid 'tab_id' UUID."
        }
        let direction = ToolArguments.string(args, "direction").lowercased() == "up" ? "up" : "down"
        var pages = args["pages"] as? Int ?? 1
        pages = min(max(pages, 1), 10)
        let toElementId = args["to_element_id"] as? Int
        return try await BrowserService.forSpace(space).scrollPage(
            tabId: tabId,
            direction: direction,
            pages: pages,
            toElementId: toElementId
        )
    }
}

// MARK: - Browser Evaluate Tool

/// 执行任意 JS（只读兜底通道）：结构化工具覆盖不了的"读"场景由此打通——
/// 提取 onclick 里的弹窗 URL、访问同源 iframe 内部、核对字段值与勾选状态。
/// 写操作禁止走此通道（直调页面函数/改 DOM/fetch 提交会绕过原生事件链与服务端点击日志）：
/// 任意脚本逐次硬确认，无视站点授权与本轮授权。
public struct BrowserEvaluateTool: DispatcherTool {
    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_evaluate",
            description: "Run JavaScript in a browser tab's main frame and return the result as JSON. READ-ONLY: "
                + "inspect DOM structure, read field values/attributes (e.g. extract the real URL behind an onclick attribute), "
                + "reach into same-origin iframes/framesets (document.querySelectorAll('iframe, frame')[0].contentDocument), "
                + "or verify form state — especially useful in legacy IE-era systems with framesets and nested iframes. "
                + "NEVER use it to change the page or submit data: do not call the page's own functions (e.g. *_onclick(), "
                + "submit or dialog handlers), do not assign DOM properties (.value = / .checked = / .innerHTML =), "
                + "and do not post forms via fetch/XHR/.submit() — such calls bypass the page's native event chain "
                + "and leave no button-click trail in server-side operation logs. "
                + "All clicks and field changes must go through browser_click / browser_fill on real elements; "
                + "if they cannot reach the target, stop and tell the user instead of mutating via script. "
                + "Scripts that look like page mutations always require explicit user confirmation. "
                + "Return a value (e.g. an object or expression) — it is serialized back to you.",
            parametersSchemaJSON: #"{"type":"object","properties":{"tab_id":{"type":"string","description":"Tab UUID"},"script":{"type":"string","description":"JavaScript expression or statements to run in the page's main frame"}},"required":["tab_id","script"]}"#
        )
    }
    public init(space: AppSpace) { self.space = space }

    /// 归属空间：只在本空间的标签里执行脚本
    public let space: AppSpace

    public var requiresConfirmation: Bool { true }

    /// 任意 JavaScript 无法通过黑名单证明只读；每次执行都需明确确认。
    public var confirmationScope: ConfirmationRequirement.Scope { .script }

    /// 任意脚本不提供站点级或本轮免确认。
    public func roundAuthorizationKey(argumentsJSON: String) -> String? {
        nil
    }

    /// 任意脚本逐次必问，不能用黑名单证明 JavaScript 只读。
    public func requiresHardConfirmation(argumentsJSON: String) -> Bool {
        true
    }

    /// 硬确认原因：任意脚本。
    public func hardConfirmationReason(argumentsJSON: String) -> ConfirmationRequirement.HardReason {
        .arbitraryScript
    }

    public func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        guard let tabId = UUID(uuidString: ToolArguments.string(args, "tab_id")),
              !ToolArguments.string(args, "script").isEmpty else {
            return "browser_evaluate requires 'tab_id' (UUID) and 'script' (JavaScript)."
        }
        let script = ToolArguments.string(args, "script")
        let result = try await BrowserService.forSpace(space).evaluate(tabId: tabId, script: script)

        return result
    }
}
