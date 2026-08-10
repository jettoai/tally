import CoreGraphics
import Foundation

// Assertion harness for the press that has to answer two questions (Tally/Core/PointerIntent.swift),
// compiled against the real source. Two halves, because the rule lives in two places that a build
// cannot check against each other: the arithmetic is here, and the event loop that consumes it is
// read off `DragOrTapArea` below - AppKit windows and a real pointer cannot be driven from here.

var failures = 0
func check(_ name: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL"): \(name)")
    if !condition { failures += 1 }
}

let down = CGPoint(x: 100, y: 100)
func moved(_ dx: CGFloat, _ dy: CGFloat, threshold: CGFloat = 4) -> PointerIntent {
    PointerIntent.dragOrTap(from: down, to: CGPoint(x: down.x + dx, y: down.y + dy),
                            threshold: threshold)
}

// 1. The two ends. A press that never moved is the click every user makes, and one that crossed the
//    slop is a hand that set out to move the window.
check("a press that did not travel at all is a tap", moved(0, 0) == .tap)
check("a press well past the slop is a drag", moved(40, 0) == .drag)

// 2. The boundary, stated in both directions because it is the one place the rule can be off by a
//    hair without anything looking wrong: exactly at the threshold is still the control's click,
//    and the first distance beyond it is a move.
check("exactly at the threshold is still a tap", moved(4, 0) == .tap)
check("a hair past the threshold is a drag", moved(4.001, 0) == .drag)
check("a hair inside it is a tap", moved(3.999, 0) == .tap)

// 3. Direction cannot matter. The panel is dragged left and up as often as right and down, and a
//    comparison written on the raw difference rather than its size answers only half of them.
check("the same distance leftwards is a drag", moved(-40, 0) == .drag)
check("upwards too", moved(0, -40) == .drag)
check("and the boundary holds on the negative side", moved(-4, 0) == .tap)
check("…including the first step past it", moved(-4.001, 0) == .drag)

// 4. Diagonals, which is what makes the measurement radial rather than per-axis: 3 points on each
//    axis is over 4 points of travel, and a per-axis reading would have called it a click.
check("a diagonal shorter on each axis than the slop can still be a drag", moved(3, 3) == .drag)
check("…while a genuinely small diagonal is not", moved(2, 2) == .tap)
// The exact diagonal boundary, chosen so no rounding is involved: 3-4-5.
check("a diagonal landing exactly on the threshold is a tap", moved(3, 4, threshold: 5) == .tap)
check("…and one point further out is a drag", moved(3, 4.001, threshold: 5) == .drag)

// 5. The default the app actually runs on. The value is a judgement, the range is not: below about
//    3 points a shaking hand loses its click, above about 5 a deliberate nudge is swallowed as one.
check("the shipped slop is within the system's own range (\(PointerIntent.slop)pt)",
      PointerIntent.slop >= 3 && PointerIntent.slop <= 5)

// 6. The event loop around it. Assertions from here down match CODE, never comments - a suite that
//    matched raw source would go green on a doc comment that merely described the rule (the window
//    anchor suite was caught by exactly that, 2026-08-05).
func code(of path: String) -> String {
    let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
        // Only a `//` outside a string literal starts a comment.
        var quotes = 0
        for index in line.indices {
            if line[index] == "\"" { quotes += 1 }
            if quotes % 2 == 0, line[index] == "/", line.index(after: index) < line.endIndex,
               line[line.index(after: index)] == "/" {
                return line[..<index]
            }
        }
        return line
    }.joined(separator: "\n")
}

