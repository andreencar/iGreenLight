import Foundation
import Testing
@testable import iGreenLight

struct FreezeDetectorTests {
    /// Runs the detector the way the session does: a check every 100 ms, stats only when it asks for them.
    /// `frameAge` is how long ago the last frame came at each tick (nil: none yet), `bytesPerTick` what arrives between ticks.
    private func run(_ d: inout FreezeDetector, from start: Double = 0, ticks: Int, fps: Double = 60, active: Bool = true,
                     bytesPerTick: Double = 30_000, decodedPerTick: Double = 0, frameAge: (Int) -> Double?) -> (requests: [Double], probes: Int) {
        var requests: [Double] = [], probes = 0
        for i in 0..<ticks {
            let now = start + Double(i) * FreezeDetector.tick, age = frameAge(i)
            guard d.suspects(sinceLastFrame: age, fps: fps, active: active, now: now) else { continue }
            probes += 1
            let probe = FreezeDetector.Probe(bytes: Double(i) * bytesPerTick, framesDecoded: 100 + Double(i) * decodedPerTick)
            if d.observe(probe, sinceLastFrame: age, fps: fps, active: active, now: now) != nil { requests.append(now) }
        }
        return (requests, probes)
    }

    @Test func thresholdIsNeverShorterThanSeveralFrames() {
        #expect(FreezeDetector.threshold(fps: 60) == 0.15)
        #expect(FreezeDetector.threshold(fps: 120) == 0.15)
        #expect(abs(FreezeDetector.threshold(fps: 30) - 5.0 / 30) < 1e-9)
        // No frame rate known yet: the 30 fps threshold.
        #expect(FreezeDetector.threshold(fps: 0) == FreezeDetector.threshold(fps: 30))
    }

    @Test func aHealthyStreamNeedsNoStats() {
        var d = FreezeDetector()
        let r = run(&d, ticks: 100) { _ in 0.016 }
        #expect(r.requests.isEmpty)
        #expect(r.probes == 0)
    }

    @Test func aStallWithDataArrivingAsksForAKeyframeWellWithinASecond() throws {
        var d = FreezeDetector()
        // The last frame came just before tick 0 and none after it.
        let r = run(&d, ticks: 10) { Double($0) * 0.1 + 0.01 }
        let first = try #require(r.requests.first)
        #expect(first <= 0.31)
        #expect(r.requests.count == 1)
    }

    @Test func reportsTheStallLength() {
        var d = FreezeDetector()
        let r1 = d.suspects(sinceLastFrame: 0.1, fps: 60, active: true, now: 10)
        #expect(r1)
        let r2 = d.observe(.init(bytes: 1000, framesDecoded: 7), sinceLastFrame: 0.1, fps: 60, active: true, now: 10)
        #expect(r2 == nil)
        let r3 = d.observe(.init(bytes: 31_000, framesDecoded: 7), sinceLastFrame: 0.2, fps: 60, active: true, now: 10.1)
        #expect(r3 == 0.2)
    }

    @Test func noRequestBeforeTheFirstFrame() {
        var d = FreezeDetector()
        let r = run(&d, ticks: 50) { _ in nil }
        #expect(r.requests.isEmpty)
        #expect(r.probes == 0)
    }

    @Test func noRequestWhileInactive() {
        var d = FreezeDetector()
        #expect(run(&d, ticks: 50, active: false) { Double($0) * 0.1 }.probes == 0)
        // Went inactive between asking for the stats and getting them.
        let r4 = d.suspects(sinceLastFrame: 0.3, fps: 60, active: true, now: 100)
        #expect(r4)
        _ = d.observe(.init(bytes: 0, framesDecoded: 1), sinceLastFrame: 0.3, fps: 60, active: true, now: 100)
        let r5 = d.observe(.init(bytes: 90_000, framesDecoded: 1), sinceLastFrame: 0.4, fps: 60, active: false, now: 100.1)
        #expect(r5 == nil)
    }

    @Test func noRequestWhenNothingArrives() {
        // A sender with nothing to send, or a dead link: a keyframe request can't help, and the stream isn't broken.
        var d = FreezeDetector()
        #expect(run(&d, ticks: 50, bytesPerTick: 0) { Double($0) * 0.1 }.requests.isEmpty)
        var e = FreezeDetector()
        #expect(run(&e, ticks: 3, bytesPerTick: 300) { Double($0) * 0.1 }.requests.isEmpty)
    }

