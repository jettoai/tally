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

    func updateButton() {
        guard let button = statusItem?.button else { return }
        let segments = UsageStore.shared.menuBarSegments
        let blocked = SessionRosterStore.shared.blockedCount
        button.attributedTitle = blocked > 0 ? Self.blockedDot : NSAttributedString(string: "")
        // What the dot MEANS, for the hover and for VoiceOver: a coloured circle with no words is
        // exactly the kind of mark a person has to be told the meaning of once.
        let waiting = blocked > 0
            ? String(format: L("%d session is waiting on you"), blocked)
            : nil
        if segments.isEmpty {
            // No visible accounts - fall back to the app glyph.
            button.image = Self.symbolImage()
            button.toolTip = waiting
        } else {
            // The whole strip is rendered as one template image (brand marks + stacked numbers).
            // Hover / VoiceOver carry the full per-account identity the compact strip can't.
            let tooltip = [waiting, UsageStore.shared.menuBarTooltip]
                .compactMap { $0 }.joined(separator: "\n")
            button.image = MenuBarStripRenderer.stripImage(segments)
            button.image?.accessibilityDescription = tooltip
            button.toolTip = tooltip
            // README screenshot hook: demo mode + -TallyStripSnapshot <path> writes the strip
            // as a standalone PNG (idempotent - demo data never changes between refreshes).
            if DemoUsage.isActive,
               let path = UserDefaults.standard.string(forKey: "TallyStripSnapshot") {
                MenuBarStripRenderer.writeSnapshot(segments, to: path)
            }
        }
        // The dot rides AFTER the numbers, which is why the position moves with it: `.imageOnly`
        // is what suppresses a title, so the strip alone keeps it and the strip-plus-dot asks for
        // the image to lead instead.
        button.imagePosition = waiting == nil ? .imageOnly : .imageLeading
        // Surface resizing is handled by PopoverRootView.onContentSize (it reports the real content
        // size on every layout change), so nothing to do here.
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
