import Foundation

/// Supported services, in the order they appear in the panel and menu bar.
public enum ProviderID: String, Sendable, CaseIterable, Identifiable {
    case claude
    case codex
    case grok
    case cursor
    case copilot

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .grok: "Grok"
        case .cursor: "Cursor"
        case .copilot: "Copilot"
        }
    }

    /// What the user needs signed in for this provider to work.
    public var requirement: String {
        switch self {
        case .claude: "Claude Code 로그인 (Pro/Max)"
        case .codex: "Codex CLI 로그인 (ChatGPT)"
        case .grok: "Grok CLI 로그인 (SuperGrok)"
        case .cursor: "Cursor 앱 로그인"
        case .copilot: "GitHub CLI 로그인 (gh)"
        }
    }
}

/// A rate-limit window such as Claude's 5-hour session or Grok's weekly pool.
public struct UsageWindow: Sendable, Equatable, Identifiable {
    public let label: String
    /// Used share of the window, 0–100.
    public let percent: Double
    public let resetsAt: Date?

    public var id: String { label }

    public init(label: String, percent: Double, resetsAt: Date?) {
        self.label = label
        self.percent = percent
        self.resetsAt = resetsAt
    }
}

public struct UsageDetail: Sendable, Equatable, Identifiable {
    public let label: String
    public let value: String

    public var id: String { label }

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public struct UsageSnapshot: Sendable, Equatable {
    public let provider: ProviderID
    public let plan: String?
    public let windows: [UsageWindow]
    public let details: [UsageDetail]
    public let fetchedAt: Date

    public init(provider: ProviderID, plan: String?, windows: [UsageWindow], details: [UsageDetail], fetchedAt: Date) {
        self.provider = provider
        self.plan = plan
        self.windows = windows
        self.details = details
        self.fetchedAt = fetchedAt
    }

    /// The window closest to its limit; this is the one that blocks you first.
    public var headlinePercent: Double? {
        windows.map(\.percent).max()
    }
}

public protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    /// Cheap local check (credential file or CLI present), used to pick sensible
    /// defaults on first launch. Never does network I/O.
    var isDetected: Bool { get }
    func fetch() async throws -> UsageSnapshot
}

public enum Providers {
    /// One instance per supported provider, in `ProviderID` order.
    public static let all: [any UsageProvider] = [
        ClaudeProvider(), CodexProvider(), GrokProvider(), CursorProvider(), CopilotProvider(),
    ]
}

public enum UsageError: LocalizedError, Sendable, Equatable {
    case credentialsMissing(String)
    case tokenExpired(String)
    case http(status: Int, body: String)
    case invalidResponse(String)
    case timeout(String)

    public var errorDescription: String? {
        switch self {
        case .credentialsMissing(let hint): "로그인 정보 없음: \(hint)"
        case .tokenExpired(let hint): "토큰 만료: \(hint)"
        case .http(let status, let body): "HTTP \(status): \(body.prefix(160))"
        case .invalidResponse(let detail): "응답 해석 실패: \(detail)"
        case .timeout(let what): "시간 초과: \(what)"
        }
    }
}

func formatMoney(minor: Double, decimals: Int = 2, currency: String = "USD") -> String {
    let value = minor / pow(10, Double(decimals))
    let symbol = currency == "USD" ? "$" : "\(currency) "
    return symbol + String(format: "%.2f", value)
}
