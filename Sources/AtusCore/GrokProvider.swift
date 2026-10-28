import Foundation

/// Reads the SuperGrok weekly pool from the billing endpoint behind Grok CLI's `/usage`.
///
/// Fast path: the bearer in `~/.grok/auth.json` against `cli-chat-proxy.grok.com`.
/// That token lives about six hours and only the Grok CLI refreshes it, so when it is
/// expired (or rejected) atus asks `grok agent stdio` for `_x.ai/billing`; the CLI
/// handles its own token refresh and atus never touches the rotating refresh token.
public struct GrokProvider: UsageProvider {
    public let id = ProviderID.grok

    static let billingURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    static let agentTimeout: Duration = .seconds(45)

    public init() {}

    public func fetch() async throws -> UsageSnapshot {
        if let token = try? Self.loadToken(), token.expiresAt.map({ $0 > Date().addingTimeInterval(60) }) ?? true {
            do {
                return try await fetchREST(token: token.value)
            } catch UsageError.tokenExpired {
                // Fall through to the CLI, which refreshes the token itself.
            }
        }
        return try await fetchViaAgent()
    }

    // MARK: - REST

    private func fetchREST(token: String) async throws -> UsageSnapshot {
        var request = URLRequest(url: Self.billingURL, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: return try Self.snapshot(from: data, fetchedAt: Date())
        case 401, 403: throw UsageError.tokenExpired("grok CLI 토큰")
        default: throw UsageError.http(status: status, body: String(decoding: data, as: UTF8.self))
        }
    }

    struct Token {
        let value: String
        let expiresAt: Date?
    }

    private struct AuthEntry: Decodable {
        let key: String?
        let expiresAt: String?

        enum CodingKeys: String, CodingKey {
            case key
            case expiresAt = "expires_at"
        }
    }

    static func loadToken() throws -> Token {
        let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".grok/auth.json")
        let entries = try JSONDecoder().decode([String: AuthEntry].self, from: Data(contentsOf: url))
        let preferred = entries.first { $0.key.hasPrefix("https://auth.x.ai") }?.value ?? entries.values.first
        guard let entry = preferred, let key = entry.key else {
            throw UsageError.credentialsMissing("`grok login`을 실행하세요")
        }
        return Token(value: key, expiresAt: entry.expiresAt.flatMap(ISODate.parse))
    }

    // MARK: - grok agent stdio

    /// `Process` is not Sendable; the box lets the timeout task terminate it.
    private final class ProcessBox: @unchecked Sendable {
        let process = Process()
    }

    func fetchViaAgent() async throws -> UsageSnapshot {
        guard let binary = Self.grokBinary() else {
            throw UsageError.credentialsMissing("grok CLI를 찾을 수 없어요 (~/.grok/bin/grok)")
        }

        let box = ProcessBox()
        let process = box.process
        process.executableURL = binary
        process.arguments = ["agent", "stdio"]
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        try process.run()
        defer {
            if process.isRunning { process.terminate() }
        }

        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{},"clientInfo":{"name":"atus","version":"0.1"}}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"_x.ai/billing","params":{}}"#,
        ]
        stdin.fileHandleForWriting.write(Data((requests.joined(separator: "\n") + "\n").utf8))

        let reader = stdout.fileHandleForReading
        let result: Data = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                for try await line in reader.bytes.lines {
                    if let payload = try Self.billingPayload(fromRPCLine: line) { return payload }
                }
                throw UsageError.invalidResponse("grok agent가 응답 없이 종료됨")
            }
            group.addTask {
                try await Task.sleep(for: Self.agentTimeout)
                // Closing the agent's stdout ends the reader loop above.
                box.process.terminate()
                throw UsageError.timeout("grok agent stdio")
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        return try Self.snapshot(from: result, fetchedAt: Date())
    }

    /// Returns the JSON `result` of the `_x.ai/billing` call (id 2), or nil for other lines.
    static func billingPayload(fromRPCLine line: String) throws -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              (object["id"] as? Int) == 2
        else { return nil }
        if let result = object["result"] {
            return try JSONSerialization.data(withJSONObject: result)
        }
        let message = (object["error"] as? [String: Any])?["message"] as? String ?? "unknown error"
        throw UsageError.invalidResponse("_x.ai/billing: \(message)")
    }

    static func grokBinary() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.grok/bin/grok", "\(home)/.local/bin/grok", "/opt/homebrew/bin/grok", "/usr/local/bin/grok"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    // MARK: - Response mapping

    struct Response: Decodable {
        struct Config: Decodable {
            struct Period: Decodable {
                let start: String?
                let end: String?
            }

            struct ProductUsage: Decodable {
                let product: String
                let usagePercent: Double?
            }

            /// Protobuf-JSON money value in cents; int64 may arrive as a string.
            struct Cents: Decodable {
                let val: Double

                init(from decoder: any Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    if let number = try? container.decode(Double.self, forKey: .val) {
                        val = number
                    } else if let text = try container.decodeIfPresent(String.self, forKey: .val) {
                        val = Double(text) ?? 0
                    } else {
                        val = 0
                    }
                }

                enum CodingKeys: String, CodingKey { case val }
            }

            let creditUsagePercent: Double?
            let currentPeriod: Period?
            let productUsage: [ProductUsage]?
            let prepaidBalance: Cents?
            let billingPeriodEnd: String?
        }

        let config: Config
        let subscriptionTier: String?

        enum CodingKeys: String, CodingKey {
            case config
            case subscriptionTier = "subscription_tier"
        }
    }

    public static func snapshot(from data: Data, fetchedAt: Date) throws -> UsageSnapshot {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw UsageError.invalidResponse(String(describing: error))
        }
        let config = response.config

        // Protobuf JSON omits zero-valued fields, so a fresh week has no creditUsagePercent.
        let weekly = UsageWindow(
            label: "주간",
            percent: config.creditUsagePercent ?? 0,
            resetsAt: (config.currentPeriod?.end ?? config.billingPeriodEnd).flatMap(ISODate.parse)
        )

        var details: [UsageDetail] = []
        for usage in config.productUsage ?? [] {
            details.append(UsageDetail(label: "이번 주 · \(usage.product)", value: "\(Int((usage.usagePercent ?? 0).rounded()))%"))
        }
        if let balance = config.prepaidBalance {
            details.append(UsageDetail(label: "추가 크레딧 잔액", value: formatMoney(minor: balance.val)))
        }

        return UsageSnapshot(provider: .grok, plan: response.subscriptionTier, windows: [weekly], details: details, fetchedAt: fetchedAt)
    }
}
