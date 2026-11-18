import Foundation
import WebRTC

/// RTCPeerConnection wrapper (Greenlight player.ts + sdp.ts + ice.ts).
final class WebRTCClient: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    private static let audioDevice = GameAudioDevice()
    static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        // Stereo game audio through our own output device (see GameAudioDevice), not libwebrtc's built-in ones.
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                        decoderFactory: AppVideoDecoderFactory(),
                                        audioDevice: audioDevice)
    }()

    let pc: RTCPeerConnection
    let queue = DispatchQueue(label: "app.igreenlight.webrtc")
    let control: ControlChannel
    let input: InputChannel
    let message: MessageChannel
    let chat: ChatChannel
    /// Channels from `Options.extraDataChannels`, in that order.
    let extraChannels: [DataChannel]
    /// Per-frame timing reports to the server; does nothing unless `Options.frameTimingFeedback` is on.
    let feedback: FrameFeedback

    var onVideoTrack: ((RTCVideoTrack) -> Void)?
    var onAudioTrack: ((RTCAudioTrack) -> Void)?
    var onIceState: ((RTCIceConnectionState) -> Void)?
    var onConnectionState: ((RTCPeerConnectionState) -> Void)?

    private var localCandidates: [RTCIceCandidate] = []
    private var gatheringDone: CheckedContinuation<Void, Never>?
    private var gatheringComplete = false
    private let lock = NSLock()

    struct Options {
        var codec: VideoCodecPreference = .h264Main
        var onlyPreferredCodec = false
        /// Video b=AS ceiling in kbps (0 = none).
        var maxVideoBitrateKbps = 0
        /// Offers RTX for the video codecs (`a=rtpmap … rtx` with `apt=`), so a lost packet can be resent on its own
        /// stream instead of costing a keyframe. Only has an effect if the console's answer keeps the rtx payloads.
        var offerRTX = false
        /// Frames go to the decoder and the renderer as soon as they are complete instead of waiting out libwebrtc's
        /// jitter-buffer and render delay (see `setLowLatencyPlayout`). Nothing in the SDP changes.
        var lowLatencyPlayout = false
        /// Lets the audio jitter buffer (NetEq) speed playback up more readily once it has built up a backlog, so audio
        /// latency recovers faster after a network hiccup, at the cost of more audible time-stretching.
        var fastAudioCatchUp = false
        /// Reports every presented frame's timing on the input channel, as the official web client does (`feedback`).
        var frameTimingFeedback = false
        /// Further data channels to open before the offer; probe hook.
        var extraDataChannels: [DataChannelSpec] = []
    }
    let options: Options

    private static let playoutLock = NSLock()
    private static var lowLatencyPlayoutApplied = false

    /// Turns libwebrtc's forced playout delay of zero on or off for the video receive streams created from now on.
    ///
    /// The only handle this WebRTC build gives on the video jitter buffer is the `WebRTC-ForcePlayoutDelay` field trial
    /// (the ObjC RTCRtpReceiver has no jitter-buffer delay setter). With `min_ms:0,max_ms:0` libwebrtc takes its
    /// low-latency path: a frame is decoded when its last packet arrives and handed on right away, where the default
    /// holds it for the estimated network jitter plus decode and render time. The trial is looked up when a receive
    /// stream is set up, so it does not have to be in place before the factory exists (measured on loopback:
    /// jitter-buffer delay drops from ~100 ms to under 1 ms for a connection made after the call, and comes back after
    /// turning it off). It is process-wide, so it follows the most recent connection; the app has one stream at a time.
    /// The price: nothing absorbs network jitter any more, so frames reach the renderer as unevenly as they arrive.
    static func setLowLatencyPlayout(_ on: Bool) {
        playoutLock.lock(); defer { playoutLock.unlock() }
        // Only on a change: every call replaces the string libwebrtc's threads read the trials from.
        guard on != lowLatencyPlayoutApplied else { return }
        lowLatencyPlayoutApplied = on
        RTCInitFieldTrialDictionary(on ? ["WebRTC-ForcePlayoutDelay": "min_ms:0,max_ms:0"] : [:])
        log("WebRTC", "low-latency playout \(on ? "on" : "off")")
    }

    init(options: Options = Options()) throws {
        self.options = options
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.iceServers = []
        config.continualGatheringPolicy = .gatherOnce
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        if options.fastAudioCatchUp { config.audioJitterBufferFastAccelerate = true }
        WebRTCClient.setLowLatencyPlayout(options.lowLatencyPlayout)
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let factory = WebRTCClient.factory
        // The delegate is set right after super.init().
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: nil) else {
            throw DataChannel.SetupError(what: "peer connection")
        }
        self.pc = pc

        let audioInit = RTCRtpTransceiverInit()
        audioInit.direction = .sendRecv
        pc.addTransceiver(of: .audio, init: audioInit)
        let videoInit = RTCRtpTransceiverInit()
        videoInit.direction = .recvOnly
        if let video = pc.addTransceiver(of: .video, init: videoInit) {
            let prefs = CodecOrdering.preferences(options.codec, onlyPreferred: options.onlyPreferredCodec, rtx: options.offerRTX, factory: factory)
            if let err = WebRTCClient.setCodecPreferences(video, prefs) {
                log("WebRTC", "setCodecPreferences failed: \(err)")
            } else {
                log("WebRTC", "video codec order: \(prefs.map { "\($0.name) \($0.parameters["profile-level-id"] ?? "")" })")
            }
        }

        // Channels must exist before the offer so they're in the SDP.
        control = try ControlChannel(pc: pc, queue: queue)
        input = try InputChannel(pc: pc, queue: queue)
        message = try MessageChannel(pc: pc, queue: queue)
        chat = try ChatChannel(pc: pc, queue: queue)
        var extra: [DataChannel] = []
        for c in options.extraDataChannels {
            extra.append(try DataChannel(pc: pc, name: c.label, protocolName: c.protocolName, ordered: c.ordered, maxRetransmits: c.maxRetransmits, queue: queue))
        }
        extraChannels = extra
        feedback = FrameFeedback(input: input, queue: queue, enabled: options.frameTimingFeedback)
        super.init()
        pc.delegate = self
    }

    /// Calls `-setCodecPreferences:error:` directly; Swift otherwise resolves to the deprecated non-throwing overload.
    static func setCodecPreferences(_ t: RTCRtpTransceiver, _ codecs: [RTCRtpCodecCapability]) -> NSError? {
        typealias Fn = @convention(c) (AnyObject, Selector, NSArray, UnsafeMutablePointer<NSError?>?) -> Bool
        let sel = NSSelectorFromString("setCodecPreferences:error:")
        guard let imp = t.method(for: sel) else { return NSError(domain: "WebRTC", code: -1) }
        var err: NSError?
        let ok = unsafeBitCast(imp, to: Fn.self)(t, sel, codecs as NSArray, &err)
        return ok ? nil : (err ?? NSError(domain: "WebRTC", code: -2))
    }

    func createOffer() async throws -> String {
        let constraints = RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "true"],
                                              optionalConstraints: nil)
        let offer: RTCSessionDescription = try await withCheckedThrowingContinuation { cont in
            pc.offer(for: constraints) { sdp, err in
                if let sdp { cont.resume(returning: sdp) } else { cont.resume(throwing: err ?? URLError(.unknown)) }
            }
        }
        // Greenlight sdp.ts: ask for stereo Opus.
        var munged = offer.sdp.replacingOccurrences(of: "useinbandfec=1", with: "useinbandfec=1;stereo=1")
        if options.maxVideoBitrateKbps > 0 { munged = WebRTCClient.setVideoBandwidth(munged, kbps: options.maxVideoBitrateKbps) }
        let local = RTCSessionDescription(type: .offer, sdp: munged)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(local) { err in if let err { cont.resume(throwing: err) } else { cont.resume() } }
        }
        return munged
    }

    /// Puts `b=AS:<kbps>` and `b=TIAS:<bps>` into the video m-section (Better xCloud's patchSdpBitrate does the b=AS part).
    static func setVideoBandwidth(_ sdp: String, kbps: Int) -> String {
        var lines = sdp.components(separatedBy: "\r\n")
        guard let m = lines.firstIndex(where: { $0.hasPrefix("m=video") }) else { return sdp }
        let end = lines[(m + 1)...].firstIndex(where: { $0.hasPrefix("m=") }) ?? lines.count
        // Drop existing b= lines in the section, then insert after c= (RFC 4566 order: m, i, c, b, …).
        var section = Array(lines[(m + 1)..<end]).filter { !$0.hasPrefix("b=AS:") && !$0.hasPrefix("b=TIAS:") }
        let at = (section.firstIndex(where: { $0.hasPrefix("c=") }).map { $0 + 1 }) ?? 0
        section.insert(contentsOf: ["b=AS:\(kbps)", "b=TIAS:\(kbps * 1000)"], at: at)
        lines.replaceSubrange((m + 1)..<end, with: section)
        return lines.joined(separator: "\r\n")
    }

    func setRemoteAnswer(_ sdp: String) async throws {
        let desc = RTCSessionDescription(type: .answer, sdp: sdp)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(desc) { err in if let err { cont.resume(throwing: err) } else { cont.resume() } }
        }
        // Unified plan: tracks may already be available on the transceivers.
        for t in pc.transceivers {
            if let v = t.receiver.track as? RTCVideoTrack { onVideoTrack?(v) }
            if let a = t.receiver.track as? RTCAudioTrack { onAudioTrack?(a) }
        }
    }

    /// Waits until ICE gathering completes (or a timeout), returns local candidates.
    func gatheredCandidates(timeout: TimeInterval = 3) async -> [RTCIceCandidate] {
        lock.lock()
        let done = gatheringComplete
        lock.unlock()
        if !done {
            await withTaskGroup(of: Void.self) { g in
                g.addTask { await withCheckedContinuation { c in self.lock.lock(); if self.gatheringComplete { self.lock.unlock(); c.resume() } else { self.gatheringDone = c; self.lock.unlock() } } }
                g.addTask { try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9)) }
                await g.next()
                g.cancelAll()
                self.finishGathering()
            }
        }
        lock.lock(); defer { lock.unlock() }
        return localCandidates
    }

    /// The gathered local candidates in the shape the gssv `/ice` endpoint takes, closed with end-of-candidates.
    func localCandidatePayload() async -> [[String: Any]] {
        var payload: [[String: Any]] = await gatheredCandidates().map {
            ["candidate": "a=" + $0.sdp, "sdpMid": $0.sdpMid ?? "0", "sdpMLineIndex": $0.sdpMLineIndex]
        }
        payload.append(["candidate": "a=end-of-candidates", "sdpMid": "0", "sdpMLineIndex": 0])
        return payload
    }

    private func finishGathering() {
        lock.lock()
        gatheringComplete = true
        let c = gatheringDone
        gatheringDone = nil
        lock.unlock()
        c?.resume()
    }

    func addRemoteCandidate(_ sdp: String, mid: String?, index: Int32) async {
        let cand = RTCIceCandidate(sdp: sdp, sdpMLineIndex: index, sdpMid: mid)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            pc.add(cand) { err in
                if let err { log("ICE", "addIceCandidate failed for \(sdp): \(err.localizedDescription)") }
                c.resume()
            }
        }
    }

    func stats() async -> RTCStatisticsReport {
        await withCheckedContinuation { c in pc.statistics { c.resume(returning: $0) } }
    }

    func close() {
        for ch in [control, input, message, chat] + extraChannels { ch.close() }
        pc.close()
    }

    // MARK: RTCPeerConnectionDelegate
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        log("WebRTC", "signaling state \(stateChanged.rawValue)")
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        log("WebRTC", "ICE connection state \(newState.rawValue)")
        onIceState?(newState)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        log("WebRTC", "ICE gathering state \(newState.rawValue)")
        if newState == .complete { finishGathering() }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        lock.lock(); localCandidates.append(candidate); lock.unlock()
        log("ICE", "local candidate: \(candidate.sdp)")
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        log("WebRTC", "remote opened data channel \(dataChannel.label)")
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        log("WebRTC", "connection state \(newState.rawValue)")
        onConnectionState?(newState)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        if let v = rtpReceiver.track as? RTCVideoTrack { log("WebRTC", "video track"); onVideoTrack?(v) }
        if let a = rtpReceiver.track as? RTCAudioTrack { log("WebRTC", "audio track"); onAudioTrack?(a) }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChangeLocalCandidate local: RTCIceCandidate, remoteCandidate remote: RTCIceCandidate, lastReceivedMs: Int32, changeReason reason: String) {
        log("ICE", "selected pair: local \(local.sdp) <-> remote \(remote.sdp) (\(reason))")
    }
}
