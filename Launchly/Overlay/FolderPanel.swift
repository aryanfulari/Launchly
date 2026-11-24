import SwiftUI

private struct MemberFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct FolderPanel: View {
    let folder: AppFolder
    let members: [AppItem]
    let screenSize: CGSize
    @ObservedObject var viewModel: LauncherViewModel
    @ObservedObject var appCatalog: AppCatalog

    @AppStorage(LaunchlySettings.Keys.gridColumns) private var gridColumns: Int = LaunchlySettings.Defaults.gridColumns
    @AppStorage(LaunchlySettings.Keys.iconSize) private var iconSize: Double = LaunchlySettings.Defaults.iconSize

    @State private var draftTitle: String = ""
    @FocusState private var isTitleFocused: Bool
    @State private var memberFrames: [String: CGRect] = [:]
    @State private var draggingMember: AppItem?
    @State private var memberDragLocation: CGPoint = .zero

    var body: some View {
        let panelWidth = min(screenSize.width * 0.70, 900)
        let panelHeight = screenSize.height * 0.60
        let panelCols = max(1, min(gridColumns, 6))
        let horizontalPad: CGFloat = 32
        let hSpacing: CGFloat = 16
        let vSpacing: CGFloat = 18
        let usableWidth = max(160, panelWidth - horizontalPad * 2)
        let cellWidth = max(68, (usableWidth - hSpacing * CGFloat(panelCols - 1)) / CGFloat(panelCols))
        let renderedIconSize = max(40, min(CGFloat(iconSize), cellWidth - 16))
        let cellHeight = renderedIconSize + 36

        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture {
                    commitTitle()
                    withAnimation(.easeOut(duration: 0.2)) {
                        viewModel.closeFolder()
                    }
                }

            LaunchlyGlassContainer {
                VStack(spacing: 16) {
                    TextField("Folder Name", text: $draftTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .focused($isTitleFocused)
                        .onSubmit {
                            commitTitle()
                            isTitleFocused = false
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 6)
                        .background {
                            if isTitleFocused {
                                Color.clear
                                    .launchlyGlass(.clear, interactive: true, in: Capsule(style: .continuous))
                            }
                        }
                        .padding(.top, 20)
                        .padding(.horizontal, 32)

                ScrollView {
                    let columnsLayout = Array(
                        repeating: GridItem(.fixed(cellWidth), spacing: hSpacing, alignment: .center),
                        count: panelCols
                    )

                    LazyVGrid(columns: columnsLayout, alignment: .leading, spacing: vSpacing) {
                        ForEach(members, id: \.id) { member in
                            AppIconCell(
                                item: member,
                                iconSize: renderedIconSize,
                                cellWidth: cellWidth,
                                cellHeight: cellHeight,
                                isSelected: false,
                                appCatalog: appCatalog,
                                existingFolders: viewModel.existingFolders.filter { $0.id != folder.id },
                                onOpen: { viewModel.launchApp(member) },
                                onShowInFinder: { viewModel.showInFinder(member) },
                                onHide: { viewModel.hideApp(member) },
                                onAddToExistingFolder: { targetID in
                                    viewModel.add(member, toFolder: targetID)
                                },
                                onRemoveFromFolder: {
                                    viewModel.layoutStore.remove(appID: member.id, fromFolder: folder.id)
                                    if members.count <= 2 {
                                        viewModel.closeFolder()
                                    }
                                }
                            )
                            .opacity(draggingMember?.id == member.id ? 0 : 1)
                            .background(
                                GeometryReader { cellGeo in
                                    Color.clear.preference(
                                        key: MemberFramePreferenceKey.self,
                                        value: [member.id: cellGeo.frame(in: .named("folderPanel"))]
                                    )
                                }
                            )
                            .gesture(
                                DragGesture(minimumDistance: 6, coordinateSpace: .named("folderPanel"))
                                    .onChanged { value in
                                        if draggingMember == nil {
                                            draggingMember = member
                                        }
                                        memberDragLocation = value.location

                                        if let targetEntry = memberFrames.first(where: { $0.value.contains(value.location) }),
                                           targetEntry.key != member.id,
                                           let targetIndex = members.firstIndex(where: { $0.id == targetEntry.key }) {
                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                viewModel.layoutStore.moveInFolder(
                                                    appID: member.id,
                                                    folder: folder.id,
                                                    to: targetIndex
                                                )
                                            }
                                        }
                                    }
                                    .onEnded { value in
                                        let panelBounds = CGRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
                                        let droppedOutside = !panelBounds.contains(value.location)
                                        draggingMember = nil

                                        if droppedOutside {
                                            viewModel.layoutStore.remove(appID: member.id, fromFolder: folder.id)
                                            withAnimation(.easeOut(duration: 0.2)) {
                                                viewModel.closeFolder()
                                            }
                                        }
                                    }
                            )
                        }
                    }
                    .padding(.horizontal, horizontalPad)
                    .padding(.vertical, 12)
                }
                .padding(.bottom, 20)
            }
            .frame(width: panelWidth, height: panelHeight)
            .launchlyGlass(.regular, in: RoundedRectangle(cornerRadius: 36, style: .continuous))
            }
            .overlay(alignment: .topLeading) {
                if let draggingMember {
                    AppIconCell(
                        item: draggingMember,
                        iconSize: renderedIconSize,
                        cellWidth: cellWidth,
                        cellHeight: cellHeight,
                        isSelected: false,
                        appCatalog: appCatalog,
                        onOpen: {},
                        onShowInFinder: {},
                        onHide: {}
                    )
                    .scaleEffect(1.12)
                    .shadow(color: Color.black.opacity(0.45), radius: 14, x: 0, y: 8)
                    .position(memberDragLocation)
                    .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: "folderPanel")
            .onPreferenceChange(MemberFramePreferenceKey.self) { frames in
                memberFrames = frames
            }
        }
        .onAppear {
            draftTitle = folder.name
        }
        .onChange(of: folder.name) { _, newName in
            draftTitle = newName
        }
        .onChange(of: viewModel.folderTitleFocusTrigger) { _, _ in
            isTitleFocused = true
        }
        .onChange(of: isTitleFocused) { _, focused in
            if !focused {
                commitTitle()
            }
        }
        .onDisappear {
            commitTitle()
        }
    }

    private func commitTitle() {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != folder.name {
            viewModel.layoutStore.rename(folder: folder.id, to: trimmed)
        }
    }
}
