import AppKit

// CONTENT TOP-LEFT: the anchor the popover, the pinned panel and the dashboard window hand the view
// to each other by (`NSWindow.contentTopLeft`, WindowPlacement.swift). Real windows, never shown:
// the geometry is AppKit's own, so it is the one part of this suite that cannot be done on paper.
// `contentRect(forFrameRect:)` already answers in screen coordinates; converting it to the screen a
// second time counts the frame origin twice (31e4cd8, a borderless panel at (100, 200) read as
// standing at (200, 700)).
@MainActor func checkContentTopLeft() {
    _ = NSApplication.shared
    let frame = NSRect(x: 100, y: 200, width: 480, height: 300)

    let panel = NSPanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: true)
    panel.setFrame(frame, display: false)
    let panelTop = panel.contentTopLeft
    check("a borderless panel's content starts at its frame's top-left (\(panelTop))",
          near(panelTop.x, 100) && near(panelTop.y, 500))

    let titled = NSWindow(contentRect: frame, styleMask: [.titled, .closable],
                          backing: .buffered, defer: true)
    titled.setFrame(frame, display: false)
    let content = titled.contentRect(forFrameRect: titled.frame)
    let titledTop = titled.contentTopLeft
    check("a titled window's content starts below its titlebar, at the content rect's top (\(titledTop))",
          near(titledTop.x, content.minX) && near(titledTop.y, content.maxY)
              && titledTop.y < titled.frame.maxY)

    // The inverse lands where it was asked to, which is what makes a hand-off land in place.
    titled.setContentTopLeft(panelTop)
    check("putting a titled window's content where the panel's was lands it there",
          near(titled.contentTopLeft.x, panelTop.x) && near(titled.contentTopLeft.y, panelTop.y))
}
