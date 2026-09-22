import Foundation

// `tally message <claude|codex> …`: one message into a conversation's own native queue, addressed
// the way every other command addresses a session.
//
// THE SIBLING OF `tally type`, AND THE DIFFERENCE WORTH KNOWING. That one types into a terminal and
// presses Return, so it can answer a permission dialog and run a slash command; this one hands a
// message to the provider's native transport, so it touches no keyboard and can do neither. Neither
// of them is a receipt: a typed line may sit queued behind a turn, and a written frame is bytes on
// a socket rather than a message somebody read.
//
// TWO GRAMMARS, ONE OF THEM A SUBSET. The explicit form (`--socket`/`--session UUID`, or
// `--home`/`--thread`) is the address written out by hand; the addressed form names a session by
// pid, by directory or by being run inside it, and looks that same pair up in the roster
// (`nativeSessionAddress`). Which one was written is decided on the flags alone, before anything is
// looked up, so one command line means one thing wherever it is run.
//
// CODEX IS EXPLICIT-ONLY, and that is a statement about evidence rather than about effort. The
// roster proves a Claude session's socket and transcript UUID together (SessionInventory.swift
// guards that pair against a stale socket, a mismatched account sidecar and a transcript stamped by
// a dead child), and it proves nothing about which home and thread a supervised Codex session is
// writing to. Guessing it would put somebody's message into whichever conversation that home's
// thread happens to be.

/// What `tally message <provider> …` asks for, when it named a session rather than an address.
struct MessageAddressRequest: Equatable {
    /// The provider named in the position after the verb, which the session that is found has to
    /// agree with.
    var provider: String
    /// The address, in the very type `tally type` builds for the same three ways of naming one.
    /// `text` is unused here: this verb carries its message in `body` instead, the address and the
    /// content being separate questions.
    var intent: SessionSendIntent
    var body: MessageBody
    var dryRun: Bool
}

/// The flags that say "this line carries an address already". `--session` is deliberately not among
/// them: it means a pid in one grammar and a transcript UUID in the other, so it is the one word
/// that cannot decide which grammar is being written.
let messageExplicitKeys: Set<String> = ["--socket", "--home", "--thread"]

/// Whether this command line is written in the explicit grammar, decided on the flags alone and
/// before the roster is asked anything.
///
/// STOPS AT `--`, because everything after it is the message rather than a flag: `tally message
/// claude -- --socket` sends those eight characters to this session, and reading them as an address
/// would be content mistaken for an instruction.
func messageVerbIsExplicit(_ args: [String]) -> Bool {
    for word in args.dropFirst() {
        if word == "--" { return false }
        if messageExplicitKeys.contains(word) { return true }
    }
    return false
}

/// What one addressed-form command line asks for, or nil when it asks for something this verb
/// cannot act on (a usage error rather than a refusal: nothing has been looked up yet).
///
/// THE ADDRESS GRAMMAR IS `tally type`'s, unchanged and through the same type that owns those three
/// flags (`SessionSendAddress`), so a session named for a message is the session the same words
/// would have typed into. `--provider` is refused here for the reason it is refused there: the
/// position has already answered that question, and a second answer is either a repetition or a
/// contradiction.
func messageAddressRequest(_ args: [String]) -> MessageAddressRequest? {
    guard let provider = args.first, sessionProviderNames.contains(provider) else { return nil }
    var address = SessionSendAddress()
    var file: String?
    var text: String?
    var dryRun = false
    var literal = false
    var index = 1
    while index < args.endIndex {
        let word = args[index]
        index += 1
        if !literal {
            if word == "--" { literal = true; continue }
            if word == "--dry-run" {
                guard !dryRun else { return nil }
                dryRun = true
                continue
            }
            if word == "--file" {
                guard file == nil, index < args.endIndex else { return nil }
                file = args[index]
                index += 1
                continue
            }
            if let taken = address.take(word, args, &index) {
                guard taken else { return nil }
                continue
            }
            guard !word.hasPrefix("-") else { return nil }
        }
        guard text == nil else { return nil }
        text = word
    }
    guard address.namesOneSession, address.provider == nil,
          let body = messageBody(file: file, text: text) else { return nil }
    // The provider is folded in only where there is a directory for it to narrow, exactly as the
    // typing verb folds it (SessionSendVerb.swift): everywhere else it travels beside the request
    // and is checked once the address has become a session key.
    var intent = SessionSendIntent(text: "", session: address.session, project: address.project)
    if intent.project != nil { intent.provider = provider }
    return MessageAddressRequest(provider: provider, intent: intent, body: body, dryRun: dryRun)
}

/// The native address a supervised session publishes: the socket Claude Code is listening on,
/// paired with the transcript UUID of the conversation on it.
///
/// READ OFF THE INVENTORY rather than recomputed. The guards that make that pair honest live in
/// SessionInventory.swift - a socket that is really there, an account sidecar matching the context
/// reading, a transcript stamped by the live child - and a second reading of them here would be
/// free to disagree with the `tally status --json` every caller is told to look at.
///
/// THE GIT IDENTITY IS STUBBED OUT, which is a cost rather than a judgement: resolving it is
/// several subprocesses per directory and nothing here reads `directory` or `project`.
///
/// A POINT-IN-TIME ADDRESS, as the report's own documentation says: the conversation can end
/// between this lookup and the write, and the write is bytes on a socket rather than a receipt.
func nativeSessionAddress(sessionKey: String,
                          inventory: [StatusReport.Session]? = nil,
                          dir: URL = supervisorStateDir) -> (socket: String, session: String)? {
    let sessions = inventory ?? sessionReadings(identity: { _ in (nil, nil) }).sessions
    // Joined on the CHILD pid, because that is the only pid the report publishes: the session key
    // is the supervisor, and the roster entry is looked up through the same reader every other
    // supervisor-to-child question goes through.
    guard let child = readSupervisorChild(pid: sessionKey, dir: dir),
          let session = sessions.first(where: { $0.pid == child }),
          let socket = session.messagingSocket,
          let transcript = session.transcriptSessionID else { return nil }
    return (socket, transcript)
}

