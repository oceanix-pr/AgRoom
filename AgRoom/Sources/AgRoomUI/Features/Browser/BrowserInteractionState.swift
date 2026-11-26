import CoreFoundation
import CryptoKit
import Foundation
import AgRoomCore

enum BrowserNavigationPolicy {
    /// Additional protection for visibly consequential destinations, shared by click and open.
    /// This never proves arbitrary scripts safe or changes the native-navigation contract.
    static func requiresActionApproval(_ url: URL, label: String = "") -> Bool {
        let intent = (label + " " + url.path + " " + (url.query ?? "")).removingPercentEncoding?.lowercased() ?? ""
        let consequential = ["submit", "delete", "remove", "approve", "reject", "send", "purchase", "save",
                             "checkout", "payment", "transfer", "logout", "signout", "revoke", "permission",
                             "提交", "删除", "刪除", "审批", "審批", "批准", "发送", "發送", "付款", "支付", "授权", "授權"]
        return consequential.contains(where: intent.contains)
    }
}

/// WebKit's isolated world supplies observations, never authorization decisions.
/// The cache contains immutable values only; the live DOM is checked again by BrowserService.
struct BrowserElementSnapshot: Codable, Sendable, Equatable {
    struct Field: Codable, Sendable, Equatable {
        let label: String
        let value: String
    }

    let id: Int
    let identity: String
    let fingerprint: String
    let scopeIdentity: String
    let tag: String
    let type: String
    let label: String
    let href: String
    let target: String
    let frameURL: String
    let topFrame: Bool
    let hasClickHandler: Bool
    let navigationCandidate: Bool
    let sensitive: Bool
    let editable: Bool
    let selectOptions: [String]
    let formIdentity: String
    let formFields: [Field]
    let formTruncated: Bool
    // Host observations, not permission supplied by the page or the executing model.
    let controlKind: String?
    let formAction: String?
    let formContract: String?
    let fieldName: String?
    let fillable: Bool?

    /// This is a *native URL navigation* contract, not a claim that arbitrary click handlers are safe.
    /// Script links, forms, downloads and unfamiliar targets always stay on the one-shot click route.
    var repeatableKind: String? {
        if navigationURL != nil { return "browser_navigation" }
        guard !sensitive, !formTruncated,
              let url = URL(string: frameURL),
              !BrowserNavigationPolicy.requiresActionApproval(url, label: label + " " + href + " " + (formAction ?? "")) else { return nil }
        switch controlKind {
        case "query":
            guard let action = formAction.flatMap(URL.init(string:)),
                  BrowserInteractionSnapshot.origin(action) == BrowserInteractionSnapshot.origin(url),
                  action.user == nil, action.password == nil,
                  !(URLComponents(url: action, resolvingAgainstBaseURL: false)?.queryItems ?? []).contains(where: {
                      ["token", "key", "secret", "password", "code", "otp", "access_token", "api_key"].contains($0.name.lowercased())
                  }) else { return nil }
            return "browser_query"
        case "control": return "browser_control"
        default: return nil
        }
    }

    var navigationURL: URL? {
        guard tag == "a", topFrame, navigationCandidate, !hasClickHandler, formIdentity.isEmpty,
              ["", "_self", "_top"].contains(target.lowercased()),
              let url = URL(string: href), BrowserInteractionSnapshot.origin(url) != nil,
              url.user == nil, url.password == nil else { return nil }
        let credentialNames = ["token", "key", "secret", "password", "code", "otp", "access_token", "api_key"]
        guard !(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .contains(where: { credentialNames.contains($0.name.lowercased()) }) else { return nil }
        guard !BrowserNavigationPolicy.requiresActionApproval(url, label: label) else { return nil }
        return url
    }
}

struct BrowserInteractionSnapshot: Sendable {
    let space: AppSpace
    let tabID: UUID
    let documentVersion: UUID
    let readVersion: UUID
    let taskGeneration: UUID
    let url: URL?
    let title: String
    let elements: [Int: BrowserElementSnapshot]

    static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }

    var pageKey: String { "browser-page#\(tabID.uuidString)#\(readVersion.uuidString)" }

