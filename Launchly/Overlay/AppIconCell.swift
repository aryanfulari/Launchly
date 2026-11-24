import AppKit
import SwiftUI

struct AppIconCell: View {
    let item: AppItem
    let iconSize: CGFloat
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let isSelected: Bool
    var isFolderTarget: Bool = false
    var hoverEnabled: Bool = true
    let appCatalog: AppCatalog
    var existingFolders: [AppFolder] = []
    var pageCount: Int = 1
    var currentPage: Int = 0
    let onOpen: () -> Void
    let onShowInFinder: () -> Void
    let onHide: () -> Void
    var onAddToNewFolder: (() -> Void)? = nil
    var onAddToExistingFolder: ((UUID) -> Void)? = nil
    var onRemoveFromFolder: (() -> Void)? = nil
    var onMoveToPage: ((Int) -> Void)? = nil

    @State private var icon: NSImage?
    @State private var isHovered = false

    var body: some View {
        let showHover = hoverEnabled && isHovered
        let hitWidth = min(max(iconSize + 12, min(cellWidth - 12, iconSize + 36)), cellWidth)

        // Outer cell frame does NOT absorb clicks so empty space between icons dismisses back to the previous app.
        VStack(spacing: 6) {
            ZStack {
                if isFolderTarget {
                    Color.clear
                        .frame(width: iconSize * 1.18, height: iconSize * 1.18)
                        .launchlyGlass(
                            .clear,
                            interactive: true,
                            tint: Color.white.opacity(0.18),
                            in: RoundedRectangle(cornerRadius: iconSize * 0.26, style: .continuous)
                        )
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                } else if isSelected {
                    Color.clear
                        .frame(width: iconSize + 12, height: iconSize + 12)
                        .launchlyGlass(
                            .clear,
                            tint: Color.white.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: iconSize * 0.24, style: .continuous)
                        )
                }

                Group {
                    if let displayIcon = icon ?? appCatalog.cachedIcon(for: item.path) {
                        Image(nsImage: displayIcon)
                            .resizable()
                            .interpolation(.medium)
                            .aspectRatio(contentMode: .fit)
                    } else {
                        RoundedRectangle(cornerRadius: iconSize * 0.22, style: .continuous)
                            .fill(Color.white.opacity(0.18))
                    }
                }
                .frame(width: iconSize * 1.08, height: iconSize * 1.08)
                .scaleEffect(iconScale(showHover: showHover))
            }
            .frame(width: iconSize, height: iconSize)
            .animation(.easeOut(duration: 0.12), value: showHover)
            .animation(.spring(response: 0.22, dampingFraction: 0.78), value: isFolderTarget)

            Text(item.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .shadow(color: Color.black.opacity(0.65), radius: 2, x: 0, y: 1)
                .frame(maxWidth: max(40, hitWidth - 4))
        }
        .frame(width: hitWidth)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hoverEnabled {
                isHovered = hovering
            } else if !hovering {
                isHovered = false
            }
        }
        .onChange(of: hoverEnabled) { _, enabled in
            if !enabled && isHovered {
                isHovered = false
            }
        }
        .onTapGesture {
            onOpen()
        }
        .contextMenu {
            Button("Open") {
                onOpen()
            }
            Button("Show in Finder") {
                onShowInFinder()
            }

            if onAddToNewFolder != nil || onAddToExistingFolder != nil || onRemoveFromFolder != nil {
                Divider()
            }

            if onAddToNewFolder != nil || onAddToExistingFolder != nil {
                Menu("Add to Folder") {
                    if let onAddToNewFolder {
                        Button("New Folder") {
                            onAddToNewFolder()
                        }
                    }
                    if !existingFolders.isEmpty, let onAddToExistingFolder {
                        Divider()
                        ForEach(existingFolders) { folder in
                            Button(folder.name) {
                                onAddToExistingFolder(folder.id)
                            }
                        }
                    }
                }
            }

            if let onRemoveFromFolder {
                Button("Remove from Folder") {
                    onRemoveFromFolder()
                }
            }

            if pageCount > 1, let onMoveToPage {
                Menu("Move to Page") {
                    ForEach(0..<pageCount, id: \.self) { pageIdx in
                        Button {
                            onMoveToPage(pageIdx)
                        } label: {
                            if pageIdx == currentPage {
                                Label("Page \(pageIdx + 1)", systemImage: "checkmark")
                            } else {
                                Text("Page \(pageIdx + 1)")
                            }
                        }
                        .disabled(pageIdx == currentPage)
                    }
                }
            }

            Divider()
            Button("Hide from Launchly") {
                onHide()
            }
        }
        .frame(width: cellWidth, height: cellHeight)
        .onAppear {
            loadIconIfNeeded()
        }
        .onChange(of: item.path) { _, _ in
            icon = nil
            loadIconIfNeeded()
        }
    }

    private func iconScale(showHover: Bool) -> CGFloat {
        if isFolderTarget { return 0.78 }
        if showHover { return 1.06 }
        return 1.0
    }

    private func loadIconIfNeeded() {
        if let cached = appCatalog.cachedIcon(for: item.path) {
            icon = cached
            return
        }
        let targetPath = item.path
        appCatalog.loadIconAsync(for: targetPath) { loaded in
            if item.path == targetPath {
                icon = loaded
            }
        }
    }
}
