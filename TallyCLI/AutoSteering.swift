import Foundation

// WHETHER TALLY MAY CHOOSE AN ACCOUNT FOR A SESSION IT IS ALREADY RUNNING.
//
// The app's launch policy has three modes and the first of them is described to the user, in the
// store that writes it and on the two Settings rows that set it, as "observe only: Tally never
// steers a launch (a dashboard, nothing more)". Until this file existed that promise was kept in
// exactly ONE place - the PATH shim (`runLaunchDir`, LaunchDir.swift) - and not at all by the
// supervisor. A session started with `tally claude` on an `off` fleet was handed off on a cap,
// rebalanced when its account went dry, reopened on a sibling when its window closed and moved at a
// `tally session clear`: four account decisions nobody asked for, made by the mode that promises
// none.
//
// WHAT `off` DOES NOT TURN OFF, and the line is the one `runLaunch` (main.swift) already drew for
// the launch itself: typing `tally claude` IS an explicit ask to pick, so the launch pick still
// happens under every mode. What `off` forbids is every LATER account decision - the ones made
// minutes or hours after that command, by a supervisor rather than by a person. Nor does it stand a
// supervisor down: the status line, the board, `tally session send`, `tally session clear`, the
// model follow, the drift monitor and the self-update all carry on. It is about one verb.
//
// AND IT IS NOT ABOUT INSTRUCTIONS THE USER TYPED. `tally account <name>` and a pin moved in the
// panel say where this conversation runs, and they are honoured under every mode. Two paths let an
// instruction about something ELSE re-pick an account as a side effect - the launch-default follow
// choosing a better home for a newly declared model, and `tally model` moving to an account that
// can serve the pair - and under `off` those still land, on the account the session is already on.
// That is not a new behaviour invented here: it is exactly what both of them already do for a
// session that is pinned, which is why the gate is folded into the reading each of them already
// takes rather than added beside it.
//
// EVERY WAY A RUNNING SESSION CAN CHANGE ACCOUNT, and what stops each one under `off`. This is the
// population the gate had to be checked against, and it is written down because a gate spread over
// nine movers is a gate whose coverage nobody can state from any one of them:
//
//   reason           where it is built              stopped under `off` by
//   ---------------  -----------------------------  --------------------------------------------
//   cap              CapDetection.applyCapHandoff   `capRecoveryAction` answers `.waitSteeringOff`
//   degraded         ModelDegradation rescue        the `steering` term in its own guard
//   rebalance        WindowRepick/Rebalance         `rebalanceAllowedForSession`
//   rebalance (ride) Reload's repick closure        the same, via `rebalanceMove`
//   window-repick    WindowRepick.windowRepickMove  its own guard
//   clear-boundary   SessionClear's landing move    the same, via `windowRepickMove`
//   turn-boundary    TurnBoundaryMove               `turnBoundaryAllowedForSession`
//   follow           FollowAdoption's re-pick       reads as pinned: adopt here, do not move
//   model            SessionModel's re-pick         the same, folded into `accountPinned`
//
//   And the relaunches that are NOT account moves, left alone on purpose because `off` has nothing
//   to say about them: `cap-fallback` and `fallback` (same account, different model), `safeguard`,
//   `reload`, `self-update`, and the two the user asked for by name, `switch` and `pin`.
//
// ONE READING PER TICK, taken from the APP's policy rather than from the session's or the project's.
// `effectivePolicy` turns a project account into `manual` and `sessionPolicy` turns a session pin
// into `manual`, so a policy read through either of them can no longer say `off` at all; asking the
// app's own document is what makes the answer independent of what is pinned over it. Same reading,
// same reason, as the shim's (`runLaunchDir`).

/// The launch-policy mode that means "observe only".
///
/// Named rather than spelled at each gate, on the same terms as `windowClearCommand` next door:
/// the value travels between the app's `LaunchPolicyStore.Mode` and this CLI as a bare string, and
/// three literals is how one of them comes to mean something slightly different from the others.
let launchModeOff = "off"

/// Whether Tally may pick an account for a session it is already supervising.
///
/// Takes the mode rather than the policy so the whole of it is one comparison and every caller is
/// obliged to say WHICH policy it read: the answer is only right for the app's own
/// (`launchPolicy(provider.id)`), and a caller that handed it a policy with a pin folded in would
/// get `true` for a fleet set to observe only.
func supervisorMaySteerAccounts(appMode: String) -> Bool { appMode != launchModeOff }
