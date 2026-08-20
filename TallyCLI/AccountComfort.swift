import Foundation

// The nearly-dry gate that runs in front of every account pick (the CLI's `best`, the
// supervisor's cap handoff, and the app's smart-pick badge all call it, so the badge keeps
// predicting the launch).
//
// `smartScore` ranks accounts by a RATE, remaining% divided by the hours until that window
// resets. That is the right question for "how hard can this account be pushed", but a rate has no
// floor: an almost empty window whose reset is close divides a tiny remainder by a tiny number of
// hours and outranks a healthy account whose reset is days away. Measured live on
// 2026-07-25T11:10Z with opus declared as the primary model (so the fable window was correctly
// excluded from both accounts):
//
//   Claude    session  75% resets in   1.48h -> 50.525 %/h
//             weekly   37% resets in 125.82h ->  0.294 %/h   account score 0.294
//   Claude 2  session 100% resets in   5.00h -> 20.000 %/h
//             weekly    1% resets in   0.80h ->  1.248 %/h   account score 1.248  <- chosen
//
// Claude 2 cleared both hysteresis gates with 1% of its weekly window left, and a session
// launched there caps within minutes.
//
// A plain "never pick an account below N%" floor would be wrong, though: 9% that resets in three
// minutes is a FULL window three minutes from now, and taking it IS the better launch. So the
// floor is applied to an EFFECTIVE remaining that counts an imminent reset as the refill it is
// about to become.

/// The line the shipped dry-pool alert already draws (`DryPoolLogic.lowFraction` is 0.05): one
/// definition of "nearly dry" across the product.
let nearlyDryPercent = 5.0

/// Under this, waiting the reset out costs the user less than a relaunch, which is visible and
/// reloads the conversation context, so quota arriving that soon counts as already there.
let imminentResetGrace: TimeInterval = 10 * 60

/// One window as the gate sees it. Callers build these from the windows the declared primary
/// model actually spends (`ratedWindows` on the CLI side, its mirror in the app), so the gate
/// never re-decides which windows count.
struct ComfortWindow {
    let remaining: Double
    let resetsAt: Date?
    /// Percentage points of this window its owner keeps for THEMSELVES (Tally's reserve, set per
    /// account in Settings and read by the CLI from `~/.tally/state.json`). Zero for every account
    /// nobody reserved anything on, which is every account until somebody says otherwise - so this
    /// field changes nothing at all on a fleet that does not use the feature. Zero as well on every
    /// window but the weekly all-models one, whatever the account reserved: the builders of these
    /// (`ratedWindows` and its app mirror) apply the reserve's scope, so this gate never has to ask
    /// which window it is weighing (Tally/Core/AccountReserve.swift).
    ///
    /// A `var` with a default rather than a `let`, because the memberwise initializer only carries
    /// a default for the first kind: the app builds these too (LaunchPolicyStore) and must go on
    /// compiling against `ComfortWindow(remaining:resetsAt:)`.
    var reserve: Double = 0
}

/// What the window is worth FOR TALLY'S OWN PURPOSES: one resetting within the grace counts as
/// fully refilled, because it will be by the time it matters (a reset time already in the past
/// counts the same way - the snapshot simply has not caught up yet), and whatever its owner
/// reserved is not Tally's to spend.
///
/// THE RESERVE IS SUBTRACTED AFTER the imminent-reset reading rather than before it, which is what
/// keeps one sentence true of both: this answers "how much of this window may an automatic decision
/// spend", and a window about to refill offers its owner a full one minus the part they kept. Doing
/// it the other way round would let a reserve survive the refill it is measured against.
///
/// EVERY GATE IN THE PRODUCT READS THIS ONE FUNCTION, which is the whole of how a reserve reaches
/// them: the nearly-dry line, the spent test, the window a claim keys on, the knock's threshold.
/// Nothing that a PERSON reads comes through here - the percentages in `windowReason` and the rate
/// in `pickReason` are the provider's own numbers - so a reserve never makes Tally quote a figure
/// the provider did not publish.
func effectiveRemaining(_ window: ComfortWindow, now: Date) -> Double {
    let refilled = window.resetsAt.map { $0.timeIntervalSince(now) <= imminentResetGrace } ?? false
    return (refilled ? 100 : window.remaining) - window.reserve
}

/// An account is comfortable when its TIGHTEST counted window, effective remaining, is strictly
/// above the nearly-dry line. Reporting no counted windows is not proof of comfort, and such an
/// account stays selectable through the all-drained fallback below.
func isComfortable(_ windows: [ComfortWindow], now: Date) -> Bool {
    guard let tightest = windows.map({ effectiveRemaining($0, now: now) }).min() else { return false }
    return tightest > nearlyDryPercent
}

// The gate has two policies, and the difference between them is the point: what an EMPTY result
// means depends on whether a session already exists. They are deliberately two functions rather
// than one with a flag, so neither call site can be read as the other and quietly unified.

/// The HANDOFF policy: comfortable candidates only, and no target when there are none. The session
/// already exists, so moving it to a spent account buys a few minutes and costs a visible restart
/// that reloads the conversation; waiting for a sibling to free up is strictly better. Callers are
/// expected to treat the empty result as "wait", not as "give up".
func requiringComfortable<T>(_ candidates: [T], now: Date,
                             windows: (T) -> [ComfortWindow]) -> [T] {
    candidates.filter { isComfortable(windows($0), now: now) }
}

/// The LAUNCH policy: comfortable candidates when there are any (so the rate ordering below never
/// has to compare a healthy account against a nearly dry one), and otherwise the field kept whole.
/// The fallback mirrors what the launcher already does when quarantine empties the field: there is
/// no session yet, and launching on a thin account beats stranding the user with none at all.
func preferringComfortable<T>(_ candidates: [T], now: Date,
                              windows: (T) -> [ComfortWindow]) -> [T] {
    let comfortable = requiringComfortable(candidates, now: now, windows: windows)
    return comfortable.isEmpty ? candidates : comfortable
}