    func navigationKey(element: BrowserElementSnapshot) -> String? {
        guard let url, let source = Self.origin(url),
              let target = element.navigationURL, Self.origin(target) == source else { return nil }
        // RoundAuthorizationStore supplies run ownership and lifetime. A cross-origin visit rotates
        // taskGeneration, so returning to an earlier site cannot revive its former grant.
        return "browser-navigation/v2#\(space.rawValue)#\(tabID)#\(taskGeneration)#\(source)"
    }

    func interactionKey(element: BrowserElementSnapshot) -> String? {
        guard let kind = element.repeatableKind else { return nil }
        if kind == "browser_navigation" { return navigationKey(element: element) }
        guard let url, let source = Self.origin(url), let frame = URL(string: element.frameURL),
              Self.origin(frame) == source else { return nil }
        // Menus share an explicitly approved task capability. Queries remain bound to one
        // form contract. Neither capability authorizes submission or unknown/script buttons.
        let contract = kind == "browser_query" ? element.formContract ?? "" : "structured-controls"
        guard !contract.isEmpty else { return nil }
        return "browser-interaction/v1#" + Self.digest([
            space.rawValue, tabID.uuidString, taskGeneration.uuidString, source, kind, contract
        ])
    }

    func executionKey(elements: [BrowserElementSnapshot], values: [String] = []) -> String {
        Self.digest([space.rawValue, pageKey, documentVersion.uuidString,
                     elements.map { $0.identity + ":" + $0.fingerprint }.joined(separator: "|")] + values)
    }

