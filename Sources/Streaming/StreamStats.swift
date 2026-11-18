import Foundation
import WebRTC

struct StreamStats {
    var fps: Double = 0
    var resolution = "-"
    var bitrateMbps: Double = 0
    var rttMs: Double?
    var packetsLost: Int = 0
    var jitterMs: Double = 0
    var decodeMs: Double?
    var codec = "-"
    var path = "-"           // e.g. "host 192.168.1.20:9002 (udp)"
    var upscale = "-"
    var serverSize: String?
    /// Decoded size in pixels, 0 until known.
    var width = 0, height = 0
    /// Average quantiser of the frames decoded in this sample; nil when the decoder reports none.
    var avgQp: Double?
    /// "sharpening at 64% (QP 38)" while adaptive sharpening holds it below the setting.
    var sharpenNote: String?
    /// What "Protect frame rate" is holding back, when it is.
    var frameRateNote: String?
    /// Freezes libwebrtc counted since the stream began (a frame that came much later than the ones before it),
    /// and the time spent in them.
    var freezeCount = 0
    var freezeSeconds: Double = 0
    /// Of those, what this sample added.
    var newFreezes = 0
    var newFreezeSeconds: Double = 0
    /// Seconds since a sample last saw a new freeze.
    var sinceFreeze: Double?

    var freezeIsRecent: Bool { sinceFreeze.map { $0 < 10 } ?? false }
    var freezeLine: String {
        var l = String(format: "freezes: %d (%.2f s frozen)", freezeCount, freezeSeconds)
        if newFreezes > 0 { l += String(format: "  +%d now (%.2f s)", newFreezes, newFreezeSeconds) }
        else if let t = sinceFreeze { l += String(format: "  last %.0f s ago", t) }
        return l
    }
}

/// Turns RTCStatisticsReport snapshots into overlay numbers (Greenlight stats.ts).
final class StatsSampler {
    private var lastBytes: Double = 0
    private var lastTime: Double = 0
    private var lastDecodeTime: Double = 0
    private var lastFramesDecoded: Double = 0
    private var lastQpSum: Double?
    private var sampleCount = 0
    private var lastFreeze = FreezeCounters()
    private var lastFreezeTime: Double?

