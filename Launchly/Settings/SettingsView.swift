import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var appCatalog: AppCatalog
    @ObservedObject var layoutStore: LayoutStore

    @AppStorage(LaunchlySettings.Keys.pinchEnabled) private var pinchEnabled: Bool = LaunchlySettings.Defaults.pinchEnabled
    @AppStorage(LaunchlySettings.Keys.pinchSensitivity) private var pinchSensitivity: Double = LaunchlySettings.Defaults.pinchSensitivity
    @AppStorage(LaunchlySettings.Keys.hotKeyEnabled) private var hotKeyEnabled: Bool = LaunchlySettings.Defaults.hotKeyEnabled
    @AppStorage(LaunchlySettings.Keys.gridRows) private var gridRows: Int = LaunchlySettings.Defaults.gridRows
    @AppStorage(LaunchlySettings.Keys.gridColumns) private var gridColumns: Int = LaunchlySettings.Defaults.gridColumns
    @AppStorage(LaunchlySettings.Keys.iconSize) private var iconSize: Double = LaunchlySettings.Defaults.iconSize
    @AppStorage(LaunchlySettings.Keys.sortMode) private var sortModeRaw: String = LaunchlySettings.Defaults.sortMode
    @AppStorage(LaunchlySettings.Keys.sortAscending) private var sortAscending: Bool = LaunchlySettings.Defaults.sortAscending
    @AppStorage(LaunchlySettings.Keys.pagingDuration) private var pagingDuration: Double = LaunchlySettings.Defaults.pagingDuration
    @AppStorage(LaunchlySettings.Keys.backgroundOpacity) private var backgroundOpacity: Double = LaunchlySettings.Defaults.backgroundOpacity

    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Trackpad Gesture Setup", systemImage: "hand.pinch")
                        .font(.headline)

                    Text("macOS intercepts the built-in four-finger pinch and spread gestures unless they are disabled in System Settings:")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("1. Open **System Settings › Trackpad › More Gestures**.")
                        Text("2. Turn off **Launchpad** / **Apps** (pinch with thumb and three fingers).")
                        Text("3. Turn off **Show Desktop** (spread with thumb and three fingers) so pinching out dismisses Launchly.")
                    }
                    .font(.callout)

                    Button("Open Trackpad Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .launchlyGlassButton(prominent: true)
                    .padding(.top, 2)
                }
                .padding(.vertical, 4)
            }

            Section("Triggers & Startup") {
                Toggle("Enable four-finger pinch gesture", isOn: $pinchEnabled)
                    .onChange(of: pinchEnabled) { _, newValue in
                        MultitouchGestureMonitor.shared.setEnabled(newValue)
                    }

                HStack {
                    Text("Pinch sensitivity")
                    Slider(value: $pinchSensitivity, in: 0.0...1.0, step: 0.05)
                        .onChange(of: pinchSensitivity) { _, newValue in
                            MultitouchGestureMonitor.shared.setSensitivity(newValue)
                        }
                    Text("\(Int(round(pinchSensitivity * 100)))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }

                Toggle("Enable ⌃⌥Space global hotkey", isOn: $hotKeyEnabled)
                    .onChange(of: hotKeyEnabled) { _, newValue in
                        GlobalHotKey.shared.setEnabled(newValue)
                    }

                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        updateLaunchAtLogin(enabled: newValue)
                    }

                if let loginItemError {
                    Text(loginItemError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Sorting & Appearance") {
                Picker("Sort apps by", selection: $sortModeRaw) {
                    ForEach(SortMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .onChange(of: sortModeRaw) { _, newRaw in
                    if let mode = SortMode(rawValue: newRaw) {
                        sortAscending = mode.defaultAscending
                    }
                }

                if (SortMode(rawValue: sortModeRaw) ?? .custom) != .custom {
                    Toggle("Ascending order", isOn: $sortAscending)
                }

                Stepper("Rows: \(gridRows)", value: $gridRows, in: 3...8)
                Stepper("Columns: \(gridColumns)", value: $gridColumns, in: 4...10)

                HStack {
                    Text("Icon Size")
                    Slider(value: $iconSize, in: 56...128, step: 4)
                    Text("\(Int(iconSize)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }

                HStack {
                    Text("Page swipe speed")
                    Slider(value: $pagingDuration, in: 0.25...1.0, step: 0.05)
                    Text("Slower")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Background opacity")
                        Spacer()
                        Text("\(Int(round(backgroundOpacity * 100)))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Text("Transparent")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(value: $backgroundOpacity, in: 0.0...1.0, step: 0.02)
                        Text("Opaque")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Button("Reset Layout", role: .destructive) {
                    layoutStore.resetToAlphabetical(orderedAppIDs: appCatalog.allApps.map(\.id))
                    sortModeRaw = SortMode.custom.rawValue
                }
                .launchlyGlassButton()
            }

            Section("Hidden Apps") {
                if appCatalog.hiddenAppEntries.isEmpty {
                    Text("No hidden apps. Right-click an app in Launchly to hide it.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appCatalog.hiddenAppEntries) { entry in
                        HStack(spacing: 10) {
                            if let path = entry.path {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                                    .resizable()
                                    .frame(width: 20, height: 20)
                            } else {
                                Image(systemName: "app")
                                    .frame(width: 20, height: 20)
                            }

                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.displayName)
                                if entry.displayName != entry.id {
                                    Text(entry.id)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()

                            Button("Unhide") {
                                appCatalog.unhide(id: entry.id)
                            }
                            .launchlyGlassButton()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 700)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func updateLaunchAtLogin(enabled: Bool) {
        loginItemError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginItemError = "Could not update login item: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
