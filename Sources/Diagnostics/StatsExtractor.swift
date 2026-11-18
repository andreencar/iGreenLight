import Foundation

struct StatsState {
    var samples = 0
    var last: [String: Double] = [:]
    var lastTime: Double = 0
}

/// Pulls the interesting fields out of a raw getStats dump and computes per-second deltas.
enum StatsExtractor {
    static let videoKeys = ["frameWidth", "frameHeight", "framesPerSecond", "framesReceived", "framesDecoded", "keyFramesDecoded",
                            "framesDropped", "freezeCount", "totalFreezesDuration", "pauseCount", "totalPausesDuration",
                            "jitter", "packetsReceived", "packetsLost", "bytesReceived", "headerBytesReceived", "nackCount", "pliCount", "firCount",
                            "qpSum", "totalDecodeTime", "totalProcessingDelay", "totalAssemblyTime", "jitterBufferDelay", "jitterBufferTargetDelay",
                            "jitterBufferMinimumDelay", "jitterBufferEmittedCount", "totalInterFrameDelay", "totalSquaredInterFrameDelay",
                            "decoderImplementation", "powerEfficientDecoder", "fecPacketsReceived", "fecPacketsDiscarded",
                            "retransmittedPacketsReceived", "retransmittedBytesReceived", "framesAssembledFromMultiplePackets",
                            "ssrc", "mid", "codecId", "transportId", "lastPacketReceivedTimestamp", "estimatedPlayoutTimestamp"]
    static let audioKeys = ["jitter", "packetsReceived", "packetsLost", "bytesReceived", "audioLevel", "totalSamplesReceived",
                            "concealedSamples", "silentConcealedSamples", "concealmentEvents", "insertedSamplesForDeceleration",
                            "removedSamplesForAcceleration", "jitterBufferDelay", "jitterBufferEmittedCount", "jitterBufferTargetDelay",
                            "nackCount", "fecPacketsReceived", "codecId", "ssrc", "mid", "playoutId"]

