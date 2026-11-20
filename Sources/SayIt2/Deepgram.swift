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
            guard let channel = message["channel"] as? [String: Any],
                  let best = (channel["alternatives"] as? [[String: Any]])?.first,
                  let text = best["transcript"] as? String else { return }
            let start = message["start"] as? Double ?? 0
            let end = start + (message["duration"] as? Double ?? 0)
            let words = (best["words"] as? [[String: Any]] ?? []).compactMap(Word.init)
            if message["is_final"] as? Bool == true {
                onFinal?(repairedFinal(text, words: words, start: start, end: end), Int((end * Provider.deepgram.sampleRate).rounded()) * 2)
            } else {
                interim = (start, words)
                onInterim?(Self.text(carried.filter { !$0.overlapsAny(words) && $0.end <= (words.first?.start ?? .infinity) + 0.05 }
                                     .map(\.text) + [text]))
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

    // MARK: Words Deepgram's final text skipped
    //
    // Deepgram sometimes finalizes a stretch of audio with fewer words than its own live text
    // had for it, most often at the boundary between two finalized stretches. The live words
    // and the final words are lined up by their text: where both agree on the words around a
    // gap and the final has nothing in the gap, the live words there were skipped and go back
    // in. Where the final has other words in the gap, those are a correction and win.

    private struct Word {
        let text: String
        let start: Double
        let end: Double

        init?(_ json: [String: Any]) {
            guard let text = json["punctuated_word"] as? String ?? json["word"] as? String,
                  let start = json["start"] as? Double, let end = json["end"] as? Double else { return nil }
            self.text = text
            self.start = start
            self.end = end
        }

        var key: String { text.lowercased().filter { $0.isLetter || $0.isNumber } }

        func overlapsAny(_ others: [Word]) -> Bool {
            others.contains { $0.start < end - 0.01 && start < $0.end - 0.01 }
        }
    }

    /// The newest live text: where its stretch starts, and its words.
    private var interim: (start: Double, words: [Word])?
    /// Live words from past the end of the last final, kept for the next stretch.
    private var carried: [Word] = []

    private func repairedFinal(_ text: String, words: [Word], start: Double, end: Double) -> String {
        let live = interim.map { abs($0.start - start) < 0.01 ? $0.words : [] } ?? []
        let heard = (carried.filter { !$0.overlapsAny(live) } + live).sorted { $0.start < $1.start }
        let merged = Self.merge(heard: heard, final: words, end: end)
        carried = merged.later
        interim = nil
        guard merged.restored > 0 else { return text }
        log.notice("restored \(merged.restored, privacy: .public) word(s) Deepgram's final text skipped")
        return Self.text(merged.words.map(\.text))
    }

    /// Lines up `heard` with `final` and puts back heard words the final skipped. Heard words
    /// that mostly lie past `end` belong to the next stretch and are returned as `later`.
    private static func merge(heard: [Word], final: [Word], end: Double) -> (words: [Word], restored: Int, later: [Word]) {
        // Longest common subsequence of the word texts.
        let n = heard.count, m = final.count
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = heard[i].key == final[j].key ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var result: [Word] = [], later: [Word] = [], restored = 0
        var i = 0, j = 0
        while i < n || j < m {
            // Collect one gap: the words up to the next pair both texts agree on.
            var gapHeard: [Word] = [], gapFinal: [Word] = []
            while i < n || j < m {
                if i < n, j < m, heard[i].key == final[j].key, table[i][j] == table[i + 1][j + 1] + 1 { break }
                if j < m, i == n || table[i][j + 1] >= table[i + 1][j] {
                    gapFinal.append(final[j]); j += 1
                } else {
                    gapHeard.append(heard[i]); i += 1
                }
            }
            let mine = gapHeard.filter { ($0.start + $0.end) / 2 < end }
            later += gapHeard.filter { ($0.start + $0.end) / 2 >= end }
            if gapFinal.isEmpty, !mine.isEmpty {
                result += mine
                restored += mine.count
            }
            result += gapFinal
            if i < n, j < m {   // the agreed pair
                result.append(final[j]); i += 1; j += 1
            }
        }
        return (result.sorted { $0.start < $1.start }, restored, later)
    }

    private static func text(_ parts: [String]) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: " ")
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
