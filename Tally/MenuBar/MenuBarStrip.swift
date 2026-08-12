import AppKit
import SwiftUI

/// The menu-bar strip, drawn as a single SwiftUI view rendered to a template `NSImage`. Each segment
/// is `mark + stacked percents`; same-provider segments sit close, different providers spaced further,
/// so a glance reads how the fleet stands. Monochrome + `isTemplate` tints it. What each segment
/// stands for - one account or one provider's pool - is decided in `MenuBarSegments`.
private struct MenuBarStripView: View {
    let segments: [MenuBarSegment]
    /// Snapshot rendering overrides: the README shot drops the DEV tag and draws white-on-dark
    /// directly instead of the template mask AppKit tints.
    var devTag: Bool = BuildVariant.isDev
    var tint: Color = .black

    var body: some View {
        HStack(spacing: 0) {
            // The dev variant announces itself right in the strip (template image is monochrome,
            // so a text tag, not a colour) - two otherwise identical icons side by side must be
            // tellable at a glance.
            if devTag {
                Text("DEV")
                    .font(.system(size: 8, weight: .heavy))
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1.5)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(lineWidth: 1))
                Color.clear.frame(width: 7, height: 0)
            }
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                if index > 0 {
                    Color.clear.frame(width: gap(before: index), height: 0)
                }
                HStack(spacing: 4) {
                    icon(segment.providerID)
                        .overlay(alignment: .bottomTrailing) {
                            // Identical marks share one glyph - a tiny corner digit is the only
                            // identity the strip carries (which account, or how many accounts the
                            // pool sums); the full story lives in the tooltip.
                            if let badge = segment.badge {
                                Text("\(badge)")
                                    .font(.system(size: 7, weight: .heavy))
                                    .offset(x: 3.5, y: 1.5)
                            }
                        }
                    numbers(segment.lines)
                }
                .opacity(segment.dimmed ? 0.5 : 1)
            }
        }
        .monospacedDigit()
        .foregroundStyle(tint)   // template mask (black) - actual tint applied by AppKit
        .padding(.horizontal, 2)
        .padding(.vertical, 1)
        .fixedSize()
    }

    /// One bold number when there's a single window, otherwise the windows stacked tight.
    @ViewBuilder
    private func numbers(_ lines: [String]) -> some View {
        if lines.count <= 1 {
            Text(lines.first ?? "—").font(.system(size: 12, weight: .bold))
        } else {
            VStack(alignment: .trailing, spacing: -2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 9, weight: .semibold))
                }
            }
        }
    }

    /// Tight gap between accounts of the same provider, wider between different providers.
    private func gap(before index: Int) -> CGFloat {
        segments[index].providerID != segments[index - 1].providerID ? 11 : 7
    }

    @ViewBuilder
    private func icon(_ providerID: String) -> some View {
        if let mark = ProviderMarks.path(for: providerID) {
            ProviderIconShape(pathData: mark, inset: 0.04)
                .fill(tint)
                .frame(width: 15, height: 15)
        } else {
            Image(systemName: ProviderCatalog.iconName(for: providerID))
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 15, height: 15)
        }
    }
}

enum MenuBarStripRenderer {
    @MainActor private static var lastSignature: String?
    @MainActor private static var lastImage: NSImage?

    /// Renders the segments into a template `NSImage` for the status item, memoized on content so an
    /// unchanged strip isn't re-rendered on every poll tick.
    @MainActor
    static func stripImage(_ segments: [MenuBarSegment]) -> NSImage? {
        let signature = segments
            .map { "\($0.providerID):\($0.lines.joined(separator: "/")):\($0.dimmed):\($0.badge ?? 0)" }
            .joined(separator: "|")
        if signature == lastSignature, let image = lastImage { return image }

        let renderer = ImageRenderer(content: MenuBarStripView(segments: segments))
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { return nil }
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: CGFloat(cgImage.width) / 2, height: CGFloat(cgImage.height) / 2))
        image.isTemplate = true

        lastSignature = signature
        lastImage = image
        return image
    }

    /// README/marketing snapshot: the strip as a dark menu bar draws it (white glyphs on the
    /// bar's dark base), written as a 2x PNG. Screen-capturing the real menu bar needs TCC
    /// grants an SSH session can't hold, so the app renders its own strip instead - same view,
    /// same data, deterministic. Fired from `-TallyStripSnapshot <path>` in demo mode only.
    @MainActor
    static func writeSnapshot(_ segments: [MenuBarSegment], to path: String) {
        let renderer = ImageRenderer(content:
            MenuBarStripView(segments: segments, devTag: false, tint: .white)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(red: 0.11, green: 0.11, blue: 0.12)))
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { return }
        try? NSBitmapImageRep(cgImage: cgImage)
            .representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
    }
}
