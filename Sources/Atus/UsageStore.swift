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
    /// Every provider ID ever offered, so a plugin added later starts enabled.
    static let seenKey = "seenProviders"

    private(set) var states: [ProviderID: ProviderState] = [:]
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    /// Providers the user tracks; persisted. At least one available provider stays
    /// enabled, so the menu bar item never vanishes.
    private(set) var enabled: Set<ProviderID>
    /// Built-ins followed by the plugins from providers.json.
    private(set) var providers: [any UsageProvider]
    /// Problems in providers.json, shown in the panel.
    private(set) var pluginErrors: [String] = []

    private let builtIn: [any UsageProvider]
    private let pluginConfigURL: URL
    private let defaults: UserDefaults

    init(
        builtIn: [any UsageProvider] = Providers.builtIn,
        pluginConfigURL: URL = PluginLoader.configURL,
        defaults: UserDefaults = .standard
    ) {
        self.builtIn = builtIn
        self.pluginConfigURL = pluginConfigURL
        self.defaults = defaults
        let plugins = PluginLoader.load(from: pluginConfigURL, reserved: Set(builtIn.map(\.id)))
        self.providers = builtIn + plugins.providers
        self.pluginErrors = plugins.errors
        self.enabled = Self.initialSelection(providers: builtIn + plugins.providers, defaults: defaults)
        persistSelection()
        Task { await runRefreshLoop() }
        Task { await refreshOnWake() }
    }

    /// Saved choice if any. Otherwise the providers whose CLI/app login is present
    /// (plugins always count), except for installs from before provider selection
    /// existed (they already have a saved menu bar position), which keep the Claude +
    /// Grok pair they had.
    private static func initialSelection(providers: [any UsageProvider], defaults: UserDefaults) -> Set<ProviderID> {
        let known = Set(providers.map(\.id))
        if let saved = defaults.stringArray(forKey: enabledKey) {
            let seen = Set((defaults.stringArray(forKey: seenKey) ?? saved).map { ProviderID($0) })
            let newPlugins = providers.filter { $0 is CommandProvider && !seen.contains($0.id) }.map(\.id)
            let selection = Set(saved.map { ProviderID($0) }).union(newPlugins)
            if !selection.intersection(known).isEmpty { return selection }
        }
        if defaults.object(forKey: "NSStatusItem Preferred Position \(StatusItemController.autosaveName)") != nil {
            return Set([.claude, .grok]).intersection(known)
        }
        let detected = Set(providers.filter(\.isDetected).map(\.id))
        return detected.isEmpty ? [providers[0].id] : detected
    }

    private func persistSelection() {
        defaults.set(enabled.map(\.rawValue).sorted(), forKey: Self.enabledKey)
        let seen = Set(defaults.stringArray(forKey: Self.seenKey) ?? []).union(providers.map(\.id.rawValue))
        defaults.set(seen.sorted(), forKey: Self.seenKey)
    }

    /// Re-reads providers.json so added, edited or removed plugins apply on the next
    /// refresh. Plugins that were never seen before start enabled.
    private func reloadPlugins() {
        let plugins = PluginLoader.load(from: pluginConfigURL, reserved: Set(builtIn.map(\.id)))
        pluginErrors = plugins.errors
        let seen = Set((defaults.stringArray(forKey: Self.seenKey) ?? []).map { ProviderID($0) })
        for plugin in plugins.providers where !seen.contains(plugin.id) {
            enabled.insert(plugin.id)
        }
        providers = builtIn + plugins.providers
        for id in states.keys where !providers.contains(where: { $0.id == id }) {
            states[id] = nil
        }
        if providerIDs.isEmpty, let first = builtIn.first {
            enabled.insert(first.id)
        }
        persistSelection()
    }

    func info(for id: ProviderID) -> ProviderInfo? {
        providers.first { $0.id == id }?.info
    }

    /// One entry per enabled provider with its menu bar text, e.g. "47%"; a trailing
    /// "!" marks a failed last refresh.
    var menuEntries: [(info: ProviderInfo, text: String)] {
        providers.filter { enabled.contains($0.id) }.map { provider in
            let state = states[provider.id]
            let text = state?.snapshot?.headlinePercent.map { "\(Int($0.rounded()))%" } ?? "–"
            return (provider.info, text + (state?.error != nil ? "!" : ""))
        }
    }

    /// Spoken/tooltip form of the label, e.g. "Claude 47% · Grok 21%".
    var menuTitle: String {
        menuEntries.map { "\($0.info.displayName) \($0.text)" }.joined(separator: " · ")
    }

    func state(for id: ProviderID) -> ProviderState {
        states[id] ?? ProviderState()
    }

    /// Enabled providers in display order.
    var providerIDs: [ProviderID] { providers.map(\.id).filter(enabled.contains) }

    /// Every available provider, for the selection list.
    var allProviders: [ProviderInfo] { providers.map(\.info) }

    func setEnabled(_ id: ProviderID, _ isOn: Bool) {
        guard isOn != enabled.contains(id), isOn || providerIDs.count > 1 else { return }
        if isOn {
            enabled.insert(id)
            Task { await fetch(providers.filter { $0.id == id }) }
        } else {
            enabled.remove(id)
            states[id] = nil
        }
        persistSelection()
    }

    /// Reloads plugins, then refreshes all enabled providers concurrently.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        reloadPlugins()
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
