import Foundation

// What the CLI asks Tally.app to draw, and what comes back. One file compiled into BOTH targets, for
// the reason PromptHookInput.swift gives about its own handover: the two ends are separate processes
// speaking through files, and a second hand-written copy of the shapes is a copy that drifts, with
// the symptom appearing only on a user's machine at the moment they ask for something.
//
// THE CHANNEL, and why it is files with a notification rather than a socket:
//
//   ~/.tally/pick/<id>.request   the CLI writes it, then knocks
//   ~/.tally/pick/<id>.claim     the app writes it the moment the panel is up
//   ~/.tally/pick/<id>.answer    the app writes it when the person has chosen (or cancelled)
//
// A `DistributedNotificationCenter` post carries the id and nothing else, exactly as the update
// check already does (UpdateCommand.swift posts, UpdaterController.swift observes). Delivery of a
// distributed notification is not guaranteed and carries no back-pressure, so THE FILE IS THE TRUTH
// and the notification is only what saves both sides from polling hard. Everything under `~/.tally`
// already works this way.
//
// THE CLAIM IS THE THIRD FILE FOR ONE REASON: without it, "the app is not running" and "the app is
// showing the panel and the person is thinking" look identical from the CLI, and they need opposite
// answers. An unclaimed request falls back to the elicitation within a second and a half; a claimed
// one is waited on, because somebody is looking at it.

/// Where one pick's files live. A directory of its own beside the switch and model requests, under
/// the same rule: these are addressed (by pick id rather than by session), and one directory per
/// kind of message keeps a sweep from reaching across.
let pickRequestDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/pick")

/// The notification the CLI posts when a request is on disk, and the one the app posts when the
/// answer is. Reverse-DNS like the update check's, because a distributed notification name is a
/// machine-wide namespace.
let pickRequestedNotification = "ai.jetto.tally.pickRequested"
let pickAnsweredNotification = "ai.jetto.tally.pickAnswered"

/// Which command is asking. The app draws one list either way; what differs is what a row means and
/// what it can be rendered with (an account row has live quota behind it, a model row does not).
enum PickKind: String, Codable, Sendable {
    case account
    case model
}

/// One row of a one-step picker: everything choosing it decides, and everything drawing it needs.
///
/// THE ROW IS THE WHOLE DECISION, which is the difference between this and the form it replaces. A
/// form has one field per axis and a submit button, so "which model" and "how deeply" are two
/// answers and a confirmation; a row that carries both axes is one. That is also why `effort` is
/// OPTIONAL rather than defaulted: a row that names no effort means "leave that axis alone", which
/// is a real third state (`ModelIntent.pin(model:effort:)` states it), and `auto` is a row that can
/// never carry one - the grammar refuses the pair, so the list must not be able to draw it.
struct PickRow: Codable, Equatable, Sendable {
    /// What choosing this row answers with: an account id, a model name, or the release token.
    let value: String
    /// The second axis, where this row decides one. nil is "leave it as it is".
    var effort: String?
    /// What the row is called: an account's nickname, a model name, a pair.
    var label: String
    /// The second line, when the row has one: an account's three windows in the order the panel
    /// draws them, or what a model row is to this session ("running now"). Carried apart from the
    /// label rather than baked into it, because the panel lays the two out differently and a picker
    /// that shipped one string would have to take it apart again to draw it.
    var detail: String?
    /// "this session", "most headroom": the vocabulary the text listing already uses, decided by the
    /// CLI so every surface agrees about which account is recommended.
    var tags: [String] = []
    /// Whether this row is what the session is on right now. Drawn as the resting selection, so the
    /// keyboard path starts where the person already is.
    var isCurrent = false
}

/// One request to draw a picker.
struct PickRequest: Codable, Equatable, Sendable {
    let id: String
    let kind: PickKind
    /// The sentence above the list, written by the CLI so both channels say the same thing.
    let message: String
    let rows: [PickRow]
}

/// What the person did. A row, or nothing.
///
/// CANCELLED IS A VALUE HERE, not a missing file: the app says "they closed it" by writing this, and
/// the CLI can then stop waiting immediately instead of sitting out the deadline. An answer file that
/// cannot be read at all is also a cancellation, decided at the reader - this is the one message on
/// the channel that pins an account, and a guess about it moves somebody's conversation.
struct PickAnswer: Codable, Equatable, Sendable {
    var value: String?
    var effort: String?

    static let cancelled = PickAnswer()

    var isCancelled: Bool { value == nil }
}

