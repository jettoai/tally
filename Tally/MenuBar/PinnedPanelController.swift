import AppKit
import SwiftUI

/// A borderless, non-activating floating panel — the pinned form of the usage view. It hosts the same
/// `PopoverRootView` as the transient popover; only one is on screen at a time.
final class PinnedUsagePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // TEMP diagnostics: log every frame-origin change with its call stack, to catch what teleports
    // the panel to the screen's top-left during a card drag. Remove once the mover is identified.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        if frameRect.origin != frame.origin {
            NSLog("TALLY-PANEL setFrame origin (%.0f,%.0f)->(%.0f,%.0f) size (%.0f,%.0f)\n%@",
                  frame.origin.x, frame.origin.y, frameRect.origin.x, frameRect.origin.y,
                  frameRect.width, frameRect.height,
                  Thread.callStackSymbols.prefix(12).joined(separator: "\n"))
        }
        super.setFrame(frameRect, display: flag)
    }

    override func setFrameOrigin(_ point: NSPoint) {
        if point != frame.origin {
            NSLog("TALLY-PANEL setFrameOrigin (%.0f,%.0f)->(%.0f,%.0f)\n%@",
                  frame.origin.x, frame.origin.y, point.x, point.y,
                  Thread.callStackSymbols.prefix(12).joined(separator: "\n"))
        }
        super.setFrameOrigin(point)
    }

    override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) {
        if frameRect.origin != frame.origin {
            NSLog("TALLY-PANEL setFrame(animate:%d) origin (%.0f,%.0f)->(%.0f,%.0f)\n%@",
                  animateFlag ? 1 : 0,
                  frame.origin.x, frame.origin.y, frameRect.origin.x, frameRect.origin.y,
                  Thread.callStackSymbols.prefix(12).joined(separator: "\n"))
        }
        super.setFrame(frameRect, display: displayFlag, animate: animateFlag)
    }
}

/// The pinned panel's window-move handle: an AppKit view that hands its mouse-down to
/// `NSWindow.performDrag`, giving the header strip (and nothing else) window-moving duty. This is the
/// counterpart to `isMovableByWindowBackground = false` — an explicit drag region can never collide
/// with the cards' reorder gesture. Inert inside the transient popover (that window must stay anchored).
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            if window is PinnedUsagePanel {
                window?.performDrag(with: event)
            } else {
                super.mouseDown(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

/// The pinned panel's base surface. Glass mode shows the desktop through behind-window vibrancy —
/// SwiftUI's `Material` only samples in-app content, so this must be an `NSVisualEffectView` with
/// `.behindWindow`, and it carries its own rounded mask because the window server composites the blur
/// without honoring the SwiftUI clip shape. Accessibility's Reduce Transparency is a need, not a
/// preference: it clamps the surface to solid regardless of the user's glass setting.
private struct PanelBackdrop: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        if settings.isPanelTranslucent,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            GlassBackdrop()
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        }
    }
}

private struct GlassBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = Self.roundedMask(cornerRadius: 12)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}

    /// A stretchable rounded-corner mask (9-slice) so the blur region itself gets rounded corners.
    private static func roundedMask(cornerRadius: CGFloat) -> NSImage {
        let edge = cornerRadius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius,
                                       bottom: cornerRadius, right: cornerRadius)
        image.resizingMode = .stretch
        return image
    }
}

/// Owns the pinned floating panel. Separate from the popover so the transient popover keeps working
/// untouched; pinning just hands its content off to this always-on-top window.
@MainActor
final class PinnedPanelController {
    static let shared = PinnedPanelController()

    private var panel: PinnedUsagePanel?
    private var host: NSHostingController<AnyView>?

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Show the panel. When `topLeft` is given (the pin hand-off from the popover), open there;
    /// otherwise reuse the autosaved frame (launch restore / re-show). The size is driven by the
    /// content's measured size via `PopoverRootView.onContentSize` → `resize(to:)`.
    func show(atTopLeft topLeft: CGPoint?) {
        let panel = panel ?? makePanel()
        self.panel = panel
        if let topLeft { panel.setFrameTopLeftPoint(topLeft) }
        clampOnScreen(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    func bringToFront() { panel?.makeKeyAndOrderFront(nil) }

    func hide() { panel?.orderOut(nil) }

    /// Resize the panel to the content's MEASURED size (reported by `PopoverRootView.onContentSize`).
    /// Measuring the real rendered size avoids `sizeThatFits`'s greedy screen-tall result. Deferred a
    /// run-loop turn so it never resizes the window from inside the SwiftUI update that reported it, and
    /// keyed on `sizingOptions = []` so this manual sizing is the only authority (two authorities were
    /// the original stack-overflow crash).
    private func resize(to contentSize: CGSize) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel else { return }
            guard contentSize.width.isFinite, contentSize.height.isFinite,
                  contentSize.width > 1, contentSize.height > 1 else { return }
            let maxHeight = ((panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 1200) - 40
            let size = CGSize(width: min(contentSize.width, 900), height: min(contentSize.height, maxHeight))
            guard size != panel.frame.size else { return }
            var frame = panel.frame
            let top = frame.maxY
            frame.size = size
            frame.origin.y = top - size.height   // keep the top-left fixed so a dragged position doesn't drift
            panel.setFrame(frame, display: false)
        }
    }

    private func makePanel() -> PinnedUsagePanel {
        let panel = PinnedUsagePanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = .floating                                    // above normal app windows, below system UI
        panel.hidesOnDeactivate = false                            // stay put when Tally isn't frontmost
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]  // visible across Spaces + over full-screen apps
        panel.isMovable = true
        // NOT movable-by-background: SwiftUI drag gestures don't opt a region out of AppKit's
        // background window drag, so dragging a card to reorder also dragged the whole panel.
        // Moving the panel is the header strip's job instead (`WindowDragArea`).
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear

        // Borderless panels have no chrome, so the content supplies its own rounded surface (the popover
        // got this from NSPopover). Same PopoverRootView, same shared stores.
        let content = AnyView(
            PopoverRootView(store: .shared, settings: .shared,
                            onContentSize: { [weak self] size in self?.resize(to: size) })
                .background(PanelBackdrop(settings: .shared))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)))
        let host = NSHostingController(rootView: content)
        host.sizingOptions = []      // do NOT let SwiftUI install sizing constraints; we set the frame
        self.host = host
        panel.contentViewController = host
        panel.setContentSize(CGSize(width: 500, height: 400))   // placeholder until onContentSize reports the real size
        panel.setFrameAutosaveName("TallyPinnedUsagePanel")
        return panel
    }

    /// Keep the panel on a visible screen (e.g. after an external display is unplugged).
    private func clampOnScreen(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { $0.frame.intersects(panel.frame) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        var frame = panel.frame
        if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width }
        if frame.minX < visible.minX { frame.origin.x = visible.minX }
        if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
        if frame.minY < visible.minY { frame.origin.y = visible.minY }
        if frame != panel.frame { panel.setFrame(frame, display: false) }
    }
}
