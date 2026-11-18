import Foundation
import QuartzCore

/// One displayed frame as this client measured it. All times are `CACurrentMediaTime()` values, the clock the
/// input channel stamps its packets with.
struct PresentedFrame: Equatable {
    /// RTP timestamp of the frame: the key the server matches the report to the frame it sent.
    var rtpTimestamp: UInt32
    /// When the decoded frame reached the renderer.
    var arrivedAt: CFTimeInterval
    /// When it was on screen.
    var presentedAt: CFTimeInterval
    /// How long the decoder took, when known. Without it the frame is reported as handed to the decoder and
    /// decoded at the same moment (which is also what Greenlight's browser player reports).
    var decodeMs: Double? = nil
    /// When the frame's first packet came off the network, when known; otherwise the moment it went to the decoder.
    var firstPacketAt: CFTimeInterval? = nil

    /// The report record, in milliseconds since `channelStart` (the input channel's time zero).
    func metadata(channelStart: CFTimeInterval) -> FrameMetadata {
        func ms(_ t: CFTimeInterval) -> Double { (t - channelStart) * 1000 }
        let decoded = ms(arrivedAt)
        let submitted = decoded - max(0, decodeMs ?? 0)
        return FrameMetadata(serverDataKey: rtpTimestamp, firstPacketArrivalMs: firstPacketAt.map(ms) ?? submitted,
                             submittedMs: submitted, decodedMs: decoded, renderedMs: max(decoded, ms(presentedAt)))
    }
}

/// Collects presented frames from the renderer (any thread) and reports them to the server on the WebRTC queue.
/// A frame is reported as soon as the rate limit allows; frames presented in between ride along in the same packet.
final class FrameFeedback: @unchecked Sendable {
    /// More frames than this waiting for one packet means the queue is stalled; the oldest are dropped.
    static let maxPending = 32

    let enabled: Bool
    private let queue: DispatchQueue
    private let minInterval: CFTimeInterval
    private let send: ([PresentedFrame]) -> Void
    private let lock = NSLock()
    private var pending: [PresentedFrame] = []
    private var flushScheduled = false
    private var lastFlush: CFTimeInterval = 0
    private var _decodeMs: Double?

    /// Decode time to report with each frame, when the session knows it (e.g. the stats' totalDecodeTime per frame).
    var decodeMs: Double? {
        get { lock.lock(); defer { lock.unlock() }; return _decodeMs }
        set { lock.lock(); _decodeMs = newValue; lock.unlock() }
    }

    /// `send` runs on `queue` with one batch per packet, oldest frame first.
    init(queue: DispatchQueue, enabled: Bool, maxPacketsPerSecond: Double = 120, send: @escaping ([PresentedFrame]) -> Void) {
        self.queue = queue
        self.enabled = enabled
        self.minInterval = 1 / max(1, maxPacketsPerSecond)
        self.send = send
    }

    convenience init(input: InputChannel, queue: DispatchQueue, enabled: Bool, maxPacketsPerSecond: Double = 120) {
        self.init(queue: queue, enabled: enabled, maxPacketsPerSecond: maxPacketsPerSecond) { [weak input] in input?.sendFrameMetadata($0) }
    }

    /// Shaped like the renderer's `onFramePresented`, so it can be assigned to it directly. Does nothing when feedback is off.
    func framePresented(rtpTimestamp: UInt32, arrivedAt: CFTimeInterval, presentedAt: CFTimeInterval) {
        guard enabled else { return }
        lock.lock()
        pending.append(PresentedFrame(rtpTimestamp: rtpTimestamp, arrivedAt: arrivedAt, presentedAt: presentedAt, decodeMs: _decodeMs))
        if pending.count > Self.maxPending { pending.removeFirst(pending.count - Self.maxPending) }
        let schedule = !flushScheduled
        flushScheduled = true
        let wait = max(0, lastFlush + minInterval - CACurrentMediaTime())
        lock.unlock()
        guard schedule else { return }
        if wait > 0 { queue.asyncAfter(deadline: .now() + wait) { self.flush() } } else { queue.async { self.flush() } }
    }

    private func flush() {
        lock.lock()
        let batch = pending
        pending = []
        flushScheduled = false
        lastFlush = CACurrentMediaTime()
        lock.unlock()
        if !batch.isEmpty { send(batch) }
    }
}
