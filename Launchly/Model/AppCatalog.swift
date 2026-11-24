import AppKit
import Combine
import Foundation
import os

final class AppCatalog: ObservableObject {
    @Published private(set) var apps: [AppItem] = []
    @Published private(set) var allApps: [AppItem] = []
    @Published private(set) var hiddenAppEntries: [HiddenAppEntry] = []

    private var hiddenIDs: Set<String> = []

    private let iconCache = NSCache<NSString, NSImage>()
    private var lastAppearanceSignature: String = ""
    private let scanQueue = DispatchQueue(label: "com.aryanfulari.Launchly.AppCatalog.scan", qos: .userInitiated)
    private let iconQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.aryanfulari.Launchly.AppCatalog.icons"
        q.qualityOfService = .userInitiated
        q.maxConcurrentOperationCount = 4
        return q
    }()
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.aryanfulari.Launchly",
        category: "AppCatalog"
    )

    private var isScanning = false

    init() {
        iconCache.countLimit = 500
        loadHiddenIDs()
        refresh()
    }

    func refresh() {
        scanQueue.async { [weak self] in
            guard let self else { return }
            if self.isScanning { return }
            self.isScanning = true
            defer { self.isScanning = false }

            let appearanceSig = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") ?? "Light"
            if self.lastAppearanceSignature != appearanceSig {
                self.lastAppearanceSignature = appearanceSig
                self.iconCache.removeAllObjects()
            }

            let scanned = self.scanApplications()

            // Refresh any icons driven by a DockTilePlugin custom icon resource in case theme/icon changed.
            for item in scanned {
                if Self.supportsCustomDockPluginIcon(at: item.url, bundleID: item.bundleID) {
                    self.iconCache.removeObject(forKey: item.path as NSString)
                }
            }

            // Publish the scanned list immediately so layout/reconciliation never waits on icon rasterization.
            DispatchQueue.main.async {
                self.allApps = scanned
                self.recomputePublishedLists()
            }

            // Warm all app icons concurrently across the bounded 4-way OperationQueue (~4x faster than serial).
            for item in scanned {
                let path = item.path
                if self.iconCache.object(forKey: path as NSString) == nil {
                    self.iconQueue.addOperation { [weak self] in
                        self?.loadAndCacheIconSync(for: path)
                    }
                }
            }
        }
    }

    func cachedIcon(for path: String) -> NSImage? {
        iconCache.object(forKey: path as NSString)
    }

    func loadIconAsync(for path: String, completion: @escaping (NSImage) -> Void) {
        if let cached = iconCache.object(forKey: path as NSString) {
            completion(cached)
            return
        }

        iconQueue.addOperation { [weak self] in
            guard let self else { return }
            let icon = self.loadAndCacheIconSync(for: path)
            DispatchQueue.main.async {
                completion(icon)
            }
        }
    }

    func isHidden(_ id: String) -> Bool {
        hiddenIDs.contains(id)
    }

    func hide(_ item: AppItem) {
        hiddenIDs.insert(item.id)
        saveHiddenIDs()
        recomputePublishedLists()
    }

    func unhide(id: String) {
        hiddenIDs.remove(id)
        saveHiddenIDs()
        recomputePublishedLists()
    }

    // MARK: - Private

    @discardableResult
    private func loadAndCacheIconSync(for path: String) -> NSImage {
        let key = path as NSString
        if let cached = iconCache.object(forKey: key) {
            return cached
        }
        let resolvedURL = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let rawIcon = Self.customDockIconIfAvailable(for: resolvedURL)
            ?? NSWorkspace.shared.icon(forFile: resolvedURL.path)
        let baked = Self.bakeBitmapIcon(from: rawIcon, pixelSize: 192) ?? rawIcon
        iconCache.setObject(baked, forKey: key)
        return baked
    }

    /// Pure bundle-file check (touches zero user containers or TCC-protected preference domains).
    /// Returns true only for non-Apple apps that ship both a `.docktileplugin` and `icon-*.png` resources.
    private static func supportsCustomDockPluginIcon(at appURL: URL, bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.hasPrefix("com.apple.") else { return false }

        let resolvedURL = appURL.resolvingSymlinksInPath()
        let pluginsURL = resolvedURL.appendingPathComponent("Contents/PlugIns", isDirectory: true)
        let fm = FileManager.default

        guard let pluginItems = try? fm.contentsOfDirectory(atPath: pluginsURL.path),
              pluginItems.contains(where: { $0.lowercased().hasSuffix(".docktileplugin") }) else {
            return false
        }

        let resourcesURL = resolvedURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        guard let resourceItems = try? fm.contentsOfDirectory(atPath: resourcesURL.path) else {
            return false
        }

        return resourceItems.contains { name in
            let lower = name.lowercased()
            return lower.hasPrefix("icon-") && (lower.hasSuffix(".png") || lower.hasSuffix(".icns"))
        }
    }

    private static func customDockIconIfAvailable(for resolvedURL: URL) -> NSImage? {
        let bundleID = Bundle(url: resolvedURL)?.bundleIdentifier
        guard supportsCustomDockPluginIcon(at: resolvedURL, bundleID: bundleID),
              let bundleID,
              let suite = UserDefaults(suiteName: bundleID) else {
            return nil
        }

        let pref = suite.string(forKey: "DockIconPreference")
        let resourceName = suite.string(forKey: "DockIconResourceName")
        guard pref != nil || resourceName != nil else { return nil }

        let resourcesURL = resolvedURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        let isDarkMode = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"

        var candidates: [String] = []
        if let pref, !pref.isEmpty {
            let lowered = pref.lowercased()
            let suffixes = ["-system", "-dark-color", "-dark", "-light", "-color"]
            var prefix = lowered
            for suffix in suffixes where prefix.hasSuffix(suffix) {
                prefix = String(prefix.dropLast(suffix.count))
                break
            }

            let wantDark = lowered.hasSuffix("-dark") || lowered.hasSuffix("-dark-color") || (lowered.hasSuffix("-system") && isDarkMode)
            let wantLight = lowered.hasSuffix("-light") || (lowered.hasSuffix("-system") && !isDarkMode)

            if !prefix.isEmpty {
                if wantDark {
                    candidates.append("icon-\(prefix)-dark-color.png")
                    candidates.append("icon-\(prefix)-dark.png")
                } else if wantLight {
                    candidates.append("icon-\(prefix)-light.png")
                }
                candidates.append("icon-\(prefix).png")
                candidates.append("icon-\(prefix).icns")
            }
        }

        if let resourceName, !resourceName.isEmpty {
            candidates.append(resourceName)
        }

        let fm = FileManager.default
        for name in candidates {
            let fileURL = resourcesURL.appendingPathComponent(name, isDirectory: false)
            if fm.fileExists(atPath: fileURL.path), let img = NSImage(contentsOf: fileURL) {
                return img
            }
        }

        return nil
    }

    private static func bakeBitmapIcon(from image: NSImage, pixelSize: Int) -> NSImage? {
        var proposedRect = NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
        guard let cgIcon = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return nil
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: pixelSize,
            height: pixelSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        ctx.interpolationQuality = .high
        let size = CGFloat(pixelSize)
        let inset = size * 0.06
        let drawRect = CGRect(
            x: inset,
            y: inset + size * 0.015,
            width: size - inset * 2,
            height: size - inset * 2
        )

        ctx.setShadow(
            offset: CGSize(width: 0, height: -size * 0.02),
            blur: size * 0.045,
            color: CGColor(gray: 0.0, alpha: 0.30)
        )
        ctx.draw(cgIcon, in: drawRect)

        guard let rendered = ctx.makeImage() else { return nil }
        return NSImage(cgImage: rendered, size: NSSize(width: 128, height: 128))
    }

    private func loadHiddenIDs() {
        let stored = UserDefaults.standard.stringArray(forKey: LaunchlySettings.Keys.hiddenApps) ?? []
        hiddenIDs = Set(stored)
    }

    private func saveHiddenIDs() {
        UserDefaults.standard.set(Array(hiddenIDs).sorted(), forKey: LaunchlySettings.Keys.hiddenApps)
    }

    private func recomputePublishedLists() {
        apps = allApps.filter { !hiddenIDs.contains($0.id) }

        let scannedByID = Dictionary(uniqueKeysWithValues: allApps.map { ($0.id, $0) })
        hiddenAppEntries = hiddenIDs
            .map { id in
                if let item = scannedByID[id] {
                    return HiddenAppEntry(id: id, displayName: item.name, path: item.path)
                }
                let fallback = URL(fileURLWithPath: id).deletingPathExtension().lastPathComponent
                return HiddenAppEntry(id: id, displayName: fallback.isEmpty ? id : fallback, path: nil)
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func scanApplications() -> [AppItem] {
        let userApps = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .path

        let roots: [(path: String, maxDepth: Int)] = [
            ("/Applications", 2),
            ("/Applications/Utilities", 2),
            ("/System/Applications", 2),
            ("/System/Applications/Utilities", 2),
            ("/System/Volumes/Preboot/Cryptexes/App/System/Applications", 2),
            (userApps, 2),
            ("/System/Library/CoreServices/Applications", 0)
        ]

        var seenKeys = Set<String>()
        var collected: [AppItem] = []

        for root in roots {
            let rootURL = URL(fileURLWithPath: root.path, isDirectory: true)
            collectApps(
                in: rootURL,
                currentDepth: 0,
                maxDepth: root.maxDepth,
                seenKeys: &seenKeys,
                collected: &collected
            )
        }

        collected.sort { lhs, rhs in
            let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if order != .orderedSame {
                return order == .orderedAscending
            }
            return lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
        }

        logger.debug("Scanned \(collected.count) application(s)")
        return collected
    }

    private func collectApps(
        in directoryURL: URL,
        currentDepth: Int,
        maxDepth: Int,
        seenKeys: inout Set<String>,
        collected: inout [AppItem]
    ) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }

        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for itemURL in contents {
            let ext = itemURL.pathExtension.lowercased()
            if ext == "app" {
                guard let appItem = AppItem.make(from: itemURL) else { continue }
                if seenKeys.contains(appItem.id) {
                    continue
                }
                seenKeys.insert(appItem.id)
                collected.append(appItem)
                continue
            }

            guard currentDepth < maxDepth else { continue }

            let values = try? itemURL.resourceValues(forKeys: Set(resourceKeys))
            let isDirectory = values?.isDirectory ?? false
            let isPackage = values?.isPackage ?? false
            if isDirectory && !isPackage {
                collectApps(
                    in: itemURL,
                    currentDepth: currentDepth + 1,
                    maxDepth: maxDepth,
                    seenKeys: &seenKeys,
                    collected: &collected
                )
            }
        }
    }
}
