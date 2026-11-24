import SwiftUI

struct PageDots: View {
    let pageCount: Int
    let currentPage: Int
    let onSelectPage: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<max(1, pageCount), id: \.self) { index in
                Button {
                    onSelectPage(index)
                } label: {
                    Circle()
                        .fill(index == currentPage ? Color.white : Color.white.opacity(0.38))
                        .frame(width: 7, height: 7)
                        .shadow(color: Color.black.opacity(0.35), radius: 2, x: 0, y: 1)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Page \(index + 1) of \(max(1, pageCount))")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .launchlyGlass(.clear, interactive: true, in: Capsule(style: .continuous))
    }
}