/// Every Swift file in the app, RECURSIVELY: the two sweeps below both ask "and nowhere else",
/// which a listing of one directory's own files cannot answer - it would go green on the thing it
/// forbids reappearing in any folder that did not exist when it was written. The floor on the count
/// is what says the sweep is reaching the tree at all: an enumerator that returned nothing would
/// otherwise pass every "nowhere else" check by having nowhere to look.
let allSources = (FileManager.default.enumerator(atPath: "Tally")?
    .compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") }.map { "Tally/\($0)" } ?? []).sorted()
check("the sweep reaches the whole source tree (\(allSources.count) files)",
      allSources.count >= 100
          && allSources.contains("Tally/MenuBar/PinnedPanelController.swift")
          && allSources.contains("Tally/Views/PopoverRootView.swift")
          && allSources.contains("Tally/Core/PointerIntent.swift"))

let panelSource = code(of: "Tally/MenuBar/PinnedPanelController.swift")
guard let classStart = panelSource.range(of: "final class HandleView"),
      let handleStart = panelSource.range(of: "override func mouseDown(with event: NSEvent) {",
                                          range: classStart.upperBound ..< panelSource.endIndex),
      let handleEnd = panelSource.range(of: "\n        }\n", range: handleStart.upperBound ..< panelSource.endIndex)
else {
    check("the drag-or-tap handle's mouse-down was found to read", false)
    exit(1)
}
let handle = String(panelSource[handleStart.upperBound ..< handleEnd.lowerBound])

// 6a. It asks THIS rule rather than restating a distance of its own, which is the only reason the
//     arithmetic above describes what the panel does.
check("the handle decides with the rule this suite tests",
      handle.contains("PointerIntent.dragOrTap(from: start, to: next.locationInWindow)"))

// 6b. Exclusive by structure. Each outcome is followed by a return inside the peek loop, so no
//     press can move the window and also fire the control it started on.
let upBranch: String = {
    guard let start = handle.range(of: "if next.type == .leftMouseUp {"),
          let end = handle.range(of: "\n                }", range: start.upperBound ..< handle.endIndex)
    else { return "" }
    return String(handle[start.upperBound ..< end.lowerBound])
}()
check("a mouse-up ends the gesture whichever way it was read",
      upBranch.contains("if intent == .tap { onTap() }") && upBranch.contains("return"))
check("and starting a drag ends it too",
      handle.contains("PanelDrag.carry { panel.performDrag(with: event) }")
          && handle.range(of: "performDrag(with: event) }\n                    return") != nil)
check("the only two things a press can do are the drag and the tap",
      handle.components(separatedBy: "onTap()").count == 2
          && handle.components(separatedBy: "performDrag").count == 3)

// 6b2. And the region with NO click to protect does not wait to find out: it moves the window on
//      the mouse-down itself. A threshold there would be a handle that starts late, which is the
//      one thing a titlebar never does.
check("a region with nothing to click moves the window at once",
      handle.contains("guard let onTap else { return PanelDrag.carry { panel.performDrag(with: event) } }"))
check("…and both entrances hand `performDrag` the event that started the gesture",
      handle.components(separatedBy: "performDrag(with: event)").count == 3)

// 6c. No clock anywhere in it. A press-and-hold reading would make every click on the tab switch
//     wait to find out whether it was one, which is the requirement this whole overlay was built
//     under.
for clock in ["asyncAfter", "Timer", "sleep", "until:", "Date()", "timestamp"] {
    check("the decision is distance only, never `\(clock)`", !handle.contains(clock))
}

// 6d. And it is the pinned panel's rule only. Off that window the overlay is not in the pointer's
//     way at all, which is what leaves the same control in the popover with its plain behaviour.
check("the overlay is transparent to the pointer on any other window",
      panelSource.contains("window is PinnedUsagePanel ? super.hitTest(point) : nil"))
check("…and the mouse-down declines the same way",
      handle.contains("guard let panel = window as? PinnedUsagePanel else"))

// 7. Who asks for it. The switch in the header's centre is the hole this fills; the shared control's
//    other copies sit in draggable space already and must not start eating presses.
let pickerSource = code(of: "Tally/Views/NeutralSegmentedPicker.swift")
check("the segmented control offers the behaviour, off by default",
      pickerSource.contains("var dragsWindow = false")
          && pickerSource.contains(".windowDragOrTap(enabled: dragsWindow) { selection = option }"))
let askers = allSources.filter { code(of: $0).contains("dragsWindow: true") }
check("only the panel header's switch asks for it (found: \(askers))",
      askers == ["Tally/Views/PopoverHeaderView.swift"])

// 8. The refresh button, the other control standing in the strip. Its two entrances run the one
//    implementation, so the press that turned out to be a click cannot refresh a different tab than
//    the button does.
let headerSource = code(of: "Tally/Views/PopoverHeaderView.swift")
// Three mentions and no more: the one declaration, the button's action, and the overlay's tap.
check("the refresh button and its drag overlay share one action",
      headerSource.contains("private func startRefresh() {")
          && headerSource.components(separatedBy: "startRefresh()").count == 4)
check("…and that action carries the disabled guard itself",
      headerSource.range(of: "func startRefresh() {\n        guard !isRefreshing else { return }") != nil)

// 9. THE MECHANISM IS AN OVERLAY, EVERYWHERE. A drag layer mounted behind SwiftUI content is never
//    sent the press (measured 2026-08-07 on the dev instance: the wordmark, the clock, the strip's
//    empty run and the panel background all carried one and all four were dead; the tab switch,
//    which carried the same view on TOP, moved every time). The old background-mounted view is gone
//    rather than left beside this one, so no surface can be given the dead half by mistake.
//    Over the whole tree (`allSources`), not the view folder: the mounting being forbidden is a
//    line anyone can write in any file, so "nowhere else" has to be asked of everywhere.
let mounted = allSources.filter {
    let text = code(of: $0)
    return text.contains("background(WindowDragArea") || text.contains("background(DragOrTapArea")
}
check("no surface mounts a drag layer behind its content (found: \(mounted))", mounted.isEmpty)
let retired = allSources.filter { code(of: $0).contains("struct WindowDragArea") }
check("…and the retired background-only view is not still around (found: \(retired))", retired.isEmpty)
let panelFile = code(of: "Tally/MenuBar/PinnedPanelController.swift")
for surface in ["func windowDragSurface() -> some View {\n        overlay(DragOrTapArea(onTap: nil))",
                "func windowDragOrTap(enabled: Bool = true, _ onTap: @escaping () -> Void) -> some View {\n        overlay {"] {
    check("the grab areas are applied as overlays", panelFile.contains(surface))
}

// 10. The header names its grab areas one region at a time: the wordmark run, the slack beside the
//     switch, the clock cluster. Counted, because the failure this replaces was a row that read as
//     one continuous handle and answered on none of it.
// Four of them: the brand run, the slack before the switch, the clock cluster, and the strip that
// covers whichever centring pad the switch is owed (`dragPad`). The count is the assertion because
// the failure being repaired was a row that looked like one continuous handle and answered on none
// of it - a region dropped from this set is exactly that failure coming back.
check("the header gives every non-interactive run of the row a grab area",
      headerSource.components(separatedBy: ".windowDragSurface()").count == 5
          && headerSource.contains("private func dragPad(_ width: CGFloat) -> some View")
          && headerSource.contains(".overlay(alignment: .leading) { dragPad(centreOffset.leading) }"))
check("…and the update badge keeps its click while joining them",
      headerSource.contains(".windowDragOrTap { startInstall() }"))
// The badge now has a state its click must NOT land in: while an install is being carried out it
// is disabled, and pressing it again would put a second check on top of the running one. So it is
// held to what the refresh button two blocks up is held to, and for the same mechanical reason -
// `.disabled` stops a SwiftUI control, and the tap entrance is an AppKit view laid over it that
// nothing stops on the caller's behalf. A refusal written on the button alone is a refusal the
// drag overlay does not make, which is the shape the badge used to be wrong in.
check("…through the one implementation its button also presses",
      headerSource.contains("private func startInstall() {")
          && headerSource.components(separatedBy: "startInstall()").count == 4)
check("…and that action carries the busy guard itself, where both entrances meet it",
      headerSource.range(of: "func startInstall() {\n        guard UpdateAvailability.shared.busy == nil else { return }") != nil)

// 11. A drag that is under way, and the reason it cannot be answered by a flag alone: AppKit carries
//     the window after `performDrag` returns (measured: the call's entry and exit share a
//     timestamp), so the release has to be watched for. A watcher that was ever lost would leave a
//     bare flag saying "dragging" forever, and the surface would stop re-reading its height cap for
//     the life of the process - so the button is asked too, which makes the wrong answer expire.
check("a started drag with the button still down is under way",
      PanelCarry.inProgress(started: true, buttonsDown: 1))
check("…and the same drag is over the moment the button is up",
      !PanelCarry.inProgress(started: true, buttonsDown: 0))
check("nothing started is never under way, whatever the pointer is doing",
      !PanelCarry.inProgress(started: false, buttonsDown: 1)
          && !PanelCarry.inProgress(started: false, buttonsDown: 0))
check("a right-button press is not this gesture",
      !PanelCarry.inProgress(started: true, buttonsDown: 2))
check("…while the left one held with others still is",
      PanelCarry.inProgress(started: true, buttonsDown: 3))

// 12. What the span is FOR: the surface re-reads its own height cap from its own top edge on every
//     move, so a panel carried down its display was resized under the hand on the way (measured
//     2026-08-07: 532 -> 476 -> 417 -> 347 -> 320 in one drag, while the window server was moving
//     the window). The cap is skipped during the carry and re-read once at the end - BOTH halves,
//     because skipping without the re-read is a panel that keeps a cap its new position never had.
let rootSource = code(of: "Tally/Views/PopoverRootView.swift")
check("the height cap is not re-read while the panel is being carried",
      rootSource.contains("guard !PanelDrag.isActive else { return }"))
check("…and is re-read once when the hand lets go",
      rootSource.contains("for: PanelDrag.ended)) { _ in")
          && rootSource.contains("refreshScreenCap()"))
check("both ways into a drag announce the carry",
      panelSource.components(separatedBy: "PanelDrag.carry { panel.performDrag(with: event) }").count == 3)
check("the release watcher stops itself rather than running on",
      panelSource.contains("release?.invalidate()") && panelSource.contains("release = nil"))
check("and the flag itself defers to the pure predicate",
      panelSource.contains("PanelCarry.inProgress(started: carrying,"))

// 13. The empty panel, which is the layout with no cards to name regions between: the first-fetch
//     skeletons, "no accounts" and "all providers off" each draw a screenful of quiet space, and
//     none of it answered a press - a panel pinned in one of those states was held by its header
//     alone (found reviewing 2ee0ebb). Both halves are asserted, because covering the copy while
//     leaving the button under the same plain overlay would trade one dead region for a dead
//     control.
let emptySource = code(of: "Tally/Views/EmptyStateView.swift")
check("the empty panel's quiet space is a grab area",
      emptySource.components(separatedBy: ".windowDragSurface()").count == 4)
check("…including the first-fetch skeletons, which have nothing to click at all",
      emptySource.range(of: "SkeletonCardsView()\n                .windowDragSurface()") != nil)
check("…and its one button keeps its click while joining the grab",
      emptySource.contains(".windowDragOrTap { openSettings() }")
          && emptySource.components(separatedBy: "openSettings()").count == 4)

print(failures == 0 ? "\nAll drag-or-tap tests passed." : "\n\(failures) drag-or-tap test(s) FAILED.")
exit(failures == 0 ? 0 : 1)
