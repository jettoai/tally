import Foundation
import ServiceManagement

// Assertion harness for the "Start at login" row's reading of macOS (Tally/Core/
// LaunchAtLoginState.swift, Tally/Core/LaunchAtLoginService.swift), compiled against the real
// source. Nothing here registers a login item or reads the machine's own: what is pinned is the
// mapping and the sentences, which is exactly the half that can be wrong while the app builds
// clean and the switch flips.
//
// Three things are held down. The four statuses macOS can answer with stay four distinct states
// (collapsing them into on/off is what produces a switch that flips and does nothing). The
// denied state reads as REGISTERED and carries the one instruction that settles it. And an error
// is only dropped where the state on screen already says what happened.

var failures = 0
func check(_ name: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL"): \(name)")
    if !condition { failures += 1 }
}

let statuses: [SMAppService.Status] = [.enabled, .notRegistered, .requiresApproval, .notFound]

// MARK: - the status mapping

check("enabled maps to enabled",
      LaunchAtLoginService.state(for: .enabled) == .enabled)
check("notRegistered maps to notRegistered",
      LaunchAtLoginService.state(for: .notRegistered) == .notRegistered)
check("requiresApproval maps to requiresApproval",
      LaunchAtLoginService.state(for: .requiresApproval) == .requiresApproval)
check("notFound maps to notFound",
      LaunchAtLoginService.state(for: .notFound) == .notFound)

// The regression this file exists for: any two of macOS's answers arriving at one state means the
// row cannot tell them apart, and the pair that would go first is enabled/requiresApproval.
check("every status macOS can answer with keeps a state of its own",
      Set(statuses.map { LaunchAtLoginService.state(for: $0) }).count == statuses.count)
check("no real status is mistaken for the unrecognized one",
      !statuses.map { LaunchAtLoginService.state(for: $0) }.contains(.unknown))

// MARK: - where the switch sits

check("an allowed login item reads as registered", LaunchAtLoginState.enabled.isRegistered)
// The registration is real; it is the consent that is missing. Drawn as "off" it would invite the
// one gesture that cannot grant it.
check("a login item awaiting consent still reads as registered",
      LaunchAtLoginState.requiresApproval.isRegistered)
check("no login item reads as off", !LaunchAtLoginState.notRegistered.isRegistered)
check("a login item macOS cannot find reads as off", !LaunchAtLoginState.notFound.isRegistered)
check("an unrecognized state reads as off", !LaunchAtLoginState.unknown.isRegistered)

// MARK: - what each state says

check("an allowed login item says nothing extra", LaunchAtLoginState.enabled.noticeKey == nil)
check("no login item says nothing extra", LaunchAtLoginState.notRegistered.noticeKey == nil)

let spoken: [LaunchAtLoginState] = [.requiresApproval, .notFound, .unknown]
check("each state that needs explaining has a sentence",
      spoken.allSatisfy { $0.noticeKey != nil })
check("and none of them shares another's sentence",
      Set(spoken.compactMap(\.noticeKey)).count == spoken.count)

// The denied state is the one the user can be stuck in, so its sentence has to name the place it
// is settled rather than describe the problem.
check("the denied state names Login Items in System Settings",
      LaunchAtLoginState.requiresApproval.noticeKey?.contains("Login Items in System Settings")
        == true)
check("the missing state says where to put the app",
      LaunchAtLoginState.notFound.noticeKey?.contains("Applications folder") == true)

// MARK: - the shortcut into System Settings

check("every state that explains itself also offers the way there",
      spoken.allSatisfy(\.offersSystemSettings))
check("a settled login item offers no shortcut",
      !LaunchAtLoginState.enabled.offersSystemSettings
        && !LaunchAtLoginState.notRegistered.offersSystemSettings)

// MARK: - which thrown errors reach the user

// register() on an existing registration throws kSMErrorAlreadyRegistered, unregister() on a
// missing one throws kSMErrorJobNotFound. Both name the state the user just asked for.
check("asking for on and getting it is not an error to report",
      !LaunchAtLoginState.surfacesFailure(after: .enabled, wanted: true))
check("asking for off and getting it is not an error to report",
      !LaunchAtLoginState.surfacesFailure(after: .notRegistered, wanted: false))
// The denial: register() throws, and requiresApproval explains it better than the error does.
check("a denied registration is explained by the state, not by the error",
      !LaunchAtLoginState.surfacesFailure(after: .requiresApproval, wanted: true))

