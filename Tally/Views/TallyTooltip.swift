import SwiftUI

/// Tally's own hover tooltip: a small callout that fades in over the hovered element after a short
/// dwell. It replaces `NSToolTip` (`.help()`) where the app wants its own voice - the system tooltip
/// arrives late, cannot be styled, and reads as an OS artefact sitting on top of the app's glass.
///
/// Two halves that find each other through a preference:
///  - `.tallyTooltip(text)` on any element: tracks hover, waits out the dwell, then publishes its own
///    frame plus the text upward.
///  - `.tallyTooltipLayer()` once per surface root: renders whatever arrives, above everything and
///    outside every clip.
///
/// The layer has to sit at the surface root because targets live inside a `ScrollView` and inside
/// cards: a plain `.overlay` on the element itself is clipped by both, and the callout must be able
/// to overhang the card it belongs to. `.overlay` (not a ZStack sibling) is what carries it, because
/// an overlay is laid out against its content's size and can never feed a size back - the dashboard
/// window sizes itself from SwiftUI's own fitting size, and the popover and the panel from
/// `PopoverRootView.onContentSize`, so a floating layer that could widen or heighten the surface
/// would set the whole host resizing every time the pointer rested on a card.
///
/// Deliberately NOT an attached borderless `NSWindow`, the other way to escape a clip: three hosts
/// (popover, pinned panel, dashboard window) would each have to attach that child window, follow it
/// across window moves, screen changes and the popover's own transient close, and a window
/// overhanging the popover would draw outside the popover's shadowed frame. The cost of staying
/// in-window is that the callout cannot overhang the surface, so at the top edge it flips below the
/// target instead of escaping upward - which is the same rule it would need against the screen edge
/// anyway.
enum TallyTooltip {
    /// The surface-root coordinate space every target reports its frame in.
    static let space = "tallyTooltip"
    /// Dwell before showing. Long enough that crossing a control on the way somewhere else never
    /// flashes it, short enough that a deliberate hover feels answered - the system tooltip's own
    /// delay is several times this, which is exactly what reads as sluggish.
    static let delay: Duration = .milliseconds(350)
    static let fadeIn: Double = 0.14
    static let fadeOut: Double = 0.12
    /// Gap between the target's edge and the callout.
    static let gap: CGFloat = 6
    /// How close to the surface's own edges the callout may sit.
    static let margin: CGFloat = 6
    /// Content width of a structured callout (`TallyTooltipBlock`). Fits the narrowest host with
    /// room to spare: the single-column panel is 380pt wide, and this plus the chip's padding and
    /// both margins comes to 268pt there.
    static let blocksWidth: CGFloat = 240

    /// Which callout a design capture is holding open (`-TallyTooltipPreview fleet` /
    /// `-TallyTooltipPreview identity`, demo or dev builds only, argument domain so nothing
    /// persists): the named one shows with no pointer involved.
    ///
    /// It exists because the alternative is worse. A callout only appears under a real hover, so
    /// capturing one otherwise means synthesizing mouse events into the app, which takes the
    /// user's desktop away from them for as long as the verification runs (the rule, and the
    /// incident behind it, are in ~/.claude/docs/patterns/macos-app-verification.md: a dev-only
    /// flag that puts the state on screen IS the sanctioned answer). Same family as
    /// `-TallyUpdateChip`, `-TallyEmptyStatePreview` and `-TallyDryNotifyTest`.
    ///
    /// It names ONE target rather than switching every forcible callout on, because all of them
    /// publish into a single preference slot: two forced at once would race for it, and the capture
    /// would show whichever the layout traversal reached last.
    enum PreviewTarget: String {
        case fleet
        case identity
    }

    static func previewForced(_ target: PreviewTarget) -> Bool {
        guard DemoUsage.isActive || BuildVariant.isDev else { return false }
        let raw = (UserDefaults.standard.string(forKey: "TallyTooltipPreview") ?? "").lowercased()
        // `YES` predates the flag naming a target, and meant the fleet gauge - the only forcible
        // callout there was then. Kept working so an older capture command still captures.
        if target == .fleet, ["yes", "true", "1"].contains(raw) { return true }
        return raw == target.rawValue
    }
}

