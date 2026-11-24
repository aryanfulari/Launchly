import Combine
import Foundation

struct AppFolder: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var appIDs: [String]
}

enum LayoutEntry: Hashable, Codable {
    case app(String)
    case folder(UUID)

    var stableID: String {
        switch self {
        case .app(let id):
            return "app:\(id)"
        case .folder(let uuid):
            return "folder:\(uuid.uuidString)"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case id
    }

    private enum EntryType: String, Codable {
        case app
        case folder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(EntryType.self, forKey: .type)
        let rawID = try container.decode(String.self, forKey: .id)
        switch kind {
        case .app:
            self = .app(rawID)
        case .folder:
            guard let uuid = UUID(uuidString: rawID) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .id,
                    in: container,
                    debugDescription: "Invalid folder UUID string: \(rawID)"
                )
            }
            self = .folder(uuid)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .app(let id):
            try container.encode(EntryType.app, forKey: .type)
            try container.encode(id, forKey: .id)
        case .folder(let uuid):
            try container.encode(EntryType.folder, forKey: .type)
            try container.encode(uuid.uuidString, forKey: .id)
        }
    }
}

private struct LayoutSnapshot: Codable {
    var entries: [LayoutEntry]
    var folders: [AppFolder]
}

final class LayoutStore: ObservableObject {
    @Published private(set) var entries: [LayoutEntry] = []
    @Published private(set) var folders: [UUID: AppFolder] = [:]

    let fileURL: URL

