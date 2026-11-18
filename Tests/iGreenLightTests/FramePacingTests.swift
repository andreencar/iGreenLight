import Testing
@testable import iGreenLight

struct IntervalStatsTests {
    @Test func noSamplesIsAllZero() {
        #expect(IntervalStats([]) == IntervalStats())
        #expect(IntervalStats([]).count == 0)
    }

    @Test func meanSpreadAndTail() {
        let s = IntervalStats([2, 4, 4, 4, 5, 5, 7, 9])
        #expect(s.count == 8)
        #expect(s.mean == 5)
        #expect(s.sd == 2)   // population standard deviation
        #expect(s.p95 == 9)
        #expect(s.max == 9)
    }

    @Test func p95IsTheNearestRank() {
        // 100 samples: the 95th smallest has 95 % at or below it.
        #expect(IntervalStats((1...100).map(Double.init)).p95 == 95)
        #expect(IntervalStats((1...20).map(Double.init)).p95 == 19)
        #expect(IntervalStats([16.7]).p95 == 16.7)
    }

    @Test func pooledWindowsMatchTheSamplesTogether() {
        let a = [16.0, 17, 17, 25, 8], b = [16.0, 33, 17]
        let pooled = IntervalStats.pooled([IntervalStats(a), IntervalStats([]), IntervalStats(b)])
        let all = IntervalStats(a + b)
        #expect(pooled.count == all.count)
        #expect(abs(pooled.mean - all.mean) < 1e-9)
        #expect(abs(pooled.sd - all.sd) < 1e-9)
        #expect(pooled.max == 33)
        #expect(pooled.p95 == 33)   // the worst window's
        #expect(IntervalStats.pooled([]) == IntervalStats())
    }
}

struct PacingMeterTests {
    @Test func countsDropsRepeatsAndIntervals() throws {
        let meter = PacingMeter()
        // Ticks before the first frame aren't a stream repeating.
        #expect(meter.tick(at: 0.9, newFrame: false, dropped: 0, paced: false) == nil)
        // 60 fps for 5 s with every tenth frame 8 ms late, on a 120 Hz display.
        var window: PacingWindow?
        var arrivals: [Double] = []
        for i in 0..<300 { arrivals.append(1 + Double(i) / 60 + (i % 10 == 9 ? 0.008 : 0)) }
        var next = 0, pending = false
        for k in 0...600 {
            let now = 1.001 + Double(k) / 120
            while next < arrivals.count, arrivals[next] <= now {
                meter.arrived(at: arrivals[next], rtp: UInt32(next) * 1500, dropped: pending ? 1 : 0)
                pending = true; next += 1
            }
            if pending { meter.presented(at: now + 0.02, drawn: now) }
            if let w = meter.tick(at: now, newFrame: pending, dropped: 0, paced: false) { window = w }
            pending = false
        }
        let w = try #require(window)
        #expect(w.received == 300)
        #expect(w.dropped == 0)
        #expect(w.ticks == 601)
        #expect(w.repeats == 301)
        #expect(abs(w.arrival.mean - 1000.0 / 60) < 0.05)
        #expect(w.arrival.sd > 3)
        #expect(abs(w.stream.mean - 1000.0 / 60) < 1e-6)
        #expect(w.stream.sd < 1e-6)
        // The late frames land one tick later: 25 ms, then 8 ms.
        #expect(abs(w.shown.max - 25) < 0.01)
        #expect(w.shownFromDrawTime == 0)
        #expect(meter.current == w.summary)
        #expect(!w.summary.contains("paced"))
    }

    @Test func fallsBackToDrawTimesWithoutMixingClocks() throws {
        let meter = PacingMeter()
        meter.arrived(at: 0, rtp: 0, dropped: 2)
        // Presented, presented, then two the system gave no time for, then presented again.
        meter.presented(at: 1.000, drawn: 0.980)
        meter.presented(at: 1.017, drawn: 0.997)
        meter.presented(at: 0, drawn: 1.014)
        meter.presented(at: 0, drawn: 1.030)
        meter.presented(at: 1.067, drawn: 1.047)
        let w = try #require(meter.tick(at: 6, newFrame: false, dropped: 1, paced: true))
        // Only presented→presented and drawn→drawn count.
        #expect(w.shown.count == 2)
        #expect(w.shownFromDrawTime == 1)
        #expect(abs(w.shown.max - 17) < 0.01)
        #expect(w.dropped == 3)
        #expect(w.summary.hasSuffix(", paced"))
    }

