import Foundation
import SQLite3
import os

/// Serial queue for every telemetry write and usage update.
let telemetryQueue = DispatchQueue(label: "sayit2.telemetry", qos: .utility)

/// The local telemetry database, `~/.local/share/sayit2/telemetry.sqlite`, in the system SQLite.
///
/// Traces, span events, and logs keep OpenTelemetry's shape: hex IDs, nanosecond times, and
/// attributes as JSON. Metrics follow Prometheus's data model: one row per observation with a
/// name, labels, and value, and the trace it came from as an exemplar. The views `sessions`,
/// `streams`, and `series` flatten them for the dashboard and for anyone with `sqlite3`.
/// Written only on `telemetryQueue`; the dashboard reads through its own read-only connection.
final class TelemetryStore: @unchecked Sendable {
    /// Rows older than this are deleted when the database opens; daily usage totals stay forever.
    static let retentionDays = 90
    private static let osLog = os.Logger(subsystem: "sayit2", category: "telemetry")

    let url: URL
    private var db: OpaquePointer?
    private var unavailable = false

    init(url: URL) { self.url = url }

    func insert(span: SpanRecord, resource: String, samples: [(name: String, unit: String, value: Double, labels: String)]) {
        telemetryQueue.async { [self] in
            guard let db = open() else { return }
            sqlite3_exec(db, "BEGIN", nil, nil, nil)
            let status: (Int, String?) = switch span.status {
            case .unset: (0, nil)
            case .ok: (1, nil)
            case .error(let message): (2, message)
            }
            run(db, """
                INSERT OR REPLACE INTO spans (trace_id, span_id, parent_span_id, name, kind, start_ns, end_ns,
                    status_code, status_message, attributes, resource) VALUES (?,?,?,?,?,?,?,?,?,?,?)
                """, [span.traceId, span.spanId, span.parentSpanId, span.name, span.kind.rawValue,
                      Self.nanos(span.startTime), Self.nanos(span.endTime), status.0, status.1,
                      Self.json(span.attributes), resource])
            for event in span.events {
                run(db, "INSERT INTO span_events (trace_id, span_id, time_ns, name, attributes) VALUES (?,?,?,?,?)",
                    [span.traceId, span.spanId, Self.nanos(event.timestamp), event.name, Self.json(event.attributes)])
            }
            for sample in samples {
                run(db, "INSERT INTO samples (time_ns, name, unit, value, labels, trace_id) VALUES (?,?,?,?,?,?)",
                    [Self.nanos(span.endTime), sample.name, sample.unit, sample.value, sample.labels, span.traceId])
            }
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
        }
    }

    func insertLog(time: Date, severity: Severity, name: String?, body: String, traceId: String?, spanId: String?,
                   attributes: [String: AttributeValue]) {
        telemetryQueue.async { [self] in
            guard let db = open() else { return }
            run(db, """
                INSERT INTO logs (time_ns, severity_number, severity_text, event_name, body, trace_id, span_id, attributes)
                VALUES (?,?,?,?,?,?,?,?)
                """, [Self.nanos(time), severity.rawValue, severity.text, name, body, traceId, spanId, Self.json(attributes)])
        }
    }

    /// Opens the database, creating the schema and dropping expired rows. On `telemetryQueue`.
    private func open() -> OpaquePointer? {
        if let db { return db }
        guard !unavailable else { return nil }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        var handle: OpaquePointer?
        let cutoff = Self.nanos(Date().addingTimeInterval(-Double(Self.retentionDays) * 86400))
        let prune = ["spans": "end_ns", "span_events": "time_ns", "logs": "time_ns", "samples": "time_ns"]
            .map { "DELETE FROM \($0.key) WHERE \($0.value) < \(cutoff);" }.joined()
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              sqlite3_exec(handle, Self.schema + prune, nil, nil, nil) == SQLITE_OK else {
            Self.osLog.error("telemetry database unavailable: \(String(cString: sqlite3_errmsg(handle)), privacy: .public)")
            sqlite3_close(handle)
            unavailable = true
            return nil
        }
        chmod(url.path, 0o600)
        sqlite3_busy_timeout(handle, 2000)
        db = handle
        return handle
    }

