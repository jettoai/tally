import Darwin
import Foundation

// Asking Tally.app to draw the picker, and waiting for the person WITHOUT going deaf.
//
// THE STRUCTURAL RULE THIS HAS TO KEEP (MCPServe.swift states it): while a pick is outstanding the
// client keeps talking - pings, tool listings, notifications - and a server that reads only for its
// own answer leaves those unanswered, with a panel open on the screen and both sides waiting for
// each other. The elicitation wait kept that property for free, because the answer arrived on the
// same stream it was already reading.
//
// A NATIVE PANEL BREAKS THAT FOR FREE PROPERTY: the answer now arrives as a FILE, so a wait blocked
// in `readLine` would never see it, and a wait that polled only the file would never serve the
// client. The wait therefore watches both, and the shape below is what keeps it honest:
//
//   every turn:  poll(2) fd 0 for one interval -> if a message is waiting, read exactly one and
//                dispatch it (never blocking, because poll just said it is there)
//                then look for the answer file, then judge the two deadlines
//
// `readLine` is called only once poll has said there is something to read. The alternative - moving
// stdin onto a background thread feeding a queue - is the more orthodox shape and was deliberately
// not taken: it changes the path EVERY MCP message travels, to buy something only the wait needs.
//
// The one caveat, stated rather than hidden: poll answers for BYTES and `readLine` consumes a LINE,
// so a client that wrote half a line and stopped would block the wait until it finished the line.
// Claude Code writes one whole JSON object per line per write, and the same assumption is already
// load-bearing in `receive()`.

/// How long Tally.app has to claim a request before the wait gives up on it and the form is drawn
/// instead. Short, because the person is looking at a terminal that has just gone quiet: this is the
/// budget for "is the app even running", not for "has it finished drawing".
let nativePickClaimSeconds: TimeInterval = 1.5

// How long a claimed panel may stay open is `nativePickDeadlineSeconds`, which lives with the
// contract rather than here: the app closes the panel just short of it (`pickPanelDeadline`), and a
// deadline the two ends kept separate copies of would drift the first time either was tuned.

/// How long each turn of the wait blocks on the client's stream. The wait's only clock, so it is
/// also the resolution of both deadlines above and the worst-case delay on serving a client message.
let nativePickPollSeconds: TimeInterval = 0.1

/// Everything the wait does to the world, in one injectable place, so the whole loop can be driven
/// in a test without an app to answer it, a client to talk to, or a `~/.tally` to write into.
struct NativePickChannel {
    /// Put the request on disk and knock. False when it could not be written at all, which is read
    /// as "there is no native path today" and falls straight through to the form.
    var publish: (PickRequest) -> Bool
    /// WHO has taken this one, or nil when nobody has. A pid rather than a yes: an app that claims
    /// a request and then dies must not be able to hold the wait open to its deadline, and the only
    /// way to tell that apart from "somebody is still looking at it" is to ask about the process
    /// (PickContract.swift writes it, `isAlive` below asks).
    var claimant: (String) -> pid_t?
    /// Whether a claiming process is still there. Its own member so the wait can be driven through a
    /// death in a test without one.
    var isAlive: (pid_t) -> Bool = { supervisorAlive($0) }
    /// WHETHER THAT CLAIMANT IS ONE OF OURS: a claim sealed by the app that took it, which a copy of
    /// Tally from before the seal existed cannot produce (`pickClaimSealFile` says why the requester
    /// is the end that has to arbitrate, and why the seal is a sibling file rather than a field).
    var sealed: (String, pid_t) -> Bool = { pickClaimIsSealed(id: $0, owner: $1) }
    /// The answer, or nil while there is not one. An unreadable answer is a CANCELLATION rather than
    /// a nil, decided in the contract, so this never has to guess.
    var answer: (String) -> PickAnswer?
    /// Take the files away, whatever happened: a request left behind would raise a panel for a
    /// question nobody is waiting for any more.
    var discard: (String) -> Void
    /// Whether the client has sent something, waiting up to this long for it. The only blocking call
    /// in the loop.
    var messageWaiting: (TimeInterval) -> Bool
    var now: () -> Date = Date.init

