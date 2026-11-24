import AppKit
import SwiftUI

enum LaunchlyGlassVariant {
    case regular
    case clear
}

extension View {
    @ViewBuilder
    func launchlyGlass<S: Shape>(
        _ variant: LaunchlyGlassVariant = .regular,
        interactive: Bool = false,
        tint: Color? = nil,
        in shape: S
    ) -> some View {
        if #available(macOS 26.0, *) {
            let base: Glass = (variant == .clear) ? .clear : .regular
            let tinted: Glass = tint.map { base.tint($0) } ?? base
            let styled: Glass = interactive ? tinted.interactive() : tinted
            self.glassEffect(styled, in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.24), lineWidth: 1))
        }
    }

    @ViewBuilder
    func launchlyGlassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            if prominent {
                self.buttonStyle(.borderedProminent)
            } else {
                self.buttonStyle(.bordered)
            }
        }
    }
}

/// Batches sibling Apple Liquid Glass surfaces into a single GPU pass on macOS 26+.
struct LaunchlyGlassContainer<Content: View>: View {
    var spacing: CGFloat? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }
}

/// Hardware-composited behind-window frosted blur managed by WindowServer (near-zero app GPU cost).
/// Hidden automatically at 0% (fully transparent) or 100% (covered by opaque wallpaper).
struct BehindWindowGlassBackdrop: NSViewRepresentable {
    var opacity: Double

    func makeNSView(context: Context) -> NSVisualEffectView {
        let visual = NSVisualEffectView(frame: .zero)
        visual.material = .popover
        visual.blendingMode = .behindWindow
        visual.state = .active
        visual.appearance = NSAppearance(named: .vibrantLight)
        applyOpacity(opacity, to: visual)
        return visual
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        applyOpacity(opacity, to: nsView)
    }

    private func applyOpacity(_ opacity: Double, to view: NSVisualEffectView) {
        let clamped = min(max(0.0, opacity), 1.0)
        if clamped <= 0.005 || clamped >= 0.995 {
            view.isHidden = true
            view.alphaValue = 0.0
        } else {
            view.isHidden = false
            view.alphaValue = CGFloat(min(0.85, clamped * 1.25))
        }
    }
}
