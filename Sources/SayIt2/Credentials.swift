import Foundation
import OpenTelemetryApi

/// The ChatGPT sign-in shared with the ChatGPT desktop app and the codex command line tool,
/// stored in ~/.codex/auth.json. SayIt2 renews it itself when it has expired, and saves the
/// renewed tokens back to the same file so those apps keep working with them.
@MainActor
enum Credentials {
    private static let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
    private static let lockFile = file.deletingLastPathComponent().appendingPathComponent("auth.lock")
    /// The token most recently handed to a connection, to tell whether someone else renewed it since.
    private static var lastUsed: String?

    static var hasChatGPTLogin: Bool { (try? readAuth()) != nil }

    static func chatGPT() throws -> (token: String, account: String) {
        let auth = try readAuth()
        guard let account = auth.tokens["account_id"] as? String
        else { throw Problem(message: "Sign in to ChatGPT", retryable: false, errorType: "missing_login") }
        let token = auth.access
        lastUsed = token
        if expiry(of: token) <= Date() { throw Problem(message: "ChatGPT sign-in expired", retryable: false, errorType: "auth_expired", renewLogin: true) }
        return (token, account)
    }

    /// Renews the ChatGPT sign-in with its refresh token.
    static func renewChatGPT(parentSpan: Span? = nil) async throws {
        let span = Telemetry.startSpan("sayit2.auth.renew", parent: parentSpan, kind: .client)
        span.setAttribute(key: "server.address", value: "auth.openai.com")
        func fail(_ problem: Problem) -> Problem {
            span.setAttribute(key: "error.type", value: problem.errorType ?? problem.message)
            span.status = .error(description: problem.message)
            span.end()
            return problem
        }
        let initial: (access: String, refresh: String)?
        do {
            initial = try await withLock {
                let auth = try readAuth()
                // Someone else already renewed it.
                if auth.access != lastUsed, expiry(of: auth.access) > Date() { return nil }
                return (auth.access, auth.refresh)
            }
        } catch {
            throw fail(error as? Problem ?? Problem(message: "Sign in to ChatGPT again", retryable: false, errorType: "auth_read_failed"))
        }
        guard let initial else {
            span.addEvent(name: "already_renewed")
            span.status = .ok
            span.end()
            return
        }

        var request = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: initial.refresh),
            URLQueryItem(name: "client_id", value: claims(of: initial.access)?["client_id"] as? String ?? ""),
        ]
        request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)

        let reply: Data, status: Int
        do {
            let (body, response) = try await URLSession.shared.data(for: request)
            reply = body
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            Telemetry.event("ChatGPT renewal network error", severity: .error, span: span)
            throw fail(Problem(message: "Can't reach ChatGPT", errorType: "network_error"))
        }
        if status > 0 { span.setAttribute(key: "http.response.status_code", value: status) }
        guard status == 200, let renewed = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
              let newAccess = renewed["access_token"] as? String
        else {
            Telemetry.event("ChatGPT renewal refused with status \(status)", severity: .error, span: span)
            if status == 408 || status == 429 || status >= 500 {
                throw fail(Problem(message: status == 429 ? "ChatGPT rate limited" : "Can't reach ChatGPT",
                                   errorType: status == 429 ? "rate_limited" : "server_error"))
            }
            let alreadyRenewed = (try? await withLock {
                let auth = try readAuth()
                return auth.access != initial.access && expiry(of: auth.access) > Date()
            }) ?? false
            if alreadyRenewed {
                span.addEvent(name: "already_renewed")
                span.status = .ok
                span.end()
                return
            }
            throw fail(Problem(message: "Sign in to ChatGPT again", retryable: false, errorType: "auth_rejected"))
        }

        do {
            try await withLock {
                var auth = try readAuth()
                // Another process renewed auth.json while our request was in flight; keep its tokens.
                if auth.access != initial.access, expiry(of: auth.access) > Date() { return }
                auth.tokens["access_token"] = newAccess
                for key in ["refresh_token", "id_token"] { if let value = renewed[key] as? String { auth.tokens[key] = value } }
                auth.root["tokens"] = auth.tokens
                let stamp = ISO8601DateFormatter()
                stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                auth.root["last_refresh"] = stamp.string(from: Date())
                guard let output = try? JSONSerialization.data(withJSONObject: auth.root, options: [.prettyPrinted, .withoutEscapingSlashes]) else {
                    throw Problem(message: "Could not save the ChatGPT sign-in", retryable: false, errorType: "auth_save_failed")
                }
                // Write a private temporary file and move it into place, so the file is never half written.
                let temporary = file.deletingLastPathComponent().appendingPathComponent(".auth.json.sayit2.\(UUID().uuidString)")
                guard FileManager.default.createFile(atPath: temporary.path, contents: output, attributes: [.posixPermissions: 0o600]),
                      rename(temporary.path, file.path) == 0
                else {
                    try? FileManager.default.removeItem(at: temporary)
                    throw Problem(message: "Could not save the ChatGPT sign-in", retryable: false, errorType: "auth_save_failed")
                }
                Telemetry.event("ChatGPT sign-in renewed", span: span)
            }
            span.status = .ok
            span.end()
        } catch {
            throw fail(error as? Problem ?? Problem(message: "Could not save the ChatGPT sign-in", retryable: false, errorType: "auth_save_failed"))
        }
    }

    private static func withLock<T>(_ body: () throws -> T) async throws -> T {
        let fd = open(lockFile.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else {
            throw errno == ENOENT
                ? Problem(message: "Sign in to ChatGPT", retryable: false, errorType: "missing_login")
                : Problem(message: "Could not lock the ChatGPT sign-in", retryable: false, errorType: "auth_lock_failed")
        }
        defer { close(fd) }
        for _ in 0..<50 {   // the ChatGPT app or codex may be renewing at the same moment
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                defer { flock(fd, LOCK_UN) }
                return try body()
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Problem(message: "Could not lock the ChatGPT sign-in", errorType: "auth_lock_timeout")
    }

    private static func readAuth() throws -> (root: [String: Any], tokens: [String: Any], access: String, refresh: String) {
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String,
              let refresh = tokens["refresh_token"] as? String
        else { throw Problem(message: "Sign in to ChatGPT", retryable: false, errorType: "missing_login") }
        return (root, tokens, access, refresh)
    }

    private static func claims(of token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Expiry from the token's own claims. An unreadable token is left for the server to judge.
    private static func expiry(of token: String) -> Date {
        (claims(of: token)?["exp"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? .distantFuture
    }
}
