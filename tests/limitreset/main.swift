import Foundation

// Runner for the weekly session-limit reset suite: the counter, the one assertion helper and the
// exit code. Every fixture and every assertion lives in limitresetchecks.swift, which is where
// this repo keeps them (tests/**/*checks.swift) and what keeps this file a runner.

var failures = 0
func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

runLimitResetChecks()

print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
