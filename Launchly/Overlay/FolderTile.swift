import AppKit
import SwiftUI

struct FolderTile: View {
    let folder: AppFolder
    let members: [AppItem]
    let iconSize: CGFloat
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    var isFolderTarget: Bool = false
    var hoverEnabled: Bool = true
    var pageCount: Int = 1
    var currentPage: Int = 0
    let appCatalog: AppCatalog
    let onOpen: () -> Void
    let onRename: () -> Void
    let onDissolve: () -> Void
    var onMoveToPage: ((Int) -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        let showHover = hoverEnabled && isHovered
        let hitWidth = min(max(iconSize + 12, min(cellWidth - 12, iconSize + 36)), cellWidth)

        VStack(spacing: 6) {
            let padding = max(6, iconSize * 0.09)
            let innerSpacing = max(3, iconSize * 0.05)
            let miniSize = max(14, (iconSize - padding * 2 - innerSpacing * 2) / 3)
            let columns = Array(repeating: GridItem(.fixed(miniSize), spacing: innerSpacing), count: 3)

            LazyVGrid(columns: columns, alignment: .leading, spacing: innerSpacing) {
                ForEach(Array(members.prefix(9))) { member in
                    MiniAppIcon(item: member, size: miniSize, appCatalog: appCatalog)
                }
            }
            .padding(padding)
            .frame(width: iconSize, height: iconSize, alignment: .topLeading)
            .launchlyGlass(
                .clear,
                interactive: true,
                tint: isFolderTarget ? Color.white.opacity(0.22) : Color.white.opacity(0.06),
                in: RoundedRectangle(cornerRadius: iconSize * 0.24, style: .continuous)
            )
            .scaleEffect(isFolderTarget ? 1.15 : (showHover ? 1.06 : 1.0))
            .animation(.easeOut(duration: 0.12), value: showHover)
            .animation(.spring(response: 0.22, dampingFraction: 0.78), value: isFolderTarget)

            Text(folder.name)
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
            Button("Rename…") {
                onRename()
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
            Button("Ungroup") {
                onDissolve()
            }
        }
        .frame(width: cellWidth, height: cellHeight)
    }
}

private struct MiniAppIcon: View {
    let item: AppItem
    let size: CGFloat
    let appCatalog: AppCatalog

    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let displayIcon = icon ?? appCatalog.cachedIcon(for: item.path) {
                Image(nsImage: displayIcon)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(Color.white.opacity(0.20))
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            if let cached = appCatalog.cachedIcon(for: item.path) {
                icon = cached
            } else {
                let targetPath = item.path
                appCatalog.loadIconAsync(for: targetPath) { loaded in
                    if item.path == targetPath {
                        icon = loaded
                    }
                }
            }
        }
    }
}
