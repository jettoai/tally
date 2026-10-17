import AppKit
import SwiftUI

/// The menu-bar strip, drawn as a single SwiftUI view rendered to an `NSImage`: one ring per pool
/// with the provider's mark inside, the arc as long as the share of the WEEK that is left, and no
/// text at all (B-2045). Ink only, so a light or dark menu bar tints the template image; a pool
/// below `PoolRing.lowBelow` turns red as a whole (see `MenuBarStripRenderer` for how). What each
/// ring stands for - one account or one provider's pool - is decided in `MenuBarSegments`, and what
/// it shows (length, red, faded, dashed) in `PoolRing`.
private struct MenuBarStripView: View {
    let segments: [MenuBarSegment]
    /// A session is waiting on the user: one solid dot after the rings, in the same ink as them.
    var waiting = false
    /// Snapshot rendering overrides: the README shot drops the DEV tag and draws white-on-dark
    /// directly instead of the template mask AppKit tints.
    var devTag: Bool = BuildVariant.isDev
    var ink: Color = .black   // template mask (black) - the actual tint is applied by AppKit
    var red: Color = .red

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
        let color = ring.isLow ? red : ink
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
            icon(segment.providerID, size: 10.5, color: color)
        }
        .frame(width: 18, height: 18)
        .opacity(ring.isFaded ? 0.4 : 1)
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

    /// The ink and the red a menu bar of each scheme gets. Fixed values rather than dynamic colours:
    /// the renderer draws each scheme once, and the image picks between the two at draw time.
    private static func palette(_ scheme: ColorScheme) -> (ink: Color, red: Color) {
        scheme == .dark
            ? (.white, Color(red: 1, green: 0.27, blue: 0.23))
            : (.black, Color(red: 1, green: 0.23, blue: 0.19))
    }

    @MainActor
    private static func render(_ segments: [MenuBarSegment], waiting: Bool,
                               scheme: ColorScheme) -> CGImage? {
        let colors = palette(scheme)
        let renderer = ImageRenderer(content: MenuBarStripView(
            segments: segments, waiting: waiting, ink: colors.ink, red: colors.red))
        renderer.scale = 2
        return renderer.cgImage
    }

    /// Renders the segments for the status item, memoized on content so an unchanged strip isn't
    /// re-rendered on every poll tick.
    ///
    /// A TEMPLATE image (one ink, AppKit tints it for a light or dark bar and inverts it while the
    /// item is pressed) whenever every ring is ink, which is nearly always. A red pool cannot be a
    /// template, so then and only then the strip is drawn twice, once per scheme in its own ink,
    /// into a non-template image that picks one at draw time from the appearance it is drawn into.
    /// Chosen over one non-template image for everything because it keeps the tint and the pressed
    /// look for the usual case, and over a separate red layer because a status button holds one image.
    @MainActor
    static func stripImage(_ segments: [MenuBarSegment], waiting: Bool = false) -> NSImage? {
        let signature = (waiting ? "!" : "") + segments.map {
            let ring = PoolRing($0)
            return "\($0.providerID):\(ring.fraction ?? -1):\(ring.isLow):\(ring.isFaded)"
        }.joined(separator: "|")
        if signature == lastSignature, let image = lastImage { return image }

        let image: NSImage
        if segments.contains(where: { PoolRing($0).isLow }) {
            guard let dark = render(segments, waiting: waiting, scheme: .dark),
                  let light = render(segments, waiting: waiting, scheme: .light) else { return nil }
            let size = NSSize(width: CGFloat(dark.width) / 2, height: CGFloat(dark.height) / 2)
            image = NSImage(size: size, flipped: false) { rect in
                let isDark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                NSImage(cgImage: isDark ? dark : light, size: size).draw(in: rect)
                return true
            }
        } else {
            guard let cgImage = render(segments, waiting: waiting, scheme: .light) else { return nil }
            image = NSImage(
                cgImage: cgImage,
                size: NSSize(width: CGFloat(cgImage.width) / 2, height: CGFloat(cgImage.height) / 2))
            image.isTemplate = true
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
    static func writeSnapshot(_ segments: [MenuBarSegment], to path: String, waiting: Bool = false) {
        let colors = palette(.dark)
        let renderer = ImageRenderer(content:
            MenuBarStripView(segments: segments, waiting: waiting, devTag: false,
                             ink: colors.ink, red: colors.red)
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
