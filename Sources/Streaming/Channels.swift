import Foundation
import WebRTC
import QuartzCore

/// A data channel to open besides the standard four (probe hook, see `WebRTCClient.Options.extraDataChannels`).
struct DataChannelSpec {
    var label: String
    var protocolName: String
    var ordered = true
    /// nil = reliable; 0 = every message is sent once and never resent.
    var maxRetransmits: Int? = nil
}

/// Base wrapper for an RTCDataChannel (Greenlight channel/channel.ts).
class DataChannel: NSObject, RTCDataChannelDelegate {
    let name: String
    let channel: RTCDataChannel
    let queue: DispatchQueue
    var onOpen: (() -> Void)?
    /// Sees what the default `didReceive` gets, i.e. messages no subclass handles; probe hook.
    var onUnhandled: ((Data) -> Void)?

    struct SetupError: LocalizedError {
        let what: String
        var errorDescription: String? { "Couldn't set up the connection (\(what))." }
    }

    init(pc: RTCPeerConnection, name: String, protocolName: String, ordered: Bool = true, maxRetransmits: Int? = nil, queue: DispatchQueue) throws {
        self.name = name
        self.queue = queue
        let cfg = RTCDataChannelConfiguration()
        cfg.isOrdered = ordered
        if let maxRetransmits { cfg.maxRetransmits = Int32(maxRetransmits) }
        cfg.`protocol` = protocolName
        guard let channel = pc.dataChannel(forLabel: name, configuration: cfg) else { throw SetupError(what: "data channel \(name)") }
        self.channel = channel
        super.init()
        channel.delegate = self
    }

    var isOpen: Bool { channel.readyState == .open }

    /// Greenlight sends strings as UTF-8 *binary* frames (TextEncoder); we do the same.
    func send(_ text: String) { send(Data(text.utf8)) }

    func send(_ data: Data) {
        guard isOpen else { log(name, "send while not open (state \(channel.readyState.rawValue))"); return }
        channel.sendData(RTCDataBuffer(data: data, isBinary: true))
        DiagnosticsRecorder.current?.recordDataChannel(name, .send, data, binary: true)
    }

    func sendJSON(_ obj: [String: Any]) {
        send(String(data: HTTP.jsonBody(obj), encoding: .utf8)!)
    }

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        log(name, "state -> \(dataChannel.readyState.rawValue)")
        if dataChannel.readyState == .open { queue.async { self.didOpen(); self.onOpen?() } }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let d = buffer.data
        DiagnosticsRecorder.current?.recordDataChannel(name, .recv, d, binary: buffer.isBinary)
        queue.async { self.didReceive(d, binary: buffer.isBinary) }
    }

    func didOpen() {}
    func didReceive(_ data: Data, binary: Bool) {
        log(name, "recv \(data.count) bytes")
        DiagnosticsRecorder.current?.noteUnhandled("\(name) recv (no handler)")
        onUnhandled?(data)
    }
    func close() { channel.close() }
}

/// `control` channel: authorization, gamepad add/remove, keyframe requests.
final class ControlChannel: DataChannel {
    init(pc: RTCPeerConnection, queue: DispatchQueue) throws {
        try super.init(pc: pc, name: "control", protocolName: "controlV1", queue: queue)
    }

    func sendAuthorization() {
        sendJSON(["message": "authorizationRequest", "accessKey": "4BDB3609-C1F1-4195-9B37-FEFF45DA8B8E"])
    }

    func gamepadChanged(index: Int, added: Bool) {
        log("control", "gamepad \(index) \(added ? "added" : "removed")")
        sendJSON(["message": "gamepadChanged", "gamepadIndex": index, "wasAdded": added])
    }

    /// Asks the server for a resolution tier: "720", "720HQ", "1080", "1080HQ" or "1440".
    func requestResolution(_ alias: String) {
        sendJSON(["message": "userRequestedResolutionUpdate", "resolutionAlias": alias])
    }

    func requestKeyframe() {
        sendJSON(["message": "videoKeyframeRequested", "ifrRequested": true])
    }

    override func didReceive(_ data: Data, binary: Bool) {
        log("control", "recv: \(String(data: data, encoding: .utf8) ?? "\(data.count) bytes")")
        DiagnosticsRecorder.current?.noteUnhandled("control recv (logged only): \((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] ?? "?")")
    }
}