    private func run(_ db: OpaquePointer, _ sql: String, _ values: [Any?]) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        Self.bind(statement, values)
        if sqlite3_step(statement) != SQLITE_DONE {
            Self.osLog.error("telemetry write failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
        }
    }

    /// Runs one read-only statement for the dashboard and returns `{columns, rows}` or `{error}`.
    /// Anything but reading (writes, ATTACH, PRAGMA) is refused by the authorizer, and a query
    /// is stopped after five seconds.
    static func query(_ sql: String, parameters: [Any], at url: URL) -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return ["columns": [String](), "rows": [[Any]]()] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            defer { sqlite3_close(db) }
            return ["error": String(cString: sqlite3_errmsg(db))]
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        sqlite3_set_authorizer(db, { _, action, _, _, _, _ in
            [SQLITE_SELECT, SQLITE_READ, SQLITE_FUNCTION, SQLITE_RECURSIVE].contains(action) ? SQLITE_OK : SQLITE_DENY
        }, nil)
        let deadline = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        defer { deadline.deallocate() }
        deadline.pointee = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        sqlite3_progress_handler(db, 10_000, { context in
            DispatchTime.now().uptimeNanoseconds > context!.load(as: UInt64.self) ? 1 : 0
        }, deadline)

        var statement: OpaquePointer?
        // The tail points into the C string, so it is read while that string is alive.
        let (prepared, rest) = sql.withCString { text -> (Int32, String) in
            var tail: UnsafePointer<CChar>?
            let code = sqlite3_prepare_v2(db, text, -1, &statement, &tail)
            return (code, tail.map { String(cString: $0) } ?? "")
        }
        defer { sqlite3_finalize(statement) }
        guard prepared == SQLITE_OK else { return ["error": String(cString: sqlite3_errmsg(db))] }
        if !rest.trimmingCharacters(in: CharacterSet(charactersIn: "; \n\t\r")).isEmpty {
            return ["error": "Run one statement at a time"]
        }
        guard statement != nil, sqlite3_stmt_readonly(statement) != 0 else { return ["error": "Only read-only queries can run here"] }
        bind(statement, parameters)
        let count = sqlite3_column_count(statement)
        let columns = (0..<count).map { String(cString: sqlite3_column_name(statement, $0)) }
        var rows: [[Any]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return ["error": String(cString: sqlite3_errmsg(db))] }
            guard rows.count < 50_000 else { return ["columns": columns, "rows": rows, "truncated": true] }
            rows.append((0..<count).map { column -> Any in
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: return sqlite3_column_int64(statement, column)
                case SQLITE_FLOAT:
                    let value = sqlite3_column_double(statement, column)
                    return value.isFinite ? value : NSNull()
                case SQLITE_TEXT: return String(cString: sqlite3_column_text(statement, column))
                default: return NSNull()
                }
            })
        }
        return ["columns": columns, "rows": rows]
    }

    private static func bind(_ statement: OpaquePointer?, _ values: [Any?]) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let i = Int32(index + 1)
            switch value {
            case let v as String: sqlite3_bind_text(statement, i, v, -1, transient)
            case let v as Int: sqlite3_bind_int64(statement, i, Int64(v))
            case let v as Int64: sqlite3_bind_int64(statement, i, v)
            case let v as Double: sqlite3_bind_double(statement, i, v)
            case let v as NSNumber: sqlite3_bind_double(statement, i, v.doubleValue)
            default: sqlite3_bind_null(statement, i)
            }
        }
    }

    static func nanos(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1e9) }

    static func json(_ attributes: [String: AttributeValue]) -> String {
        var object: [String: Any] = [:]
        for (key, value) in attributes {
            switch value {
            case .string(let v): object[key] = v
            case .bool(let v): object[key] = v
            case .int(let v): object[key] = v
            case .double(let v): if v.isFinite { object[key] = v }
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Tables keep the raw signals; views are rebuilt on every start so they follow the app version.
    private static let schema = """
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;
        CREATE TABLE IF NOT EXISTS spans (
            trace_id TEXT NOT NULL, span_id TEXT PRIMARY KEY, parent_span_id TEXT, name TEXT NOT NULL, kind INTEGER,
            start_ns INTEGER NOT NULL, end_ns INTEGER NOT NULL, status_code INTEGER, status_message TEXT,
            attributes TEXT NOT NULL DEFAULT '{}', resource TEXT NOT NULL DEFAULT '{}');
        CREATE INDEX IF NOT EXISTS spans_trace ON spans (trace_id);
        CREATE INDEX IF NOT EXISTS spans_name_start ON spans (name, start_ns);
        CREATE TABLE IF NOT EXISTS span_events (
            trace_id TEXT NOT NULL, span_id TEXT NOT NULL, time_ns INTEGER NOT NULL, name TEXT NOT NULL,
            attributes TEXT NOT NULL DEFAULT '{}');
        CREATE INDEX IF NOT EXISTS span_events_span ON span_events (span_id);
        CREATE INDEX IF NOT EXISTS span_events_trace ON span_events (trace_id);
        CREATE TABLE IF NOT EXISTS logs (
            time_ns INTEGER NOT NULL, severity_number INTEGER, severity_text TEXT, event_name TEXT, body TEXT,
            trace_id TEXT, span_id TEXT, attributes TEXT NOT NULL DEFAULT '{}');
        CREATE INDEX IF NOT EXISTS logs_trace ON logs (trace_id);
        CREATE INDEX IF NOT EXISTS logs_time ON logs (time_ns);
        CREATE TABLE IF NOT EXISTS samples (
            time_ns INTEGER NOT NULL, name TEXT NOT NULL, unit TEXT, value REAL NOT NULL,
            labels TEXT NOT NULL DEFAULT '{}', trace_id TEXT);
        CREATE INDEX IF NOT EXISTS samples_name_time ON samples (name, time_ns);

        DROP VIEW IF EXISTS sessions;
        DROP VIEW IF EXISTS streams;
        DROP VIEW IF EXISTS series;
        CREATE VIEW streams AS
        SELECT s.trace_id, s.span_id, s.start_ns, s.end_ns, (s.end_ns - s.start_ns) / 1e9 AS duration_s,
            coalesce(s.attributes ->> '$."gen_ai.provider.name"', d.attributes ->> '$."gen_ai.provider.name"') AS provider,
            coalesce(s.attributes ->> '$."gen_ai.request.model"', d.attributes ->> '$."gen_ai.request.model"') AS model,
            coalesce(s.attributes ->> '$."sayit2.stream.attempt"', 1) AS attempt,
            s.attributes ->> '$."server.address"' AS server,
            s.attributes ->> '$."http.response.status_code"' AS http_status,
            s.attributes ->> '$."websocket.close.code"' AS ws_close_code,
            s.attributes ->> '$."websocket.close.reason"' AS ws_close_reason,
            s.attributes ->> '$."error.type"' AS error_type,
            s.status_message AS error_message,
            s.attributes ->> '$."sayit2.stream.connect.seconds"' AS connect_s,
            coalesce(s.attributes ->> '$."sayit2.stream.first_message.seconds"',
                (SELECT (e.time_ns - s.start_ns) / 1e9 FROM span_events e WHERE e.span_id = s.span_id AND e.name = 'first_message' LIMIT 1)) AS first_message_s,
            coalesce(s.attributes ->> '$."sayit2.stream.first_text.seconds"',
                (SELECT (e.time_ns - s.start_ns) / 1e9 FROM span_events e WHERE e.span_id = s.span_id AND e.name = 'first_text' LIMIT 1)) AS first_text_s,
            s.attributes ->> '$."sayit2.stream.first_text_after_audio.seconds"' AS first_text_after_audio_s,
            s.attributes ->> '$."sayit2.stream.replay.seconds"' AS replay_s,
            s.attributes ->> '$."sayit2.stream.commit_strategy"' AS commit_strategy
        FROM spans s LEFT JOIN spans d ON d.span_id = s.parent_span_id
        WHERE s.name = 'sayit2.stream';
        CREATE VIEW sessions AS
        SELECT d.trace_id, d.start_ns, d.end_ns, (d.end_ns - d.start_ns) / 1e9 AS duration_s,
            d.resource ->> '$."service.version"' AS version,
            d.attributes ->> '$."gen_ai.provider.name"' AS provider,
            d.attributes ->> '$."gen_ai.request.model"' AS model,
            d.attributes ->> '$."sayit2.trigger_mode"' AS trigger_mode,
            coalesce(d.attributes ->> '$."sayit2.end_reason"', 'completed') AS outcome,
            d.attributes ->> '$."error.type"' AS error_type,
            d.status_message AS error_message,
            coalesce(d.attributes ->> '$."sayit2.attempts"', 1) AS attempts,
            d.attributes ->> '$."sayit2.audio.seconds"' AS audio_s,
            coalesce(d.attributes ->> '$."sayit2.text.words"', 0) AS words,
            coalesce(d.attributes ->> '$."sayit2.text.characters"', 0) AS characters,
            d.attributes ->> '$."sayit2.language"' AS language,
            d.attributes ->> '$."sayit2.target_app.bundle_id"' AS target_app,
            d.attributes ->> '$."sayit2.mic.type"' AS mic_type,
            coalesce(d.attributes ->> '$."sayit2.mic.recoveries"', 0) AS mic_recoveries,
            d.attributes ->> '$."sayit2.audio.dropouts"' AS mic_dropouts,
            d.attributes ->> '$."sayit2.audio.peak_dbfs"' AS peak_dbfs,
            d.attributes ->> '$."sayit2.audio.rms_dbfs"' AS rms_dbfs,
            d.attributes ->> '$."sayit2.audio.clipped_ratio"' AS clipped_ratio,
            d.attributes ->> '$."sayit2.audio.backlog.max_seconds"' AS backlog_max_s,
            d.attributes ->> '$."sayit2.partials.count"' AS partials,
            d.attributes ->> '$."sayit2.partials.revisions"' AS revisions,
            d.attributes ->> '$."sayit2.text.final_change"' AS final_change,
            d.attributes ->> '$."sayit2.finish.seconds"' AS finish_s,
            coalesce(d.attributes ->> '$."sayit2.release.seconds"',
                (SELECT (d.end_ns - e.time_ns) / 1e9 FROM span_events e WHERE e.span_id = d.span_id AND e.name = 'recording_stopped' LIMIT 1)) AS release_s,
            (SELECT st.connect_s FROM streams st WHERE st.trace_id = d.trace_id AND st.connect_s IS NOT NULL ORDER BY st.start_ns LIMIT 1) AS connect_s,
            (SELECT st.first_text_after_audio_s FROM streams st WHERE st.trace_id = d.trace_id AND st.first_text_after_audio_s IS NOT NULL ORDER BY st.start_ns LIMIT 1) AS first_text_s,
            (SELECT st.first_text_s FROM streams st WHERE st.trace_id = d.trace_id AND st.first_text_s IS NOT NULL ORDER BY st.start_ns LIMIT 1) AS first_text_connect_s,
            (SELECT (i.end_ns - i.start_ns) / 1e9 FROM spans i WHERE i.trace_id = d.trace_id AND i.name = 'sayit2.insert'
                AND NOT coalesce(i.attributes ->> '$."sayit2.insert.waited"', 0) LIMIT 1) AS typing_s,
            (SELECT i.attributes ->> '$."sayit2.insert.wait.seconds"' FROM spans i WHERE i.trace_id = d.trace_id AND i.name = 'sayit2.insert' LIMIT 1) AS focus_wait_s,
            (SELECT max(st.replay_s) FROM streams st WHERE st.trace_id = d.trace_id) AS replay_max_s,
            (SELECT count(*) FROM spans a WHERE a.trace_id = d.trace_id AND a.name = 'sayit2.auth.renew') AS auth_renewals,
            (SELECT count(*) FROM spans a WHERE a.trace_id = d.trace_id AND a.name = 'sayit2.auth.renew' AND a.status_code = 2) AS auth_failures
        FROM spans d WHERE d.name = 'sayit2.dictation' AND d.parent_span_id IS NULL;
        CREATE VIEW series AS
        SELECT name, unit, labels, count(*) AS samples, min(time_ns) AS first_ns, max(time_ns) AS last_ns
        FROM samples GROUP BY name, unit, labels;

        """
}
