import AppKit
import Foundation

// Assertions for the surface height cap (Tally/Views/ScreenFitStack.swift): how tall a surface may
// become on a given display AND at a given position on it. The position half exists because the
// pinned panel and the dashboard window keep their top left as they grow, so content that outgrows
// the room below that edge gets the whole window shoved back up by clampOnScreen - which moves the
// row out from under the pointer that just clicked it.

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition { print("  ok: \(message)") } else { print("  FAIL: \(message)"); failures += 1 }
}
func section(_ title: String) { print("\n\(title)") }

// A 1152pt display with the menu bar taken out, the shape the incident was measured on.
let visible = CGRect(x: 0, y: 0, width: 2048, height: 1120)

section("no top edge: the screen rule alone")

let screenOnly = ScreenFitStack.cap(visible: visible, topEdge: nil)
check(screenOnly == visible.height - ScreenFitStack.screenMargin,
      "a host that does not grow downward (the popover) is capped by the display only")
check(ScreenFitStack.cap(visible: CGRect(x: 0, y: 0, width: 800, height: 200), topEdge: nil)
        == ScreenFitStack.minSurfaceHeight,
      "an absurdly short display gets the floor, not a slit")

section("with a top edge: whichever rule is tighter")

// Top edge high on the screen: the room below it exceeds the screen rule, so nothing changes.
check(ScreenFitStack.cap(visible: visible, topEdge: visible.maxY) == screenOnly,
      "a surface at the top of the display is capped exactly as before")
// The incident's geometry: content top 552pt above the bottom of the visible area.
let low = ScreenFitStack.cap(visible: visible, topEdge: visible.minY + 552)
check(low == 552, "a surface placed low may only be as tall as the room beneath its own top edge")
check(low < screenOnly, "and that is tighter than the screen rule, which is the whole point")
// Dragged so low that the room is less than a usable surface: the floor wins, and the caller
// accepts that the overflow (and the clamp) comes back down there.
check(ScreenFitStack.cap(visible: visible, topEdge: visible.minY + 100) == ScreenFitStack.minSurfaceHeight,
      "below the floor the floor wins, deliberately")

section("the cap never exceeds the room below the top edge")

// The invariant the fix is really about, swept rather than sampled: for every position where the
// room is between the floor and the screen rule, the cap fits under the top edge.
var overflow = 0
for offset in stride(from: Int(ScreenFitStack.minSurfaceHeight), through: Int(visible.height), by: 7) {
    let topEdge = visible.minY + CGFloat(offset)
    if ScreenFitStack.cap(visible: visible, topEdge: topEdge) > topEdge - visible.minY { overflow += 1 }
}
check(overflow == 0, "no position between the floor and the top of the display can overflow downward")

section("a screen whose origin is not zero")

// A second display sits at a negative origin in this rig; the arithmetic is relative, never
// absolute, and reading `minY` as "zero" would silently uncap every surface on such a screen.
let offscreen = CGRect(x: 2048, y: -288, width: 2560, height: 1400)
check(ScreenFitStack.cap(visible: offscreen, topEdge: offscreen.minY + 500) == 500,
      "the room is measured from the display's own bottom, not from y = 0")

print(failures == 0 ? "\nAll screen-fit cap tests passed." : "\n\(failures) screen-fit cap test(s) failed.")
exit(failures == 0 ? 0 : 1)