/// Why a session that was found cannot be written to this way. Pure, so the wording is assertable,
/// and worded like every other refusal here: nothing of yours was sent, and here is what to type
/// instead.
func nativeAddressMissing(sessionKey: String) -> String {
    "session \(sessionKey) publishes no native address right now, so nothing was sent. A message "
        + "needs both the socket Claude Code is listening on and the transcript UUID of the "
        + "conversation on it, and `tally status --json` publishes that pair under "
        + "sessions[].messagingSocket and sessions[].transcriptSessionID only while both can be "
        + "proved. Type into it with `tally type claude` instead, or try again once that session "
        + "has had a turn"
}

/// Why a Codex session cannot be named rather than addressed.
let codexMessageAddressRefusal = """
`tally message codex` takes an explicit address only, so nothing was sent: \(codexMessageForm)

A Codex home and thread are not published for a supervised session the way a Claude socket and
transcript UUID are, so there is nothing here to look one up in and naming the session would mean
guessing which conversation the message lands in. To reach a supervised Codex session without an
address, type into its terminal instead: `tally type codex <text>`.
"""

let messageVerbUsage = """
usage: tally message <claude|codex> [<text> | --file <absolute-file>]
                     [--project <dir-or-name> | --session <pid>] [--dry-run]
       \(claudeMessageForm)
       \(codexMessageForm)

Hands one message to a session's own native transport: it appears in that conversation as a user
message, and nothing is typed and no key is pressed. `tally type <claude|codex>` is the other
thing: that one types into the terminal and presses Return, which is what answers a permission
dialog or runs a slash command. NEITHER IS A RECEIPT - a written frame is bytes on a socket, and a
queued line is a line behind somebody's turn.

The word after `message` is required and says which kind of session is meant; one that turns out to
be the other kind is refused rather than written to. With neither address flag the target is the
session this command runs in. --session <pid> names another one by either of its pids, and --project
takes the directory a session was launched in or a bare PROJECT NAME, matched against the last
component of each directory on the roster exactly and with its case. The two flags are alternatives,
and there is no --provider flag here because the position already answered that question.

For Claude the socket and transcript UUID are looked up in the same roster `tally status --json`
publishes them in, and a session that publishes neither is refused rather than guessed at. CODEX IS
EXPLICIT-ONLY: nothing publishes which home and thread a supervised Codex session writes to, so it
takes the address written out in full.

The message is one argument or --file <absolute-file>, never both: nonempty UTF-8 of at most 65536
bytes, and Codex rejects NUL bytes. Every message carries a trust prefix marking it as unverified
agent input rather than anything its recipient was authorised by. --dry-run reports the address and
writes nothing.

Exit codes: 0 written or queued (which is not a receipt); 2 usage, or a message this transport
refused; 3 no session was addressed; 1 the transport failed.
"""

/// `tally message <claude|codex> …`: both grammars, one verb.
func runMessage(args: [String]) -> Int32 {
    guard let provider = args.first, sessionProviderNames.contains(provider) else {
        warn(messageVerbUsage)
        return 2
    }
    // The explicit grammar is answered by the half that owns it, unchanged: this is the same
    // command it has always been, now with a way to name a session instead (NativeMessage.swift).
    if messageVerbIsExplicit(args) { return runNativeMessage(args: args) }
    guard let request = messageAddressRequest(args) else {
        warn(messageVerbUsage)
        return 2
    }
    guard provider == "claude" else {
        warn(codexMessageAddressRefusal)
        return 2
    }
    // A DIRECTORY BECOMES A PID HERE, through the one lookup the typing verb uses, so a directory
    // that names no session or more than one is refused in the same words and nothing is sent.
    var intent = request.intent
    if intent.project != nil {
        switch resolveSessionProject(intent, sessions: liveSessionProjectCandidates()) {
        case .addressed(let addressed):
            intent = addressed
        case .refused(let why):
            warn(why)
            return 3
        }
    }
    let marker = SessionMarkerTrust.trusted(liveSessionMarker())
    let sessionKey: String
    switch addressedSessionKey(intent, marker: marker) {
    case .session(let key):
        sessionKey = key
    case .monitoringOnly(let key):
        // A monitored Codex supervisor reached by `tally message claude`: the provider check is the
        // answer it deserves, rather than the terminal-input refusal, because nothing was going to
        // be typed either way.
        warn(sessionProviderMismatch(wanted: provider, found: "codex", sessionKey: key,
                                     verb: "message")
            ?? codexMessageAddressRefusal)
        return 3
    case .refused(let why):
        warn(why)
        return 3
    }
    // WHICH KIND OF SESSION THIS TURNED OUT TO BE, asked where all three ways of naming one have
    // become the same key, and before anything is written.
    if let mismatch = sessionProviderMismatch(
        wanted: provider, found: sessionProviderName(sessionKey: sessionKey, dir: supervisorStateDir),
        sessionKey: sessionKey, verb: "message") {
        warn(mismatch)
        return 3
    }
    guard let address = nativeSessionAddress(sessionKey: sessionKey) else {
        warn(nativeAddressMissing(sessionKey: sessionKey))
        return 3
    }
    return deliverClaudeNativeMessage(socket: address.socket, session: address.session,
                                      body: request.body, dryRun: request.dryRun)
}
