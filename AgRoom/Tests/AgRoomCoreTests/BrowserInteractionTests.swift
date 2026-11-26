import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Browser task authorization", .serialized)
@MainActor
struct BrowserInteractionTests {
    private func fixture() async throws -> (BrowserService, BrowserTabModel) {
        _ = NSApplication.shared
        let service = BrowserService(space: .work, dataStore: .nonPersistent())
        let tab = service.addTab()
        tab.webView.loadHTMLString("""
            <html><head><title>Leave Request</title></head><body>
            <a id="navigation" href="#details">Details</a>
            <a id="cross" href="https://other.test/">Other site</a>
            <a id="script" href="javascript:window.effects.clicks++">Search</a>
            <a id="placeholder" href="#">Expand menu</a>
            <a id="delete" href="/delete?id=1">Details</a>
            <form id="request" onsubmit="window.effects.submits++; return false">
            <label for="name">Name</label><input id="name" value="Before">
            <label for="note">Note</label><textarea id="note">Original</textarea>
            <label for="choice">Type</label><select id="choice"><option value="a">Annual</option><option value="b">Other</option></select>
            <input type="password" id="password" value="FIXTURE_PASSWORD">
            <input id="otp" name="otp" value="FIXTURE_OTP">
            <button id="submit" type="submit">Send Request</button>
            <button id="unknown" type="button">Search</button>
            </form><div id="details">Details section</div>
            <script>
            window.effects = {inputs: 0, submits: 0, clicks: 0};
            document.addEventListener('input', function() { window.effects.inputs++; });
            document.addEventListener('click', function() { window.effects.clicks++; });
            </script></body></html>
            """, baseURL: URL(string: "https://fixture.test/"))
        let deadline = Date().addingTimeInterval(15)
        while (tab.webView.isLoading || tab.webView.title != "Leave Request") && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(tab.webView.title == "Leave Request")
        _ = try await service.readPage(tabId: tab.id)
        return (service, tab)
    }

    private func element(_ name: String, in tab: BrowserTabModel) async throws -> Int {
        let value = try await tab.webView.evaluateJavaScript("document.getElementById('\(name)').getAttribute('data-ah-id')")
        let text = try #require(value as? String)
        return try #require(Int(text))
    }

    private func arguments(tab: BrowserTabModel, element: Int) -> String {
        "{\"tab_id\":\"\(tab.id)\",\"element_id\":\(element)}"
    }

    private func fillArguments(tab: BrowserTabModel, fields: [(Int, String)]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "tab_id": tab.id.uuidString,
            "fields": fields.map { ["element_id": $0.0, "value": $0.1] as [String: Any] }
        ], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func requirement(_ tool: any DispatcherTool, _ arguments: String, keys: Set<String> = [],
                             mode: PermissionMode = .workspaceWrite) -> ConfirmationRequirement? {
        DispatcherEngine.confirmationRequirement(.init(id: "fixture", name: tool.definition.name, argumentsJSON: arguments),
            toolsByName: [tool.definition.name: tool], authorizedKeys: keys,
            permissionPolicy: .init(mode: mode, fileAreaPolicy: nil))
    }

    @Test func sleepingBackgroundTabReleasesWebViewAndRevokesSnapshot() async throws {
        _ = NSApplication.shared
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let service = BrowserService(space: .personal, dataStore: dataStore)
        let url = try #require(URL(string: "http://127.0.0.1:9/fixture"))
        var page: BrowserTabModel? = service.addTab()
        weak var oldView = page?.webView
        weak var oldPage = page
        let id = try #require(page?.id)
        page?.webView.loadHTMLString("<title>Fixture</title><input>", baseURL: url)
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while page?.title != "Fixture" || page?.isLoading == true {
            try #require(.now < deadline); try await Task.sleep(for: .milliseconds(8))
        }
        page?.recordRead()
        let oldRead = try #require(page?.readSnapshotVersion)
        #expect(page.flatMap { service.sleepRequest(for: $0) } == nil)
        _ = service.addTab()
        let proposed = page.flatMap { service.sleepRequest(for: $0) }
        let request = try #require(proposed)
        page?.operationCount += 1
        service.sleep(request)
        #expect(service.lookupTab(id: id) != nil)
        page?.operationCount -= 1
        service.sleep(request)
        #expect(service.lookupTab(id: id) == nil && service.sleepingTabs.first?.url == url)
        #expect(page?.readSnapshotVersion == nil)
        page = nil
        while (oldPage != nil || oldView != nil) && .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(oldPage == nil && oldView == nil)
        let restored = try #require(service.wake(id))
        #expect(restored.space == .personal && service.activeTabId == id && restored.webView.configuration.websiteDataStore == dataStore)
        #expect(restored.readSnapshotVersion == nil && restored.urlText == url.absoluteString)
        #expect(throws: (any Error).self) { try restored.validateSnapshot(authorizationKey: "browser-page#\(id.uuidString)#\(oldRead.uuidString)") }
        service.closeTab(restored)
    }

    @Test("A concurrent observation cannot mint new execution authority after a reused grant was checked")
    func identityRace() async throws {
        let state = BrowserAuthorizationRaceTool.State()
        let tool = BrowserAuthorizationRaceTool(state: state)
        let engine = DispatcherEngine(tools: [tool], systemPrompt: "",
            roundAuthorizations: .init(["fixture-navigation"]))
        _ = try await engine.executeCommand(.init(id: "race", name: tool.definition.name, argumentsJSON: "{}"))
        #expect(state.snapshot.checks == 3)
        #expect(!state.snapshot.executed)
        #expect(engine.traceEntries.first?.succeeded == false)
    }

