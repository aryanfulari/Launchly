import Combine
import CoreServices
import Foundation

struct AppMetadata {
    var dateAdded: Date?
    var lastUsed: Date?
    var sizeBytes: Int64?
    var useCount: Int?
}

private struct CachedSizeEntry: Codable {
    var modTimeInterval: TimeInterval
    var bytes: Int64
}

final class AppMetadataStore: ObservableObject {
    @Published private(set) var metadata: [String: AppMetadata] = [:]

    private let queue = DispatchQueue(label: "com.aryanfulari.Launchly.Metadata", qos: .utility)
    private let cacheURL: URL
    private var sizeCache: [String: CachedSizeEntry] = [:]
    private var localLaunchCounts: [String: Int] = [:]

    private static let localLaunchCountsKey = "launchlyLocalLaunchCounts"

    static var defaultCacheURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("Launchly", isDirectory: true)
            .appendingPathComponent("sizes.json", isDirectory: false)
    }

    init(cacheURL: URL = AppMetadataStore.defaultCacheURL) {
        self.cacheURL = cacheURL
        loadSizeCache()
        loadLocalLaunchCounts()
    }

    func recordLaunch(appID: String) {
        let now = Date()
        let updatedLocal = (localLaunchCounts[appID] ?? 0) + 1
        localLaunchCounts[appID] = updatedLocal
        UserDefaults.standard.set(localLaunchCounts, forKey: Self.localLaunchCountsKey)

        var current = metadata[appID] ?? AppMetadata()
        current.lastUsed = now
        current.useCount = max((current.useCount ?? 0) + 1, updatedLocal)
        metadata[appID] = current
    }

    func update(for apps: [AppItem]) {
        let localSnapshot = localLaunchCounts

        queue.async { [weak self] in
            guard let self else { return }

            var firstPass: [String: AppMetadata] = [:]
            var pendingSizeCalculation: [AppItem] = []

            for app in apps {
                var itemMeta = AppMetadata()
                let mdItem = MDItemCreateWithURL(nil, app.url as CFURL)

                if let mdItem {
                    if let added = MDItemCopyAttribute(mdItem, kMDItemDateAdded) as? Date {
                        itemMeta.dateAdded = added
                    }
                    if let used = MDItemCopyAttribute(mdItem, kMDItemLastUsedDate) as? Date {
                        itemMeta.lastUsed = used
                    }
                    if let physicalSize = (MDItemCopyAttribute(mdItem, "kMDItemPhysicalSize" as CFString) as? NSNumber)
                        ?? (MDItemCopyAttribute(mdItem, kMDItemFSSize) as? NSNumber) {
                        itemMeta.sizeBytes = physicalSize.int64Value
                    }
                    if let uses = MDItemCopyAttribute(mdItem, "kMDItemUseCount" as CFString) as? NSNumber {
                        let count = uses.intValue
                        if count > 0 {
                            itemMeta.useCount = count
                        }
                    }
                }

                if let localUses = localSnapshot[app.id], localUses > 0 {
                    itemMeta.useCount = max(itemMeta.useCount ?? 0, localUses)
                }

                if itemMeta.dateAdded == nil {
                    let values = try? app.url.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey])
                    itemMeta.dateAdded = values?.addedToDirectoryDate ?? values?.creationDate
                }

                if itemMeta.sizeBytes == nil {
                    if let modTime = self.bundleModificationInterval(for: app.url),
                       let cached = self.sizeCache[app.path],
                       abs(cached.modTimeInterval - modTime) < 1.0 {
                        itemMeta.sizeBytes = cached.bytes
                    } else {
                        pendingSizeCalculation.append(app)
                    }
                }

                firstPass[app.id] = itemMeta
            }

            DispatchQueue.main.async {
                self.metadata = firstPass
            }

            guard !pendingSizeCalculation.isEmpty else { return }

            var secondPass = firstPass
            var cacheChanged = false

            for app in pendingSizeCalculation {
                let bytes = self.calculateDirectorySize(at: app.url)
                if var existing = secondPass[app.id] {
                    existing.sizeBytes = bytes
                    secondPass[app.id] = existing
                }
                if let modTime = self.bundleModificationInterval(for: app.url) {
                    self.sizeCache[app.path] = CachedSizeEntry(modTimeInterval: modTime, bytes: bytes)
                    cacheChanged = true
                }
            }

            if cacheChanged {
                self.saveSizeCache()
            }

            DispatchQueue.main.async {
                self.metadata = secondPass
            }
        }
    }

    // MARK: - Private

    private func bundleModificationInterval(for url: URL) -> TimeInterval? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate?.timeIntervalSince1970
    }

    private func calculateDirectorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: nil
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            if let allocated = values.totalFileAllocatedSize ?? values.fileAllocatedSize {
                total += Int64(allocated)
            }
        }
        return total
    }

    private func loadLocalLaunchCounts() {
        if let dict = UserDefaults.standard.dictionary(forKey: Self.localLaunchCountsKey) as? [String: Int] {
            localLaunchCounts = dict
        }
    }

    private func loadSizeCache() {
        guard FileManager.default.fileExists(atPath: cacheURL.path),
              let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: CachedSizeEntry].self, from: data) else {
            sizeCache = [:]
            return
        }
        sizeCache = decoded
    }

    private func saveSizeCache() {
        let dir = cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(sizeCache) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
