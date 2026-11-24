import Foundation
import XCTest

final class LayoutStoreTests: XCTestCase {
    private var tempDir: URL!
    private var layoutURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchlyLayoutTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        layoutURL = tempDir.appendingPathComponent("layout.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testReconcileEmptyAppendsAndDrops() {
        let store = LayoutStore(fileURL: layoutURL)
        store.reconcile(knownAppIDs: ["app.a", "app.b", "app.c"])
        XCTAssertEqual(store.entries, [.app("app.a"), .app("app.b"), .app("app.c")])

        store.reconcile(knownAppIDs: ["app.b", "app.c", "app.d"])
        XCTAssertEqual(store.entries, [.app("app.b"), .app("app.c"), .app("app.d")])
    }

    func testMoveEntry() {
        let store = LayoutStore(fileURL: layoutURL)
        store.reconcile(knownAppIDs: ["app.a", "app.b", "app.c", "app.d"])

        store.move(entry: .app("app.d"), to: 1)
        XCTAssertEqual(store.entries, [.app("app.a"), .app("app.d"), .app("app.b"), .app("app.c")])
    }

    func testCreateFolderAddRemoveDissolveRename() {
        let store = LayoutStore(fileURL: layoutURL)
        store.reconcile(knownAppIDs: ["app.a", "app.b", "app.c", "app.d"])

        let folderID = store.createFolder(appIDs: ["app.a", "app.b"], name: "Productivity", at: 0)
        XCTAssertEqual(store.entries, [.folder(folderID), .app("app.c"), .app("app.d")])
        XCTAssertEqual(store.folders[folderID]?.name, "Productivity")
        XCTAssertEqual(store.folders[folderID]?.appIDs, ["app.a", "app.b"])

        store.add(appID: "app.c", toFolder: folderID)
        XCTAssertEqual(store.entries, [.folder(folderID), .app("app.d")])
        XCTAssertEqual(store.folders[folderID]?.appIDs, ["app.a", "app.b", "app.c"])

        store.rename(folder: folderID, to: "Work")
        XCTAssertEqual(store.folders[folderID]?.name, "Work")

        // Remove 1 app -> inserted right after folder, folder still has 2 members
        store.remove(appID: "app.b", fromFolder: folderID)
        XCTAssertEqual(store.entries, [.folder(folderID), .app("app.b"), .app("app.d")])
        XCTAssertEqual(store.folders[folderID]?.appIDs, ["app.a", "app.c"])

        // Remove another -> only 1 left, so folder dissolves automatically
        store.remove(appID: "app.c", fromFolder: folderID)
        XCTAssertNil(store.folders[folderID])
        XCTAssertEqual(store.entries, [.app("app.a"), .app("app.c"), .app("app.b"), .app("app.d")])

        // Before folder2: [app.a, app.c, app.b, app.d]. Creating folder2 at index 2 places it after app.a, before app.b.
        let folder2 = store.createFolder(appIDs: ["app.c", "app.d"], name: "Tools", at: 2)
        XCTAssertEqual(store.entries, [.app("app.a"), .folder(folder2), .app("app.b")])
        store.dissolve(folder: folder2)
        XCTAssertNil(store.folders[folder2])
        XCTAssertEqual(store.entries, [.app("app.a"), .app("app.c"), .app("app.d"), .app("app.b")])
    }

    func testPersistenceRoundTrip() throws {
        let store = LayoutStore(fileURL: layoutURL)
        store.reconcile(knownAppIDs: ["app.a", "app.b", "app.c"])
        let folderID = store.createFolder(appIDs: ["app.a", "app.b"], name: "Group", at: 0)

        let reloaded = LayoutStore(fileURL: layoutURL)
        XCTAssertEqual(reloaded.entries, store.entries)
        XCTAssertEqual(reloaded.folders, store.folders)
        XCTAssertEqual(reloaded.folders[folderID]?.appIDs, ["app.a", "app.b"])

        // Also test direct LayoutEntry JSON round-trip
        let sample: [LayoutEntry] = [.app("app.x"), .folder(folderID)]
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode([LayoutEntry].self, from: data)
        XCTAssertEqual(decoded, sample)
    }
}
