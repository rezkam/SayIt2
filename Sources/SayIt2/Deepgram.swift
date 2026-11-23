import Foundation

/// Deepgram live streaming: raw PCM16 16 kHz mono binary frames, JSON results.
/// The query parameters (model, language, formatting and so on) come from the config file.
final class DeepgramStream: Transcriber {
    private let config: Config
    private var finishing = false
    private var coveredUntil = 0.0
    private var draft = ""
    private var draftStart = 0.0
    private var draftEnd = 0.0
    private var draftWords: [[String: Any]] = []

    init(config: Config) {
        self.config = config
    }

    override func request() throws -> URLRequest {
        var url = URLComponents(string: config.url(for: .deepgram))
        url?.queryItems = config.parameters(for: .deepgram)
        guard let address = url?.url else {
            throw Problem(message: "Deepgram url in the config is not valid", retryable: false, errorType: "invalid_config")
        }
        var request = URLRequest(url: address)
        request.setValue("Token \(config.key(for: .deepgram) ?? "")", forHTTPHeaderField: "Authorization")
        return request
    }

    override func send(audio: Data) {
        // Deepgram closes the socket if sent an empty binary frame.
        guard !audio.isEmpty else { return }
        send(.data(audio))
    }

    override func finish() {
        finishing = true
        span?.addEvent(name: "finish_requested")
        send(.string(#"{"type":"CloseStream"}"#))
    }

    override func received(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "Results":
            // A final replaces the live text for its stretch of audio: it is usually the better text.
            guard let channel = message["channel"] as? [String: Any],
                  let alternative = (channel["alternatives"] as? [[String: Any]])?.first,
                  let raw = alternative["transcript"] as? String else { return }
            let text = raw.allSatisfy(\.isWhitespace) ? "" : raw
            let start = message["start"] as? Double ?? 0
            let end = start + (message["duration"] as? Double ?? 0)
            if message["is_final"] as? Bool == true {
                // Silence can produce an empty result. It cannot confirm a draft with words.
                if text.isEmpty, !draft.isEmpty, end > draftStart { return }
                coveredUntil = max(coveredUntil, end)
                if draftEnd <= coveredUntil + 0.02 { draft = "" }
                onFinal?(text, Int((coveredUntil * Provider.deepgram.sampleRate).rounded()) * 2)
            } else if !text.isEmpty, end > coveredUntil {
                draft = text
                draftStart = start
                draftEnd = end
                draftWords = alternative["words"] as? [[String: Any]] ?? []
            }
            if draftStart < coveredUntil - 0.02, !draft.isEmpty {
                // Keep unconfirmed words after the final's audio boundary, not a string suffix.
                draftWords = draftWords.filter { ($0["start"] as? Double ?? 0) >= coveredUntil - 0.02 }
                draft = draftWords.compactMap { $0["punctuated_word"] as? String ?? $0["word"] as? String }.joined(separator: " ")
                draftStart = coveredUntil
            }
            onInterim?(draft)
        case "Metadata":
            if let id = message["request_id"] as? String, !id.isEmpty {
                span?.setAttribute(key: "sayit2.provider.request_id", value: id)
            }
            // CloseStream flushes final results before Metadata. An unconfirmed draft is
            // still useful as an error fallback, but is not a successful final.
            if finishing {
                end(draft.isEmpty ? nil : Problem(message: "Deepgram did not confirm the final text", retryable: false, errorType: "unconfirmed_final"))
            }
        case "Error":
            fail(message)
        default:
            if message["err_code"] != nil || message["error"] != nil { fail(message) }
        }
    }

    private func fail(_ message: [String: Any]) {
        let code = (message["err_code"] as? String ?? message["category"] as? String ?? "provider_error").trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = (message["err_msg"] as? String ?? message["description"] as? String ?? message["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        Telemetry.event("Deepgram error (\(code))\(detail.isEmpty ? "" : ": \(String(detail.prefix(160)))")", severity: .error, span: span)
        let upper = code.uppercased()
        if upper.contains("AUTH") || upper.contains("PERMISSION") {
            return end(Problem(message: "Deepgram key rejected", retryable: false, errorType: code))
        }
        if upper.contains("PAYMENT") || upper.contains("QUOTA") || upper.contains("INSUFFICIENT_FUNDS") {
            return end(Problem(message: "Deepgram quota or balance exceeded", retryable: false, errorType: code))
        }
        if upper.contains("BAD_REQUEST") || upper.contains("INVALID") || upper.hasPrefix("DATA-") {
            return end(Problem(message: "Deepgram rejected the config or audio", retryable: false, errorType: code))
        }
        end(Problem(message: "Deepgram connection interrupted", errorType: code))
    }

    override func closed(status: Int, closeCode: Int, reason: String?) -> Problem {
        switch status {
        case 401: return Problem(message: "Deepgram key rejected", retryable: false, errorType: "auth_error")
        case 402: return Problem(message: "Deepgram quota or balance exceeded", retryable: false, errorType: "quota_exceeded")
        case 403: return Problem(message: "Deepgram: no access to this model", retryable: false, errorType: "forbidden")
        case 400, 422: return Problem(message: "Deepgram rejected the config", retryable: false, errorType: "invalid_request")
        case 429: return Problem(message: "Deepgram rate limited", errorType: "rate_limited")
        case 500...599: return Problem(message: "Deepgram server error", errorType: "server_error")
        default: break
        }
        let why = reason ?? ""
        if closeCode == 1008 || why.contains("DATA-") {
            return Problem(message: "Deepgram rejected the audio format", retryable: false, errorType: "ws_1008_data")
        }
        if closeCode == 1009 {
            return Problem(message: "Deepgram audio frame too large", retryable: false, errorType: "ws_1009")
        }
        if closeCode == 1011 {
            let noAudio = why.contains("NET-0002") || why.contains("no_audio_timeout")
            return Problem(message: noAudio ? "Deepgram timed out waiting for audio" : "Deepgram connection interrupted",
                           errorType: noAudio ? "ws_1011_no_audio" : "ws_1011")
        }
        return Problem(message: "Can't reach Deepgram", errorType: closeCode > 0 ? "ws_\(closeCode)" : "connection_lost")
    }
}
