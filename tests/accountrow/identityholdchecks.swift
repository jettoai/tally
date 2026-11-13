import Foundation

/// B-4530: what the identity memory does after a login that landed as somebody else. Its own file
/// because the account-row checks sit at the test-file size cap.
func runIdentityHoldChecks() {
    var failed = 0
    func check(_ name: String, _ condition: Bool) {
        if condition { print("PASS \(name)") } else { failed += 1; print("FAIL \(name)") }
    }

    // A login that landed as somebody else (B-4530): the memory keeps who the account was MEANT to be,
    // however many rounds read the wrong account out of the home afterwards.
    var held = AccountIdentityMemory()
    held.remember(accountID: "claude:.claude4", email: "a@example.com")
    check("holding an address is a change", held.hold(accountID: "claude:.claude4", email: "a@example.com"))
    check("a round naming the account that landed instead is not written down",
          held.remember(accountID: "claude:.claude4", email: "b@example.com") == false
              && held.email("claude:.claude4") == "a@example.com")
    check("and the next attempt is held to the original address",
          held.expectedEmail("claude:.claude4") == "a@example.com")
    check("a round reading the original address back settles it and persists",
          held.remember(accountID: "claude:.claude4", email: "a@example.com")
              && held.expectedEmail("claude:.claude4") == "a@example.com"
              && held.remember(accountID: "claude:.claude4", email: "b@example.com"))
    var unnamed = AccountIdentityMemory()
    unnamed.hold(accountID: "claude:.claude5", email: "a@example.com")
    check("an account with nothing remembered is still held to the address it was meant for",
          unnamed.email("claude:.claude5") == nil && unnamed.expectedEmail("claude:.claude5") == "a@example.com"
              && unnamed.remember(accountID: "claude:.claude5", email: "b@example.com") == false)
    check("keeping the other account releases the hold",
          unnamed.release(accountID: "claude:.claude5")
              && unnamed.remember(accountID: "claude:.claude5", email: "b@example.com")
              && unnamed.expectedEmail("claude:.claude5") == "b@example.com")
    var heldAgain = AccountIdentityMemory()
    heldAgain.hold(accountID: "claude:.claude4", email: "a@example.com")
    let heldRestored = try! JSONDecoder().decode(AccountIdentityMemory.self,
                                                 from: JSONEncoder().encode(heldAgain))
    check("a hold survives a relaunch", heldRestored == heldAgain
              && heldRestored.expectedEmail("claude:.claude4") == "a@example.com")
    check("a memory stored before holds existed still loads",
          (try? JSONDecoder().decode(AccountIdentityMemory.self,
                                     from: Data(#"{"emails":{"claude:.claude":"old@example.com"}}"#.utf8)))?
              .email("claude:.claude") == "old@example.com")
    check("removing the account removes the hold", heldAgain.forget(accountID: "claude:.claude4")
              && heldAgain.expectedEmail("claude:.claude4") == nil)

    if failed > 0 { print("\(failed) FAILURES"); exit(1) }
}
