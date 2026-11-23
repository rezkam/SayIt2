import AppKit
import Foundation
import Network

/// Loopback-only HTTP server for the local usage stats and settings dashboard.
/// Starts lazily when opened from the menu; guarded by a per-launch token, Host, and Origin checks.
final class Dashboard: @unchecked Sendable {
    private let queue = DispatchQueue(label: "sayit2.dashboard", qos: .utility)
    private let token = UUID().uuidString
    private var listener: NWListener?
    private var activePort: UInt16 = 0   // read/written only on `queue`
    private let onConfigChange: @MainActor () -> Void
    /// Files bundled next to dashboard.html: the Observability tab's script and uPlot (MIT),
    /// the chart library Grafana uses.
    private static let assets = ["observability.js": "text/javascript; charset=utf-8",
                                 "uPlot.iife.min.js": "text/javascript; charset=utf-8", "uPlot.min.css": "text/css; charset=utf-8"]

    init(onConfigChange: @escaping @MainActor () -> Void = {}) {
        self.onConfigChange = onConfigChange
    }

    @MainActor
    func open(section: String = "stats") {
        if let port = listener?.port?.rawValue {
            openBrowser(port: port, section: section)
            return
        }
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        guard let listener = try? NWListener(using: params) else { return }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready:
                guard let self, let port = listener?.port?.rawValue else { return }
                self.activePort = port
                Task { @MainActor [weak self] in self?.openBrowser(port: port, section: section) }
            case .failed, .cancelled:
                self?.activePort = 0
                Task { @MainActor [weak self] in self?.listener = nil }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { conn.cancel(); return }
            conn.start(queue: self.queue)
            let timeout = DispatchWorkItem { conn.cancel() }
            self.queue.asyncAfter(deadline: .now() + 5, execute: timeout)
            self.readRequest(conn, port: self.activePort, buffer: Data(), timeout: timeout)
        }
        listener.start(queue: queue)
    }

    @MainActor
    private func openBrowser(port: UInt16, section: String) {
        if let url = URL(string: "http://127.0.0.1:\(port)/\(token)/#\(section)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func readRequest(_ conn: NWConnection, port: UInt16, buffer: Data, timeout: DispatchWorkItem, remaining: Int = 0) {
        conn.receive(minimumIncompleteLength: max(remaining, 1), maximumLength: max(remaining, 65536)) { [weak self] chunk, _, isComplete, _ in
            guard let self else { timeout.cancel(); conn.cancel(); return }
            var data = buffer
            if let chunk { data.append(chunk) }
            if let split = data.prefix(65536).range(of: Data("\r\n\r\n".utf8)) {
                let head = String(data: data[..<split.lowerBound], encoding: .utf8) ?? ""
                let headers = self.parseHeaders(head)
                let length = max(0, Int(headers["content-length"] ?? "0") ?? 0)
                // Only authenticated config writes need room for a 2 MB keyterm library and JSON escaping.
                let configWrite = head.hasPrefix("POST /\(self.token)/config ") && self.validOrigin(headers, port: port)
                let limit = configWrite ? 16 * 1024 * 1024 : 65536
                guard length <= limit - split.upperBound else {
                    timeout.cancel(); self.send(conn, "413 Payload Too Large", "text/plain", Data()); return
                }
                if data.count >= split.upperBound + length {
                    timeout.cancel()
                    let body = Data(data[split.upperBound ..< (split.upperBound + length)])
                    self.route(conn, port: port, head: head, headers: headers, body: body)
                    return
                }
                if !isComplete, chunk != nil {
                    self.readRequest(conn, port: port, buffer: data, timeout: timeout, remaining: split.upperBound + length - data.count)
                    return
                }
            } else if data.count >= 65536 {
                timeout.cancel(); self.send(conn, "413 Payload Too Large", "text/plain", Data()); return
            }
            if isComplete || chunk == nil { timeout.cancel(); conn.cancel(); return }
            self.readRequest(conn, port: port, buffer: data, timeout: timeout)
        }
    }

    private func parseHeaders(_ head: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in head.split(separator: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                out[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return out
    }

    private func validOrigin(_ headers: [String: String], port: UInt16) -> Bool {
        port != 0 && headers["host"] == "127.0.0.1:\(port)" &&
            (headers["origin"] == nil || headers["origin"] == "http://127.0.0.1:\(port)")
    }

    private func route(_ conn: NWConnection, port: UInt16, head: String, headers: [String: String], body: Data) {
        let parts = (head.split(separator: "\r\n", maxSplits: 1).first ?? "").split(separator: " ")
        guard parts.count >= 2 else { send(conn, "400 Bad Request", "text/plain", Data()); return }
        guard validOrigin(headers, port: port) else {
            send(conn, "403 Forbidden", "text/plain", Data()); return
        }
        let target = parts[1].split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        let prefix = "/\(token)/"
        guard target.hasPrefix(prefix) else { send(conn, "404 Not Found", "text/plain", Data()); return }

        switch (String(parts[0]), String(target.dropFirst(prefix.count))) {
        case ("GET", ""):
            guard let url = Bundle.main.url(forResource: "dashboard", withExtension: "html"),
                  let html = try? Data(contentsOf: url) else {
                send(conn, "404 Not Found", "text/plain", Data()); return
            }
            send(conn, "200 OK", "text/html; charset=utf-8", html)

        case ("GET", "usage_stats.json"):
            serveStats(conn, ifNoneMatch: headers["if-none-match"])

        case ("GET", let name) where Self.assets[name] != nil:
            guard let url = Bundle.main.url(forResource: name, withExtension: nil),
                  let data = try? Data(contentsOf: url) else {
                send(conn, "404 Not Found", "text/plain", Data()); return
            }
            send(conn, "200 OK", Self.assets[name], data)

        case ("POST", "query"):
            // Read-only SQL over the local telemetry database, for the Observability tab.
            guard (headers["content-type"] ?? "").lowercased().hasPrefix("application/json"),
                  let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let sql = obj["sql"] as? String else {
                send(conn, "400 Bad Request", "application/json", Data()); return
            }
            let result = TelemetryStore.query(sql, parameters: obj["params"] as? [Any] ?? [], at: Telemetry.databaseURL)
            let data = (try? JSONSerialization.data(withJSONObject: result)) ?? Data("{\"error\":\"encoding failed\"}".utf8)
            send(conn, "200 OK", "application/json; charset=utf-8", data)

        case ("GET", "config"):
            sendConfig(conn)

        case ("POST", "config"):
            guard (headers["content-type"] ?? "").lowercased().hasPrefix("application/json"),
                  let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let updates = obj["updates"] as? [String: [String]] else {
                send(conn, "400 Bad Request", "application/json", Data()); return
            }
            Task { @MainActor [weak self] in
                guard let self else { conn.cancel(); return }
                guard Config.update(updates) else {
                    self.queue.async { self.send(conn, "500 Internal Server Error", "application/json", Data()) }
                    return
                }
                self.onConfigChange()
                self.sendConfigOnMain(conn)
            }

        default:
            send(conn, "404 Not Found", "text/plain", Data())
        }
    }

    private func serveStats(_ conn: NWConnection, ifNoneMatch: String?) {
        let url = Telemetry.dataDirectory.appendingPathComponent("usage_stats.json")
        var st = stat()
        if stat(url.path, &st) == 0 {
            let etag = "\"\(st.st_mtimespec.tv_sec)-\(st.st_mtimespec.tv_nsec)-\(st.st_size)\""
            if ifNoneMatch == etag { send(conn, "304 Not Modified", nil, Data(), etag: etag); return }
            if let body = try? Data(contentsOf: url) {
                send(conn, "200 OK", "application/json; charset=utf-8", body, etag: etag); return
            }
        }
        send(conn, "200 OK", "application/json; charset=utf-8", Data("{\"schemaVersion\":1,\"days\":{}}".utf8))
    }

    private func sendConfig(_ conn: NWConnection) {
        Task { @MainActor [weak self] in self?.sendConfigOnMain(conn) }
    }

    @MainActor
    private func sendConfigOnMain(_ conn: NWConnection) {
        let payload: [String: Any] = ["entries": Config.allEntries(), "chatgptSignedIn": Credentials.hasChatGPTLogin]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8)
        queue.async { self.send(conn, "200 OK", "application/json; charset=utf-8", data) }
    }

    private func send(_ conn: NWConnection, _ status: String, _ type: String?, _ body: Data, etag: String? = nil) {
        var header = "HTTP/1.1 \(status)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n"
        if let type { header += "Content-Type: \(type)\r\nContent-Length: \(body.count)\r\n" }
        if let etag { header += "ETag: \(etag)\r\n" }
        header += "\r\n"
        var packet = Data(header.utf8)
        packet.append(body)
        conn.send(content: packet, completion: .contentProcessed { _ in conn.cancel() })
    }
}
