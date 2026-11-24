import AppKit
import Combine
import CoreImage
import Foundation
import SwiftUI

enum GridEntry: Identifiable {
    case app(AppItem)
    case folder(AppFolder, [AppItem])

    var id: String {
        switch self {
        case .app(let item):
            return "app:\(item.id)"
        case .folder(let folder, _):
            return "folder:\(folder.id.uuidString)"
        }
    }

    var layoutEntry: LayoutEntry {
        switch self {
        case .app(let item):
            return .app(item.id)
        case .folder(let folder, _):
            return .folder(folder.id)
        }
    }
}

final class LauncherViewModel: ObservableObject {
    @Published var searchText: String = "" {
        didSet {
            if searchText != oldValue {
                currentPage = 0
                pagerAnimator.snapToPage(0, pageWidth: pageWidth)
                openFolderID = nil
                cancelDragState()
                rebuildSearchResults()
                let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                selectedIndex = trimmed.isEmpty ? nil : (searchResults.isEmpty ? nil : 0)
            }
        }
    }

    @Published var currentPage: Int = 0
    @Published var selectedIndex: Int?
    @Published var focusTrigger = UUID()
    @Published var isSwiping: Bool = false
    var pageWidth: CGFloat = 1200

    let pagerAnimator = PagerAnimator()

    // Cached lists so SwiftUI body never allocates dictionaries or re-sorts during animations.
    @Published private(set) var gridEntries: [GridEntry] = []
    @Published private(set) var searchResults: [AppItem] = []

    // Safe insets so menu bar and Dock stay clear
    @Published var topSafeInset: CGFloat = 38
    @Published var bottomSafeInset: CGFloat = 0

    // Pre-blurred, downsampled desktop wallpaper (zero live GPU blur cost per frame)
    @Published var blurredWallpaperImage: NSImage?
    private var loadedWallpaperURL: URL?

    @Published var openFolderID: UUID?
    @Published var folderTitleFocusTrigger = UUID()

    // Drag & drop state
    @Published var draggingID: String?
    @Published var dragLocation: CGPoint = .zero
    @Published var dragWorkingOrder: [LayoutEntry]? {
        didSet {
            rebuildGridEntries()
        }
    }
    @Published var folderTargetID: String?
    @Published var activeEdgeDirection: Int = 0 // -1 left, +1 right, 0 none
    var horizontalInset: CGFloat = 96

    let appCatalog: AppCatalog
    let layoutStore: LayoutStore
    let metadataStore: AppMetadataStore
    let spotlightIndex: SpotlightAppIndex
    var onDismiss: ((Bool) -> Void)?
    var onOpenSettings: (() -> Void)?

    private var cancellables = Set<AnyCancellable>()
    private var hoverFolderWorkItem: DispatchWorkItem?
    private var pendingFolderTargetID: String?
    private var pendingReorderWorkItem: DispatchWorkItem?
    private var pendingReorderIndex: Int?
    private var edgePagingTimer: Timer?
    private var edgePagingDirection: Int = 0
    private var isDraggingItem = false
    private var mouseDragBaseOffset: CGFloat = 0

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    init(
        appCatalog: AppCatalog,
        layoutStore: LayoutStore,
        metadataStore: AppMetadataStore,
        spotlightIndex: SpotlightAppIndex
    ) {
        self.appCatalog = appCatalog
        self.layoutStore = layoutStore
        self.metadataStore = metadataStore
        self.spotlightIndex = spotlightIndex

        Publishers.MergeMany([
            appCatalog.$apps.map { _ in () }.eraseToAnyPublisher(),
            appCatalog.$allApps.map { _ in () }.eraseToAnyPublisher(),
            layoutStore.$entries.map { _ in () }.eraseToAnyPublisher(),
            layoutStore.$folders.map { _ in () }.eraseToAnyPublisher(),
            metadataStore.$metadata.map { _ in () }.eraseToAnyPublisher()
        ])
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.rebuildGridEntries()
        }
        .store(in: &cancellables)

        Publishers.Merge(
            appCatalog.$allApps.map { _ in () },
            spotlightIndex.$apps.map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            guard let self, self.isSearching else { return }
            self.rebuildSearchResults()
        }
        .store(in: &cancellables)

