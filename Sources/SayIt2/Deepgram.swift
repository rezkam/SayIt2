import Foundation

/// Deepgram Nova-3 live streaming: raw PCM16 16 kHz mono binary frames, JSON results.
final class DeepgramStream: Transcriber {
    private let key: String
    private var finishing = false

    init(key: String) {
        self.key = key
    }

    override func request() throws -> URLRequest {
        var url = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        url.queryItems = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "language", value: "multi"),       // detects English and Persian
            URLQueryItem(name: "language_hint", value: "en"),
            URLQueryItem(name: "language_hint", value: "fa"),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: String(Int(Provider.deepgram.sampleRate))),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "interim_results", value: "true"), // required for live text; the default is false
            URLQueryItem(name: "endpointing", value: "300"),
            // No smart_format and no punctuate: plain lowercase text without punctuation.
        ]
        var request = URLRequest(url: url.url!)
        request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
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
            guard let channel = message["channel"] as? [String: Any],
                  let text = (channel["alternatives"] as? [[String: Any]])?.first?["transcript"] as? String else { return }
            if message["is_final"] as? Bool == true {
                let seconds = (message["start"] as? Double ?? 0) + (message["duration"] as? Double ?? 0)
                onFinal?(text, Int((seconds * Provider.deepgram.sampleRate).rounded()) * 2)
            } else {
                onInterim?(text)
            }
        case "Metadata":
            // Sent once everything after CloseStream has been flushed.
            if finishing { end(nil) }
        default:
            break
        }
    }

    override func closed(status: Int) -> Problem {
        status == 401 || status == 403
            ? Problem(message: "Deepgram key rejected", retryable: false)
            : Problem(message: "Can't reach Deepgram")
    }
}
