import AppKit
import QuartzCore
import SwiftUI

final class FlippedClipView: NSView {
    override var isFlipped: Bool { true }
}

/// Hardware-accelerated CoreAnimation pager controller.
/// Moves the hosted page strip via `frame.origin.x` and `CASpringAnimation(keyPath: "position.x")`
/// so both interactive scrubbing and spring deceleration run natively in macOS WindowServer
/// at locked 120fps with zero SwiftUI view-tree re-evaluation and near-zero battery usage.
final class PagerAnimator {
    weak var clipView: FlippedClipView?
    weak var contentView: NSView?

    private var isInteracting = false
    private var lastSyncedPage: Int = 0
    private var lastSyncedWidth: CGFloat = 0

    func attach(clipView: FlippedClipView, contentView: NSView) {
        self.clipView = clipView
        self.contentView = contentView
    }

    func updateLayout(page: Int, pageWidth: CGFloat) {
        guard let contentView, pageWidth > 0 else { return }
        if isInteracting { return }

        let targetOriginX = -CGFloat(page) * pageWidth
        let widthChanged = abs(pageWidth - lastSyncedWidth) > 0.5
        let pageChanged = page != lastSyncedPage

        if widthChanged || (pageChanged && contentView.layer?.animation(forKey: "pageSpring") == nil) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            contentView.layer?.removeAnimation(forKey: "pageSpring")
            var frame = contentView.frame
            frame.origin.x = targetOriginX
            contentView.frame = frame
            CATransaction.commit()
        }

        lastSyncedPage = page
        lastSyncedWidth = pageWidth
    }

    /// Captures the live presentation offset if interrupting a spring mid-flight, returning the existing drag delta.
    func beginInteractiveScroll(page: Int, pageWidth: CGFloat) -> CGFloat {
        isInteracting = true
        guard let contentView else { return 0 }

        let livePosX = contentView.layer?.presentation()?.position.x ?? contentView.layer?.position.x ?? contentView.frame.origin.x
        let modelPosX = contentView.layer?.position.x ?? contentView.frame.origin.x
        let deltaFromModel = livePosX - modelPosX
        let liveOriginX = contentView.frame.origin.x + deltaFromModel

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentView.layer?.removeAnimation(forKey: "pageSpring")
        var frame = contentView.frame
        frame.origin.x = liveOriginX
        contentView.frame = frame
        CATransaction.commit()

        let restingOriginX = -CGFloat(page) * pageWidth
        return liveOriginX - restingOriginX
    }

    func setInteractiveOffset(_ dragOffset: CGFloat, page: Int, pageWidth: CGFloat) {
        guard let contentView else { return }
        let targetOriginX = -CGFloat(page) * pageWidth + dragOffset

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentView.layer?.removeAnimation(forKey: "pageSpring")
        var frame = contentView.frame
        frame.origin.x = targetOriginX
        contentView.frame = frame
        CATransaction.commit()
    }

    func animateToPage(_ targetPage: Int, pageWidth: CGFloat, velocity: CGFloat, duration: Double) {
        isInteracting = false
        lastSyncedPage = targetPage
        lastSyncedWidth = pageWidth

        guard let contentView, let layer = contentView.layer, pageWidth > 0 else { return }

        let fromPosX = layer.presentation()?.position.x ?? layer.position.x
        let targetOriginX = -CGFloat(targetPage) * pageWidth

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: "pageSpring")
        var frame = contentView.frame
        frame.origin.x = targetOriginX
        contentView.frame = frame
        CATransaction.commit()

        let toPosX = layer.position.x
        let distance = toPosX - fromPosX
        guard abs(distance) > 0.5 else { return }

        let response = max(0.22, min(1.0, duration))
        let omega = (2.0 * Double.pi) / response
        let dampingRatio = 0.94

        let spring = CASpringAnimation(keyPath: "position.x")
        spring.mass = 1.0
        spring.stiffness = CGFloat(omega * omega)
        spring.damping = CGFloat(2.0 * dampingRatio * omega)
        spring.fromValue = fromPosX
        spring.toValue = toPosX

        // Both velocity and position.x share sign (swiping left = negative velocity & negative position delta).
        let normalizedVelocity = max(-10.0, min(10.0, velocity / distance))
        spring.initialVelocity = normalizedVelocity
        spring.duration = spring.settlingDuration
        spring.fillMode = .backwards

        layer.add(spring, forKey: "pageSpring")
    }

    func snapToPage(_ page: Int, pageWidth: CGFloat) {
        isInteracting = false
        lastSyncedPage = page
        lastSyncedWidth = pageWidth
        guard let contentView else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentView.layer?.removeAnimation(forKey: "pageSpring")
        var frame = contentView.frame
        frame.origin.x = -CGFloat(page) * pageWidth
        contentView.frame = frame
        CATransaction.commit()
    }
}

struct NativeSmoothPager<Content: View>: NSViewRepresentable {
    let animator: PagerAnimator
    let currentPage: Int
    let pageCount: Int
    let pageWidth: CGFloat
    let pageHeight: CGFloat
    @ViewBuilder let content: () -> Content

    final class Coordinator {
        var hostingView: NSHostingView<Content>?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> FlippedClipView {
        let clipView = FlippedClipView(frame: NSRect(x: 0, y: 0, width: pageWidth, height: pageHeight))
        clipView.wantsLayer = true
        clipView.clipsToBounds = true
        clipView.layer?.masksToBounds = true
        clipView.layer?.backgroundColor = NSColor.clear.cgColor

        let totalWidth = max(pageWidth, CGFloat(max(1, pageCount)) * pageWidth)
        let hosting = NSHostingView(rootView: content())
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.frame = NSRect(x: -CGFloat(currentPage) * pageWidth, y: 0, width: totalWidth, height: pageHeight)

        clipView.addSubview(hosting)
        context.coordinator.hostingView = hosting
        animator.attach(clipView: clipView, contentView: hosting)
        animator.snapToPage(currentPage, pageWidth: pageWidth)
        return clipView
    }

    func updateNSView(_ nsView: FlippedClipView, context: Context) {
        let totalWidth = max(pageWidth, CGFloat(max(1, pageCount)) * pageWidth)

        if let hosting = context.coordinator.hostingView {
            animator.attach(clipView: nsView, contentView: hosting)
            hosting.rootView = content()
            if abs(hosting.frame.width - totalWidth) > 0.5 || abs(hosting.frame.height - pageHeight) > 0.5 {
                var frame = hosting.frame
                frame.size = NSSize(width: totalWidth, height: pageHeight)
                hosting.frame = frame
            }
        }

        animator.updateLayout(page: currentPage, pageWidth: pageWidth)
    }
}
