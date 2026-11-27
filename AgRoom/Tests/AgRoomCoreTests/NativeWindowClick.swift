import AppKit
import Testing

extension NSWindow {
    /// Activate a control only at the point located in this test window.
    @MainActor
    func sendTestClick(at point: NSPoint, matching title: String? = nil,
                       sourceLocation: SourceLocation = #_sourceLocation) throws {
        let root = try #require(contentView, sourceLocation: sourceLocation)
        var hit = root.hitTest(root.superview?.convert(point, from: nil) ?? point)
        while let view = hit {
            if let control = view as? NSControl, let cell = control.cell as? NSSegmentedCell {
                // NSCell tracks mouseDown synchronously in a nested event loop.
                // Use the visible segment's own action in the SwiftPM test host.
                let label = try #require(title, sourceLocation: sourceLocation)
                let index = try #require((0..<cell.segmentCount).first { cell.label(forSegment: $0) == label },
                                         "No segment with the requested label", sourceLocation: sourceLocation)
                try #require(control.isEnabled && cell.isEnabled(forSegment: index), sourceLocation: sourceLocation)
                let action = try #require(control.action, sourceLocation: sourceLocation)
                if cell.trackingMode == .selectAny {
                    cell.setSelected(!cell.isSelected(forSegment: index), forSegment: index)
                } else {
                    cell.selectedSegment = index
                }
                defer {
                    if cell.trackingMode == .momentary || cell.trackingMode == .momentaryAccelerator {
                        cell.setSelected(false, forSegment: index)
                    }
                }
                try #require(control.sendAction(action, to: control.target), sourceLocation: sourceLocation)
                return
            }
            if let control = view as? NSControl, let cell = control.cell as? NSButtonCell,
               !(cell is NSPopUpButtonCell), let action = control.action {
                // A plain AppKit button also waits for a mouse-up inside mouseDown.
                // Invoke the hit control's action without entering the tracking loop.
                try #require(control.isEnabled, sourceLocation: sourceLocation)
                switch cell.accessibilityRole() {
                case .radioButton: cell.state = .on
                case .checkBox, .disclosureTriangle: cell.setNextState()
                default: break
                }
                try #require(control.sendAction(action, to: control.target), sourceLocation: sourceLocation)
                return
            }
            hit = view.superview
        }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0), sourceLocation: sourceLocation)
            sendEvent(event)
        }
    }
}

@MainActor
@Suite("Native window click delivery", .serialized)
struct NativeWindowClickTests {
    private final class Probe: NSView {
        var received: [NSEvent.EventType] = []
        var selections: [Int] = []
        var checked: [NSControl.StateValue] = []
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { received.append(event.type) }
        override func mouseUp(with event: NSEvent) { received.append(event.type) }
        @objc func selected(_ control: NSSegmentedControl) { selections.append(control.selectedSegment) }
        @objc func toggle(_ control: NSButton) { checked.append(control.state) }
    }

    @Test("Native controls activate once and a custom view receives its mouse release")
    func activatesControlAndCustomView() throws {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 180, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let probe = Probe(frame: .zero)
        window.contentView = probe
        let control = NSSegmentedControl(labels: ["One", "Two"], trackingMode: .selectOne,
                                         target: probe, action: #selector(Probe.selected(_:)))
        control.frame = .init(x: 10, y: 55, width: 140, height: 28)
        control.selectedSegment = 0
        probe.addSubview(control)
        let checkbox = NSButton(checkboxWithTitle: "Enable", target: probe, action: #selector(Probe.toggle(_:)))
        checkbox.frame = .init(x: 10, y: 30, width: 110, height: 20)
        probe.addSubview(checkbox)
        window.orderFront(nil)
        try window.sendTestClick(at: .init(x: 110, y: 69), matching: "Two")
        #expect(probe.selections == [1] && control.selectedSegment == 1)
        try window.sendTestClick(at: .init(x: 20, y: 20))
        #expect(probe.received == [.leftMouseDown, .leftMouseUp])
        try window.sendTestClick(at: .init(x: 30, y: 40), matching: "Enable")
        #expect(probe.checked == [.on] && checkbox.state == .on)
    }
}