    static func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue ?? (v as? Double) }

    static func extract(_ raw: [String: [String: Any]], state: inout StatsState) -> [String: Any] {
        var out: [String: Any] = [:]
        func codec(_ id: Any?) -> [String: Any]? {
            guard let id = id as? String, let c = raw[id] else { return nil }
            var d: [String: Any] = [:]
            for k in ["mimeType", "payloadType", "clockRate", "channels", "sdpFmtpLine"] { if let v = c[k] { d[k] = v } }
            return d
        }
        var tNow: Double = 0
        for (_, st) in raw where (st["type"] as? String) == "inbound-rtp" {
            let kind = st["kind"] as? String ?? ""
            let keys = kind == "video" ? videoKeys : audioKeys
            var d: [String: Any] = [:]
            for k in keys { if let v = st[k] { d[k] = v } }
            if let c = codec(st["codecId"]) { d["codec"] = c }
            out[kind] = d
            if kind == "video", let ts = num(st["timestamp_us"]) { tNow = ts / 1_000_000 }
        }
        // Per-second deltas for video.
        if var v = out["video"] as? [String: Any] {
            let dt = state.lastTime > 0 ? tNow - state.lastTime : 0
            func delta(_ k: String) -> Double? {
                guard let cur = num(v[k]) else { return nil }
                defer { state.last[k] = cur }
                guard dt > 0, let prev = state.last[k] else { return nil }
                return cur - prev
            }
            let dBytes = delta("bytesReceived"), dFrames = delta("framesDecoded"), dQp = delta("qpSum")
            let dDecode = delta("totalDecodeTime"), dPackets = delta("packetsReceived"), dLost = delta("packetsLost")
            let dNack = delta("nackCount"), dPli = delta("pliCount"), dKey = delta("keyFramesDecoded"), dFreeze = delta("freezeCount")
            let dJbDelay = delta("jitterBufferDelay"), dJbCount = delta("jitterBufferEmittedCount")
            if dt > 0 {
                if let b = dBytes { v["videoMbps"] = round2(b * 8 / dt / 1_000_000) }
                if let f = dFrames, f > 0 {
                    if let q = dQp { v["avgQp"] = round2(q / f) }
                    if let d = dDecode { v["decodeMsPerFrame"] = round2(d / f * 1000) }
                    v["fpsDecoded"] = round2(f / dt)
                }
                if let p = dPackets, let l = dLost, p + l > 0 { v["lossPercent"] = round2(l / (p + l) * 100) }
                if let n = dNack { v["nackPerSec"] = round2(n / dt) }
                if let n = dPli { v["pliPerSec"] = round2(n / dt) }
                if let n = dKey { v["keyframesThisSecond"] = n }
                if let n = dFreeze { v["freezesThisSecond"] = n }
                if let d = dJbDelay, let c = dJbCount, c > 0 { v["jitterBufferMs"] = round2(d / c * 1000) }
            }
            state.lastTime = tNow
            out["video"] = v
        }
        if var a = out["audio"] as? [String: Any], let b = num(a["bytesReceived"]) {
            if let prev = state.last["audioBytes"], state.lastTime > 0 { a["audioKbps"] = round2((b - prev) * 8 / 1000) }
            state.last["audioBytes"] = b
            out["audio"] = a
        }
        // Selected candidate pair.
        var pairId: String?
        for (_, st) in raw where (st["type"] as? String) == "transport" {
            if let p = st["selectedCandidatePairId"] as? String { pairId = p }
            var t: [String: Any] = [:]
            for k in ["dtlsState", "iceState", "tlsVersion", "dtlsCipher", "srtpCipher", "selectedCandidatePairChanges", "bytesReceived", "packetsReceived"] {
                if let v = st[k] { t[k] = v }
            }
            out["transport"] = t
        }
        if pairId == nil {
            pairId = raw.first { ($0.value["type"] as? String) == "candidate-pair" && ($0.value["nominated"] as? NSNumber)?.boolValue == true
                && ($0.value["state"] as? String) == "succeeded" }?.key
        }
        if let pid = pairId, let p = raw[pid] {
            var d: [String: Any] = [:]
            for k in ["state", "nominated", "currentRoundTripTime", "totalRoundTripTime", "responsesReceived", "availableIncomingBitrate",
                      "availableOutgoingBitrate", "bytesReceived", "bytesSent", "packetsReceived", "consentRequestsSent"] {
                if let v = p[k] { d[k] = v }
            }
            func cand(_ id: Any?) -> [String: Any]? {
                guard let id = id as? String, let c = raw[id] else { return nil }
                var cd: [String: Any] = [:]
                for k in ["candidateType", "address", "ip", "port", "protocol", "networkType", "relayProtocol", "priority", "networkAdapterType", "vpn"] {
                    if let v = c[k] { cd[k] = v }
                }
                return cd
            }
            if let l = cand(p["localCandidateId"]) { d["local"] = l }
            if let r = cand(p["remoteCandidateId"]) { d["remote"] = r }
            if let rtt = num(p["currentRoundTripTime"]) { d["rttMs"] = round2(rtt * 1000) }
            d["path"] = pathLabel(d)
            out["candidatePair"] = d
        }
        // Flattened copy for the overlay / aggregate.
        if let v = out["video"] as? [String: Any] {
            var flat: [String: Any] = [:]
            for k in ["videoMbps", "avgQp", "decoderImplementation", "nackCount", "pliCount", "freezeCount", "totalFreezesDuration", "pauseCount", "framesDropped", "packetsLost",
                      "frameWidth", "frameHeight", "keyFramesDecoded", "decodeMsPerFrame", "jitterBufferMs",
                      "packetsReceived", "retransmittedPacketsReceived", "retransmittedBytesReceived", "fecPacketsReceived"] { flat[k] = v[k] }
            flat["fps"] = v["framesPerSecond"]
            if let c = v["codec"] as? [String: Any] { flat["codec"] = "\(c["mimeType"] ?? "?") \(c["sdpFmtpLine"] ?? "")" }
            if let p = out["candidatePair"] as? [String: Any] { flat["path"] = p["path"]; flat["rttMs"] = p["rttMs"] }
            out["flat"] = flat
        }
        return out
    }

    static func pathLabel(_ pair: [String: Any]) -> String {
        let l = pair["local"] as? [String: Any] ?? [:], r = pair["remote"] as? [String: Any] ?? [:]
        let lt = l["candidateType"] as? String ?? "?", rt = r["candidateType"] as? String ?? "?"
        let raddr = (r["address"] ?? r["ip"]).map { "\($0)" } ?? "?"
        let isLAN = isPrivate(raddr)
        let route = (lt == "host" && rt == "host" && isLAN) ? "LAN direct" : (lt == "relay" || rt == "relay") ? "relayed" : isLAN ? "LAN" : "remote path"
        return "\(route): local \(lt) \(l["address"] ?? l["ip"] ?? "?") <-> remote \(rt) \(raddr):\(r["port"] ?? "?") \(r["protocol"] ?? "")"
    }

    static func isPrivate(_ ip: String) -> Bool {
        if ip.hasPrefix("10.") || ip.hasPrefix("192.168.") || ip.hasPrefix("169.254.") || ip.hasPrefix("fe80") || ip.hasPrefix("fd") { return true }
        if ip.hasPrefix("172."), let second = Int(ip.split(separator: ".").dropFirst().first ?? ""), (16...31).contains(second) { return true }
        return false
    }

    static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
}

