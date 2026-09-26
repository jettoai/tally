import Foundation
import Observation

/// WHAT A RELOAD COULD DO RIGHT NOW, as the footer tooltip and the Settings row draw it.
///
/// Read off the main thread by the roster's own scan (SessionRosterScan.swift) and published here,
/// so a view body reads a stored value and nothing else. The reading lists the supervisor registry,
/// opens each session's marker files and, with an empty registry, walks the whole process table; it
/// ran on every render of the panel footer and held the menu bar for seconds on a loaded machine
/// (Sentry TALLY-10, 2026-09-26). The reload button itself still reads the state at the press
/// (`ReloadAction.presentConfirm`), because that answer has to be the truth at the click.
@MainActor
@Observable
final class ReloadReadinessStore {
    static let shared = ReloadReadinessStore()

    /// Nil until the first scan lands, which the surfaces read as the ordinary wording.
    private(set) var readiness: ReloadReadiness?

    private init() {}

    /// Assign only on a change, so a board standing still does not re-render every surface.
    func publish(_ next: ReloadReadiness) {
        guard next != readiness else { return }
        readiness = next
    }
}