    @Test func aStoppedStreamReportsOneEmptyWindowThenGoesQuiet() {
        let meter = PacingMeter()
        meter.arrived(at: 0, rtp: 0, dropped: 0)
        #expect(meter.tick(at: 5, newFrame: true, dropped: 0, paced: false) != nil)
        #expect(meter.tick(at: 10, newFrame: false, dropped: 0, paced: false)?.received == 0)
        #expect(meter.tick(at: 15, newFrame: false, dropped: 0, paced: false) == nil)
    }
}

struct FramePacerTests {
    /// Deterministic noise, roughly normal with standard deviation 1.
    private struct Noise {
        var state: UInt64 = 42
        mutating func unit() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func normal() -> Double { (0..<12).reduce(-6) { s, _ in s + unit() } }
    }

    private struct Shown { let frame: Int; let time: Double }

    /// Runs frames (arrival time, RTP timestamp) through a display ticking at `hz`. Unpaced is the renderer's
    /// own rule: every tick takes the newest frame.
    private func play(_ arrivals: [(time: Double, rtp: UInt32)], hz: Double, phase: Double = 0.003, paced: Bool = true,
                      pacer: inout FramePacer<Int>) -> [Shown] {
        var shown: [Shown] = [], next = 0, pending: Int?
        var now = phase
        let end = (arrivals.last?.time ?? 0) + 0.2
        while now < end {
            while next < arrivals.count, arrivals[next].time <= now {
                if paced { pacer.enqueue(next, rtp: arrivals[next].rtp, at: arrivals[next].time) } else { pending = next }
                next += 1
            }
            if let f = paced ? pacer.dequeue(at: now) : pending { shown.append(Shown(frame: f, time: now)) }
            pending = nil
            now += 1 / hz
        }
        return shown
    }

    /// `seconds` of a stream at `fps` whose frames arrive with `jitter` (standard deviation, seconds). The RTP
    /// timestamps start just below the 32-bit wrap, so every run crosses it.
    private func stream(fps: Double, seconds: Double, jitter: Double, from start: Double = 1, rtpStart: UInt32 = 4_294_960_000,
                        seed: UInt64 = 42) -> [(time: Double, rtp: UInt32)] {
        var noise = Noise(state: seed), last = 0.0
        return (0..<Int(seconds * fps)).map { i in
            let t = max(last + 0.0005, start + Double(i) / fps + noise.normal() * jitter)
            last = t
            return (t, rtpStart &+ UInt32((Double(i) * 90_000 / fps).rounded()))
        }
    }

    private func intervals(_ shown: [Shown], after start: Double) -> [Double] {
        let t = shown.filter { $0.time >= start }.map(\.time)
        return zip(t.dropFirst(), t).map { ($0 - $1) * 1000 }
    }

    @Test func steadyArrivalsPassStraightThroughOnEveryOtherTick() {
        var pacer = FramePacer<Int>()
        let frames = stream(fps: 60, seconds: 3, jitter: 0)
        let shown = play(frames, hz: 120, pacer: &pacer)
        #expect(shown.map(\.frame) == Array(0..<frames.count))
        #expect(pacer.dropped == 0)
        #expect(abs(pacer.interval - 1.0 / 60) < 1e-4)
        #expect(abs(pacer.refresh - 1.0 / 120) < 1e-9)
        let gaps = intervals(shown, after: 1.5)
        #expect(gaps.allSatisfy { abs($0 - 1000.0 / 60) < 0.01 })
        // Half a stream frame of margin, plus at most the wait for a tick either side of it.
        for s in shown where s.time >= 1.5 {
            let held = (s.time - frames[s.frame].time) * 1000
            #expect(held > 8.3 - 4.2 - 0.01 && held < 8.3 + 8.4)
        }
    }

    @Test func jitteredArrivalsComeOutEvenOn120Hz() {
        // 7 ms of arrival jitter around 60 fps: what the recorded session looked like.
        let frames = stream(fps: 60, seconds: 20, jitter: 0.007)
        for phase in [0.0, 0.002, 0.004, 0.006] {
            var pacer = FramePacer<Int>(), unused = FramePacer<Int>()
            let paced = IntervalStats(intervals(play(frames, hz: 120, phase: phase, pacer: &pacer), after: 3))
            let unpaced = IntervalStats(intervals(play(frames, hz: 120, phase: phase, paced: false, pacer: &unused), after: 3))
            #expect(unpaced.sd > 7)
            #expect(paced.sd < unpaced.sd / 2)
            #expect(abs(paced.mean - 1000.0 / 60) < 0.1)
            // Unpaced drops a frame whenever two arrive within one tick; paced has room for them.
            #expect(pacer.dropped <= 3)
            let even = intervals(play(frames, hz: 120, phase: phase, pacer: &unused), after: 3).filter { abs($0 - 1000.0 / 60) < 0.01 }
            #expect(Double(even.count) / Double(paced.count) > 0.85)
        }
    }

