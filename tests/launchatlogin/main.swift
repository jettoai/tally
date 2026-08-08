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

check("every state that explains itself is one settled in System Settings",
      spoken.allSatisfy(\.needsSystemSettings))
check("a settled login item is not",
      !LaunchAtLoginState.enabled.needsSystemSettings
        && !LaunchAtLoginState.notRegistered.needsSystemSettings)

// The button is a rule over BOTH lines the row can be showing, not over the state alone.
func offersWayOut(_ state: LaunchAtLoginState, _ failure: LaunchAtLoginFailure?) -> Bool {
    LaunchAtLoginState.offersSystemSettings(for: state, failure: failure)
}
let anyFailureShown = LaunchAtLoginFailure(wanted: true, message: "code signature refused")

check("each state that explains itself still offers the button on its own",
      spoken.allSatisfy { offersWayOut($0, nil) })
check("and a quiet state on its own still offers nothing",
      !offersWayOut(.enabled, nil) && !offersWayOut(.notRegistered, nil))

// The gap this closed: a refused signature leaves an ordinary `.notRegistered` behind, so the row
// said "that failed" and gave the user nowhere to go.
check("a failure beside a state with nothing to say still offers the button",
      offersWayOut(.notRegistered, anyFailureShown))
check("and so does one beside an enabled login item",
      offersWayOut(.enabled, anyFailureShown))
check("a failure never takes the button away from a state that had it",
      spoken.allSatisfy { offersWayOut($0, anyFailureShown) })
// Stated whole: of every state, the button is absent only when there is nothing on screen to
// explain, so no line can ever be shown without a way to act on it.
let allStates: [LaunchAtLoginState] = [.enabled, .notRegistered, .requiresApproval, .notFound,
                                       .unknown]
check("nothing is ever said without somewhere to go with it",
      allStates.allSatisfy { state in
          [anyFailureShown, nil].allSatisfy { failure in
              let saysSomething = state.noticeKey != nil || failure != nil
              return offersWayOut(state, failure) == saysSomething
          } })

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

// MARK: - how a launch opens the Settings window

// Both halves of this were shipped wrong once: the window opened on Accounts, where the previewed
// row is not, and it pulled itself to the front out of a background launch.
let previewOpening = LoginItemPreview.settingsOpening(
    previewing: LoginItemPreview.fixture(named: "notFound"))
let summonOpening = LoginItemPreview.settingsOpening(previewing: nil)

check("a preview opens Settings on the pane the previewed row lives on",
      previewOpening.onLaunchPane)
check("an ordinary summon still opens where it always did",
      !summonOpening.onLaunchPane)
// Every state has to land there, not just the one sampled above: a reviewer walking the five
// values must not have to find the row again on some of them.
check("every previewable state opens on that same pane",
      LoginItemPreview.names.allSatisfy {
          LoginItemPreview.settingsOpening(previewing: LoginItemPreview.fixture(named: $0))
              .onLaunchPane })

// The foreground half of this used to live in `SettingsOpening` too, back when the login-item
// preview was the only capture flag. It belongs to the whole family now (see below), so what is
// left here is the pane, stated whole so a second difference cannot appear without this failing.
check("a preview differs from a summon in the pane it opens on, and nothing else",
      previewOpening == LoginItemPreview.SettingsOpening(onLaunchPane: true)
        && summonOpening == LoginItemPreview.SettingsOpening(onLaunchPane: false))
// This process previews nothing, so the property that reads the real inputs is the summon answer.
check("previewing nothing gets the ordinary opening",
      LoginItemPreview.settingsOpening == summonOpening)

// MARK: - the one uninvited registration

typealias Plan = LaunchAtLoginDefault.Plan

func plan(applied: Bool = false, unshipped: Bool = false, demo: Bool = false) -> Plan {
    LaunchAtLoginDefault.plan(alreadyApplied: applied, isUnshipped: unshipped, isDemo: demo)
}

// A machine nobody has configured, running an installed build.
check("an unconfigured install registers itself once", plan() == .attemptThenRecord)

// The property the whole design exists for: turning it off must stay off. Nothing in the world
// tells "never asked" from "asked and declined", so only the record does.
check("and never again, whatever the user did with the switch afterwards",
      plan(applied: true) == .skip)

// The write gate, with no exception: these builds would take the installed app's login item over
// and point the next login at a directory that is about to stop existing.
check("a build nobody installed never registers", plan(unshipped: true) == .skip)
check("nor does a launch showing demo fixtures", plan(demo: true) == .skip)
check("and neither of those is overridden by the machine being unconfigured",
      plan(applied: false, unshipped: true) == .skip
        && plan(applied: false, demo: true) == .skip)

// Stated over the whole input space, so a fourth condition cannot be added without deciding what
// it means: of the eight combinations, exactly one registers.
let bools = [false, true]
let attempting = bools.flatMap { a in bools.flatMap { u in bools.map { d in
    (applied: a, unshipped: u, demo: d, plan: plan(applied: a, unshipped: u, demo: d))
} } }.filter { $0.plan == .attemptThenRecord }
check("exactly one of the eight input combinations registers",
      attempting.count == 1)
