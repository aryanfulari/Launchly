import Foundation
import XCTest

final class LayoutSortingTests: XCTestCase {
    private let folderID = UUID()

    private lazy var folders: [UUID: AppFolder] = [
        folderID: AppFolder(id: folderID, name: "M-Folder", appIDs: ["a", "b"])
    ]

    private let names: [String: String] = [
        "a": "Alpha",
        "b": "Zulu",
        "c": "Beta",
        "d": "Delta"
    ]

    private let datesAdded: [String: Date] = [
        "a": Date(timeIntervalSince1970: 100),
        "b": Date(timeIntervalSince1970: 500), // folder max = 500
        "c": Date(timeIntervalSince1970: 300)
        // "d" is nil
    ]

    private let lastUsedDates: [String: Date] = [
        "a": Date(timeIntervalSince1970: 200),
        "b": Date(timeIntervalSince1970: 50),  // folder max = 200
        "c": Date(timeIntervalSince1970: 400)
        // "d" is nil
    ]

    private let sizes: [String: Int64] = [
        "a": 100,
        "b": 200, // folder sum = 300
        "c": 150
        // "d" is nil
    ]

    private let useCounts: [String: Int] = [
        "a": 3,
        "b": 12, // folder sum = 15
        "c": 8
        // "d" is nil
    ]

    private var entries: [LayoutEntry] {
        [.app("d"), .folder(folderID), .app("c")]
    }

    func testSortByMostUsedWithFolderSumAndNilLast() {
        let mostFirst = sort(.mostUsed, ascending: false)
        XCTAssertEqual(mostFirst, [.folder(folderID), .app("c"), .app("d")]) // 15, 8, nil

        let leastFirst = sort(.mostUsed, ascending: true)
        XCTAssertEqual(leastFirst, [.app("c"), .folder(folderID), .app("d")]) // 8, 15, nil
    }

    func testSortByNameAscendingAndDescending() {
        let asc = sort(.name, ascending: true)
        XCTAssertEqual(asc, [.app("c"), .app("d"), .folder(folderID)]) // Beta, Delta, M-Folder

        let desc = sort(.name, ascending: false)
        XCTAssertEqual(desc, [.folder(folderID), .app("d"), .app("c")])
    }

    func testSortByDateAddedWithFolderMaxAndNilLast() {
        let asc = sort(.dateAdded, ascending: true)
        XCTAssertEqual(asc, [.app("c"), .folder(folderID), .app("d")]) // 300, 500, nil

        let desc = sort(.dateAdded, ascending: false)
        XCTAssertEqual(desc, [.folder(folderID), .app("c"), .app("d")]) // 500, 300, nil
    }

    func testSortByLastOpenedWithFolderMaxAndNilLast() {
        let asc = sort(.lastOpened, ascending: true)
        XCTAssertEqual(asc, [.folder(folderID), .app("c"), .app("d")]) // 200, 400, nil

        let desc = sort(.lastOpened, ascending: false)
        XCTAssertEqual(desc, [.app("c"), .folder(folderID), .app("d")]) // 400, 200, nil
    }

    func testSortBySizeWithFolderSumAndNilLast() {
        let asc = sort(.size, ascending: true)
        XCTAssertEqual(asc, [.app("c"), .folder(folderID), .app("d")]) // 150, 300, nil

        let desc = sort(.size, ascending: false)
        XCTAssertEqual(desc, [.folder(folderID), .app("c"), .app("d")]) // 300, 150, nil
    }

    private func sort(_ mode: SortMode, ascending: Bool) -> [LayoutEntry] {
        LayoutSorter.sortedEntries(
            entries,
            folders: folders,
            mode: mode,
            ascending: ascending,
            name: { names[$0] ?? $0 },
            dateAdded: { datesAdded[$0] },
            lastUsed: { lastUsedDates[$0] },
            size: { sizes[$0] },
            useCount: { useCounts[$0] }
        )
    }
}
