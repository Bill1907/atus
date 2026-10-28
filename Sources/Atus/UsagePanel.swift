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
                ProviderSection(id: id, state: store.state(for: id))
                if id != store.providerIDs.last { Divider() }
            }
        }
    }

    private var footer: some View {
        HStack {
            if let lastRefresh = store.lastRefresh {
                Text("갱신 \(lastRefresh.formatted(date: .omitted, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await store.refresh() }
            } label: {
                if store.isRefreshing { ProgressView().controlSize(.small) } else { Text("새로고침") }
            }
            .keyboardShortcut("r")
            .disabled(store.isRefreshing)
            Button("종료") { NSApplication.shared.terminate(nil) }
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
        DisclosureGroup("서비스 선택 (\(store.providerIDs.count)/\(store.allProviderIDs.count))", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(store.allProviderIDs) { id in
                    let isOn = store.enabled.contains(id)
                    Toggle(isOn: Binding(get: { isOn }, set: { store.setEnabled(id, $0) })) {
                        HStack(spacing: 6) {
                            ProviderLogoView(id: id)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(id.displayName)
                                Text(id.requirement).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(isOn && store.enabled.count == 1)
                }
            }
            .padding(.top, 6)
        }
        .font(.caption)
    }
}

struct ProviderLogoView: View {
    let id: ProviderID
    var size: CGFloat = 13

    var body: some View {
        Image(nsImage: ProviderLogo.image(for: id))
            .renderingMode(.template)
            .resizable()
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
            Toggle("로그인 시 자동 실행", isOn: Binding(get: { isEnabled }, set: { setEnabled($0) }))
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
    let id: ProviderID
    let state: UsageStore.ProviderState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                ProviderLogoView(id: id, size: 14)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                Text(id.displayName).font(.headline)
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
                    Text("\(remaining(until: resetsAt, from: context.date)) 후 초기화 · \(resetsAt.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
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
        if days > 0 { return "\(days)일 \(hours)시간" }
        if hours > 0 { return "\(hours)시간 \(mins)분" }
        return "\(mins)분"
    }
}
