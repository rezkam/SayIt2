import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk

/// Daily usage counters in ~/.local/share/sayit2/usage_stats.json, updated on `telemetryQueue`.
enum Usage {
    struct Bucket: Codable {
        var recordings = 0, seconds = 0.0, words = 0, characters = 0
        mutating func add(_ seconds: Double, _ words: Int, _ chars: Int) {
            recordings += 1; self.seconds += seconds; self.words += words; characters += chars
        }
    }

    struct Day: Codable {
        var recordings = 0, completed = 0, failed = 0, cancelled = 0, seconds = 0.0, words = 0, characters = 0
        var byModel: [String: Bucket] = [:], byLanguage: [String: Bucket] = [:], byHour: [String: Bucket] = [:]
        var byTrigger: [String: Bucket] = [:], byApp: [String: Bucket] = [:]
    }

    struct Store: Codable {
        var schemaVersion = 1
        var days: [String: Day] = [:]
    }

    /// Detects script of final text: "fa" (Arabic), "en" (Latin), "mixed" (both), or nil.
    static func language(of text: String) -> String? {
        var arabic = false, latin = false
        for s in text.unicodeScalars where s.properties.isAlphabetic {
            let v = s.value
            if (0x0600...0x06FF).contains(v) || (0x0750...0x077F).contains(v)
                || (0x08A0...0x08FF).contains(v) || (0xFB50...0xFDFF).contains(v)
                || (0xFE70...0xFEFF).contains(v) { arabic = true }
            else if (0x0041...0x005A).contains(v) || (0x0061...0x007A).contains(v)
                || (0x00C0...0x024F).contains(v) { latin = true }
            if arabic && latin { return "mixed" }
        }
        return arabic ? "fa" : (latin ? "en" : nil)
    }

    /// Updates usage_stats.json from one ended root dictation span. Must run on `telemetryQueue`.
    static func record(_ span: SpanData, in directory: URL) {
        let file = directory.appendingPathComponent("usage_stats.json")
        var store = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Store.self, from: $0) } ?? Store()
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour], from: span.startTime)
        let dayKey = String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
        let hourKey = String(format: "%02d", c.hour ?? 0)
        let a = span.attributes
        let secs: Double = if case .double(let d) = a["sayit2.audio.seconds"], d.isFinite { max(0, d) } else { 0 }
        let words: Int = if case .int(let n) = a["sayit2.text.words"] { max(0, n) } else { 0 }
        let chars: Int = if case .int(let n) = a["sayit2.text.characters"] { max(0, n) } else { 0 }

        var day = store.days[dayKey] ?? Day()
        day.recordings += 1; day.seconds += secs; day.words += words; day.characters += chars
        if case .string(let r) = a["sayit2.end_reason"] {
            if r == "completed" { day.completed += 1 } else if r == "failed" { day.failed += 1 } else if r == "cancelled" { day.cancelled += 1 }
        }
        let provider: String = if case .string(let p) = a["gen_ai.provider.name"] { p } else { "unknown" }
        let model = if provider == "deepgram", case .string(let m) = a["gen_ai.request.model"] { "deepgram/\(m)" } else { provider }
        day.byModel[model, default: Bucket()].add(secs, words, chars)
        day.byHour[hourKey, default: Bucket()].add(secs, words, chars)
        if case .string(let l) = a["sayit2.language"], !l.isEmpty { day.byLanguage[l, default: Bucket()].add(secs, words, chars) }
        if case .string(let t) = a["sayit2.trigger_mode"], !t.isEmpty { day.byTrigger[t, default: Bucket()].add(secs, words, chars) }
        if case .string(let b) = a["sayit2.target_app.bundle_id"], !b.isEmpty { day.byApp[b, default: Bucket()].add(secs, words, chars) }
        store.days[dayKey] = day

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let output = try? encoder.encode(store) else { return }
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            chmod(directory.path, 0o700)
        }
        let temp = directory.appendingPathComponent(".usage_stats.\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: output, attributes: [.posixPermissions: 0o600]),
              rename(temp.path, file.path) == 0 else {
            try? FileManager.default.removeItem(at: temp)
            return
        }
    }
}
