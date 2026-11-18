import Testing
@testable import iGreenLight

struct MouseStickTests {
    /// Feeds steady movement at `speed` units per second for `seconds`, one event every `interval`.
    private func steady(_ stick: inout MouseStick, speed: Float, seconds: Double = 0.2, interval: Double = 0.004,
                        direction: (Float, Float) = (1, 0)) -> Double {
        let count = Int((seconds / interval).rounded())
        let d = speed * Float(interval)
        for i in 0..<count { stick.add(dx: d * direction.0, dy: d * direction.1, at: Double(i) * interval) }
        return Double(count - 1) * interval
    }

    @Test func aStillMouseLeavesTheStickCentred() {
        var stick = MouseStick()
        #expect(stick.value(at: 0) == (0, 0))
    }

    @Test func deflectionFollowsSpeed() {
        var stick = MouseStick(fullSpeed: 1000, deadZone: 0)
        let t = steady(&stick, speed: 500)
        let v = stick.value(at: t)
        #expect(abs(v.x - 0.5) < 0.02)
        #expect(v.y == 0)
    }

    @Test func fastMovementStopsAtFullDeflection() {
        var stick = MouseStick(fullSpeed: 1000, deadZone: 0.2)
        let t = steady(&stick, speed: 8000, direction: (0.6, 0.8))
        let v = stick.value(at: t)
        // In steps: Xcode 26's compiler gives up on these as single expressions inside #expect.
        let length: Float = (v.x * v.x + v.y * v.y).squareRoot()
        #expect(abs(length - 1) < 0.001)
        let offX: Float = abs(v.x - 0.6), offY: Float = abs(v.y - 0.8)
        #expect(offX < 0.001)
        #expect(offY < 0.001)
    }

    @Test func slowMovementIsLiftedPastTheDeadZone() {
        var stick = MouseStick(fullSpeed: 1000, deadZone: 0.2)
        let t = steady(&stick, speed: 50)
        let v = stick.value(at: t)
        #expect(v.x > 0.2 && v.x < 0.3)
    }

    @Test func theStickRecentresOneWindowAfterTheMouseStops() {
        var stick = MouseStick(fullSpeed: 1000, deadZone: 0.2)
        let t = steady(&stick, speed: 500)
        #expect(stick.value(at: t + stick.window * 0.5).x > 0)
        #expect(stick.value(at: t + stick.window + 0.001) == (0, 0))
    }

    /// The camera's turn is the stick held over time: the same mouse distance gives the same turn however the
    /// events are spaced (a 125 Hz mouse against a 1000 Hz one).
    @Test func turnFollowsDistanceWhateverTheEventRate() {
        func turn(everyMs: Int) -> Float {
            var stick = MouseStick(fullSpeed: 2000, deadZone: 0)
            var sum: Float = 0
            for ms in 0..<600 {
                // 600 units/s for 0.4 s, then still.
                if ms < 400, ms % everyMs == 0 { stick.add(dx: 0.6 * Float(everyMs), dy: 0, at: Double(ms) * 0.001) }
                // Sampled between the events' times, so none sits exactly on the edge of the window.
                sum += stick.value(at: Double(ms) * 0.001 + 0.0005).x * 0.001
            }
            return sum
        }
        let slow = turn(everyMs: 8), fast = turn(everyMs: 1)
        #expect(abs(slow - fast) / fast < 0.03)
        // 600 units/s for 0.4 s = 240 units; full deflection for one second is 2000.
        #expect(abs(fast - 240.0 / 2000) < 0.005)
    }

    @Test func theCurveBoostsSlowMovementAndLeavesFullDeflectionAlone() {
        var linear = MouseStick(fullSpeed: 1000, deadZone: 0), boosted = MouseStick(fullSpeed: 1000, deadZone: 0, curve: 0.5)
        let t = steady(&linear, speed: 250)
        _ = steady(&boosted, speed: 250)
        #expect(abs(linear.value(at: t).x - 0.25) < 0.02)
        #expect(abs(boosted.value(at: t).x - 0.5) < 0.02)
        var full = MouseStick(fullSpeed: 1000, deadZone: 0, curve: 0.5)
        let t2 = steady(&full, speed: 1000)
        #expect(abs(full.value(at: t2).x - 1) < 0.02)
    }

    @Test func sensitivityStepsAreFasterAndClamped() {
        #expect(MouseStick.fullSpeed(sensitivity: 5) == 400)
        #expect(MouseStick.fullSpeed(sensitivity: 6) < MouseStick.fullSpeed(sensitivity: 5))
        #expect(MouseStick.fullSpeed(sensitivity: 99) == MouseStick.fullSpeed(sensitivity: 10))
        #expect(MouseStick.fullSpeed(sensitivity: 0) == MouseStick.fullSpeed(sensitivity: 1))
    }
}
