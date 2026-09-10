import AppKit
import ApplicationServices
import QuartzCore

final class EventController {
    static let eventTag: Int64 = 0x414E43484F52
    let prefs: Preferences
    let indicator = Indicator()
    var statusChanged: ((String) -> Void)?
    private(set) var status = "尚未启动"
    private(set) var state = ClickState()
    private(set) var outputEvents = 0
    private(set) var activations = 0
    private(set) var trace: [String] = []
    private let tracing = CommandLine.arguments.contains("--integration-test")
    // Default input and output use HID. Scroll output uses the current cursor
    // position, not the speed anchor, to avoid moving the real cursor.
    private var outputTap: CGEventTapLocation {
        if CommandLine.arguments.contains("--test-hid-output") { return .cghidEventTap }
        if CommandLine.arguments.contains("--test-session-output") { return .cgSessionEventTap }
        if prefs.defaults.string(forKey: "eventDelivery") == "hid" { return .cghidEventTap }
        if prefs.defaults.string(forKey: "eventDelivery") == "session" { return .cgSessionEventTap }
        return .cghidEventTap
    }
    private var gesturePhases: Bool {
        CommandLine.arguments.contains("--test-gesture-phases") || prefs.defaults.bool(forKey: "gesturePhases")
    }
    var testDirection: Double { prefs.reverseVertical ? -1 : 1 }
    var deliveryDescription: String { "tap=\(outputTap.rawValue), gesturePhases=\(gesturePhases)" }
    func note(_ value: String) {
        if tracing && trace.count < 100 { trace.append(value) }
    }
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var timer: Timer?
    private var watchdog: Timer?
    private var observers: [NSObjectProtocol] = []
    private var anchor = CGPoint.zero
    private var pointer = CGPoint.zero
    private var targetPID: pid_t = 0
    private var lineMode = false
    private var lastTick = 0.0
    private var integrator = ScrollIntegrator()
    private var phaseStarted = false
    private let eventSource = CGEventSource(stateID: .privateState)

