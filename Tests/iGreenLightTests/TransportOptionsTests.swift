import Foundation
import QuartzCore
import Testing
import WebRTC
@testable import iGreenLight

/// Real offers from the app's peer-connection factory: what each `WebRTCClient.Options` field does to the SDP.
/// Serialized because low-latency playout is a process-wide libwebrtc switch.
@Suite(.serialized) struct OfferOptionTests {
    /// The parts of an offer that don't change from one peer connection to the next: m-lines and codec lines.
    private func stable(_ sdp: String) -> [String] {
        sdp.components(separatedBy: "\r\n").filter {
            $0.hasPrefix("m=") || $0.hasPrefix("a=rtpmap:") || $0.hasPrefix("a=fmtp:") || $0.hasPrefix("a=rtcp-fb:") || $0.hasPrefix("a=extmap:") || $0.hasPrefix("b=")
        }
    }

    private func offer(_ options: WebRTCClient.Options) async throws -> String {
        let client = try WebRTCClient(options: options)
        defer { client.close() }
        return try await client.createOffer()
    }

    @Test func defaultOfferHasNoRTX() async throws {
        let sdp = try await offer(.init())
        #expect(!sdp.lowercased().contains("rtx/90000"))
        #expect(SDPSummary.rtxProtected(SDPSummary(sdp)).isEmpty)
    }