    @Test func oneFramePerTickOn60Hz() {
        let frames = stream(fps: 60, seconds: 20, jitter: 0.007)
        for phase in [0.0, 0.004, 0.008, 0.012] {
            var pacer = FramePacer<Int>(), unused = FramePacer<Int>()
            let paced = intervals(play(frames, hz: 60, phase: phase, pacer: &pacer), after: 3)
            let unpaced = intervals(play(frames, hz: 60, phase: phase, paced: false, pacer: &unused), after: 3)
            func repeats(_ gaps: [Double]) -> Int { gaps.filter { $0 > 20 }.count }
            #expect(repeats(unpaced) > 150)
            #expect(repeats(paced) < repeats(unpaced) / 2)
        }
    }

    @Test func latencyStaysBounded() {
        let frames = stream(fps: 60, seconds: 20, jitter: 0.007)
        for hz in [60.0, 120] {
            var pacer = FramePacer<Int>()
            let shown = play(frames, hz: hz, pacer: &pacer)
            let held = shown.filter { $0.time >= 3 }.map { ($0.time - frames[$0.frame].time) * 1000 }
            // On average about half a stream frame plus the wait for a tick; never more than the queue can hold.
            #expect(held.reduce(0, +) / Double(held.count) < 8.3 + 1000 / hz)
            #expect((held.max() ?? 0) < 50)
        }
    }

    @Test func aBurstDropsTheOldestSoLatencyCannotGrow() {
        var pacer = FramePacer<Int>()
        // Steady frames set the clock, then five arrive at once (a stall releasing).
        for i in 0..<30 { pacer.enqueue(i, rtp: UInt32(i) * 1500, at: Double(i) / 60); _ = pacer.dequeue(at: Double(i) / 60 + 0.012) }
        #expect(pacer.count == 0)
        let burst = 30.0 / 60
        for i in 30..<35 { pacer.enqueue(i, rtp: UInt32(i) * 1500, at: burst + Double(i - 30) * 0.0001) }
        #expect(pacer.count == FramePacer<Int>.capacity)
        #expect(pacer.dropped == 2)
        // The frames kept are the newest, in order.
        var out: [Int] = []
        for k in 0..<12 { if let f = pacer.dequeue(at: burst + 0.004 + Double(k) / 120) { out.append(f) } }
        #expect(out == out.sorted())
        #expect(out.last == 34)
        #expect(pacer.count == 0)
    }

    @Test func aStallResyncsToTheNextFrame() {
        var pacer = FramePacer<Int>()
        let before = stream(fps: 60, seconds: 2, jitter: 0.003)
        // 3 s with nothing, then the stream is back 40 ms later relative to its timestamps (a new network delay).
        let gap = 3.04, count = before.count
        let after = stream(fps: 60, seconds: 2, jitter: 0.003, from: 1 + 2 + gap, rtpStart: 4_294_960_000 &+ UInt32((2 + 3.0) * 90_000), seed: 7)
        let frames = before + after
        let shown = play(frames, hz: 120, pacer: &pacer)
        #expect(pacer.resyncs == 2)   // the first frame, and the first after the stall
        // Nothing waits in the queue through the stall, and the first frame after it is shown at once.
        let lastBefore = shown.last { $0.frame < count }!
        #expect(lastBefore.time < before[count - 1].time + 0.05)
        let firstAfter = shown.first { $0.frame >= count }!
        #expect(firstAfter.frame == count)
        #expect(firstAfter.time - frames[count].time < 0.03)
        // And the cadence is even again within a second.
        let gaps = intervals(shown, after: frames[count].time + 1)
        // In steps: Xcode 26's compiler gives up on these as single expressions inside #expect.
        let step: Double = 1000.0 / 60
        let even: Int = gaps.filter { abs($0 - step) < 0.01 }.count
        let evenShare: Double = Double(even) / Double(gaps.count)
        #expect(evenShare > 0.85)
        let held: [Double] = shown.filter { $0.frame >= count + 60 }.map { ($0.time - frames[$0.frame].time) * 1000 }
        let meanHeld: Double = held.reduce(0, +) / Double(held.count)
        #expect(meanHeld < 16.7)
    }