    init(prefs: Preferences) {
        self.prefs = prefs
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in self?.cancel()
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) {
                [weak self] _ in self?.cancel()
            })
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !AXIsProcessTrusted() {
                self.cancel()
                self.setStatus("需要辅助功能授权")
            } else if let tap = self.tap, !CGEvent.tapIsEnabled(tap: tap) {
                self.cancel(); CGEvent.tapEnable(tap: tap, enable: true)
                self.setStatus(CGEvent.tapIsEnabled(tap: tap) ? "已恢复，请重新点按中键" : "监听不可用，请重试")
            } else if self.tap == nil {
                self.start(prompt: false)
            }
        }
    }

    func setStatus(_ value: String) { status = value; statusChanged?(value) }

    func start(prompt: Bool) {
        cancel()
        if prompt {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        guard AXIsProcessTrusted() else { setStatus("需要辅助功能授权"); return }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            setStatus(CGEvent.tapIsEnabled(tap: tap) ? "已就绪" : "监听不可用，请重试")
            return
        }
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .mouseMoved, .leftMouseDragged, .rightMouseDragged,
            .otherMouseDragged, .keyDown, .keyUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<EventController>.fromOpaque(context).takeUnretainedValue()
            return owner.handle(type, event)
        }
        guard let newTap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            setStatus("监听创建失败，请检查辅助功能和输入监控权限")
            return
        }
        tap = newTap
        tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        setStatus("已就绪")
    }

    func configurationChanged() {
        cancel()
        setStatus(prefs.enabled ? (tap == nil ? "需要授权／重试" : "已就绪") : "已暂停")
    }

    func cancel() {
        if state.mode != .idle { note("cancel mode=\(state.mode)") }
        timer?.invalidate(); timer = nil
        integrator.reset()
        if phaseStarted { post(x: 0, y: 0, ending: true) }
        phaseStarted = false
        state.cancel(); indicator.hide()
    }

    func shutdown() {
        cancel(); watchdog?.invalidate()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            cancel()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            setStatus("监听已恢复，请重新点按中键")
            return Unmanaged.passUnretained(event)
        }
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            pointer = event.location
            if state.mode == .armed && hypot(pointer.x - anchor.x, pointer.y - anchor.y) > 6 {
                cancel() // Point-and-release activation; a held drag does not latch.
            }
            if state.mode == .active {
                indicator.update(dy: pointer.y - anchor.y, deadZone: prefs.tuning.deadZone)
                // Drop residue as soon as the pointer reaches center, before the next tick.
                _ = integrator.step(dx: pointer.x - anchor.x, dy: pointer.y - anchor.y,
                                    elapsed: Double.leastNonzeroMagnitude, tuning: prefs.tuning,
                                    lineMode: lineMode)
            }
            return pass
        case .keyDown, .keyUp:
            guard event.getIntegerValueField(.keyboardEventKeycode) == 53 else { return pass }
            let result = state.escape(down: type == .keyDown)
            if result == .stop { cancel() }
            return result == .pass ? pass : nil
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            let app = NSWorkspace.shared.frontmostApplication
            let noOtherHeld = !CGEventSource.buttonState(.combinedSessionState, button: .left)
                && !CGEventSource.buttonState(.combinedSessionState, button: .right)
            let eligible = prefs.enabled && noOtherHeld && !prefs.excluded.contains(app?.bundleIdentifier ?? "")
            let result = state.down(button, option: event.flags.contains(.maskAlternate), eligible: eligible)
            note("down button=\(button) eligible=\(eligible) otherHeld=\(!noOtherHeld) result=\(result)")
            if result == .arm {
                anchor = event.location; pointer = anchor
                targetPID = app?.processIdentifier ?? 0
                lineMode = prefs.lineApps.contains(app?.bundleIdentifier ?? "")
            } else if result == .stop || (button == 2 && event.flags.contains(.maskAlternate)) {
                cancel()
            }
            return result == .pass ? pass : nil
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            let result = state.up(Int(event.getIntegerValueField(.mouseEventButtonNumber)))
            note("up result=\(result)")
            if result == .activate {
                guard prefs.enabled, targetPID == NSWorkspace.shared.frontmostApplication?.processIdentifier else {
                    cancel(); return nil
                }
                activations += 1
                pointer = event.location
                integrator.reset(); lastTick = CACurrentMediaTime()
                indicator.show(at: anchor)
                let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.tick() }
                timer = t; RunLoop.main.add(t, forMode: .common)
            }
            return result == .pass ? pass : nil
        default: return pass
        }
    }

    private func tick() {
        guard state.mode == .active else { return }
        guard targetPID == NSWorkspace.shared.frontmostApplication?.processIdentifier else { cancel(); return }
        let now = CACurrentMediaTime()
        let dt = now - lastTick; lastTick = now
        let dx = pointer.x - anchor.x, dy = pointer.y - anchor.y
        let t = prefs.tuning
        let delta = integrator.step(dx: dx, dy: dy, elapsed: dt, tuning: t, lineMode: lineMode)
        if t.speed(dy) == 0 && (!t.horizontal || t.speed(dx) == 0) {
            if phaseStarted { post(x: 0, y: 0, ending: true); phaseStarted = false }
            return
        }
        if delta.0 != 0 || delta.1 != 0 { post(x: -delta.0, y: prefs.reverseVertical ? delta.1 : -delta.1) }
    }

    private func post(x: Int32, y: Int32, ending: Bool = false) {
        guard !ending || (!lineMode && gesturePhases) else { return }
        guard let event = CGEvent(scrollWheelEvent2Source: eventSource,
            units: lineMode ? .line : .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0) else { return }
        // HID scroll events also update the global cursor position on this Mac.
        // Never send the fixed anchor through HID: it pulls the physical cursor back
        // and resets the next real mouse movement to the dead zone.
        event.location = CGEvent(source: nil)?.location ?? pointer
        event.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: lineMode ? 0 : 1)
        if !lineMode && gesturePhases {
            // CGScrollPhase: began=1, changed=2, ended=4; momentum is never synthesized.
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: ending ? 4 : (phaseStarted ? 2 : 1))
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        }
        event.post(tap: outputTap)
        if !ending { phaseStarted = true; outputEvents += 1 }
    }
}
