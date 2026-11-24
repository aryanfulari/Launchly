import SwiftUI

struct LauncherView: View {
    @ObservedObject var viewModel: LauncherViewModel
    @ObservedObject var appCatalog: AppCatalog

    @AppStorage(LaunchlySettings.Keys.gridRows) private var gridRows: Int = LaunchlySettings.Defaults.gridRows
    @AppStorage(LaunchlySettings.Keys.gridColumns) private var gridColumns: Int = LaunchlySettings.Defaults.gridColumns
    @AppStorage(LaunchlySettings.Keys.iconSize) private var iconSize: Double = LaunchlySettings.Defaults.iconSize
    @AppStorage(LaunchlySettings.Keys.sortMode) private var sortModeRaw: String = LaunchlySettings.Defaults.sortMode
    @AppStorage(LaunchlySettings.Keys.sortAscending) private var sortAscending: Bool = LaunchlySettings.Defaults.sortAscending
    @AppStorage(LaunchlySettings.Keys.backgroundOpacity) private var backgroundOpacity: Double = LaunchlySettings.Defaults.backgroundOpacity

    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let isSearching = viewModel.isSearching
        let safeRows = max(1, gridRows)
        let safeCols = max(1, gridColumns)
        let perPage = safeRows * safeCols
        let hoverEnabled = !viewModel.isSwiping && viewModel.draggingID == nil

        let entries: [GridEntry] = isSearching ? [] : viewModel.gridEntries
        let searchApps: [AppItem] = isSearching ? viewModel.searchResults : []

        let totalPagesCount: Int = isSearching
            ? viewModel.paginated(searchApps, perPage: perPage).count
            : viewModel.paginated(entries, perPage: perPage).count
        let clampedPage = min(max(0, viewModel.currentPage), max(0, totalPagesCount - 1))

