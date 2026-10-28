import Foundation

/// Reads the SuperGrok weekly pool from the billing endpoint behind Grok CLI's `/usage`.
///
/// Fast path: the bearer in `~/.grok/auth.json` against `cli-chat-proxy.grok.com`.
/// That token lives about six hours and only the Grok CLI refreshes it, so when it is
/// expired (or rejected) atus asks `grok agent stdio` for `_x.ai/billing`; the CLI
/// handles its own token refresh and atus never touches the rotating refresh token.
public struct GrokProvider: UsageProvider {
    public let info = ProviderInfo(id: .grok, displayName: "Grok", requirement: "Grok CLI 로그인 (SuperGrok)", icon: .bundled(.grok))

    static let billingURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!

    public init() {}

    public var isDetected: Bool {
        FileManager.default.fileExists(atPath: "\(CLILocator.home)/.grok/auth.json")
    }

    public func fetch() async throws -> UsageSnapshot {
        // Without ~/.grok/auth.json the CLI fallback cannot authenticate either, so say
        // "log in" instead of surfacing the agent's opaque billing error.
        guard let token = try? Self.loadToken() else {
            throw UsageError.credentialsMissing("`grok login`을 실행하세요")
        }
        if token.expiresAt.map({ $0 > Date().addingTimeInterval(60) }) ?? true {
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

    func fetchViaAgent() async throws -> UsageSnapshot {
        guard let binary = Self.grokBinary() else {
            throw UsageError.credentialsMissing("grok CLI를 찾을 수 없어요 (~/.grok/bin/grok)")
        }
        let result = try await StdioJSONRPC.call(
            executable: binary,
            arguments: ["agent", "stdio"],
            messages: [
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{},"clientInfo":{"name":"atus","version":"0.1"}}}"#,
                #"{"jsonrpc":"2.0","id":2,"method":"_x.ai/billing","params":{}}"#,
            ],
            resultID: 2,
            method: "_x.ai/billing"
        )
        return try Self.snapshot(from: result, fetchedAt: Date())
    }

    static func grokBinary() -> URL? {
        CLILocator.find("grok", preferring: ["\(CLILocator.home)/.grok/bin"])
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
