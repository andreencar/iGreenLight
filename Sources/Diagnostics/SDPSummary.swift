import Foundation

/// Parsed view of an SDP blob: per m-section codecs (rtpmap + fmtp + rtcp-fb), bandwidth lines and header extensions.
struct SDPSummary {
    struct Codec {
        let pt: String
        var name: String
        var clock: String
        var fmtp: String?
        var rtcpFb: [String] = []
        var label: String {
            var s = "\(name)/\(clock) pt=\(pt)"
            if let fmtp { s += " [\(fmtp)]" }
            return s
        }
    }

    struct Media {
        var kind: String
        var port: String
        var proto: String
        var payloadOrder: [String]
        var mid: String?
        var direction: String?
        var bandwidth: [String] = []
        var extmaps: [(id: String, uri: String)] = []
        var codecs: [String: Codec] = [:]
        var other: [String] = []   // sctp-port, max-message-size, setup etc.

        var orderedCodecs: [Codec] { payloadOrder.compactMap { codecs[$0] } }
    }

    var sessionLines: [String] = []
    var media: [Media] = []

    init(_ sdp: String) {
        var current: Media?
        for raw in sdp.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("m=") {
                if let c = current { media.append(c) }
                let p = line.dropFirst(2).split(separator: " ").map(String.init)
                current = Media(kind: p.first ?? "?", port: p.count > 1 ? p[1] : "", proto: p.count > 2 ? p[2] : "",
                                payloadOrder: Array(p.dropFirst(3)))
                continue
            }
            guard var m = current else {
                if line.hasPrefix("b=") || line.hasPrefix("a=group") || line.hasPrefix("a=extmap-allow-mixed") || line.hasPrefix("a=msid-semantic") {
                    sessionLines.append(line)
                }
                continue
            }
            if line.hasPrefix("b=") { m.bandwidth.append(String(line.dropFirst(2))) }
            else if line.hasPrefix("a=mid:") { m.mid = String(line.dropFirst(6)) }
            else if ["a=sendrecv", "a=recvonly", "a=sendonly", "a=inactive"].contains(line) { m.direction = String(line.dropFirst(2)) }
            else if line.hasPrefix("a=extmap:") {
                let p = line.dropFirst(9).split(separator: " ")
                if p.count >= 2 { m.extmaps.append((String(p[0]), String(p[1]))) }
            } else if line.hasPrefix("a=rtpmap:") {
                let p = line.dropFirst(9).split(separator: " ", maxSplits: 1)
                if p.count == 2 {
                    let pt = String(p[0])
                    let nc = p[1].split(separator: "/")
                    m.codecs[pt, default: Codec(pt: pt, name: "", clock: "")].name = String(nc.first ?? "")
                    m.codecs[pt]!.clock = nc.dropFirst().joined(separator: "/")
                }
            } else if line.hasPrefix("a=fmtp:") {
                let p = line.dropFirst(7).split(separator: " ", maxSplits: 1)
                if p.count == 2 { m.codecs[String(p[0]), default: Codec(pt: String(p[0]), name: "?", clock: "")].fmtp = String(p[1]) }
            } else if line.hasPrefix("a=rtcp-fb:") {
                let p = line.dropFirst(10).split(separator: " ", maxSplits: 1)
                if p.count == 2 {
                    if p[0] == "*" { for k in m.codecs.keys { m.codecs[k]!.rtcpFb.append(String(p[1])) } }
                    else { m.codecs[String(p[0]), default: Codec(pt: String(p[0]), name: "?", clock: "")].rtcpFb.append(String(p[1])) }
                }
            } else if line.hasPrefix("a=sctp-port") || line.hasPrefix("a=max-message-size") || line.hasPrefix("a=setup")
                        || line.hasPrefix("a=rtcp-mux") || line.hasPrefix("a=rtcp-rsize") || line.hasPrefix("a=ssrc-group") || line.hasPrefix("a=x-") {
                m.other.append(String(line.dropFirst(2)))
            }
            current = m
        }
        if let c = current { media.append(c) }
    }

    var video: Media? { media.first { $0.kind == "video" } }
    var audio: Media? { media.first { $0.kind == "audio" } }

    static let colorSpaceURI = "http://www.webrtc.org/experiments/rtp-hdrext/color-space"

    static func hasColorSpace(_ s: SDPSummary) -> Bool {
        s.media.contains { $0.extmaps.contains { $0.uri == colorSpaceURI } }
    }

    /// With this extension in the answer the sender can ask for a playout delay itself (0 = show at once), which
    /// would make forcing one on our side redundant.
    static let playoutDelayURI = "http://www.webrtc.org/experiments/rtp-hdrext/playout-delay"

    static func hasPlayoutDelay(_ s: SDPSummary) -> Bool {
        s.video?.extmaps.contains { $0.uri == playoutDelayURI } ?? false
    }

    /// Payload types of the video codecs that have an RTX stream (`a=fmtp:<rtx pt> apt=<codec pt>`), in m-line order.
    /// Empty = no retransmission stream in this description.
    static func rtxProtected(_ s: SDPSummary) -> [String] {
        guard let v = s.video else { return [] }
        return v.orderedCodecs.filter { $0.name.lowercased() == "rtx" }.compactMap { c in
            c.fmtp?.split(separator: ";").first { $0.hasPrefix("apt=") }.map { String($0.dropFirst(4)) }
        }.filter { v.codecs[$0] != nil }
    }

    /// First non-RTX/FEC codec in the answer's video m-line = what the server will send.
    static func selectedVideoCodec(_ s: SDPSummary) -> String? {
        guard let v = s.video else { return nil }
        let real = v.orderedCodecs.filter { !["rtx", "red", "ulpfec", "flexfec-03"].contains($0.name.lowercased()) }
        return real.first.map { c in
            var s = c.name
            if let f = c.fmtp { s += " " + f }
            return s
        }
    }

    var json: [String: Any] {
        ["session": sessionLines,
         "media": media.map { m -> [String: Any] in
             var d: [String: Any] = ["kind": m.kind, "port": m.port, "proto": m.proto, "payloadOrder": m.payloadOrder,
                                     "bandwidth": m.bandwidth, "other": m.other,
                                     "extmaps": m.extmaps.map { ["id": $0.id, "uri": $0.uri] },
                                     "codecs": m.orderedCodecs.map { c -> [String: Any] in
                                         var cd: [String: Any] = ["pt": c.pt, "name": c.name, "clock": c.clock, "rtcpFb": c.rtcpFb]
                                         if let f = c.fmtp { cd["fmtp"] = f }
                                         return cd
                                     }]
             if let mid = m.mid { d["mid"] = mid }
             if let dir = m.direction { d["direction"] = dir }
             return d
         }]
    }

    static func negotiated(offer: SDPSummary, answer: SDPSummary) -> [String: Any] {
        var out: [String: Any] = [:]
        out["selectedVideoCodec"] = selectedVideoCodec(answer) ?? "-"
        out["answerVideoCodecs"] = answer.video?.orderedCodecs.map(\.label) ?? []
        out["answerAudioCodecs"] = answer.audio?.orderedCodecs.map(\.label) ?? []
        out["offeredVideoCodecs"] = offer.video?.orderedCodecs.map(\.label) ?? []
        out["colorSpaceExtensionOffered"] = hasColorSpace(offer)
        out["colorSpaceExtensionNegotiated"] = hasColorSpace(answer)
        out["rtxOffered"] = !rtxProtected(offer).isEmpty
        out["rtxNegotiated"] = !rtxProtected(answer).isEmpty
        out["playoutDelayExtensionNegotiated"] = hasPlayoutDelay(answer)
        out["answerVideoExtensions"] = answer.video?.extmaps.map(\.uri) ?? []
        out["answerVideoBandwidth"] = answer.video?.bandwidth ?? []
        out["offerVideoBandwidth"] = offer.video?.bandwidth ?? []
        out["answerSessionLines"] = answer.sessionLines
        return out
    }

    static func text(offer: SDPSummary, answer: SDPSummary?) -> String {
        var s = ""
        func dump(_ title: String, _ sdp: SDPSummary) {
            s += "== \(title) ==\n"
            for l in sdp.sessionLines { s += "  session: \(l)\n" }
            for m in sdp.media {
                s += "\n[\(m.kind)] mid=\(m.mid ?? "-") \(m.direction ?? "") port=\(m.port) \(m.proto)\n"
                for b in m.bandwidth { s += "  b=\(b)\n" }
                for e in m.extmaps { s += "  extmap \(e.id) \(e.uri)\(e.uri == colorSpaceURI ? "   <-- COLOR SPACE" : "")\n" }
                for c in m.orderedCodecs {
                    s += "  codec \(c.label)\n"
                    if !c.rtcpFb.isEmpty { s += "        rtcp-fb: \(c.rtcpFb.joined(separator: ", "))\n" }
                }
                for o in m.other { s += "  \(o)\n" }
            }
            s += "\n"
        }
        dump("OFFER (local)", offer)
        if let answer {
            dump("ANSWER (remote)", answer)
            s += "== NEGOTIATED ==\n"
            s += "  selected video codec: \(selectedVideoCodec(answer) ?? "-")\n"
            s += "  color-space header extension: offered=\(hasColorSpace(offer)) negotiated=\(hasColorSpace(answer))\n"
        }
        return s
    }
}
