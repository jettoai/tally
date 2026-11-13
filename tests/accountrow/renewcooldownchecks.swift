import Foundation

/// B-4530: the cooldown that refuses a repeat "Renew login" and the notice sentence about a session
/// that keeps its own mark. Its own file because the account-row checks sit at the test-file size cap.
func runRenewCooldownChecks() {
    var failed = 0
    func check(_ name: String, _ condition: Bool) {
        if condition { print("PASS \(name)") } else { failed += 1; print("FAIL \(name)") }
    }
    let renewed = "codex:.codex2"
    let other = "claude:.claude"

    // MARK: - A repeat press right behind a success is refused (RenewalCooldown, B-4530)

    // Two browser sign-ins 27 seconds apart on an account that was never signed out: the first one
    // worked, the mark beside it did not go away (it belongs to a session), and the button still said
    // "renew". Settling cannot cover it, because only a signed-out account settles.
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    var cooldown = RenewalCooldown()
    check("an account that never renewed is not cooling down",
          cooldown.isCoolingDown(renewed, now: t0) == false)
    cooldown.succeeded(renewed, at: t0)
    check("a second renewal 27 seconds after the first is refused",
          cooldown.isCoolingDown(renewed, now: t0.addingTimeInterval(27)))
    check("it is still refused just inside the window",
          cooldown.isCoolingDown(renewed, now: t0.addingTimeInterval(RenewalCooldown.window - 1)))
    check("and allowed again once the window has passed",
          cooldown.isCoolingDown(renewed, now: t0.addingTimeInterval(RenewalCooldown.window)) == false)
    check("the refusal is per account", cooldown.isCoolingDown(other, now: t0.addingTimeInterval(1)) == false)
    check("the window is a minute, not a settle", RenewalCooldown.window == 60)

    // MARK: - The "renewed" notice says what it did not fix (B-4530)

    check("with a session incident on the account the notice carries the extra sentence",
          AccountSignIn.renewedBody("Signed in.", sessionNote: "Session note.", hasSessionIncident: true)
              == "Signed in. Session note.")
    check("without one the notice is unchanged",
          AccountSignIn.renewedBody("Signed in.", sessionNote: "Session note.", hasSessionIncident: false)
              == "Signed in.")

    if failed > 0 { print("\(failed) FAILURES"); exit(1) }
}
