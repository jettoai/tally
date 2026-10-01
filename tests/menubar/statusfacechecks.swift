import Foundation

/// The status item skips an unchanged face (Sentry TALLY-6) and applies any difference.
func statusFaceChecks() {
    let seg = MenuBarSegment(providerID: "claude", lines: ["12%", "40%"], dimmed: false, badge: 1)
    let face = StatusItemFace(segments: [seg], blocked: 0, tooltip: "tip")
    expect(StatusItemFace(segments: [seg], blocked: 0, tooltip: "tip") == face, "an identical face is skipped")
    var changed: [StatusItemFace] = []
    for edit: (inout StatusItemFace) -> Void in [
        { $0.segments = [] }, { $0.blocked = 1 }, { $0.tooltip = nil }, { $0.tooltip = "other" },
        { $0.segments[0].providerID = "codex" }, { $0.segments[0].lines = ["13%", "40%"] },
        { $0.segments[0].dimmed = true }, { $0.segments[0].badge = 2 }, { $0.segments[0].tag = "P" },
    ] { var f = face; edit(&f); changed.append(f) }
    expect(changed.allSatisfy { $0 != face },
           "every field of the face, and of each segment, makes it apply again")
}