    @Test func rtxOptionAddsAnRTXPayloadWithAptForEveryVideoCodec() async throws {
        let plain = try await offer(.init())
        let sdp = try await offer(.init(offerRTX: true))
        let video = try #require(SDPSummary(sdp).video)
        let codecs = video.orderedCodecs.filter { !["rtx", "red", "ulpfec", "flexfec-03"].contains($0.name.lowercased()) }
        #expect(!codecs.isEmpty)
        #expect(SDPSummary.rtxProtected(SDPSummary(sdp)).sorted() == codecs.map(\.pt).sorted())
        for c in video.orderedCodecs where c.name.lowercased() == "rtx" { #expect(c.clock == "90000") }
        // Nothing else moved: without the rtx payloads it is the default offer, same codecs in the same order.
        let rtxPts = Set(video.orderedCodecs.filter { $0.name.lowercased() == "rtx" }.map(\.pt))
        let stripped = stable(sdp).compactMap { line -> String? in
            if line.hasPrefix("m=video") { return line.split(separator: " ").filter { !rtxPts.contains(String($0)) }.joined(separator: " ") }
            if let pt = line.split(separator: ":").dropFirst().first?.split(separator: " ").first, rtxPts.contains(String(pt)),
               line.hasPrefix("a=rtpmap:") || line.hasPrefix("a=fmtp:") { return nil }
            return line
        }
        #expect(stripped == stable(plain))
    }

    @Test func rtxFollowsTheCodecSelection() async throws {
        let sdp = try await offer(.init(codec: .h264Main, onlyPreferredCodec: true, offerRTX: true))
        let s = SDPSummary(sdp)
        let h264 = try #require(s.video?.orderedCodecs.first { $0.name == "H264" })
        #expect(h264.fmtp?.contains("profile-level-id=4d") == true)
        #expect(SDPSummary.rtxProtected(s) == [h264.pt])
    }

    @Test func optionsThatAreNotAboutTheOfferLeaveItAlone() async throws {
        let plain = try await offer(.init())
        var o = WebRTCClient.Options()
        o.lowLatencyPlayout = true; o.fastAudioCatchUp = true; o.frameTimingFeedback = true
        let sdp = try await offer(o)
        WebRTCClient.setLowLatencyPlayout(false)
        #expect(stable(sdp) == stable(plain))
    }

    @Test func extraDataChannelsAreOpenedAsSpecified() throws {
        var o = WebRTCClient.Options()
        o.extraDataChannels = [DataChannelSpec(label: "reliableinput", protocolName: "1.0"),
                               DataChannelSpec(label: "unreliableinput", protocolName: "1.0", ordered: false, maxRetransmits: 0)]
        let client = try WebRTCClient(options: o)
        defer { client.close() }
        #expect(client.extraChannels.map(\.name) == ["reliableinput", "unreliableinput"])
        let reliable = client.extraChannels[0].channel, unreliable = client.extraChannels[1].channel
        #expect(reliable.isOrdered && reliable.label == "reliableinput" && reliable.`protocol` == "1.0")
        #expect(!unreliable.isOrdered && unreliable.maxRetransmits == 0)
        #expect(try WebRTCClient(options: .init()).extraChannels.isEmpty)
    }
}

@Suite struct RTXSummaryTests {
    @Test func findsTheCodecsAnRTXStreamPointsAt() {
        let sdp = ["v=0", "m=video 9 UDP/TLS/RTP/SAVPF 102 103 104 118",
                   "a=rtpmap:102 H264/90000", "a=fmtp:102 packetization-mode=1;profile-level-id=4d0033",
                   "a=rtpmap:103 rtx/90000", "a=fmtp:103 apt=102",
                   "a=rtpmap:104 rtx/90000", "a=fmtp:104 apt=99",      // points at a codec that isn't there
                   "a=rtpmap:118 ulpfec/90000", "a=extmap:5 " + SDPSummary.playoutDelayURI].joined(separator: "\r\n")
        let s = SDPSummary(sdp)
        #expect(SDPSummary.rtxProtected(s) == ["102"])
        #expect(SDPSummary.hasPlayoutDelay(s))
        #expect(SDPSummary.rtxProtected(SDPSummary("v=0\r\nm=video 9 RTP 102\r\na=rtpmap:102 H264/90000")).isEmpty)
        #expect(!SDPSummary.hasPlayoutDelay(SDPSummary("v=0\r\nm=audio 9 RTP 111")))
    }
}

@Suite struct FrameFeedbackTests {
    @Test func timingBecomesMillisecondsOnTheChannelClock() {
        let start: CFTimeInterval = 1000
        let known = PresentedFrame(rtpTimestamp: 90_000, arrivedAt: 1000.050, presentedAt: 1000.058, decodeMs: 4, firstPacketAt: 1000.040)
        let m = known.metadata(channelStart: start)
        #expect(m.serverDataKey == 90_000)
        #expect(abs(m.firstPacketArrivalMs - 40) < 1e-6)
        #expect(abs(m.submittedMs - 46) < 1e-6)
        #expect(abs(m.decodedMs - 50) < 1e-6)
        #expect(abs(m.renderedMs - 58) < 1e-6)
        // Unknown decode time and first packet: all three collapse onto the arrival, and nothing runs backwards.
        let bare = PresentedFrame(rtpTimestamp: 1, arrivedAt: 1000.050, presentedAt: 1000.049).metadata(channelStart: start)
        #expect(bare.firstPacketArrivalMs == bare.submittedMs && bare.submittedMs == bare.decodedMs)
        #expect(bare.renderedMs == bare.decodedMs)
    }

    @Test func severalFramesShareOnePacket() {
        // Times that are exact in binary, so the 0.1 ms values are too.
        let frames = [PresentedFrame(rtpTimestamp: 3000, arrivedAt: 8.25, presentedAt: 8.5),
                      PresentedFrame(rtpTimestamp: 6000, arrivedAt: 8.75, presentedAt: 9)].map { $0.metadata(channelStart: 8) }
        let d = [UInt8](InputPacket.frameMetadata(sequence: 9, timestampMs: 1000, frames: frames))
        #expect(d.count == 14 + 1 + 2 * 28)
        #expect(Array(d[0..<2]) == [1, 0])                       // report type: metadata
        #expect(d[14] == 2)
        #expect(Array(d[15..<19]) == [0xB8, 0x0B, 0, 0])         // 3000
        #expect(Array(d[31..<35]) == [0x88, 0x13, 0, 0])         // first frame rendered at 500 ms = 5000
        #expect(Array(d[43..<47]) == [0x70, 0x17, 0, 0])         // 6000
        #expect(Array(d[47..<51]) == [0x4C, 0x1D, 0, 0])         // second frame's first packet at 750 ms = 7500
    }

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var _batches: [[PresentedFrame]] = []
        var batches: [[PresentedFrame]] { lock.lock(); defer { lock.unlock() }; return _batches }
        func add(_ b: [PresentedFrame]) { lock.lock(); _batches.append(b); lock.unlock() }
    }

