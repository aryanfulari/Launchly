import Foundation

enum SortMode: String, CaseIterable, Identifiable {
    case custom
    case name
    case mostUsed
    case dateAdded
    case lastOpened
    case size

    var id: String { rawValue }

    var title: String {
        switch self {
        case .custom: return "Custom"
        case .name: return "Name"
        case .mostUsed: return "Most Used"
        case .dateAdded: return "Date Added"
        case .lastOpened: return "Last Opened"
        case .size: return "Size"
        }
    }

    var defaultAscending: Bool {
        switch self {
        case .custom, .name:
            return true
        case .mostUsed, .dateAdded, .lastOpened, .size:
            return false
        }
    }
}

enum LayoutSorter {
    static func sortedEntries(
        _ entries: [LayoutEntry],
        folders: [UUID: AppFolder],
        mode: SortMode,
        ascending: Bool,
        name: (String) -> String,
        dateAdded: (String) -> Date?,
        lastUsed: (String) -> Date?,
        size: (String) -> Int64?,
        useCount: (String) -> Int? = { _ in nil }
    ) -> [LayoutEntry] {
        guard mode != .custom else { return entries }

        return entries.sorted { lhs, rhs in
            let lhsName = entryName(lhs, folders: folders, name: name)
            let rhsName = entryName(rhs, folders: folders, name: name)

            switch mode {
            case .custom:
                return false

            case .name:
                let cmp = lhsName.localizedCaseInsensitiveCompare(rhsName)
                if cmp != .orderedSame {
                    return ascending ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
                }
                return lhs.stableID < rhs.stableID

            case .mostUsed:
                let lhsUses = entryTotalUses(lhs, folders: folders, usesForID: useCount)
                let rhsUses = entryTotalUses(rhs, folders: folders, usesForID: useCount)
                return compareOptionals(lhsUses, rhsUses, ascending: ascending, lhsName: lhsName, rhsName: rhsName)

            case .dateAdded:
                let lhsDate = entryMaxDate(lhs, folders: folders, dateForID: dateAdded)
                let rhsDate = entryMaxDate(rhs, folders: folders, dateForID: dateAdded)
                return compareOptionals(lhsDate, rhsDate, ascending: ascending, lhsName: lhsName, rhsName: rhsName)

            case .lastOpened:
                let lhsDate = entryMaxDate(lhs, folders: folders, dateForID: lastUsed)
                let rhsDate = entryMaxDate(rhs, folders: folders, dateForID: lastUsed)
                return compareOptionals(lhsDate, rhsDate, ascending: ascending, lhsName: lhsName, rhsName: rhsName)

            case .size:
                let lhsSize = entryTotalSize(lhs, folders: folders, sizeForID: size)
                let rhsSize = entryTotalSize(rhs, folders: folders, sizeForID: size)
                return compareOptionals(lhsSize, rhsSize, ascending: ascending, lhsName: lhsName, rhsName: rhsName)
            }
        }
    }

    static func sortedAppIDs(
        _ ids: [String],
        mode: SortMode,
        ascending: Bool,
        name: (String) -> String,
        dateAdded: (String) -> Date?,
        lastUsed: (String) -> Date?,
        size: (String) -> Int64?,
        useCount: (String) -> Int? = { _ in nil }
    ) -> [String] {
        guard mode != .custom else { return ids }

        return ids.sorted { lhs, rhs in
            let lhsName = name(lhs)
            let rhsName = name(rhs)

            switch mode {
            case .custom:
                return false

            case .name:
                let cmp = lhsName.localizedCaseInsensitiveCompare(rhsName)
                if cmp != .orderedSame {
                    return ascending ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
                }
                return lhs < rhs

            case .mostUsed:
                return compareOptionals(useCount(lhs), useCount(rhs), ascending: ascending, lhsName: lhsName, rhsName: rhsName)

            case .dateAdded:
                return compareOptionals(dateAdded(lhs), dateAdded(rhs), ascending: ascending, lhsName: lhsName, rhsName: rhsName)

            case .lastOpened:
                return compareOptionals(lastUsed(lhs), lastUsed(rhs), ascending: ascending, lhsName: lhsName, rhsName: rhsName)

            case .size:
                return compareOptionals(size(lhs), size(rhs), ascending: ascending, lhsName: lhsName, rhsName: rhsName)
            }
        }
    }

    // MARK: - Helpers

    private static func entryName(_ entry: LayoutEntry, folders: [UUID: AppFolder], name: (String) -> String) -> String {
        switch entry {
        case .app(let id):
            return name(id)
        case .folder(let folderID):
            return folders[folderID]?.name ?? ""
        }
    }

    private static func entryMaxDate(_ entry: LayoutEntry, folders: [UUID: AppFolder], dateForID: (String) -> Date?) -> Date? {
        switch entry {
        case .app(let id):
            return dateForID(id)
        case .folder(let folderID):
            guard let memberIDs = folders[folderID]?.appIDs else { return nil }
            return memberIDs.compactMap(dateForID).max()
        }
    }

    private static func entryTotalSize(_ entry: LayoutEntry, folders: [UUID: AppFolder], sizeForID: (String) -> Int64?) -> Int64? {
        switch entry {
        case .app(let id):
            return sizeForID(id)
        case .folder(let folderID):
            guard let memberIDs = folders[folderID]?.appIDs else { return nil }
            let sizes = memberIDs.compactMap(sizeForID)
            guard !sizes.isEmpty else { return nil }
            return sizes.reduce(0, +)
        }
    }

    private static func entryTotalUses(_ entry: LayoutEntry, folders: [UUID: AppFolder], usesForID: (String) -> Int?) -> Int? {
        switch entry {
        case .app(let id):
            return usesForID(id)
        case .folder(let folderID):
            guard let memberIDs = folders[folderID]?.appIDs else { return nil }
            let counts = memberIDs.compactMap(usesForID)
            guard !counts.isEmpty else { return nil }
            return counts.reduce(0, +)
        }
    }

    private static func compareOptionals<T: Comparable>(
        _ lhs: T?,
        _ rhs: T?,
        ascending: Bool,
        lhsName: String,
        rhsName: String
    ) -> Bool {
        switch (lhs, rhs) {
        case (.some(let l), .some(let r)):
            if l != r {
                return ascending ? (l < r) : (l > r)
            }
            return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
        }
    }
}
