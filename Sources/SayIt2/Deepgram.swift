import Foundation

/// Deepgram live streaming: raw PCM16 16 kHz mono binary frames, JSON results.
/// The query parameters (model, language, formatting and so on) come from the config file.
final class DeepgramStream: Transcriber {
    private let config: Config
    private var finishing = false

    init(config: Config) {
        self.config = config
    }

    override func request() throws -> URLRequest {
        guard var url = URLComponents(string: config.deepgramURL) else {
            throw Problem(message: "Deepgram url in the config is not valid", retryable: false)
        }
        url.queryItems = config.deepgramParameters
        guard let address = url.url else { throw Problem(message: "Deepgram url in the config is not valid", retryable: false) }
        var request = URLRequest(url: address)
        request.setValue("Token \(config.deepgramKey ?? "")", forHTTPHeaderField: "Authorization")
        return request
    }

    override func send(audio: Data) {
        send(data: audio)
    }

    override func finish() {
        finishing = true
        send(text: #"{"type":"CloseStream"}"#)
    }

    override func received(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "Results":
            // A final replaces the live text for its stretch of audio: it is usually the better text.
            guard let channel = message["channel"] as? [String: Any],
                  let text = (channel["alternatives"] as? [[String: Any]])?.first?["transcript"] as? String else { return }
            if message["is_final"] as? Bool == true {
                let seconds = (message["start"] as? Double ?? 0) + (message["duration"] as? Double ?? 0)
                onFinal?(text, Int((seconds * Provider.deepgram.sampleRate).rounded()) * 2)
            } else {
                onInterim?(text)
            }
        case "Metadata":
            // Sent once everything after CloseStream has been flushed. Finals are now the whole
            // transcript, so interim text that no final confirmed is dropped.
            if finishing {
                onInterim?("")
                end(nil)
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
