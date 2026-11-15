import Foundation

/// THE ONE SET OF METER COLOURS (B-4059, design B). Every bar and ring that says how much of a
/// window is left reads its state colour from here: the Detailed panel's rows and pool ring, the
/// menu bar rings, the pinned panel's rings and the fleet bar. Pure numbers and free of AppKit,
/// like `PanelPalette`, so a test asserts exactly what is drawn.
///
/// Two sets rather than one colour per state: the dark set is lightened and the light set
/// darkened, so each colour clears 3:1 on its own background (pure black, pure white). One colour
/// for both would have to sit at a middle lightness that reads muddy on black.
///
/// The thresholds are `MetricSeverity.fromUsedPercent`'s: 50% or more left, under 50%, under 20%,
/// and spent (100% used).
struct MeterPalette: Equatable {
    /// Arc and bar fill per state.
    var normal: UInt32
    var warning: UInt32
    var critical: UInt32
    var exhausted: UInt32
    /// The figure from critical on (a ring's numeral and caption, a row's figure and its reset
    /// countdown); above that the surface keeps its own text colour.
    var alarmInk: UInt32
    /// The groove under every bar and ring.
    var grooveHex: UInt32
    var grooveAlpha: Double
    /// A spent window's groove: the exhausted colour at this opacity, so an empty ring or bar still
    /// reads red. The shape (a full red groove) is what tells it from "near empty", not the hue.
    var exhaustedGrooveAlpha: Double

    static let dark = MeterPalette(normal: 0x3DCF6A, warning: 0xFFB224, critical: 0xFF6259,
                                   exhausted: 0xFF6259, alarmInk: 0xFF8A80,
                                   grooveHex: 0xFFFFFF, grooveAlpha: 0.12, exhaustedGrooveAlpha: 0.30)
    static let light = MeterPalette(normal: 0x168A42, warning: 0xB86E00, critical: 0xD92D20,
                                    exhausted: 0xD92D20, alarmInk: 0xB3261E,
                                    grooveHex: 0x000000, grooveAlpha: 0.08, exhaustedGrooveAlpha: 0.18)

    static func of(dark: Bool) -> MeterPalette { dark ? .dark : .light }

    /// The 22pt rings (menu bar, pinned panel) draw their track in the state colour itself, faint.
    /// A spent ring's track is stronger, so a ring with no arc left still reads red.
    static let smallRingTrackAlpha = 0.28
    static let smallRingExhaustedTrackAlpha = 0.45
}