    @Test("Direct navigation cannot turn a known action URL into an approval-free read")
    func actionURLCannotBypass() {
        let tool = BrowserOpenTool(space: .work)
        let args = #"{"url":"https://fixture.test/delete?id=1"}"#
        #expect(tool.permissionClass(argumentsJSON: args) == .externalEffect)
        #expect(requirement(tool, args)?.kind == .hard)
        #expect(requirement(tool, args, mode: .readOnly) == nil)
        let normal = #"{"url":"https://fixture.test/reports?page=2"}"#
        #expect(tool.permissionClass(argumentsJSON: normal) == .readOnly)
        #expect(requirement(tool, normal) == nil)
        let padded = #"{"url":"  https://fixture.test/delete?id=1\n"}"#
        #expect(requirement(tool, padded)?.kind == .hard)
        #expect(throws: (any Error).self) {
            try tool.validateArguments(argumentsJSON: #"{"url":"https://user:password@fixture.test/"}"#)
        }
    }

    @Test("Repeated observation preserves only task navigation authority; execution identity changes")
    func rereadAndRiskBoundaries() async throws {
        let (service, tab) = try await fixture()
        defer { service.closeTab(tab) }
        let tool = BrowserClickTool(space: .work, service: { service })
        let args = arguments(tab: tab, element: try await element("navigation", in: tab))
        let grant = try #require(tool.roundAuthorizationKey(argumentsJSON: args))
        let execution = try #require(tool.executionAuthorizationKey(argumentsJSON: args))
        #expect(requirement(tool, args)?.availableApprovalDurations == [.once, .round])

        _ = try await service.readPage(tabId: tab.id)
        #expect(tool.roundAuthorizationKey(argumentsJSON: args) == grant)
        #expect(tool.executionAuthorizationKey(argumentsJSON: args) != execution)
        #expect(requirement(tool, args, keys: [grant]) == nil)
        #expect(requirement(tool, args) != nil) // A new run has no inherited store.
        await #expect(throws: (any Error).self) {
            try await tool.execute(argumentsJSON: args, authorizationKey: execution)
        }

        for name in ["submit", "unknown", "script", "delete", "placeholder"] {
            let action = arguments(tab: tab, element: try await element(name, in: tab))
            let approval = try #require(requirement(tool, action, keys: [grant]))
            #expect(approval.kind == .hard)
            #expect(approval.availableApprovalDurations == [.once])
            #expect(tool.roundAuthorizationKey(argumentsJSON: action) == nil)
        }
        let cross = arguments(tab: tab, element: try await element("cross", in: tab))
        #expect(tool.roundAuthorizationKey(argumentsJSON: cross) == nil)
        #expect(requirement(tool, cross, keys: [grant]) != nil)

