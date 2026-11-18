import Foundation

/// gssv session endpoints: /v5/sessions/{home|cloud}/... (Greenlight player/src/server/index.ts + desktop xcloudapi.ts).
struct SessionAPI {
    enum Kind: String { case home, cloud }

    let baseURL: String
    let gsToken: String
    let kind: Kind
    let deviceInfo: String
    var sessionPath: String = ""   // "v5/sessions/home/<id>"
    // Probe hooks (deep-merged into the requests; empty in normal use).
    var playBodyMerge: [String: Any] = [:]
    var sdpConfigMerge: [String: Any] = [:]
    var extraHeaders: [String: String] = [:]

    static func deepMerge(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
        var out = base
        for (k, v) in over {
            if v is NSNull { out.removeValue(forKey: k) }
            else if let a = out[k] as? [String: Any], let b = v as? [String: Any] { out[k] = deepMerge(a, b) }
            else { out[k] = v }
        }
        return out
    }

    var sessionId: String { sessionPath.split(separator: "/").last.map(String.init) ?? "" }

    private var headers: [String: String] {
        ["Accept": "application/json", "Content-Type": "application/json",
         "X-Gssv-Client": "XboxComBrowser", "X-MS-Device-Info": deviceInfo,
         "Authorization": "Bearer " + gsToken].merging(extraHeaders) { _, b in b }
    }

    private func url(_ suffix: String) -> String { baseURL + "/" + sessionPath + suffix }

    mutating func play(target: String, locale: String, osName: String) async throws -> String {
        let tz = TimeZone.current.secondsFromGMT() / 60
        var body: [String: Any] = [
            "clientSessionId": "",
            "titleId": kind == .cloud ? target : "",
            "systemUpdateGroup": "",
            "settings": ["nanoVersion": "V3;WebrtcTransport.dll", "enableOptionalDataCollection": false,
                         "enableTextToSpeech": false, "highContrast": 0, "locale": locale,
                         "useIceConnection": false, "timezoneOffsetMinutes": tz, "sdkType": "web", "osName": osName],
            "serverId": kind == .home ? target : "",
            "fallbackRegionNames": [],
        ]
        body = Self.deepMerge(body, playBodyMerge)
        let r = try await HTTP.request("POST", baseURL + "/v5/sessions/\(kind.rawValue)/play", headers: headers, body: HTTP.jsonBody(body))
        log("Session", "play -> \(r.text)")
        guard let obj = r.object as? [String: Any], let path = obj["sessionPath"] as? String else {
            throw HTTPError(status: r.status, url: "play", body: r.text)
        }
        sessionPath = path
        return path
    }

    func state() async throws -> [String: Any] {
        let r = try await HTTP.request("GET", url("/state"), headers: headers)
        return r.object as? [String: Any] ?? [:]
    }

    /// Polls `/state` until the session is Provisioned, sending the console transfer token once when it asks
    /// (ReadyToConnect). `onState` sees every state on the way; a Failed session or running out of polls throws.
    @MainActor
    func waitForProvisioned(pollNanoseconds: UInt64 = 1_000_000_000, maxPolls: Int = .max,
                            transferToken: () async throws -> String,
                            onState: (String) async -> Void = { _ in }) async throws {
        var sentConnect = false
        for _ in 0..<maxPolls {
            try Task.checkCancellation()
            let s = try await state()
            let state = s["state"] as? String ?? "?"
            switch state {
            case "Provisioned":
                return
            case "Failed":
                let details = s["errorDetails"] as? [String: Any]
                throw HTTPError(status: 0, url: "state", body: (details?["message"] as? String) ?? (details?["code"] as? String) ?? "Session failed: \(s)")
            case "ReadyToConnect":
                if !sentConnect {
                    sentConnect = true
                    await onState(state)
                    try await connect(userToken: try await transferToken())
                    log("Session", "sent /connect transfer token")
                }
            default:
                await onState(state)
            }
            try await Task.sleep(nanoseconds: pollNanoseconds)
        }
        throw HTTPError(status: 0, url: "state", body: "Timed out waiting for the session to be provisioned")
    }

    func connect(userToken: String) async throws {
        try await HTTP.request("POST", url("/connect"), headers: headers, body: HTTP.jsonBody(["userToken": userToken]))
    }

