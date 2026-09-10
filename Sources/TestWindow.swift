import AppKit

final class TestDocument: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirty: NSRect) {
        NSColor.textBackgroundColor.setFill(); dirty.fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 16, weight: .regular), .foregroundColor: NSColor.labelColor]
        let first = max(0, Int(dirty.minY / 40)), last = min(499, Int(dirty.maxY / 40) + 1)
        guard first <= last else { return }
        for row in first...last {
            if row % 2 == 0 {
                NSColor.controlBackgroundColor.setFill()
                NSRect(x: 0, y: row * 40, width: 2000, height: 40).fill()
            }
            "第 \(row + 1) 行    中键点按后移开；回中心停止；点击或 Esc 退出。"
                .draw(at: NSPoint(x: 20, y: row * 40 + 10), withAttributes: attributes)
        }
    }
}

final class TestWindow {
    let window: NSWindow
    let scroll = NSScrollView()
    let label = NSTextField(labelWithString: "实际页面位移：0 px")
    private var observer: NSObjectProtocol?
    private var report: [String: Any] = [:]

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "AnchorScroll 实际滚动测试"; window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 850, height: 600))
        label.frame = NSRect(x: 20, y: 563, width: 810, height: 24)
        label.autoresizingMask = [.width, .minYMargin]
        scroll.frame = NSRect(x: 20, y: 20, width: 810, height: 530)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.documentView = TestDocument(frame: NSRect(x: 0, y: 0, width: 2000, height: 20000))
        scroll.contentView.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.label.stringValue = String(format: "实际页面位移：x %.1f  /  y %.1f px", self.scroll.contentView.bounds.minX, self.scroll.contentView.bounds.minY)
            }
        content.addSubview(scroll); content.addSubview(label); window.contentView = content; window.center()
    }

    /// Opt-in integration test. Measures NSScrollView bounds, not the indicator.
    /// Invoked only with --integration-test; uses the app's own accessibility grant.
    func runIntegration(events: EventController) {
        guard AXIsProcessTrusted() else { finish(["status": "blocked", "reason": "Accessibility permission required"]); return }
        let original = CGEvent(source: nil)?.location ?? .zero
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            report["frontmost_before_test"] = NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            report["post_event_access"] = CGPreflightPostEventAccess()
            report["delivery"] = events.deliveryDescription
            let cocoa = window.convertPoint(toScreen: scroll.convert(NSPoint(x: 200, y: 350), to: nil))
            let anchor = CGPoint(x: cocoa.x, y: CGDisplayBounds(CGMainDisplayID()).height - cocoa.y)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 1000))
            scroll.reflectScrolledClipView(scroll.contentView)
            report["vertical_direction_multiplier"] = events.testDirection
            let start = scroll.contentView.bounds.minY
            mouse(.mouseMoved, anchor)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in mouse(.otherMouseDown, anchor) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [self] in mouse(.otherMouseUp, anchor) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
                mouse(.mouseMoved, CGPoint(x: anchor.x, y: anchor.y + 14))
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
                    let slow = scroll.contentView.bounds.minY
                    let slowCursor = CGEvent(source: nil)?.location ?? .zero
                    report["slow_cursor_error"] = hypot(slowCursor.x-anchor.x, slowCursor.y-(anchor.y+14))
                    report["slow_displacement"] = slow - start
                    mouse(.mouseMoved, CGPoint(x: anchor.x, y: anchor.y + 100))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                        let fast = scroll.contentView.bounds.minY
                        let fastCursor = CGEvent(source: nil)?.location ?? .zero
                        report["fast_cursor_error"] = hypot(fastCursor.x-anchor.x, fastCursor.y-(anchor.y+100))
                        report["fast_displacement"] = fast - slow
                        mouse(.mouseMoved, anchor)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
                            let stopped = scroll.contentView.bounds.minY
                            let stoppedEventCount = events.outputEvents
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                                report["center_drift"] = scroll.contentView.bounds.minY - stopped
                                report["events_after_center_settled"] = events.outputEvents - stoppedEventCount
                                mouse(.leftMouseDown, anchor, button: .left)
                                mouse(.leftMouseUp, anchor, button: .left)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
                                    report["idle_after_click"] = events.state.mode == .idle
                                    report["output_events"] = events.outputEvents
                                    report["activations"] = events.activations
                                    report["listener_status"] = events.status
                                    report["trace"] = events.trace
                                    report["frontmost_is_test_app"] = NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
                                    let ok = (slow - start) * events.testDirection > 0
                                        && (fast - slow) * events.testDirection > (slow - start) * events.testDirection
                                        && abs(scroll.contentView.bounds.minY - stopped) < 1 && events.state.mode == .idle
                                        && (report["slow_cursor_error"] as? Double ?? .infinity) < 1
                                        && (report["fast_cursor_error"] as? Double ?? .infinity) < 1
                                    report["status"] = ok ? "passed" : "failed"
                                    mouse(.mouseMoved, original)
                                    finish(report)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    func mouse(_ type: CGEventType, _ location: CGPoint, button: CGMouseButton = .center) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: button)?.post(tap: .cghidEventTap)
    }
    func finish(_ result: [String: Any]) {
        guard let index = CommandLine.arguments.firstIndex(of: "--report"), CommandLine.arguments.count > index + 1 else { return }
        let path = CommandLine.arguments[index + 1]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
