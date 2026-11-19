import Foundation
import os

let log = Logger(subsystem: "sayit2", category: "app")

/// Something went wrong in a way worth telling the user about.
struct Problem: Error {
    let message: String
    var retryable = true
}

enum Provider: String, CaseIterable {
    case chatgpt, deepgram

    var title: String { self == .chatgpt ? "ChatGPT" : "Deepgram Nova-3" }
    /// Wire sample rate: the rates the reference apps were captured using.
    var sampleRate: Double { self == .chatgpt ? 48000 : 16000 }
    /// Bytes per audio message: 2,048 samples for ChatGPT, 100 ms for Deepgram.
    var frameBytes: Int { self == .chatgpt ? 4096 : 3200 }
    /// ChatGPT sessions last 5 minutes, so recording finishes a little earlier.
    var maxSeconds: TimeInterval { self == .chatgpt ? 285 : .infinity }
}

/// Plain text settings in ~/.config/sayit2/config, one `key = value` per line.
enum Config {
    static let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/sayit2/config")

    static var provider: Provider {
        get {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            for line in text.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, parts[0] == "provider", let provider = Provider(rawValue: parts[1]) { return provider }
            }
            return .chatgpt
        }
        set {
            let text = "# SayIt 2 settings\n# provider = chatgpt or deepgram\nprovider = \(newValue.rawValue)\n"
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: file, atomically: true, encoding: .utf8)
        }
    }
}
