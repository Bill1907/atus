import Foundation
import Testing
@testable import AtusCore

@Suite struct CommandProviderTests {
    private func provider(_ command: String, timeout: Duration = .seconds(10)) -> CommandProvider {
        CommandProvider(
            info: ProviderInfo(id: ProviderID("test"), displayName: "Test", requirement: "", icon: .symbol("star")),
            command: command,
            timeout: timeout
        )
    }

    @Test func readsSnapshotFromCommandOutput() async throws {
        let json = #"{"plan":"Pro","windows":[{"label":"5h","percent":12.5,"resetsAt":"2026-10-28T12:00:00Z"},{"label":"week","percent":40,"resetsAt":1798248843}],"details":[{"label":"Credits","value":"$4.20"}]}"#
        let snapshot = try await provider("printf '%s' '\(json)'").fetch()

        #expect(snapshot.provider == ProviderID("test"))
        #expect(snapshot.plan == "Pro")
        #expect(snapshot.headlinePercent == 40)
        #expect(snapshot.windows.map(\.resetsAt) == [ISODate.parse("2026-10-28T12:00:00Z"), Date(timeIntervalSince1970: 1798248843)])
        #expect(snapshot.details == [UsageDetail(label: "Credits", value: "$4.20")])
    }

    @Test func reportsLastStderrLineOnFailure() async {
        await #expect(throws: UsageError.pluginFailed("token expired")) {
            try await provider("echo noise >&2; echo 'token expired' >&2; exit 3").fetch()
        }
    }

    @Test func rejectsOutputThatIsNotTheSchema() async {
        await #expect(throws: UsageError.self) {
            try await provider("echo '{\"windows\":[{\"label\":\"x\"}]}'").fetch()
        }
    }

    @Test func terminatesCommandsThatRunTooLong() async {
        let start = Date()
        await #expect(throws: UsageError.timeout("플러그인 명령")) {
            try await provider("sleep 5", timeout: .milliseconds(300)).fetch()
        }
        #expect(Date().timeIntervalSince(start) < 3)
    }
}

@Suite struct PluginLoaderTests {
    private func write(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "atus-providers-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        return url
    }

    @Test func missingFileMeansNoPlugins() {
        let result = PluginLoader.load(from: URL(fileURLWithPath: "/nonexistent/providers.json"), reserved: [])
        #expect(result.providers.isEmpty)
        #expect(result.errors.isEmpty)
    }

    @Test func loadsValidEntriesAndReportsInvalidOnes() throws {
        let url = try write("""
        {"providers": [
          {"id": "gemini", "name": "Gemini", "command": "~/bin/gemini.sh", "icon": "sparkles", "timeout": 5},
          {"id": "claude", "name": "Mine", "command": "true"},
          {"id": "gemini", "name": "Again", "command": "true"},
          {"id": "", "name": "Empty", "command": "true"},
          {"id": "logo", "name": "Logo", "command": "true", "icon": "~/logos/x.svg"}
        ]}
        """)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = PluginLoader.load(from: url, reserved: [.claude])

        #expect(result.providers.map(\.id.rawValue) == ["gemini", "logo"])
        #expect(result.providers[0].info.icon == .symbol("sparkles"))
        #expect(result.providers[0].timeout == .seconds(5))
        #expect(result.providers[1].info.icon == .file(NSString(string: "~/logos/x.svg").expandingTildeInPath))
        #expect(result.errors.count == 3)
    }

    @Test func malformedJSONIsAnErrorNotACrash() throws {
        let url = try write(#"{"providers": [ {"id": "x" "#)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = PluginLoader.load(from: url, reserved: [])
        #expect(result.providers.isEmpty)
        #expect(result.errors.count == 1)
    }
}
