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

/// One section of a palette: an axis, what it is called, and the rows that answer it.
///
/// WHY BOTH AXES ARE ON ONE PANEL. `/tally-model` and `/tally-account` ask two halves of one
/// sentence ("what runs this conversation, and where"), and somebody who opened one and wanted the
/// other had to escape it and type the second command. A section is what makes the second question
/// reachable without making the first one longer: the axis that was asked for is on top, and a row
/// still decides everything about itself, so there is still nothing to confirm.
/// NO NAME ON THE WIRE, which is the one thing this does not carry and the reason is the app's
/// languages: the CLI writes English (`pickAutoLabel` and every other string here), while the panel
/// draws Traditional Chinese, Simplified, Japanese or Korean depending on what the person set. A
/// heading sent from here would be the English one on all five. So the axis travels and the WORD is
/// the panel's own (`pickColumnHeadingKey`), which is the same split `pickPanelLabel` already makes
/// for the rows: what the surfaces draw differently belongs to the drawing.
struct PickSection: Codable, Equatable, Sendable {
    let kind: PickKind
    let rows: [PickRow]
}

/// The sections in the order they are drawn: the one that was asked for, then the rest.
///
/// One implementation for both ends, and that is the point: the CLI writes them focus-first, and
/// the app puts them focus-first again rather than trusting the order it was handed. A request
/// whose sections arrived the other way round would otherwise pin the wrong section's release row
/// under the list, which is the one row a person reaches for when the list is not what they wanted.
func pickSectionsFocusFirst(_ sections: [PickSection], focus: PickKind) -> [PickSection] {
    guard let index = sections.firstIndex(where: { $0.kind == focus }), index != 0 else {
        return sections
    }
    var ordered = sections
    ordered.insert(ordered.remove(at: index), at: 0)
    return ordered
}

/// WHICH PROJECT A PICK IS ABOUT, so a panel that arrives out of the air says whose conversation it
/// is about to move.
///
/// WHY IT HAS TO TRAVEL. One app answers every session on the machine, and several are usually open
/// at once in several repositories; the panel is raised by a knock carrying an id and nothing else,
/// so the only thing that knows which session asked is the process that asked. Two panels for two
/// projects were previously identical down to the sentence on them, and the answer moves a
/// conversation - a mis-read one moves the wrong conversation.
///
/// A TYPE OF ITS OWN rather than fields beside each other, for the reason `PickAxisAnswer` states:
/// a name without its path is half an identity, and a struct is what makes "all of it or none of
/// it" a property of the wire rather than a habit of the two ends.
struct PickProject: Codable, Equatable, Sendable {
    /// What the project is called: the MAIN repo's directory name, so every parallel line of one
    /// repository reads as that repository (the line itself is named below).
    var name: String
    /// The checkout this session is in, whole. Not drawn on the line - a path is longer than
    /// everything else on it together - but kept for the surface that has room for it on hover.
    var path: String
    /// The parallel line, when this checkout is not the main one. `tally worktree` lands them beside
    /// the repo as `<repo>-<branch>` (`worktreePath`), so three lines of one repository would
    /// otherwise raise three panels that say exactly the same thing.
    var worktree: String?
}

/// The identity, built from the two answers git gives about a directory. Pure, so the rule can be
/// asserted without a repository on disk; the asking is the CLI's (`pickProjectForCwd`).
///
/// A DIRECTORY THAT IS NOT A REPOSITORY STILL HAS A NAME, and it is the one the person sees in
/// their terminal, so nothing here fails: an unanswerable git is a project called after its own
/// folder, which is exactly what the launch profile does with the same question
/// (`projectPolicyKey`).
func pickProject(cwd: String, mainRepo: String?, checkout: String?) -> PickProject {
    let home = checkout ?? cwd
    let name = ((mainRepo ?? home) as NSString).lastPathComponent
    guard let mainRepo, let checkout, checkout != mainRepo else {
        return PickProject(name: name, path: home, worktree: nil)
    }
    // The line's own name rather than its folder: the folder is `<repo>-<branch>` by construction,
    // and a panel that said "tally-feat-cart" beside "tally" would be saying the repository twice.
    // A checkout somewhere else entirely (a worktree made by hand) keeps its folder name, which is
    // all anyone can say about it.
    let folder = (checkout as NSString).lastPathComponent
    let prefix = name + "-"
    let line = folder.hasPrefix(prefix) ? String(folder.dropFirst(prefix.count)) : folder
    return PickProject(name: name, path: checkout, worktree: line.isEmpty ? nil : line)
}

/// What the panel draws at the head of its sentence: the project, and the parallel line when there
/// is one. One string, so the drawn lead and anything else reading this identity cannot come apart.
func pickProjectLead(_ project: PickProject) -> String {
    guard let worktree = project.worktree else { return project.name }
    return project.name + pickEffortSeparator + worktree
}

