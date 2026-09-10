import Foundation

/// All distances are Quartz logical screen points; output is scrolling pixels.
struct ScrollTuning: Equatable {
    var deadZone = 6.0
    var fullDistance = 240.0
    var exponent = 1.5
    var maxSpeed = 1800.0
    var sensitivity = 1.0
    var horizontal = false

    func speed(_ distance: Double) -> Double {
        guard distance.isFinite else { return 0 }
        let excess = max(0, abs(distance) - deadZone)
        let fraction = min(excess * sensitivity / fullDistance, 1)
        return (distance < 0 ? -1 : 1) * maxSpeed * pow(fraction, exponent)
    }
}

struct ScrollIntegrator {
    private(set) var remainderX = 0.0
    private(set) var remainderY = 0.0
    private var previousX = 0.0
    private var previousY = 0.0

    mutating func reset() { self = ScrollIntegrator() }

    // Fractional displacement is retained across frames, never rounded away.
    // Zero / sign changes discard the old direction's residue immediately.
    private mutating func integrate(_ speed: Double, dt: Double, unit: Double,
                                    remainder: inout Double, previous: inout Double) -> Int32 {
        if speed == 0 || (speed > 0) != (previous > 0) { remainder = 0 }
        previous = speed
        guard speed != 0 else { return 0 }
        remainder += speed * dt / unit
        let whole = remainder.rounded(.towardZero)
        remainder -= whole
        return Int32(whole)
    }

    mutating func step(dx: Double, dy: Double, elapsed: Double,
                       tuning: ScrollTuning, lineMode: Bool = false) -> (Int32, Int32) {
        guard elapsed.isFinite, elapsed > 0 else { return (0, 0) }
        // Never replay a large backlog after a blocked run loop or wake.
        let dt = min(elapsed, 0.05)
        let unit = lineMode ? 20.0 : 1.0
        // Local copies avoid overlapping mutating access to self.
        var rx = remainderX, ry = remainderY, px = previousX, py = previousY
        let x = integrate(tuning.horizontal ? tuning.speed(dx) : 0, dt: dt,
                          unit: unit, remainder: &rx, previous: &px)
        let y = integrate(tuning.speed(dy), dt: dt,
                          unit: unit, remainder: &ry, previous: &py)
        remainderX = rx; remainderY = ry; previousX = px; previousY = py
        return (x, y)
    }
}

/// Pure event state machine, shared by the app and regression tests.
struct ClickState {
    enum Mode { case idle, armed, active }
    enum Action: Equatable { case pass, swallow, arm, activate, stop }
    private(set) var mode: Mode = .idle
    private(set) var swallowedButtons = Set<Int>()
    private var passthroughMiddle = false
    private var swallowedEscape = false

    mutating func cancel() { mode = .idle }

    mutating func down(_ button: Int, option: Bool, eligible: Bool) -> Action {
        if swallowedButtons.contains(button) { return .swallow }
        if button == 2 && option {
            passthroughMiddle = true
            mode = .idle
            return .pass
        }
        if mode != .idle {
            swallowedButtons.insert(button)
            mode = .idle
            return .stop
        }
        guard button == 2, eligible, !passthroughMiddle else { return .pass }
        swallowedButtons.insert(button)
        mode = .armed
        return .arm
    }

    mutating func up(_ button: Int) -> Action {
        if button == 2 && passthroughMiddle {
            passthroughMiddle = false
            return .pass
        }
        guard swallowedButtons.remove(button) != nil else { return .pass }
        if button == 2 && mode == .armed {
            mode = .active
            return .activate
        }
        return .swallow
    }

    mutating func escape(down: Bool) -> Action {
        if down && swallowedEscape { return .swallow }
        if !down && swallowedEscape { swallowedEscape = false; return .swallow }
        if down && mode != .idle {
            swallowedEscape = true; mode = .idle; return .stop
        }
        return .pass
    }
}
