import Foundation

/// A user-defined provider: atus runs the configured shell command and reads usage
/// from the JSON it prints. This is how services without a built-in provider are
/// added; the script decides how (and whether) to authenticate, not atus.
///
/// Expected stdout:
/// ```json
/// {
///   "plan": "Pro",
///   "windows": [{ "label": "5h", "percent": 12.5, "resetsAt": "2026-10-28T12:00:00Z" }],
///   "details": [{ "label": "Credits", "value": "$4.20" }]
/// }
/// ```
/// `resetsAt` is ISO-8601 or Unix seconds. A non-zero exit fails the refresh with the
/// last line of stderr as the message.
public struct CommandProvider: UsageProvider {
    public let info: ProviderInfo
    public let command: String
    public let timeout: Duration

    public init(info: ProviderInfo, command: String, timeout: Duration = .seconds(30)) {
        self.info = info
        self.command = command
        self.timeout = timeout
    }

    /// The user configured it explicitly, so it is always "present".
    public var isDetected: Bool { true }

    public func fetch() async throws -> UsageSnapshot {
        let result = try await ShellCommand.run(command, timeout: timeout)
        guard result.status == 0 else {
            let lastLine = String(decoding: result.stderr, as: UTF8.self)
                .split(whereSeparator: \.isNewline).last.map(String.init)
            throw UsageError.pluginFailed(lastLine ?? "exit \(result.status)")
        }
        return try Self.snapshot(from: result.stdout, provider: info.id, fetchedAt: Date())
    }

    // MARK: - Output mapping

    struct Output: Decodable {
        struct Window: Decodable {
            let label: String
            let percent: Double
            let resetsAt: Timestamp?
        }

        struct Detail: Decodable {
            let label: String
            let value: String
        }

        let plan: String?
        let windows: [Window]?
        let details: [Detail]?
    }

    /// ISO-8601 string or Unix seconds.
    struct Timestamp: Decodable {
        let date: Date

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                date = Date(timeIntervalSince1970: seconds)
            } else {
                let text = try container.decode(String.self)
                guard let parsed = ISODate.parse(text) else {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "resetsAt is not ISO-8601: \(text)")
                }
                date = parsed
            }
        }
    }

    public static func snapshot(from data: Data, provider: ProviderID, fetchedAt: Date) throws -> UsageSnapshot {
        let output: Output
        do {
            output = try JSONDecoder().decode(Output.self, from: data)
        } catch {
            throw UsageError.invalidResponse("플러그인 출력이 형식과 달라요: \(error)")
        }
        let windows = (output.windows ?? []).map {
            UsageWindow(label: $0.label, percent: $0.percent, resetsAt: $0.resetsAt?.date)
        }
        let details = (output.details ?? []).map { UsageDetail(label: $0.label, value: $0.value) }
        return UsageSnapshot(provider: provider, plan: output.plan, windows: windows, details: details, fetchedAt: fetchedAt)
    }
}

/// Reads user plugins from `~/.config/atus/providers.json`.
public enum PluginLoader {
    public static var configURL: URL {
        URL(fileURLWithPath: "\(CLILocator.home)/.config/atus/providers.json")
    }

    struct Config: Decodable {
        struct Entry: Decodable {
            let id: String
            let name: String
            let command: String
            let icon: String?
            let requirement: String?
            let timeout: Double?
        }

        let providers: [Entry]
    }

    public struct Result: Sendable {
        public let providers: [CommandProvider]
        /// Problems with the config; valid entries still load.
        public let errors: [String]
    }

    /// A missing file means no plugins. `reserved` holds built-in IDs a plugin may not reuse.
    public static func load(from url: URL = configURL, reserved: Set<ProviderID>) -> Result {
        guard let data = try? Data(contentsOf: url) else { return Result(providers: [], errors: []) }
        let config: Config
        do {
            config = try JSONDecoder().decode(Config.self, from: data)
        } catch {
            return Result(providers: [], errors: ["\(url.lastPathComponent): \(error)"])
        }

        var providers: [CommandProvider] = []
        var errors: [String] = []
        var seen = reserved
        for entry in config.providers {
            let id = ProviderID(entry.id.trimmingCharacters(in: .whitespaces))
            if id.rawValue.isEmpty || entry.name.isEmpty || entry.command.isEmpty {
                errors.append("'\(entry.id)': id, name, command는 비울 수 없어요")
                continue
            }
            if seen.contains(id) {
                errors.append("'\(id.rawValue)': 이미 쓰고 있는 id예요")
                continue
            }
            seen.insert(id)
            let info = ProviderInfo(
                id: id,
                displayName: entry.name,
                requirement: entry.requirement ?? "플러그인",
                icon: icon(from: entry.icon)
            )
            providers.append(CommandProvider(info: info, command: entry.command, timeout: .seconds(entry.timeout ?? 30)))
        }
        return Result(providers: providers, errors: errors)
    }

    /// A value with a "/" or an image extension is a file path (with `~` expanded);
    /// anything else is an SF Symbol name.
    static func icon(from value: String?) -> ProviderIcon {
        guard let value, !value.isEmpty else { return .symbol("puzzlepiece.extension") }
        let lowercased = value.lowercased()
        if value.contains("/") || lowercased.hasSuffix(".svg") || lowercased.hasSuffix(".png") {
            return .file(NSString(string: value).expandingTildeInPath)
        }
        return .symbol(value)
    }
}

/// Runs `/bin/sh -c <command>` and collects its output, terminating it on timeout.
enum ShellCommand {
    struct Output {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    /// `Process` is not Sendable; the box lets the timeout task terminate it.
    private final class ProcessBox: @unchecked Sendable {
        let process = Process()
    }

    static func run(_ command: String, timeout: Duration) async throws -> Output {
        let box = ProcessBox()
        let process = box.process
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = CLILocator.environment
        process.currentDirectoryURL = URL(fileURLWithPath: CLILocator.home)
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let watchdog = Task {
            do {
                try await Task.sleep(for: timeout)
                box.process.terminate()
                return true
            } catch {
                return false
            }
        }
        // Both pipes are drained concurrently so a chatty stderr can't block the child.
        async let out = collect(stdout.fileHandleForReading)
        async let err = collect(stderr.fileHandleForReading)
        let (outData, errData) = try await (out, err)
        process.waitUntilExit()
        watchdog.cancel()
        if await watchdog.value {
            throw UsageError.timeout("플러그인 명령")
        }
        return Output(status: process.terminationStatus, stdout: outData, stderr: errData)
    }

    private static func collect(_ handle: FileHandle) async throws -> Data {
        var data = Data()
        for try await byte in handle.bytes { data.append(byte) }
        return data
    }
}
