import Foundation

// The decisions `StreamSession` takes from its stats while a stream runs: when a stalled picture needs a keyframe,
// how far to back the sharpening off on a starved stream, and how much upscaling the device can afford. Each is a
// value type fed plain numbers, so the rules can be tested without a stream.

/// The stream's frame rate as these rules use it: the highest rate seen recently. A second with a stall in it
/// reports a handful of frames, and that must not stretch a threshold counted in frame intervals.
enum StreamPace {
    static func nominalFPS(sample: Double, previous: Double) -> Double {
        guard sample > 0 else { return previous }
        // A stream that really went from 60 to 30 fps is followed within a few seconds.
        return max(sample, previous * 0.9)
    }
}

// MARK: - Freeze recovery

/// Decides when a picture that stopped moving needs a keyframe: no frame has reached the renderer for a few frame
/// intervals while video bytes keep arriving and the decoder turns none of them into frames (it lost its
/// reference). The session asks it every `tick`; it only wants stats (`suspects`) once the picture is late, so
/// getStats runs a few times around a stall and not at all otherwise.
struct FreezeDetector {
    /// The two inbound-rtp video counters the decision needs.
    struct Probe: Equatable {
        var bytes: Double
        var framesDecoded: Double
    }

    /// How often the session checks, seconds.
    static let tick = 0.1
    /// No frame for this long is a stall…
    static let minStall = 0.15
    /// …but never less than this many frame intervals: at 30 fps that is 167 ms.
    static let frameIntervals = 5.0
    /// Used until the stats have reported a frame rate; the slower rate gives the longer, safer threshold.
    static let fallbackFPS = 30.0
    /// Video payload that must arrive during the stall. A sender with nothing to send (a static screen with frame
    /// skipping) stays far below this; one packet of a real frame is about 1200 bytes.
    static let minBytes = 5_000.0
    /// The console answers a request within about a second; asking again sooner only costs bitrate.
    static let minRequestInterval = 1.0

    static func threshold(fps: Double) -> Double { max(minStall, frameIntervals / (fps > 0 ? fps : fallbackFPS)) }

    /// Counters when the picture first looked late; cleared whenever frames flow again.
    private var baseline: Probe?
    private var lastRequest = -Double.infinity
    /// Looks at the stats since the picture went late that asked for nothing. A stream that simply isn't sending
    /// frames (a paused or skipped static screen) would otherwise have its stats fetched every tick for as long
    /// as that lasts; after `patience` of them only every `patience`th tick looks again.
    private var idleLooks = 0, skipped = 0
    static let patience = 10

    /// True when the picture is late enough (half the threshold) that the caller should fetch stats and call
    /// `observe`. `sinceLastFrame` is nil before the first frame; `active` is false when the stream isn't up or
    /// the app isn't in front.
    mutating func suspects(sinceLastFrame: Double?, fps: Double, active: Bool, now: Double) -> Bool {
        guard active, let gap = sinceLastFrame, gap >= Self.threshold(fps: fps) / 2 else {
            baseline = nil; idleLooks = 0; skipped = 0
            return false
        }
        guard now - lastRequest >= Self.minRequestInterval else { baseline = nil; return false }
        if idleLooks >= Self.patience {
            skipped += 1
            if skipped % Self.patience != 0 { return false }
        }
        return true
    }

    /// The stall length in seconds when a keyframe should be requested now, else nil. `sinceLastFrame` and
    /// `active` are read again after the stats came back: a frame may have arrived meanwhile.
    mutating func observe(_ probe: Probe, sinceLastFrame: Double?, fps: Double, active: Bool, now: Double) -> Double? {
        guard active, let gap = sinceLastFrame else { baseline = nil; return nil }
        // The first look, or the decoder produced a frame since: count the bytes from here.
        guard let base = baseline, probe.framesDecoded == base.framesDecoded, probe.bytes >= base.bytes else { baseline = probe; return nil }
        guard gap >= Self.threshold(fps: fps), probe.bytes - base.bytes >= Self.minBytes, now - lastRequest >= Self.minRequestInterval else {
            idleLooks += 1
            return nil
        }
        lastRequest = now
        baseline = nil; idleLooks = 0; skipped = 0
        return gap
    }
}

