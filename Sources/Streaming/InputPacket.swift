import Foundation

/// Binary input report format used on the `input` data channel.
/// Port of Greenlight player/src/client/lib/channel/input/packet.ts.
struct GamepadFrame: Equatable {
    var index: UInt8 = 0
    var nexus = false, menu = false, view = false
    var a = false, b = false, x = false, y = false
    var dpadUp = false, dpadDown = false, dpadLeft = false, dpadRight = false
    var leftShoulder = false, rightShoulder = false, leftThumb = false, rightThumb = false
    /// -1...1, +Y is up (Xbox convention).
    var leftX: Float = 0, leftY: Float = 0, rightX: Float = 0, rightY: Float = 0
    /// 0...1
    var leftTrigger: Float = 0, rightTrigger: Float = 0

    var buttonMask: UInt16 {
        var m: UInt16 = 0
        if nexus { m |= 2 }; if menu { m |= 4 }; if view { m |= 8 }
        if a { m |= 16 }; if b { m |= 32 }; if x { m |= 64 }; if y { m |= 128 }
        if dpadUp { m |= 256 }; if dpadDown { m |= 512 }; if dpadLeft { m |= 1024 }; if dpadRight { m |= 2048 }
        if leftShoulder { m |= 4096 }; if rightShoulder { m |= 8192 }
        if leftThumb { m |= 16384 }; if rightThumb { m |= 32768 }
        return m
    }

    /// Merge two sources (e.g. controller + keyboard) into one pad.
    func merged(with o: GamepadFrame) -> GamepadFrame {
        var r = self
        r.nexus = nexus || o.nexus; r.menu = menu || o.menu; r.view = view || o.view
        r.a = a || o.a; r.b = b || o.b; r.x = x || o.x; r.y = y || o.y
        r.dpadUp = dpadUp || o.dpadUp; r.dpadDown = dpadDown || o.dpadDown
        r.dpadLeft = dpadLeft || o.dpadLeft; r.dpadRight = dpadRight || o.dpadRight
        r.leftShoulder = leftShoulder || o.leftShoulder; r.rightShoulder = rightShoulder || o.rightShoulder
        r.leftThumb = leftThumb || o.leftThumb; r.rightThumb = rightThumb || o.rightThumb
        func pick(_ a: Float, _ b: Float) -> Float { abs(a) >= abs(b) ? a : b }
        r.leftX = pick(leftX, o.leftX); r.leftY = pick(leftY, o.leftY)
        r.rightX = pick(rightX, o.rightX); r.rightY = pick(rightY, o.rightY)
        r.leftTrigger = max(leftTrigger, o.leftTrigger); r.rightTrigger = max(rightTrigger, o.rightTrigger)
        return r
    }
}

struct MouseFrame { var x: Int32, y: Int32, wheelX: Int32 = 0, wheelY: Int32 = 0, buttons: UInt8, relative: UInt8 = 0 }
struct KeyboardFrame { var pressed: Bool; var vkey: UInt8 }

/// One frame of the timing feedback report, with the fields Greenlight's input packet writes
/// (serverDataKey, firstFramePacketArrivalTimeMs, frameSubmittedTimeMs, frameDecodedTimeMs, frameRenderedTimeMs).
/// Times are milliseconds on the input channel's clock, the one the packet header's timestamp uses.
struct FrameMetadata: Equatable {
    /// The frame's RTP timestamp; the server uses it to find the frame the report is about.
    var serverDataKey: UInt32
    /// When the first packet of the frame arrived.
    var firstPacketArrivalMs: Double
    /// When the complete frame was handed to the decoder.
    var submittedMs: Double
    /// When the decoder returned it.
    var decodedMs: Double
    /// When it was shown.
    var renderedMs: Double
}

enum ReportType: UInt16 {
    case none = 0, metadata = 1, gamepad = 2, pointer = 4, clientMetadata = 8, serverMetadata = 16
    case mouse = 32, keyboard = 64, vibration = 128, sensor = 256
}

