import Foundation

// READING THE PERSONAL ACCOUNT'S RESERVE BACK, and handing it to the picks.
//
// THE RULES THEMSELVES ARE NOT HERE. They live in Tally/Core/AccountReserve.swift, which BOTH
// TARGETS COMPILE (project.yml says why), and this file is the CLI's reader of them: the state file
// read, and one lookup shaped for the thing the picks actually hold - a `Snapshot.Account` rather
// than a config-home string. Everything that decides anything (which key names this home, that only
// the marked account carries a reserve, what the bounds are, which of two marked homes wins) is
// asked of `AccountRoles` and never re-spelled here. These are two processes speaking through a
// document the user owns, so a second spelling fails silently in both directions - quota held back
// on an account whose Settings row shows none, or a water line the launcher walks straight through.
//
// WHAT THE RESERVE IS FOR, in one paragraph, because this is the file every pick imports. Tally
// hands sessions out across a fleet on its own initiative - it picks the launch account, moves a
// running session off a dying one, re-picks after a `/clear`. That is the whole product, and it is
// also why the fleet needs a way to say that one account is not entirely Tally's to spend: the
// person is signed in to claude.ai on it, and an automatic decision that drains it to 2% takes their
// afternoon away without ever telling them.
//
// ONE NUMBER, AND IT MEANS ONE THING EVERYWHERE. The reserve is percentage points held back from
// each window the account SHARES with that browser - its weekly all-models one, its 5h session one
// and its flagship model's - and from no other (Tally/Core/AccountReserve.swift states that ruling,
// and why one knob covers all three windows rather than three knobs).
// It reaches the product as a single subtraction inside `effectiveRemaining` (AccountComfort.swift),
// on the windows that carry it. Everything an automatic decision asks - is this account comfortable,
// is it spent, may a session be moved onto it, how hard can it be pushed - is already asked through
// that one reading, so nothing here has to teach eight movers about reserves. What it does have to
// do is hand each of them the reserves to read, which is what `AccountReserves` below is for.
//
// A RESERVE IS A HARD LINE (B-1213, owner's ruling 2026-10-07: "otherwise what is it reserving?"):
//
//   - A named launch is refused under the line. `tally claude --account X`, a panel pin and a
//     project pin onto an account under its line exit 1 with the reason, unless `--spend-reserve`
//     is passed; the shim's bare `claude` cannot carry the flag and is refused outright.
//   - An automatic launch with nothing above the line refuses and names when the first account is
//     back (`reserveHoldout`), from every path that makes that pick: `runLaunch` on stderr, the two
//     shim commands through the script they print (LaunchDir.swift). `--spend-reserve` ranks the
//     field without reserves and says so (`reserveDipNotice`).
//   - A running session under the line moves when a target exists; with none it is HELD: nothing
//     Tally types reaches it (DroughtWatch.swift). `--spend-reserve` lets a session start and stay on
//     an account under its line while there is nowhere to go; once a sibling above its line exists,
//     the existing movers still carry it off (an `--account` launch, unsupervised, is never moved).
//
// AUTOMATIC MOVES NEVER CROSS A LINE EITHER. A running session already has somewhere to be, so the
// strict half of the nearly-dry gate
// (`requiringComfortable`) answers "wait" and the session stays where it is - which is exactly what
// it does today when no sibling has room.

/// The `accounts` block as the CLI holds it, with the two questions the picks ask of it.
///
/// A WRAPPER RATHER THAN THE RAW DICTIONARY, for one reason: the picks hold `Snapshot.Account`s, and
/// the block is keyed by config home. Putting that join in one named place is what keeps every call
/// site from re-deriving "which home is this account" - and `AccountReserves.none` gives a call site
/// a way to SAY that it is a path a person named an account on, which is the audit trail for the one
/// rule this feature has.
struct AccountReserves: Equatable {
    /// What a call site passes when the account was asked for BY NAME. Its own name so the reading
    /// is visible at the call: `reserves: .none` says "a person chose this", not "I forgot".
    static let none = AccountReserves(settings: [:])

    var settings: [String: AccountRoleSetting]

    /// The reserve held back from `account`, through the shared rule: only the marked account has
    /// one, the value is clamped into range, and the home is matched under the same normalization
    /// the app wrote it with. 0 for every account nobody marked - which includes every account when
    /// the file has no `accounts` block at all (an app that predates the feature, or a fleet that
    /// never set one) and every account of a provider the feature does not cover.
    ///
    /// `Double` because everything downstream of it is: the reserve is subtracted from a percentage
    /// the provider reports as one. The document stores an integer, which is what the stepper writes.
    func reserve(for account: Snapshot.Account) -> Double {
        Double(AccountRoles.reserve(settings, home: account.launchHome))
    }
}

/// The `accounts` block of `~/.tally/state.json`, written by the app's `LaunchPolicyStore`.
///
/// A READER OF ITS OWN: this is a top-level block rather than one of a provider's launch policies,
/// and a decoder that knows only the key it needs cannot be broken by a `launch` block from a
/// version this binary predates. Every way of not having an answer - no file, bytes that will not
/// parse, the key absent - is the same answer, an empty block, which is the behaviour every account
/// had before the feature existed.
///
/// `version` is deliberately not read: the schema only ever gains keys, so a file this binary is too
/// old for still yields the keys it does understand, and one it is too new for is not a reason to
/// forget the reserves the user set.
///
/// The entries are kept EXACTLY as written, unnormalized. The shared rules normalize both sides at
/// lookup time (`AccountRoles.key`), so normalizing on the way in would be a second, earlier copy of
/// the one thing this file exists not to have a copy of - and it would collapse two keys that the
/// writer still tells apart.
func accountReserves(_ url: URL = stateURL) -> AccountReserves {
    struct StateFile: Decodable {
        // Mirror of the app's `LaunchPolicyStore.StateFile` field of the same name, decoded into the
        // shared entry type so this reader cannot disagree with the writer about a field.
        var accounts: [String: AccountRoleSetting]?
    }
    guard let data = try? Data(contentsOf: url),
          let file = try? JSONDecoder().decode(StateFile.self, from: data),
          let accounts = file.accounts else { return .none }
    return AccountReserves(settings: accounts)
}