    @Test func aTrickleOfDataAddsUpOverTheStall() {
        var d = FreezeDetector()
        // 1.5 kB per tick passes 5 kB a few ticks after the first look.
        let r = run(&d, ticks: 20, bytesPerTick: 1_500) { Double($0) * 0.1 }
        #expect(r.requests.count >= 1)
        #expect((r.requests.first ?? 0) > 0.3)
    }

    @Test func noRequestWhileTheDecoderStillProducesFrames() {
        // Frames are decoded but none reaches the renderer: not a lost reference.
        var d = FreezeDetector()
        #expect(run(&d, ticks: 50, decodedPerTick: 6) { Double($0) * 0.1 }.requests.isEmpty)
    }

    @Test func aThirtyFPSStreamIsNotMisreadAtAGapThatIsNormalForIt() {
        var d = FreezeDetector()
        // 160 ms without a frame is past the 60 fps threshold but under five 30 fps frames.
        #expect(run(&d, ticks: 50, fps: 30) { _ in 0.16 }.requests.isEmpty)
        var e = FreezeDetector()
        #expect(!run(&e, ticks: 50, fps: 60) { _ in 0.16 }.requests.isEmpty)
    }

    @Test func aStreamThatSendsNothingIsLookedAtLessOften() {
        // A static screen the sender skips: no frames and no bytes, for a long time.
        var d = FreezeDetector()
        var looks = 0
        for i in 0..<300 {   // 30 s of ticks
            let now = 100 + Double(i) * FreezeDetector.tick
            guard d.suspects(sinceLastFrame: 1 + Double(i) * FreezeDetector.tick, fps: 60, active: true, now: now) else { continue }
            looks += 1
            let r = d.observe(.init(bytes: 1000, framesDecoded: 7), sinceLastFrame: 1, fps: 60, active: true, now: now)
            #expect(r == nil)
        }
        // The first second in full, then a tenth of the ticks.
        #expect(looks < 50)
        // Frames flow again, then really freeze with data arriving: found at the usual speed.
        let flowing = d.suspects(sinceLastFrame: 0.01, fps: 60, active: true, now: 200)
        let late = d.suspects(sinceLastFrame: 0.1, fps: 60, active: true, now: 200.1)
        let first = d.observe(.init(bytes: 2000, framesDecoded: 9), sinceLastFrame: 0.1, fps: 60, active: true, now: 200.1)
        let stillLate = d.suspects(sinceLastFrame: 0.2, fps: 60, active: true, now: 200.2)
        let second = d.observe(.init(bytes: 40_000, framesDecoded: 9), sinceLastFrame: 0.2, fps: 60, active: true, now: 200.2)
        #expect(!flowing && late && stillLate)
        #expect(first == nil)
        #expect(second != nil)
    }

    @Test func atMostOneRequestASecond() {
        var d = FreezeDetector()
        // Frozen for five seconds with data arriving throughout.
        let r = run(&d, ticks: 50) { Double($0) * 0.1 }
        #expect(r.requests.count >= 3)
        #expect(r.requests.count <= 5)
        for (a, b) in zip(r.requests, r.requests.dropFirst()) { #expect(b - a >= FreezeDetector.minRequestInterval - 1e-9) }
    }

    @Test func aFrameArrivingBeforeTheStatsCancelsTheRequest() {
        var d = FreezeDetector()
        let r6 = d.suspects(sinceLastFrame: 0.2, fps: 60, active: true, now: 1)
        #expect(r6)
        _ = d.observe(.init(bytes: 0, framesDecoded: 5), sinceLastFrame: 0.2, fps: 60, active: true, now: 1)
        let r7 = d.suspects(sinceLastFrame: 0.3, fps: 60, active: true, now: 1.1)
        #expect(r7)
        let r8 = d.observe(.init(bytes: 50_000, framesDecoded: 5), sinceLastFrame: 0.004, fps: 60, active: true, now: 1.1)
        #expect(r8 == nil)
    }

    @Test func nominalFrameRateIgnoresASecondWithAStallInIt() {
        var fps = 0.0
        for sample in [60.0, 59, 60, 12, 60] { fps = StreamPace.nominalFPS(sample: sample, previous: fps) }
        #expect(fps == 60)
        fps = StreamPace.nominalFPS(sample: 12, previous: 60)
        #expect(fps == 54)
        fps = StreamPace.nominalFPS(sample: 0, previous: fps)
        #expect(fps == 54)
        // A stream that really dropped to 30 fps is followed.
        for _ in 0..<10 { fps = StreamPace.nominalFPS(sample: 30, previous: fps) }
        #expect(fps == 30)
    }
}

struct SharpenGovernorTests {
    private typealias Sample = CompressionPressure.Sample