/// The two tags a row can carry, spelled once for every surface that draws or reads them: the text
/// listing, the arrow-key menu (which opens on the recommended row), and the native panel (which
/// draws them apart from the label and tints the recommendation). Here rather than beside the
/// listing that invented them, because they now cross a process boundary.
let switchCurrentSessionTag = "this session"
let switchRecommendedTag = "most headroom"

/// What the release row is called wherever it is offered.
let pickAutoLabel = "automatic selection  (release this session's pin)"

/// How long a panel that has just been raised may lose the key window without that meaning anybody
/// put it down.
///
/// THE INCIDENT THIS EXISTS FOR (0.41.0, first real use): every `/tally-model` and `/tally-account`
/// came back INSTANTLY with "nothing was changed", and no panel was ever seen. The file trace says
/// exactly what happened - request written, claimed 11ms later, and an EMPTY answer (a cancellation)
/// 147ms after that, with nobody having touched anything:
///
///     80.876  <id>.request
///     80.887  <id>.claim    17431
///     81.034  <id>.answer   {}
///
/// Tally is an accessory app, so raising this panel means asking for the foreground, and that ask
/// does not complete synchronously: the panel is made key in-process, the activation then settles
/// (or does not), and AppKit takes the key window back. The controller read that as the person
/// clicking away and answered on their behalf, before they had seen anything to click.
let pickPanelActivationGrace: TimeInterval = 0.6

/// Whether a panel losing the key window is the PERSON putting it down.
///
/// Pure and shared so the rule can be asserted without an app: the panel is AppKit, but "what counts
/// as a dismissal" is a decision, and this incident is what it costs when that decision lives only
/// inside a delegate callback nothing can reach.
///
/// A panel that was never shown answers false, which is the same fail-safe direction: silence is not
/// a dismissal, and the CLI's own deadline is what ends a pick nobody answers.
func pickDismissalIsFromPerson(shownAt: Date?, now: Date = Date(),
                               grace: TimeInterval = pickPanelActivationGrace) -> Bool {
    guard let shownAt else { return false }
    return now.timeIntervalSince(shownAt) >= grace
}

/// WHAT A RAISED PANEL IS DOING, judged whenever its grace runs out.
///
/// THIS IS THE THIRD SHAPE OF ONE JUDGEMENT, and the first two failed in opposite directions, which
/// is why it is a state machine now rather than another condition:
///
///   v1 read every lost key window as a dismissal, so every pick answered itself in 147ms.
///   v2 swallowed the ones inside the grace, so a person who really left was never answered at all.
///   v3 gave the expiry three answers, two of which STOPPED THE CLOCK on a panel that had not
///      settled: a foreground ask that never landed, and a sibling window of ours taking key. Both
///      left a claimed request and a panel on screen with nothing watching either.
///
/// So the rule below has one invariant, and it is the thing all three rounds got wrong in turn:
/// EVERY READING THAT LEAVES THE PANEL UP ALSO LEAVES SOMETHING WATCHING IT. Only `.settled` stops
/// the clock, and it is reachable only while the panel actually holds the key window - the one state
/// where the ordinary resign path takes over and answers on its own.
enum PickGraceVerdict: Equatable, Sendable {
    /// The panel holds the key window. Nothing more to poll: a later resign is past the grace and
    /// answers for itself.
    case settled
    /// Not resolved, and nobody has put anything down. Look again.
    case keepWatching
    /// Ask for the foreground once more, on a FRESH grace: the second ask resigns asynchronously
    /// exactly as the first did, so it needs its own window to settle in (that is the other half of
    /// what v3 got wrong).
    case retryActivation
    /// The person put it down. Answer for them, which frees the waiting CLI now rather than at its
    /// deadline.
    case dismissed
    /// Asked twice and still unreachable: not key, and not even our own foreground. Nobody can get
    /// to this panel, so it is cancelled and the foreground handed back rather than left as a
    /// window the person can neither see the point of nor answer.
    case abandoned
}