/// One request to draw a picker.
struct PickRequest: Codable, Equatable, Sendable {
    let id: String
    let kind: PickKind
    /// The sentence above the list, written by the CLI so both channels say the same thing.
    let message: String
    /// THE FOCUS SECTION'S ROWS, and the whole of what an app from before the palette can see. Kept
    /// byte for byte as it was for exactly that reason: a copy of Tally that has never heard of
    /// `sections` decodes this field and draws the one list it always drew, which is this request
    /// with its second half missing rather than a request it cannot read at all.
    let rows: [PickRow]
    /// Every section, focus first, for an app that can draw a palette.
    ///
    /// OPTIONAL BECAUSE THE FAR END IS WHATEVER IS INSTALLED. The CLI ships inside the bundle but a
    /// session that was already talking when an update landed goes on running the CLI it launched
    /// with (`pickClaimSealFile` states the same limit one axis over), so both skews are live at
    /// once: a new CLI's request reaching an old app (which reads `rows`), and an old CLI's request
    /// reaching a new app (which finds this nil and draws a single section, exactly as before).
    var sections: [PickSection]?
    /// Whose conversation this is, when the CLI that asked was able to say (`PickProject`). Optional
    /// for the reason the sections above are, and read the same way: a request from a CLI that
    /// predates this field draws the panel exactly as it drew before, with no lead on its sentence.
    /// Additive only, which is the rule every file under `~/.tally` is under.
    var project: PickProject?

    /// Every row the request offers, whichever section it is in. What "there is something to draw"
    /// means for a request that may carry either shape.
    var everyRow: [PickRow] {
        guard let sections, !sections.isEmpty else { return rows }
        return sections.flatMap(\.rows)
    }
}

/// ONE AXIS OF AN ANSWER: the row one column had circled when the panel was submitted.
///
/// A TYPE OF ITS OWN, so the second axis travels as ONE field rather than as a second set of
/// siblings beside the first: a reader that gained `value2` but not `effort2` would act on half an
/// answer, and the pair is meaningless apart (`ModelIntent.pin(model:effort:)`).
struct PickAxisAnswer: Codable, Equatable, Sendable {
    var value: String
    var effort: String?
    var kind: PickKind
}

/// What the person did. The axes they changed, or nothing.
///
/// CANCELLED IS A VALUE HERE, not a missing file: the app says "they closed it" by writing this, and
/// the CLI can then stop waiting immediately instead of sitting out the deadline. An answer file that
/// cannot be read at all is also a cancellation, decided at the reader - this is the one message on
/// the channel that pins an account, and a guess about it moves somebody's conversation.
///
/// TWO AXES, IN TWO SHAPES AT ONCE, for the reason `PickRequest.sections` carries both of its own:
/// the far end is whatever is installed. The panel now submits everything that was circled, which
/// can be a move AND a model change in one press, while a CLI from before that reads three fields
/// and stops. So the three fields go on carrying ONE axis - the focused column's, which is the one
/// the person typed the command about - and the other rides in `also`, which an older reader drops
/// on the floor as JSON does with any unknown key. The degradation is therefore "the axis you asked
/// for happened, the other one did not", which is the least surprising half of the pair to lose.
struct PickAnswer: Codable, Equatable, Sendable {
    var value: String?
    var effort: String?
    /// WHICH SECTION THE ROW CAME FROM, because one palette offers both axes and the two are applied
    /// by different paths: the same click can move a conversation to another account or change what
    /// answers it, and nothing about the value says which.
    ///
    /// Optional for the same reason `PickRequest.sections` is: an app that predates the palette
    /// answers from the only section it ever drew, which is the request's own kind, so nil READS AS
    /// the focus kind rather than as an error (`MCPPickOffer.content`).
    var kind: PickKind?
    /// The other axis, when one submit changed both. Absent whenever only one was changed, which is
    /// most picks.
    var also: PickAxisAnswer?

    static let cancelled = PickAnswer()

    /// Nothing was chosen. BOTH FIELDS, because an answer carrying only the second axis would
    /// otherwise read as a cancellation and quietly drop a real change - the builder never writes
    /// one, and this is what makes that a property rather than a habit.
    var isCancelled: Bool { value == nil && also == nil }
}

extension PickAnswer {
    /// The answer a submit with these axes writes: the first into the fields every reader has, the
    /// second into the one only a current reader looks at. Anything past two is unreachable (there
    /// are two axes), and dropping it is what the type can say about that.
    init(axes: [PickAxisAnswer]) {
        self.init(value: axes.first?.value, effort: axes.first?.effort, kind: axes.first?.kind,
                  also: axes.dropFirst().first)
    }

