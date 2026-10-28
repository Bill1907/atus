import Foundation

/// Reads Claude subscription limits from the endpoint Claude Code's `/usage` uses.
/// The OAuth token is the one Claude Code keeps in the login keychain; atus only
/// reads it and never refreshes it, so Claude Code's own login is never disturbed.
public struct ClaudeProvider: UsageProvider {
    public let id = ProviderID.claude

    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let keychainService = "Claude Code-credentials"

    public init() {}

    public func fetch() async throws -> UsageSnapshot {
        let credentials = try Self.loadCredentials()
        if let expiresAt = credentials.expiresAt, expiresAt <= Date() {
            throw UsageError.tokenExpired("Claude Code를 한 번 실행하면 갱신돼요")
        }

        var request = URLRequest(url: Self.usageURL, timeoutInterval: 20)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            return try Self.snapshot(from: data, plan: credentials.plan, fetchedAt: Date())
        case 401:
            throw UsageError.tokenExpired("Claude Code를 한 번 실행하면 갱신돼요")
        default:
            throw UsageError.http(status: status, body: String(decoding: data, as: UTF8.self))
        }
    }

    // MARK: - Credentials

    struct Credentials {
        let accessToken: String
        let expiresAt: Date?
        let plan: String?
    }

    private struct CredentialsFile: Decodable {
        struct OAuth: Decodable {
            let accessToken: String
            let expiresAt: Double?
            let subscriptionType: String?
            let rateLimitTier: String?
        }
        let claudeAiOauth: OAuth?
    }

    /// Claude Code stores the item with `/usr/bin/security`, so that binary is on the
    /// item's ACL and can read it without a keychain prompt. Reading it through
    /// SecItemCopyMatching from atus would prompt again after every rebuild.
    static func loadCredentials() throws -> Credentials {
        let keychainJSON = try? runSecurity(["find-generic-password", "-s", keychainService, "-w"])
        let fileURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/.credentials.json")
        let candidates = [keychainJSON, try? Data(contentsOf: fileURL)].compactMap { $0 }

        for data in candidates {
            guard let oauth = try? JSONDecoder().decode(CredentialsFile.self, from: data).claudeAiOauth else { continue }
            return Credentials(
                accessToken: oauth.accessToken,
                expiresAt: oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) },
                plan: planName(subscriptionType: oauth.subscriptionType, tier: oauth.rateLimitTier)
            )
        }
        throw UsageError.credentialsMissing("Claude Code에 로그인하세요 (`claude` → /login)")
    }

    private static func runSecurity(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UsageError.credentialsMissing("keychain item \(keychainService)")
        }
        return data
    }

    static func planName(subscriptionType: String?, tier: String?) -> String? {
        if let tier {
            if tier.contains("max_20x") { return "Max 20x" }
            if tier.contains("max_5x") { return "Max 5x" }
        }
        return subscriptionType.map { $0.prefix(1).uppercased() + $0.dropFirst() }
    }

    // MARK: - Response mapping

    struct Response: Decodable {
        struct Window: Decodable {
            let utilization: Double?
            let resetsAt: String?
        }

        struct ExtraUsage: Decodable {
            let isEnabled: Bool?
            let monthlyLimit: Double?
            let usedCredits: Double?
            let currency: String?
            let decimalPlaces: Int?
            let disabledReason: String?
        }

        struct Breakdown: Decodable {
            struct Row: Decodable {
                let displayName: String
                let percent: Double
            }
            let rows: [Row]?
        }

        let fiveHour: Window?
        let sevenDay: Window?
        let sevenDayOpus: Window?
        let sevenDaySonnet: Window?
        let extraUsage: ExtraUsage?
        let sevenDayBreakdown: Breakdown?
    }

    public static func snapshot(from data: Data, plan: String?, fetchedAt: Date) throws -> UsageSnapshot {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response: Response
        do {
            response = try decoder.decode(Response.self, from: data)
        } catch {
            throw UsageError.invalidResponse(String(describing: error))
        }

        let namedWindows: [(String, Response.Window?)] = [
            ("5시간 세션", response.fiveHour),
            ("주간", response.sevenDay),
            ("주간 · Opus", response.sevenDayOpus),
            ("주간 · Sonnet", response.sevenDaySonnet),
        ]
        let windows = namedWindows.compactMap { label, window -> UsageWindow? in
            guard let window, let percent = window.utilization else { return nil }
            return UsageWindow(label: label, percent: percent, resetsAt: window.resetsAt.flatMap(ISODate.parse))
        }
        guard !windows.isEmpty else {
            throw UsageError.invalidResponse("five_hour/seven_day 없음")
        }

        var details: [UsageDetail] = []
        for row in response.sevenDayBreakdown?.rows ?? [] {
            details.append(UsageDetail(label: "이번 주 · \(row.displayName)", value: "\(Int(row.percent.rounded()))%"))
        }
        if let extra = response.extraUsage {
            let value: String
            if extra.isEnabled == true {
                let decimals = extra.decimalPlaces ?? 2
                let currency = extra.currency ?? "USD"
                value = formatMoney(minor: extra.usedCredits ?? 0, decimals: decimals, currency: currency)
                    + " / " + formatMoney(minor: extra.monthlyLimit ?? 0, decimals: decimals, currency: currency)
            } else {
                value = "꺼짐" + (extra.disabledReason.map { " (\($0))" } ?? "")
            }
            details.append(UsageDetail(label: "추가 사용량", value: value))
        }

        return UsageSnapshot(provider: .claude, plan: plan, windows: windows, details: details, fetchedAt: fetchedAt)
    }
}
