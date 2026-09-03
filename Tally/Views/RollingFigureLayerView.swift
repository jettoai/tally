import AppKit
import CoreText
import SwiftUI

/// A LIVE FIGURE'S DIGITS, ROLLED BY THE RENDER SERVER INSTEAD OF BY THE VIEW TREE.
///
/// THE SAME MEASUREMENT THE LINE BESIDE IT WAS MOVED FOR (Albert, 2026-09-03, feeling the board
/// lag). `contentTransition(.numericText)` is a transition in the view tree, so every frame of every
/// quarter-second roll made a leaf's layout computer dirty and the whole panel was laid out again:
/// nothing between that leaf and the root truncates an invalidation travelling up, `.geometryGroup`
/// included, so the digits rolling ALONE cost 38.9% of one core against 13.2% with nothing moving on
/// the same board in the same minute (measured 2026-09-04, the line already being a layer's work).
/// A layer's roll is one commit per reading and no per-frame SwiftUI layout between two readings,
/// which is the only shape of fix that reaches the threshold rather than trimming it
/// (`FootprintSparklineLayerView` carries the whole of that reasoning for the outline). NOT
/// LITERALLY NO MAIN THREAD WORK, which this used to claim: the frames themselves are the window
/// server's, and what this process still runs is one completion block per departing character
/// (`depart`), which is that layer taking itself off when its fade is over.
///
/// ONE LAYER PER CHARACTER, which is what makes a roll a roll: the digits that changed travel and
/// fade while the ones that did not stay exactly where they are, so `459 MB` becoming `460 MB` moves
/// one character and not a number. The characters that stand still are the point - a whole figure
/// sliding on every reading is the motion this replaced (`.push`).
///
/// WHAT IT IS NOT is `numericText`'s own blur, which no layer property spells. That difference is
/// the one thing here a diff cannot settle, so the samples window draws this and the view tree's
/// version side by side under one clock (`MotionDemoWindow`, N3 and N3v).
struct RollingFigureLayerView: NSViewRepresentable {
    /// The figure as it is spelled, which is what a change is judged on.
    let text: String
    /// The same reading as a quantity, which is the only thing that can say which way to turn:
    /// `999 MB` to `1.0 GB` is a rise that reads as a fall (`Trend.value`).
    let value: Double?
    /// What colour to draw it in. Handed down rather than inherited: a layer is outside the view
    /// tree and a `foregroundStyle` does not reach it (`FigureTone`).
    let tone: FigureTone
    /// Every motion off, for a reader who asked the system for that.
    let still: Bool
    /// Which curve, out of the three this launch chooses between (`MotionChoice.Curve`).
    let curve: MotionChoice.Curve

    func makeNSView(context: Context) -> RollingFigureLayerHost {
        let view = RollingFigureLayerHost()
        update(view)
        return view
    }

    func updateNSView(_ nsView: RollingFigureLayerHost, context: Context) { update(nsView) }

    /// THE SIZE ASKS THE SUBTREE NOTHING, which is half of why this is cheaper than the transition
    /// it replaces: a leaf whose measurement never walks a subtree cannot make its ancestors' layout
    /// computers dirty, and the seven-candidate ladder above it measures this seven times per tick
    /// (`SessionCardTrendRow.sessionFootprintTrends`).
    ///
    /// THE COLUMN IS THE SIZE AUTHORITY, so what this normally answers is the proposal it was handed:
    /// the width is already pinned by a hidden copy of the widest reading this metric can print, and
    /// this view fills that box (`SessionCardView.column`). The fallback is a measurement of the
    /// STRING, which is a pure function of the value rather than a question put to the view.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RollingFigureLayerHost,
                      context: Context) -> CGSize? {
        if let width = proposal.width, let height = proposal.height {
            return CGSize(width: width, height: height)
        }
        let measured = RollingFigureLayerHost.measure(text)
        return CGSize(width: proposal.width ?? measured.width,
                      height: proposal.height ?? measured.height)
    }

    private func update(_ view: RollingFigureLayerHost) {
        view.apply(text: text, value: value, tone: tone, still: still, curve: curve)
    }
}