    static var defaultFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("Launchly", isDirectory: true)
            .appendingPathComponent("layout.json", isDirectory: false)
    }

    init(fileURL: URL = LayoutStore.defaultFileURL) {
        self.fileURL = fileURL
        load()
    }

    func reconcile(knownAppIDs: [String]) {
        let knownSet = Set(knownAppIDs)
        var updatedFolders = folders
        var updatedEntries: [LayoutEntry] = []
        var representedAppIDs = Set<String>()
        var seenFolders = Set<UUID>()

        // Prune missing apps from every folder first.
        for (folderID, var folder) in updatedFolders {
            var filtered: [String] = []
            var seenInFolder = Set<String>()
            for appID in folder.appIDs where knownSet.contains(appID) && !seenInFolder.contains(appID) {
                filtered.append(appID)
                seenInFolder.insert(appID)
            }
            folder.appIDs = filtered
            updatedFolders[folderID] = folder
        }

        // Rebuild top-level entries, dissolving 0/1-item folders and skipping removed apps.
        for entry in entries {
            switch entry {
            case .app(let appID):
                guard knownSet.contains(appID), !representedAppIDs.contains(appID) else { continue }
                updatedEntries.append(.app(appID))
                representedAppIDs.insert(appID)

            case .folder(let folderID):
                guard !seenFolders.contains(folderID), let folder = updatedFolders[folderID] else { continue }
                seenFolders.insert(folderID)

                let validMemberIDs = folder.appIDs.filter { !representedAppIDs.contains($0) }
                if validMemberIDs.count <= 1 {
                    updatedFolders.removeValue(forKey: folderID)
                    if let singleID = validMemberIDs.first {
                        updatedEntries.append(.app(singleID))
                        representedAppIDs.insert(singleID)
                    }
                } else {
                    var cleanedFolder = folder
                    cleanedFolder.appIDs = validMemberIDs
                    updatedFolders[folderID] = cleanedFolder
                    updatedEntries.append(.folder(folderID))
                    validMemberIDs.forEach { representedAppIDs.insert($0) }
                }
            }
        }

        // Drop any orphaned folders that weren't referenced in entries.
        for folderID in Array(updatedFolders.keys) where !seenFolders.contains(folderID) {
            updatedFolders.removeValue(forKey: folderID)
        }

        // Append newly discovered apps at the end in known order.
        for appID in knownAppIDs where !representedAppIDs.contains(appID) {
            updatedEntries.append(.app(appID))
            representedAppIDs.insert(appID)
        }

        if updatedEntries != entries || updatedFolders != folders || !FileManager.default.fileExists(atPath: fileURL.path) {
            entries = updatedEntries
            folders = updatedFolders
            save()
        }
    }

    func setOrder(_ newEntries: [LayoutEntry]) {
        entries = newEntries
        save()
    }

    func move(entry: LayoutEntry, to index: Int) {
        guard let currentIdx = entries.firstIndex(of: entry) else { return }
        var updated = entries
        updated.remove(at: currentIdx)
        let clamped = min(max(0, index), updated.count)
        updated.insert(entry, at: clamped)
        entries = updated
        save()
    }

    @discardableResult
    func createFolder(appIDs: [String], name: String, at index: Int) -> UUID {
        var uniqueIDs: [String] = []
        var seen = Set<String>()
        for id in appIDs where !seen.contains(id) {
            uniqueIDs.append(id)
            seen.insert(id)
        }

        let folderID = UUID()
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folderName = cleanedName.isEmpty ? "New Folder" : cleanedName

        var updatedFolders = folders
        var updatedEntries = entries

        // Count how many top-level items being removed sit before `index` so insertion lands at the visual slot.
        let boundedTarget = min(max(0, index), updatedEntries.count)
        var removedBeforeTarget = 0
        for i in 0..<boundedTarget {
            if case .app(let existingID) = updatedEntries[i], seen.contains(existingID) {
                removedBeforeTarget += 1
            }
        }

        // Remove these app IDs from top-level entries.
        updatedEntries.removeAll { entry in
            if case .app(let id) = entry {
                return seen.contains(id)
            }
            return false
        }

        // Remove these app IDs from any existing folders, dissolving folders that drop below 2 members.
        for (existingFolderID, var existingFolder) in updatedFolders {
            let beforeCount = existingFolder.appIDs.count
            existingFolder.appIDs.removeAll { seen.contains($0) }
            guard existingFolder.appIDs.count != beforeCount else { continue }

            if existingFolder.appIDs.count <= 1 {
                updatedFolders.removeValue(forKey: existingFolderID)
                if let pos = updatedEntries.firstIndex(of: .folder(existingFolderID)) {
                    updatedEntries.remove(at: pos)
                    if let remaining = existingFolder.appIDs.first {
                        updatedEntries.insert(.app(remaining), at: pos)
                    }
                }
            } else {
                updatedFolders[existingFolderID] = existingFolder
            }
        }

        let newFolder = AppFolder(id: folderID, name: folderName, appIDs: uniqueIDs)
        updatedFolders[folderID] = newFolder

        let adjustedIndex = min(max(0, boundedTarget - removedBeforeTarget), updatedEntries.count)
        updatedEntries.insert(.folder(folderID), at: adjustedIndex)

        folders = updatedFolders
        entries = updatedEntries
        save()
        return folderID
    }

    func add(appID: String, toFolder folderID: UUID) {
        guard var targetFolder = folders[folderID] else { return }
        if targetFolder.appIDs.contains(appID) { return }

        var updatedFolders = folders
        var updatedEntries = entries

        // Remove from top-level entries if present.
        updatedEntries.removeAll { $0 == .app(appID) }

        // Remove from any other folder if present.
        for (otherID, var otherFolder) in updatedFolders where otherID != folderID {
            if let idx = otherFolder.appIDs.firstIndex(of: appID) {
                otherFolder.appIDs.remove(at: idx)
                if otherFolder.appIDs.count <= 1 {
                    updatedFolders.removeValue(forKey: otherID)
                    if let pos = updatedEntries.firstIndex(of: .folder(otherID)) {
                        updatedEntries.remove(at: pos)
                        if let remaining = otherFolder.appIDs.first {
                            updatedEntries.insert(.app(remaining), at: pos)
                        }
                    }
                } else {
                    updatedFolders[otherID] = otherFolder
                }
            }
        }

        targetFolder.appIDs.append(appID)
        updatedFolders[folderID] = targetFolder

        folders = updatedFolders
        entries = updatedEntries
        save()
    }

    func remove(appID: String, fromFolder folderID: UUID) {
        guard var folder = folders[folderID],
              let memberIndex = folder.appIDs.firstIndex(of: appID) else { return }

        folder.appIDs.remove(at: memberIndex)

        var updatedFolders = folders
        var updatedEntries = entries
        let folderPos = updatedEntries.firstIndex(of: .folder(folderID)) ?? updatedEntries.count

        if folder.appIDs.count <= 1 {
            updatedFolders.removeValue(forKey: folderID)
            if folderPos < updatedEntries.count {
                updatedEntries.remove(at: folderPos)
            }
            var insertionOffset = folderPos
            if let remainingID = folder.appIDs.first {
                updatedEntries.insert(.app(remainingID), at: min(insertionOffset, updatedEntries.count))
                insertionOffset += 1
            }
            updatedEntries.insert(.app(appID), at: min(insertionOffset, updatedEntries.count))
        } else {
            updatedFolders[folderID] = folder
            let insertAt = min(folderPos + 1, updatedEntries.count)
            updatedEntries.insert(.app(appID), at: insertAt)
        }

        folders = updatedFolders
        entries = updatedEntries
        save()
    }

    func moveInFolder(appID: String, folder folderID: UUID, to index: Int) {
        guard var folder = folders[folderID],
              let currentIdx = folder.appIDs.firstIndex(of: appID) else { return }

        folder.appIDs.remove(at: currentIdx)
        let clamped = min(max(0, index), folder.appIDs.count)
        folder.appIDs.insert(appID, at: clamped)

        folders[folderID] = folder
        save()
    }

    func rename(folder folderID: UUID, to name: String) {
        guard var folder = folders[folderID] else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        folder.name = trimmed
        folders[folderID] = folder
        save()
    }

    func dissolve(folder folderID: UUID) {
        guard let folder = folders[folderID] else { return }
        var updatedFolders = folders
        updatedFolders.removeValue(forKey: folderID)

        var updatedEntries = entries
        let replacement = folder.appIDs.map { LayoutEntry.app($0) }

        if let pos = updatedEntries.firstIndex(of: .folder(folderID)) {
            updatedEntries.replaceSubrange(pos...pos, with: replacement)
        } else {
            updatedEntries.append(contentsOf: replacement)
        }

        folders = updatedFolders
        entries = updatedEntries
        save()
    }

    func resetToAlphabetical(orderedAppIDs: [String]? = nil) {
        if let orderedAppIDs {
            folders = [:]
            entries = orderedAppIDs.map { .app($0) }
            save()
            return
        }

        var collected: [String] = []
        var seen = Set<String>()
        for entry in entries {
            switch entry {
            case .app(let id):
                if !seen.contains(id) {
                    collected.append(id)
                    seen.insert(id)
                }
            case .folder(let folderID):
                if let folder = folders[folderID] {
                    for id in folder.appIDs where !seen.contains(id) {
                        collected.append(id)
                        seen.insert(id)
                    }
                }
            }
        }
        collected.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        folders = [:]
        entries = collected.map { .app($0) }
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(LayoutSnapshot.self, from: data) else {
            entries = []
            folders = [:]
            return
        }

        entries = snapshot.entries
        folders = Dictionary(uniqueKeysWithValues: snapshot.folders.map { ($0.id, $0) })
    }

    private func save() {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let orderedFolders = folders.values.sorted { $0.id.uuidString < $1.id.uuidString }
        let snapshot = LayoutSnapshot(entries: entries, folders: orderedFolders)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
