import AtusCore
import SwiftUI

struct UsagePanel: View {
    let store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(store.providerIDs) { id in
                ProviderSection(id: id, state: store.state(for: id))
                if id != store.providerIDs.last { Divider() }
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { store.refreshIfStale() }
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

private struct ProviderSection: View {
    let id: ProviderID
    let state: UsageStore.ProviderState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
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
