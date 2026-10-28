import Foundation

/// Reads ChatGPT/Codex plan limits through the Codex CLI's own `codex app-server`
/// (`account/rateLimits/read`). The CLI owns `~/.codex/auth.json` and refreshes it,
/// so atus never touches the token.
public struct CodexProvider: UsageProvider {
    public let info = ProviderInfo(id: .codex, displayName: "Codex", requirement: L("Codex CLI sign-in (ChatGPT)"), icon: .bundled(.codex))

    public init() {}

    public var isDetected: Bool {
        FileManager.default.fileExists(atPath: "\(CLILocator.home)/.codex/auth.json")
    }

    public func fetch() async throws -> UsageSnapshot {
        guard let binary = CLILocator.find("codex") else {
            throw UsageError.credentialsMissing(L("codex CLI not found"))
        }
        let result = try await StdioJSONRPC.call(
            executable: binary,
            arguments: ["app-server"],
            messages: [
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"atus","title":"atus","version":"0.1"}}}"#,
                #"{"jsonrpc":"2.0","method":"initialized"}"#,
                #"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read"}"#,
            ],
            resultID: 2,
            method: "account/rateLimits/read"
        )
        return try Self.snapshot(from: result, fetchedAt: Date())
    }

    // MARK: - Response mapping

    struct Response: Decodable {
        struct RateLimits: Decodable {
            struct Window: Decodable {
                let usedPercent: Double
                let windowDurationMins: Int?
                let resetsAt: Double?
            }

            struct Credits: Decodable {
                let hasCredits: Bool?
                let unlimited: Bool?
                let balance: FlexibleNumber?
            }

            let primary: Window?
            let secondary: Window?
            let credits: Credits?
            let planType: String?
        }

        let rateLimits: RateLimits
    }

    public static func snapshot(from data: Data, fetchedAt: Date) throws -> UsageSnapshot {
        let limits: Response.RateLimits
        do {
            limits = try JSONDecoder().decode(Response.self, from: data).rateLimits
        } catch {
            throw UsageError.invalidResponse(String(describing: error))
        }

        let windows = [limits.primary, limits.secondary].compactMap { window -> UsageWindow? in
            guard let window else { return nil }
            return UsageWindow(
                label: window.windowDurationMins.map(windowLabel) ?? L("Usage"),
                percent: window.usedPercent,
                resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: $0) }
            )
        }
        guard !windows.isEmpty else {
            throw UsageError.invalidResponse("no limit windows in rateLimits")
        }

        var details: [UsageDetail] = []
        if let credits = limits.credits, credits.hasCredits == true {
            let value = credits.unlimited == true ? L("Unlimited") : (credits.balance.map { String(format: "%.0f", $0.value) } ?? "-")
            details.append(UsageDetail(label: L("Credits"), value: value))
        }

        let plan = limits.planType.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return UsageSnapshot(provider: .codex, plan: plan, windows: windows, details: details, fetchedAt: fetchedAt)
    }

    /// 300 → "5-hour", 10080 → "Weekly", 43200 → "30-day" (localized).
    static func windowLabel(minutes: Int) -> String {
        if minutes == 10080 { return L("Weekly") }
        if minutes % 1440 == 0 { return L("%ld-day", minutes / 1440) }
        if minutes % 60 == 0 { return L("%ld-hour", minutes / 60) }
        return L("%ld-minute", minutes)
    }
}

/// A JSON number that some APIs send as a string.
struct FlexibleNumber: Decodable {
    let value: Double

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            value = number
        } else {
            let text = try container.decode(String.self)
            guard let number = Double(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a number: \(text)")
            }
            value = number
        }
    }
}