    @Test func queuesFromAnyThreadAndSendsInOrderAtABoundedRate() async throws {
        let queue = DispatchQueue(label: "test.feedback")
        let sink = Sink()
        let feedback = FrameFeedback(queue: queue, enabled: true, maxPacketsPerSecond: 10) { [sink] in
            dispatchPrecondition(condition: .onQueue(queue))
            sink.add($0)
        }
        feedback.decodeMs = 3
        let t0 = CACurrentMediaTime()
        // 60 frames over ~300 ms from another thread: at 10 packets a second that is 3 to 5 packets, never 60.
        await Task.detached {
            for i in 0..<60 {
                let t = CACurrentMediaTime()
                feedback.framePresented(rtpTimestamp: UInt32(i), arrivedAt: t, presentedAt: t)
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }.value
        try await Task.sleep(nanoseconds: 250_000_000)
        let elapsed = CACurrentMediaTime() - t0
        let batches = sink.batches
        #expect(batches.flatMap { $0 }.map(\.rtpTimestamp) == (0..<60).map(UInt32.init))
        #expect(batches.count >= 2 && Double(batches.count) <= elapsed * 10 + 2)
        #expect(batches.flatMap { $0 }.allSatisfy { $0.decodeMs == 3 })
    }

    @Test func aStalledQueueKeepsOnlyTheNewestFrames() async throws {
        let queue = DispatchQueue(label: "test.feedback.stalled")
        let sink = Sink()
        let feedback = FrameFeedback(queue: queue, enabled: true) { [sink] in sink.add($0) }
        queue.suspend()
        for i in 0..<(FrameFeedback.maxPending + 8) { feedback.framePresented(rtpTimestamp: UInt32(i), arrivedAt: 0, presentedAt: 0) }
        queue.resume()
        queue.sync {}
        let batches = sink.batches
        #expect(batches.count == 1)
        #expect(batches.first?.map(\.rtpTimestamp) == (8..<(FrameFeedback.maxPending + 8)).map(UInt32.init))
    }

    @Test func doesNothingWhenOff() {
        let queue = DispatchQueue(label: "test.feedback.off")
        let sink = Sink()
        let feedback = FrameFeedback(queue: queue, enabled: false) { [sink] in sink.add($0) }
        feedback.framePresented(rtpTimestamp: 1, arrivedAt: 0, presentedAt: 0)
        queue.sync {}
        #expect(sink.batches.isEmpty)
    }
}

@Suite struct TransportAggregateTests {
    @Test func resultCarriesJitterBufferAndRetransmissionNumbers() {
        var agg = Aggregate()
        for (i, jb) in [40.0, 60.0, 50.0].enumerated() {
            agg.add(stats: ["flat": ["jitterBufferMs": jb, "decodeMsPerFrame": 2.0, "nackCount": i * 2, "packetsReceived": 1000 * (i + 1),
                                     "retransmittedPacketsReceived": i, "retransmittedBytesReceived": i * 1200, "fecPacketsReceived": 0,
                                     "packetsLost": i] as [String: Any]])
        }
        let r = agg.result(offer: nil, answer: nil)
        #expect((r["jitterBufferMs"] as? [String: Any])?["avg"] as? Double == 50)
        #expect((r["jitterBufferMs"] as? [String: Any])?["max"] as? Double == 60)
        #expect(r["retransmittedPacketsTotal"] as? Int == 2)
        #expect(r["retransmittedBytesTotal"] as? Int == 2400)
        #expect(r["packetsReceivedTotal"] as? Int == 3000)
        #expect(r["packetsLostTotal"] as? Int == 2)
        #expect(r["nackTotal"] as? Int == 4)
        #expect(Aggregate().result(offer: nil, answer: nil)["jitterBufferMs"] == nil)
    }
}