/// One line of a structured callout: a label on the left, its value on the right, and the severity
/// the value is tinted by (nil = no verdict, rendered in the callout's own quiet colour).
///
/// A row rather than a sentence because the values are numbers that want a column: three lines of
/// "Weekly pool 42% left" read as prose that has to be parsed one line at a time, where a column of
/// right-aligned figures is read at a glance. That is the whole reason this type exists.
struct TallyTooltipRow: Equatable {
    let label: String
    let value: String
    let severity: MetricSeverity?

    init(_ label: String, _ value: String, severity: MetricSeverity? = nil) {
        self.label = label
        self.value = value
        self.severity = severity
    }
}

/// A titled group of rows: one subject per block, so a two-provider fleet reads as two small tables
/// rather than one list the reader has to re-sort in their head.
struct TallyTooltipBlock: Equatable {
    let title: String
    let rows: [TallyTooltipRow]
}

/// What a callout carries. Plain text stays the default and the common case (most call sites are
/// one short sentence); a second line is for the hovers that answer with a subject and something
/// qualifying it, and blocks are for the few that answer with figures.
enum TallyTooltipContent: Equatable {
    /// The first line is the subject, in the callout's primary ink; any after it are quieter. Empty
    /// lines are dropped by the modifier that builds this, so a missing qualifier never renders as
    /// a blank row under the subject.
    case lines([String])
    case blocks([TallyTooltipBlock])

    var isEmpty: Bool {
        switch self {
        case .lines(let lines): return lines.allSatisfy(\.isEmpty)
        case .blocks(let blocks): return blocks.allSatisfy { $0.rows.isEmpty && $0.title.isEmpty }
        }
    }

    /// The same content as one string, for the accessibility hint: VoiceOver reads what the pointer
    /// would have been shown, and there is one source for both so they cannot drift.
    var spoken: String {
        switch self {
        case .lines(let lines):
            return lines.filter { !$0.isEmpty }.joined(separator: ", ")
        case .blocks(let blocks):
            return blocks.map { block in
                ([block.title] + block.rows.map { "\($0.label) \($0.value)" })
                    .filter { !$0.isEmpty }.joined(separator: ", ")
            }.joined(separator: ". ")
        }
    }
}

/// A live tooltip request: what to say and where its target is, in the surface's coordinate space.
private struct TallyTooltipItem: Equatable {
    let content: TallyTooltipContent
    let anchor: CGRect
}

/// One request at a time travels up: the hovered target publishes, everything else publishes nothing.
private struct TallyTooltipKey: PreferenceKey {
    static let defaultValue: TallyTooltipItem? = nil

    static func reduce(value: inout TallyTooltipItem?, nextValue: () -> TallyTooltipItem?) {
        value = nextValue() ?? value
    }
}

extension View {
    /// Hosts the callout for this surface. Apply once at the surface root, outside every clip.
    /// - Parameter suppressed: hide any callout while something else owns the pointer (a card
    ///   reorder drag): the anchors move under the pointer during it, so a callout fading in
    ///   mid-drag would both mislead and read as a glitch.
    func tallyTooltipLayer(suppressed: Bool = false) -> some View {
        modifier(TallyTooltipLayer(suppressed: suppressed))
    }

    /// Show Tally's own callout over this element after a short hover. Needs a `tallyTooltipLayer()`
    /// somewhere above it; without one, nothing shows and nothing breaks.
    ///
    /// The text is also the element's accessibility hint, so VoiceOver reads what the pointer would
    /// have been shown - the two can never drift, because there is one argument.
    ///
    /// - Parameters:
    ///   - detail: a quieter second line qualifying the first. Absent (or empty) shows the one line,
    ///     which is what every caller that has nothing to qualify passes.
    ///   - forced: hold it open with no pointer, for a design capture. The caller decides rather
    ///     than the flag alone, because a text callout can have many targets on one surface and
    ///     they would all publish at once (`TallyTooltip.previewForced`).
    func tallyTooltip(_ text: String, detail: String? = nil, forced: Bool = false) -> some View {
        modifier(TallyTooltipTarget(payload: .lines([text, detail ?? ""].filter { !$0.isEmpty }),
                                    forced: forced))
    }