    func configuration() async throws -> [String: Any] {
        let r = try await HTTP.request("GET", url("/configuration"), headers: headers)
        return r.object as? [String: Any] ?? [:]
    }

    func waitTime(titleId: String) async throws -> [String: Any] {
        let r = try await HTTP.request("GET", baseURL + "/v1/waittime/" + titleId, headers: headers)
        return r.object as? [String: Any] ?? [:]
    }

    /// Posts the SDP offer, then polls GET /sdp until the answer is ready.
    func exchangeSDP(offer: String, chatOnly: Bool = false) async throws -> String {
        let (sdp, obj) = try await exchangeSDPDetailed(offer: offer, chatOnly: chatOnly)
        guard let sdp else { throw HTTPError(status: 0, url: "sdp", body: "No SDP answer: \(obj)") }
        return sdp
    }

    /// Returns the answer SDP (nil when the server didn't produce one) and the decoded exchange response.
    func exchangeSDPDetailed(offer: String, chatOnly: Bool = false, requestId: String = "1") async throws -> (sdp: String?, response: [String: Any]) {
        var config: [String: Any] = chatOnly ? ["isMediaStreamsChatRenegotiation": true] : [
            "chatConfiguration": ["bytesPerSample": 2, "expectedClipDurationMs": 20,
                                  "format": ["codec": "opus", "container": "webm"],
                                  "numChannels": 1, "sampleFrequencyHz": 24000],
            "chat": ["minVersion": 1, "maxVersion": 1],
            "control": ["minVersion": 1, "maxVersion": 3],
            // Greenlight desktop (the shipping app) negotiates input v1-8 on a single `input` channel.
            // Offering v9 also needs the `reliableinput`/`unreliableinput` channels, which we don't open: what goes on
            // which of them, and in what format, is not known yet (probes/unreliable-input.json is there to find out).
            "input": ["minVersion": 1, "maxVersion": 8],
            "message": ["minVersion": 1, "maxVersion": 1],
        ]
        config = Self.deepMerge(config, sdpConfigMerge)
        try await HTTP.request("POST", url("/sdp"), headers: headers,
                               body: HTTP.jsonBody(["messageType": "offer", "sdp": offer, "requestId": requestId, "configuration": config]))
        let obj = try await pollExchange("/sdp")
        var answer: [String: Any] = [:]
        if let exchange = obj["exchangeResponse"] as? String,
           let a = (try? JSONSerialization.jsonObject(with: Data(exchange.utf8))) as? [String: Any] { answer = a }
        if let status = answer["status"] as? String, status != "success" { log("Session", "SDP answer status: \(status)") }
        var response = answer
        response["_errorDetails"] = obj["errorDetails"]
        return (answer["sdp"] as? String, response)
    }

    /// Posts local ICE candidates, polls for the console's candidates.
    func exchangeICE(_ candidates: [[String: Any]]) async throws -> [[String: Any]] {
        try await HTTP.request("POST", url("/ice"), headers: headers,
                               body: HTTP.jsonBody(["messageType": "iceCandidate", "candidate": candidates]))
        let obj = try await pollExchange("/ice")
        guard let exchange = obj["exchangeResponse"] as? String,
              let list = (try? JSONSerialization.jsonObject(with: Data(exchange.utf8))) as? [[String: Any]] else {
            throw HTTPError(status: 0, url: "ice", body: "No ICE answer: \(obj)")
        }
        return list
    }

    private func pollExchange(_ suffix: String) async throws -> [String: Any] {
        for _ in 0..<60 {
            let r = try await HTTP.request("GET", url(suffix), headers: headers)
            if r.status == 200, let obj = r.object as? [String: Any] {
                if let err = obj["errorDetails"] as? [String: Any], let msg = err["message"] as? String, !msg.isEmpty {
                    log("Session", "\(suffix) errorDetails: \(err)")
                }
                return obj
            }
            try await Task.sleep(nanoseconds: 750_000_000)
        }
        throw HTTPError(status: 204, url: suffix, body: "Timed out waiting for exchange")
    }

    func keepalive() async throws {
        try await HTTP.request("POST", url("/keepalive"), headers: headers, body: HTTP.jsonBody([String: String]()))
    }

    func stop() async {
        guard !sessionPath.isEmpty else { return }
        _ = try? await HTTP.request("DELETE", url(""), headers: headers)
    }
}
