import Foundation

/// ChatGPT's dictation stream, as captured from the desktop app:
/// JSON text frames, PCM16 48 kHz mono audio as Base64 in `audio.append`.
final class ChatGPTStream: Transcriber {
    private var ready = false
    private var finishing = false
    private var utterances: [String] = []       // utterance ids in arrival order
    private var texts: [String: String] = [:]   // latest revision per utterance

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
        send(json: ["type": "session.close"])
    }

    override func received(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "session.started":
            ready = true
        case "transcript.segment", "transcript.final":
            // Each message carries the whole utterance so far; a newer revision replaces the older one.
            guard let id = message["utterance_id"] as? String, let text = message["text"] as? String else { return }
            if texts[id] == nil { utterances.append(id) }
            texts[id] = text
            onInterim?(utterances.compactMap { texts[$0]?.trimmingCharacters(in: .whitespaces) }.joined(separator: " "))
        case "session.updated":
            // Closed before all audio was handed over means the server gave up, not that it is done.
            if (message["session"] as? [String: Any])?["status"] as? String == "closed" {
                end(finishing ? nil : Problem(message: "ChatGPT closed the session"))
            }
        case "session.stop_requested":
            onStopRequested?()
        case "session.error":
            let code = (message["error"] as? [String: Any])?["code"] as? String ?? message["code"] as? String ?? "unknown"
            let fatal = message["fatal"] as? Bool == true
            log.notice("ChatGPT session error: \(code, privacy: .public), fatal \(fatal, privacy: .public)")
            if fatal || !ready { end(Problem(message: "ChatGPT error")) }
        case "transcript.failed":
            let code = (message["error"] as? [String: Any])?["code"] as? String ?? "unknown"
            log.notice("ChatGPT transcript failed: \(code, privacy: .public)")
            end(Problem(message: "ChatGPT could not transcribe"))
        default:
            break
        }
    }

    override func closed(status: Int) -> Problem {
        switch status {
        case 401: Problem(message: "ChatGPT sign-in expired", retryable: false, renewLogin: true)
        case 403: Problem(message: "ChatGPT refused the connection", retryable: false)
        default: Problem(message: "Can't reach ChatGPT")
        }
    }

    private func send(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        send(text: String(decoding: data, as: UTF8.self))
    }
}
