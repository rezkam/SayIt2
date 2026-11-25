import AppKit
import CryptoKit
import Network

/// SayIt2's own ChatGPT sign-in, separate from the ChatGPT app and codex, so it can be another
/// account. Signed in from the dashboard with ChatGPT's browser sign-in (the OAuth flow codex
/// uses), kept in ~/.config/sayit2/chatgpt.json, and renewed with its refresh token only when the
/// token has expired or the server rejects it.
@MainActor
enum Credentials {
    private static let file = Config.file.deletingLastPathComponent().appendingPathComponent("chatgpt.json")
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let redirectURI = "http://localhost:1455/auth/callback"

    private struct Login {
        let access: String
        let refresh: String
    }

    /// The token most recently handed to a connection, to tell whether it was renewed since.
    private static var lastUsed: String?
    /// The renewal in flight. Refresh tokens are single use, so concurrent renewals share one.
    private static var renewal: Task<Void, Error>?
    /// The browser sign-in waiting for ChatGPT to send the browser back, if any.
    private static var callback: SignInCallback?
    /// Why the last browser sign-in failed, for the dashboard.
    private(set) static var signInProblem: String?

    static var hasChatGPTLogin: Bool { read() != nil }
    static var isSigningIn: Bool { callback != nil }

    /// The signed-in account's email and plan, from the token's own claims.
    static var accountSummary: (email: String?, plan: String?)? {
        guard let login = read() else { return nil }
        let claims = claims(of: login.access)
        return ((claims?["https://api.openai.com/profile"] as? [String: Any])?["email"] as? String,
                auth(of: login.access)?["chatgpt_plan_type"] as? String)
    }

    static func chatGPT() throws -> (token: String, account: String) {
        guard let login = read(), let account = auth(of: login.access)?["chatgpt_account_id"] as? String
        else { throw Problem(message: "Sign in to ChatGPT in Settings", retryable: false, errorType: "missing_login") }
        lastUsed = login.access
        if expiry(of: login.access) <= Date().addingTimeInterval(60) {
            throw Problem(message: "ChatGPT sign-in expired", retryable: false, errorType: "auth_expired", renewLogin: true)
        }
        return (login.access, account)
    }

    /// Renews the ChatGPT sign-in with its refresh token.
    static func renewChatGPT(parentSpan: Span? = nil) async throws {
        if let renewal { return try await renewal.value }
        let task = Task { try await renew(parentSpan: parentSpan) }
        renewal = task
        defer { renewal = nil }
        try await task.value
    }

    private static func renew(parentSpan: Span?) async throws {
        let span = Telemetry.startSpan("sayit2.auth.renew", parent: parentSpan, kind: .client)
        span.setAttribute(key: "server.address", value: "auth.openai.com")
        do {
            guard let login = read() else {
                throw Problem(message: "Sign in to ChatGPT in Settings", retryable: false, errorType: "missing_login")
            }
            if login.access != lastUsed, expiry(of: login.access) > Date().addingTimeInterval(60) {
                span.addEvent(name: "already_renewed")
            } else {
                let renewed = try await requestTokens([("grant_type", "refresh_token"), ("refresh_token", login.refresh),
                                                       ("client_id", clientID)], keeping: login.refresh, span: span)
                // Signed out or into another account while the request was in flight: keep that.
                guard read()?.refresh == login.refresh else { span.status = .ok; span.end(); return }
                try save(renewed)
                Telemetry.event("ChatGPT sign-in renewed", span: span)
            }
            span.status = .ok
            span.end()
        } catch {
            throw fail(span, error, otherwise: Problem(message: "Sign in to ChatGPT again in Settings", retryable: false, errorType: "auth_rejected"))
        }
    }

    // MARK: Browser sign-in