    @Test func pressureFromTheQuantiser() throws {
        #expect(try #require(CompressionPressure.estimate(Sample(avgQp: 24, fps: 60))).pressure == 0)
        #expect(try #require(CompressionPressure.estimate(Sample(avgQp: 35, fps: 60))).pressure == 0.5)
        #expect(try #require(CompressionPressure.estimate(Sample(avgQp: 46, fps: 60))).pressure == 1)
        // VP9 and AV1 report a 0…255 index: 46 is a clean picture there.
        #expect(try #require(CompressionPressure.estimate(Sample(avgQp: 46, codec: "VP9", fps: 60))).pressure == 0)
        #expect(try #require(CompressionPressure.estimate(Sample(avgQp: 220, codec: "AV1", fps: 60))).pressure == 1)
    }

    @Test func withoutAQuantiserTheSharpeningIsLeftAlone() {
        // A decoder that reports none: nothing to go by, and the bitrate is not a stand-in (a still menu has
        // hardly any bits and a clean picture).
        #expect(CompressionPressure.estimate(Sample(fps: 60)) == nil)
        var g = SharpenGovernor()
        for _ in 0..<60 { g.update(Sample(fps: 60)) }
        #expect(g.sharpenScale == 1)
        #expect(g.debandBoost == 1)
    }

    @Test func aStalledSampleSaysNothing() {
        #expect(CompressionPressure.estimate(Sample(avgQp: 45, fps: 2)) == nil)
        var g = SharpenGovernor()
        for _ in 0..<30 { g.update(Sample(avgQp: 45, fps: 60)) }
        let before = g.sharpenScale
        g.update(Sample(avgQp: nil, fps: 0))
        #expect(g.sharpenScale == before)
    }

    @Test func aHealthyStreamKeepsFullSharpening() {
        var g = SharpenGovernor()
        for qp in [22.0, 26, 29, 24, 30, 27] { g.update(Sample(avgQp: qp, fps: 60)) }
        #expect(g.sharpenScale == 1)
        #expect(g.debandBoost == 1)
    }

    @Test func aStarvedStreamIsSharpenedLessButNotNotAtAllAndDebandedMore() {
        var g = SharpenGovernor()
        for _ in 0..<5 { g.update(Sample(avgQp: 25, fps: 60)) }
        for _ in 0..<60 { g.update(Sample(avgQp: 48, fps: 60)) }
        #expect(abs(g.sharpenScale - Float(SharpenGovernor.minSharpenScale)) < 1e-6)
        #expect(g.sharpenScale > 0)
        #expect(g.debandBoost == 2)
        // And everything comes back when the stream recovers.
        for _ in 0..<60 { g.update(Sample(avgQp: 25, fps: 60)) }
        #expect(g.sharpenScale == 1)
        #expect(g.debandBoost == 1)
    }

    @Test func oneBadSecondDoesNotMoveThePicture() {
        var g = SharpenGovernor()
        for _ in 0..<10 { g.update(Sample(avgQp: 26, fps: 60)) }
        g.update(Sample(avgQp: 33, fps: 60))   // pressure 0.3 for one sample
        #expect(g.sharpenScale == 1)
    }

    @Test func aStreamHoveringAroundOneLevelDoesNotPump() {
        var g = SharpenGovernor()
        for _ in 0..<40 { g.update(Sample(avgQp: 35, fps: 60)) }
        let settled = g.sharpenScale
        #expect(settled < 1)
        var changes = 0, last = settled
        for i in 0..<120 {
            g.update(Sample(avgQp: i % 2 == 0 ? 34 : 36, fps: 60))
            if g.sharpenScale != last { changes += 1; last = g.sharpenScale }
        }
        #expect(changes == 0)
    }