        // Scheme/port changes and a return to the old site must not revive its grant.
        tab.updateAuthorizationOrigin(URL(string: "https://fixture.test:8443/"))
        _ = try await service.readPage(tabId: tab.id)
        #expect(tool.roundAuthorizationKey(argumentsJSON: args) != grant)
        #expect(requirement(tool, args, keys: [grant]) != nil)
        let otherSpace = BrowserClickTool(space: .personal)
        #expect(throws: (any Error).self) { try otherSpace.validateArguments(argumentsJSON: args) }
        #expect(requirement(tool, args, keys: [grant], mode: .readOnly) == nil)
    }

    @Test("An approved navigation dispatches no page click handler and retains authority in the same origin")
    func nativeNavigation() async throws {
        let (service, tab) = try await fixture()
        defer { service.closeTab(tab) }
        let tool = BrowserClickTool(space: .work, service: { service })
        let args = arguments(tab: tab, element: try await element("navigation", in: tab))
        let store = RoundAuthorizationStore()
        let engine = DispatcherEngine(tools: [tool], systemPrompt: "", roundAuthorizations: store)
        guard case .needsConfirmation = try await engine.executeCommand(.init(id: "navigate", name: "browser_click", argumentsJSON: args)) else {
            Issue.record("Navigation must request initial authority"); return
        }
        let id = try #require(engine.pendingApprovalID)
        _ = try await engine.resume(.confirmed(approvalID: id, approved: true, alwaysAllow: true, persistRule: false))
        #expect(engine.traceEntries.first?.succeeded == true)
        _ = try await service.readPage(tabId: tab.id)
        let clicks = try await tab.webView.evaluateJavaScript("window.effects.clicks") as? Int
        #expect(clicks == 0)
        #expect(tab.webView.url?.fragment == "details")
        #expect(store.contains(try #require(tool.roundAuthorizationKey(argumentsJSON: args))))
    }

    @Test("One approval fills an ordered plan and cannot authorize replay")
    func fillBatch() async throws {
        let (service, tab) = try await fixture()
        defer { service.closeTab(tab) }
        let name = try await element("name", in: tab), note = try await element("note", in: tab)
        let tool = BrowserFillTool(space: .work, service: { service })
        let args = try fillArguments(tab: tab, fields: [(name, "Alice"), (note, "Two days")])
        let store = RoundAuthorizationStore()
        let engine = DispatcherEngine(tools: [tool], systemPrompt: "", roundAuthorizations: store)
        guard case .needsConfirmation = try await engine.executeCommand(.init(id: "fill", name: "browser_fill", argumentsJSON: args)) else {
            Issue.record("Filling must request one batch approval"); return
        }
        #expect(try await tab.webView.evaluateJavaScript("window.effects.inputs") as? Int == 0)
        let pendingID = try #require(engine.pendingApprovalID)
        _ = try await engine.resume(.confirmed(approvalID: pendingID, approved: true, alwaysAllow: true, persistRule: false))
        #expect(engine.traceEntries.first?.succeeded == true)
        #expect(try await tab.webView.evaluateJavaScript("document.getElementById('name').value") as? String == "Alice")
        #expect(try await tab.webView.evaluateJavaScript("document.getElementById('note').value") as? String == "Two days")
        #expect(try await tab.webView.evaluateJavaScript("window.effects.inputs") as? Int == 2)
        #expect(try await tab.webView.evaluateJavaScript("window.effects.submits") as? Int == 0)
        _ = try await service.readPage(tabId: tab.id)
        #expect(requirement(tool, args, keys: store.all) != nil)
        #expect(store.all.isEmpty)
        let changed = try fillArguments(tab: tab, fields: [(name, "Bob"), (note, "Two days")])
        #expect(requirement(tool, changed, keys: store.all) != nil)
        let presentation = try #require(tool.approvalPresentation(argumentsJSON: args))
        #expect(presentation.executionDetails.joined().contains("Alice"))
        #expect(!presentation.executionDetails.joined().contains("FIXTURE_PASSWORD"))
        #expect(!presentation.executionDetails.joined().contains("FIXTURE_OTP"))
    }

    @Test("Invalid batches fail before approval and have no partial effects")
    func invalidBatch() async throws {
        let (service, tab) = try await fixture()
        defer { service.closeTab(tab) }
        let tool = BrowserFillTool(space: .work, service: { service })
        let name = try await element("name", in: tab), otp = try await element("otp", in: tab)
        let choice = try await element("choice", in: tab)
        for fields in [[(name, "Changed"), (999999, "Missing")], [(name, "Changed"), (otp, "123456")], [(name, "One"), (name, "Two")], [(name, "Changed"), (choice, "not-an-option")]] {
            let args = try fillArguments(tab: tab, fields: fields)
            let engine = DispatcherEngine(tools: [tool], systemPrompt: "")
            guard case .finished = try await engine.executeCommand(.init(id: UUID().uuidString, name: "browser_fill", argumentsJSON: args)) else {
                Issue.record("Invalid input must fail without a confirmation"); continue
            }
            #expect(engine.traceEntries.first?.succeeded == false)
        }
        #expect(try await tab.webView.evaluateJavaScript("window.effects.inputs") as? Int == 0)
        #expect(try await tab.webView.evaluateJavaScript("document.getElementById('name').value") as? String == "Before")
    }

    @Test("A reactive partial fill revokes its grant and cannot replay earlier writes")
    func partialFillRequiresNewApproval() async throws {
        let (service, tab) = try await fixture()
        defer { service.closeTab(tab) }
        _ = try await tab.webView.evaluateJavaScript("""
            document.getElementById('name').addEventListener('input', function() {
                document.getElementById('note').value = 'Reactive change';
            });
            """)
        let name = try await element("name", in: tab), note = try await element("note", in: tab)
        let tool = BrowserFillTool(space: .work, service: { service })
        let args = try fillArguments(tab: tab, fields: [(name, "Alice"), (note, "Two days")])
        #expect(tool.roundAuthorizationKey(argumentsJSON: args) == nil)
        let store = RoundAuthorizationStore()
        let engine = DispatcherEngine(tools: [tool], systemPrompt: "", roundAuthorizations: store)
        _ = try await engine.executeCommand(.init(id: "partial", name: "browser_fill", argumentsJSON: args))
        let id = try #require(engine.pendingApprovalID)
        _ = try await engine.resume(.confirmed(approvalID: id, approved: true, alwaysAllow: true, persistRule: false))
        #expect(engine.traceEntries.first?.succeeded == false)
        #expect(try await tab.webView.evaluateJavaScript("window.effects.inputs") as? Int == 1)
        #expect(try await tab.webView.evaluateJavaScript("document.getElementById('name').value") as? String == "Alice")
        #expect(try await tab.webView.evaluateJavaScript("document.getElementById('note').value") as? String == "Reactive change")
        #expect(engine.traceEntries.first?.resultDisplay.contains("Current field status: not dispatched") == true)
        #expect(BrowserInteractionSnapshotCache.shared.snapshot(tabID: tab.id, space: .work) == nil)
        _ = try await service.readPage(tabId: tab.id)
        #expect(tool.roundAuthorizationKey(argumentsJSON: args) == nil)
        #expect(requirement(tool, args, keys: store.all) != nil)
    }

    @Test("Structured menu grants cover other panels but never unknown or consequential actions")
    func structuredTaskScope() async throws {
        let (service, tab) = try await fixture()
        defer { service.closeTab(tab) }
        _ = try await tab.webView.evaluateJavaScript("""
            document.body.insertAdjacentHTML('beforeend', '<button id="menu1" type="button" aria-controls="panel1" aria-expanded="false">Reports</button><div id="panel1"></div><button id="menu2" role="tab" aria-controls="panel2">History</button><div id="panel2"></div><button id="danger" type="button" aria-controls="panel2" aria-expanded="false">Delete</button>');
            """)
        _ = try await service.readPage(tabId: tab.id)
        let tool = BrowserClickTool(space: .work, service: { service })
        let first = arguments(tab: tab, element: try await element("menu1", in: tab))
        let second = arguments(tab: tab, element: try await element("menu2", in: tab))
        let key = try #require(tool.roundAuthorizationKey(argumentsJSON: first))
        #expect(requirement(tool, first)?.kind == .normal)
        #expect(tool.approvalRoute(argumentsJSON: first) == .modelReviewable)
        #expect(requirement(tool, second, keys: [key]) == nil)
        for name in ["unknown", "submit", "danger", "script"] {
            let args = arguments(tab: tab, element: try await element(name, in: tab))
            #expect(requirement(tool, args, keys: [key])?.kind == .hard)
        }
        // A decorative class change must not turn the approved operation into a stale action.
        let identity = try #require(tool.executionAuthorizationKey(argumentsJSON: first))
        _ = try await tab.webView.evaluateJavaScript("document.getElementById('menu1').className='active'")
        _ = try await tool.execute(argumentsJSON: first, authorizationKey: identity)
        #expect(try await tab.webView.evaluateJavaScript("window.effects.clicks") as? Int == 1)
    }

    @Test("Search form scope survives rereads, but changed destinations and POST cannot inherit")
    func queryTaskScope() async throws {
        let (service, tab) = try await fixture()
        defer { service.closeTab(tab) }
        _ = try await tab.webView.evaluateJavaScript("""
            document.body.insertAdjacentHTML('beforeend', '<form id="searchForm" role="search" method="get" action="/reports"><input type="search" name="q" value="this month"><button id="query" type="submit">Search</button></form>');
            """)
        _ = try await service.readPage(tabId: tab.id)
        let tool = BrowserClickTool(space: .work, service: { service })
        let args = arguments(tab: tab, element: try await element("query", in: tab))
        let key = try #require(tool.roundAuthorizationKey(argumentsJSON: args))
        #expect(tool.approvalPresentation(argumentsJSON: args)?.reasonCode == "browser_query")
        #expect(tool.approvalPresentation(argumentsJSON: args)?.browserAction?.destination == "https://fixture.test/reports")
        _ = try await service.readPage(tabId: tab.id)
        #expect(requirement(tool, args, keys: [key]) == nil)
        _ = try await tab.webView.evaluateJavaScript("document.getElementById('searchForm').action='/other-reports'")
        _ = try await service.readPage(tabId: tab.id)
        #expect(requirement(tool, args, keys: [key]) != nil)
        for mutation in ["f.method='post'", "f.method='get'; f.action='/delete'", "f.method='get'; f.action='https://other.test/reports'", "f.method='get'; f.action='/reports?token=secret'"] {
            _ = try await tab.webView.evaluateJavaScript("var f=document.getElementById('searchForm'); " + mutation)
            _ = try await service.readPage(tabId: tab.id)
            #expect(requirement(tool, args, keys: [key])?.kind == .hard)
        }
    }

    @Test("Structured browser evidence can reach model review; incomplete evidence and hard actions cannot")
    func browserReviewEligibility() async throws {
        let (service, tab) = try await fixture()
        defer { service.closeTab(tab) }
        _ = try await tab.webView.evaluateJavaScript("""
            document.body.insertAdjacentHTML('beforeend', '<button id="menu" type="button" role="tab" aria-controls="details">Details</button>');
            """)
        _ = try await service.readPage(tabId: tab.id)
        let tool = BrowserClickTool(space: .work)
        let args = arguments(tab: tab, element: try await element("menu", in: tab))
        let scope = TaskExecutionScope.make(space: .work, sessionID: UUID(), runID: UUID(), parentRunID: nil,
            workspaceID: nil, workspacePath: "", readRoots: [], writeRoots: [], artifactRoots: [],
            mode: .workspaceWrite, autoReviewEnabled: true, policyVersion: AutoReviewService.ruleVersion,
            userRequest: "Read the details panel")
        let request = AutoReviewRequest(callId: "review", toolName: "browser_click", argumentsJSON: args,
            requirement: try #require(requirement(tool, args)), route: tool.approvalRoute(argumentsJSON: args),
            sideEffectClass: .nonIdempotentWrite, taskScope: scope, evidence: tool.autoReviewEvidence(argumentsJSON: args))
        let environment = AutoReviewEnvironment(space: .work, workspacePath: "")
        #expect(AutoReviewService.ruleResult(request, environment: environment) == .needsModelReview(reason: "browser_structured"))
        let missing = AutoReviewRequest(callId: "missing", toolName: "browser_click", argumentsJSON: args,
            requirement: try #require(requirement(tool, args)), route: .modelReviewable,
            sideEffectClass: .nonIdempotentWrite, taskScope: scope)
        #expect(AutoReviewService.ruleResult(missing, environment: environment) == .manual(reason: "browser_unverified"))
        let dangerous = arguments(tab: tab, element: try await element("submit", in: tab))
        #expect(tool.approvalRoute(argumentsJSON: dangerous) == .manualOnly)
        #expect(tool.autoReviewEvidence(argumentsJSON: dangerous).isEmpty)
    }

    @Test("Browser review explains HTTPS, truncated and oversized evidence without allowing it")
    func browserReviewFallbackReasons() async throws {
        let scope = TaskExecutionScope.make(space: .work, sessionID: UUID(), runID: UUID(), parentRunID: nil,
            workspaceID: nil, workspacePath: "", readRoots: [], writeRoots: [], artifactRoots: [],
            mode: .workspaceWrite, autoReviewEnabled: true, policyVersion: AutoReviewService.ruleVersion,
            userRequest: "Search the report")
        let baseline = ["space": "work", "execution_profile": "browser_structured",
            "browser_policy": "structured/v1", "operation": "browser_query",
            "origin": "https://fixture.test:443", "execution_identity": "fixture-identity",
            "evidence_truncated": "false"]
        let cases: [(String, String, String)] = [
            ("origin", "http://fixture.test:80", "browser_https_required"),
            ("evidence_truncated", "true", "browser_evidence_truncated"),
            ("evidence_truncated", "unknown", "browser_unverified"),
            ("form_fields", String(repeating: "x", count: 24 * 1024), "browser_evidence_too_large"),
            ("space", "personal", "browser_unverified")]
        for (key, value, reason) in cases {
            var evidence = baseline
            evidence[key] = value
            let request = AutoReviewRequest(callId: "fallback", toolName: "browser_click", argumentsJSON: "{}",
                requirement: .init(kind: .normal, scope: .domain), route: .modelReviewable,
                sideEffectClass: .nonIdempotentWrite, taskScope: scope, evidence: evidence)
            #expect(AutoReviewService.ruleResult(request, environment: .init(space: .work, workspacePath: ""))
                == .manual(reason: reason))
            #expect(!ConfirmationCard.autoReviewReasonText(reason).contains("chat.autoReview.reason."))
        }
    }

    @Test("Legacy GET searches become review candidates, never POST, overrides, scripts or unknown buttons")
    func legacySearchCandidates() async throws {
        let (service, tab) = try await fixture()
        defer { service.closeTab(tab) }
        _ = try await tab.webView.evaluateJavaScript("""
            document.body.insertAdjacentHTML('beforeend', '<form id=legacy method=get action=/reports><input name=keyword value=report><button id=legacySearch type=submit>查询</button></form>');
            """)
        _ = try await service.readPage(tabId: tab.id)
        let tool = BrowserClickTool(space: .work)
        let args = arguments(tab: tab, element: try await element("legacySearch", in: tab))
        #expect(tool.approvalRoute(argumentsJSON: args) == .modelReviewable)
        let key = try #require(tool.roundAuthorizationKey(argumentsJSON: args))
        #expect(requirement(tool, args, keys: [key]) == nil)
        #expect(tool.autoReviewEvidence(argumentsJSON: args)["operation"] == "browser_query")
        let mutations = [
            "form.method='post'",
            "button.type='button'",
            "button.disabled=true",
            "button.setAttribute('formtarget','_blank')",
            "button.setAttribute('formaction','https://other.test/')",
            "button.setAttribute('formmethod','post')",
            "button.setAttribute('formenctype','text/plain')",
            "button.setAttribute('onclick','return false')",
            "form.setAttribute('onsubmit','return false')",
            "button.textContent='Approve'",
            "form.querySelector('input').name='customer'",
            "form.querySelector('input').disabled=true",
            "form.querySelector('input').readOnly=true",
            "var fieldset=document.createElement('fieldset'); fieldset.id='legacyDisabledFields'; fieldset.disabled=true; form.after(fieldset); var query=form.querySelector('input'); query.setAttribute('form','legacy'); fieldset.append(query)",
            "form.action='/delete'",
            "form.insertAdjacentHTML('beforeend','<input name=otp>')",
            "form.after(button); button.setAttribute('form','legacy'); form.setAttribute('onsubmit','return false')",
            "form.after(button); button.setAttribute('form','legacy'); form.setAttribute('data-remote','true')"]
        for mutation in mutations {
            // Rebuild each case so disabled fields, overrides and external submitters cannot leak.
            _ = try await tab.webView.evaluateJavaScript("""
                document.getElementById('legacySearch').remove();
                document.getElementById('legacy').remove();
                var disabledFields=document.getElementById('legacyDisabledFields');
                if (disabledFields) disabledFields.remove();
                document.body.insertAdjacentHTML('beforeend', '<form id=legacy method=get action=/reports><input name=keyword value=report><button id=legacySearch type=submit>查询</button></form>');
                """)
            _ = try await service.readPage(tabId: tab.id)
            let caseArgs = arguments(tab: tab, element: try await element("legacySearch", in: tab))
            #expect(tool.approvalRoute(argumentsJSON: caseArgs) == .modelReviewable)
            _ = try await tab.webView.evaluateJavaScript("""
                var form=document.getElementById('legacy'), button=document.getElementById('legacySearch');
                """ + mutation)
            _ = try await service.readPage(tabId: tab.id)
            #expect(tool.approvalRoute(argumentsJSON: caseArgs) == .manualOnly)
            #expect(requirement(tool, caseArgs, keys: [key])?.kind == .hard)
            #expect(tool.autoReviewEvidence(argumentsJSON: caseArgs).isEmpty)
        }
        #expect(try await tab.webView.evaluateJavaScript("window.effects.inputs") as? Int == 0)
        #expect(try await tab.webView.evaluateJavaScript("window.effects.submits") as? Int == 0)
    }

    @Test("Read-only form readiness supports batching and redacts sensitive fields")
    func formReadinessObservations() async throws {
        let (service, tab) = try await fixture()
        defer { service.closeTab(tab) }
        _ = try await tab.webView.evaluateJavaScript("""
            document.getElementById('name').name='employee';
            document.getElementById('note').readOnly=true;
            document.getElementById('choice').disabled=true;
            document.getElementById('choice').options[1].disabled=true;
            """)
        let text = try await service.readPage(tabId: tab.id)
        #expect(text.contains(" | form="))
        #expect(text.contains("name=\"employee\""))
        #expect(text.contains("disabled=true"))
        #expect(text.contains("readonly=true"))
        #expect(text.contains("\"disabled\":true"))
        #expect(!text.contains("FIXTURE_PASSWORD"))
        #expect(!text.contains("FIXTURE_OTP"))
        #expect(try await tab.webView.evaluateJavaScript("window.effects.inputs") as? Int == 0)
    }

    @Test("One concrete approval fills asynchronous select and newly appearing fields without submission")
    func dependentFillPlan() async throws {
        let (service, tab) = try await fixture()
        defer { service.closeTab(tab) }
        _ = try await tab.webView.evaluateJavaScript("""
            var choice=document.getElementById('choice'); choice.disabled=true; choice.innerHTML='';
            document.getElementById('name').addEventListener('input', function() {
                setTimeout(function() {
                    choice.innerHTML='<option value="ready">Ready</option>'; choice.disabled=false;
                    document.getElementById('request').insertAdjacentHTML('beforeend', '<input name="details" id="deferred">');
                }, 80);
            });
            """)
        _ = try await service.readPage(tabId: tab.id)
        let name = try await element("name", in: tab), choice = try await element("choice", in: tab)
        let data = try JSONSerialization.data(withJSONObject: ["tab_id": tab.id.uuidString,
            "form_element_id": name, "fields": [
                ["element_id": name, "value": "Alice"],
                ["element_id": choice, "value": "ready", "wait_for_ready": true],
                ["field_name": "details", "value": "Reviewed plan", "wait_for_ready": true]]])
        let args = String(decoding: data, as: UTF8.self)
        let tool = BrowserFillTool(space: .work, service: { service })
        let engine = DispatcherEngine(tools: [tool], systemPrompt: "")
        guard case .needsConfirmation = try await engine.executeCommand(.init(id: "plan", name: "browser_fill", argumentsJSON: args)) else {
            Issue.record("A concrete plan must be reviewed first"); return
        }
        #expect(try await tab.webView.evaluateJavaScript("window.effects.inputs") as? Int == 0)
        _ = try await engine.resume(.confirmed(approvalID: try #require(engine.pendingApprovalID), approved: true, alwaysAllow: false, persistRule: false))
        #expect(engine.traceEntries.first?.succeeded == true)
        #expect(try await tab.webView.evaluateJavaScript("document.getElementById('name').value") as? String == "Alice")
        #expect(try await tab.webView.evaluateJavaScript("document.getElementById('choice').value") as? String == "ready")
        #expect(try await tab.webView.evaluateJavaScript("document.getElementById('deferred').value") as? String == "Reviewed plan")
        #expect(try await tab.webView.evaluateJavaScript("window.effects.submits") as? Int == 0)
        #expect(tab.activeFillPlan == nil)
        #expect(BrowserInteractionSnapshotCache.shared.snapshot(tabID: tab.id, space: .work) == nil)
    }

    @Test("A fill dependency cannot change the form destination or silently reach a sensitive field")
    func changedPlanBoundary() async throws {
        for change in ["document.getElementById('request').action='/other'", "document.getElementById('note').setAttribute('name','password')"] {
            let (service, tab) = try await fixture()
            defer { service.closeTab(tab) }
            _ = try await tab.webView.evaluateJavaScript("document.getElementById('name').addEventListener('input', function(){" + change + "})")
            _ = try await service.readPage(tabId: tab.id)
            let name = try await element("name", in: tab), note = try await element("note", in: tab)
            let args = try fillArguments(tab: tab, fields: [(name, "Alice"), (note, "Must not write")])
            let tool = BrowserFillTool(space: .work, service: { service })
            let engine = DispatcherEngine(tools: [tool], systemPrompt: "")
            _ = try await engine.executeCommand(.init(id: "changed-plan", name: "browser_fill", argumentsJSON: args))
            _ = try await engine.resume(.confirmed(approvalID: try #require(engine.pendingApprovalID), approved: true, alwaysAllow: false, persistRule: false))
            #expect(engine.traceEntries.first?.succeeded == false)
            #expect(try await tab.webView.evaluateJavaScript("window.effects.inputs") as? Int == 1)
            #expect(try await tab.webView.evaluateJavaScript("document.getElementById('note').value") as? String == "Original")
        }
    }

    @Test("Dependent field replacement is matched inside the same form using its approved contract")
    func rerenderedDependency() async throws {
        let (service, tab) = try await fixture()
        defer { service.closeTab(tab) }
        _ = try await tab.webView.evaluateJavaScript("""
            var choice=document.getElementById('choice'); choice.disabled=true; choice.innerHTML='';
            document.getElementById('name').addEventListener('input', function() {
                choice.outerHTML='<select id="choice"><option value="ready">Ready</option></select>';
            });
            """)
        _ = try await service.readPage(tabId: tab.id)
        let name = try await element("name", in: tab), choice = try await element("choice", in: tab)
        let args = String(decoding: try JSONSerialization.data(withJSONObject: ["tab_id": tab.id.uuidString, "fields": [
            ["element_id": name, "value": "Alice"], ["element_id": choice, "value": "ready", "wait_for_ready": true]]]), as: UTF8.self)
        let tool = BrowserFillTool(space: .work, service: { service })
        let engine = DispatcherEngine(tools: [tool], systemPrompt: "")
        _ = try await engine.executeCommand(.init(id: "rerender", name: "browser_fill", argumentsJSON: args))
        _ = try await engine.resume(.confirmed(approvalID: try #require(engine.pendingApprovalID), approved: true, alwaysAllow: false, persistRule: false))
        #expect(engine.traceEntries.first?.succeeded == true)
        #expect(try await tab.webView.evaluateJavaScript("document.getElementById('choice').value") as? String == "ready")
    }

    @Test("Hidden business object changes stop remaining plan steps")
    func hiddenBusinessState() async throws {
        let (service, tab) = try await fixture()
        defer { service.closeTab(tab) }
        _ = try await tab.webView.evaluateJavaScript("""
            document.getElementById('request').insertAdjacentHTML('beforeend', '<input type="hidden" name="record_id" id="record_id" value="original">');
            document.getElementById('name').addEventListener('input', function() { document.getElementById('record_id').value='different'; });
            """)
        _ = try await service.readPage(tabId: tab.id)
        let args = try fillArguments(tab: tab, fields: [(try await element("name", in: tab), "Alice"), (try await element("note", in: tab), "Do not write")])
        let tool = BrowserFillTool(space: .work, service: { service })
        let engine = DispatcherEngine(tools: [tool], systemPrompt: "")
        _ = try await engine.executeCommand(.init(id: "hidden", name: "browser_fill", argumentsJSON: args))
        _ = try await engine.resume(.confirmed(approvalID: try #require(engine.pendingApprovalID), approved: true, alwaysAllow: false, persistRule: false))
        #expect(engine.traceEntries.first?.succeeded == false)
        #expect(try await tab.webView.evaluateJavaScript("window.effects.inputs") as? Int == 1)
        #expect(try await tab.webView.evaluateJavaScript("document.getElementById('note').value") as? String == "Original")
    }

    @Test("Cancelling a waiting dependency releases the tab without replaying completed fields")
    func cancelledPlan() async throws {
        let (service, tab) = try await fixture()
        defer { service.closeTab(tab) }
        _ = try await tab.webView.evaluateJavaScript("document.getElementById('choice').disabled=true")
        _ = try await service.readPage(tabId: tab.id)
        let name = try await element("name", in: tab), choice = try await element("choice", in: tab)
        let args = String(decoding: try JSONSerialization.data(withJSONObject: ["tab_id": tab.id.uuidString, "fields": [
            ["element_id": name, "value": "Alice"], ["element_id": choice, "value": "b", "wait_for_ready": true]]]), as: UTF8.self)
        let tool = BrowserFillTool(space: .work, service: { service })
        let key = try #require(tool.executionAuthorizationKey(argumentsJSON: args))
        let task = Task { try await tool.execute(argumentsJSON: args, authorizationKey: key) }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if try await tab.webView.evaluateJavaScript("window.effects.inputs") as? Int == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(tab.activeFillPlan == nil)
        #expect(try await tab.webView.evaluateJavaScript("window.effects.inputs") as? Int == 1)
        #expect(try await tab.webView.evaluateJavaScript("document.getElementById('choice').value") as? String == "a")
        #expect(BrowserInteractionSnapshotCache.shared.snapshot(tabID: tab.id, space: .work) == nil)
    }

    @Test("Browser approval facts remain compatible with old serialized summaries")
    func summaryCompatibility() async throws {
        let (service, tab) = try await fixture()
        defer { service.closeTab(tab) }
        let tool = BrowserClickTool(space: .work)
        let args = arguments(tab: tab, element: try await element("submit", in: tab))
        let presentation = try #require(tool.approvalPresentation(argumentsJSON: args))
        #expect(presentation.browserAction?.targetLabel == "Send Request")
        let encoded = try JSONEncoder().encode(presentation)
        #expect(try JSONDecoder().decode(ToolApprovalPresentation.self, from: encoded) == presentation)
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "browserAction")
        let decoded = try JSONDecoder().decode(ToolApprovalPresentation.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.browserAction == nil)
    }

    @Test("Browser cards render three languages with bounded details",
          .enabled(if: ProcessInfo.processInfo.environment["AGROOM_BROWSER_SNAPSHOT_DIR"] != nil))
    func approvalCards() async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["AGROOM_BROWSER_SNAPSHOT_DIR"]))
        let (service, tab) = try await fixture()
        defer { service.closeTab(tab) }
        let tool = BrowserFillTool(space: .work)
        let args = try fillArguments(tab: tab, fields: [(try await element("name", in: tab), "Alice"), (try await element("note", in: tab), "Two days")])
        let approval = try #require(requirement(tool, args))
        let pending = PendingConfirmation(messageId: UUID(), toolName: "browser_fill", argumentsDisplay: args, requirement: approval, approvalID: UUID())
        let oldLanguage = LanguageManager.shared.currentLanguage
        defer { LanguageManager.shared.currentLanguage = oldLanguage }
        for language in [AppLanguage.simplifiedChinese, .traditionalChinese, .english] {
            LanguageManager.shared.currentLanguage = language
            for dark in [false, true] {
                let host = NSHostingView(rootView: ConfirmationCard(pending: pending, onDecision: { _ in })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, dark ? .dark : .light))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 530),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(70))
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(
                    to: directory.appendingPathComponent("browser-fill-\(language.rawValue)-\(dark).png"))
                window.close()
            }
        }
    }

    @Test("Task-scope cards render query and menu authorization in three languages",
          .enabled(if: ProcessInfo.processInfo.environment["AGROOM_BROWSER_SNAPSHOT_DIR"] != nil))
    func taskApprovalCards() async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["AGROOM_BROWSER_SNAPSHOT_DIR"]))
        let oldLanguage = LanguageManager.shared.currentLanguage
        defer { LanguageManager.shared.currentLanguage = oldLanguage }
        for language in [AppLanguage.simplifiedChinese, .traditionalChinese, .english] {
            LanguageManager.shared.currentLanguage = language
            for kind in ["browser_query", "browser_control"] {
                let presentation = ToolApprovalPresentation(executionKind: .other, resourceAccess: .init(verified: false),
                    network: .init(allowed: true), childProcesses: .init(allowed: false), reasonCode: kind,
                    constraintSources: ["space", "task", "browserSnapshot"], executionDetails: [],
                    browserAction: .init(pageTitle: "Purchasing", origin: "https://fixture.test:443", targetLabel: "Search",
                        destination: kind == "browser_query" ? "https://fixture.test/reports" : nil,
                        fields: [.init(label: "Month", value: "2026-11")], formTruncated: false))
                let approval = ConfirmationRequirement(kind: .normal, scope: .domain, roundKey: kind, presentation: presentation)
                let pending = PendingConfirmation(messageId: UUID(), toolName: "browser_click", argumentsDisplay: "{}", requirement: approval, approvalID: UUID())
                let host = NSHostingView(rootView: ConfirmationCard(pending: pending, onDecision: { _ in })
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, .light))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: .aqua)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(70))
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                var colors = Set<String>()
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 24) {
                    for y in stride(from: 0, to: bitmap.pixelsHigh, by: 24) {
                        if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                            colors.insert("\(Int(color.redComponent * 255))-\(Int(color.greenComponent * 255))-\(Int(color.blueComponent * 255))-\(Int(color.alphaComponent * 255))")
                        }
                    }
                }
                #expect(colors.count > 3, "The native task card must render visible content, not a blank bitmap")
                try #require(bitmap.representation(using: .png, properties: [:])).write(
                    to: directory.appendingPathComponent("\(kind)-\(language.rawValue).png"))
                window.close()
            }
        }
    }

    @Test("A changed form value after the confirmation was shown cannot submit")
    func staleSubmission() async throws {
        let (service, tab) = try await fixture()
        defer { service.closeTab(tab) }
        let tool = BrowserClickTool(space: .work, service: { service })
        let args = arguments(tab: tab, element: try await element("submit", in: tab))
        let engine = DispatcherEngine(tools: [tool], systemPrompt: "")
        guard case .needsConfirmation = try await engine.executeCommand(.init(id: "submit", name: "browser_click", argumentsJSON: args)) else {
            Issue.record("Submission must require explicit approval"); return
        }
        _ = try await tab.webView.evaluateJavaScript("document.getElementById('name').value = 'Changed after review'")
        let id = try #require(engine.pendingApprovalID)
        _ = try await engine.resume(.confirmed(approvalID: id, approved: true, alwaysAllow: true, persistRule: false))
        #expect(engine.traceEntries.first?.succeeded == false)
        #expect(try await tab.webView.evaluateJavaScript("window.effects.submits") as? Int == 0)
        #expect(try await tab.webView.evaluateJavaScript("window.effects.clicks") as? Int == 0)
    }
}

