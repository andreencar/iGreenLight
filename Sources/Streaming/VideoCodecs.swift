import Foundation
import WebRTC
import VideoToolbox
import CoreMedia

/// Video decoder factory: libwebrtc's defaults (H.264 via VideoToolbox, VP8/VP9 via libvpx, AV1 via dav1d)
/// plus codecs the stasel/WebRTC build can depacketize but doesn't advertise:
/// * H.264 Main (4d) and High level 5.1 (640033) — decoded by the stock VideoToolbox H.264 decoder
/// * H.265 Main (profile-id 1) and Main 10 (profile-id 2) — decoded by `VTHEVCDecoder` below
/// Every decoder is wrapped in `InspectingDecoder` so diagnostics can parse parameter sets from the bitstream.
final class AppVideoDecoderFactory: NSObject, RTCVideoDecoderFactory {
    private let base = RTCDefaultVideoDecoderFactory()

    static let extraCodecs: [RTCVideoCodecInfo] = [
        RTCVideoCodecInfo(name: "H264", parameters: ["profile-level-id": "640033", "level-asymmetry-allowed": "1", "packetization-mode": "1"]),
        RTCVideoCodecInfo(name: "H264", parameters: ["profile-level-id": "4d0033", "level-asymmetry-allowed": "1", "packetization-mode": "1"]),
        RTCVideoCodecInfo(name: "H265", parameters: ["profile-id": "1", "tier-flag": "0", "level-id": "153", "tx-mode": "SRST"]),
        RTCVideoCodecInfo(name: "H265", parameters: ["profile-id": "2", "tier-flag": "0", "level-id": "153", "tx-mode": "SRST"]),
    ]

    func supportedCodecs() -> [RTCVideoCodecInfo] {
        var list = base.supportedCodecs()
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) { list += Self.extraCodecs } else { list += Self.extraCodecs.filter { $0.name == "H264" } }
        return list
    }

    func createDecoder(_ info: RTCVideoCodecInfo) -> RTCVideoDecoder? {
        let inner: RTCVideoDecoder?
        if info.name.uppercased() == "H265" { inner = VTHEVCDecoder(profileId: info.parameters["profile-id"] ?? "1") }
        else { inner = base.createDecoder(info) }
        guard let inner else { return nil }
        // libwebrtc only runs its native (libvpx / dav1d) decoders when it gets the original RTCWrappedNativeVideoDecoder
        // back; wrapping those breaks decoding. So only ObjC decoders (VideoToolbox H.264, our HEVC) are inspected.
        let cls = NSStringFromClass(object_getClass(inner as AnyObject) ?? NSObject.self)
        log("Codec", "createDecoder \(info.name) \(info.parameters) -> \(cls)")
        if cls.contains("WrappedNative") || info.name.uppercased() != "H264" && info.name.uppercased() != "H265" { return inner }
        return InspectingDecoder(inner: inner, codec: info.name)
    }
}

/// Forwards to the real decoder; while diagnostics are recording, parses SPS/VPS/SEI/VP9 headers from keyframes.
final class InspectingDecoder: NSObject, RTCVideoDecoder {
    private let inner: RTCVideoDecoder
    private let codec: String
    private var inspected = 0

    init(inner: RTCVideoDecoder, codec: String) { self.inner = inner; self.codec = codec }

    func setCallback(_ callback: @escaping RTCVideoDecoderCallback) { inner.setCallback(callback) }
    func startDecode(withNumberOfCores numberOfCores: Int32) -> Int { inner.startDecode(withNumberOfCores: numberOfCores) }
    func release() -> Int { inner.release() }
    func implementationName() -> String { inner.implementationName() }

    func decode(_ encodedImage: RTCEncodedImage, missingFrames: Bool, codecSpecificInfo info: RTCCodecSpecificInfo?, renderTimeMs: Int64) -> Int {
        if let rec = DiagnosticsRecorder.current {
            inspected += 1
            // Every keyframe (parameter sets usually ride along) plus the first frames (SEI may be on any frame).
            if encodedImage.frameType == .videoFrameKey || inspected <= 30 || inspected % 600 == 0 {
                for var unit in Bitstream.inspect(codec: codec, data: encodedImage.buffer) {
                    unit["frameType"] = encodedImage.frameType == .videoFrameKey ? "key" : "delta"
                    unit["encodedSize"] = "\(encodedImage.encodedWidth)x\(encodedImage.encodedHeight)"
                    if let qp = encodedImage.value(forKey: "qp") as? NSNumber { unit["qp"] = qp }   // declared nonnull, but nil in practice
                    rec.recordBitstream(unit)
                }
            }
        }
        return inner.decode(encodedImage, missingFrames: missingFrames, codecSpecificInfo: info, renderTimeMs: renderTimeMs)
    }
}