    /// Every axis this answer names, the one an older app could have written first.
    ///
    /// `focus` is what a nil `kind` means, and nothing else: an app that predates the palette
    /// answers from the only section it ever drew.
    func axes(focus: PickKind) -> [PickAxisAnswer] {
        let named = value.map { [PickAxisAnswer(value: $0, effort: effort, kind: kind ?? focus)] }
        return (named ?? []) + (also.map { [$0] } ?? [])
    }
}

/// The two tags a row can carry, spelled once for every surface that draws or reads them: the text
/// listing, the arrow-key menu (which opens on the recommended row), and the native panel (which
/// draws them apart from the label and tints the recommendation). Here rather than beside the
/// listing that invented them, because they now cross a process boundary.
let switchCurrentSessionTag = "this session"
let switchRecommendedTag = "most headroom"

/// THE MIDDOT THIS FAMILY JOINS TWO SHORT THINGS WITH: a model and its depth, a project and the
/// parallel line it is on, two pending changes in one sentence. On the contract rather than beside
/// the panel's own arithmetic because BOTH ENDS write labels with it - the CLI builds "opus · high"
/// and the panel takes it apart again (`pickPanelLabel`) - and a second copy of a glyph is how the
/// building and the taking apart come to disagree.
let pickEffortSeparator = " · "

/// What the release row is called wherever it is offered.
let pickAutoLabel = "automatic selection  (release this session's pin)"

/// How long a panel that has just been raised may go without the keyboard before the foreground is
/// asked for a second time.
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
///
/// LOSING THE KEY WINDOW IS NO LONGER AN ANSWER AT ALL, which is what finally closed that family
/// rather than narrowing it a fifth time: a panel stands until somebody closes it (Escape, the ✕ on
/// its header, or a row), so nothing about focus can end a pick. What this window is left deciding
/// is when to ask for the foreground once more, which is a question about our own activation rather
/// than about anybody's intent.
let pickPanelActivationGrace: TimeInterval = 0.6

/// WHETHER A PANEL THAT HAS BEEN UP FOR ONE GRACE SHOULD ASK FOR THE FOREGROUND AGAIN.
///
/// THIS IS WHAT IS LEFT OF A FIVE-STATE MACHINE, and what went is every reading that ANSWERED a pick
/// nobody had touched (`dismissed`, `abandoned`) or kept a clock on one so that it could later
/// (`keepWatching`). Four rounds of defects came out of one distinction: "the person walked away"
/// against "the foreground ask never landed". From inside the app those two are the same
/// observation - not key, not active - and every round that tried to separate them broke in the
/// direction the last one had just closed. So the panel stopped asking. Nothing here cancels
/// anything, the panel keeps standing, and a panel nobody comes back to is ended by a deadline
/// instead (`pickPanelDeadline`), which cannot be wrong about intent because it never reads any.
///
/// Pure, so all four states can be asserted without an app.
///
/// `prompted` = somebody asked for this panel and is waiting on it. False for the panel a launch
/// flag raises to be looked at, which must never take a foreground it was deliberately launched
/// without (the last cell of the background launch contract, `CaptureLaunch`) - and answering that
/// here rather than in the caller is what keeps it testable.
///
/// ASKED ONCE, and that is a property of the schedule rather than of a flag: the grace is armed when
/// the panel goes up and never re-armed, so there is no second expiry for this to answer.
func pickShouldRetryActivation(prompted: Bool, isKey: Bool) -> Bool {
    prompted && !isKey
}

/// How long a CLAIMED panel may stay open before the CLI stops waiting for it. Reached only when
/// somebody raises a panel and does not come back to it, and it resolves the way every other
/// unanswered pick already does: nothing was chosen.
///
/// HERE RATHER THAN BESIDE THE WAIT THAT COUNTS IT (`MCPServe.askNatively`), because the panel now
/// has a deadline of its own and the two must be one number: an app that closed later than the CLI
/// gave up would answer into a directory the CLI had already swept, and one that closed on a timer
/// written separately would drift away from the wait the moment either was tuned.
let nativePickDeadlineSeconds: TimeInterval = 300

/// How long the PANEL stands before it closes itself, which is deliberately a little short of the
/// wait above.
///
/// WHY THE PANEL NEEDS A DEADLINE AT ALL, and it is the price of the panel standing through a lost
/// key window: a pick somebody raised and then forgot used to end the moment they clicked elsewhere,
/// and now nothing about focus ends it. Without this it would sit on the screen for the rest of the
/// session, over a CLI that stopped waiting for it minutes earlier.
///
/// WHY SHORTER RATHER THAN EQUAL. The answer has to land while the wait is still reading: the CLI
/// discards the whole request the moment it gives up (`defer { pick.discard(id) }`), so an answer
/// written after that is a file nobody reads, left behind in `~/.tally/pick`. The panel also starts
/// its clock LATER than the wait starts its own - the request is written, knocked on and claimed
/// first - so the margin covers that skew as well as one poll interval. Seconds against five
/// minutes, which nobody sitting in front of a panel can perceive.
let pickPanelDeadline: TimeInterval = nativePickDeadlineSeconds - 5

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

