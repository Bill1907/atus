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
    static let enabledKey = "enabledProviders"

    private(set) var states: [ProviderID: ProviderState] = [:]
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    /// Providers the user tracks; persisted. Never empty, so the menu bar item never vanishes.
    private(set) var enabled: Set<ProviderID>

    private let providers: [any UsageProvider]
    private let defaults: UserDefaults

    init(providers: [any UsageProvider] = Providers.all, defaults: UserDefaults = .standard) {
        self.providers = providers
        self.defaults = defaults
        self.enabled = Self.initialSelection(providers: providers, defaults: defaults)
        defaults.set(enabled.map(\.rawValue).sorted(), forKey: Self.enabledKey)
        Task { await runRefreshLoop() }
        Task { await refreshOnWake() }
    }

    /// Saved choice if any. Otherwise the providers whose CLI/app login is present,
    /// except for installs from before provider selection existed (they already have a
    /// saved menu bar position), which keep the Claude + Grok pair they had.
    private static func initialSelection(providers: [any UsageProvider], defaults: UserDefaults) -> Set<ProviderID> {
        let known = Set(providers.map(\.id))
        if let saved = defaults.stringArray(forKey: enabledKey) {
            let selection = Set(saved.compactMap(ProviderID.init(rawValue:))).intersection(known)
            if !selection.isEmpty { return selection }
        }
        if defaults.object(forKey: "NSStatusItem Preferred Position \(StatusItemController.autosaveName)") != nil {
            return Set([.claude, .grok]).intersection(known)
        }
        let detected = Set(providers.filter(\.isDetected).map(\.id))
        return detected.isEmpty ? [providers[0].id] : detected
    }

    /// One entry per enabled provider with its menu bar text, e.g. "47%"; a trailing
    /// "!" marks a failed last refresh.
    var menuEntries: [(id: ProviderID, text: String)] {
        providerIDs.map { id in
            let percent = states[id]?.snapshot?.headlinePercent
            let text = percent.map { "\(Int($0.rounded()))%" } ?? "–"
            let failed = states[id]?.error != nil
            return (id, text + (failed ? "!" : ""))
        }
    }

    /// Spoken/tooltip form of the label, e.g. "Claude 47% · Grok 21%".
    var menuTitle: String {
        menuEntries.map { "\($0.id.displayName) \($0.text)" }.joined(separator: " · ")
    }

    func state(for id: ProviderID) -> ProviderState {
        states[id] ?? ProviderState()
    }

    /// Enabled providers in display order.
    var providerIDs: [ProviderID] { providers.map(\.id).filter(enabled.contains) }

    /// Every supported provider, for the selection list.
    var allProviderIDs: [ProviderID] { providers.map(\.id) }

    func setEnabled(_ id: ProviderID, _ isOn: Bool) {
        guard isOn != enabled.contains(id), isOn || enabled.count > 1 else { return }
        if isOn {
            enabled.insert(id)
            Task { await fetch(providers.filter { $0.id == id }) }
        } else {
            enabled.remove(id)
            states[id] = nil
        }
        defaults.set(enabled.map(\.rawValue).sorted(), forKey: Self.enabledKey)
    }

    /// Refreshes all enabled providers concurrently.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await fetch(providers.filter { enabled.contains($0.id) })
        lastRefresh = Date()
    }

    /// A failed provider keeps its last good snapshot and only records the error, so
    /// the menu shows stale data instead of nothing.
    private func fetch(_ targets: [any UsageProvider]) async {
        await withTaskGroup(of: (ProviderID, Result<UsageSnapshot, any Error>).self) { group in
            for provider in targets {
                group.addTask {
                    do { return (provider.id, .success(try await provider.fetch())) }
                    catch { return (provider.id, .failure(error)) }
                }
            }
            for await (id, result) in group {
                // Disabled while the request was in flight: drop the result.
                guard enabled.contains(id) else { continue }
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
