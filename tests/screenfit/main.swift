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

section("whole points only (the ratchet's source)")

// The cap and the flexible child's height both have to be whole points. The panel's own numbers
// from the incident: a cap of exactly 480 with the old arithmetic reported 480.00000000000006,
// AppKit rounded the frame up to 481, the top edge rose a point, and the cap - measured from that
// edge - grew a point with it. Once per expand, forever.
check(ScreenFitStack.cap(visible: CGRect(x: 0, y: 0, width: 2048, height: 1120.4), topEdge: nil)
        == (1120.4 - ScreenFitStack.screenMargin).rounded(.down),
      "a fractional display height still yields a whole-point cap")
check(ScreenFitStack.cap(visible: visible, topEdge: visible.minY + 479.6) == 479,
      "a fractional top edge is floored, never rounded up into the room it does not have")

// The residue itself, with child heights that are not exact in binary (a real surface's never
// are: they come out of text metrics). The old form took the excess off the CHILD, which means
// summing a dozen such numbers and subtracting; the new one subtracts from the cap and floors.
let others: [CGFloat] = [22.2, 0.5, 186.7, 0.5, 32.8]
let othersTotal = others.reduce(0, +)
let flexibleIdeal: CGFloat = 418.1
let cap: CGFloat = 480

let naive = flexibleIdeal - ((othersTotal + flexibleIdeal) - cap)
let naiveTotal = othersTotal + naive
check(naiveTotal > cap,
      "the old arithmetic overshoots the cap by a residue (\(naiveTotal - cap)), which a window frame rounds up into a whole point")

let fixed = ScreenFitStack.flexibleHeight(others: othersTotal, maxHeight: cap)
let fixedTotal = othersTotal + fixed
check(fixed == fixed.rounded(.down),
      "the flexible child is given WHOLE points, because a window frame can only hold whole points")
check(fixedTotal <= cap, "subtracting from the cap and flooring lands at or below it, never above")
check(cap - fixedTotal < 1, "and not so far below that the surface gives up a visible strip")

// Swept rather than sampled: no fractional layout with room above the floor may exceed the cap.
var overshoots = 0
for step in 0 ..< 400 {
    let fixedPart = 240 + CGFloat(step) * 0.37
    guard cap - fixedPart >= 120 else { continue }
    if fixedPart + ScreenFitStack.flexibleHeight(others: fixedPart, maxHeight: cap) > cap { overshoots += 1 }
}
check(overshoots == 0, "no fractional split of the fixed rows can push the total past the cap")

// The one case that is ALLOWED to overshoot, and does so by design: a cap so tight that the
// flexible child would be a slit, where the floor wins and the surface overflows instead.
check(440 + ScreenFitStack.flexibleHeight(others: 440, maxHeight: 480) > 480,
      "the minimum flexible height still wins over the cap, which is the documented overflow case")

section("a size difference worth acting on")

check(!ResizeAnchor.needsResize(from: CGSize(width: 504, height: 480),
                                to: CGSize(width: 504, height: 480.00000000000006)),
      "the residue that started the ratchet is not a resize")
check(ResizeAnchor.needsResize(from: CGSize(width: 504, height: 480),
                               to: CGSize(width: 504, height: 481)),
      "a whole point still is")
check(ResizeAnchor.needsResize(from: CGSize(width: 504, height: 480),
                               to: CGSize(width: 520, height: 480)),
      "and so is a width change on its own")

section("who may be top-anchored in its host")

// `TopAnchored` reports whatever size it is proposed, which is what stops `NSHostingView` centring
// the page while the window catches up - and which is also a fixpoint at ANY size. A host that
// takes its size from this view's own layout constraints therefore keeps whatever degenerate size
// it started with: the dashboard window opened 1x32 instead of 504x548 (measured 2026-08-05).
//
// The hosts that are safe are exactly the ones that size themselves from what the surface REPORTS,
// which they say by passing an `onContentSize`. Pinned here because nothing about the collapse is
// visible in a build, a type-check or any other test: the window simply comes up empty.
let rootSource = (try? String(contentsOfFile: "Tally/Views/PopoverRootView.swift",
                              encoding: .utf8)) ?? ""
check(rootSource.contains(".topAnchoredInHost(enabled: onContentSize != nil)"),
      "the surface is top-anchored only where the host sizes itself from what it reports")

for (name, path) in [("pinned panel", "Tally/MenuBar/PinnedPanelController.swift"),
                     ("menu-bar popover", "Tally/MenuBar/StatusItemController.swift")] {
    let source = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    check(source.contains("onContentSize:") && source.contains("sizingOptions = []"),
          "the \(name) is one of those hosts: it reports-and-sizes, with no second authority")
}

print(failures == 0 ? "\nAll screen-fit cap tests passed." : "\n\(failures) screen-fit cap test(s) failed.")
exit(failures == 0 ? 0 : 1)
