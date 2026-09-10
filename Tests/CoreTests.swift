import Foundation

@main struct CoreTests {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        count += 1
        guard condition() else { fputs("FAIL: \(label)\n", stderr); exit(1) }
        print("PASS: \(label)")
    }
    static func displacement(distance: Double, fps: Int, seconds: Int = 10, lineMode: Bool = false) -> Int {
        var integrator = ScrollIntegrator(), total = 0
        for _ in 0..<(fps * seconds) {
            total += Int(integrator.step(dx: 0, dy: distance, elapsed: 1 / Double(fps),
                                         tuning: ScrollTuning(), lineMode: lineMode).1)
        }
        return total
    }
    static func main() {
        let tuning = ScrollTuning()
        check(tuning.speed(0) == 0 && tuning.speed(6) == 0 && tuning.speed(-6) == 0, "center dead zone")
        check(tuning.speed(7) > 0, "speed starts just outside center")
        check(tuning.speed(50) == -tuning.speed(-50), "symmetric directions")
        check(tuning.speed(1000) == 1800, "maximum speed cap")
        check(tuning.speed(.nan) == 0 && tuning.speed(.infinity) == 0, "non-finite pointer rejected")
        for d in 7...246 { check(tuning.speed(Double(d)) >= tuning.speed(Double(d-1)), "monotonic \(d)") }
        for d in [7.0, 10, 14, 50, 100, 300] {
            let expected = Int(tuning.speed(d) * 10)
            for fps in [60, 120, 240] {
                check(abs(displacement(distance: d, fps: fps) - expected) <= 1, "integrated distance \(d) at \(fps) Hz")
            }
        }
        check(displacement(distance: 7, fps: 120) > 0, "subpixel slow motion is not lost")
        check(abs(displacement(distance: -14, fps: 120) + displacement(distance: 14, fps: 120)) <= 1, "upward cumulative distance")
        check(abs(displacement(distance: 100, fps: 120, lineMode: true) * 20 - displacement(distance: 100, fps: 120)) < 21, "line mode conversion")
        var core = ScrollIntegrator()
        for _ in 0..<9 { _ = core.step(dx: 0, dy: 14, elapsed: 1/120, tuning: tuning) }
        check(core.remainderY > 0, "remainder retained")
        let stop = core.step(dx: 0, dy: 0, elapsed: 1/120, tuning: tuning)
        check(stop.1 == 0 && core.remainderY == 0, "center flushes remainder")
        _ = core.step(dx: 0, dy: 14, elapsed: 1/120, tuning: tuning)
        let reverse = core.step(dx: 0, dy: -14, elapsed: 1/120, tuning: tuning)
        check(reverse.1 <= 0 && core.remainderY < 0, "reverse drops old direction")
        core.reset()
        check(core.remainderX == 0 && core.remainderY == 0, "cancel flushes all residue")
        check(core.step(dx: 0, dy: 300, elapsed: 9, tuning: tuning).1 <= 90, "stall cannot replay backlog")
        check(core.step(dx: 300, dy: 0, elapsed: 1/120, tuning: tuning).0 == 0, "horizontal disabled")
        var horizontal = tuning; horizontal.horizontal = true
        check(core.step(dx: 300, dy: 0, elapsed: 1/120, tuning: horizontal).0 > 0, "horizontal enabled")

        var click = ClickState()
        check(click.down(2, option: false, eligible: true) == .arm && click.mode == .armed, "middle down only arms")
        check(click.up(2) == .activate && click.mode == .active, "middle release activates")
        check(click.down(0, option: false, eligible: true) == .stop, "exit left click consumed")
        check(click.up(0) == .swallow, "exit left release consumed")
        check(click.down(0, option: false, eligible: true) == .pass && click.up(0) == .pass, "next left click passes")
        check(click.down(2, option: true, eligible: true) == .pass, "Option middle passes")
        check(click.up(2) == .pass && click.mode == .idle, "Option middle release passes")
        check(click.down(2, option: false, eligible: false) == .pass && click.up(2) == .pass, "excluded and paused passthrough")
        _ = click.down(2, option: false, eligible: true); click.cancel()
        check(click.up(2) == .swallow && click.mode == .idle, "focus cancellation preserves paired release")
        _ = click.down(2, option: false, eligible: true); _ = click.up(2)
        check(click.escape(down: true) == .stop && click.escape(down: false) == .swallow, "Escape pair stops mode")
        check(click.escape(down: true) == .pass, "ordinary Escape passes")
        _ = click.down(2, option: false, eligible: true); _ = click.up(2)
        check(click.down(2, option: true, eligible: true) == .pass && click.mode == .idle && click.up(2) == .pass, "Option middle cancels active mode and passes")
        for _ in 0..<100 {
            _ = click.down(2, option: false, eligible: true); _ = click.up(2)
            _ = click.down(2, option: false, eligible: true); _ = click.up(2)
        }
        check(click.mode == .idle && click.swallowedButtons.isEmpty, "100 rapid activation and cancellation cycles")
        print("\(count) assertions passed")
    }
}