        rebuildGridEntries()
    }

    deinit {
        cancelDragTimers()
    }

    func updateWallpaper(for screen: NSScreen?) {
        guard let screen, let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return }
        if url == loadedWallpaperURL && blurredWallpaperImage != nil { return }
        loadedWallpaperURL = url

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let preblurred = Self.renderPreBlurredWallpaper(from: url) else { return }
            DispatchQueue.main.async {
                guard let self, self.loadedWallpaperURL == url else { return }
                self.blurredWallpaperImage = preblurred
            }
        }
    }

    private static func renderPreBlurredWallpaper(from url: URL) -> NSImage? {
        guard let source = CIImage(contentsOf: url) else { return nil }
        let origExtent = source.extent
        guard origExtent.width > 0, origExtent.height > 0 else { return nil }

        let targetWidth: CGFloat = 640
        let scale = min(1.0, targetWidth / origExtent.width)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let targetRect = scaled.extent.integral

        let saturated = scaled.applyingFilter(
            "CIColorControls",
            parameters: [kCIInputSaturationKey: 1.22]
        )
        let blurred = saturated
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 16.0])
            .cropped(to: targetRect)

        guard let cgImage = ciContext.createCGImage(blurred, from: targetRect) else { return nil }
        return NSImage(cgImage: cgImage, size: targetRect.size)
    }

    // MARK: - Settings Accessors

    var sortMode: SortMode {
        let raw = UserDefaults.standard.string(forKey: LaunchlySettings.Keys.sortMode) ?? LaunchlySettings.Defaults.sortMode
        return SortMode(rawValue: raw) ?? .custom
    }

    var sortAscending: Bool {
        UserDefaults.standard.bool(forKey: LaunchlySettings.Keys.sortAscending)
    }

    var pagingDuration: Double {
        let val = UserDefaults.standard.double(forKey: LaunchlySettings.Keys.pagingDuration)
        return val > 0 ? val : LaunchlySettings.Defaults.pagingDuration
    }

    var gridRows: Int {
        let val = UserDefaults.standard.integer(forKey: LaunchlySettings.Keys.gridRows)
        return max(1, val > 0 ? val : LaunchlySettings.Defaults.gridRows)
    }

    var gridColumns: Int {
        let val = UserDefaults.standard.integer(forKey: LaunchlySettings.Keys.gridColumns)
        return max(1, val > 0 ? val : LaunchlySettings.Defaults.gridColumns)
    }

    var itemsPerPage: Int {
        max(1, gridRows * gridColumns)
    }

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Cached Rebuild

    func rebuildGridEntries() {
        let allByID = Dictionary(uniqueKeysWithValues: appCatalog.allApps.map { ($0.id, $0) })
        let visibleByID = Dictionary(uniqueKeysWithValues: appCatalog.apps.map { ($0.id, $0) })
        let meta = metadataStore.metadata
        let mode = sortMode
        let ascending = sortAscending

        let sourceEntries: [LayoutEntry]
        if let dragWorkingOrder {
            sourceEntries = dragWorkingOrder
        } else {
            sourceEntries = LayoutSorter.sortedEntries(
                layoutStore.entries,
                folders: layoutStore.folders,
                mode: mode,
                ascending: ascending,
                name: { allByID[$0]?.name ?? $0 },
                dateAdded: { meta[$0]?.dateAdded },
                lastUsed: { meta[$0]?.lastUsed },
                size: { meta[$0]?.sizeBytes },
                useCount: { meta[$0]?.useCount }
            )
        }

        var result: [GridEntry] = []
        result.reserveCapacity(sourceEntries.count)

        for entry in sourceEntries {
            switch entry {
            case .app(let appID):
                if let item = visibleByID[appID] {
                    result.append(.app(item))
                }
            case .folder(let folderID):
                guard let folder = layoutStore.folders[folderID] else { continue }
                let visibleMemberIDs = folder.appIDs.filter { visibleByID[$0] != nil }
                guard !visibleMemberIDs.isEmpty else { continue }

                let orderedMemberIDs: [String]
                if mode == .custom || dragWorkingOrder != nil {
                    orderedMemberIDs = visibleMemberIDs
                } else {
                    orderedMemberIDs = LayoutSorter.sortedAppIDs(
                        visibleMemberIDs,
                        mode: mode,
                        ascending: ascending,
                        name: { allByID[$0]?.name ?? $0 },
                        dateAdded: { meta[$0]?.dateAdded },
                        lastUsed: { meta[$0]?.lastUsed },
                        size: { meta[$0]?.sizeBytes },
                        useCount: { meta[$0]?.useCount }
                    )
                }

                let memberItems = orderedMemberIDs.compactMap { visibleByID[$0] }
                if !memberItems.isEmpty {
                    result.append(.folder(folder, memberItems))
                }
            }
        }

        gridEntries = result
    }

    func rebuildSearchResults() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            if !searchResults.isEmpty {
                searchResults = []
            }
            return
        }

        var poolByID: [String: AppItem] = [:]
        for item in spotlightIndex.apps {
            poolByID[item.id] = item
        }
        for item in appCatalog.allApps {
            poolByID[item.id] = item
        }

        var ranked: [(rank: Int, item: AppItem)] = []
        for item in poolByID.values {
            if let rank = matchRank(for: item, query: query) {
                ranked.append((rank, item))
            }
        }

        ranked.sort { lhs, rhs in
            if lhs.rank != rhs.rank {
                return lhs.rank < rhs.rank
            }
            let cmp = lhs.item.name.localizedCaseInsensitiveCompare(rhs.item.name)
            if cmp != .orderedSame {
                return cmp == .orderedAscending
            }
            return lhs.item.id < rhs.item.id
        }

        searchResults = ranked.map(\.item)
    }

    var existingFolders: [AppFolder] {
        layoutStore.entries.compactMap { entry in
            if case .folder(let id) = entry {
                return layoutStore.folders[id]
            }
            return nil
        }
    }

    var pageCount: Int {
        let count = isSearching ? searchResults.count : gridEntries.count
        return max(1, Int(ceil(Double(count) / Double(itemsPerPage))))
    }

    func paginated<T>(_ items: [T], perPage: Int) -> [[T]] {
        let safePerPage = max(1, perPage)
        guard !items.isEmpty else { return [[]] }
        return stride(from: 0, to: items.count, by: safePerPage).map { start in
            let end = min(start + safePerPage, items.count)
            return Array(items[start..<end])
        }
    }

    // MARK: - Presentation & Paging

    func resetForPresentation() {
        searchText = ""
        currentPage = 0
        selectedIndex = nil
        isSwiping = false
        openFolderID = nil
        cancelDragState()
        focusTrigger = UUID()
        rebuildGridEntries()
        pagerAnimator.snapToPage(0, pageWidth: pageWidth)
    }

    func goToPage(_ page: Int, animated: Bool = true, velocity: CGFloat = 0) {
        let clamped = min(max(0, page), pageCount - 1)
        currentPage = clamped
        if animated {
            pagerAnimator.animateToPage(clamped, pageWidth: pageWidth, velocity: velocity, duration: pagingDuration)
        } else {
            pagerAnimator.snapToPage(clamped, pageWidth: pageWidth)
        }
    }

    func nextPage(animated: Bool = true, velocity: CGFloat = 0) {
        goToPage(currentPage + 1, animated: animated, velocity: velocity)
    }

    func previousPage(animated: Bool = true, velocity: CGFloat = 0) {
        goToPage(currentPage - 1, animated: animated, velocity: velocity)
    }

    func moveSelection(deltaRow: Int, deltaCol: Int) {
        let items = searchResults
        guard !items.isEmpty else {
            selectedIndex = nil
            return
        }

        let step = deltaRow * gridColumns + deltaCol
        let current = selectedIndex ?? 0
        let next = min(max(0, current + step), items.count - 1)
        selectedIndex = next

        let targetPage = next / itemsPerPage
        goToPage(targetPage)
    }

    func launchSelectedOrFirst() {
        let items = searchResults
        guard !items.isEmpty else { return }
        let idx = min(max(0, selectedIndex ?? 0), items.count - 1)
        launchApp(items[idx])
    }

    func launchApp(_ item: AppItem) {
        metadataStore.recordLaunch(appID: item.id)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: item.url, configuration: config) { _, _ in }
        dismiss(restoreFocus: false)
    }

    func showInFinder(_ item: AppItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
        dismiss(restoreFocus: false)
    }

    func hideApp(_ item: AppItem) {
        appCatalog.hide(item)
        if let idx = selectedIndex, idx >= searchResults.count {
            selectedIndex = searchResults.isEmpty ? nil : searchResults.count - 1
        }
        if currentPage >= pageCount {
            goToPage(max(0, pageCount - 1), animated: false)
        }
    }

    func openFolder(_ folderID: UUID, focusTitle: Bool = false) {
        openFolderID = folderID
        if focusTitle {
            folderTitleFocusTrigger = UUID()
        }
    }

    func closeFolder() {
        openFolderID = nil
    }

    func addToNewFolder(app item: AppItem) {
        materializeSortIfNeeded()
        let currentIndex = layoutStore.entries.firstIndex(of: .app(item.id)) ?? layoutStore.entries.count
        let name = suggestedFolderName(for: item.id)
        let folderID = layoutStore.createFolder(appIDs: [item.id], name: name, at: currentIndex)
        openFolder(folderID, focusTitle: true)
    }

    func add(_ item: AppItem, toFolder folderID: UUID) {
        materializeSortIfNeeded()
        layoutStore.add(appID: item.id, toFolder: folderID)
    }

    func dissolveFolder(_ folderID: UUID) {
        materializeSortIfNeeded()
        if openFolderID == folderID {
            openFolderID = nil
        }
        layoutStore.dissolve(folder: folderID)
    }

    func moveEntry(_ entry: LayoutEntry, toPage targetPage: Int) {
        let clampedPage = min(max(0, targetPage), max(0, pageCount - 1))
        guard clampedPage != currentPage else { return }

        materializeSortIfNeeded()
        let visibleEntries = gridEntries.map(\.layoutEntry)
        guard let currentIndex = visibleEntries.firstIndex(of: entry) else { return }

        var updated = visibleEntries
        updated.remove(at: currentIndex)

        let destinationIndex: Int
        if clampedPage > currentPage {
            // Place at the first slot of the target page.
            destinationIndex = min(max(0, clampedPage * itemsPerPage), updated.count)
        } else {
            // Place at the last slot of the target page.
            destinationIndex = min(max(0, (clampedPage + 1) * itemsPerPage - 1), updated.count)
        }

        updated.insert(entry, at: destinationIndex)
        commitVisibleOrder(updated)
        goToPage(clampedPage, animated: true)
    }

    func dismiss(restoreFocus: Bool = true) {
        openFolderID = nil
        isSwiping = false
        cancelDragState()
        onDismiss?(restoreFocus)
    }

    // MARK: - Drag & Drop Paging/Reordering/Grouping

    enum SlotZone {
        case center
        case edge
    }

    func handlePagerDragChanged(
        startLocation: CGPoint,
        location: CGPoint,
        translationWidth: CGFloat,
        hitSlot: (CGPoint) -> (index: Int, zone: SlotZone)?
    ) {
        guard !isSearching, openFolderID == nil else { return }

        if draggingID == nil && !isDraggingItem && !isSwiping {
            let currentEntries = gridEntries
            if let startHit = hitSlot(startLocation), startHit.index < currentEntries.count {
                let entry = currentEntries[startHit.index]
                isDraggingItem = true
                draggingID = entry.id
                dragLocation = location
                dragWorkingOrder = currentEntries.map(\.layoutEntry)
            } else {
                isSwiping = true
                mouseDragBaseOffset = pagerAnimator.beginInteractiveScroll(page: currentPage, pageWidth: pageWidth)
            }
        }

        if isDraggingItem, let draggedID = draggingID {
            dragLocation = location
            updateEdgePaging(forX: location.x)

            guard let working = dragWorkingOrder,
                  let draggedIndex = working.firstIndex(where: { $0.stableID == draggedID }) else { return }

            if let hit = hitSlot(location) {
                if hit.index < working.count {
                    let targetEntry = working[hit.index]
                    if targetEntry.stableID == draggedID {
                        cancelHoverFolderTimer()
                        cancelPendingReorder()
                    } else if hit.zone == .center, case .app = working[draggedIndex] {
                        cancelPendingReorder()
                        let isFolder = {
                            if case .folder = targetEntry { return true }
                            return false
                        }()
                        scheduleHoverFolderTimer(for: targetEntry.stableID, delay: isFolder ? 0.08 : 0.14)
                    } else {
                        cancelHoverFolderTimer()
                        scheduleReorder(to: hit.index)
                    }
                } else {
                    cancelHoverFolderTimer()
                    scheduleReorder(to: max(0, working.count - 1))
                }
            } else {
                cancelHoverFolderTimer()
                cancelPendingReorder()
            }
        } else {
            let combined = mouseDragBaseOffset + translationWidth
            let maxPage = max(0, pageCount - 1)
            let rubber: CGFloat
            if (currentPage == 0 && combined > 0) || (currentPage >= maxPage && combined < 0) {
                rubber = combined / 3.0
            } else {
                rubber = combined
            }
            pagerAnimator.setInteractiveOffset(rubber, page: currentPage, pageWidth: pageWidth)
        }
    }

    func handlePagerDragEnded(translationWidth: CGFloat, predictedWidth: CGFloat) {
        if isDraggingItem {
            let effectiveTargetID = folderTargetID ?? pendingFolderTargetID
            defer { cancelDragState() }

            guard let working = dragWorkingOrder,
                  let draggedID = draggingID else { return }

            if let targetID = effectiveTargetID,
               let draggedEntry = working.first(where: { $0.stableID == draggedID }),
               case .app(let draggedAppID) = draggedEntry,
               let targetIndex = working.firstIndex(where: { $0.stableID == targetID }) {
                materializeSortIfNeeded(using: working)

                switch working[targetIndex] {
                case .folder(let targetFolderID):
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        layoutStore.add(appID: draggedAppID, toFolder: targetFolderID)
                    }
                case .app(let targetAppID):
                    let name = suggestedFolderName(for: targetAppID)
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        _ = layoutStore.createFolder(appIDs: [targetAppID, draggedAppID], name: name, at: targetIndex)
                    }
                }
            } else {
                commitVisibleOrder(working)
            }
            return
        }

        isSwiping = false
        let threshold = max(40, pageWidth * 0.14)
        let targetPage: Int
        if translationWidth < -threshold || predictedWidth < -threshold * 1.8 {
            targetPage = min(currentPage + 1, pageCount - 1)
        } else if translationWidth > threshold || predictedWidth > threshold * 1.8 {
            targetPage = max(currentPage - 1, 0)
        } else {
            targetPage = currentPage
        }
        goToPage(targetPage, animated: true)
    }

    func suggestedFolderName(for appID: String) -> String {
        guard let item = appCatalog.allApps.first(where: { $0.id == appID }),
              let bundle = Bundle(url: item.url.resolvingSymlinksInPath()) ?? Bundle(url: item.url),
              let category = bundle.infoDictionary?["LSApplicationCategoryType"] as? String,
              let lastComponent = category.split(separator: ".").last,
              !lastComponent.isEmpty else {
            return "New Folder"
        }

        let words = lastComponent
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? "New Folder" : words.capitalized
    }

    // MARK: - Private Helpers

    private func materializeSortIfNeeded(using visibleOrder: [LayoutEntry]? = nil) {
        let order = visibleOrder ?? gridEntries.map(\.layoutEntry)
        if sortMode != .custom {
            commitVisibleOrder(order)
            UserDefaults.standard.set(SortMode.custom.rawValue, forKey: LaunchlySettings.Keys.sortMode)
        } else if visibleOrder != nil {
            commitVisibleOrder(order)
        }
    }

    private func commitVisibleOrder(_ visibleOrder: [LayoutEntry]) {
        let visibleSet = Set(visibleOrder.map(\.stableID))
        let hiddenRemainder = layoutStore.entries.filter { !visibleSet.contains($0.stableID) }
        layoutStore.setOrder(visibleOrder + hiddenRemainder)
        if sortMode != .custom {
            UserDefaults.standard.set(SortMode.custom.rawValue, forKey: LaunchlySettings.Keys.sortMode)
        }
    }

    private func scheduleReorder(to targetIndex: Int) {
        if pendingReorderIndex == targetIndex { return }
        cancelPendingReorder()
        pendingReorderIndex = targetIndex

        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.isDraggingItem,
                  self.pendingReorderIndex == targetIndex,
                  let draggedID = self.draggingID,
                  var working = self.dragWorkingOrder,
                  let draggedIndex = working.firstIndex(where: { $0.stableID == draggedID }) else { return }

            let clamped = min(max(0, targetIndex), max(0, working.count - 1))
            guard draggedIndex != clamped else { return }
            let moved = working.remove(at: draggedIndex)
            working.insert(moved, at: clamped)
            withAnimation(.easeInOut(duration: 0.2)) {
                self.dragWorkingOrder = working
            }
            self.pendingReorderIndex = nil
            self.pendingReorderWorkItem = nil
        }
        pendingReorderWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: workItem)
    }

    private func cancelPendingReorder() {
        pendingReorderWorkItem?.cancel()
        pendingReorderWorkItem = nil
        pendingReorderIndex = nil
    }

    private func scheduleHoverFolderTimer(for targetID: String, delay: TimeInterval) {
        if pendingFolderTargetID == targetID {
            return
        }
        cancelHoverFolderTimer()
        pendingFolderTargetID = targetID

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isDraggingItem, self.pendingFolderTargetID == targetID else { return }
            withAnimation(.spring(response: 0.22, dampingFraction: 0.78)) {
                self.folderTargetID = targetID
            }
        }
        hoverFolderWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelHoverFolderTimer() {
        hoverFolderWorkItem?.cancel()
        hoverFolderWorkItem = nil
        pendingFolderTargetID = nil
        if folderTargetID != nil {
            withAnimation(.easeOut(duration: 0.15)) {
                folderTargetID = nil
            }
        }
    }

    private func updateEdgePaging(forX x: CGFloat) {
        let edgeThreshold = max(84, horizontalInset * 0.95)
        let newDirection: Int
        if x < edgeThreshold && currentPage > 0 {
            newDirection = -1
        } else if x > pageWidth - edgeThreshold && currentPage < pageCount - 1 {
            newDirection = 1
        } else {
            newDirection = 0
        }

        if newDirection == edgePagingDirection {
            return
        }

        edgePagingTimer?.invalidate()
        edgePagingTimer = nil
        edgePagingDirection = newDirection
        if activeEdgeDirection != newDirection {
            withAnimation(.easeOut(duration: 0.15)) {
                activeEdgeDirection = newDirection
            }
        }

        guard newDirection != 0 else { return }

        // Schedule on .common RunLoop mode so the timer fires reliably during active mouse DragGesture (.eventTracking).
        let initialTimer = Timer(timeInterval: 0.35, repeats: false) { [weak self] _ in
            guard let self, self.isDraggingItem, self.edgePagingDirection == newDirection else { return }
            self.stepEdgePage(direction: newDirection)

            let repeatTimer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
                guard let self, self.isDraggingItem, self.edgePagingDirection == newDirection else { return }
                self.stepEdgePage(direction: newDirection)
            }
            RunLoop.main.add(repeatTimer, forMode: .common)
            self.edgePagingTimer = repeatTimer
        }
        RunLoop.main.add(initialTimer, forMode: .common)
        edgePagingTimer = initialTimer
    }

    func stepEdgePage(direction: Int) {
        let targetPage: Int
        if direction < 0 {
            guard currentPage > 0 else { return }
            targetPage = currentPage - 1
        } else if direction > 0 {
            guard currentPage < pageCount - 1 else { return }
            targetPage = currentPage + 1
        } else {
            return
        }

        cancelHoverFolderTimer()
        cancelPendingReorder()

        // Immediately relocate the dragged app/folder onto the destination page so dropping anywhere lands it there.
        if let draggedID = draggingID,
           var working = dragWorkingOrder,
           let draggedIndex = working.firstIndex(where: { $0.stableID == draggedID }) {
            let moved = working.remove(at: draggedIndex)
            let targetSlot: Int
            if direction > 0 {
                // First slot on the next page
                targetSlot = min(max(0, targetPage * itemsPerPage), working.count)
            } else {
                // Last slot on the previous page
                targetSlot = min(max(0, (targetPage + 1) * itemsPerPage - 1), working.count)
            }
            working.insert(moved, at: targetSlot)
            withAnimation(.easeInOut(duration: 0.2)) {
                dragWorkingOrder = working
            }
        }

        goToPage(targetPage, animated: true)

        // Stop edge glow if we reached the first/last page.
        if (direction < 0 && currentPage == 0) || (direction > 0 && currentPage >= pageCount - 1) {
            edgePagingTimer?.invalidate()
            edgePagingTimer = nil
            edgePagingDirection = 0
            withAnimation(.easeOut(duration: 0.15)) {
                activeEdgeDirection = 0
            }
        }
    }

    private func cancelDragTimers() {
        hoverFolderWorkItem?.cancel()
        hoverFolderWorkItem = nil
        pendingFolderTargetID = nil
        cancelPendingReorder()
        edgePagingTimer?.invalidate()
        edgePagingTimer = nil
        edgePagingDirection = 0
        if activeEdgeDirection != 0 {
            activeEdgeDirection = 0
        }
    }

    private func cancelDragState() {
        cancelDragTimers()
        isDraggingItem = false
        draggingID = nil
        dragWorkingOrder = nil
        folderTargetID = nil
    }

    private func matchRank(for item: AppItem, query: String) -> Int? {
        if item.name.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return 0
        }
        if item.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil {
            return 1
        }
        let words = item.name.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        if words.contains(where: { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil }) {
            return 2
        }
        if item.name.localizedCaseInsensitiveContains(query) {
            return 3
        }
        if let bundleID = item.bundleID, bundleID.localizedCaseInsensitiveContains(query) {
            return 4
        }
        return nil
    }
}
