import SwiftUI

struct SortMenu: View {
    @AppStorage(LaunchlySettings.Keys.sortMode) private var sortModeRaw: String = LaunchlySettings.Defaults.sortMode
    @AppStorage(LaunchlySettings.Keys.sortAscending) private var sortAscending: Bool = LaunchlySettings.Defaults.sortAscending

    var onOpenSettings: (() -> Void)?

    private var currentMode: SortMode {
        SortMode(rawValue: sortModeRaw) ?? .custom
    }

    var body: some View {
        Menu {
            Section("Sort By") {
                ForEach(SortMode.allCases) { mode in
                    Button {
                        if mode != currentMode {
                            sortModeRaw = mode.rawValue
                            sortAscending = mode.defaultAscending
                        }
                    } label: {
                        if mode == currentMode {
                            Label(mode.title, systemImage: "checkmark")
                        } else {
                            Text(mode.title)
                        }
                    }
                }
            }

            if currentMode != .custom {
                Divider()

                Button {
                    sortAscending.toggle()
                } label: {
                    Label(orderToggleLabel, systemImage: sortAscending ? "arrow.up" : "arrow.down")
                }
            }

            if let onOpenSettings {
                Divider()
                Button {
                    onOpenSettings()
                } label: {
                    Label("Settings…", systemImage: "gearshape")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(.white.opacity(0.82))
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort: \(currentMode.title)")
    }

    private var orderToggleLabel: String {
        switch currentMode {
        case .custom:
            return sortAscending ? "Ascending" : "Descending"
        case .name:
            return sortAscending ? "Ascending (A–Z)" : "Descending (Z–A)"
        case .mostUsed:
            return sortAscending ? "Least Used First" : "Most Used First"
        case .dateAdded, .lastOpened:
            return sortAscending ? "Oldest First" : "Newest First"
        case .size:
            return sortAscending ? "Smallest First" : "Largest First"
        }
    }
}
