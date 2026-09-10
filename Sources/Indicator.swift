import AppKit

final class Indicator {
    private let panel: NSPanel
    private let drawing: IndicatorDrawing
    init() {
        drawing = IndicatorDrawing(frame: NSRect(x: 0, y: 0, width: 34, height: 34))
        panel = NSPanel(contentRect: drawing.frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false; panel.contentView = drawing
    }
    func show(at point: CGPoint) {
        // Cocoa global coordinates are flipped around the PRIMARY display height.
        // Using the current screen's height breaks displays above/below the primary.
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        panel.setFrameOrigin(NSPoint(x: point.x - 17, y: primaryHeight - point.y - 17))
        drawing.direction = 0; panel.orderFrontRegardless()
    }
    func update(dy: Double, deadZone: Double) {
        let direction = abs(dy) <= deadZone ? 0 : (dy > 0 ? -1 : 1)
        if drawing.direction != direction { drawing.direction = direction }
    }
    func hide() { panel.orderOut(nil) }
}

final class IndicatorDrawing: NSView {
    var direction = 0 { didSet { needsDisplay = true } }
    override func draw(_ rect: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        NSColor.labelColor.withAlphaComponent(0.4).setStroke()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).stroke()
        for sign in [-1, 1] {
            (direction == sign ? NSColor.systemBlue : NSColor.secondaryLabelColor).setFill()
            let p = NSBezierPath()
            p.move(to: NSPoint(x: 17, y: 17 + sign * 12))
            p.line(to: NSPoint(x: 12, y: 17 + sign * 6))
            p.line(to: NSPoint(x: 22, y: 17 + sign * 6)); p.close(); p.fill()
        }
        NSColor.labelColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: 15, y: 15, width: 4, height: 4)).fill()
    }
}