/// Minimal VideoToolbox HEVC decoder for libwebrtc (Annex B in, CVPixelBuffer out).
/// Main 10 streams decode to `x420` (10-bit 4:2:0 biplanar); Main to `420v`.
final class VTHEVCDecoder: NSObject, RTCVideoDecoder {
    private var callback: RTCVideoDecoderCallback?
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var paramSets: [Data] = []
    private let profileId: String
    private var bitDepth = 8
    private var loggedFormat = false

    init(profileId: String) { self.profileId = profileId }

    func setCallback(_ callback: @escaping RTCVideoDecoderCallback) { self.callback = callback }
    func startDecode(withNumberOfCores numberOfCores: Int32) -> Int { 0 }
    func implementationName() -> String { "VideoToolbox HEVC (iGreenLight)" }

    func release() -> Int {
        if let s = session { VTDecompressionSessionWaitForAsynchronousFrames(s); VTDecompressionSessionInvalidate(s) }
        session = nil; format = nil
        return 0
    }

    func decode(_ encodedImage: RTCEncodedImage, missingFrames: Bool, codecSpecificInfo info: RTCCodecSpecificInfo?, renderTimeMs: Int64) -> Int {
        let nals = Bitstream.nalUnits(encodedImage.buffer)
        var vps: Data?, sps: Data?, pps: Data?
        var body: [Data] = []
        for n in nals where n.count > 2 {
            switch Int(n[n.startIndex] >> 1) & 0x3f {
            case 32: vps = n
            case 33: sps = n
            case 34: pps = n
            default: body.append(n)
            }
        }
        if let vps, let sps, let pps, [vps, sps, pps] != paramSets {
            if let s = session { VTDecompressionSessionWaitForAsynchronousFrames(s); VTDecompressionSessionInvalidate(s); session = nil }
            var info: [String: Any] = [:]
            try? Bitstream.h265SPS(Bitstream.rbsp(sps, from: 2), into: &info)
            bitDepth = info["bitDepthLuma"] as? Int ?? (profileId == "2" ? 10 : 8)
            guard makeSession(vps: vps, sps: sps, pps: pps) else { return -1 }
            paramSets = [vps, sps, pps]
        }
        guard let session, let format, !body.isEmpty else { return session == nil ? -1 : 0 }   // -1 → libwebrtc requests a keyframe

        // Annex B → 4-byte length prefixes.
        var avcc = Data()
        for n in body {
            var len = UInt32(n.count).bigEndian
            avcc.append(Data(bytes: &len, count: 4)); avcc.append(n)
        }
        var block: CMBlockBuffer?
        let count = avcc.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: count, flags: 0, blockBufferOut: &block) == noErr,
              let block else { return -1 }
        _ = avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: count) }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: renderTimeMs, timescale: 1000), decodeTimeStamp: .invalid)
        var size = count
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
                                        sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { return -1 }
        let rtpTimestamp = encodedImage.timeStamp
        let cb = callback
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { [weak self] status, _, image, pts, _ in
            guard status == noErr, let image else {
                if status != noErr { log("Codec", "HEVC decode error \(status)") }
                return
            }
            if let self, !self.loggedFormat {
                self.loggedFormat = true
                log("Codec", "HEVC decoded \(CVPixelBufferGetWidth(image))x\(CVPixelBufferGetHeight(image)) \(FrameInspector.fourCC(CVPixelBufferGetPixelFormatType(image)))")
            }
            let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: image), rotation: ._0,
                                      timeStampNs: Int64(CMTimeGetSeconds(pts) * 1_000_000_000))
            frame.timeStamp = Int32(bitPattern: rtpTimestamp)
            cb?(frame)
        }
        if status != noErr {
            log("Codec", "VTDecompressionSessionDecodeFrame failed \(status)")
            if status == kVTInvalidSessionErr { self.session = nil; paramSets = [] }
            return -1
        }
        return 0
    }

    private func makeSession(vps: Data, sps: Data, pps: Data) -> Bool {
        var fmt: CMFormatDescription?
        let sets = [vps, sps, pps]
        let status: OSStatus = sets[0].withUnsafeBytes { v in sets[1].withUnsafeBytes { s in sets[2].withUnsafeBytes { p in
            let ptrs = [v.bindMemory(to: UInt8.self).baseAddress!, s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
            let sizes = sets.map(\.count)
            return CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: 3, parameterSetPointers: ptrs,
                                                                      parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil,
                                                                      formatDescriptionOut: &fmt)
        } } }
        guard status == noErr, let fmt else { log("Codec", "HEVC format description failed \(status)"); return false }
        let ext = CMFormatDescriptionGetExtensions(fmt) as? [String: Any] ?? [:]
        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        log("Codec", "HEVC stream \(dims.width)x\(dims.height), \(bitDepth)-bit, extensions: \(ext.filter { !$0.key.contains("SampleDescriptionExtensionAtoms") })")
        DiagnosticsRecorder.current?.event("hevcFormatDescription", ["width": Int(dims.width), "height": Int(dims.height), "bitDepth": bitDepth,
                                                                     "extensions": ext.filter { !$0.key.contains("SampleDescriptionExtensionAtoms") }.mapValues { "\($0)" }])
        let pixelFormat = bitDepth > 8 ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                                    kCVPixelBufferMetalCompatibilityKey as String: true,
                                    kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        let spec: [String: Any] = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: true]
        var s: VTDecompressionSession?
        let st = VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt, decoderSpecification: spec as CFDictionary,
                                              imageBufferAttributes: attrs as CFDictionary, outputCallback: nil, decompressionSessionOut: &s)
        guard st == noErr, let s else { log("Codec", "VTDecompressionSessionCreate failed \(st)"); return false }
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = s; format = fmt
        return true
    }
}

