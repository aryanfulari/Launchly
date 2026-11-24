import AppKit
import Foundation
import QuartzCore
import SwiftUI
import os

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

final class OverlayWindowController: NSObject, NSWindowDelegate {
    private let appCatalog: AppCatalog
    private let viewModel: LauncherViewModel
    private var panel: KeyablePanel?
    private var scrollMonitor: Any?
    private var keyMonitor: Any?
    private var appDeactivateObserver: NSObjectProtocol?
    private var previousApp: NSRunningApplication?

    private var isAnimatingOut = false
    private var presentationToken = UUID()
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.aryanfulari.Launchly",
        category: "Overlay"
    )

    // Scroll gesture tracking
    private enum SwipeAxis {
        case undecided
        case horizontal
        case vertical
    }
    private var scrollAccumX: CGFloat = 0
    private var scrollAccumY: CGFloat = 0
    private var scrollBaseOffset: CGFloat = 0
    private var lockedSwipeAxis: SwipeAxis = .undecided
    private var lastScrollTime: TimeInterval = 0
    private var lastScrollVelocity: CGFloat = 0
    private var lastDiscretePageTime: TimeInterval = 0
    private let discreteScrollThreshold: CGFloat = 40

    var onOpenSettings: (() -> Void)? {
        didSet {
            viewModel.onOpenSettings = onOpenSettings
        }
    }

    var isVisible: Bool {
        (panel?.isVisible ?? false) && !isAnimatingOut
    }

    init(
        appCatalog: AppCatalog,
        layoutStore: LayoutStore,
        metadataStore: AppMetadataStore,
        spotlightIndex: SpotlightAppIndex
    ) {
        self.appCatalog = appCatalog
        self.viewModel = LauncherViewModel(
            appCatalog: appCatalog,
            layoutStore: layoutStore,
            metadataStore: metadataStore,
            spotlightIndex: spotlightIndex
        )
        super.init()

        self.viewModel.onDismiss = { [weak self] restoreFocus in
            self?.hide(restoreFocus: restoreFocus)
        }

        // Preload and pre-blur wallpaper off-thread at launch so first open is instant.
        self.viewModel.updateWallpaper(for: NSScreen.main ?? NSScreen.screens.first)

        appDeactivateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, self.isVisible else { return }
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.bundleIdentifier == Bundle.main.bundleIdentifier {
                self.hide(restoreFocus: false)
            }
        }
    }

    deinit {
        removeEventMonitors()
        if let appDeactivateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appDeactivateObserver)
        }
    }

    func toggle() {
        if isVisible {
            hide(restoreFocus: true)
        } else {
            show()
        }
    }

    func show() {
        if isVisible { return }

        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = frontmost
        } else {
            previousApp = nil
        }

        isAnimatingOut = false
        presentationToken = UUID()
        appCatalog.refresh()
        viewModel.resetForPresentation()

        let screen = screenUnderMouse() ?? NSScreen.main ?? NSScreen.screens.first
        let targetFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        if let screen {
            viewModel.topSafeInset = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
            viewModel.bottomSafeInset = max(0, screen.visibleFrame.minY - screen.frame.minY)
            viewModel.updateWallpaper(for: screen)
        }

        let panel = ensurePanel(frame: targetFrame)
        panel.setFrame(targetFrame, display: true)
        panel.alphaValue = 1.0

        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        logger.info("Showing overlay on screen \(NSStringFromRect(targetFrame), privacy: .public)")

        installEventMonitors()

        // Pure GPU CoreAnimation open transition (0 SwiftUI layout/diff ticks)
        if let layer = panel.contentView?.layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.removeAllAnimations()
            layer.opacity = 1.0
            layer.transform = CATransform3DIdentity
            CATransaction.commit()

            let fromScale = centeredScaleTransform(1.04, in: layer.bounds)

            let scaleAnim = CASpringAnimation(keyPath: "transform")
            scaleAnim.mass = 1.0
            scaleAnim.stiffness = 380
            scaleAnim.damping = 34
            scaleAnim.fromValue = NSValue(caTransform3D: fromScale)
            scaleAnim.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            scaleAnim.duration = scaleAnim.settlingDuration

            let fadeAnim = CABasicAnimation(keyPath: "opacity")
            fadeAnim.fromValue = 0.0
            fadeAnim.toValue = 1.0
            fadeAnim.duration = 0.16
            fadeAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)

            layer.add(scaleAnim, forKey: "openScale")
            layer.add(fadeAnim, forKey: "openFade")
        }

        DispatchQueue.main.async { [weak self] in
            self?.viewModel.focusTrigger = UUID()
        }
    }

    func hide(restoreFocus: Bool = true) {
        guard let panel, panel.isVisible, !isAnimatingOut else { return }

        logger.info("Hiding overlay (restoreFocus=\(restoreFocus))")
        isAnimatingOut = true
        let token = presentationToken
        let appToRestore = restoreFocus ? previousApp : nil
        previousApp = nil
        removeEventMonitors()

        let finishHide: () -> Void = { [weak self] in
            guard let self, self.presentationToken == token else { return }
            panel.orderOut(nil)
            if let layer = panel.contentView?.layer {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.removeAllAnimations()
                layer.opacity = 1.0
                layer.transform = CATransform3DIdentity
                CATransaction.commit()
            }
            self.isAnimatingOut = false

            if restoreFocus {
                if let appToRestore, !appToRestore.isTerminated {
                    appToRestore.activate()
                } else if !NSApp.windows.contains(where: { $0 !== panel && $0.isVisible }) {
                    NSApp.hide(nil)
                }
            }
        }

        if let layer = panel.contentView?.layer {
            let toScale = centeredScaleTransform(1.03, in: layer.bounds)

            CATransaction.begin()
            CATransaction.setCompletionBlock {
                DispatchQueue.main.async(execute: finishHide)
            }

            let group = CAAnimationGroup()
            group.duration = 0.14
            group.timingFunction = CAMediaTimingFunction(name: .easeIn)
            group.isRemovedOnCompletion = false
            group.fillMode = .forwards

            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = layer.presentation()?.opacity ?? 1.0
            fade.toValue = 0.0

            let scale = CABasicAnimation(keyPath: "transform")
            scale.fromValue = NSValue(caTransform3D: layer.presentation()?.transform ?? CATransform3DIdentity)
            scale.toValue = NSValue(caTransform3D: toScale)

            group.animations = [fade, scale]
            layer.add(group, forKey: "closeGroup")
            CATransaction.commit()
        } else {
            finishHide()
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        guard isVisible else { return }
        logger.info("Overlay panel resigned key")
        hide(restoreFocus: false)
    }

    // MARK: - Private Setup

    private func centeredScaleTransform(_ scale: CGFloat, in bounds: CGRect) -> CATransform3D {
        let cx = bounds.midX
        let cy = bounds.midY
        var t = CATransform3DIdentity
        t = CATransform3DTranslate(t, cx, cy, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        t = CATransform3DTranslate(t, -cx, -cy, 0)
        return t
    }

    private func ensurePanel(frame: NSRect) -> KeyablePanel {
        if let existing = panel {
            return existing
        }

        let created = KeyablePanel(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let belowDockLevel = Int(CGWindowLevelForKey(.dockWindow)) - 1
        created.level = NSWindow.Level(rawValue: belowDockLevel)
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        created.backgroundColor = .clear
        created.isOpaque = false
        created.hasShadow = false
        created.hidesOnDeactivate = false
        created.becomesKeyOnlyIfNeeded = false
        created.isMovable = false
        created.delegate = self

        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.autoresizingMask = [.width, .height]

        let launcherView = LauncherView(viewModel: viewModel, appCatalog: appCatalog)
        let hosting = NSHostingView(rootView: launcherView)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]

        container.addSubview(hosting)
        created.contentView = container

        self.panel = created
        return created
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
    }

    // MARK: - Event Monitors

    private func installEventMonitors() {
        removeEventMonitors()
        resetScrollState()

        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.isVisible, event.window === self.panel else {
                return event
            }
            if self.viewModel.openFolderID != nil {
                return event
            }
            self.handleScrollWheel(event)
            return nil
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible, event.window === self.panel else {
                return event
            }
            if self.handleKeyDown(event) {
                return nil
            }
            return event
        }
    }

    private func removeEventMonitors() {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        resetScrollState()
    }

    private func resetScrollState() {
        scrollAccumX = 0
        scrollAccumY = 0
        scrollBaseOffset = 0
        lockedSwipeAxis = .undecided
        lastScrollTime = 0
        lastScrollVelocity = 0
    }

    private func handleScrollWheel(_ event: NSEvent) {
        if !event.momentumPhase.isEmpty {
            return
        }

        if !event.phase.isEmpty {
            let now = event.timestamp

            switch event.phase {
            case .began:
                resetScrollState()
                lastScrollTime = now
                viewModel.isSwiping = true
                scrollBaseOffset = viewModel.pagerAnimator.beginInteractiveScroll(
                    page: viewModel.currentPage,
                    pageWidth: viewModel.pageWidth
                )

            case .changed:
                let dx = event.scrollingDeltaX
                let dy = event.scrollingDeltaY
                scrollAccumX += dx
                scrollAccumY += dy

                if lockedSwipeAxis == .undecided && (abs(scrollAccumX) > 4 || abs(scrollAccumY) > 4) {
                    lockedSwipeAxis = abs(scrollAccumY) > abs(scrollAccumX) * 1.6 ? .vertical : .horizontal
                }

                let stepDelta = (lockedSwipeAxis == .vertical) ? dy : dx
                let totalDelta = scrollBaseOffset + ((lockedSwipeAxis == .vertical) ? scrollAccumY : scrollAccumX)

                let dt = now - lastScrollTime
                if dt > 0.001 && dt < 0.25 {
                    let instantVelocity = stepDelta / CGFloat(dt)
                    lastScrollVelocity = lastScrollVelocity * 0.4 + instantVelocity * 0.6
                }
                lastScrollTime = now

                // Direct CoreAnimation layer bounds write: 0 SwiftUI diffing, locked 120fps.
                viewModel.pagerAnimator.setInteractiveOffset(
                    rubberBandedOffset(totalDelta),
                    page: viewModel.currentPage,
                    pageWidth: viewModel.pageWidth
                )

            case .ended, .cancelled:
                let totalDelta = scrollBaseOffset + ((lockedSwipeAxis == .vertical) ? scrollAccumY : scrollAccumX)
                let distanceThreshold = max(48, viewModel.pageWidth * 0.14)
                let velocityThreshold: CGFloat = 340

                let targetPage: Int
                if totalDelta < -distanceThreshold || (totalDelta < -14 && lastScrollVelocity < -velocityThreshold) {
                    targetPage = min(viewModel.currentPage + 1, viewModel.pageCount - 1)
                } else if totalDelta > distanceThreshold || (totalDelta > 14 && lastScrollVelocity > velocityThreshold) {
                    targetPage = max(viewModel.currentPage - 1, 0)
                } else {
                    targetPage = viewModel.currentPage
                }

                viewModel.isSwiping = false
                viewModel.goToPage(targetPage, animated: true, velocity: lastScrollVelocity)
                resetScrollState()

            default:
                break
            }
            return
        }

        // Discrete mouse scroll wheel
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastDiscretePageTime >= 0.38 else { return }

        scrollAccumX += event.scrollingDeltaX
        scrollAccumY += event.scrollingDeltaY
        let dominantDelta = abs(scrollAccumY) > abs(scrollAccumX) ? scrollAccumY : scrollAccumX

        if abs(dominantDelta) >= discreteScrollThreshold {
            if dominantDelta < 0 {
                viewModel.nextPage(animated: true)
            } else {
                viewModel.previousPage(animated: true)
            }
            lastDiscretePageTime = now
            resetScrollState()
        }
    }

    private func rubberBandedOffset(_ rawDelta: CGFloat) -> CGFloat {
        let maxPage = max(0, viewModel.pageCount - 1)
        if (viewModel.currentPage == 0 && rawDelta > 0) ||
            (viewModel.currentPage >= maxPage && rawDelta < 0) {
            return rawDelta / 3.0
        }
        return rawDelta
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let disallowedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        guard event.modifierFlags.intersection(disallowedModifiers).isEmpty else {
            return false
        }

        if event.keyCode == 53 {
            if viewModel.openFolderID != nil {
                withAnimation(.easeOut(duration: 0.2)) {
                    viewModel.closeFolder()
                }
            } else if !viewModel.searchText.isEmpty {
                viewModel.searchText = ""
            } else {
                hide(restoreFocus: true)
            }
            return true
        }

        if viewModel.openFolderID != nil {
            return false
        }

        let isSearching = viewModel.isSearching

        switch event.keyCode {
        case 36, 76:
            guard isSearching else { return false }
            viewModel.launchSelectedOrFirst()
            return true

        case 123:
            if viewModel.draggingID != nil {
                viewModel.stepEdgePage(direction: -1)
            } else if isSearching {
                viewModel.moveSelection(deltaRow: 0, deltaCol: -1)
            } else {
                viewModel.previousPage(animated: true)
            }
            return true

        case 124:
            if viewModel.draggingID != nil {
                viewModel.stepEdgePage(direction: 1)
            } else if isSearching {
                viewModel.moveSelection(deltaRow: 0, deltaCol: 1)
            } else {
                viewModel.nextPage(animated: true)
            }
            return true

        case 125:
            if isSearching {
                viewModel.moveSelection(deltaRow: 1, deltaCol: 0)
                return true
            }
            return false

        case 126:
            if isSearching {
                viewModel.moveSelection(deltaRow: -1, deltaCol: 0)
                return true
            }
            return false

        default:
            return false
        }
    }
}