// MARK: - Sharpening on a starved stream

/// How hard the encoder is squeezing the picture, 0 (healthy) … 1 (starved), from one stats sample.
enum CompressionPressure {
    struct Sample {
        /// Average quantiser of the frames decoded in the sample (`qpSum` over `framesDecoded`), when the decoder reports one.
        var avgQp: Double?
        /// As in the stats overlay: "H264", "H265", "VP9", "AV1".
        var codec = "H264"
        var fps = 0.0
    }

    enum Source: Equatable {
        case qp(Double)

        var label: String {
            switch self { case .qp(let q): String(format: "QP %.0f", q) }
        }
    }

    /// Below this the sample is a stall or a paused stream, not a measure of the encoder.
    static let minFPS = 10.0

    /// Quantiser range from "looks clean" to "visibly blocky". H.264 and HEVC count 0…51; VP9 and AV1 report
    /// their 0…255 index.
    static func qpRange(codec: String) -> (healthy: Double, starved: Double) {
        let c = codec.uppercased()
        return c.contains("VP") || c.contains("AV1") ? (130, 200) : (30, 40)
    }

    /// nil when the sample says nothing about the encoder: no frames, or a decoder that reports no quantiser.
    /// The bitrate is deliberately not used in its place: a still menu or a slow scene needs few bits and looks
    /// clean, and the bitrate can't tell that from a starved stream, so it would soften the picture when it is at
    /// its best. Without a quantiser the sharpening stays as it is set.
    static func estimate(_ s: Sample) -> (pressure: Double, source: Source)? {
        guard s.fps >= minFPS, let qp = s.avgQp, qp > 0 else { return nil }
        let r = qpRange(codec: s.codec)
        return (min(max((qp - r.healthy) / (r.starved - r.healthy), 0), 1), .qp(qp))
    }
}

/// Turns the pressure into the renderer's two multipliers. Sharpening a starved stream sharpens its blocks and
/// ringing, so it is backed off (never to nothing) while the debanding, which hides the coarser steps, is raised.
struct SharpenGovernor {
    /// Weight of a new sample: with one a second the estimate follows a change in about four seconds.
    static let smoothing = 0.25
    /// The multipliers only move once the estimate has left the value they were set from by this much, so a
    /// stream hovering around one level doesn't make the picture pump.
    static let deadband = 0.1
    /// Sharpening that is left on a fully starved stream.
    static let minSharpenScale = 0.4

    private var smoothed: Double?
    /// The pressure the multipliers are set from.
    private(set) var applied = 0.0
    private(set) var source: CompressionPressure.Source?

    var sharpenScale: Float { Float(1 - (1 - Self.minSharpenScale) * applied) }
    /// Up to the renderer's limit of 2.
    var debandBoost: Float { Float(1 + applied) }

    mutating func update(_ sample: CompressionPressure.Sample) {
        // A sample that says nothing (a stall) leaves everything as it was.
        guard let e = CompressionPressure.estimate(sample) else { return }
        source = e.source
        let s = smoothed.map { $0 + (e.pressure - $0) * Self.smoothing } ?? e.pressure
        smoothed = s
        // The ends are reached exactly: a healthy stream gets all of its sharpening back.
        if s < 0.03 { applied = 0 } else if s > 0.97 { applied = 1 } else if abs(s - applied) >= Self.deadband { applied = s }
    }
}

// MARK: - Upscaling the device can afford

/// Lowers the ceiling on the upscaler when the device is hot or the GPU needs too much of each frame, and raises
/// it again once things have been well for clearly longer. Fed once a second.
struct UpscalerGovernor {
    /// GPU time above this share of a stream frame, for `lowerAfter` samples in a row, costs one step.
    static let overBudget = 0.6
    /// GPU time must stay below this share before a step is given back: the next step up costs more than this one.
    static let healthyBudget = 0.45
    static let lowerAfter = 5
    /// Healthy samples before a step up. Doubles (to `raiseAfterMax`) each time a step up had to be taken back
    /// within `relapseWindow`, so a device that can't hold the higher step isn't pushed onto it every half minute.
    static let raiseAfterBase = 30, raiseAfterMax = 480, relapseWindow = 60