check("and it is the unconfigured, installed, non-demo one",
      attempting.first.map { !$0.applied && !$0.unshipped && !$0.demo } == true)

// The imperative half, with both effects injected. No login item is anywhere near this.
final class Effects {
    var registered = 0
    var marked = 0
    var throwing: Error?
    func register() throws { registered += 1; if let throwing { throw throwing } }
    func mark() { marked += 1 }
}
struct StubError: LocalizedError { var errorDescription: String? { "code signature refused" } }

let ok = Effects()
let okFailure = LaunchAtLoginDefault.apply(.attemptThenRecord, register: { try ok.register() },
                                           markApplied: { ok.mark() })
check("attempting registers exactly once", ok.registered == 1)
check("and records that it did", ok.marked == 1)
check("with nothing to report", okFailure == nil)

let skipped = Effects()
let skipFailure = LaunchAtLoginDefault.apply(.skip, register: { try skipped.register() },
                                             markApplied: { skipped.mark() })
check("skipping registers nothing", skipped.registered == 0)
check("and records nothing, leaving the attempt for a proper install", skipped.marked == 0)
check("and has nothing to report", skipFailure == nil)

let failed = Effects()
failed.throwing = StubError()
let thrownFailure = LaunchAtLoginDefault.apply(.attemptThenRecord, register: { try failed.register() },
                                               markApplied: { failed.mark() })
check("a registration that threw is still recorded, so it is not retried forever",
      failed.marked == 1)
// Not swallowed: it comes back as the same kind of record a user's own failed press produces, so
// the row shows it and expires it by the one rule.
check("and the error comes back rather than being swallowed",
      thrownFailure?.message == "code signature refused")
check("as an attempt that wanted it on", thrownFailure?.wanted == true)
check("which the row will drop once the state agrees with it anyway",
      LaunchAtLoginState.surviving(thrownFailure, beside: .enabled) == nil)
check("and keep while it does not",
      LaunchAtLoginState.surviving(thrownFailure, beside: .notRegistered) == thrownFailure)

// MARK: - one answer about the foreground, for every window a launch puts up by itself

// The first version of this rule lived on the Settings window alone, which left it true only while
// the OTHER window happened not to restore. Both restores now ask this one question.
check("a preview launch takes the foreground from nobody",
      !LoginItemPreview.mayTakeForeground(previewing: LoginItemPreview.fixture(named: "notFound")))
check("an ordinary launch is free to come forward",
      LoginItemPreview.mayTakeForeground(previewing: nil))
check("and no previewable state is an exception",
      LoginItemPreview.names.allSatisfy {
          !LoginItemPreview.mayTakeForeground(previewing: LoginItemPreview.fixture(named: $0)) })
check("this process, carrying no capture flag, may come forward",
      CaptureLaunch.launchMayTakeForeground)

// MARK: - and the whole capture family gets that same answer

// Scoping this to the login-item preview was the defect: every flag here exists so something can
// be looked at, and a window restore was pulling the app forward on all the others. One cell per
// member, because a family rule that is only spot-checked is how the first one got missed.
for key in CaptureLaunch.backgroundKeys {
    check("a launch carrying \(key) does not come forward on its own",
          !CaptureLaunch.mayTakeForeground(activeKeys: [key]))
}
// The membership itself, written out rather than derived from the list under test. The grid above
// is generated FROM `backgroundKeys`, so dropping a member silently drops its own check with it:
// shrinking the family back to one flag left that loop green over a single cell. Spelled out, both
// directions are pinned, a member going missing and one appearing without anybody deciding to.
let expectedFamily: Set<String> = [
    "TallyDemoData", "TallyAppearance", "TallyCardStyle",
    "TallyPanelCapture", "TallyTooltipPreview", "TallyEmptyStatePreview",
    "TallyTokenGraphPreview", "TallyUpdateChip", "TallyPickPreview", "TallyLoginItemPreview",
    "TallyStripSnapshot",
    "TallyDryNotifyTest", "TallyResetHintTest", "TallyLoginExpiryTest",
]
check("the family is exactly these fourteen flags",
      Set(CaptureLaunch.backgroundKeys) == expectedFamily)
check("and it carries no duplicates",
      CaptureLaunch.backgroundKeys.count == expectedFamily.count)
check("a launch carrying none of them does",
      CaptureLaunch.mayTakeForeground(activeKeys: []))
check("and one carrying several is answered once, the same way",
      !CaptureLaunch.mayTakeForeground(
          activeKeys: ["TallyDemoData", "TallyPanelCapture", "TallyAppearance"]))

// The membership that makes a preview launch a background one. Without it the login-item rule
// above would be a second, drifting copy of the family's.
check("the login-item state preview is a member of the family",
      CaptureLaunch.backgroundKeys.contains(CaptureLaunch.loginItemPreview))

// Deliberately NOT members, each for its own stated reason. Asserted so the choices are visible
// rather than inferred from an absence.
check("the interactive renewal hook is not a member, it exists to be driven",
      CaptureLaunch.mayTakeForeground(activeKeys: ["TallyRenewLoginCLI"]))