    @Test func multipliersStayInTheRenderersRange() {
        var g = SharpenGovernor()
        for qp in stride(from: 0.0, through: 60, by: 1.5) {
            for _ in 0..<8 { g.update(Sample(avgQp: qp, fps: 60)) }
            #expect((Float(SharpenGovernor.minSharpenScale) - 1e-6...1).contains(g.sharpenScale))
            #expect((1...2).contains(g.debandBoost))
        }
    }
}

struct UpscalerGovernorTests {
    /// Feeds `seconds` one-second samples and returns the last ceiling and every change line.
    @discardableResult
    private func feed(_ g: inout UpscalerGovernor, seconds: Int, thermal: ProcessInfo.ThermalState = .nominal, gpuMs: Double?, fps: Double = 60,
                      setting: Upscaler = .videoToolbox) -> (cap: Upscaler, changes: [String]) {
        var cap = Upscaler.videoToolbox, changes: [String] = []
        for _ in 0..<seconds {
            let d = g.update(thermal: thermal, gpuMs: gpuMs, fps: fps, setting: setting)
            cap = d.cap
            if let c = d.change { changes.append(c) }
        }
        return (cap, changes)
    }

    @Test func aCoolDeviceWithALightLoadIsLeftAlone() {
        var g = UpscalerGovernor()
        let r = feed(&g, seconds: 600, gpuMs: 4)
        #expect(r.cap == .videoToolbox)
        #expect(r.changes.isEmpty)
        #expect(g.status == nil)
    }

    @Test func heatLowersTheCeilingAtOnceAndCoolingRestoresIt() {
        var g = UpscalerGovernor()
        #expect(feed(&g, seconds: 1, thermal: .fair, gpuMs: 4).cap == .videoToolbox)
        let hot = feed(&g, seconds: 1, thermal: .serious, gpuMs: 4)
        #expect(hot.cap == .metalFX)
        #expect(hot.changes.count == 1)
        #expect(g.status?.contains("hot") == true)
        #expect(feed(&g, seconds: 1, thermal: .critical, gpuMs: 4).cap == .off)
        let cooled = feed(&g, seconds: 1, thermal: .nominal, gpuMs: 4)
        #expect(cooled.cap == .videoToolbox)
        #expect(g.status == nil)
    }

    @Test func sustainedGPULoadCostsAStepAndAShortSpikeDoesNot() {
        var g = UpscalerGovernor()
        // 60 fps: 16.7 ms a frame, 60 % is 10 ms.
        #expect(feed(&g, seconds: UpscalerGovernor.lowerAfter - 1, gpuMs: 12).cap == .videoToolbox)
        #expect(feed(&g, seconds: 1, gpuMs: 6).cap == .videoToolbox)
        #expect(feed(&g, seconds: UpscalerGovernor.lowerAfter - 1, gpuMs: 12).cap == .videoToolbox)
        let r = feed(&g, seconds: 1, gpuMs: 12)
        #expect(r.cap == .metalFX)
        #expect(r.changes.first?.contains("GPU 12.0 ms") == true)
        #expect(g.status?.contains("GPU load") == true)
        // Still too much with MetalFX alone: off.
        #expect(feed(&g, seconds: UpscalerGovernor.lowerAfter, gpuMs: 12).cap == .off)
        // Nothing lower to go to.
        #expect(feed(&g, seconds: 60, gpuMs: 12).changes.isEmpty)
    }

    @Test func theBudgetFollowsTheStreamFrameRate() {
        var g = UpscalerGovernor()
        // 12 ms is 36 % of a 30 fps frame.
        #expect(feed(&g, seconds: 60, gpuMs: 12, fps: 30).cap == .videoToolbox)
        var h = UpscalerGovernor()
        // 6 ms is 72 % of a 120 fps frame.
        #expect(feed(&h, seconds: UpscalerGovernor.lowerAfter, gpuMs: 6, fps: 120).cap == .metalFX)
    }

