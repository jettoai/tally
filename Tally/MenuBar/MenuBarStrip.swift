import AppKit
import SwiftUI

/// The menu-bar strip, drawn as a single SwiftUI view rendered to an `NSImage`: one ring per pool
/// with the provider's mark inside, the arc as long as the share of the WEEK that is left, and no
/// text at all (B-2045). Each ring and its mark wear the colour of the panel bar for the same
/// window (`MetricSeverity.color`: green from 50% left, amber from 20%, red below); the waiting dot
/// and the DEV tag are ink, which `MenuBarStripRenderer` picks for the bar's scheme. What each ring
/// stands for - one account or one provider's pool - is decided in `MenuBarSegments`, and what it
/// shows (length, colour, faded, dashed) in `PoolRing`.
private struct MenuBarStripView: View {
    let segments: [MenuBarSegment]
    /// A session is waiting on the user: one solid dot after the rings, in ink.
    var waiting = false
    /// Snapshot rendering override: the README shot drops the DEV tag.
    var devTag: Bool = BuildVariant.isDev
    /// The bar's ink for this scheme; also the colour of a ring with no severity to show.
    var ink: Color = .black
    /// Adds a thinner inner ring for the 5-hour window inside each weekly ring.
    var showSession = false

    var body: some View {
        HStack(spacing: 0) {
            // The dev variant announces itself right in the strip - two otherwise identical icons
            // side by side must be tellable at a glance.
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
                    // Tight between pools of one provider, wider between providers.
                    Color.clear.frame(width: segment.providerID == segments[index - 1].providerID ? 3 : 6,
                                      height: 0)
                }
                ringUnit(segment)
            }
            if waiting {
                Color.clear.frame(width: 4, height: 0)
                Circle().frame(width: 5, height: 5)
            }
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 2)
        .padding(.vertical, 1)
        .fixedSize()
    }

    private func ringUnit(_ segment: MenuBarSegment) -> some View {
        let ring = PoolRing(segment)
        let color = ring.severity == .unknown ? ink : ring.severity.color
        return ZStack {
            if let fraction = ring.fraction {
                Circle().strokeBorder(color, lineWidth: 2).opacity(0.28)
                Circle().inset(by: 1).trim(from: 0, to: fraction)
                    .stroke(color, lineWidth: 2)
                    .rotationEffect(.degrees(-90))
            } else {
                // Nothing to read: a dashed track with no arc, the mark stays.
                Circle().strokeBorder(color, style: StrokeStyle(lineWidth: 2, dash: [2, 2]))
            }
            if showSession {
                innerRing(ring)
            }
            icon(segment.providerID, size: showSession ? 7 : 10.5, color: color)
        }
        .frame(width: 18, height: 18)
        .opacity(ring.isFaded ? 0.4 : 1)
    }

    /// The 5-hour ring: 1.5 pt wide, 1 pt inside the weekly ring's inner edge, same track, start and
    /// direction. No reading draws a dashed track, the way the weekly ring does.
    @ViewBuilder
    private func innerRing(_ ring: PoolRing) -> some View {
        let color = ring.innerSeverity == .unknown ? ink : ring.innerSeverity.color
        let ringSpace: CGFloat = 3.75
        if let fraction = ring.innerFraction {
            Circle().inset(by: ringSpace).stroke(color, lineWidth: 1.5).opacity(0.28)
            Circle().inset(by: ringSpace).trim(from: 0, to: fraction)
                .stroke(color, lineWidth: 1.5)
                .rotationEffect(.degrees(-90))
        } else {
            Circle().inset(by: ringSpace)
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: [1.5, 1.5]))
        }
    }

    @ViewBuilder
    private func icon(_ providerID: String, size: CGFloat, color: Color) -> some View {
        if let mark = ProviderMarks.path(for: providerID) {
            ProviderIconShape(pathData: mark, inset: 0.04)
                .fill(color)
                .frame(width: size, height: size)
        } else {
            Image(systemName: ProviderCatalog.iconName(for: providerID))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: size, height: size)
        }
    }
}

enum MenuBarStripRenderer {
    @MainActor private static var lastSignature: String?
    @MainActor private static var lastImage: NSImage?

    /// The ink a menu bar of each scheme gets. A fixed colour rather than a dynamic one: the
    /// renderer draws each scheme once, and the image picks between the two at draw time.
    private static func ink(_ scheme: ColorScheme) -> Color { scheme == .dark ? .white : .black }

    @MainActor
    private static func render(_ segments: [MenuBarSegment], waiting: Bool, showSession: Bool,
                               scheme: ColorScheme) -> CGImage? {
        let renderer = ImageRenderer(content: MenuBarStripView(
            segments: segments, waiting: waiting, ink: ink(scheme), showSession: showSession))
        renderer.scale = 2
        return renderer.cgImage
    }

    /// Renders the segments for the status item, memoized on content so an unchanged strip isn't
    /// re-rendered on every poll tick.
    ///
    /// A NON-template image, because the rings are coloured. The strip is drawn twice, once per
    /// scheme in its own ink, and the image picks one at draw time from the appearance it is drawn
    /// into, so the white or black parts follow a light or dark bar (and the per-button pin of
    /// `-TallyMenuBarAppearance`) while green, amber and red stay as they are. Chosen over a template
    /// image because a template has no colours of its own, and over one fixed-ink image because the
    /// bar's scheme changes under the app; what it gives up is the press inversion a template gets.
    @MainActor
    static func stripImage(_ segments: [MenuBarSegment], waiting: Bool = false,
                           showSession: Bool = false) -> NSImage? {
        let signature = (waiting ? "!" : "") + (showSession ? "s" : "") + segments.map {
            let ring = PoolRing($0)
            return "\($0.providerID):\(ring.fraction ?? -1):\(ring.severity.rawValue):\(ring.isFaded)"
                + ":\(ring.innerFraction ?? -1):\(ring.innerSeverity.rawValue)"
        }.joined(separator: "|")
        if signature == lastSignature, let image = lastImage { return image }

        guard let dark = render(segments, waiting: waiting, showSession: showSession, scheme: .dark),
              let light = render(segments, waiting: waiting, showSession: showSession, scheme: .light)
        else { return nil }
        let size = NSSize(width: CGFloat(dark.width) / 2, height: CGFloat(dark.height) / 2)
        let image = NSImage(size: size, flipped: false) { rect in
            let isDark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            NSImage(cgImage: isDark ? dark : light, size: size).draw(in: rect)
            return true
        }

        lastSignature = signature
        lastImage = image
        return image
    }

    /// README/marketing snapshot: the strip as a dark menu bar draws it (white glyphs on the
    /// bar's dark base), written as a 2x PNG. Screen-capturing the real menu bar needs TCC
    /// grants an SSH session can't hold, so the app renders its own strip instead - same view,
    /// same data, deterministic. Fired from `-TallyStripSnapshot <path>` in demo mode only.
    @MainActor
    static func writeSnapshot(_ segments: [MenuBarSegment], to path: String, waiting: Bool = false,
                              showSession: Bool = false) {
        let renderer = ImageRenderer(content:
            MenuBarStripView(segments: segments, waiting: waiting, devTag: false, ink: ink(.dark),
                             showSession: showSession)
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