    /// Opens ChatGPT's sign-in page in the browser. ChatGPT sends the browser back to
    /// localhost:1455, the address registered for codex, where SayIt2 exchanges the code for tokens.
    static func startSignIn() {
        callback?.cancel()
        signInProblem = nil
        let verifier = randomToken(), state = randomToken()
        var url = URLComponents(string: "https://auth.openai.com/oauth/authorize")!
        url.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "openid profile email offline_access"),
            URLQueryItem(name: "code_challenge", value: base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: "codex_cli_rs"),
        ]
        let callback = SignInCallback(state: state, page: url.url!) { result in
            Task { @MainActor in await finishSignIn(result, state: state, verifier: verifier) }
        }
        self.callback = callback
        callback.start()
    }

    static func signOut() {
        callback?.cancel()
        callback = nil
        signInProblem = nil
        try? FileManager.default.removeItem(at: file)
    }

    private static func finishSignIn(_ result: Result<String, Problem>, state: String, verifier: String) async {
        guard callback?.state == state else { return }
        let span = Telemetry.startSpan("sayit2.auth.sign_in", kind: .client)
        span.setAttribute(key: "server.address", value: "auth.openai.com")
        do {
            let login = try await requestTokens([("grant_type", "authorization_code"), ("client_id", clientID), ("code", try result.get()),
                                                 ("code_verifier", verifier), ("redirect_uri", redirectURI)], keeping: nil, span: span)
            guard callback?.state == state else { span.end(); return }
            try save(login)
            Telemetry.event("ChatGPT signed in", span: span)
            span.status = .ok
            span.end()
        } catch {
            let problem = fail(span, error, otherwise: Problem(message: "ChatGPT sign-in failed", retryable: false, errorType: "signin_failed"))
            if callback?.state == state {
                signInProblem = problem.errorType == "auth_rejected" ? "ChatGPT did not accept the sign-in" : problem.message
            }
        }
        if callback?.state == state { callback = nil }
    }

    // MARK: Tokens

    private static func requestTokens(_ fields: [(String, String)], keeping refresh: String?, span: Span) async throws -> Login {
        var request = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = Data(fields.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").utf8)
        let body: Data, status: Int
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            body = data
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            throw Problem(message: "Can't reach ChatGPT", errorType: "network_error")
        }
        span.setAttribute(key: "http.response.status_code", value: status)
        guard status == 200, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let access = json["access_token"] as? String, auth(of: access)?["chatgpt_account_id"] is String,
              let newRefresh = json["refresh_token"] as? String ?? refresh
        else {
            Telemetry.event("ChatGPT token request refused with status \(status)", severity: .error, span: span)
            if status == 429 { throw Problem(message: "ChatGPT rate limited", errorType: "rate_limited") }
            if status == 408 || status >= 500 { throw Problem(message: "Can't reach ChatGPT", errorType: "server_error") }
            throw Problem(message: "Sign in to ChatGPT again in Settings", retryable: false, errorType: "auth_rejected")
        }
        return Login(access: access, refresh: newRefresh)
    }

    private static func read() -> Login? {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String, let refresh = json["refresh_token"] as? String
        else { return nil }
        return Login(access: access, refresh: refresh)
    }

    /// Writes a private temporary file and moves it into place, so the file is never half written.
    private static func save(_ login: Login) throws {
        let folder = file.deletingLastPathComponent()
        let temporary = folder.appendingPathComponent(".chatgpt.json.\(UUID().uuidString)")
        guard let data = try? JSONSerialization.data(withJSONObject: ["access_token": login.access, "refresh_token": login.refresh],
                                                     options: [.prettyPrinted, .sortedKeys]),
              (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
              FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]),
              rename(temporary.path, file.path) == 0
        else {
            try? FileManager.default.removeItem(at: temporary)
            throw Problem(message: "Could not save the ChatGPT sign-in", retryable: false, errorType: "auth_save_failed")
        }
    }

    private static func fail(_ span: Span, _ error: Error, otherwise: Problem) -> Problem {
        let problem = error as? Problem ?? otherwise
        span.setAttribute(key: "error.type", value: problem.errorType ?? problem.message)
        span.status = .error(description: problem.message)
        span.end()
        return problem
    }

    private static func claims(of token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func auth(of token: String) -> [String: Any]? {
        claims(of: token)?["https://api.openai.com/auth"] as? [String: Any]
    }

    /// Expiry from the token's own claims. An unreadable token is left for the server to judge.
    private static func expiry(of token: String) -> Date {
        (claims(of: token)?["exp"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? .distantFuture
    }

    private static func randomToken() -> String {
        base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Listens on localhost:1455 for the browser coming back from ChatGPT's sign-in page, and opens
/// that page once listening. Ends after one sign-in, a cancel, or ten minutes.
private final class SignInCallback: @unchecked Sendable {
    let state: String
    private let page: URL
    private let queue = DispatchQueue(label: "sayit2.signin")
    private var listener: NWListener?   // on `queue`
    private var done = false            // on `queue`
    private let onResult: @Sendable (Result<String, Problem>) -> Void

    init(state: String, page: URL, onResult: @escaping @Sendable (Result<String, Problem>) -> Void) {
        self.state = state
        self.page = page
        self.onResult = onResult
    }

    func start() {
        queue.async { [self] in
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: 1455)
            guard let listener = try? NWListener(using: params) else { return finish(.failure(Self.busy)) }
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: DispatchQueue.main.async { NSWorkspace.shared.open(self.page) }
                case .failed, .waiting: self.finish(.failure(Self.busy))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 600) { [weak self] in
                self?.finish(.failure(Problem(message: "ChatGPT sign-in timed out", retryable: false, errorType: "signin_timeout")))
            }
        }
    }

    func cancel() {
        queue.async { [self] in
            done = true
            listener?.cancel()
            listener = nil
        }
    }

    private static let busy = Problem(message: "Port 1455 is in use; finish or close any codex sign-in and try again",
                                      retryable: false, errorType: "signin_port_busy")

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self else { return conn.cancel() }
            let line = data.flatMap { String(data: $0, encoding: .utf8) }?.split(separator: "\r\n").first ?? ""
            let parts = line.split(separator: " ")
            guard parts.count >= 2, parts[0] == "GET", let target = URLComponents(string: String(parts[1])),
                  target.path == "/auth/callback"
            else { return self.reply(conn, "404 Not Found", "Not found.") }
            let query = Dictionary((target.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } },
                                   uniquingKeysWith: { first, _ in first })
            guard query["state"] == self.state, !self.done else {
                return self.reply(conn, "400 Bad Request", "This sign-in is no longer open. Start again from SayIt2's Settings.")
            }
            if let code = query["code"] {
                self.reply(conn, "200 OK", "SayIt2 received the sign-in. Return to SayIt2's Settings to see the result; you can close this tab.")
                self.finish(.success(code))
            } else {
                self.reply(conn, "400 Bad Request", "ChatGPT sign-in did not finish. Start again from SayIt2's Settings.")
                self.finish(.failure(Problem(message: "ChatGPT sign-in was cancelled", retryable: false,
                                             errorType: query["error"] ?? "signin_cancelled")))
            }
        }
    }

    /// Called on `queue`.
    private func finish(_ result: Result<String, Problem>) {
        guard !done else { return }
        done = true
        listener?.cancel()
        listener = nil
        onResult(result)
    }

    private func reply(_ conn: NWConnection, _ status: String, _ text: String) {
        let html = "<!doctype html><meta charset=utf-8><title>SayIt2</title><body style=\"font:16px -apple-system;margin:4em\">\(text)</body>"
        let body = Data(html.utf8)
        var packet = Data("HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        packet.append(body)
        conn.send(content: packet, completion: .contentProcessed { _ in conn.cancel() })
    }
}