/// WHAT COLOUR A ROLLED FIGURE IS DRAWN IN.
///
/// A LAYER IS HANDED A COLOUR RATHER THAN INHERITING A STYLE. The figures this replaces are `Text`
/// with a `foregroundStyle` on them, and a style is a view tree thing: nothing of it reaches an
/// `NSView`, so an amber reading whose digits rolled in grey would be the warning going missing for
/// the quarter second the roll takes. The three the board asks for are named here and resolved
/// against the appearance under the view, the greys being different colours in the two appearances
/// (`FootprintSparklineLayerHost.recolour`).
enum FigureTone: Equatable {
    /// A reading with nothing wrong with it, in the colour every calm figure is drawn in.
    case primary
    /// A ceiling, a step back from the reading it belongs to (`SessionCardTrendRow.trendRow`).
    case tertiary
    /// A tier's own colour, or the flame's (`FootprintAlertLevel.tint`, `SessionCardView.flameTint`).
    case tinted(Color)

    /// A tier's colour where there is one, and the plain reading where there is not, which is the
    /// same question the speller asks (`SessionCardView.figure`).
    static func tint(_ colour: Color?) -> FigureTone { colour.map(FigureTone.tinted) ?? .primary }

    /// Resolved against whatever appearance is current, so the two greys are the system's own.
    var nsColor: NSColor {
        switch self {
        case .primary: .labelColor
        case .tertiary: .tertiaryLabelColor
        case .tinted(let colour): NSColor(colour)
        }
    }
}

/// The view those layers hang in: no drawing of its own, no hit testing, nothing to say to a
/// listener. Everything it does is in `apply`.
final class RollingFigureLayerHost: NSView {
    /// One per character of the figure on screen, left to right.
    private var glyphs: [CATextLayer] = []
    /// The characters those layers spell, so a new reading can be compared one place at a time.
    private var characters: [Character] = []
    /// The figure on screen, or nothing before the first reading has been applied.
    private var shown: String?
    /// The reading behind the one on screen, which is where the direction comes from. Kept here
    /// rather than asked of the caller: this view is told every reading, including the ones that are
    /// spelled the same as the last (9.1% and 9.4% are both `9%`), and the direction is the
    /// QUANTITY'S even when the spelling did not change.
    private var value: Double?
    private var tone: FigureTone = .primary
    private var still = false
    private var curve: MotionChoice.Curve = .bouncy
    /// The characters on their way out, still fading. Held so a reading that arrives still can cut
    /// them off rather than letting them finish (`apply`).
    private var ghosts: [CATextLayer] = []
    /// The box the glyphs were last laid out in, so a layout pass that changed nothing does not
    /// rebuild them underneath an animation in flight.
    private var placed: CGSize = .zero

