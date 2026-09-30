import Foundation

/// What a token turns out to be worth, asked of the API rather than assumed.
enum TokenCheckResult {
    /// The token authenticates, and the API named the organisation it billed
    /// the test request to.
    case valid(organizationID: String?)
    /// The token itself is no good: wrong, revoked, or expired.
    case rejected(String)
    /// We could not tell (offline, timeout). The token may be perfectly fine.
    case unreachable(String)
}

/// Checks an OAuth token by using it, the way a session would.
///
/// This is the difference between "saved" and "works": pasting a token proves
/// nothing until something has actually presented it.
///
/// It answers the harder question too. A `claude setup-token` token never names
/// its account — Claude Code shows it as "Claude API", and the OAuth profile
/// endpoint refuses it for want of scope — but the API does say which
/// organisation a request was billed to. Comparing that with the signed-in
/// account's organisation is what turns "the label says Upgrade Estate" into
/// something checked.
enum TokenCheck {
    private static let countTokens = URL(string: "https://api.anthropic.com/v1/messages/count_tokens")!
    private static let messages = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let model = "claude-haiku-4-5-20251001"

    static func run(token: String, completion: @escaping (TokenCheckResult) -> Void) {
        // `count_tokens` is free and changes nothing, which makes it the right
        // question to ask of a token you are only checking.
        var request = self.request(countTokens, token: token)
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [["role": "user", "content": "hi"]],
        ])

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                return finish(.unreachable(error.localizedDescription), completion)
            }
            guard let http = response as? HTTPURLResponse else {
                return finish(.unreachable("No answer from the API."), completion)
            }
            switch http.statusCode {
            case 200..<300, 429:            // rate limited is still authenticated
                finish(.valid(organizationID: organization(in: http)), completion)
            case 401, 403:
                let why = message(in: data)
                if let why, isScopeComplaint(why) {
                    // Authenticated, just not entitled to this endpoint.
                    finish(.valid(organizationID: organization(in: http)), completion)
                } else {
                    finish(.rejected(why
                        ?? "The token was rejected — it is wrong, revoked or expired."),
                           completion)
                }
            default:
                finish(.unreachable("The API answered \(http.statusCode)."), completion)
            }
        }.resume()
    }

    /// The rate-limit headers, for the usage readout.
    ///
    /// It has to be a real message: an endpoint that costs nothing reports no
    /// limits, so `count_tokens` comes back with no rate-limit headers at all.
    /// This asks the cheapest question there is, one token in and one out, and
    /// reads the limits off the answer.
    static func limits(token: String, completion: @escaping ([String: String]) -> Void) {
        var request = self.request(messages, token: token)
        request.timeoutInterval = 30
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 1,
            // A Claude Code token is authorised for Claude Code; the system
            // line is what the CLI itself sends.
            "system": "You are Claude Code, Anthropic's official CLI for Claude.",
            "messages": [["role": "user", "content": "hi"]],
        ])

        URLSession.shared.dataTask(with: request) { data, response, _ in
            var headers: [String: String] = [:]
            if let http = response as? HTTPURLResponse {
                headers = rateLimits(in: http)
                // Every read is written down, not only the empty ones. A number
                // that looks wrong on screen can only be answered against what
                // the API actually said at that moment — guessing at it
                // afterwards is how an afternoon goes. Only the rate-limit
                // headers are kept: no token, no ids.
                log(status: http.statusCode, response: http,
                    error: headers.isEmpty ? message(in: data) : nil,
                    limits: headers)
            }
            DispatchQueue.main.async { completion(headers) }
        }.resume()
    }

    // MARK: - Asking

    private static func request(_ url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        return request
    }

    // MARK: - Reading the answer

    /// `anthropic-ratelimit-unified-5h-utilization` and friends.
    private static func rateLimits(in response: HTTPURLResponse) -> [String: String] {
        var limits: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let name = (key as? String)?.lowercased(), let text = value as? String,
                  name.contains("ratelimit") else { continue }
            limits[name] = text
        }
        return limits
    }

    /// Which organisation the API billed the request to, whatever it calls the
    /// header this month.
    private static func organization(in response: HTTPURLResponse) -> String? {
        for (key, value) in response.allHeaderFields {
            guard let name = key as? String, let text = value as? String else { continue }
            if name.lowercased().contains("organization"), !text.isEmpty { return text }
        }
        return nil
    }

    /// "does not meet scope requirement any_of(user:profile, user:office)" —
    /// the API talking to a token it has already accepted as genuine.
    private static func isScopeComplaint(_ message: String) -> Bool {
        let text = message.lowercased()
        return text.contains("scope") && !text.contains("invalid")
    }

    private static func message(in data: Data?) -> String? {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let text = error["message"] as? String else { return nil }
        return text
    }

    private static func finish(_ result: TokenCheckResult,
                               _ completion: @escaping (TokenCheckResult) -> Void) {
        DispatchQueue.main.async { completion(result) }
    }

    /// What the API said about the limits, every time it is asked.
    ///
    /// The header names are not documented, so this is what makes a change in
    /// them knowable instead of a mystery — and a bar that reads wrong
    /// answerable, which a reading kept only in memory never is. A read that
    /// comes back with nothing usable says so and names the headers it did
    /// get. Rate-limit headers only: no token, no organisation or request ids.
    private static func log(status: Int,
                            response: HTTPURLResponse,
                            error: String?,
                            limits: [String: String]) {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ClaudeHub")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let body = limits.isEmpty
            ? "headers: " + response.allHeaderFields.keys
                .compactMap { $0 as? String }.sorted().joined(separator: ", ")
            : limits.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
                .joined(separator: "\n")
        let entry = """

            ===== \(Date()) — \(limits.isEmpty ? "no rate-limit headers" : "limits read") =====
            status: \(status)
            \(error.map { "error: \($0)\n" } ?? "")\(body)

            """
        guard let data = entry.data(using: .utf8) else { return }
        let file = folder.appendingPathComponent("token-check.log")
        trim(file)
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: file)
        }
    }

    /// A read a minute adds up; half a megabyte is days of history, and the
    /// oldest half goes rather than the file growing for the life of the app.
    private static func trim(_ file: URL) {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 512_000,
              let data = try? Data(contentsOf: file) else { return }
        try? data.suffix(256_000).write(to: file)
    }
}
