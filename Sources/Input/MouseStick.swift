import Foundation

/// Mouse movement → analog stick, for games that only take a controller.
///
/// A mouse reports how far it moved; a stick reports how hard it is pushed, and the game turns the camera at a
/// speed that follows the push. So the stick is driven by the mouse's speed: the movement of the last `window`
/// seconds, divided by the speed that means "stick fully over". Every bit of movement counts for exactly one
/// window's worth of time, so (below full deflection) how far the camera turns follows how far the mouse went,
/// however the events happen to be spaced, and the stick is back at centre one window after the mouse stops.
///
/// Games ignore a stick that is barely off centre (the dead zone), which would swallow slow, precise movement.
/// `deadZone` lifts any movement past it: the output starts at the edge of the dead zone and grows from there.
///
/// The same recipe as Better xCloud's virtual controller and the XIM / Cronus adapters, and with the same limit:
/// the game caps how fast the camera turns at full deflection, so a flick is never as fast as on a PC.
struct MouseStick {
    /// Mouse speed, in the platform's units per second, that pushes the stick all the way.
    var fullSpeed: Float = 400
    /// 0..<1: the part of the stick's travel the game ignores.
    var deadZone: Float = 0.1
    /// Shapes the response: 1 is linear; below 1 pushes the stick further for slow movement, to undo the curve
    /// most games put on their sticks (little turn for a small push, a lot for a big one).
    var curve: Float = 1
    /// Seconds of movement the speed is measured over.
    var window: Double = 0.032

    private var samples: [(time: Double, dx: Float, dy: Float)] = []

    /// Written out: with a private stored property the memberwise initialiser is private too before Swift 6.3,
    /// and the tests set these.
    init(fullSpeed: Float = 400, deadZone: Float = 0.1, curve: Float = 1, window: Double = 0.032) {
        self.fullSpeed = fullSpeed
        self.deadZone = deadZone
        self.curve = curve
        self.window = window
    }

    /// Below this the mouse counts as still (after the window's averaging, it's the tail of one small event).
    private static let stillness: Float = 0.004

    mutating func add(dx: Float, dy: Float, at time: Double) {
        samples.append((time, dx, dy))
    }

    mutating func reset() { samples.removeAll(keepingCapacity: true) }

    /// The stick position at `time`: x and y in -1...1, in the mouse's own directions (+y is down).
    mutating func value(at time: Double) -> (x: Float, y: Float) {
        samples.removeAll { time - $0.time >= window }
        guard !samples.isEmpty, fullSpeed > 0 else { return (0, 0) }
        var sx: Float = 0, sy: Float = 0
        for s in samples { sx += s.dx; sy += s.dy }
        let scale = 1 / (Float(window) * fullSpeed)
        let x = sx * scale, y = sy * scale
        let length = (x * x + y * y).squareRoot()
        guard length > Self.stillness else { return (0, 0) }
        let lifted = min(1, deadZone + (1 - deadZone) * powf(min(1, length), curve))
        return (x / length * lifted, y / length * lifted)
    }

    /// The setting (1...10, 5 in the middle) as a full-deflection speed: each step is about 30% faster.
    /// The middle is a moderate hand movement (the other tools of this kind sit around there too): the stick has
    /// to be fully over long before a fast swipe, or the camera only ever crawls.
    static func fullSpeed(sensitivity: Int) -> Float {
        400 / powf(1.3, Float(min(10, max(1, sensitivity)) - 5))
    }

    /// The curve setting (0 linear, 1 boosted, 2 strong) as an exponent.
    static func curve(setting: Int) -> Float { [1, 0.7, 0.5][min(2, max(0, setting))] }
}
