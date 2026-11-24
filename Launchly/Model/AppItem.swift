import Foundation

struct AppItem: Identifiable, Hashable {
    let id: String
    let bundleID: String?
    let name: String
    let url: URL
    let path: String

    init(bundleID: String?, name: String, url: URL) {
        self.bundleID = bundleID
        self.name = name
        self.url = url
        self.path = url.path
        self.id = bundleID ?? url.path
    }

    static func make(from url: URL) -> AppItem? {
        let resolvedURL = url.resolvingSymlinksInPath()
        let bundle = Bundle(url: resolvedURL) ?? Bundle(url: url)
        let bundleID = bundle?.bundleIdentifier

        if let selfBundleID = Bundle.main.bundleIdentifier, bundleID == selfBundleID {
            return nil
        }

        let rawName = FileManager.default.displayName(atPath: resolvedURL.path)
        let displayName: String
        if rawName.lowercased().hasSuffix(".app") {
            displayName = String(rawName.dropLast(4))
        } else {
            displayName = rawName
        }

        return AppItem(bundleID: bundleID, name: displayName, url: resolvedURL)
    }
}

struct HiddenAppEntry: Identifiable, Hashable {
    let id: String
    let displayName: String
    let path: String?
}
