import Foundation

/// ChatGPT's dictation stream, as captured from the desktop app:
/// JSON text frames, PCM16 48 kHz mono audio as Base64 in `audio.append`.
final class ChatGPTStream: Transcriber {
    private var ready = false
    private var finishing = false
    private var utterances: [String] = []       // utterance ids in arrival order
    private var drafts: [String: String] = [:]
    private var finals: [String: String] = [:]

    override var isReady: Bool { ready }

    override func request() throws -> URLRequest {
        let login = try Credentials.chatGPT()
        var request = URLRequest(url: URL(string: "wss://chatgpt.com/backend-api/dictation/stream?dictation_surface=composer&client_type=desktop")!)
        request.setValue("Bearer \(login.token)", forHTTPHeaderField: "Authorization")
        request.setValue(login.account, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        request.setValue("Codex Desktop/26.1111.21308 (Mac OS; arm64)", forHTTPHeaderField: "User-Agent")
        request.setValue("en-US", forHTTPHeaderField: "Accept-Language")
        request.setValue("chatgpt-dictation,codex-desktop", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        return request
    }

    override func opened() {
        send(json: [
            "type": "session.start",
            "dictation_session_id": UUID().uuidString.lowercased(),
            "attempt_id": UUID().uuidString.lowercased(),
            "client_capabilities": ["server_stop_requested"],
            "config": [
                "input_audio_format": "pcm16",
                "sample_rate_hz": Int(Provider.chatgpt.sampleRate),
                "num_channels": 1,
                "max_buffer_size_bytes": 4_194_304,
                "max_utterance_duration_ms": 30_000,
                "session_ttl_ms": 300_000,
                "provider_mode": "streaming_sse",
                "transcript_delivery_mode": "segment",
                "vad": ["type": "server_vad", "threshold": 0.5, "prefix_padding_ms": 300, "silence_duration_ms": 500],
            ],
        ])
    }

    override func send(audio: Data) {
        send(json: ["type": "audio.append", "audio": audio.base64EncodedString()])
    }

    override func finish() {
        finishing = true
        span?.addEvent(name: "finish_requested")
        send(json: ["type": "session.close"])
    }

    override func received(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "session.started":
            ready = true
            span?.addEvent(name: "session_started")
        case "transcript.segment", "transcript.final":
            guard let id = message["utterance_id"] as? String, let raw = message["text"] as? String else { return }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !utterances.contains(id) { utterances.append(id) }
            if !text.isEmpty {
                if message["type"] as? String == "transcript.final" { finals[id] = text }
                else if finals[id] == nil { drafts[id] = text }
            }
            onInterim?(utterances.compactMap { finals[$0] ?? drafts[$0] }.joined(separator: " "))
        case "session.updated":
            // Closed before all audio was handed over means the server gave up, not that it is done.
            if (message["session"] as? [String: Any])?["status"] as? String == "closed" {
                if !finishing { end(Problem(message: "ChatGPT closed the session", errorType: "unexpected_close")) }
                else if drafts.keys.contains(where: { finals[$0] == nil }) {
                    end(Problem(message: "ChatGPT did not confirm the final text", retryable: false, errorType: "unconfirmed_final"))
                } else { end(nil) }
            }
        case "session.stop_requested":
            span?.addEvent(name: "server_stop_requested")
            onStopRequested?()
        case "session.error":
            let code = (message["error"] as? [String: Any])?["code"] as? String ?? message["code"] as? String ?? "session_error"
            let fatal = message["fatal"] as? Bool == true
            Telemetry.event("ChatGPT session error: \(code), fatal \(fatal)", severity: fatal || !ready ? .error : .warn, span: span)
            if fatal || !ready { end(Problem(message: "ChatGPT error", errorType: code)) }
        case "transcript.failed":
            let code = (message["error"] as? [String: Any])?["code"] as? String ?? "transcript_failed"
            Telemetry.event("ChatGPT transcript failed: \(code)", severity: .error, span: span)
            end(Problem(message: "ChatGPT could not transcribe", errorType: code))
        default:
            break
        }
    }

    override func closed(status: Int, closeCode: Int, reason: String?) -> Problem {
        switch status {
        case 401: return Problem(message: "ChatGPT sign-in expired", retryable: false, errorType: "auth_expired", renewLogin: true)
        case 403: return Problem(message: "ChatGPT refused the connection", retryable: false, errorType: "auth_forbidden")
        case 400, 422: return Problem(message: "ChatGPT rejected the request", retryable: false, errorType: "invalid_request")
        case 429: return Problem(message: "ChatGPT rate limited", errorType: "rate_limited")
        case 500...599: return Problem(message: "ChatGPT server error", errorType: "server_error")
        default: return Problem(message: "Can't reach ChatGPT", errorType: closeCode > 0 ? "ws_\(closeCode)" : "connection_lost")
        }
    }

    private func send(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        send(.string(String(decoding: data, as: UTF8.self)))
    }
}