/// Deterministically swaps a navigation observation for a consequential action immediately after
/// the final round-grant check. It models another chat reading the same shared browser tab.
private struct BrowserAuthorizationRaceTool: DispatcherTool {
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var checks = 0
        private var version = 0
        private var executed = false
        var snapshot: (checks: Int, version: Int, executed: Bool) {
            lock.withLock { (checks, version, executed) }
        }
        func checkGrant() {
            lock.withLock {
                checks += 1
                if checks == 3 { version = 1 }
            }
        }
        func recordExecution() { lock.withLock { executed = true } }
    }
    let state: State
    let definition = ToolDefinition(name: "fixture_browser_race", description: "fixture", parametersSchemaJSON: #"{"type":"object","properties":{}}"#)
    let requiresConfirmation = true
    func requiresHardConfirmation(argumentsJSON: String) -> Bool { state.snapshot.version != 0 }
    func roundAuthorizationKey(argumentsJSON: String) -> String? {
        state.checkGrant()
        return "fixture-navigation"
    }
    func executionAuthorizationKey(argumentsJSON: String) -> String? { "observation-\(state.snapshot.version)" }
    func execute(argumentsJSON: String) async throws -> String { throw ToolExecutionFailure(message: "Missing identity") }
    func execute(argumentsJSON: String, authorizationKey: String?) async throws -> String {
        guard authorizationKey == executionAuthorizationKey(argumentsJSON: argumentsJSON) else {
            throw ToolExecutionFailure(message: "Observation changed")
        }
        state.recordExecution()
        return "executed"
    }
}