struct ByteWriter {
    var data = Data()
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func i16(_ v: Int16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u32be(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func i32(_ v: Int32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func f64(_ v: Double) { withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
}

enum InputPacket {
    static func axis(_ v: Float) -> Int16 {
        let s = (v * 32767).rounded()
        return Int16(max(-32767, min(32767, s.isNaN ? 0 : s)))
    }

    static func trigger(_ v: Float) -> UInt16 {
        if v <= 0 || v.isNaN { return 0 }
        if v >= 1 { return 65535 }
        return UInt16(v * 65535)
    }

    private static func header(_ w: inout ByteWriter, type: UInt16, sequence: UInt32, timestampMs: Double) {
        w.u16(type)
        w.u32(sequence)
        w.f64(timestampMs)
    }

    /// Per-frame timing feedback (report type 1), as the official web client sends for every displayed frame:
    /// count, then 7 × u32 per frame (RTP timestamp, then times in 0.1 ms units on the input channel's clock).
    /// The last two values of a frame are when the packet was written (Greenlight's framePacketTime and frameDateNow).
    /// At most 255 frames fit in a packet; any beyond that are left out.
    static func frameMetadata(sequence: UInt32, timestampMs: Double, frames: [FrameMetadata]) -> Data {
        var w = ByteWriter()
        header(&w, type: ReportType.metadata.rawValue, sequence: sequence, timestampMs: timestampMs)
        w.u8(UInt8(min(frames.count, 255)))
        func t(_ ms: Double) -> UInt32 { UInt32(truncatingIfNeeded: Int64(max(0, ms) * 10)) }
        for f in frames.prefix(255) {
            w.u32(f.serverDataKey)
            w.u32(t(f.firstPacketArrivalMs)); w.u32(t(f.submittedMs)); w.u32(t(f.decodedMs)); w.u32(t(f.renderedMs))
            w.u32(t(timestampMs)); w.u32(t(timestampMs))
        }
        return w.data
    }

    /// Client metadata report sent once when the input channel starts (15 bytes).
    static func clientMetadata(sequence: UInt32, timestampMs: Double, maxTouchPoints: UInt8 = 1) -> Data {
        var w = ByteWriter()
        header(&w, type: ReportType.clientMetadata.rawValue, sequence: sequence, timestampMs: timestampMs)
        w.u8(maxTouchPoints)
        return w.data
    }

    static func report(sequence: UInt32, timestampMs: Double, gamepads: [GamepadFrame] = [],
                       mouse: [MouseFrame] = [], keyboard: [KeyboardFrame] = []) -> Data {
        var type: UInt16 = 0
        if !gamepads.isEmpty { type |= ReportType.gamepad.rawValue }
        if !mouse.isEmpty { type |= ReportType.mouse.rawValue }
        if !keyboard.isEmpty { type |= ReportType.keyboard.rawValue }
        var w = ByteWriter()
        header(&w, type: type, sequence: sequence, timestampMs: timestampMs)
        if !gamepads.isEmpty {
            w.u8(UInt8(gamepads.count))
            for g in gamepads {
                w.u8(g.index)
                w.u16(g.buttonMask)
                w.i16(axis(g.leftX)); w.i16(axis(g.leftY))
                w.i16(axis(g.rightX)); w.i16(axis(g.rightY))
                w.u16(trigger(g.leftTrigger)); w.u16(trigger(g.rightTrigger))
                w.u32(1)      // PhysicalPhysicality
                w.u32be(1)    // VirtualPhysicality (Greenlight writes this big-endian)
            }
        }
        if !mouse.isEmpty {
            w.u8(UInt8(mouse.count))
            for m in mouse {
                w.i32(m.x); w.i32(m.y); w.i32(m.wheelX); w.i32(m.wheelY)
                w.u8(m.buttons); w.u8(m.relative)
            }
        }
        if !keyboard.isEmpty {
            w.u8(UInt8(keyboard.count))
            for k in keyboard {
                w.u8(2)   // 2 = VKey
                w.u8(k.pressed ? 1 : 0)
                w.u8(k.vkey)
            }
        }
        return w.data
    }
}
