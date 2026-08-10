import Foundation

// WHEN EACH OF AN ACCOUNT'S WINDOWS COMES BACK, which is the other half of what its percentage
// means: "session 12%" is a reason to move a conversation if the window refreshes in four hours and
// no reason at all if it refreshes in six minutes, and choosing between accounts on these numbers is
// the whole point of the list they are drawn in.
//
// ONE FORMATTER, TWO SURFACES (`mcpAccountWindows`): the panel's rows and the elicitation form's
// options are the same string, so the fallback a person gets when Tally is not running cannot become
// the poorer surface twice over.

func runAccountWindowChecks() {
    var first = switchAccount("claude:.claude", label: "Claude", home: "/tmp/a")
    first.modelRemaining = 54
    first.sessionRemaining = 86
    first.weeklyRemaining = 47
    first.modelWindowName = "Fable"

    let readAt = Date(timeIntervalSince1970: 1_800_000_000)
    var timed = first
    timed.sessionResetsAt = readAt.addingTimeInterval(2 * 3600 + 14 * 60)
    timed.weeklyResetsAt = readAt.addingTimeInterval(5 * 86_400 + 7 * 3600)
    // The flagship window on the weekly boundary, which is what every real account has (measured
    // across a five-account fleet, 2026-08-10).
    timed.modelResetsAt = timed.weeklyResetsAt
    check("each window says when it comes back, in the countdown every other surface uses",
          mcpAccountWindows(timed, now: readAt)
              == "fable 54% · session 86% (2h14m) · weekly 47% (5d7h)")
    // …INCLUDING WHEN THE TWO BOUNDARIES ARE NOT THE SAME INSTANT, which is how this went wrong on
    // a live panel: a real snapshot mints the flagship and weekly resets in separate readings, so
    // they land seconds apart, and an equality test on the dates let the row say "(3d13h)" twice.
    // What a person sees repeated is the WORDS.
    var drifted = timed
    // Half an hour off the boundary, so the forty seconds below are a drift rather than a rounding
    // step: at exactly 5d7h the shorter reading really is a different duration ("5d6h").
    drifted.weeklyResetsAt = readAt.addingTimeInterval(5 * 86_400 + 7 * 3600 + 1800)
    drifted.modelResetsAt = drifted.weeklyResetsAt?.addingTimeInterval(-40)
    check("a flagship reset that merely lands seconds off the weekly one is still said once",
          mcpAccountWindows(drifted, now: readAt)
              == "fable 54% · session 86% (2h14m) · weekly 47% (5d7h)")
    // ONE COUNTDOWN, SAID ONCE. Spelling the flagship's as well would put the same duration twice in
    // one line, and the one that keeps it is the last window that reads that way.
    var ownWindow = timed
    ownWindow.modelResetsAt = readAt.addingTimeInterval(3600)
    check("…and a flagship window resetting on its own says so, since that is news",
          mcpAccountWindows(ownWindow, now: readAt)
              == "fable 54% (1h) · session 86% (2h14m) · weekly 47% (5d7h)")
    // A reset in the past is a snapshot that was read a while ago (`snapshotMaxAge`); "(0m)" on a
    // window that came back while nobody was looking says less than nothing.
    var expired = timed
    expired.sessionResetsAt = readAt.addingTimeInterval(-60)
    check("a window that has already come back is not counted down",
          mcpAccountWindows(expired, now: readAt)
              == "fable 54% · session 86% · weekly 47% (5d7h)")
    check("an account whose snapshot carries no reset times reads exactly as it always did",
          mcpAccountWindows(first, now: readAt) == "fable 54% · session 86% · weekly 47%")
    // THE FORM GETS IT TOO, because it is the same string: the fallback list is what a person sees
    // when Tally is not there to draw the panel, and it must not be the poorer surface twice over.
    //
    // ANCHORED ON THE CLOCK THIS RUN IS ON, not on the fixed instant above: neither of the two
    // surfaces takes a `now` (they are called with a live snapshot and nothing else), so the only
    // way to assert they carry the countdown is to give the fixture a reset that is in the future
    // whenever this suite runs. The formatter's own output is the expected value, and it is checked
    // for a countdown first so a formatter that stopped producing one could not pass this vacuously.
    var live = first
    live.sessionResetsAt = Date().addingTimeInterval(3600)
    live.weeklyResetsAt = Date().addingTimeInterval(4 * 86_400)
    let windows = mcpAccountWindows(live)
    let ranked = switchFleetRows(accounts: [live], provider: "claude", current: nil)
    check("the countdown really is in what the formatter produced for this fixture",
          windows.contains("session 86% (") && windows.contains("weekly 47% ("))
    check("the fallback form's options carry the countdowns with them",
          mcpAccountOptions(accounts: [live], ranked: ranked).first?.label.contains(windows) == true)
    check("…and so do the rows the panel draws, from the one formatter",
          mcpAccountPickRows([live], ranked: ranked).first?.detail == windows)
}