check("nor are the two modifiers, which show nothing on their own",
      CaptureLaunch.mayTakeForeground(
          activeKeys: ["TallyUpdateChipReady", "TallyTokenGraphHover"]))
// ... but riding along with their parent changes nothing: the parent is what is asked about.
check("a modifier alongside its flag is still a background launch",
      !CaptureLaunch.mayTakeForeground(
          activeKeys: ["TallyUpdateChip", "TallyUpdateChipReady"]))

// How a flag counts as carried. Launch arguments land in defaults as strings of every shape.
check("a flag with any value is carried", CaptureLaunch.isActive(rawValue: "fleet")
        && CaptureLaunch.isActive(rawValue: "YES") && CaptureLaunch.isActive(rawValue: "0.15.0"))
check("an absent flag is not", !CaptureLaunch.isActive(rawValue: nil))
check("an explicitly switched-off one is not, so a saved command can keep it",
      !CaptureLaunch.isActive(rawValue: "NO") && !CaptureLaunch.isActive(rawValue: "false")
        && !CaptureLaunch.isActive(rawValue: ""))

// MARK: - the startup failure is consumed, not merely unpersisted

var report = LaunchAtLoginAttemptReport(
    LaunchAtLoginFailure(wanted: true, message: "code signature refused"))
check("a startup failure is handed to whoever asks first",
      report.take()?.message == "code signature refused")
check("and is gone for the next reader", report.take() == nil)
check("and stays gone however many times it is asked", report.take() == nil)

var nothingWrong = LaunchAtLoginAttemptReport(nil)
check("a launch with nothing to report reports nothing", nothingWrong.take() == nil)

// MARK: - and only a row the user can actually see may consume it

// What the row does: collect only while its pane is the one on screen, and only outside a preview.
func collect(_ report: inout LaunchAtLoginAttemptReport,
             visible: Bool, previewing: Bool = false) -> LaunchAtLoginFailure? {
    guard LaunchAtLoginAttemptReport.collectible(visible: visible, previewing: previewing)
    else { return nil }
    return report.take()
}

check("a row on the pane being shown may collect",
      LaunchAtLoginAttemptReport.collectible(visible: true, previewing: false))
check("a row on a pane nobody opened may not",
      !LaunchAtLoginAttemptReport.collectible(visible: false, previewing: false))
check("and a preview never collects, shown or not",
      !LaunchAtLoginAttemptReport.collectible(visible: true, previewing: true)
        && !LaunchAtLoginAttemptReport.collectible(visible: false, previewing: true))

// The scenario this missed: Settings opens on Accounts, and the Launch pane is BUILT anyway,
// because every pane lives in the one stack. Its lifecycle hooks run. It must not eat the report.
var pending = LaunchAtLoginAttemptReport(
    LaunchAtLoginFailure(wanted: true, message: "code signature refused"))
check("a built but hidden pane takes nothing", collect(&pending, visible: false) == nil)
check("and a second hidden pane takes nothing either", collect(&pending, visible: false) == nil)
// The user switches to Launch. Now it is theirs to read.
check("the report survives for the pane the user opens",
      collect(&pending, visible: true)?.message == "code signature refused")
// The other end, which must keep standing: rebuilt while visible, it does not say it twice.
check("and is not said a second time on a rebuilt visible pane",
      collect(&pending, visible: true) == nil)

// Both ends together, stated as the invariant: the report reaches exactly one reader, and that
// reader is one the user could see.
var once = LaunchAtLoginAttemptReport(LaunchAtLoginFailure(wanted: true, message: "x"))
let readers = [false, false, true, true, false, true].map { collect(&once, visible: $0) }
check("exactly one reader ever gets it", readers.compactMap { $0 }.count == 1)
check("and it is the first visible one",
      readers.firstIndex(where: { $0 != nil }) == 2)

// The path that produced the defect, end to end. Switching the app's language re-keys SettingsView,
// so the row is built again and asks again; by then the user has turned the switch on and back off
// deliberately, and the state contradicts what that old attempt wanted.
var launchReport = LaunchAtLoginAttemptReport(
    LaunchAtLoginFailure(wanted: true, message: "code signature refused"))
let firstBuild = LaunchAtLoginState.surviving(launchReport.take(), beside: .notRegistered)
check("the first Settings view says the startup registration failed", firstBuild != nil)
let afterRebuild = LaunchAtLoginState.surviving(launchReport.take(), beside: .notRegistered)
check("a rebuilt view does not tell the user their own switch-off failed", afterRebuild == nil)
// And the filter is not what saves it: at this state `surviving` would happily have kept it.
check("which the expiry rule alone would NOT have prevented",
      LaunchAtLoginState.surviving(firstBuild, beside: .notRegistered) != nil)

print(failures == 0 ? "\nAll launch-at-login checks passed."
                    : "\n\(failures) launch-at-login check(s) failed.")
exit(failures == 0 ? 0 : 1)
