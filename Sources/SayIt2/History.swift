import AppKit

/// The text of recent dictations, newest first, kept in ~/.local/share/sayit2/recent.json
/// (readable only by the user) so it survives a restart. The menu offers the last 10 and the
/// dashboard lists them all; both copy a text to the clipboard on request.
@MainActor
enum History {
    struct Entry: Codable {
        let id: String
        let time: Date
        let text: String
        let provider: String
        /// "inserted", "failed" (the text may not have reached its field), "discarded" (its field
        /// never got focus back), or "cancelled" (Esc).
        var outcome: String
    }

    static let limit = 100
    private static var file: URL { Telemetry.dataDirectory.appendingPathComponent("recent.json") }
    private(set) static var entries: [Entry] = load()

    /// Remembers a dictation's text and returns its entry's id. Empty text is not kept.
    @discardableResult
    static func add(_ text: String, provider: String, outcome: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let id = UUID().uuidString
        entries.insert(Entry(id: id, time: Date(), text: text, provider: provider, outcome: outcome), at: 0)
        entries = Array(entries.prefix(limit))
        save()
        return id
    }

    static func mark(_ id: String, outcome: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].outcome = outcome
        save()
    }

    static func clear() {
        entries = []
        save()
    }

    /// Puts text on the general pasteboard for the user to paste. Insertion never uses this.
    @discardableResult
    static func copy(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    static var json: Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(["entries": entries])) ?? Data("{\"entries\":[]}".utf8)
    }

    private static func load() -> [Entry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: file),
              let stored = try? decoder.decode([String: [Entry]].self, from: data) else { return [] }
        return stored["entries"] ?? []
    }

    private static func save() {
        let directory = Telemetry.dataDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temp = directory.appendingPathComponent(".recent.\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: json, attributes: [.posixPermissions: 0o600]),
              rename(temp.path, file.path) == 0 else {
            try? FileManager.default.removeItem(at: temp)
            Telemetry.event("recent texts could not be saved", severity: .error)
            return
        }
    }
}
