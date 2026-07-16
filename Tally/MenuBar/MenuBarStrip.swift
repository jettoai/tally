import AppKit
import SwiftUI

/// One account's compact readout in the menu-bar strip: its provider's brand mark + the account-wide
/// windows (5h session on top, weekly below) stacked. Every account gets its own mark, so N accounts
/// read as N marks.
struct MenuBarSegment: Sendable {
    var providerID: String
    var lines: [String]        // account-wide window percents, session then weekly; ["!"]/["—"] for error/no-data
    var dimmed: Bool           // stale (last-good shown after a failed refresh)
    var accountIndex: Int?     // 1-based badge when the same provider has several accounts; nil otherwise
}

/// The menu-bar strip, drawn as a single SwiftUI view rendered to a template `NSImage`. Each account
/// is `mark + stacked percents`; same-provider accounts sit close, different providers spaced further,
/// so a glance reads how many accounts and how each stands. Monochrome + `isTemplate` tints it.
private struct MenuBarStripView: View {
    let segments: [MenuBarSegment]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                if index > 0 {
                    Color.clear.frame(width: gap(before: index), height: 0)
                }
                HStack(spacing: 4) {
                    icon(segment.providerID)
                        .overlay(alignment: .bottomTrailing) {
                            // Same-provider accounts share one mark — a tiny corner digit is the only
                            // identity the strip carries; the full names live in the tooltip.
                            if let index = segment.accountIndex {
                                Text("\(index)")
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
        .foregroundStyle(.black)   // template mask — actual tint applied by AppKit
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
                .fill(Color.black)
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
            .map { "\($0.providerID):\($0.lines.joined(separator: "/")):\($0.dimmed):\($0.accountIndex ?? 0)" }
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
}
