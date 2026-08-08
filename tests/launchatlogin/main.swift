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

print(failures == 0 ? "\nAll launch-at-login checks passed."
                    : "\n\(failures) launch-at-login check(s) failed.")
exit(failures == 0 ? 0 : 1)
