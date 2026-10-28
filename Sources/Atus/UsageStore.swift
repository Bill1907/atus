import AppKit
import AtusCore
import Observation

@MainActor
@Observable
final class UsageStore {
    struct ProviderState {
        var snapshot: UsageSnapshot?
        var error: String?
    }

    static let refreshInterval: Duration = .seconds(300)

    private(set) var states: [ProviderID: ProviderState] = [:]
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?

    private let providers: [any UsageProvider]

    init(providers: [any UsageProvider] = [ClaudeProvider(), GrokProvider()]) {
        self.providers = providers
        Task { await runRefreshLoop() }
        Task { await refreshOnWake() }
    }

    var menuTitle: String {
        providers.map { provider in
            let percent = states[provider.id]?.snapshot?.headlinePercent
            let text = percent.map { "\(Int($0.rounded()))%" } ?? "–"
            let failed = states[provider.id]?.error != nil
            return "\(provider.id.shortName) \(text)\(failed ? "!" : "")"
        }
        .joined(separator: " · ")
    }

    func state(for id: ProviderID) -> ProviderState {
        states[id] ?? ProviderState()
    }

    var providerIDs: [ProviderID] { providers.map(\.id) }

    /// Refreshes all providers concurrently. A failed provider keeps its last good
    /// snapshot and only records the error, so the menu shows stale data instead of nothing.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        await withTaskGroup(of: (ProviderID, Result<UsageSnapshot, any Error>).self) { group in
            for provider in providers {
                group.addTask {
                    do { return (provider.id, .success(try await provider.fetch())) }
                    catch { return (provider.id, .failure(error)) }
                }
            }
            for await (id, result) in group {
                var state = states[id] ?? ProviderState()
                switch result {
                case .success(let snapshot):
                    state.snapshot = snapshot
                    state.error = nil
                case .failure(let error):
                    state.error = error.localizedDescription
                }
                states[id] = state
            }
        }
        lastRefresh = Date()
    }

    /// Called when the panel opens; skips if the data is fresh enough.
    func refreshIfStale(olderThan age: TimeInterval = 60) {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < age { return }
        Task { await refresh() }
    }

    private func runRefreshLoop() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: Self.refreshInterval)
        }
    }

    private func refreshOnWake() async {
        for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification) {
            await refresh()
        }
    }
}