    /// The real one: files under `~/.tally/pick`, a distributed notification, and `poll(2)` on the
    /// client's own file descriptor.
    static var live: NativePickChannel {
        NativePickChannel(
            publish: { request in
                guard isPickID(request.id), let data = encodePick(request) else { return false }
                try? FileManager.default.createDirectory(at: pickRequestDir,
                                                        withIntermediateDirectories: true)
                do {
                    try data.write(to: pickRequestFile(id: request.id), options: .atomic)
                } catch {
                    return false
                }
                // The knock. Delivery is not guaranteed and carries no answer, which is exactly why
                // the file is written FIRST and is the thing the app reads: this only saves the app
                // from polling.
                DistributedNotificationCenter.default().postNotificationName(
                    Notification.Name(pickRequestedNotification), object: request.id,
                    userInfo: nil, deliverImmediately: true)
                return true
            },
            claimant: { readPickClaim(id: $0) },
            answer: { readPickAnswer(id: $0) },
            discard: { id in
                guard isPickID(id) else { return }
                for file in [pickRequestFile(id: id), pickClaimFile(id: id), pickAnswerFile(id: id),
                             pickClaimSealFile(id: id)] {
                    try? FileManager.default.removeItem(at: file)
                }
            },
            messageWaiting: { seconds in
                var descriptor = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
                // Rounded UP to a whole millisecond: a zero timeout would turn the wait into a spin,
                // and poll takes milliseconds while every other duration here is seconds.
                let milliseconds = Int32(max(1, (seconds * 1000).rounded()))
                let ready = poll(&descriptor, 1, milliseconds)
                // POLLHUP and POLLERR both mean "read it and find out", and reading is how end of
                // input is noticed: the caller turns that into a decline. Only a timeout (0) and a
                // signal (-1) mean there is nothing to read.
                return ready > 0
            })
    }

    /// A channel that answers "there is no native picker here": nothing is written, nothing is
    /// knocked on, and the caller falls straight through to the form. The shape a machine without
    /// Tally.app effectively has, and what every test that is exercising the FORM path uses, so a
    /// suite can never write into the user's own `~/.tally/pick` or knock on a running app.
    static var unavailable: NativePickChannel {
        NativePickChannel(publish: { _ in false }, claimant: { _ in nil },
                          sealed: { _, _ in false }, answer: { _ in nil }, discard: { _ in },
                          messageWaiting: { _ in true })
    }
}

/// A fresh id for one pick. A uuid rather than a counter: two sessions can ask at the same moment,
/// and the id names files in a directory they share.
func newPickID() -> String { UUID().uuidString }

/// WHOSE CONVERSATION THIS PICK IS ABOUT, asked of git here and drawn by the panel there
/// (`PickProject`, which states why it has to travel at all and builds the identity from these two
/// answers).
///
/// ASKED OF THE DIRECTORY THE PROMPT REPORTED, which the caller passes in
/// (`MCPPickOffer.directory`). THE SERVER'S OWN IS THE FALLBACK, and only that: an MCP server is
/// spawned once per Claude Code session and lives for all of it, so its working directory is
/// whatever that session was launched in - usually right, and quietly wrong for a session that has
/// moved since. The wire does carry the client's answer, in the hook payload every tool call brings
/// with it (`MCPHookInput.sessionDirectory`, which is where the four other answers on the same call
/// come from); a comment here once said it did not, and the panel could therefore name the project a
/// session had left (codex review of 46b09ec). The default below is for a caller that has no hook
/// reading at all, and the answer it gives is the same one the launch profile is keyed by
/// (`projectPolicyKey`), which is what keeps "which project" one answer across the app.
///
/// Two git calls per pick, on a path that is already about to put a window on somebody's screen.
func pickProjectForCwd(_ cwd: String = FileManager.default.currentDirectoryPath) -> PickProject {
    // The CHECKOUT this session is in, which is the worktree rather than the repository: the two
    // differ exactly when the session is on a parallel line, and that difference is the line's name.
    let top = runGit(["rev-parse", "--path-format=absolute", "--show-toplevel"], cwd: cwd)
    let checkout = top.code == 0 && !top.out.isEmpty ? realpathString(top.out) : nil
    return pickProject(cwd: realpathString(cwd), mainRepo: resolveMainRepo(cwd: cwd),
                       checkout: checkout)
}
