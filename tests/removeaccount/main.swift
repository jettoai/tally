import Foundation

// Removing one account: which homes may be removed at all, what happens to the folder, and what
// Tally has to forget alongside it (Tally/Core/RemoveAccount.swift).
//
// The rules are probe-injected, so nothing here moves a real folder or touches the running user's
// Trash. What the ACTION does with them (ask first, remove the folder, then forget the account, and
// only in that order) is pinned by source below, the same way tests/addshare pins the add flow's
// two surfaces: an ordering mistake there is invisible to a type check.

var passed = 0, failed = 0
func check(_ name: String, _ cond: Bool) {
    if cond { passed += 1; print("PASS \(name)") } else { failed += 1; print("FAIL \(name)") }
}

let fm = FileManager.default
let home = URL(fileURLWithPath: "/Users/someone")

// MARK: - Which homes may be removed

// The provider's default home is the user's primary setup, and the target of every numbered home's
// share links and seeded trust. Removing it is not a thing "remove this account" can mean.
check("the claude default home is never removable",
      !accountHomeIsRemovable(providerID: "claude",
                              home: home.appendingPathComponent(".claude").path, userHome: home))
check("nor the codex one",
      !accountHomeIsRemovable(providerID: "codex",
                              home: home.appendingPathComponent(".codex").path, userHome: home))
check("a numbered home is",
      accountHomeIsRemovable(providerID: "claude",
                             home: home.appendingPathComponent(".claude2").path, userHome: home))
check("…including a codex one, whose own default is a different name",
      accountHomeIsRemovable(providerID: "codex",
                             home: home.appendingPathComponent(".codex3").path, userHome: home))
// The card asks this about `configHome`, which is nil for a demo fixture and for any account
// discovered without a directory behind it.
check("an account with no config home behind it is not removable",
      !accountHomeIsRemovable(providerID: "claude", home: nil, userHome: home)
          && !accountHomeIsRemovable(providerID: "claude", home: "", userHome: home))
// A path is a string until it is normalised, and the one comparison standing between the user and
// their main config folder must not be beaten by a `.` or a trailing slash.
check("an unnormalised spelling of the default home is still the default home",
      !accountHomeIsRemovable(providerID: "claude", home: home.path + "/./.claude", userHome: home)
          && !accountHomeIsRemovable(providerID: "claude", home: home.path + "/.claude/",
                                     userHome: home)
          && !accountHomeIsRemovable(providerID: "claude",
                                     home: home.path + "/.claude2/../.claude", userHome: home))

// MARK: - The folder itself

// The Trash, never a delete: this directory holds the account's conversations, and the undo has to
// be the user's own Finder rather than a backup they do not have.
var moved: [URL] = []
check("removal moves the home",
      trashAccountHome(at: "/Users/someone/.claude2", trash: { moved.append($0) })
          && moved.map(\.path) == ["/Users/someone/.claude2"])
struct TrashRefused: Error {}
check("a Trash that refuses is reported rather than swallowed",
      !trashAccountHome(at: "/Users/someone/.claude2", trash: { _ in throw TrashRefused() }))
// And it really is the system Trash rather than a delete, which no injected probe can prove: the
// one real call is pinned by source.
let coreSource = (try? String(contentsOfFile: "Tally/Core/RemoveAccount.swift",
                              encoding: .utf8)) ?? ""
check("the source is readable from this suite", !coreSource.isEmpty)
check("the real probe trashes rather than removes",
      coreSource.contains("trashItem(at: url, resultingItemURL: nil)")
          && !coreSource.contains("removeItem("))

// MARK: - What Tally forgets with it

// An account id is derived from its config home's NAME (`claude:.claude3`), so a later `~/.claude3`
// is the same id again and would inherit anything left behind here: a stranger's nickname, its
// position in the order, a hidden or switched-off state with no visible cause.
let traces = AccountSettingsTraces(
    labels: ["claude:.claude2": "Work", "claude:.claude3": "Spare"],
    order: ["claude:.claude", "claude:.claude2", "claude:.claude3"],
    menuBarHidden: ["claude:.claude2", "claude:.claude3"],
    disabled: ["claude:.claude2"])
let left = traces.forgetting("claude:.claude2")
check("the removed account's nickname, position, menu-bar state and on/off state all go",
      left.labels["claude:.claude2"] == nil && !left.order.contains("claude:.claude2")
          && !left.menuBarHidden.contains("claude:.claude2")
          && !left.disabled.contains("claude:.claude2"))
check("…and its siblings' settings are left exactly as they were",
      left.labels == ["claude:.claude3": "Spare"]
          && left.order == ["claude:.claude", "claude:.claude3"]
          && left.menuBarHidden == ["claude:.claude3"] && left.disabled.isEmpty)
check("forgetting an account nothing was remembered about changes nothing",
      traces.forgetting("claude:.claude9") == traces)

// MARK: - The act, in the one order that is safe

let actionSource = (try? String(contentsOfFile: "Tally/Views/RemoveAccountAction.swift",
                                encoding: .utf8)) ?? ""
let menuSource = (try? String(contentsOfFile: "Tally/Views/AccountCardMenu.swift",
                              encoding: .utf8)) ?? ""
let knownSource = (try? String(contentsOfFile: "Tally/Stores/KnownAccountsStore.swift",
                               encoding: .utf8)) ?? ""
check("every surface is readable from this suite",
      !actionSource.isEmpty && !menuSource.isEmpty && !knownSource.isEmpty)
check("the entry is drawn from the same removable rule the action re-asks",
      menuSource.contains("accountHomeIsRemovable(")
          && actionSource.contains("accountHomeIsRemovable("))
check("and it is switched off in demo mode, where the fixtures stand for no real folder",
      menuSource.contains("DemoUsage.isActive"))
check("nothing is moved before the user has been asked",
      actionSource.contains("CentredAlert.confirm("))
// THE ORDER. Forgetting an account whose folder is still there would leave the card to come back on
// the next refresh as a stranger: no name, no place in the order, and its pin gone.
let trashCall = actionSource.range(of: "guard trashAccountHome(")
let forgets = ["LaunchPolicyStore.shared.forget(", "KnownAccountsStore.shared.forget(",
               "SettingsStore.shared.forgetAccount("]
check("the pin, the memory and the settings are all forgotten",
      forgets.allSatisfy { actionSource.contains($0) })
check("…and every one of them only after the folder actually left",
      trashCall.map { trash in
          forgets.allSatisfy { (actionSource.range(of: $0)?.lowerBound ?? trash.lowerBound)
              > trash.upperBound }
      } == true)
// The other end of the same story: the pending marker an add leaves behind is cleared the first
// time Tally sees an account signed in that home, or an expired login would make it reusable again
// (tests/addshare has the rule itself).
check("a home Tally sees signed in stops being an unfinished add",
      knownSource.contains("clearAddAccountPendingMarker("))

print(failed == 0 ? "ALL \(passed) PASS" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
