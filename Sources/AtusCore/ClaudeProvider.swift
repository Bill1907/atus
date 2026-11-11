import Foundation
import os

/// Reads Claude subscription limits from the endpoint Claude Code's `/usage` uses.
/// The OAuth token is the one Claude Code keeps in the login keychain. atus only reads
/// it and never refreshes it itself: when it has expired, atus starts Claude Code, which
/// renews its own login, and then reads the keychain again.
public struct ClaudeProvider: UsageProvider {
    public let info = ProviderInfo(id: .claude, displayName: "Claude", requirement: L("Claude Code sign-in (Pro/Max)"), icon: .bundled(.claude))

    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let keychainService = "Claude Code-credentials"

    public init() {}

    /// Claude Code keeps its login in the keychain; its config directory is the cheap,
    /// prompt-free signal that it is installed.
    public var isDetected: Bool {
        FileManager.default.fileExists(atPath: "\(CLILocator.home)/.claude")
    }

    public func fetch() async throws -> UsageSnapshot {
        var credentials = try Self.loadCredentials()
        if Self.needsRenewal(expiresAt: credentials.expiresAt, now: Date()) {
            // A failed renewal is not fatal by itself: a token inside the margin still
            // works for this call, and an expired one is reported just below.
            await RenewalGate.shared.renew()
            credentials = try Self.loadCredentials()
        }
        if let expiresAt = credentials.expiresAt, expiresAt <= Date() {
            throw Self.tokenExpired
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
            throw Self.tokenExpired
        default:
            throw UsageError.http(status: status, body: String(decoding: data, as: UTF8.self))
        }
    }

    private static var tokenExpired: UsageError {
        .tokenExpired(L("Run Claude Code once to renew it"))
    }

    // MARK: - Renewal

    /// A token is renewed this long before it expires, so it is never sent in its last
    /// seconds. The same margin `GrokProvider.fetch` uses.
    static let renewalMargin: TimeInterval = 60

    /// After a failed attempt, Claude Code is not started again for this long.
    static let renewalCooldown: TimeInterval = 600

    static let initializeRequestID = "atus-1"

    /// The only thing atus sends to Claude Code: a control request, never a user message,
    /// so no model is called and no usage is spent.
    private static let initializeRequest = Data(
        #"{"type":"control_request","request_id":"\#(initializeRequestID)","request":{"subtype":"initialize"}}\#n"#.utf8
    )

    static func needsRenewal(expiresAt: Date?, now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(renewalMargin)
    }

    static func mayAttemptRenewal(lastFailure: Date?, now: Date) -> Bool {
        guard let lastFailure else { return true }
        return now.timeIntervalSince(lastFailure) >= renewalCooldown
    }

    /// True for the stdout line in which Claude Code answers our `initialize` request
    /// with success.
    static func isInitializeResponse(line: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "control_response",
              let response = object["response"] as? [String: Any]
        else { return false }
        return response["request_id"] as? String == initializeRequestID
            && response["subtype"] as? String == "success"
    }

    /// Has Claude Code renew its own login. A headless session that is sent only the
    /// `initialize` control request is enough: Claude Code renews an expired token without
    /// calling a model (confirmed on claude 2.1.321; `claude auth status` does not renew).
    ///
    /// Killing Claude Code in the middle of a renewal can log the user out, because the
    /// refresh token rotates. So the session runs in its own task, which a cancelled
    /// caller cannot cut short, and it always ends the same way: stdin is closed and the
    /// process is left to exit by itself.
    static func renewViaCLI() async throws {
        guard let executable = CLILocator.find("claude") else { throw tokenExpired }
        try await Task { try await runRenewal(with: executable) }.value
    }