/// The transition, pure and total, so every combination can be asserted without an app.
///
/// The inputs are what the panel can observe about itself at the moment its grace expires; the
/// discriminator that does the real work is `sawResign`, because a panel that never became key never
/// resigned - which is exactly how "the foreground ask never landed" is told apart from "somebody
/// walked away", the distinction the whole family of defects turns on.
func pickGraceVerdict(sawResign: Bool, isKey: Bool, appIsActive: Bool,
                      alreadyRetried: Bool) -> PickGraceVerdict {
    // KEY IS THE ONLY WAY TO STOP WATCHING. Everything else below keeps a clock on the panel.
    if isKey { return .settled }
    // Our own foreground, some other window of ours holding key: nobody has left the app, so this is
    // not a dismissal, and the panel is still reachable by hand. Keep looking rather than answering
    // or giving up (the CLI's own deadline is the backstop if a person really does leave it).
    if appIsActive { return .keepWatching }
    // Not key, and not our foreground either. One more ask before this is believed: an activation
    // that never landed looks exactly like somebody leaving, and only the retry tells them apart.
    guard alreadyRetried else { return .retryActivation }
    // Asked twice. A resign says the panel was in their hands and they left it; no resign at all
    // says it was never reachable to begin with.
    return sawResign ? .dismissed : .abandoned
}

// MARK: - The files

func pickRequestFile(id: String, dir: URL = pickRequestDir) -> URL {
    dir.appendingPathComponent("\(id).request")
}

func pickClaimFile(id: String, dir: URL = pickRequestDir) -> URL {
    dir.appendingPathComponent("\(id).claim")
}

func pickAnswerFile(id: String, dir: URL = pickRequestDir) -> URL {
    dir.appendingPathComponent("\(id).answer")
}

/// Whether an id may be turned into a path in that directory. The id is generated by the CLI and
/// travels through a notification, which is a machine-wide bus anything can post on, so it is
/// checked at both ends rather than trusted: a name carrying a separator would let a post name a
/// file outside the directory (`isTranscriptSessionID` guards the same way one axis over).
func isPickID(_ id: String) -> Bool {
    !id.isEmpty && id.count <= 64
        && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
}

/// Encode and decode, in one place, so neither end can invent a spelling. JSON because the rows are
/// structured and both ends have Codable; unreadable input is nil at both ends, never a partial
/// value.
func encodePick<T: Encodable>(_ value: T) -> Data? {
    try? JSONEncoder().encode(value)
}

func decodePick<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
    guard let data else { return nil }
    return try? JSONDecoder().decode(type, from: data)
}

func readPickRequest(id: String, dir: URL = pickRequestDir) -> PickRequest? {
    guard isPickID(id) else { return nil }
    return decodePick(PickRequest.self, from: try? Data(contentsOf: pickRequestFile(id: id, dir: dir)))
}

/// Take the claim, or find that somebody already has it.
///
/// EXCLUSIVE ON PURPOSE, and it is the only thing that keeps two running copies of Tally apart: the
/// notification goes to EVERY listener on the machine, so a release build and a dev build both hear
/// the same knock, both find nothing drawn yet, and both raise a panel over the same question. The
/// person then answers one of them while the other hangs there, and whichever wrote its claim last
/// owns a file the first one thinks is its own. `withoutOverwriting` is the whole fix: the file
/// system decides, once, and the loser draws nothing.
///
/// The pid inside it is what lets the CLI tell "somebody is looking at this" from "somebody WAS":
/// an app that claims and then dies would otherwise hold the request until the deadline.
func takePickClaim(id: String, owner: pid_t = ProcessInfo.processInfo.processIdentifier,
                   dir: URL = pickRequestDir) -> Bool {
    guard isPickID(id) else { return false }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    do {
        try Data("\(owner)\n".utf8).write(to: pickClaimFile(id: id, dir: dir),
                                           options: .withoutOverwriting)
        return true
    } catch {
        return false
    }
}

/// The process holding this request, or nil when nobody does (or the file says nothing usable,
/// which reads the same way: there is no one to wait for).
func readPickClaim(id: String, dir: URL = pickRequestDir) -> pid_t? {
    guard isPickID(id),
          let raw = try? String(contentsOf: pickClaimFile(id: id, dir: dir), encoding: .utf8),
          let owner = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)), owner > 0
    else { return nil }
    return owner
}

/// The answer, or nil when there is not one yet. AN UNREADABLE FILE IS AN ANSWER: it means the app
/// wrote something this build cannot use, and the only safe reading of that is that nothing was
/// chosen (`PickAnswer` says why guessing is not an option). Absent and unreadable are therefore
/// different: absent is "keep waiting".
func readPickAnswer(id: String, dir: URL = pickRequestDir) -> PickAnswer? {
    guard isPickID(id), let data = try? Data(contentsOf: pickAnswerFile(id: id, dir: dir))
    else { return nil }
    return decodePick(PickAnswer.self, from: data) ?? .cancelled
}