    /// The same callout, answering with labelled figures instead of a sentence (see
    /// `TallyTooltipRow`). Empty blocks show nothing, exactly like empty text.
    func tallyTooltip(blocks: [TallyTooltipBlock]) -> some View {
        modifier(TallyTooltipTarget(payload: .blocks(blocks),
                                    forced: TallyTooltip.previewForced(.fleet)))
    }
}

// MARK: - Target

private struct TallyTooltipTarget: ViewModifier {
    /// Named `payload` rather than `content`: `ViewModifier.body(content:)` binds that word to the
    /// view being wrapped, and a stored property of the same name is silently shadowed inside it.
    let payload: TallyTooltipContent
    /// Held open with no pointer, for a design capture (`TallyTooltip.previewForced`).
    var forced = false

    @State private var isHovering = false
    @State private var isShown = false

    func body(content: Content) -> some View {
        content
            // A row of glyphs and labels is only hit-testable ON the glyphs, so without a shape the
            // pointer would leave and re-enter the target crossing every gap between them.
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                // Leaving hides at once (the dwell is an entry cost, not an exit one); the layer
                // still fades it out.
                if !hovering { isShown = false }
            }
            // Cancelled and restarted by every hover change, including the view going away, so a
            // pointer that passes through never leaves a callout behind it.
            .task(id: isHovering) {
                guard isHovering, !payload.isEmpty else { return }
                try? await Task.sleep(for: TallyTooltip.delay)
                guard !Task.isCancelled else { return }
                isShown = true
            }
            .background(probe)
            .accessibilityHint(Text(payload.spoken))
    }

    /// Publishes this target's frame while it is showing, and nothing at all otherwise - so the layer
    /// follows whichever target is hovered without the surface having to arbitrate between them.
    @ViewBuilder
    private var probe: some View {
        if isShown || (forced && !payload.isEmpty) {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: TallyTooltipKey.self,
                    value: TallyTooltipItem(content: payload,
                                            anchor: proxy.frame(in: .named(TallyTooltip.space))))
            }
        }
    }
}

// MARK: - Layer

private struct TallyTooltipLayer: ViewModifier {
    let suppressed: Bool

    @State private var item: TallyTooltipItem?
    /// A need, not a preference - the same rule the rest of the surface follows.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shown: TallyTooltipItem? { suppressed ? nil : item }

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(TallyTooltipKey.self) { item = $0 }
            .overlay {
                GeometryReader { proxy in
                    if let shown {
                        TallyTooltipCallout(item: shown, bounds: proxy.size)
                            .transition(transition)
                    }
                }
                // The layer spans the whole surface: hit-testing it would swallow every click and,
                // fatally for a hover tooltip, every hover underneath it.
                .allowsHitTesting(false)
                .animation(reduceMotion ? nil : .easeOut(duration: TallyTooltip.fadeIn), value: shown)
            }
            // Applied outside the overlay so targets AND the callout share one origin: the frames the
            // targets report are the frames the callout positions against.
            .coordinateSpace(name: TallyTooltip.space)
    }

    private var transition: AnyTransition {
        guard !reduceMotion else { return .identity }
        // Leaving is quicker than arriving: a callout that lingers follows the pointer around.
        return .asymmetric(insertion: .opacity,
                           removal: .opacity.animation(.easeIn(duration: TallyTooltip.fadeOut)))
    }
}

// MARK: - Callout

