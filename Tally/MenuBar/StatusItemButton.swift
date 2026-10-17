import AppKit

/// WHAT THE STATUS ITEM SHOWS: the rendered strip, the waiting dot, and the fallback glyph.
///
/// Split out of `StatusItemController` on 2026-08-15, unchanged: that file had grown past this
/// repo's 500-line limit while the summoning path inside it was being rewritten, and drawing the
/// button shares nothing with placing a surface but the object it hangs off.
extension StatusItemController {
    /// The glyph shown when there is no strip to draw, first of these the running system has.
    private static let symbolCandidates = ["gauge.medium", "gauge", "chart.bar.fill"]

    /// THE ONE MARK THAT IS NOT A NUMBER: a red dot beside the strip while any supervised session
    /// is waiting on the user.
    ///
    /// DRAWN AS THE BUTTON'S TITLE RATHER THAN INTO THE IMAGE, and that is the whole design. The
    /// strip is a TEMPLATE image, which is what lets AppKit tint it for a light or dark menu bar
    /// and invert it while the item is pressed; a template image has no colours of its own, so a
    /// red dot composited into it would come out the same grey as everything else, and turning the
    /// template off to keep the red would cost the tint and the press inversion for the whole
    /// strip. The title is a separate, coloured layer on the same button, so the numbers keep
    /// behaving exactly as they always have and the dot is really red.
    private static var blockedDot: NSAttributedString {
        NSAttributedString(string: "●", attributes: [
            .foregroundColor: NSColor.systemRed,
            .font: NSFont.systemFont(ofSize: 7),
            // Lifted to the top of the strip: beside 12pt digits a baseline-aligned dot reads as
            // punctuation, and up in the corner it reads as a badge.
            .baselineOffset: 5,
        ])
    }

    /// `-TallyDemoRingStates` (demo only): the four things a ring can be, left to right: plenty
    /// left, under 20% left (red), a stale last-known figure (faded), nothing readable (dashed).
    private static let demoRingStates = [
        MenuBarSegment(providerID: "claude", lines: ["74%"], dimmed: false, badge: nil, remaining: 74),
        MenuBarSegment(providerID: "claude", lines: ["12%"], dimmed: false, badge: nil, remaining: 12),
        MenuBarSegment(providerID: "codex", lines: ["48%"], dimmed: true, badge: nil, remaining: 48),
        MenuBarSegment(providerID: "codex", lines: ["!"], dimmed: false, badge: nil),
    ]

    /// `updateButton` on the next run-loop turn, with every request before it folded into one. The
    /// refresh job calls this from its tail: drawing the strip there (an `ImageRenderer` built and
    /// torn down) made one main-thread slice of the whole refresh plus the render, which is what
    /// Sentry TALLY-37 sampled. The strip is a turn late, and only ever the latest state.
    func updateButtonSoon() {
        guard !Self.buttonUpdateQueued else { return }
        Self.buttonUpdateQueued = true
        DispatchQueue.main.async { [weak self] in
            Self.buttonUpdateQueued = false
            self?.updateButton()
        }
    }

    private static var buttonUpdateQueued = false

