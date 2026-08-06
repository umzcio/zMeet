import AppKit

/// Shared show/hide motion for zMeet's floating panels. Banner panels slide
/// down 8pt while fading in (like system notification banners); centered
/// panels fade in place. Honors Reduce Motion by dropping the movement.
@MainActor
enum PanelAnimator {
    static let easeOut = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)

    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Order the panel front at `finalOrigin`, animating in.
    /// `slide`: vertical offset for banner-style entrances (0 = fade only).
    static func present(_ panel: NSPanel, at finalOrigin: NSPoint, slide: CGFloat = 8, duration: TimeInterval = 0.22) {
        let offset: CGFloat = reduceMotion ? 0 : slide
        panel.setFrameOrigin(NSPoint(x: finalOrigin.x, y: finalOrigin.y + offset))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = easeOut
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(finalOrigin)
        }
    }

    /// Order the panel out with no motion — for replacing a still-visible panel
    /// with a new one (an animated fade under a new panel double-exposes).
    static func dismissImmediately(_ panel: NSPanel) {
        panel.orderOut(nil)
    }

    /// Fade the panel out (drifting up 6pt for banners), then order it out.
    /// Callers typically release their reference before dismissing; `completion`
    /// fires after order-out for anything that must wait.
    static func dismiss(_ panel: NSPanel, slide: CGFloat = 6, duration: TimeInterval = 0.16, completion: @escaping @MainActor () -> Void = {}) {
        let offset: CGFloat = reduceMotion ? 0 : slide
        let target = NSPoint(x: panel.frame.origin.x, y: panel.frame.origin.y + offset)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = easeOut
            panel.animator().alphaValue = 0
            panel.animator().setFrameOrigin(target)
        }, completionHandler: {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                completion()
            }
        })
    }
}
