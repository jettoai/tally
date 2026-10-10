import AppKit

// THE USAGE PANEL FLOATS ONLY WHILE PINNED (B-1056). A dev launch with `-TallyPanelCapture` showed
// the panel without pinning it and it still floated over every other app, because the panel was
// built at `.floating` once and nothing ever read the pin. The level is now one function of the pin
// (`PanelPinLevel`), applied on every way the panel comes on screen and on unpin.
@MainActor func checkPanelPinLevel() {
    _ = NSApplication.shared
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    PanelPinLevel.apply(to: panel, pinned: false)
    check("an unpinned panel (a capture launch) stands at the normal level", panel.level == .normal)
    PanelPinLevel.apply(to: panel, pinned: true)
    check("pinning it raises it to floating", panel.level == .floating)
    PanelPinLevel.apply(to: panel, pinned: false)
    check("unpinning it puts it back to the normal level", panel.level == .normal)
    PanelPinLevel.apply(to: panel, pinned: false)
    check("showing it again while unpinned keeps it normal", panel.level == .normal)

    // And the panel controller asks that function on every path that puts the panel up, with no
    // level of its own: a literal `.floating` there is the bug this suite exists for.
    let source = code(of: "Tally/MenuBar/PinnedPanelController.swift")
    func body(_ signature: String) -> String { functionBody(signature, in: source) }
    let apply = "applyPinLevel()"
    check("the panel controller never sets a level of its own",
          !source.contains("level = .floating") && !source.contains("level = .normal"))
    check("…its level is the pin setting's answer",
          body("func applyPinLevel()").contains(
              "PanelPinLevel.apply(to: panel, pinned: SettingsStore.shared.isUsagePanelPinned)"))
    check("…asked every time the panel is shown (launch restore, capture launch, pin hand-off)",
          body("func show(atTopLeft topLeft: CGPoint?, showing page: SurfacePage? = nil)").contains(apply))
    check("…and every time the status item summons it",
          body("func summon(onScreenOf anchor: CGRect?)").contains(apply))
    let commands = code(of: "Tally/MenuBar/StatusItemCommands.swift")
    check("unpinning re-reads the level on the panel that is up",
          functionBody("static func unpin()", in: commands).contains("PinnedPanelController.shared.applyPinLevel()"))
}

/// The text between a function's signature and its closing brace at four-space indent.
func functionBody(_ signature: String, in source: String) -> String {
    guard let start = source.range(of: signature),
          let end = source.range(of: "\n    }\n", range: start.upperBound ..< source.endIndex)
    else { return "" }
    return String(source[start.upperBound ..< end.lowerBound])
}