    func updateButton() {
        guard let button = statusItem?.button else { return }
        let demo = DemoUsage.isActive
        let defaults = UserDefaults.standard
        // Demo capture only: one ring per state the strip can be in (the fixtures reach two of them).
        let segments = demo && defaults.bool(forKey: "TallyDemoRingStates")
            ? Self.demoRingStates : UsageStore.shared.menuBarSegments
        // Demo capture only: `-TallyDemoWaiting YES` makes sure one session is waiting, `NO` that none is
        // (the fixture roster has one by default), so both states of the dot can be photographed.
        let real = SessionRosterStore.shared.blockedCount
        let blocked: Int
        switch demo ? defaults.string(forKey: "TallyDemoWaiting")?.uppercased() : nil {
        case "YES"?, "1"?: blocked = max(1, real)
        case "NO"?, "0"?: blocked = 0
        default: blocked = real
        }
        // The waiting dot is drawn into the strip (one ink); the fallback glyph has no strip to
        // hold it, so it keeps the red title.
        let dotInStrip = !segments.isEmpty
        // What the dot MEANS, for the hover and for VoiceOver: a coloured circle with no words is
        // exactly the kind of mark a person has to be told the meaning of once.
        let waiting = blocked > 0
            ? String(format: L("%d session is waiting on you"), blocked)
            : nil
        // Hover / VoiceOver carry the full per-account identity the compact strip can't.
        // A private build's note (OverlayApp.statusItemNote) adds one hover line and a small mark;
        // nil, as in the public build, leaves both exactly as they were.
        let note = OverlayApp.statusItemNote
        var tooltip = segments.isEmpty
            ? waiting
            : [waiting, UsageStore.shared.menuBarTooltip].compactMap { $0 }.joined(separator: "\n")
        if let note { tooltip = [tooltip, note].compactMap { $0 }.joined(separator: "\n") }
        let face = StatusItemFace(segments: segments, blocked: blocked, tooltip: tooltip, note: note)
        guard face != lastAppliedFace else { return }
        lastAppliedFace = face
        let title = NSMutableAttributedString()
        if blocked > 0 && !dotInStrip { title.append(Self.blockedDot) }
        if let note { title.append(Self.noteMark(note)) }
        button.attributedTitle = title
        button.toolTip = tooltip
        if segments.isEmpty {
            // No visible accounts - fall back to the app glyph.
            button.image = Self.symbolImage()
        } else {
            // The whole strip is rendered as one image of rings (see MenuBarStripRenderer).
            button.image = MenuBarStripRenderer.stripImage(segments, waiting: blocked > 0)
            button.image?.accessibilityDescription = tooltip
            // README screenshot hook: demo mode + -TallyStripSnapshot <path> writes the strip
            // as a standalone PNG (idempotent - demo data never changes between refreshes).
            if DemoUsage.isActive,
               let path = UserDefaults.standard.string(forKey: "TallyStripSnapshot") {
                if let scheme = Self.capturedAppearance(button) {
                    Self.writeButtonSnapshot(button, to: path, dark: scheme == .darkAqua)
                } else {
                    MenuBarStripRenderer.writeSnapshot(segments, to: path, waiting: blocked > 0)
                }
            }
        }
        // `.imageOnly` is what suppresses a title, so a strip whose dot is inside the image keeps
        // it; only the fallback glyph's red title (or a private build's mark) asks the image to lead.
        button.imagePosition = (waiting == nil || dotInStrip) && note == nil ? .imageOnly : .imageLeading
        // Surface resizing is handled by PopoverRootView.onContentSize (it reports the real content
        // size on every layout change), so nothing to do here.
    }

    /// `-TallyMenuBarAppearance light|dark` (demo or Dev only): pins THIS status button to one scheme,
    /// so the item can be judged on a light bar without flipping the system setting, and returns the
    /// scheme it pinned. The system menu bar cannot be photographed while the screen is locked and
    /// is not this app's to repaint, so with `-TallyStripSnapshot` the button itself is captured.
    private static func capturedAppearance(_ button: NSStatusBarButton) -> NSAppearance.Name? {
        guard DemoUsage.isActive || BuildVariant.isDev,
              let raw = UserDefaults.standard.string(forKey: "TallyMenuBarAppearance")?.lowercased(),
              raw == "light" || raw == "dark" else { return nil }
        let name: NSAppearance.Name = raw == "light" ? .aqua : .darkAqua
        button.appearance = NSAppearance(named: name)
        return name
    }

    /// The real status button, drawn by AppKit under the pinned scheme over a bar-coloured base,
    /// written as a PNG once its frame has settled. Demo capture only.
    private static func writeButtonSnapshot(_ button: NSStatusBarButton, to path: String, dark: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let bounds = button.bounds
            guard bounds.width > 0, let rep = button.bitmapImageRepForCachingDisplay(in: bounds) else { return }
            button.cacheDisplay(in: bounds, to: rep)
            let base = dark ? NSColor(white: 0.11, alpha: 1) : NSColor(white: 0.93, alpha: 1)
            let image = NSImage(size: bounds.size)
            image.lockFocus()
            base.setFill()
            NSRect(origin: .zero, size: bounds.size).fill()
            rep.draw(in: NSRect(origin: .zero, size: bounds.size))
            image.unlockFocus()
            guard let tiff = image.tiffRepresentation, let out = NSBitmapImageRep(data: tiff) else { return }
            try? out.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    /// A private build's mark: a small template symbol, so it follows the menu bar's tint.
    private static func noteMark(_ note: String) -> NSAttributedString {
        let image = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: note)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        image?.isTemplate = true
        let attachment = NSTextAttachment()
        attachment.image = image
        return NSAttributedString(attachment: attachment)
    }

    private static func symbolImage() -> NSImage? {
        for name in symbolCandidates {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: "Tally") {
                image.isTemplate = true
                return image
            }
        }
        return nil
    }
}