    private static func runRenewal(with executable: URL) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json",
            "--verbose", "--safe-mode", "--no-session-persistence",
        ]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        // Without these overrides Claude Code uses, and so renews, the default login
        // that atus reads.
        var environment = CLILocator.environment
        for name in ["CLAUDE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY"] {
            environment[name] = nil
        }
        process.environment = environment
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        // stdout is read for as long as the process lives, so a full pipe can never
        // block it. A handler rather than `bytes.lines`: it holds no thread while Claude
        // Code is silent, and it can be removed.
        let output = OSAllocatedUnfairLock(initialState: Output())
        let reader = stdout.fileHandleForReading
        reader.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                output.withLock { $0.ended = true }
                return
            }
            output.withLock { state in
                // Once the response is in, the rest is only drained.
                guard !state.responded else { return }
                var rest = chunk[...]
                while let newline = rest.firstIndex(of: 0x0A) {
                    state.line.append(rest[..<newline])
                    if isInitializeResponse(line: state.line) {
                        state.responded = true
                        state.line = Data()
                        return
                    }
                    state.line.removeAll(keepingCapacity: true)
                    rest = rest[(newline + 1)...]
                }
                state.line.append(rest)
            }
        }
        defer { reader.readabilityHandler = nil }

        try process.run()
        // No wait below runs past this; the three of them add up to it.
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(45)

        // If Claude Code died at once, writing to its pipe would kill atus with SIGPIPE.
        let input = stdin.fileHandleForWriting
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        try? input.write(contentsOf: initializeRequest)

        _ = await poll(every: .milliseconds(100), until: min(clock.now + .seconds(15), deadline)) {
            output.withLock { $0.responded || $0.ended }
        }
        let (responded, ended) = output.withLock { ($0.responded, $0.ended) }

        // Whether Claude Code stores the renewed token before or after it answers is not
        // known, so the keychain decides, not the response.
        var renewed = false
        if responded {
            renewed = await poll(every: .seconds(1), until: min(clock.now + .seconds(20), deadline)) {
                hasFreshToken()
            }
        }

        // Closing stdin ends the session and Claude Code exits by itself. SIGTERM is only
        // the last resort against a leaked process.
        try? input.close()
        let exited = await poll(every: .milliseconds(100), until: min(clock.now + .seconds(10), deadline)) {
            !process.isRunning
        }
        if !exited { process.terminate() }

        let name = executable.lastPathComponent
        guard responded else {
            throw ended
                ? UsageError.invalidResponse(L("%@ exited without a response", name))
                : UsageError.timeout("\(name) initialize")
        }
        guard renewed else { throw tokenExpired }
    }

    /// What the stdout handler has seen so far.
    private struct Output {
        var line = Data()
        var responded = false
        var ended = false
    }

    /// Checks `condition` every `interval` until it holds or `deadline` has passed, and
    /// returns whether it held. Only called from the renewal task, which is never
    /// cancelled, so the sleep cannot be cut short.
    private static func poll(
        every interval: Duration,
        until deadline: ContinuousClock.Instant,
        _ condition: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        while !condition() {
            let now = clock.now
            guard now < deadline else { return false }
            try? await clock.sleep(until: min(now + interval, deadline))
        }
        return true
    }

    private static func hasFreshToken() -> Bool {
        guard let credentials = try? loadCredentials() else { return false }
        return !needsRenewal(expiresAt: credentials.expiresAt, now: Date())
    }

    /// Shared by every `fetch()`: at most one Claude Code process at a time, and after a
    /// failed attempt none for `renewalCooldown`.
    private actor RenewalGate {
        static let shared = RenewalGate()

        private var inFlight: Task<Void, any Error>?
        private var lastFailure: Date?

        /// Joins the attempt in flight, or starts one unless the cooldown forbids it.
        func renew() async {
            if let inFlight {
                _ = await inFlight.result
                return
            }
            guard ClaudeProvider.mayAttemptRenewal(lastFailure: lastFailure, now: Date()) else { return }
            let attempt = Task { try await ClaudeProvider.renewViaCLI() }
            inFlight = attempt
            let result = await attempt.result
            inFlight = nil
            switch result {
            case .success: lastFailure = nil
            case .failure: lastFailure = Date()
            }
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
        let keychainJSON = CLILocator.output(
            of: URL(fileURLWithPath: "/usr/bin/security"),
            ["find-generic-password", "-s", keychainService, "-w"]
        )
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
        throw UsageError.credentialsMissing(L("Sign in to Claude Code (`claude` → /login)"))
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
            (L("5-hour session"), response.fiveHour),
            (L("Weekly"), response.sevenDay),
            (L("Weekly · Opus"), response.sevenDayOpus),
            (L("Weekly · Sonnet"), response.sevenDaySonnet),
        ]
        let windows = namedWindows.compactMap { label, window -> UsageWindow? in
            guard let window, let percent = window.utilization else { return nil }
            return UsageWindow(label: label, percent: percent, resetsAt: window.resetsAt.flatMap(ISODate.parse))
        }
        guard !windows.isEmpty else {
            throw UsageError.invalidResponse("missing five_hour/seven_day")
        }

        var details: [UsageDetail] = []
        for row in response.sevenDayBreakdown?.rows ?? [] {
            details.append(UsageDetail(label: L("This week · %@", row.displayName), value: "\(Int(row.percent.rounded()))%"))
        }
        if let extra = response.extraUsage {
            let value: String
            if extra.isEnabled == true {
                let decimals = extra.decimalPlaces ?? 2
                let currency = extra.currency ?? "USD"
                value = formatMoney(minor: extra.usedCredits ?? 0, decimals: decimals, currency: currency)
                    + " / " + formatMoney(minor: extra.monthlyLimit ?? 0, decimals: decimals, currency: currency)
            } else {
                value = extra.disabledReason.map { L("Off (%@)", $0) } ?? L("Off")
            }
            details.append(UsageDetail(label: L("Extra usage"), value: value))
        }

        return UsageSnapshot(provider: .claude, plan: plan, windows: windows, details: details, fetchedAt: fetchedAt)
    }
}
