import Foundation

// Shared scaffolding for the update-feed checks. Lives apart from the checks themselves because
// two files use it: main.swift and userchoice.swift. Nothing here asserts anything.

var failures = 0
func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

let sonoma = [14, 6, 0]

func release(_ build: Int, _ display: String, minimum: String? = nil) -> FeedRelease {
    FeedRelease(build: build, display: display, minimumSystemVersion: minimum)
}

let epoch = Date(timeIntervalSince1970: 1_000_000)
func fresh(watching: Bool = true, autoInstall: Bool = true) -> UpdateState {
    var state = UpdateState(installedBuild: 510)
    state.watching = watching
    state.installsAutomatically = autoInstall
    return state
}

@discardableResult
func send(_ state: inout UpdateState, _ event: UpdateEvent,
          at moment: Date = epoch) -> [UpdateAction] {
    UpdateReducer.reduce(&state, event, now: moment)
}

let v521 = release(521, "0.40.0")
let v531 = release(531, "0.41.0")
