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
        popover.contentViewController = NSHostingController(rootView: UsagePanel(store: store))

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

    /// Stacks one "logo + percent" row per provider into a template image, so the
    /// menu bar tints it for light and dark mode.
    static func labelImage(entries: [(id: ProviderID, text: String)]) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let rows = entries.map { (logo: ProviderLogo.image(for: $0.id), text: NSAttributedString(string: $0.text, attributes: attributes)) }
        let lineHeight = ceil(font.ascender - font.descender)
        let logoSize = lineHeight - 1.5
        let textX = logoSize + 2.5
        let width = ceil(textX + (rows.map { $0.text.size().width }.max() ?? 0))
        let height = max(22, lineHeight * CGFloat(rows.count))

        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            var y = (height - lineHeight * CGFloat(rows.count)) / 2
            for row in rows {
                let logoRect = NSRect(x: 0, y: y + (lineHeight - logoSize) / 2, width: logoSize, height: logoSize)
                row.logo.draw(in: logoRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                row.text.draw(at: NSPoint(x: textX, y: y))
                y += lineHeight
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