/// Running per-session aggregate used for `summary.md`, `run.json` and the overlay.
struct Aggregate {
    var offer: SDPSummary?
    var answer: SDPSummary?
    var httpCounts: [String: Int] = [:]
    var dcCounts: [String: Int] = [:]
    var unhandled = Set<String>()
    var serverVideoSizes = Set<String>()
    var decodedSizes = Set<String>()
    var pixelFormats = Set<String>()
    var colorInfo = Set<String>()
    var hdrMetadataSeen = false
    var lastFrame: [String: Any]?
    var lastStats: [String: Any] = [:]
    var bitstream: [[String: Any]] = []
    var bitstreamKeys = Set<String>()
    var configuration: [String: Any]?
    var play: [String: Any]?
    var mbps: [Double] = []
    var maxMbps: Double = 0
    var qps: [Double] = []
    var rtts: [Double] = []
    var jitterBufferMs: [Double] = []
    var decodeMs: [Double] = []
    var codecs = Set<String>()
    var decoders = Set<String>()
    var paths = Set<String>()
    var resolutions = Set<String>()
    var pacing: [PacingWindow] = []

    mutating func add(stats s: [String: Any]) {
        guard let flat = s["flat"] as? [String: Any] else { return }
        lastStats = flat
        if let m = flat["videoMbps"] as? Double { mbps.append(m); maxMbps = max(maxMbps, m) }
        if let q = flat["avgQp"] as? Double { qps.append(q) }
        if let r = flat["rttMs"] as? Double { rtts.append(r) }
        if let j = flat["jitterBufferMs"] as? Double { jitterBufferMs.append(j) }
        if let d = flat["decodeMsPerFrame"] as? Double { decodeMs.append(d) }
        if let c = flat["codec"] as? String { codecs.insert(c) }
        if let d = flat["decoderImplementation"] { decoders.insert("\(d)") }
        if let p = flat["path"] as? String { paths.insert(p) }
        if let w = flat["frameWidth"], let h = flat["frameHeight"] { resolutions.insert("\(w)x\(h)") }
    }

    mutating func add(frame f: [String: Any]) {
        lastFrame = f
        if let w = f["width"], let h = f["height"] { decodedSizes.insert("\(w)x\(h)") }
        pixelFormats.insert("\(f["pixelFormat"] ?? "?") (\(f["bitDepth"].map { "\($0)-bit" } ?? "?"), \(f["bufferClass"] ?? "?"))")
        colorInfo.insert("primaries=\(f["colorPrimaries"] ?? "-") transfer=\(f["transferFunction"] ?? "-") matrix=\(f["yCbCrMatrix"] ?? "-") range=\(f["range"] ?? "-")\(f["colorInfoGuessedBy"].map { " (guessed by \($0))" } ?? "")")
        if f["hdrMetadata"] as? Bool == true { hdrMetadataSeen = true }
    }