        GeometryReader { outerGeo in
            let horizontalInset = max(56, outerGeo.size.width * 0.065)

            ZStack {
                glassyBackground(size: outerGeo.size)
                    .ignoresSafeArea()

                // Click-to-dismiss hit target around outer margins
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture {
                        dismissOrCloseFolder()
                    }

                VStack(spacing: 0) {
                    // Centered top glassy search bar (with integrated sort/options menu), right below menu bar
                    searchBar
                        .padding(.top, max(38, viewModel.topSafeInset) + 14)
                        .padding(.bottom, 18)

                    // Full-width edge-to-edge CoreAnimation pager viewport (no side clipping boundary!)
                    GeometryReader { gridGeo in
                        let pageWidth = max(100, gridGeo.size.width)
                        let pageHeight = max(100, gridGeo.size.height)
                        let contentWidth = max(100, pageWidth - horizontalInset * 2)
                        let hSpacing: CGFloat = 18
                        let vSpacing: CGFloat = 18
                        let cellWidth = max(60, (contentWidth - hSpacing * CGFloat(safeCols - 1)) / CGFloat(safeCols))
                        let cellHeight = max(72, (pageHeight - vSpacing * CGFloat(safeRows - 1)) / CGFloat(safeRows))
                        let effectiveIconSize = max(32, min(CGFloat(iconSize), cellHeight - 32, cellWidth - 16))
                        let gridColumnsLayout = Array(
                            repeating: GridItem(.fixed(cellWidth), spacing: hSpacing, alignment: .center),
                            count: safeCols
                        )

                        Group {
                            if isSearching {
                                if searchApps.isEmpty {
                                    emptyStateView
                                        .frame(width: pageWidth, height: pageHeight)
                                        .contentShape(Rectangle())
                                        .onTapGesture { dismissOrCloseFolder() }
                                } else {
                                    let pages = viewModel.paginated(searchApps, perPage: perPage)
                                    NativeSmoothPager(
                                        animator: viewModel.pagerAnimator,
                                        currentPage: clampedPage,
                                        pageCount: pages.count,
                                        pageWidth: pageWidth,
                                        pageHeight: pageHeight
                                    ) {
                                        HStack(spacing: 0) {
                                            ForEach(Array(pages.enumerated()), id: \.offset) { pageIndex, pageItems in
                                                if abs(pageIndex - clampedPage) <= 1 {
                                                    let pageStartIndex = pageIndex * perPage

                                                    ZStack(alignment: .topLeading) {
                                                        Color.black.opacity(0.001)
                                                            .onTapGesture { dismissOrCloseFolder() }

                                                        LazyVGrid(columns: gridColumnsLayout, alignment: .leading, spacing: vSpacing) {
                                                            ForEach(pageItems, id: \.id) { item in
                                                                let itemOffset = pageItems.firstIndex(of: item) ?? 0
                                                                let globalIndex = pageStartIndex + itemOffset

                                                                AppIconCell(
                                                                    item: item,
                                                                    iconSize: effectiveIconSize,
                                                                    cellWidth: cellWidth,
                                                                    cellHeight: cellHeight,
                                                                    isSelected: viewModel.selectedIndex == globalIndex,
                                                                    hoverEnabled: hoverEnabled,
                                                                    appCatalog: appCatalog,
                                                                    existingFolders: viewModel.existingFolders,
                                                                    onOpen: { viewModel.launchApp(item) },
                                                                    onShowInFinder: { viewModel.showInFinder(item) },
                                                                    onHide: { viewModel.hideApp(item) },
                                                                    onAddToNewFolder: { viewModel.addToNewFolder(app: item) },
                                                                    onAddToExistingFolder: { folderID in viewModel.add(item, toFolder: folderID) }
                                                                )
                                                            }
                                                        }
                                                        .frame(width: contentWidth, height: pageHeight, alignment: .topLeading)
                                                        .padding(.horizontal, horizontalInset)
                                                    }
                                                    .frame(width: pageWidth, height: pageHeight)
                                                } else {
                                                    Color.clear
                                                        .frame(width: pageWidth, height: pageHeight)
                                                }
                                            }
                                        }
                                    }
                                }
                            } else {
                                if entries.isEmpty {
                                    emptyStateView
                                        .frame(width: pageWidth, height: pageHeight)
                                        .contentShape(Rectangle())
                                        .onTapGesture { dismissOrCloseFolder() }
                                } else {
                                    let pages = viewModel.paginated(entries, perPage: perPage)
                                    NativeSmoothPager(
                                        animator: viewModel.pagerAnimator,
                                        currentPage: clampedPage,
                                        pageCount: pages.count,
                                        pageWidth: pageWidth,
                                        pageHeight: pageHeight
                                    ) {
                                        HStack(spacing: 0) {
                                            ForEach(Array(pages.enumerated()), id: \.offset) { pageIndex, pageEntries in
                                                if abs(pageIndex - clampedPage) <= 1 {
                                                    ZStack(alignment: .topLeading) {
                                                        Color.black.opacity(0.001)
                                                            .onTapGesture { dismissOrCloseFolder() }

                                                        LaunchlyGlassContainer {
                                                            LazyVGrid(columns: gridColumnsLayout, alignment: .leading, spacing: vSpacing) {
                                                                ForEach(pageEntries, id: \.id) { entry in
                                                                    entryView(
                                                                        entry: entry,
                                                                        iconSize: effectiveIconSize,
                                                                        cellWidth: cellWidth,
                                                                        cellHeight: cellHeight,
                                                                        hoverEnabled: hoverEnabled,
                                                                        pageCount: pages.count,
                                                                        currentPage: pageIndex
                                                                    )
                                                                    .opacity(viewModel.draggingID == entry.id ? 0 : 1)
                                                                }
                                                            }
                                                            .frame(width: contentWidth, height: pageHeight, alignment: .topLeading)
                                                            .padding(.horizontal, horizontalInset)
                                                        }
                                                    }
                                                    .frame(width: pageWidth, height: pageHeight)
                                                } else {
                                                    Color.clear
                                                        .frame(width: pageWidth, height: pageHeight)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .frame(width: pageWidth, height: pageHeight, alignment: .leading)
                        .overlay {
                            // Subtle Liquid Glass edge chevrons when dragging an item near screen edges to cross pages
                            if viewModel.draggingID != nil {
                                HStack {
                                    if viewModel.activeEdgeDirection == -1 {
                                        Image(systemName: "chevron.left")
                                            .font(.system(size: 22, weight: .semibold))
                                            .foregroundColor(.white)
                                            .frame(width: 44, height: 84)
                                            .launchlyGlass(.clear, in: Capsule(style: .continuous))
                                            .padding(.leading, 18)
                                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                                    }
                                    Spacer()
                                    if viewModel.activeEdgeDirection == 1 {
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 22, weight: .semibold))
                                            .foregroundColor(.white)
                                            .frame(width: 44, height: 84)
                                            .launchlyGlass(.clear, in: Capsule(style: .continuous))
                                            .padding(.trailing, 18)
                                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                                    }
                                }
                                .allowsHitTesting(false)
                            }
                        }
                        .overlay(alignment: .topLeading) {
                            if let draggingID = viewModel.draggingID,
                               let draggedEntry = entries.first(where: { $0.id == draggingID }) {
                                entryView(
                                    entry: draggedEntry,
                                    iconSize: effectiveIconSize,
                                    cellWidth: cellWidth,
                                    cellHeight: cellHeight,
                                    hoverEnabled: false,
                                    pageCount: totalPagesCount,
                                    currentPage: clampedPage
                                )
                                .scaleEffect(1.12)
                                .shadow(color: Color.black.opacity(0.45), radius: 14, x: 0, y: 8)
                                .position(viewModel.dragLocation)
                                .allowsHitTesting(false)
                            }
                        }
                        .coordinateSpace(name: "pager")
                        .gesture(
                            DragGesture(minimumDistance: 6, coordinateSpace: .named("pager"))
                                .onChanged { value in
                                    viewModel.handlePagerDragChanged(
                                        startLocation: value.startLocation,
                                        location: value.location,
                                        translationWidth: value.translation.width,
                                        hitSlot: { point in
                                            slot(
                                                at: point,
                                                entries: viewModel.gridEntries,
                                                page: viewModel.currentPage,
                                                perPage: perPage,
                                                rows: safeRows,
                                                cols: safeCols,
                                                horizontalInset: horizontalInset,
                                                contentWidth: contentWidth,
                                                pageHeight: pageHeight,
                                                cellWidth: cellWidth,
                                                cellHeight: cellHeight,
                                                hSpacing: hSpacing,
                                                vSpacing: vSpacing
                                            )
                                        }
                                    )
                                }
                                .onEnded { value in
                                    viewModel.handlePagerDragEnded(
                                        translationWidth: value.translation.width,
                                        predictedWidth: value.predictedEndTranslation.width
                                    )
                                }
                        )
                        .onAppear {
                            viewModel.pageWidth = pageWidth
                            viewModel.horizontalInset = horizontalInset
                        }
                        .onChange(of: pageWidth) { _, newWidth in
                            viewModel.pageWidth = newWidth
                            viewModel.horizontalInset = horizontalInset
                        }
                    }
                    .padding(.vertical, 8)

                    PageDots(
                        pageCount: totalPagesCount,
                        currentPage: clampedPage,
                        onSelectPage: { target in
                            viewModel.goToPage(target)
                        }
                    )
                    .padding(.top, 12)
                    .padding(.bottom, max(24, viewModel.bottomSafeInset + 18))
                }
                .blur(radius: viewModel.openFolderID != nil ? 12 : 0)
                .animation(.easeOut(duration: 0.2), value: viewModel.openFolderID != nil)

                if let openFolderID = viewModel.openFolderID,
                   case .folder(let folder, let members) = entries.first(where: {
                       if case .folder(let f, _) = $0 { return f.id == openFolderID }
                       return false
                   }) {
                    FolderPanel(
                        folder: folder,
                        members: members,
                        screenSize: outerGeo.size,
                        viewModel: viewModel,
                        appCatalog: appCatalog
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
                }
            }
        }
        .onAppear {
            isSearchFocused = true
        }
        .onChange(of: viewModel.focusTrigger) { _, _ in
            isSearchFocused = true
        }
        .onChange(of: sortModeRaw) { _, _ in
            viewModel.rebuildGridEntries()
        }
        .onChange(of: sortAscending) { _, _ in
            viewModel.rebuildGridEntries()
        }
    }

    private func dismissOrCloseFolder() {
        if viewModel.openFolderID != nil {
            withAnimation(.easeOut(duration: 0.2)) {
                viewModel.closeFolder()
            }
        } else {
            viewModel.dismiss(restoreFocus: true)
        }
    }

    @ViewBuilder
    private func glassyBackground(size: CGSize) -> some View {
        let clampedOpacity = min(max(0.0, backgroundOpacity), 1.0)

        ZStack {
            BehindWindowGlassBackdrop(opacity: clampedOpacity)

            if clampedOpacity > 0.001 {
                Group {
                    if let wallpaper = viewModel.blurredWallpaperImage {
                        Image(nsImage: wallpaper)
                            .resizable()
                            .interpolation(.medium)
                            .aspectRatio(contentMode: .fill)
                            .frame(width: size.width, height: size.height)
                            .clipped()
                    } else {
                        LinearGradient(
                            colors: [
                                Color(red: 0.14, green: 0.24, blue: 0.62),
                                Color(red: 0.08, green: 0.15, blue: 0.45),
                                Color(red: 0.12, green: 0.28, blue: 0.66)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
                }
                .opacity(clampedOpacity)

                LinearGradient(
                    colors: [
                        Color.white.opacity(0.12 * clampedOpacity),
                        Color.white.opacity(0.03 * clampedOpacity),
                        Color.white.opacity(0.07 * clampedOpacity)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func entryView(
        entry: GridEntry,
        iconSize: CGFloat,
        cellWidth: CGFloat,
        cellHeight: CGFloat,
        hoverEnabled: Bool,
        pageCount: Int,
        currentPage: Int
    ) -> some View {
        switch entry {
        case .app(let item):
            AppIconCell(
                item: item,
                iconSize: iconSize,
                cellWidth: cellWidth,
                cellHeight: cellHeight,
                isSelected: false,
                isFolderTarget: viewModel.folderTargetID == entry.id,
                hoverEnabled: hoverEnabled,
                appCatalog: appCatalog,
                existingFolders: viewModel.existingFolders,
                pageCount: pageCount,
                currentPage: currentPage,
                onOpen: { viewModel.launchApp(item) },
                onShowInFinder: { viewModel.showInFinder(item) },
                onHide: { viewModel.hideApp(item) },
                onAddToNewFolder: { viewModel.addToNewFolder(app: item) },
                onAddToExistingFolder: { folderID in viewModel.add(item, toFolder: folderID) },
                onMoveToPage: { targetPage in viewModel.moveEntry(entry.layoutEntry, toPage: targetPage) }
            )
        case .folder(let folder, let members):
            FolderTile(
                folder: folder,
                members: members,
                iconSize: iconSize,
                cellWidth: cellWidth,
                cellHeight: cellHeight,
                isFolderTarget: viewModel.folderTargetID == entry.id,
                hoverEnabled: hoverEnabled,
                pageCount: pageCount,
                currentPage: currentPage,
                appCatalog: appCatalog,
                onOpen: {
                    withAnimation(.easeOut(duration: 0.2)) {
                        viewModel.openFolder(folder.id)
                    }
                },
                onRename: {
                    withAnimation(.easeOut(duration: 0.2)) {
                        viewModel.openFolder(folder.id, focusTitle: true)
                    }
                },
                onDissolve: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.dissolveFolder(folder.id)
                    }
                },
                onMoveToPage: { targetPage in viewModel.moveEntry(entry.layoutEntry, toPage: targetPage) }
            )
        }
    }

    private func slot(
        at point: CGPoint,
        entries: [GridEntry],
        page: Int,
        perPage: Int,
        rows: Int,
        cols: Int,
        horizontalInset: CGFloat,
        contentWidth: CGFloat,
        pageHeight: CGFloat,
        cellWidth: CGFloat,
        cellHeight: CGFloat,
        hSpacing: CGFloat,
        vSpacing: CGFloat
    ) -> (index: Int, zone: LauncherViewModel.SlotZone)? {
        let gridX = point.x - horizontalInset
        guard gridX >= 0, point.y >= 0, gridX <= contentWidth, point.y <= pageHeight else {
            return nil
        }

        let stepX = cellWidth + hSpacing
        let stepY = cellHeight + vSpacing
        let col = Int(gridX / stepX)
        let row = Int(point.y / stepY)

        guard col >= 0, col < cols, row >= 0, row < rows else {
            return nil
        }

        let localX = gridX - CGFloat(col) * stepX
        let localY = point.y - CGFloat(row) * stepY
        let index = page * perPage + row * cols + col

        if localX > cellWidth {
            guard localY <= cellHeight else { return nil }
            let insertIndex = min(index + 1, page * perPage + (row + 1) * cols - 1)
            return (index: insertIndex, zone: .edge)
        }

        guard localY <= cellHeight else {
            return nil
        }

        let isFolderAtSlot: Bool = {
            guard index < entries.count else { return false }
            if case .folder = entries[index] { return true }
            return false
        }()

        let xMargin: CGFloat = isFolderAtSlot ? 0.08 : 0.15
        let yMargin: CGFloat = isFolderAtSlot ? 0.08 : 0.12

        let inCenter = localX >= cellWidth * xMargin &&
            localX <= cellWidth * (1.0 - xMargin) &&
            localY >= cellHeight * yMargin &&
            localY <= cellHeight * (1.0 - yMargin)

        return (index: index, zone: inCenter ? .center : .edge)
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(.white.opacity(0.75))
            Text("No Applications Found")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .launchlyGlass(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var searchBar: some View {
        LaunchlyGlassContainer(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))

                TextField("Search Applications", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundColor(.white)
                    .focused($isSearchFocused)

                if !viewModel.searchText.isEmpty {
                    Button {
                        viewModel.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.78))
                    }
                    .buttonStyle(.plain)
                }

                SortMenu(onOpenSettings: {
                    viewModel.dismiss(restoreFocus: false)
                    viewModel.onOpenSettings?()
                })
            }
            .padding(.horizontal, 14)
            .frame(width: 340, height: 38)
            .launchlyGlass(.regular, interactive: true, in: Capsule(style: .continuous))
        }
    }
}
