import Foundation

/// Reads GitHub Copilot quotas from `api.github.com/copilot_internal/user`, the
/// endpoint Copilot editor extensions use. The GitHub token comes from `gh auth token`
/// first, then from the Copilot editor plugins' `~/.config/github-copilot` files.
public struct CopilotProvider: UsageProvider {
    public let info = ProviderInfo(id: .copilot, displayName: "Copilot", requirement: "GitHub CLI 로그인 (gh)", icon: .bundled(.copilot))

    static let userURL = URL(string: "https://api.github.com/copilot_internal/user")!
    static var copilotConfigDirectory: String { "\(CLILocator.home)/.config/github-copilot" }

    public init() {}

    public var isDetected: Bool {
        FileManager.default.fileExists(atPath: "\(CLILocator.home)/.config/gh/hosts.yml")
            || FileManager.default.fileExists(atPath: Self.copilotConfigDirectory)
    }

    public func fetch() async throws -> UsageSnapshot {
        let tokens = Self.candidateTokens()
        guard !tokens.isEmpty else {
            throw UsageError.credentialsMissing("`gh auth login`을 실행하세요")
        }
        // A stale editor-plugin token is common, so try every source before giving up.
        for token in tokens {
            var request = URLRequest(url: Self.userURL, timeoutInterval: 20)
            request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("vscode/1.96.2", forHTTPHeaderField: "Editor-Version")
            request.setValue("copilot-chat/0.26.7", forHTTPHeaderField: "Editor-Plugin-Version")
            request.setValue("GitHubCopilotChat/0.26.7", forHTTPHeaderField: "User-Agent")
            request.setValue("2025-04-01", forHTTPHeaderField: "X-Github-Api-Version")

            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200: return try Self.snapshot(from: data, fetchedAt: Date())
            case 401, 403, 404: continue
            default: throw UsageError.http(status: status, body: String(decoding: data, as: UTF8.self))
            }
        }
        throw UsageError.tokenExpired("`gh auth login`으로 다시 로그인하세요")
    }

    static func candidateTokens() -> [String] {
        var tokens: [String] = []
        if let gh = CLILocator.find("gh"),
           let data = CLILocator.output(of: gh, ["auth", "token", "--hostname", "github.com"]) {
            let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty { tokens.append(token) }
        }
        for file in ["apps.json", "hosts.json"] {
            let url = URL(fileURLWithPath: "\(copilotConfigDirectory)/\(file)")
            guard let data = try? Data(contentsOf: url),
                  let entries = try? JSONDecoder().decode([String: CopilotHostEntry].self, from: data)
            else { continue }
            for (host, entry) in entries where host.hasPrefix("github.com") {
                if let token = entry.oauthToken, !tokens.contains(token) { tokens.append(token) }
            }
        }
        return tokens
    }

    private struct CopilotHostEntry: Decodable {
        let oauthToken: String?

        enum CodingKeys: String, CodingKey { case oauthToken = "oauth_token" }
    }

    // MARK: - Response mapping

    // Explicit keys: `.convertFromSnakeCase` would also rename the `quota_snapshots`
    // dictionary keys ("premium_interactions" → "premiumInteractions").
    struct Response: Decodable {
        struct Quota: Decodable {
            let percentRemaining: Double?
            let unlimited: Bool?
            let entitlement: Double?
            let remaining: Double?

            enum CodingKeys: String, CodingKey {
                case percentRemaining = "percent_remaining"
                case unlimited, entitlement, remaining
            }
        }

        let accessTypeSku: String?
        let copilotPlan: String?
        let quotaSnapshots: [String: Quota]?
        let quotaResetDateUtc: String?

        enum CodingKeys: String, CodingKey {
            case accessTypeSku = "access_type_sku"
            case copilotPlan = "copilot_plan"
            case quotaSnapshots = "quota_snapshots"
            case quotaResetDateUtc = "quota_reset_date_utc"
        }
    }

    /// Quota keys in display order with their labels.
    static let quotas: [(key: String, label: String)] = [
        ("premium_interactions", "프리미엄 요청"),
        ("chat", "채팅"),
        ("completions", "코드 완성"),
    ]

    public static func snapshot(from data: Data, fetchedAt: Date) throws -> UsageSnapshot {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw UsageError.invalidResponse(String(describing: error))
        }
        guard let snapshots = response.quotaSnapshots else {
            throw UsageError.invalidResponse("quota_snapshots 없음")
        }

        let resetsAt = response.quotaResetDateUtc.flatMap(ISODate.parse)
        var windows: [UsageWindow] = []
        var details: [UsageDetail] = []
        for (key, label) in quotas {
            // Unlimited quotas and ones the plan does not include (entitlement 0) have no meter.
            guard let quota = snapshots[key], quota.unlimited != true,
                  let entitlement = quota.entitlement, entitlement > 0,
                  let remainingPercent = quota.percentRemaining
            else { continue }
            windows.append(UsageWindow(label: label, percent: max(0, 100 - remainingPercent), resetsAt: resetsAt))
            if let remaining = quota.remaining {
                details.append(UsageDetail(label: "\(label) 남음", value: "\(Int(remaining)) / \(Int(entitlement))"))
            }
        }

        let plan: String?
        if response.accessTypeSku?.contains("free") == true {
            plan = "Free"
        } else {
            plan = response.copilotPlan.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        }
        return UsageSnapshot(provider: .copilot, plan: plan, windows: windows, details: details, fetchedAt: fetchedAt)
    }
}
