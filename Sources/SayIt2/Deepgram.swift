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
            throw Problem(message: "Deepgram url in the config is not valid", retryable: false)
        }
        var request = URLRequest(url: address)
        request.setValue("Token \(config.key(for: .deepgram) ?? "")", forHTTPHeaderField: "Authorization")
        return request
    }

    override func send(audio: Data) {
        send(.data(audio))
    }

    override func finish() {
        finishing = true
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
            // CloseStream flushes final results before Metadata. An unconfirmed draft is
            // still useful as an error fallback, but is not a successful final.
            if finishing {
                end(draft.isEmpty ? nil : Problem(message: "Deepgram did not confirm the final text", retryable: false))
            }
        default:
            break
        }
    }

    override func closed(status: Int) -> Problem {
        switch status {
        case 401: Problem(message: "Deepgram key rejected", retryable: false)
        case 403: Problem(message: "Deepgram: no access to this model", retryable: false)   // often a misspelled model name
        case 400: Problem(message: "Deepgram rejected the config", retryable: false)
        default: Problem(message: "Can't reach Deepgram")
        }
    }
}