    @Test func aStepStartsFromTheUpscalerThatIsRunning() {
        var g = UpscalerGovernor()
        // The user runs MetalFX: one step down turns it off, not "down to MetalFX".
        #expect(feed(&g, seconds: UpscalerGovernor.lowerAfter, gpuMs: 12, setting: .metalFX).cap == .off)
        var h = UpscalerGovernor()
        #expect(feed(&h, seconds: 120, gpuMs: 12, setting: .off).changes.isEmpty)
        #expect(h.status == nil)
    }

    @Test func aStepComesBackOnlyAfterAClearlyLongerHealthyPeriod() {
        var g = UpscalerGovernor()
        feed(&g, seconds: UpscalerGovernor.lowerAfter, gpuMs: 12)
        #expect(feed(&g, seconds: UpscalerGovernor.raiseAfterBase - 1, gpuMs: 5).cap == .metalFX)
        #expect(feed(&g, seconds: 1, gpuMs: 5).cap == .videoToolbox)
        #expect(UpscalerGovernor.raiseAfterBase >= UpscalerGovernor.lowerAfter * 4)
    }

    @Test func theBandBetweenTheLimitsNeitherLowersNorRaises() {
        var g = UpscalerGovernor()
        feed(&g, seconds: UpscalerGovernor.lowerAfter, gpuMs: 12)
        // 9 ms is 54 % of a frame: under the limit to lower, over the one to raise.
        let r = feed(&g, seconds: 600, gpuMs: 9)
        #expect(r.cap == .metalFX)
        #expect(r.changes.isEmpty)
    }

    @Test func aDeviceThatCannotHoldTheHigherStepIsTriedLessAndLessOften() {
        var g = UpscalerGovernor()
        var raises: [Int] = [], t = 0, cap = Upscaler.videoToolbox
        // The GPU is fine with MetalFX (5 ms) and overloaded with VideoToolbox ML (12 ms).
        for _ in 0..<1200 {
            t += 1
            let d = g.update(thermal: .nominal, gpuMs: cap == .videoToolbox ? 12 : 5, fps: 60, setting: .videoToolbox)
            if d.cap == .videoToolbox, cap != .videoToolbox { raises.append(t) }
            cap = d.cap
        }
        #expect(raises.count >= 3)
        let gaps = zip(raises, raises.dropFirst()).map { $1 - $0 }
        #expect(gaps == gaps.sorted())
        #expect((gaps.last ?? 0) > (gaps.first ?? 0))
    }

    @Test func noGPUReadingMeansNoLoadDecision() {
        var g = UpscalerGovernor()
        #expect(feed(&g, seconds: 120, gpuMs: nil).changes.isEmpty)
        #expect(feed(&g, seconds: 120, gpuMs: 12, fps: 0).changes.isEmpty)
        // Heat still counts.
        #expect(feed(&g, seconds: 1, thermal: .critical, gpuMs: nil).cap == .off)
    }

    @Test func heatDoesNotCountAsAHealthyPeriod() {
        var g = UpscalerGovernor()
        feed(&g, seconds: UpscalerGovernor.lowerAfter, gpuMs: 12)
        // Hot with a light load for a long time: the load ceiling is not raised meanwhile.
        #expect(feed(&g, seconds: 300, thermal: .serious, gpuMs: 5).cap == .metalFX)
        #expect(feed(&g, seconds: 1, thermal: .nominal, gpuMs: 5).cap == .metalFX)
        #expect(feed(&g, seconds: UpscalerGovernor.raiseAfterBase, thermal: .nominal, gpuMs: 5).cap == .videoToolbox)
    }
}

struct QualityTierTests {
    @Test func storedNamesOfTheTiersDoNotChange() {
        #expect(StreamQuality.allCases.map(\.rawValue) == ["p720", "p720HQ", "p1080", "p1080HQ", "p1440"])
    }

    @Test func aliasesAreTheOnesTheControlChannelDocuments() {
        #expect(StreamQuality.allCases.map(\.resolutionAlias) == ["720", "720HQ", "1080", "1080HQ", "1440"])
    }

    @Test func the720pHQTier() {
        let q = StreamQuality.p720HQ
        #expect(q.label == "720p HQ")
        #expect(q.height == 720)
        #expect(q.osName == StreamQuality.p720.osName)
        #expect(StreamQuality.allCases.map(\.height) == [720, 720, 1080, 1080, 1440])
    }
}
