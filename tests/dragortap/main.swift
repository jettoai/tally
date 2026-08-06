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
      handle.contains("panel.performDrag(with: event)")
          && handle.range(of: "performDrag(with: event)\n                    return") != nil)
check("the only two things a press can do are the drag and the tap",
      handle.components(separatedBy: "onTap()").count == 2
          && handle.components(separatedBy: "performDrag").count == 2)

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
let askers = ((try? FileManager.default.contentsOfDirectory(atPath: "Tally/Views")) ?? [])
    .filter { $0.hasSuffix(".swift") && code(of: "Tally/Views/\($0)").contains("dragsWindow: true") }
check("only the panel header's switch asks for it (found: \(askers))",
      askers == ["PopoverHeaderView.swift"])

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

print(failures == 0 ? "\nAll drag-or-tap tests passed." : "\n\(failures) drag-or-tap test(s) FAILED.")
exit(failures == 0 ? 0 : 1)