/// The chip itself: an inverted surface (dark over light, one step lighter than the window over
/// dark), so it reads as a layer above the content rather than another card in it. Positioned with
/// alignment guides rather than a measured size, which keeps it to one layout pass - the guide is
/// handed the chip's own dimensions, so the flip and the clamp are computed from the real size
/// instead of an estimate that would have to be re-measured and re-positioned a frame later.
private struct TallyTooltipCallout: View {
    let item: TallyTooltipItem
    /// The surface the callout has to stay inside.
    let bounds: CGSize

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(shape.fill(surface))
            .overlay(shape.strokeBorder(rim, lineWidth: TallyMetrics.hairline))
            .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.22), radius: 7, x: 0, y: 2)
            .fixedSize()
            .alignmentGuide(.leading) { dimensions in -originX(width: dimensions.width) }
            .alignmentGuide(.top) { dimensions in -originY(height: dimensions.height) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var content: some View {
        switch item.content {
        case .lines(let lines):
            // Tight leading between them: the second line qualifies the first rather than following
            // it, and a paragraph's worth of gap would read as two separate answers.
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(index == 0 ? primaryInk : secondaryInk)
                        .lineLimit(1)
                }
            }
        case .blocks(let blocks):
            // A fixed width rather than a fitted one, because the callout has to stay INSIDE the
            // surface (see the type's header) and the narrowest host is the 380pt single-column
            // panel: a width that grew with the longest account name would eventually reach the
            // margins with no way to give anything back. Rows truncate instead, and every block
            // then shares one column, which is what makes the values line up.
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(block.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(primaryInk)
                            .lineLimit(1)
                        ForEach(Array(block.rows.enumerated()), id: \.offset) { _, row in
                            HStack(spacing: 10) {
                                Text(row.label)
                                    .foregroundStyle(secondaryInk)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                                Text(row.value)
                                    .foregroundStyle(row.severity.map { $0.color } ?? primaryInk)
                                    .monospacedDigit()
                                    .lineLimit(1)
                                    .layoutPriority(1)
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            .frame(width: TallyTooltip.blocksWidth, alignment: .leading)
        }
    }

    /// The chip's own two ink levels. Its surface is dark in BOTH schemes (see `surface`), so these
    /// are fixed rather than semantic colours - `.secondary` over a dark chip on a light window
    /// resolves against the window and comes out unreadable.
    private var primaryInk: Color { Color.white.opacity(0.95) }
    private var secondaryInk: Color { Color.white.opacity(0.62) }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: TallyMetrics.calloutRadius, style: .continuous)
    }

    /// Near-black over a light window; a step lighter than the window over a dark one, because a
    /// black chip on a dark panel loses its own edge.
    private var surface: Color {
        Color(white: scheme == .dark ? 0.20 : 0.12)
    }

    /// A rim of light, the way the cards get theirs from `Color.primary` - here it has to be white
    /// in both schemes, because the chip's own background is dark in both.
    private var rim: Color {
        Color.white.opacity(scheme == .dark ? 0.16 : 0.10)
    }

    /// Centred on the target, then held inside the surface's margins.
    ///
    /// `nonisolated` because an alignment guide is resolved by the layout engine outside the view's
    /// own actor: both stored properties this reads are immutable and `Sendable`, so the geometry is
    /// pure arithmetic on values, not a hop back to the view.
    private nonisolated func originX(width: CGFloat) -> CGFloat {
        let centred = item.anchor.midX - width / 2
        let rightmost = max(TallyTooltip.margin, bounds.width - width - TallyTooltip.margin)
        return min(max(centred, TallyTooltip.margin), rightmost)
    }

    /// Above the target, or below it when there is no room above (the top card in a panel). Below is
    /// itself held off the bottom edge, so a target near either edge still shows the whole chip.
    private nonisolated func originY(height: CGFloat) -> CGFloat {
        let above = item.anchor.minY - TallyTooltip.gap - height
        if above >= TallyTooltip.margin { return above }
        let lowest = max(TallyTooltip.margin, bounds.height - height - TallyTooltip.margin)
        return min(item.anchor.maxY + TallyTooltip.gap, lowest)
    }
}
