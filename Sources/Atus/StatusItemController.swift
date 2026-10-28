import AtusCore
import AppKit
import Observation
import SwiftUI

/// Owns the menu bar item. AppKit instead of `MenuBarExtra` for two reasons:
/// - a fixed `autosaveName`, so the position the user (or Ice/Bartender) gives the
///   item is saved and survives relaunches and updates;
/// - a compact two-line label (~30 pt instead of ~115 pt) that still fits next to
///   the notch on MacBooks with crowded menu bars.
@MainActor
final class StatusItemController: NSObject {
    static let autosaveName = "atus"

    private let store: UsageStore
    private let statusItem: NSStatusItem
    private let popover = NSPopover()

    init(store: UsageStore) {
        self.store = store

        // New status items appear left of all others, which on a notched MacBook is
        // usually behind the notch. On first launch, ask for the right end instead
        // (preferred position is the distance from the screen's right edge).
        let positionKey = "NSStatusItem Preferred Position \(Self.autosaveName)"
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(0, forKey: positionKey)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = Self.autosaveName
        statusItem.behavior = []

        super.init()

        popover.behavior = .transient
        let hostingController = NSHostingController(rootView: UsagePanel(store: store))
        // Resize the popover when the panel grows (provider picker expanded, providers added).
        hostingController.sizingOptions = .preferredContentSize
        popover.contentViewController = hostingController

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageOnly
        }
        observeStore()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    /// Re-renders the label whenever the store's values change.
    private func observeStore() {
        withObservationTracking {
            render(entries: store.menuEntries, title: store.menuTitle)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeStore() }
        }
    }

    private func render(entries: [(id: ProviderID, text: String)], title: String) {
        guard let button = statusItem.button else { return }
        button.image = Self.labelImage(entries: entries)
        button.setAccessibilityLabel(title)
        button.toolTip = title
    }

    /// Lays out one "logo + percent" row per provider, two rows per column, into a
    /// template image so the menu bar tints it for light and dark mode.
    static func labelImage(entries: [(id: ProviderID, text: String)]) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let rows = entries.map { (logo: ProviderLogo.image(for: $0.id), text: NSAttributedString(string: $0.text, attributes: attributes)) }
        let columns = stride(from: 0, to: rows.count, by: 2).map { Array(rows[$0..<min($0 + 2, rows.count)]) }
        let lineHeight = ceil(font.ascender - font.descender)
        let logoSize = lineHeight - 1.5
        let textX = logoSize + 2.5
        let columnSpacing: CGFloat = 6
        let columnWidths = columns.map { column in
            ceil(textX + (column.map { $0.text.size().width }.max() ?? 0))
        }
        let width = columnWidths.reduce(0, +) + columnSpacing * CGFloat(max(0, columns.count - 1))
        let height = max(22, lineHeight * 2)

        let image = NSImage(size: NSSize(width: max(width, 1), height: height), flipped: true) { _ in
            var x: CGFloat = 0
            for (column, columnWidth) in zip(columns, columnWidths) {
                var y = (height - lineHeight * CGFloat(column.count)) / 2
                for row in column {
                    let logoRect = NSRect(x: x, y: y + (lineHeight - logoSize) / 2, width: logoSize, height: logoSize)
                    row.logo.draw(in: logoRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                    row.text.draw(at: NSPoint(x: x + textX, y: y))
                    y += lineHeight
                }
                x += columnWidth + columnSpacing
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