    func sample(_ report: RTCStatisticsReport) -> StreamStats {
        var s = StreamStats()
        let all = report.statistics
        func num(_ v: NSObject?) -> Double? { (v as? NSNumber)?.doubleValue }
        for (_, st) in all where st.type == "inbound-rtp" && (st.values["kind"] as? String) == "video" {
            let v = st.values
            sampleCount += 1
            if sampleCount % 5 == 1 {
                let keys = ["framesReceived", "framesDecoded", "keyFramesDecoded", "framesDropped", "frameWidth", "frameHeight", "decoderImplementation", "powerEfficientDecoder", "pliCount", "firCount", "nackCount", "framesPerSecond", "trackIdentifier"]
                log("Stats", "inbound video: " + keys.map { "\($0)=\(v[$0].map { "\($0)" } ?? "-")" }.joined(separator: " "))
            }
            s.fps = num(v["framesPerSecond"]) ?? 0
            if let w = num(v["frameWidth"]), let h = num(v["frameHeight"]) { s.resolution = "\(Int(w))x\(Int(h))"; s.width = Int(w); s.height = Int(h) }
            s.packetsLost = Int(num(v["packetsLost"]) ?? 0)
            s.jitterMs = (num(v["jitter"]) ?? 0) * 1000
            let bytes = num(v["bytesReceived"]) ?? 0
            let t = st.timestamp_us / 1_000_000
            if lastTime > 0, t > lastTime { s.bitrateMbps = (bytes - lastBytes) * 8 / (t - lastTime) / 1_000_000 }
            lastBytes = bytes; lastTime = t
            let dt = num(v["totalDecodeTime"]) ?? 0, fd = num(v["framesDecoded"]) ?? 0
            if fd > lastFramesDecoded { s.decodeMs = (dt - lastDecodeTime) / (fd - lastFramesDecoded) * 1000 }
            // As StatsExtractor's avgQp. Not every decoder reports qpSum.
            let qp = num(v["qpSum"])
            if let qp, let last = lastQpSum, fd > lastFramesDecoded, qp > last { s.avgQp = (qp - last) / (fd - lastFramesDecoded) }
            lastQpSum = qp
            lastDecodeTime = dt; lastFramesDecoded = fd
            let now = FreezeCounters(freezes: num(v["freezeCount"]) ?? 0, seconds: num(v["totalFreezesDuration"]) ?? 0, pauses: num(v["pauseCount"]) ?? 0,
                                     nack: num(v["nackCount"]) ?? 0, pli: num(v["pliCount"]) ?? 0, dropped: num(v["framesDropped"]) ?? 0,
                                     lost: num(v["packetsLost"]) ?? 0)
            s.freezeCount = Int(now.freezes); s.freezeSeconds = now.seconds
            if let line = now.report(since: lastFreeze, resolution: s.resolution, fps: s.fps) {
                s.newFreezes = Int(now.freezes - lastFreeze.freezes); s.newFreezeSeconds = now.seconds - lastFreeze.seconds
                lastFreezeTime = t
                // Nobody sees a freeze counter move: the log has to say when each one happened and what came with it.
                log("Stream", line)
                DiagnosticsRecorder.current?.event("freeze", ["count": s.freezeCount, "seconds": s.newFreezeSeconds, "totalSeconds": now.seconds,
                                                              "nack": now.nack - lastFreeze.nack, "pli": now.pli - lastFreeze.pli, "resolution": s.resolution])
            }
            lastFreeze = now
            s.sinceFreeze = lastFreezeTime.map { t - $0 }
            if let cid = v["codecId"] as? String, let c = all[cid] { s.codec = (c.values["mimeType"] as? String ?? "-").replacingOccurrences(of: "video/", with: "") }
        }
        for (_, st) in all where st.type == "candidate-pair" {
            let v = st.values
            guard (v["state"] as? String) == "succeeded", (v["nominated"] as? NSNumber)?.boolValue == true else { continue }
            if let rtt = num(v["currentRoundTripTime"]) { s.rttMs = rtt * 1000 }
            if let rid = v["remoteCandidateId"] as? String, let r = all[rid]?.values {
                let type = r["candidateType"] as? String ?? "?"
                let addr = r["address"] as? String ?? r["ip"] as? String ?? "?"
                let port = (r["port"] as? NSNumber)?.intValue ?? 0
                s.path = "\(type) \(addr):\(port) (\(r["protocol"] as? String ?? "udp"))"
            }
        }
        return s
    }
}

/// The inbound-rtp counters that describe a freeze, as of one stats sample.
struct FreezeCounters: Equatable {
    var freezes = 0.0, seconds = 0.0, pauses = 0.0, nack = 0.0, pli = 0.0, dropped = 0.0, lost = 0.0

    /// The log line for the freezes counted since `last`, nil when there were none. NACK and PLI say whether
    /// packets went missing (retransmission, then a keyframe request); none of either points at the sender or
    /// the decoder.
    func report(since last: FreezeCounters, resolution: String, fps: Double) -> String? {
        guard freezes > last.freezes else { return nil }
        return String(format: "freeze #%d: %.2f s (%d new, %.2f s frozen in total); since the last sample NACK +%d, PLI +%d, frames dropped +%d, packets lost +%d, pauses %d; decoding %@ at %.0f fps",
                      Int(freezes), seconds - last.seconds, Int(freezes - last.freezes), seconds,
                      Int(nack - last.nack), Int(pli - last.pli), Int(dropped - last.dropped), Int(lost - last.lost), Int(pauses), resolution, fps)
    }
}