    func result(offer: SDPSummary?, answer: SDPSummary?) -> [String: Any] {
        func stats(_ a: [Double]) -> [String: Any] {
            guard !a.isEmpty else { return [:] }
            let s = a.sorted()
            return ["avg": StatsExtractor.round2(a.reduce(0, +) / Double(a.count)), "p50": s[s.count / 2],
                    "p95": s[min(s.count - 1, Int(Double(s.count) * 0.95))], "max": s.last!]
        }
        // Ignore the first few seconds of ramp-up for the "steady" bitrate.
        let steady = mbps.count > 8 ? Array(mbps.dropFirst(5)) : mbps
        var r: [String: Any] = [
            "selectedVideoCodec": answer.flatMap { SDPSummary.selectedVideoCodec($0) } ?? "-",
            "statsCodecs": codecs.sorted(),
            "decoderImplementations": decoders.sorted(),
            "statsResolutions": resolutions.sorted(),
            "decodedSizes": decodedSizes.sorted(),
            "serverReportedVideoSizes": serverVideoSizes.sorted(),
            "pixelFormats": pixelFormats.sorted(),
            "colorInfo": colorInfo.sorted(),
            "hdrMetadataSeen": hdrMetadataSeen,
            "colorSpaceExtensionNegotiated": answer.map(SDPSummary.hasColorSpace) ?? false,
            "answerVideoBandwidth": answer?.video?.bandwidth ?? [],
            "videoMbps": stats(steady),
            "avgQp": stats(qps),
            "rttMs": stats(rtts),
            "paths": paths.sorted(),
            "unhandledMessages": unhandled.sorted(),
            "bitstream": bitstream,
            "statsSamples": mbps.count,
        ]
        if let last = lastStats["framesDropped"] { r["framesDroppedTotal"] = last }
        if let last = lastStats["freezeCount"] { r["freezesTotal"] = last }
        if let last = lastStats["totalFreezesDuration"] { r["freezeSecondsTotal"] = last }
        if let last = lastStats["pauseCount"] { r["pausesTotal"] = last }
        if !pacing.isEmpty {
            // Frames between the decoder and the screen, over the whole run (5 s windows from the renderer).
            func sum(_ k: KeyPath<PacingWindow, Int>) -> Int { pacing.reduce(0) { $0 + $1[keyPath: k] } }
            r["framePacing"] = ["windows": pacing.count, "pacedWindows": pacing.filter(\.paced).count,
                                "framesReceived": sum(\.received), "framesDroppedByRenderer": sum(\.dropped),
                                "displayTicks": sum(\.ticks), "repeatTicks": sum(\.repeats), "shownFromDrawTime": sum(\.shownFromDrawTime),
                                "arrivalIntervalMs": IntervalStats.pooled(pacing.map(\.arrival)).json,
                                "streamIntervalMs": IntervalStats.pooled(pacing.map(\.stream)).json,
                                "shownIntervalMs": IntervalStats.pooled(pacing.map(\.shown)).json] as [String: Any]
        }
        if let last = lastStats["nackCount"] { r["nackTotal"] = last }
        if let last = lastStats["pliCount"] { r["pliTotal"] = last }
        // What decides the transport options: how long frames sit in the jitter buffer (per-second averages, ramp-up
        // included), and how much loss was repaired by retransmission (only non-zero when RTX was negotiated) or FEC.
        if !jitterBufferMs.isEmpty { r["jitterBufferMs"] = stats(jitterBufferMs) }
        if !decodeMs.isEmpty { r["decodeMs"] = stats(decodeMs) }
        for (key, name) in [("packetsReceived", "packetsReceivedTotal"), ("packetsLost", "packetsLostTotal"),
                            ("retransmittedPacketsReceived", "retransmittedPacketsTotal"),
                            ("retransmittedBytesReceived", "retransmittedBytesTotal"), ("fecPacketsReceived", "fecPacketsTotal")] {
            if let last = lastStats[key] { r[name] = last }
        }
        return r
    }

    func markdown(meta: [String: Any], result r: [String: Any]) -> String {
        var s = "# Diagnostics run \(meta["runId"] ?? "")\n\n"
        s += "Target: \(meta["target"] ?? "-")  \nDuration: \(meta["durationSeconds"] ?? "-") s, ended: \(meta["endReason"] ?? "-")\n\n"
        s += "## Settings\n\n"
        for (k, v) in (meta["settings"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) { s += "- \(k): `\(v)`\n" }
        s += "\n## Results\n\n"
        let order = ["selectedVideoCodec", "statsCodecs", "decoderImplementations", "statsResolutions", "decodedSizes", "serverReportedVideoSizes",
                     "pixelFormats", "colorInfo", "hdrMetadataSeen", "colorSpaceExtensionNegotiated", "answerVideoBandwidth", "videoMbps", "avgQp",
                     "rttMs", "paths", "framesDroppedTotal", "freezesTotal", "freezeSecondsTotal", "pausesTotal", "nackTotal", "pliTotal",
                     "jitterBufferMs", "decodeMs", "packetsReceivedTotal", "packetsLostTotal", "retransmittedPacketsTotal", "retransmittedBytesTotal",
                     "fecPacketsTotal", "framePacing",
                     "unhandledMessages", "bitstream"]
        for k in order { if let v = r[k] { s += "- **\(k)**: \(Aggregate.short(v))\n" } }
        s += "\n## HTTP calls\n\n"
        for (k, v) in httpCounts.sorted(by: { $0.key < $1.key }) { s += "- \(k): \(v)\n" }
        s += "\n## Data-channel message counts\n\n"
        for (k, v) in dcCounts.sorted(by: { $0.key < $1.key }) { s += "- \(k): \(v)\n" }
        return s
    }

    static func short(_ v: Any) -> String {
        if let d = try? JSONSerialization.data(withJSONObject: DiagnosticsRecorder.jsonSafe(v) as Any, options: [.sortedKeys, .fragmentsAllowed]),
           let str = String(data: d, encoding: .utf8) { return str }
        return "\(v)"
    }
}

// MARK: - Data channels

/// Decodes data-channel payloads in the formats the app understands; reports whether the message type is handled.
enum DataChannelDecoder {
    struct Result { let kind: String; let value: Any?; let handled: Bool }