// Everything else has to reach the user, or the switch flips with nothing behind it. A refused
// code signature lands here.
check("a registration that did not happen still reports why",
      LaunchAtLoginState.surfacesFailure(after: .notRegistered, wanted: true))
check("an unregister that left it needing approval still reports why",
      LaunchAtLoginState.surfacesFailure(after: .requiresApproval, wanted: false))
check("a registration macOS could not find still reports why",
      LaunchAtLoginState.surfacesFailure(after: .notFound, wanted: true))
check("an unregister that left it enabled still reports why",
      LaunchAtLoginState.surfacesFailure(after: .enabled, wanted: false))
check("an unrecognized outcome always reports why",
      LaunchAtLoginState.surfacesFailure(after: .unknown, wanted: true)
        && LaunchAtLoginState.surfacesFailure(after: .unknown, wanted: false))

// MARK: - a failure outliving what caused it

// The row's two paths, spelled the way it runs them: an attempt records what was asked and what
// threw, and BOTH the attempt and every later re-read put that record through the one filter. The
// composition is what is pinned here, not just the filter, because the defect being fixed was a
// refresh path that never asked.
func afterAttempt(wanted: Bool, threw message: String?,
                  settlingAt state: LaunchAtLoginState) -> LaunchAtLoginFailure? {
    let recorded = message.map { LaunchAtLoginFailure(wanted: wanted, message: $0) }
    return LaunchAtLoginState.surviving(recorded, beside: state)
}

func afterRefresh(_ shown: LaunchAtLoginFailure?,
                  nowAt state: LaunchAtLoginState) -> LaunchAtLoginFailure? {
    LaunchAtLoginState.surviving(shown, beside: state)
}

// A signature macOS refuses: the switch does not move and the row has to say why.
let refused = afterAttempt(wanted: true, threw: "code signature refused", settlingAt: .notRegistered)
check("a failed switch-on says why the moment it fails",
      refused?.message == "code signature refused")

// Stepping away and back changes nothing on its own. This is the half that must NOT be cleared:
// the answer to the gesture still stands, because the state still contradicts what was asked.
check("stepping away and back leaves a failure that still stands",
      afterRefresh(refused, nowAt: .notRegistered) == refused)

// ... and this is the defect: settle it under Login Items, come back, and the old line must go.
check("a failure goes once coming back finds the login item enabled",
      afterRefresh(refused, nowAt: .enabled) == nil)
check("a failure goes once coming back finds it merely awaiting consent",
      afterRefresh(refused, nowAt: .requiresApproval) == nil)

// The contradiction stated directly, over every failure a row can be holding: "on, enabled" and
// "that did not work" must never be on screen together, whichever way the switch was pushed.
let anyFailure = [LaunchAtLoginFailure(wanted: true, message: "x"),
                  LaunchAtLoginFailure(wanted: false, message: "x")]
check("nothing ever shows a failure beside a login item that is enabled and was wanted on",
      afterRefresh(anyFailure[0], nowAt: .enabled) == nil)
check("nor beside an absent login item that was wanted off",
      afterRefresh(anyFailure[1], nowAt: .notRegistered) == nil)

// The mirror: a switch-OFF that failed is still unexplained while the login item is there.
let stuckOn = afterAttempt(wanted: false, threw: "could not unregister", settlingAt: .enabled)
check("a failed switch-off says why while the login item is still there", stuckOn != nil)
check("and goes once coming back finds it gone", afterRefresh(stuckOn, nowAt: .notRegistered) == nil)

check("no failure recorded shows nothing", afterAttempt(wanted: true, threw: nil,
                                                        settlingAt: .notRegistered) == nil)
check("refreshing with nothing to show stays nothing", afterRefresh(nil, nowAt: .enabled) == nil)
// Refreshes are frequent (every activation); a survivor must not decay across them.
check("a surviving failure is unchanged by refreshing again",
      afterRefresh(afterRefresh(refused, nowAt: .notRegistered), nowAt: .notRegistered) == refused)
check("and keeps its message verbatim", afterRefresh(refused, nowAt: .notFound)?.message
        == "code signature refused")

// MARK: - the dev state preview, and its total absence from a normal launch

// The leak question first, because it is the one that matters to somebody who never asked for a
// preview. Two independent conditions produce "no fixture", and the row treats no fixture as "run
// the code that was there before the flag existed".
check("a shipped build that is not showing demo data cannot preview at all",
      !LoginItemPreview.previewable(isDemo: false, isDev: false))
check("the dev build can", LoginItemPreview.previewable(isDemo: false, isDev: true))
check("and so can a demo launch, the rest of the capture family's rule",
      LoginItemPreview.previewable(isDemo: true, isDev: false))
