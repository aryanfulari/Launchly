import Foundation

enum LaunchlySettings {
    enum Keys {
        static let pinchEnabled = "pinchEnabled"
        static let pinchSensitivity = "pinchSensitivity"
        static let hotKeyEnabled = "hotKeyEnabled"
        static let gridRows = "gridRows"
        static let gridColumns = "gridColumns"
        static let iconSize = "iconSize"
        static let hiddenApps = "hiddenApps"
        static let hasShownOnboarding = "hasShownOnboarding"
        static let pagingDuration = "pagingDuration"
        static let sortMode = "sortMode"
        static let sortAscending = "sortAscending"
        static let backgroundOpacity = "backgroundOpacity"
    }

    enum Defaults {
        static let pinchEnabled = true
        static let pinchSensitivity: Double = 0.80
        static let hotKeyEnabled = true
        static let gridRows = 5
        static let gridColumns = 7
        static let iconSize: Double = 88.0
        static let hiddenApps: [String] = []
        static let hasShownOnboarding = false
        static let pagingDuration: Double = 0.42
        static let sortMode = "custom"
        static let sortAscending = true
        static let backgroundOpacity: Double = 0.65
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Keys.pinchEnabled: Defaults.pinchEnabled,
            Keys.pinchSensitivity: Defaults.pinchSensitivity,
            Keys.hotKeyEnabled: Defaults.hotKeyEnabled,
            Keys.gridRows: Defaults.gridRows,
            Keys.gridColumns: Defaults.gridColumns,
            Keys.iconSize: Defaults.iconSize,
            Keys.hiddenApps: Defaults.hiddenApps,
            Keys.hasShownOnboarding: Defaults.hasShownOnboarding,
            Keys.pagingDuration: Defaults.pagingDuration,
            Keys.sortMode: Defaults.sortMode,
            Keys.sortAscending: Defaults.sortAscending,
            Keys.backgroundOpacity: Defaults.backgroundOpacity
        ])
    }
}