/// `message` channel: handshake, client config, transactions (Greenlight channel/message.ts + handler.ts).
final class MessageChannel: DataChannel {
    var onHandshake: (() -> Void)?
    var onServerDisconnect: (() -> Void)?
    var onDialog: ((_ id: String, _ title: String, _ text: String, _ buttons: [String]) -> Void)?
    var requestedSize: (width: Int, height: Int) = (1920, 1080)
    /// Content of the clientdevicecapabilities message (Greenlight sends `{}`); probe hook.
    var deviceCapabilities: [String: Any] = [:]
    /// Extra (target, content) messages sent after the standard configuration; probe hook.
    var extraMessages: [(String, [String: Any])] = []

    init(pc: RTCPeerConnection, queue: DispatchQueue) throws {
        try super.init(pc: pc, name: "message", protocolName: "messageV1", queue: queue)
    }

    override func didOpen() {
        log("message", "sending handshake")
        sendJSON(["type": "Handshake", "version": "messageV1", "id": "be0bfc6d-1e83-4c8a-90ed-fa8601c5a179", "cv": "0"])
    }

    override func didReceive(_ data: Data, binary: Bool) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let type = obj["type"] as? String else {
            log("message", "unparseable message: \(String(data: data, encoding: .utf8) ?? "")"); return
        }
        switch type {
        case "HandshakeAck":
            log("message", "handshake completed")
            onHandshake?()
            sendConfig()
        case "TransactionStart", "Message":
            handle(obj)
        default:
            log("message", "unhandled type \(type): \(obj)")
            DiagnosticsRecorder.current?.noteUnhandled("message type \(type)")
        }
    }

    func message(_ target: String, _ content: [String: Any]) -> [String: Any] {
        ["type": "Message", "content": String(data: HTTP.jsonBody(content), encoding: .utf8)!,
         "id": UUID().uuidString.lowercased(), "target": target, "cv": ""]
    }

    func sendConfig() {
        sendJSON(message("/streaming/systemUi/configuration", ["version": [0, 2, 0], "systemUis": [Int]()]))
        sendJSON(message("/streaming/properties/clientappinstallidchanged", ["clientAppInstallId": "c97d7ee0-73b2-4239-bf1d-9d805a338429"]))
        sendJSON(message("/streaming/characteristics/orientationchanged", ["orientation": 0]))
        sendJSON(message("/streaming/characteristics/touchinputenabledchanged", ["touchInputEnabled": false]))
        sendJSON(message("/streaming/characteristics/clientdevicecapabilities", deviceCapabilities))
        sendDimensions()
        for (target, content) in extraMessages { sendJSON(message(target, content)) }
    }

    func sendDimensions() {
        let (w, h) = requestedSize
        log("message", "dimensionschanged \(w)x\(h) (supportsCustomResolution)")
        sendJSON(message("/streaming/characteristics/dimensionschanged", [
            "horizontal": w, "vertical": h, "preferredWidth": w, "preferredHeight": h,
            "safeAreaLeft": 0, "safeAreaTop": 0, "safeAreaRight": w, "safeAreaBottom": h,
            "supportsCustomResolution": true,
        ]))
    }

    private func handle(_ obj: [String: Any]) {
        let target = obj["target"] as? String ?? ""
        let id = obj["id"] as? String ?? ""
        let content = (obj["content"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any] ?? [:]
        switch target {
        case "/streaming/sessionLifetimeManagement/serverInitiatedDisconnect":
            log("message", "server initiated disconnect: \(content)")
            completeTransaction(id, "")
            onServerDisconnect?()
        case "/streaming/properties/titleinfo":
            log("message", "title info: \(content)")
        case "/streaming/systemUi/messages/ShowMessageDialog":
            let title = content["TitleText"] as? String ?? ""
            let text = content["ContentText"] as? String ?? ""
            var buttons: [String] = []
            for k in ["CommandLabel1", "CommandLabel2", "CommandLabel3"] { if let b = content[k] as? String, !b.isEmpty { buttons.append(b) } }
            onDialog?(id, title, text, buttons)
        default:
            log("message", "unhandled transaction \(target): \(content)")
            DiagnosticsRecorder.current?.noteUnhandled("message target \(target)")
        }
    }

    /// Greenlight sends `JSON.stringify(data)` as content (so "" becomes "\"\"").
    func completeTransaction(_ id: String, _ content: Any) {
        let c: String
        if let s = content as? String {
            c = String(data: (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8), encoding: .utf8)!
        } else {
            c = String(data: HTTP.jsonBody(content), encoding: .utf8)!
        }
        sendJSON(["type": "TransactionComplete", "content": c, "id": id, "cv": ""])
    }
}

