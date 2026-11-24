import AppKit
import SwiftUI

final class SettingsWindowController {
    private let appCatalog: AppCatalog
    private let layoutStore: LayoutStore
    private var window: NSWindow?

    init(appCatalog: AppCatalog, layoutStore: LayoutStore) {
        self.appCatalog = appCatalog
        self.layoutStore = layoutStore
    }

    func show() {
        let win = ensureWindow()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    private func ensureWindow() -> NSWindow {
        if let existing = window {
            return existing
        }

        let settingsView = SettingsView(appCatalog: appCatalog, layoutStore: layoutStore)
        let hosting = NSHostingController(rootView: settingsView)

        let created = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        created.title = "Launchly Settings"
        created.titlebarAppearsTransparent = true
        created.isMovableByWindowBackground = true
        created.contentViewController = hosting
        created.isReleasedWhenClosed = false
        created.center()

        self.window = created
        return created
    }
}
