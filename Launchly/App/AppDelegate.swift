import AppKit
import Combine
import Foundation
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let appCatalog = AppCatalog()
    private let layoutStore = LayoutStore()
    private let metadataStore = AppMetadataStore()
    private let spotlightIndex = SpotlightAppIndex()

    private var overlayController: OverlayWindowController?
    private var settingsController: SettingsWindowController?
    private var cancellables = Set<AnyCancellable>()

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.aryanfulari.Launchly",
        category: "AppDelegate"
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchlySettings.registerDefaults()

        appCatalog.$allApps
            .receive(on: DispatchQueue.main)
            .filter { !$0.isEmpty }
            .sink { [weak self] scannedApps in
                guard let self else { return }
                self.layoutStore.reconcile(knownAppIDs: scannedApps.map(\.id))
                self.metadataStore.update(for: scannedApps)
            }
            .store(in: &cancellables)

        spotlightIndex.start()

        let overlay = OverlayWindowController(
            appCatalog: appCatalog,
            layoutStore: layoutStore,
            metadataStore: metadataStore,
            spotlightIndex: spotlightIndex
        )
        let settings = SettingsWindowController(appCatalog: appCatalog, layoutStore: layoutStore)
        overlay.onOpenSettings = { [weak self] in
            self?.settingsController?.show()
        }
        overlayController = overlay
        settingsController = settings

        setupStatusItem()
        setupGestureMonitor()
        setupHotKey()

        if !UserDefaults.standard.bool(forKey: LaunchlySettings.Keys.hasShownOnboarding) {
            UserDefaults.standard.set(true, forKey: LaunchlySettings.Keys.hasShownOnboarding)
            settings.show()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            logger.info("Received URL: \(url.absoluteString, privacy: .public)")
            guard url.scheme?.lowercased() == "launchly" else { continue }
            switch url.host?.lowercased() {
            case "show":
                overlayController?.show()
            case "hide":
                overlayController?.hide(restoreFocus: true)
            case "toggle":
                overlayController?.toggle()
            default:
                break
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Private Setup

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: "Launchly")
            image?.isTemplate = true
            button.image = image
        }

        let menu = NSMenu()
        let showItem = NSMenuItem(title: "Show Launchly", action: #selector(showLauncher), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Launchly", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    private func setupGestureMonitor() {
        let monitor = MultitouchGestureMonitor.shared
        monitor.onGesture = { [weak self] event in
            guard let self, let overlay = self.overlayController else { return }
            switch event {
            case .pinchIn:
                if !overlay.isVisible {
                    overlay.show()
                }
            case .pinchOut:
                if overlay.isVisible {
                    overlay.hide(restoreFocus: true)
                }
            }
        }

        let sensitivity = UserDefaults.standard.object(forKey: LaunchlySettings.Keys.pinchSensitivity) as? Double
            ?? LaunchlySettings.Defaults.pinchSensitivity
        monitor.setSensitivity(sensitivity)

        let enabled = UserDefaults.standard.bool(forKey: LaunchlySettings.Keys.pinchEnabled)
        monitor.setEnabled(enabled)
    }

    private func setupHotKey() {
        let hotKey = GlobalHotKey.shared
        hotKey.onTrigger = { [weak self] in
            self?.overlayController?.toggle()
        }

        let enabled = UserDefaults.standard.bool(forKey: LaunchlySettings.Keys.hotKeyEnabled)
        hotKey.setEnabled(enabled)
    }

    // MARK: - Actions

    @objc private func showLauncher() {
        overlayController?.show()
    }

    @objc private func openSettings() {
        settingsController?.show()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
