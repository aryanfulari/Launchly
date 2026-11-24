import Combine
import Foundation
import os

final class SpotlightAppIndex: ObservableObject {
    @Published private(set) var apps: [AppItem] = []

    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var hasLoggedInitialCount = false

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.aryanfulari.Launchly",
        category: "Spotlight"
    )

    deinit {
        stop()
    }

    func start() {
        stop()

        let metadataQuery = NSMetadataQuery()
        metadataQuery.predicate = NSPredicate(format: "kMDItemContentType == 'com.apple.application-bundle'")

        // Scope strictly to application directories so Spotlight never queries TCC-protected user media/data folders.
        let userAppsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .path
        let candidateScopes = [
            "/Applications",
            "/System/Applications",
            "/System/Volumes/Preboot/Cryptexes/App/System/Applications",
            "/System/Library/CoreServices/Applications",
            userAppsPath
        ]
        metadataQuery.searchScopes = candidateScopes.filter { FileManager.default.fileExists(atPath: $0) }

        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
                object: metadataQuery,
                queue: .main
            ) { [weak self] _ in
                self?.processResults(isInitial: true)
            },
            center.addObserver(
                forName: .NSMetadataQueryDidUpdate,
                object: metadataQuery,
                queue: .main
            ) { [weak self] _ in
                self?.processResults(isInitial: false)
            }
        ]

        query = metadataQuery
        metadataQuery.start()
    }

    func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        query?.stop()
        query = nil
    }

    // MARK: - Private

    private func processResults(isInitial: Bool) {
        guard let query else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }

        var seenIDs = Set<String>()
        var collected: [AppItem] = []

        for case let item as NSMetadataItem in query.results {
            guard let path = item.value(forAttribute: kMDItemPath as String) as? String else { continue }
            guard !Self.shouldExclude(path: path) else { continue }

            let url = URL(fileURLWithPath: path, isDirectory: true)
            guard let appItem = AppItem.make(from: url) else { continue }
            guard !seenIDs.contains(appItem.id) else { continue }

            seenIDs.insert(appItem.id)
            collected.append(appItem)
        }

        collected.sort {
            let cmp = $0.name.localizedCaseInsensitiveCompare($1.name)
            return cmp != .orderedSame ? (cmp == .orderedAscending) : ($0.path < $1.path)
        }

        apps = collected
        if isInitial || !hasLoggedInitialCount {
            hasLoggedInitialCount = true
            logger.info("Spotlight indexed \(collected.count) app(s)")
        }
    }

    private static func shouldExclude(path: String) -> Bool {
        // Exclude nested helper apps inside another .app bundle.
        let parentPath = (path as NSString).deletingLastPathComponent
        if parentPath.contains(".app/") || parentPath.hasSuffix(".app") {
            return true
        }

        if path.hasPrefix("/System/Library/") && !path.hasPrefix("/System/Library/CoreServices/Applications/") {
            return true
        }

        if path.hasPrefix("/Library/Apple/") ||
            path.hasPrefix("/private/") ||
            path.hasPrefix("/usr/") ||
            path.hasPrefix("/opt/") {
            return true
        }

        if path.contains("/Developer/Platforms/") || path.contains("/Xcode.app/Contents/") {
            return true
        }

        return false
    }
}
