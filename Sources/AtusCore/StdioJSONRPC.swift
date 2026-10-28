import Foundation

/// Runs a CLI that speaks line-delimited JSON-RPC on stdin/stdout (`grok agent stdio`,
/// `codex app-server`), sends a fixed script of messages, and returns the `result` of
/// the response with `resultID`. The process is terminated as soon as that arrives.
enum StdioJSONRPC {
    /// `Process` is not Sendable; the box lets the timeout task terminate it.
    private final class ProcessBox: @unchecked Sendable {
        let process = Process()
    }

    static func call(
        executable: URL,
        arguments: [String],
        messages: [String],
        resultID: Int,
        method: String,
        timeout: Duration = .seconds(45)
    ) async throws -> Data {
        let box = ProcessBox()
        let process = box.process
        process.executableURL = executable
        process.arguments = arguments
        process.environment = CLILocator.environment
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        try process.run()
        defer {
            if process.isRunning { process.terminate() }
        }
        stdin.fileHandleForWriting.write(Data((messages.joined(separator: "\n") + "\n").utf8))

        let reader = stdout.fileHandleForReading
        let name = executable.lastPathComponent
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                for try await line in reader.bytes.lines {
                    if let payload = try result(fromLine: line, id: resultID, method: method) { return payload }
                }
                throw UsageError.invalidResponse("\(name)가 응답 없이 종료됨")
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                // Closing the child's stdout ends the reader loop above.
                box.process.terminate()
                throw UsageError.timeout("\(name) \(method)")
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    /// Returns the JSON `result` of the response with `id`, nil for any other line,
    /// and throws when that response is a JSON-RPC error.
    static func result(fromLine line: String, id: Int, method: String) throws -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              (object["id"] as? Int) == id
        else { return nil }
        if let result = object["result"] {
            return try JSONSerialization.data(withJSONObject: result)
        }
        let message = (object["error"] as? [String: Any])?["message"] as? String ?? "unknown error"
        throw UsageError.invalidResponse("\(method): \(message)")
    }
}

/// Finds vendor CLIs from a GUI app, whose PATH lacks the usual user install locations.
enum CLILocator {
    static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    static var searchDirectories: [String] {
        ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
    }

    static func find(_ name: String, preferring directories: [String] = []) -> URL? {
        (directories + searchDirectories)
            .map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// The app's environment with the CLI install directories prepended to PATH.
    static var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (searchDirectories + [environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        return environment
    }

    /// Runs a short command and returns its stdout, or nil when it fails.
    static func output(of executable: URL, _ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}