/// THE SEAL BESIDE A CLAIM: the claimant's pid again, written by the app the instant it wins the
/// claim, and the whole of the handshake this protocol has.
///
/// WHY THERE IS ONE AT ALL. The stand-down above only reaches builds that have it, and the builds
/// this is about are by definition older than it: an app already running from before this change
/// claims exactly as it always did, and the one thing it carries for certain is the panel defect
/// that made it dangerous. So the arbitration is put on the requester, where a claim nobody sealed
/// is declined as a claim (MCPServe.askNatively).
///
/// WHICH REQUESTERS THAT ACTUALLY REACHES, precisely, because the tempting version of this sentence
/// is false: the CLI ships inside the bundle, so every session STARTED after an update runs the new
/// code. Not every session. `MCPServer.serve()` reads until its Claude Code closes stdin, which is
/// hours or days, and a process cannot be reloaded from underneath itself: a session that was
/// already talking when the update landed goes on running the CLI it launched with, asks for no
/// seal, and can still be answered by a stale app. That is not a hole this opens, it is the state
/// those sessions were already in, and it closes on its own as they turn over. Nothing here can
/// shorten it, which is why it is written down instead of implied away.
///
/// WHY A FILE BESIDE THE CLAIM RATHER THAN A FIELD INSIDE IT, which is the shape this obviously
/// wanted: the claim file's whole content IS the pid (`readPickClaim` parses the trimmed file), so
/// there is no way to add a line to it that an older reader survives. A CLI from before this change
/// would read a two-line claim as unparseable, which it reads as NOBODY CLAIMING, and fall back to
/// the form while a healthy app is drawing the panel: a form and a panel on screen at once, for the
/// one reader we cannot go back and fix. The claim file is therefore left byte for byte as it was,
/// and the addition is a sibling that old readers never look at.
///
/// WHAT IT COSTS, stated rather than discovered: while a CLI that asks for the seal is talking to an
/// app that does not write one, every pick draws the form. That pairing is the version skew itself
/// (an update landed and the app has not been relaunched into it, which Sparkle does as part of
/// installing), and the form is the surface those picks had before the panel existed. Between "the
/// person gets the old surface for a few minutes" and "a build with a known defect answers for
/// them", the first is the one worth choosing.
///
/// WRITTEN AFTER THE CLAIM AND ONLY BY THE WINNER, which is what keeps it race-free: a loser that
/// had sealed first would be vouching for a claim it does not hold. The gap between the two writes
/// is microseconds and costs nothing, because a claim without a seal reads exactly like a request
/// nobody has taken yet, and that is a state the wait already sits through until its claim deadline.
func pickClaimSealFile(id: String, dir: URL = pickRequestDir) -> URL {
    dir.appendingPathComponent("\(id).seal")
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
    } catch {
        return false
    }
    // SEALED HERE RATHER THAN BY THE CALLER, so the handshake cannot be forgotten by whoever draws
    // the next surface: taking the claim and vouching for it are one act (`pickClaimSealFile`).
    do {
        try Data("\(owner)\n".utf8).write(to: pickClaimSealFile(id: id, dir: dir), options: .atomic)
    } catch {
        // An unsealed claim of ours is worse than no claim: the wait would time it out and draw the
        // form with our panel already on screen. Give the request back instead, and let the person
        // have the surface that is definitely going to work.
        try? FileManager.default.removeItem(at: pickClaimFile(id: id, dir: dir))
        return false
    }
    return true
}

/// Whether the claim on this request was taken by a build that speaks this protocol, which is the
/// question the pid alone cannot answer: `readPickClaim` says WHO holds it, and a copy of Tally
/// running from before the seal existed holds it exactly as convincingly as a current one.
///
/// The claimant's own pid is what the seal carries, so the two files have to agree about who is
/// drawing. Nothing else would: a bare marker could be left behind by a claimant that has since
/// lost the request (`takePickClaim` gives one back when it cannot seal it).
func pickClaimIsSealed(id: String, owner: pid_t, dir: URL = pickRequestDir) -> Bool {
    guard isPickID(id),
          let raw = try? String(contentsOf: pickClaimSealFile(id: id, dir: dir), encoding: .utf8),
          let sealed = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return false }
    return sealed == owner
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