    /// The ceiling from GPU load alone.
    private(set) var loadCap: Upscaler = .videoToolbox
    /// Why the ceiling is where it is, for the stats overlay; nil when nothing is held back.
    private(set) var status: String?
    private var cap: Upscaler = .videoToolbox
    private var over = 0, healthy = 0
    private var raiseAfter = UpscalerGovernor.raiseAfterBase
    private var sinceRaise: Int?

    static func thermalCeiling(_ state: ProcessInfo.ThermalState) -> Upscaler {
        switch state {
        case .critical: .off
        case .serious: .metalFX
        default: .videoToolbox
        }
    }

    /// The ceiling for the renderer's `maxUpscaler`, and a line for the log when it changed. `setting` is the
    /// upscaler the user chose; `gpuMs` the renderer's recent GPU time per frame, nil when it has none yet.
    /// While the VideoToolbox ML scaler runs, pass the pass's whole time instead: its work is not in the GPU time.
    mutating func update(thermal: ProcessInfo.ThermalState, gpuMs: Double?, fps: Double, setting: Upscaler) -> (cap: Upscaler, change: String?) {
        let thermalCap = Self.thermalCeiling(thermal)
        var why: String?
        if let n = sinceRaise { sinceRaise = n + 1 }
        if let gpuMs, fps > 0 {
            let budget = 1000 / fps, running = setting.capped(by: loadCap).capped(by: thermalCap)
            if gpuMs > budget * Self.overBudget {
                healthy = 0
                over += 1
                if over >= Self.lowerAfter, let lower = running.lowered {
                    over = 0
                    if let n = sinceRaise, n <= Self.relapseWindow { raiseAfter = min(raiseAfter * 2, Self.raiseAfterMax) }
                    sinceRaise = nil
                    loadCap = lower
                    why = String(format: "GPU %.1f ms of a %.1f ms frame", gpuMs, budget)
                }
            } else {
                over = 0
                // Not while the device is hot (the load is lower only because the heat already took a step), and
                // not in the band between the two limits.
                healthy = gpuMs < budget * Self.healthyBudget && thermalCap == .videoToolbox ? healthy + 1 : 0
                // Only a ceiling that holds the chosen upscaler back is worth raising.
                if healthy >= raiseAfter, setting.capped(by: loadCap) != setting, let higher = loadCap.raised {
                    healthy = 0
                    sinceRaise = 0
                    loadCap = higher
                    why = String(format: "GPU %.1f ms of a %.1f ms frame for %d s", gpuMs, budget, raiseAfter)
                }
            }
        }
        let new = loadCap.capped(by: thermalCap)
        defer { cap = new }
        // What the user would notice: only a ceiling below the upscaler they chose holds anything back.
        if setting.capped(by: new) == setting {
            status = nil
        } else {
            status = "upscaler held at \(new.label) (" + (thermalCap == new && thermalCap != .videoToolbox ? "device is \(Self.name(thermal))" : "GPU load") + ")"
        }
        guard new != cap else { return (new, nil) }
        return (new, "upscaler ceiling \(cap.rawValue) → \(new.rawValue): " + (why ?? "device is \(Self.name(thermal))"))
    }

    static func name(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "cool"
        case .fair: "warm"
        case .serious: "hot"
        case .critical: "very hot"
        @unknown default: "in an unknown thermal state"
        }
    }
}

private extension Upscaler {
    var lowered: Upscaler? { switch self { case .videoToolbox: .metalFX; case .metalFX: .off; case .off: nil } }
    var raised: Upscaler? { switch self { case .off: .metalFX; case .metalFX: .videoToolbox; case .videoToolbox: nil } }
}