    static let handledMessageTypes: Set<String> = ["Handshake", "HandshakeAck", "TransactionStart", "TransactionComplete", "Message"]
    static let handledTargets: Set<String> = ["/streaming/sessionLifetimeManagement/serverInitiatedDisconnect", "/streaming/properties/titleinfo",
                                              "/streaming/systemUi/messages/ShowMessageDialog"]

    static func decode(channel: String, dir: DiagnosticsRecorder.Direction, data: Data) -> Result {
        if channel == "input" { return input(dir: dir, data: data) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            if let s = String(data: data, encoding: .utf8), !s.isEmpty { return Result(kind: "text", value: Redact.scrub(s), handled: dir == .send) }
            return Result(kind: "binary", value: nil, handled: dir == .send)
        }
        let red = Redact.value(obj)
        guard let d = obj as? [String: Any] else { return Result(kind: "json", value: red, handled: dir == .send) }
        if channel == "message" {
            let type = d["type"] as? String ?? "?"
            let target = d["target"] as? String
            let kind = target.map { "\(type) \($0)" } ?? type
            var handled = dir == .send || handledMessageTypes.contains(type)
            if dir == .recv, let target, (type == "TransactionStart" || type == "Message") { handled = handledTargets.contains(target) }
            return Result(kind: kind, value: red, handled: handled)
        }
        if channel == "control" {
            let kind = (d["message"] as? String) ?? (d["type"] as? String) ?? "json"
            // The app only logs what the control channel receives.
            return Result(kind: kind, value: red, handled: dir == .send)
        }
        return Result(kind: (d["type"] as? String) ?? (d["message"] as? String) ?? "json", value: red, handled: dir == .send)
    }

    /// Input reports: u16 LE report-type bit mask, u32 sequence, f64 timestamp, then per-type payloads.
    static func input(dir: DiagnosticsRecorder.Direction, data: Data) -> Result {
        let b = [UInt8](data)
        guard b.count >= 2 else { return Result(kind: "short", value: nil, handled: false) }
        let type = Int(b[0]) | Int(b[1]) << 8
        var names: [String] = []
        let known: [(Int, String)] = [(1, "metadata"), (2, "gamepad"), (4, "pointer"), (8, "clientMetadata"), (16, "serverMetadata"),
                                      (32, "mouse"), (64, "keyboard"), (128, "vibration"), (256, "sensor")]
        for (bit, n) in known where type & bit != 0 { names.append(n) }
        let unknownBits = type & ~known.reduce(0) { $0 | $1.0 }
        if unknownBits != 0 { names.append("unknown(0x\(String(unknownBits, radix: 16)))") }
        let kind = names.isEmpty ? "type0" : names.joined(separator: "+")
        var v: [String: Any] = ["reportType": type, "types": names, "hex": b.prefix(64).map { String(format: "%02x", $0) }.joined()]
        func u16(_ o: Int) -> Int { o + 1 < b.count ? Int(b[o]) | Int(b[o + 1]) << 8 : 0 }
        func u32(_ o: Int) -> Int { o + 3 < b.count ? u16(o) | u16(o + 2) << 16 : 0 }
        if dir == .recv {
            if b[0] == 16, b.count >= 10 { v["serverMetadata"] = ["height": u32(2), "width": u32(6)] }
            if b[0] == 128, b.count >= 13 {
                v["vibration"] = ["gamepad": Int(b[3]), "left": Int(b[4]), "right": Int(b[5]), "leftTrigger": Int(b[6]),
                                  "rightTrigger": Int(b[7]), "durationMs": u16(8), "delayMs": u16(10), "repeat": Int(b[12])]
            }
        }
        let handled = dir == .send || b[0] == 16 || b[0] == 128
        return Result(kind: kind, value: v, handled: handled)
    }
}
