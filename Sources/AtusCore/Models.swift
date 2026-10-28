import Foundation

/// Identifies a provider: one of the built-ins below, or a user plugin's `id`.
public struct ProviderID: RawRepresentable, Hashable, Sendable, Identifiable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public var id: String { rawValue }

    public static let claude = ProviderID("claude")
    public static let codex = ProviderID("codex")
    public static let grok = ProviderID("grok")
    public static let cursor = ProviderID("cursor")
    public static let copilot = ProviderID("copilot")
}

/// How a provider's logo is drawn in the menu bar and panel.
public enum ProviderIcon: Sendable, Equatable {
    /// A logo shipped with atus.
    case bundled(ProviderID)
    /// An SF Symbol name, e.g. "sparkles".
    case symbol(String)
    /// Path to an SVG or PNG file; drawn as a monochrome template image.
    case file(String)
}

public struct ProviderInfo: Sendable, Equatable, Identifiable {
    public let id: ProviderID
    public let displayName: String
    /// What the user needs signed in or set up for this provider to work.
    public let requirement: String
    public let icon: ProviderIcon

    public init(id: ProviderID, displayName: String, requirement: String, icon: ProviderIcon) {
        self.id = id
        self.displayName = displayName
        self.requirement = requirement
        self.icon = icon
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
    var info: ProviderInfo { get }
    /// Cheap local check (credential file or CLI present), used to pick sensible
    /// defaults on first launch. Never does network I/O.
    var isDetected: Bool { get }
    func fetch() async throws -> UsageSnapshot
}

extension UsageProvider {
    public var id: ProviderID { info.id }
}

public enum Providers {
    /// The providers built into atus, in display order. User plugins follow them.
    public static let builtIn: [any UsageProvider] = [
        ClaudeProvider(), CodexProvider(), GrokProvider(), CursorProvider(), CopilotProvider(),
    ]
}

public enum UsageError: LocalizedError, Sendable, Equatable {
    case credentialsMissing(String)
    case tokenExpired(String)
    case http(status: Int, body: String)
    case invalidResponse(String)
    case timeout(String)
    case pluginFailed(String)

    public var errorDescription: String? {
        switch self {
        case .credentialsMissing(let hint): "로그인 정보 없음: \(hint)"
        case .tokenExpired(let hint): "토큰 만료: \(hint)"
        case .http(let status, let body): "HTTP \(status): \(body.prefix(160))"
        case .invalidResponse(let detail): "응답 해석 실패: \(detail)"
        case .timeout(let what): "시간 초과: \(what)"
        case .pluginFailed(let message): "플러그인 오류: \(message.prefix(200))"
        }
    }
}

func formatMoney(minor: Double, decimals: Int = 2, currency: String = "USD") -> String {
    let value = minor / pow(10, Double(decimals))
    let symbol = currency == "USD" ? "$" : "\(currency) "
    return symbol + String(format: "%.2f", value)
}
