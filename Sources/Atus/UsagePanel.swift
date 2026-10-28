import AtusCore
import ServiceManagement
import SwiftUI

struct UsagePanel: View {
    let store: UsageStore

    /// Above this many providers the usage list scrolls instead of growing the popover.
    private static let maxUnscrolledProviders = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if store.providerIDs.count > Self.maxUnscrolledProviders {
                ScrollView { providerList }
                    .frame(height: 520)
            } else {
                providerList
            }
            Divider()
            ProviderPicker(store: store)
            LaunchAtLoginToggle()
            footer
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { store.refreshIfStale() }
    }

    private var providerList: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(store.providerIDs) { id in
                if let info = store.info(for: id) {
                    ProviderSection(info: info, state: store.state(for: id))
                }
                if id != store.providerIDs.last { Divider() }
            }
        }
    }

    private var footer: some View {
        HStack {
            if let lastRefresh = store.lastRefresh {
                Text(L("Updated %@", lastRefresh.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(appLocale))))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await store.refresh() }
            } label: {
                if store.isRefreshing { ProgressView().controlSize(.small) } else { Text(L("Refresh")) }
            }
            .keyboardShortcut("r")
            .disabled(store.isRefreshing)
            Button(L("Quit")) { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .font(.caption)
    }
}

/// Lets the user choose which services atus tracks. The last enabled one can't be
/// turned off, so the menu bar item always has something to show.
private struct ProviderPicker: View {
    let store: UsageStore
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(store.allProviders) { info in
                    let isOn = store.enabled.contains(info.id)
                    Toggle(isOn: Binding(get: { isOn }, set: { store.setEnabled(info.id, $0) })) {
                        HStack(spacing: 6) {
                            ProviderLogoView(icon: info.icon)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(info.displayName)
                                Text(info.requirement).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(isOn && store.providerIDs.count == 1)
                }
                ForEach(store.pluginErrors, id: \.self) { error in
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(L("Open plugin settings (providers.json)")) { openPluginConfig() }
                    .buttonStyle(.link)
                    .font(.caption2)
            }
            .padding(.top, 6)
        } label: {
            Text(L("Choose services (%ld/%ld)", store.providerIDs.count, store.allProviders.count))
        }
        .font(.caption)
    }

    /// Opens providers.json, creating an empty one first so there is something to edit.
    private func openPluginConfig() {
        let url = PluginLoader.configURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("{\n  \"providers\": []\n}\n".utf8).write(to: url)
        }
        NSWorkspace.shared.open(url)
    }
}

struct ProviderLogoView: View {
    let icon: ProviderIcon
    var size: CGFloat = 13

    var body: some View {
        Image(nsImage: ProviderLogo.image(for: icon))
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }
}

/// Registers the installed app as a login item (System Settings → General → Login Items).
private struct LaunchAtLoginToggle: View {
    @State private var isEnabled = SMAppService.mainApp.status == .enabled
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // A closure, not `set: setEnabled`: Swift 6.3 crashes in IRGen on the method-reference thunk.
            Toggle(L("Launch at login"), isOn: Binding(get: { isEnabled }, set: { setEnabled($0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
            if let error {
                Text(error).font(.caption2).foregroundStyle(.orange)
            }
        }
        .font(.caption)
    }

    private func setEnabled(_ enable: Bool) {
        do {
            if enable { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}

private struct ProviderSection: View {
    let info: ProviderInfo
    let state: UsageStore.ProviderState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                ProviderLogoView(icon: info.icon, size: 14)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                Text(info.displayName).font(.headline)
                if let plan = state.snapshot?.plan {
                    Text(plan).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let error = state.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let snapshot = state.snapshot {
                ForEach(snapshot.windows) { WindowRow(window: $0) }
                ForEach(snapshot.details) { detail in
                    HStack {
                        Text(detail.label).foregroundStyle(.secondary)
                        Spacer()
                        Text(detail.value).monospacedDigit()
                    }
                    .font(.caption)
                }
            } else if state.error == nil {
                ProgressView().controlSize(.small)
            }
        }
    }
}

private struct WindowRow: View {
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.label)
                Spacer()
                Text("\(Int(window.percent.rounded()))%").monospacedDigit().bold()
            }
            .font(.callout)
            ProgressView(value: min(window.percent, 100), total: 100)
                .tint(tint)
            if let resetsAt = window.resetsAt {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(L("Resets in %@ · %@", remaining(until: resetsAt, from: context.date), resetsAt.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(appLocale))))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var tint: Color {
        switch window.percent {
        case ..<70: .green
        case ..<90: .orange
        default: .red
        }
    }

    private func remaining(until date: Date, from now: Date) -> String {
        let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
        let days = minutes / 1440
        let hours = minutes % 1440 / 60
        let mins = minutes % 60
        if days > 0 { return L("%ldd %ldh", days, hours) }
        if hours > 0 { return L("%ldh %ldm", hours, mins) }
        return L("%ldm", mins)
    }
}
