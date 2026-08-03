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
// THE SECOND PRIMARY HOME (codex review, 2026-08-03). Codex reads `~/.codex` first and falls back
// to the XDG location when no `~/.codex*` login exists, so on a machine whose only account lives
// there, `~/.config/codex` IS the primary setup - and a rule that only knew the one name offered to
// move it, with its history, to the Trash.
check("codex's XDG fallback home is a primary setup too, never removable",
      !accountHomeIsRemovable(providerID: "codex",
                              home: home.appendingPathComponent(".config/codex").path,
                              userHome: home))
check("…including spelled the long way round",
      !accountHomeIsRemovable(providerID: "codex",
                              home: home.path + "/.config/./codex/", userHome: home))
check("…and it is codex's alone: claude has no such fallback to protect",
      accountHomeIsRemovable(providerID: "claude",
                             home: home.appendingPathComponent(".config/codex").path,
                             userHome: home))
check("both of codex's homes are named in one list, and claude's one",
      mainAccountHomes(providerID: "codex", userHome: home).map(\.lastPathComponent)
          == [".codex", "codex"]
          && mainAccountHomes(providerID: "claude", userHome: home).map(\.lastPathComponent)
          == [".claude"])
// The list and the discovery fallback have to name the same directory, and discovery lives in a
// file this suite does not compile (it needs the whole provider stack), so the constant is pinned
// by source instead.
let codexSource = (try? String(contentsOfFile: "Tally/Providers/Codex/CodexAccounts.swift",
                               encoding: .utf8)) ?? ""
check("discovery falls back to the very constant the protection reads",
      codexSource.contains("appendingPathComponent(codexXDGConfigHome")
          && !codexSource.contains("\".config/codex\""))

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

// MARK: - The caches an account id survives in

// A removal that only drops the CARD leaves the store still holding this account's numbers under an
// id a recreated `~/.claude3` takes again: the new account's first failed fetch would be filled in
// with the old one's quota, published to the snapshot, and routed on by smart pick (codex review,
// 2026-08-03).
let usageSource = (try? String(contentsOfFile: "Tally/Stores/UsageStore.swift",
                               encoding: .utf8)) ?? ""
check("the store's own caches are readable from this suite", !usageSource.isEmpty)
check("removal goes through the store's forget rather than a bare hide",
      actionSource.contains("UsageStore.shared.forgetAccount(")
          && !actionSource.contains("UsageStore.shared.hideAccounts("))
check("…which drops the last-good numbers the next account under this id would inherit",
      usageSource.contains("func forgetAccount(_ accountID: String)")
          && usageSource.contains("lastGood[accountID] = nil")
          && usageSource.contains("failureStreak[accountID] = nil"))
check("…and the snapshot inputs, so the CLI stops being pointed into the Trash",
      usageSource.contains("lastPublishedAccounts.removeAll { $0.id == accountID }")
          && usageSource.contains("lastLaunchHomes[accountID] = nil")
          && usageSource.contains("republishSnapshot()"))

// MARK: - The refresh that was already out when the removal happened

// A round that began BEFORE the removal captured discovery, launch homes and fetches while the home
// was still on disk. Committing it unchanged re-remembers the account and republishes a snapshot
// pointing at a directory now in the Trash.
var removals = AccountRemovals()
let inFlight = removals.beginRound()
removals.remove("claude:.claude3")
check("an account removed mid-round is filtered out of that round's results",
      removals.isRemoved("claude:.claude3")
          && removals.removedIDs(inRound: inFlight) == ["claude:.claude3"])
removals.endRound(inFlight)
check("…and the tombstone outlives the very round it was filed against",
      removals.isRemoved("claude:.claude3"))
let afterwards = removals.beginRound()
// …but it does not BIND that next round. Its discovery ran against a filesystem the home was
// already gone from, so an account under this id is news: the user restored the folder from the
// Trash, or rebuilt the slot straight away. Filtering it here hid the new account for a whole
// refresh interval, because the tombstone was only retired at the end of this very round (codex
// review, 2026-08-03).
check("a round that started after the removal shows a home that came back, in that same round",
      removals.removedIDs(inRound: afterwards).isEmpty)
removals.endRound(afterwards)
// It has to expire, or a config home recreated under the same name would be invisible forever: the
// id is derived from the directory's name, so `~/.claude3` rebuilt IS `claude:.claude3` again.
check("a round that started after the removal retires it",
      !removals.isRemoved("claude:.claude3") && removals.removedIDs(inRound: afterwards).isEmpty)
var quiet = AccountRemovals()
quiet.remove("claude:.claude2")
let next = quiet.beginRound()
quiet.endRound(next)
check("a removal with nothing in flight is retired by the very next round",
      !quiet.isRemoved("claude:.claude2"))
var restored = AccountRemovals()
restored.remove("claude:.claude2")
let rebuilt = restored.beginRound()
check("…and a removal filed while nothing was running never filters the round that follows it",
      restored.removedIDs(inRound: rebuilt).isEmpty)
check("the refresh really does filter what it found through them",
      usageSource.contains("let removed = removals.removedIDs(inRound: round)")
          && usageSource.contains("allDiscovered.removeAll { removed.contains($0.id) }")
          && usageSource.contains("results.removeAll { removed.contains($0.id) }")
          && usageSource.contains("launchHomes = launchHomes.filter { !removed.contains($0.key) }"))
check("…before the reconcile that would otherwise remember them again",
      (usageSource.range(of: "let removed = removals.removedIDs(inRound: round)")?.upperBound)
          .map { filtered in
              (usageSource.range(of: "reconcile(discovered: allDiscovered)")?.lowerBound ?? filtered)
                  > filtered
          } == true)
check("…and retires the spent tombstones once the round has committed",
      usageSource.contains("let round = removals.beginRound()")
          && usageSource.contains("removals.endRound(round)"))

print(failed == 0 ? "ALL \(passed) PASS" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