/// Codec ordering for the video transceiver (the offer's m=video payload order).
enum CodecOrdering {
    /// `rtx`: also offer retransmission. The capabilities carry one generic `rtx` entry; with it in the preferences
    /// libwebrtc writes an rtx payload type with `apt=` for every video codec in the offer.
    static func preferences(_ pref: VideoCodecPreference, onlyPreferred: Bool, rtx: Bool = false, factory: RTCPeerConnectionFactory) -> [RTCRtpCodecCapability] {
        let caps = factory.rtpReceiverCapabilities(forKind: kRTCMediaStreamTrackKindVideo).codecs
        func plid(_ c: RTCRtpCodecCapability) -> String { (c.parameters["profile-level-id"] ?? "").lowercased() }
        func h264(_ prefix: String) -> [RTCRtpCodecCapability] { caps.filter { $0.name.uppercased() == "H264" && plid($0).hasPrefix(prefix) } }
        func named(_ n: String, _ key: String? = nil, _ value: String? = nil) -> [RTCRtpCodecCapability] {
            caps.filter { $0.name.uppercased() == n && (key == nil || $0.parameters[key!] == value) }
        }
        // Default = the order the app shipped with (stock caps: High 640c1f → constrained baseline → baseline).
        let defaultH264 = h264("640c") + h264("42e") + h264("420")
        let preferred: [RTCRtpCodecCapability]
        switch pref {
        case .h264High: preferred = h264("640c")
        case .h264High51: preferred = h264("6400")
        case .h264Main: preferred = h264("4d")
        case .h264Baseline: preferred = h264("42e") + h264("420")
        case .hevcMain: preferred = named("H265", "profile-id", "1")
        case .hevcMain10: preferred = named("H265", "profile-id", "2")
        case .vp9p0: preferred = named("VP9", "profile-id", "0")
        case .vp9p2: preferred = named("VP9", "profile-id", "2")
        case .av1: preferred = named("AV1")
        }
        // Same FEC set as before (no RED, RTX only on request), then VP9/VP8 as the last fallbacks.
        let fec = caps.filter { ["ULPFEC", "FLEXFEC-03"].contains($0.name.uppercased()) || rtx && $0.name.uppercased() == "RTX" }
        var out = preferred
        if !onlyPreferred {
            for c in defaultH264 where !out.contains(where: { $0 === c }) { out.append(c) }
        }
        out += fec
        if !onlyPreferred {
            for c in named("VP9", "profile-id", "0") + named("VP8") where !out.contains(where: { $0 === c }) { out.append(c) }
        }
        if out.allSatisfy({ fec.contains($0) }) { log("Codec", "preferred codec \(pref.rawValue) not available; using default order"); out = defaultH264 + fec }
        return out
    }
}
