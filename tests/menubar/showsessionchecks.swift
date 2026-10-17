import Foundation

// The inner 5-hour ring's wiring, checked as text (the settings store and the status item do not
// compile into this harness, same technique as section 13 of main.swift).
func showSessionChecks() {
    let settingsSource = readSource("Tally/Stores/SettingsStore.swift")
    // The inner 5-hour ring is OFF until chosen, read and written in one place each, and a flip
    // repaints the strip (AppKit, so it needs the nudge).
    expect(settingsSource.contains("menuBarShowSession = defaults.bool(forKey: \"menuBarShowSession\")"),
           "the inner ring is off for an unset preference")
    expect(settingsSource.components(separatedBy: "forKey: \"menuBarShowSession\"").count == 3,
           "the inner ring key is read in one place and written in one place")
    expect(settingsSource.contains("""
        didSet {
            UserDefaults.standard.set(menuBarShowSession, forKey: "menuBarShowSession")
            UsageStore.shared.onChange?()
"""),
           "…and flipping it repaints the strip")
    // The renderer memoizes on a signature: the switch and the inner figures must be in it, or a
    // flip keeps returning the old image.
    let stripSource = readSource("Tally/MenuBar/MenuBarStrip.swift")
    expect(stripSource.contains("(showSession ? \"s\" : \"\")")
           && stripSource.contains("ring.innerFraction ?? -1")
           && stripSource.contains("ring.innerSeverity.rawValue"),
           "the strip image's cache key carries the inner ring switch and both inner figures")
    let buttonSource = readSource("Tally/MenuBar/StatusItemButton.swift")
    expect(buttonSource.contains("note: note,\n                                  showSession: showSession)")
           && buttonSource.contains("stripImage(segments, waiting: blocked > 0,\n                                                              showSession: showSession)")
           && buttonSource.contains("SettingsStore.shared.menuBarShowSession"),
           "the status item feeds the setting to the renderer and to the face it compares")
}