    /// THE FIGURES' OWN TYPE, which is the row's: caption two with the digits all one width, so a
    /// reading whose digits change does not change its own width mid-roll (`trendRow` sets the same
    /// font on the SwiftUI side of this column).
    ///
    /// TAKEN FROM THE STYLE AND THEN GIVEN MONOSPACED DIGITS, rather than asked for by size and
    /// weight: macOS draws caption two in MEDIUM, and a system font asked for at that size in the
    /// obvious weight comes back Regular - visibly thinner than the `Text` beside it in the samples
    /// window, which is the comparison this whole surface is judged by (measured 2026-09-04:
    /// `.SFNS-Medium` against `.SFNS-Regular`, both 10pt).
    private static let font: NSFont = {
        let base = NSFont.preferredFont(forTextStyle: .caption2)
        let descriptor = base.fontDescriptor.addingAttributes([
            .featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                                NSFontDescriptor.FeatureKey.selectorIdentifier:
                                    kMonospacedNumbersSelector]]
        ])
        return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let host = CALayer()
        layer = host
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        // WHAT MAKES A ROLL A ROLL RATHER THAN A DRIFT: a character leaves through the top or the
        // bottom edge of the line it is on, so what a reader sees is a digit turning over in place.
        // One mask for the whole strip rather than one per character, which is the same clip: the
        // characters only ever move vertically and every one of them spans the full height.
        host.masksToBounds = true
        // The digits say nothing a reader who cannot see them can use, and the row around them
        // states every figure on it in words (`SessionCardTrendRow.spokenTrends`).
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// A FIGURE, NOT A CONTROL. The card underneath is one button and the row carries a drag; a view
    /// that answered a hit test would take a click meant for either (`SessionCardView`).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        guard bounds.size != placed else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        place(shown ?? "")
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rescale()
    }

    /// Drawn at the backing store's own resolution, and again when the window moves to a display
    /// with a different one.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rescale()
    }

    /// The two greys are the system's own and are different colours in the two appearances, so they
    /// are resolved again whenever the appearance under this view changes.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        recolour()
    }

    /// EVERYTHING THIS VIEW DOES, ONCE PER READING. Whatever changed decides which animation is
    /// committed; nothing at all is committed when nothing changed, which matters because SwiftUI
    /// re-runs an update for reasons that are not a new reading.
    func apply(text: String, value: Double?, tone: FigureTone, still: Bool,
               curve: MotionChoice.Curve) {
        // THE DIRECTION IS READ BEFORE THE GUARD BELOW, because a reading that is spelled the same
        // is still a reading: 9.1% and 9.4% are both `9%`, and the rise from 9.4% to 10% is a rise
        // from the reading that arrived rather than from the last one that changed the digits.
        let rising = MotionChoice.rising(from: self.value, to: value)
        self.value = value
        let previous = shown
        let arriving = previous != nil && previous != text
        let restyled = self.tone != tone || self.still != still || self.curve != curve
        guard previous == nil || arriving || restyled else { return }
        shown = text
        self.tone = tone
        self.still = still
        self.curve = curve

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // A READING THAT ARRIVES STILL CUTS OFF WHATEVER WAS IN FLIGHT, rather than letting it
        // finish: Reduce Motion switched on mid-roll must stop the roll then, not up to a settling
        // duration later. The characters leaving go with it - they exist only for the motion.
        if still {
            for glyph in glyphs { glyph.removeAllAnimations() }
            for ghost in ghosts { ghost.removeAllAnimations(); ghost.removeFromSuperlayer() }
            ghosts.removeAll()
        }
        ghosts.removeAll { $0.superlayer == nil }
        if arriving, !still {
            roll(to: text, rising: rising)
        } else {
            place(text)
        }
        CATransaction.commit()
    }

    // MARK: - The reading arriving

    /// THE CHARACTERS THAT CHANGED, AND ONLY THOSE. Two readings of the same length are compared one
    /// place at a time, so `459 MB` becoming `460 MB` turns one digit over and leaves the rest
    /// standing. Two of DIFFERENT lengths are not comparable place by place - `9%` becoming `12%` is
    /// every character in a new place - so the whole figure travels as one group, which is also what
    /// a reader sees happen: the number got wider.
    private func roll(to text: String, rising: Bool) {
        let before = characters
        let after = Array(text)
        let aligned = before.count == after.count
        let leaving = aligned ? before.indices.filter { before[$0] != after[$0] }
                              : Array(before.indices)
        let departing = glyphs.map { (frame: $0.frame, string: $0.string) }
        for index in leaving where departing.indices.contains(index) {
            depart(frame: departing[index].frame, string: departing[index].string, rising: rising)
        }
        place(text)
        let entering = aligned ? after.indices.filter { before[$0] != after[$0] }
                               : Array(after.indices)
        for index in entering where glyphs.indices.contains(index) {
            arrive(glyphs[index], rising: rising)
        }
    }

    /// One character on its way out: it travels the way the reading moved and fades as it goes, and
    /// takes itself off the layer when it has. A throwaway copy rather than the glyph layer itself,
    /// which is already spelling the new character by the time this is seen.
    private func depart(frame: CGRect, string: Any?, rising: Bool) {
        let ghost = makeGlyph()
        ghost.frame = frame
        ghost.string = string
        ghost.foregroundColor = glyphColour()
        layer?.addSublayer(ghost)
        ghosts.append(ghost)
        let rest = ghost.position.y
        ghost.position.y = rest + (rising ? bounds.height : -bounds.height)
        ghost.opacity = 0
        CATransaction.begin()
        CATransaction.setCompletionBlock { ghost.removeFromSuperlayer() }
        ghost.add(spring(curve, keyPath: "position.y", from: rest, to: ghost.position.y),
                  forKey: "roll")
        ghost.add(spring(curve, keyPath: "opacity", from: 1, to: 0), forKey: "fade")
        CATransaction.commit()
    }

    /// One character arriving: from the side the one it replaces left towards, so the two read as
    /// one turning rather than as two independent fades.
    private func arrive(_ glyph: CATextLayer, rising: Bool) {
        let rest = glyph.position.y
        glyph.add(spring(curve, keyPath: "position.y",
                         from: rest - (rising ? bounds.height : -bounds.height), to: rest),
                  forKey: "roll")
        glyph.add(spring(curve, keyPath: "opacity", from: 0, to: 1), forKey: "fade")
    }

    // MARK: - The figure as it stands

    /// THE FIGURE WITH NO MOTION IN IT: one layer per character, each in the place the whole string
    /// puts it. Layers are reused where the length allows, so an ordinary reading rebuilds nothing.
    private func place(_ text: String) {
        placed = bounds.size
        characters = Array(text)
        while glyphs.count > characters.count { glyphs.removeLast().removeFromSuperlayer() }
        while glyphs.count < characters.count {
            let glyph = makeGlyph()
            layer?.addSublayer(glyph)
            glyphs.append(glyph)
        }
        let colour = glyphColour()
        for (index, box) in Self.boxes(characters, in: bounds).enumerated() {
            let glyph = glyphs[index]
            glyph.frame = box
            glyph.string = String(characters[index])
            glyph.foregroundColor = colour
            glyph.opacity = 1
        }
    }

    /// WHERE EACH CHARACTER SITS, TAKEN FROM THE WHOLE STRING rather than from the characters one at
    /// a time: a line's own layout is what decides the space between two characters, and one
    /// measured alone would not know about the one beside it. Right aligned, which is what the
    /// column it fills is (`SessionCardView.column`).
    private static func boxes(_ characters: [Character], in bounds: CGRect) -> [CGRect] {
        guard !characters.isEmpty else { return [] }
        let line = CTLineCreateWithAttributedString(attributed(String(characters)))
        var offsets: [CGFloat] = []
        var index = 0
        for character in characters {
            offsets.append(CTLineGetOffsetForStringIndex(line, index, nil))
            index += character.utf16.count
        }
        let width = CTLineGetOffsetForStringIndex(line, index, nil)
        let origin = bounds.width - width
        return offsets.indices.map { place in
            let next = place + 1 < offsets.count ? offsets[place + 1] : width
            return CGRect(x: origin + offsets[place], y: 0,
                          width: next - offsets[place], height: bounds.height)
        }
    }

    /// The figure at the size it would be drawn, for the one caller that has no box to fill yet
    /// (`RollingFigureLayerView.sizeThatFits`).
    static func measure(_ text: String) -> CGSize {
        let line = CTLineCreateWithAttributedString(attributed(text))
        return CGSize(width: CTLineGetOffsetForStringIndex(line, text.utf16.count, nil),
                      height: font.ascender - font.descender + font.leading)
    }

    private static func attributed(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font])
    }

    private func makeGlyph() -> CATextLayer {
        let glyph = CATextLayer()
        glyph.font = Self.font
        glyph.fontSize = Self.font.pointSize
        glyph.isWrapped = false
        glyph.contentsScale = scale
        // NOTHING HERE ANIMATES UNLESS IT IS ASKED TO. A layer property changed outside a
        // transaction of this view's own carries Core Animation's own default half-second fade, so
        // a window resize would roll every digit on the board.
        glyph.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(),
                         "opacity": NSNull(), "foregroundColor": NSNull()]
        return glyph
    }

    // MARK: - Colour and resolution

    private func glyphColour() -> CGColor {
        var colour = NSColor.labelColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { colour = tone.nsColor.cgColor }
        return colour
    }

    private func recolour() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let colour = glyphColour()
        for glyph in glyphs { glyph.foregroundColor = colour }
        CATransaction.commit()
    }

    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    private func rescale() {
        for glyph in glyphs + ghosts { glyph.contentsScale = scale }
    }
}