/// `input` channel: binary input reports out; vibration + server metadata in.
final class InputChannel: DataChannel {
    struct Vibration {
        let gamepadIndex: Int
        let leftMotor: Float, rightMotor: Float, leftTrigger: Float, rightTrigger: Float
        let durationMs: Int, delayMs: Int, repeatCount: Int
    }

    private var sequence: UInt32 = 0
    /// Time zero of the packet timestamps, on the `CACurrentMediaTime()` clock (monotonic, like the web client's
    /// performance.now()), so frame times measured by the renderer convert without a second clock.
    let start = CACurrentMediaTime()
    var onVibration: ((Vibration) -> Void)?
    var onServerVideoSize: ((_ width: Int, _ height: Int) -> Void)?

    init(pc: RTCPeerConnection, queue: DispatchQueue) throws {
        try super.init(pc: pc, name: "input", protocolName: "1.0", queue: queue)
    }

    private var now: Double { (CACurrentMediaTime() - start) * 1000 }
    private func nextSeq() -> UInt32 { sequence &+= 1; return sequence }

    func sendClientMetadata() {
        send(InputPacket.clientMetadata(sequence: 0, timestampMs: now, maxTouchPoints: 1))
    }

    /// Reports displayed frames to the server (report type 1), several per packet if need be, oldest first.
    /// Call on the WebRTC queue; `FrameFeedback` does that for frames coming from the renderer.
    func sendFrameMetadata(_ frames: [PresentedFrame]) {
        guard isOpen, !frames.isEmpty else { return }
        send(InputPacket.frameMetadata(sequence: nextSeq(), timestampMs: now, frames: frames.map { $0.metadata(channelStart: start) }))
    }

    func send(gamepads: [GamepadFrame] = [], mouse: [MouseFrame] = [], keyboard: [KeyboardFrame] = []) {
        guard isOpen, !(gamepads.isEmpty && mouse.isEmpty && keyboard.isEmpty) else { return }
        send(InputPacket.report(sequence: nextSeq(), timestampMs: now, gamepads: gamepads, mouse: mouse, keyboard: keyboard))
    }

    override func didReceive(_ data: Data, binary: Bool) {
        guard data.count >= 2 else { return }
        let b = [UInt8](data)
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 }
        let type = b[0]   // Greenlight reads the report type as the first byte
        if type == UInt8(ReportType.vibration.rawValue), b.count >= 13 {
            let v = Vibration(gamepadIndex: Int(b[3]), leftMotor: Float(b[4]) / 100, rightMotor: Float(b[5]) / 100,
                              leftTrigger: Float(b[6]) / 100, rightTrigger: Float(b[7]) / 100,
                              durationMs: u16(8), delayMs: u16(10), repeatCount: Int(b[12]))
            onVibration?(v)
        } else if type == UInt8(ReportType.serverMetadata.rawValue), b.count >= 10 {
            let h = u32(2), w = u32(6)
            log("input", "server metadata: video \(w)x\(h)")
            DiagnosticsRecorder.current?.recordServerVideoSize(w, h)
            onServerVideoSize?(w, h)
        } else {
            log("input", "recv report type \(type), \(b.count) bytes")
            DiagnosticsRecorder.current?.noteUnhandled("input report type \(type)")
        }
    }
}

/// `chat` channel. Opened so the console negotiates it; mic capture isn't wired up yet.
final class ChatChannel: DataChannel {
    init(pc: RTCPeerConnection, queue: DispatchQueue) throws {
        try super.init(pc: pc, name: "chat", protocolName: "chatV1", queue: queue)
    }
}