    @Test func followsAFrameRateChange() {
        var pacer = FramePacer<Int>()
        let fast = stream(fps: 60, seconds: 2, jitter: 0.002)
        let slow = stream(fps: 30, seconds: 3, jitter: 0.002, from: 3, rtpStart: 4_294_960_000 &+ 180_000, seed: 3)
        let again = stream(fps: 60, seconds: 3, jitter: 0.002, from: 6, rtpStart: 4_294_960_000 &+ 450_000, seed: 5)
        let frames = fast + slow + again
        let shown = play(frames, hz: 120, pacer: &pacer)
        #expect(abs(pacer.interval - 1.0 / 60) < 1e-4)
        // Every 30 fps frame is shown, 33 ms apart once the clock has settled, and nothing piles up afterwards.
        let slowGaps = intervals(shown.filter { $0.frame >= fast.count && $0.frame < fast.count + slow.count }, after: 4)
        #expect(slowGaps.allSatisfy { abs($0 - 1000.0 / 30) < 8.4 })
        let fastGaps = intervals(shown, after: 7)
        #expect(Double(fastGaps.filter { abs($0 - 1000.0 / 60) < 0.01 }.count) / Double(fastGaps.count) > 0.85)
        #expect(pacer.dropped <= 2)
        let held = shown.filter { $0.time >= 7 }.map { ($0.time - frames[$0.frame].time) * 1000 }
        #expect((held.max() ?? 0) < 35)
    }

    @Test func framesWithoutUsableTimestampsBehaveAsUnpaced() {
        // Every frame carries the same RTP timestamp: there is no cadence to follow, so the newest goes out at each tick.
        let frames = stream(fps: 60, seconds: 3, jitter: 0.007).map { (time: $0.time, rtp: UInt32(0)) }
        var pacer = FramePacer<Int>(), unused = FramePacer<Int>()
        let paced = play(frames, hz: 120, pacer: &pacer)
        let unpaced = play(frames, hz: 120, paced: false, pacer: &unused)
        #expect(paced.map(\.frame) == unpaced.map(\.frame))
        #expect(paced.map(\.time) == unpaced.map(\.time))
    }

    @Test func anEmptyQueueShowsNothing() {
        var pacer = FramePacer<Int>()
        #expect(pacer.dequeue(at: 0) == nil)
        pacer.enqueue(1, rtp: 0, at: 0.010)
        // The very first frame has no clock yet and goes out on the next tick.
        #expect(pacer.dequeue(at: 0.0167) == 1)
        #expect(pacer.dequeue(at: 0.025) == nil)
        pacer.reset()
        #expect(pacer.count == 0 && pacer.interval == 0)
    }
}

struct FreezeReportTests {
    @Test func aNewFreezeIsReportedWithWhatCameWithIt() throws {
        let before = FreezeCounters(freezes: 1, seconds: 0.4, pauses: 0, nack: 10, pli: 1, dropped: 3, lost: 2)
        var now = before
        #expect(now.report(since: before, resolution: "1920x1080", fps: 60) == nil)
        now.nack = 30   // counters moving without a freeze is not one
        #expect(now.report(since: before, resolution: "1920x1080", fps: 60) == nil)
        now.freezes = 2; now.seconds = 3.6; now.pli = 2
        let line = try #require(now.report(since: before, resolution: "1920x1080", fps: 58))
        #expect(line.hasPrefix("freeze #2: 3.20 s (1 new, 3.60 s frozen in total)"))
        #expect(line.contains("NACK +20, PLI +1, frames dropped +0, packets lost +0"))
        #expect(line.hasSuffix("decoding 1920x1080 at 58 fps"))
    }

    @Test func theOverlayLineShowsTheDeltaThenHowLongAgo() {
        var s = StreamStats()
        #expect(s.freezeLine == "freezes: 0 (0.00 s frozen)")
        #expect(!s.freezeIsRecent)
        s.freezeCount = 2; s.freezeSeconds = 3.6; s.newFreezes = 1; s.newFreezeSeconds = 3.2; s.sinceFreeze = 0
        #expect(s.freezeLine == "freezes: 2 (3.60 s frozen)  +1 now (3.20 s)")
        #expect(s.freezeIsRecent)
        s.newFreezes = 0; s.sinceFreeze = 42
        #expect(s.freezeLine == "freezes: 2 (3.60 s frozen)  last 42 s ago")
        #expect(!s.freezeIsRecent)
    }
}