check("no flag previews nothing", LoginItemPreview.fixture(named: nil) == nil)
check("an empty flag previews nothing", LoginItemPreview.fixture(named: "") == nil)
// A guess here would put fiction in front of somebody who thought they asked for something else.
check("a word this build does not know previews nothing, rather than guessing",
      LoginItemPreview.fixture(named: "enabledish") == nil)
// The leak property stated over every name that WOULD work, rather than over one sample: a normal
// build previews nothing no matter what the flag says, so the row runs the code it ran before.
check("a shipped build previews nothing whatever the flag says",
      LoginItemPreview.names.allSatisfy {
          LoginItemPreview.fixture(named: $0, isDemo: false, isDev: false) == nil })
check("and the same names do reach a fixture once the build is allowed to preview",
      LoginItemPreview.names.allSatisfy {
          LoginItemPreview.fixture(named: $0, isDemo: false, isDev: true) != nil })
// This process is neither, so the property that reads the real inputs is shut too.
check("and with the gate shut, the flag is not even consulted", LoginItemPreview.fixture == nil)

// Every state the row can draw is reachable by name, which is what makes the flag worth having.
check("each state has a name that reaches it",
      LoginItemPreview.names.compactMap { LoginItemPreview.fixture(named: $0)?.state }
        == [.enabled, .notRegistered, .requiresApproval, .notFound, .unknown])
check("and the names survive being typed back in another shape",
      LoginItemPreview.fixture(named: "requires-approval")?.state == .requiresApproval
        && LoginItemPreview.fixture(named: "NotFound")?.state == .notFound)

// The held-back walk: the loop the row's notice says cannot be won has to be losable more than
// once, or the preview teaches the opposite of what ships.
let held = LoginItemPreview.fixture(named: "requiresApproval")!
check("preview: it starts held back", held.state == .requiresApproval)
let (heldOff, _) = LoginItemPreview.pressing(false, on: held)
check("preview: switching it off does release it", heldOff.state == .notRegistered)
let (heldAgain, heldError) = LoginItemPreview.pressing(true, on: heldOff)
check("preview: switching it back on is refused again", heldAgain.state == .requiresApproval)
check("preview: and the refusal is explained by the state, not by an error line",
      LaunchAtLoginState.surviving(heldError, beside: heldAgain.state) == nil)

// The failure walk, which is the behaviour fixed this round: press, fail, press again, then go and
// settle it. Each step runs the shipping filter, not a preview-only one.
let broken = LoginItemPreview.fixture(named: "notFound")!
let (stillBroken, brokeError) = LoginItemPreview.pressing(true, on: broken)
let brokeShown = LaunchAtLoginState.surviving(brokeError, beside: stillBroken.state)
check("preview: a refused registration leaves the row where it was",
      stillBroken.state == .notFound)
check("preview: and puts a failure on screen", brokeShown != nil)
let (stillBroken2, brokeError2) = LoginItemPreview.pressing(true, on: stillBroken)
check("preview: pressing again keeps the failure there",
      LaunchAtLoginState.surviving(brokeError2, beside: stillBroken2.state) != nil)
let settled = LoginItemPreview.settledInSystemSettings
check("preview: the trip to Login Items comes back enabled", settled.state == .enabled)
check("preview: and the failure that outlived its cause is gone",
      LaunchAtLoginState.surviving(brokeShown, beside: settled.state) == nil)

// The healthy world still behaves like a switch, or the other four are being compared to nothing.
let healthy = LoginItemPreview.fixture(named: "notRegistered")!
let (turnedOn, noError) = LoginItemPreview.pressing(true, on: healthy)
check("preview: an unobstructed switch simply goes on", turnedOn.state == .enabled)
check("preview: with nothing to report", noError == nil)
check("preview: and comes back off", LoginItemPreview.pressing(false, on: turnedOn).fixture.state
        == .notRegistered)

// A fixture is an obstruction plus a registration, and no combination of the two may name a state
// the real API could not report.
check("no fixture can describe a state macOS never reports",
      LoginItemPreview.names.compactMap { LoginItemPreview.fixture(named: $0) }
        .allSatisfy { statuses.map { LaunchAtLoginService.state(for: $0) }
            .contains($0.state) || $0.state == .unknown })

print(failures == 0 ? "\nAll launch-at-login checks passed."
                    : "\n\(failures) launch-at-login check(s) failed.")
exit(failures == 0 ? 0 : 1)