    static func digest(_ values: [String]) -> String {
        let data = (try? JSONEncoder().encode(values)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func presentation(kind: String, targets: [BrowserElementSnapshot], values: [String] = []) -> ToolApprovalPresentation {
        let fields: [ToolApprovalPresentation.BrowserAction.Field]
        if kind == "browser_fill" {
            fields = zip(targets, values).map { .init(label: $0.label, value: $1) }
        } else {
            fields = (targets.first?.formFields ?? []).map { .init(label: $0.label, value: $0.value) }
        }
        let browser = ToolApprovalPresentation.BrowserAction(
            pageTitle: title, origin: url.flatMap(Self.origin),
            targetLabel: kind == "browser_fill" ? nil : targets.first?.label,
            destination: targets.first?.navigationURL?.absoluteString
                ?? (kind == "browser_query" ? targets.first?.formAction : nil), fields: fields,
            formTruncated: targets.first?.formTruncated ?? false)
        return ToolApprovalPresentation(
            executionKind: .other,
            resourceAccess: .init(verified: false),
            network: .init(allowed: true), childProcesses: .init(allowed: false),
            reasonCode: kind, constraintSources: ["space", "task", "browserSnapshot"],
            executionDetails: fields.map { "\($0.label): \($0.value)" }, browserAction: browser
        )
    }
}

/// The lock protects only value copies. No WebKit, I/O, callbacks or awaits inside it.
final class BrowserInteractionSnapshotCache: @unchecked Sendable {
    static let shared = BrowserInteractionSnapshotCache()
    private let lock = NSLock()
    private var snapshots: [UUID: BrowserInteractionSnapshot] = [:]

    func snapshot(tabID: UUID, space: AppSpace) -> BrowserInteractionSnapshot? {
        lock.withLock {
            guard let value = snapshots[tabID], value.space == space else { return nil }
            return value
        }
    }

    func record(_ snapshot: BrowserInteractionSnapshot) {
        lock.withLock { snapshots[snapshot.tabID] = snapshot }
    }

    func remove(_ tabID: UUID) { lock.withLock { snapshots[tabID] = nil } }
}

enum BrowserInteractionArguments {
    struct Click {
        let snapshot: BrowserInteractionSnapshot
        let element: BrowserElementSnapshot
        var executionKey: String { snapshot.executionKey(elements: [element]) }
    }

    struct FillField: Sendable {
        let element: BrowserElementSnapshot?
        let name: String
        let value: String
        let waitForReady: Bool
        var label: String { element?.label ?? name }
    }

    struct Fill {
        let snapshot: BrowserInteractionSnapshot
        let fields: [FillField]
        let anchor: BrowserElementSnapshot
        var executionKey: String {
            snapshot.executionKey(elements: [anchor] + fields.compactMap(\.element),
                values: fields.flatMap { [$0.name, $0.value, String($0.waitForReady)] })
        }
        var presentation: ToolApprovalPresentation {
            let browser = ToolApprovalPresentation.BrowserAction(
                pageTitle: snapshot.title, origin: snapshot.url.flatMap(BrowserInteractionSnapshot.origin),
                targetLabel: nil, destination: nil,
                fields: fields.map { .init(label: $0.label, value: $0.value) }, formTruncated: false)
            return ToolApprovalPresentation(executionKind: .other, resourceAccess: .init(verified: false),
                network: .init(allowed: true), childProcesses: .init(allowed: false),
                reasonCode: "browser_fill", constraintSources: ["space", "task", "browserSnapshot", "fillPlan"],
                executionDetails: fields.map { "\($0.label): \($0.value)" }, browserAction: browser)
        }
    }

    static func click(_ json: String, space: AppSpace) throws -> Click {
        let args = ToolArguments.parse(json)
        let page = try page(args, space: space)
        guard let id = integer(args["element_id"]), let element = page.elements[id] else {
            throw ToolExecutionFailure(message: "Unknown element. Read the page again before acting.")
        }
        return Click(snapshot: page, element: element)
    }

    static func fill(_ json: String, space: AppSpace) throws -> Fill {
        let args = ToolArguments.parse(json)
        let page = try page(args, space: space)
        guard let fields = args["fields"] as? [[String: Any]], !fields.isEmpty, fields.count <= 50 else {
            throw ToolExecutionFailure(message: "browser_fill requires 1–50 fields in one batch.")
        }
        let anchorID = integer(args["form_element_id"]) ?? fields.first.flatMap { integer($0["element_id"]) }
        guard let anchorID, let anchor = page.elements[anchorID] else {
            throw ToolExecutionFailure(message: "Observe a form element first; deferred fields require form_element_id.")
        }
        var resolved: [FillField] = []
        var identities = Set<String>()
        var bytes = 0
        for field in fields {
            let element = integer(field["element_id"]).flatMap { page.elements[$0] }
            let name = ToolArguments.string(field, "field_name")
            let wait = field["wait_for_ready"] as? Bool ?? false
            guard let value = field["value"] as? String,
                  (field["element_id"] == nil) != (field["field_name"] == nil) else {
                throw ToolExecutionFailure(message: "Each planned field needs exactly one observed element_id or deferred field_name, and a string value.")
            }
            if let element {
                guard !element.sensitive, element.editable || (wait && element.fillable == true),
                      element.frameURL == anchor.frameURL, element.formIdentity == anchor.formIdentity else {
                    throw ToolExecutionFailure(message: "Every field must be a non-sensitive input in the same observed form and frame.")
                }
                if element.tag == "select", !wait, !element.selectOptions.contains(value) {
                    throw ToolExecutionFailure(message: "The requested option was not present in the observed select field. Nothing was filled.")
                }
            } else {
                guard field["element_id"] == nil, wait, !anchor.formIdentity.isEmpty,
                      !name.isEmpty, name.utf8.count <= 128,
                      name.range(of: "pass|secret|token|otp|verification|credit|card|cvv|cvc", options: .regularExpression.union(.caseInsensitive)) == nil else {
                    throw ToolExecutionFailure(message: "Deferred fields require a non-sensitive exact field_name, wait_for_ready=true and an observed form anchor.")
                }
            }
            let identity = element?.fieldName.flatMap { $0.isEmpty ? nil : "name:" + $0 }
                ?? element.map { "id:" + $0.identity } ?? "name:" + name
            guard identities.insert(identity).inserted else {
                throw ToolExecutionFailure(message: "Duplicate fields are not allowed in a fill plan.")
            }
            bytes += value.utf8.count
            guard bytes <= 32 * 1024 else { throw ToolExecutionFailure(message: "Form input exceeds the 32 KiB plan limit.") }
            resolved.append(.init(element: element, name: name, value: value, waitForReady: wait))
        }
        return Fill(snapshot: page, fields: resolved, anchor: anchor)
    }

    private static func page(_ args: [String: Any], space: AppSpace) throws -> BrowserInteractionSnapshot {
        guard let tabID = UUID(uuidString: ToolArguments.string(args, "tab_id")),
              let snapshot = BrowserInteractionSnapshotCache.shared.snapshot(tabID: tabID, space: space) else {
            throw ToolExecutionFailure(message: "No current page observation in this space. Use browser_read first.")
        }
        return snapshot
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue > 0, number.doubleValue <= Double(Int32.max),
              number.doubleValue.rounded() == number.doubleValue else { return nil }
        return number.intValue
    }
}
