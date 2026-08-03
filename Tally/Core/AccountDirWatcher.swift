import Foundation

// Noticing a new account the moment it finishes logging in, instead of up to a refresh interval
// later.
//
// `tally add` hands the terminal to the provider's own login flow and says the account will show up
// in Tally. Until this existed, "show up" meant "on the next poll": discovery runs inside `refresh`,
// and refresh only fires on the timer (a minute at its fastest, five by default), at launch, on the
// manual button, or on a failure retry. The user finishes logging in and watches an app that does
// not know anything happened.
//
// THE FILTER IS THE DESIGN, not an optimization. A config dir is one of the busiest directories on
// the machine: `.claude.json` is rewritten constantly by every running session, and `projects/` is a
// shared symlink that every account writes through. Wiring these events straight to `refresh` would
// turn ordinary typing into a stream of usage-API requests against an endpoint that rate-limits
// aggressively. So an event only ever buys a DISCOVERY pass, which is local and cheap (a directory
// listing plus a Keychain attribute probe per dir), and only a discovery pass whose ANSWER differs
// from the last one buys a refresh.
//
// Fail-open at every step: if the stream cannot be created, or dies, the timer behaves exactly as it
// did before. Nothing here is load-bearing for correctness, only for latency.

/// Whether a changed path is worth a discovery pass.
///
/// FSEvents watches a whole subtree, and the subtree here is the user's home directory, so the great
/// majority of what arrives is their editor and their builds. This is the cheap string test that
/// keeps that traffic away from everything downstream: only the provider config dirs themselves
/// matter, and a new account arrives as a new directory among them.
///
/// THE HOME DIRECTORY ITSELF COUNTS, and that is the whole reason a new account is seen at all.
/// At directory granularity, creating `~/.claude4` is reported as a change to `~`, not as an event
/// naming the new directory: the name only appears once something is written INSIDE it. Rejecting
/// the parent therefore meant a login could be missed entirely, which is what an end-to-end run
/// against a real stream showed (2026-07-28) after the unit tests passed. The paths also arrive with
/// a trailing slash, so both sides are normalized before anything is compared.
///
/// Pure and exported so the rule is testable without a filesystem.
func accountDirEventIsInteresting(path: String, home: String) -> Bool {
    func withoutTrailingSlash(_ s: String) -> String {
        s.hasSuffix("/") && s.count > 1 ? String(s.dropLast()) : s
    }
    let home = withoutTrailingSlash(home), path = withoutTrailingSlash(path)
    guard path != home else { return true }
    guard path.hasPrefix(home + "/") else { return false }
    let entry = path.dropFirst(home.count + 1).prefix { $0 != "/" }
    return entry.hasPrefix(".claude") || entry.hasPrefix(".codex")
}

/// Whether two discovery results describe a different set of accounts.
///
/// Identity only: a usage number changing is what the refresh timer is for, and reacting to it here
/// would defeat the whole filter. What this is asking is "did an account appear or disappear", which
/// is the only question a login completing can answer differently.
///
/// The launch home rides along with the id because that is what makes an account launchable; an
/// account whose home moved is, to every surface downstream, a different account.
///
/// So does whether it is DORMANT, and that is the login landing. A signed-out account is not
/// discoverable, but it is not gone either: it comes back from the memory as a dormant account with
/// the very same id and the very same home (KnownAccounts.swift). Comparing only those two made
/// signing back IN a non-event - the set read identical either side of the credential appearing -
/// which is the state the "Login expired" chip is read off, and it would have stayed up until the
/// next poll tick (codex review, 2026-08-03). This is still identity rather than freshness: it
/// changes only when a credential appears or disappears, which is the one thing a login does.
func accountSetChanged(from before: [ProviderAccount], to after: [ProviderAccount]) -> Bool {
    func identity(_ accounts: [ProviderAccount]) -> Set<String> {
        Set(accounts.map { "\($0.id)@\($0.launchHome ?? "")\($0.isDormant ? " (dormant)" : "")" })
    }
    return identity(before) != identity(after)
}

/// Watches the provider config dirs and reports when the set of discoverable accounts changes.
///
/// Deliberately not an @Observable store: it owns no state anyone renders, and its whole output is
/// one callback. The owner (UsageStore) decides what a change means.
@MainActor
final class AccountDirWatcher {
    /// Holds the raw stream apart from the main-actor state, so it can be torn down from `deinit`
    /// (which cannot hop actors) without making the whole class nonisolated. The three teardown
    /// calls are safe from any thread, which is what makes the unchecked conformance honest.
    private final class StreamBox: @unchecked Sendable {
        var stream: FSEventStreamRef?
        deinit {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private let box = StreamBox()
    private var debounceTask: Task<Void, Never>?
    private let home: URL
    private let debounce: Duration
    /// Runs a discovery pass and answers whether the account set differs from the last one the app
    /// acted on. Injected so the watcher itself needs no provider knowledge.
    private let discoverChanged: () -> Bool
    private let onChange: () -> Void

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         debounce: Duration = .seconds(3),
         discoverChanged: @escaping () -> Bool,
         onChange: @escaping () -> Void) {
        self.home = home
        self.debounce = debounce
        self.discoverChanged = discoverChanged
        self.onChange = onChange
    }

    /// Begin watching. Safe to call twice; a second call is ignored.
    func start() {
        guard box.stream == nil else { return }
        // `self` is handed over unretained: the stream is owned by this object and torn down in
        // deinit, so it cannot outlive it.
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info, let paths = paths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
                as UnsafeMutablePointer<UnsafePointer<CChar>?>? else { return }
            let watcher = Unmanaged<AccountDirWatcher>.fromOpaque(info).takeUnretainedValue()
            var changed: [String] = []
            for i in 0 ..< count {
                if let raw = paths[i] { changed.append(String(cString: raw)) }
            }
            // The callback arrives on the stream's own queue; everything below is main-actor state.
            Task { @MainActor in watcher.handle(changed) }
        }
        // Directory-level granularity on purpose (no kFSEventStreamCreateFlagFileEvents): one event
        // per busy directory rather than one per write, which is all the filter below needs and a
        // fraction of the traffic.
        guard let created = FSEventStreamCreate(
            nil, callback, &context, [home.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)) else { return }
        FSEventStreamSetDispatchQueue(created, DispatchQueue.global(qos: .utility))
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return
        }
        box.stream = created
    }

    private func handle(_ paths: [String]) {
        guard paths.contains(where: { accountDirEventIsInteresting(path: $0, home: home.path) })
        else { return }
        // Coalesce: a login writes a burst, and the answer is only interesting once it settles.
        debounceTask?.cancel()
        debounceTask = Task { [debounce, discoverChanged, onChange] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, discoverChanged() else { return }
            onChange()
        }
    }
}
