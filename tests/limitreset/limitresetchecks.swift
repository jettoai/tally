import Foundation

// Assertion harness for Claude's weekly session-limit reset, over the two Foundation-only files
// that hold every rule about it: the state machine and the record (Tally/Core/LimitReset.swift),
// and the transcript matcher (TallyCLI/LimitResetSignals.swift).
//
// WHAT THIS SUITE IS FOR, and what it deliberately cannot be. Nothing on this machine is in
// Anthropic's rollout for `/limit-reset` (`tengu_nifty_lemur`), so no fixture here comes from a
// live run: the sentences are read off the 2.1.263 binary's own string table, and the cap
// sentences are read off this machine's real transcripts. So what is asserted is that the code
// answers correctly for the sentences the PRODUCT contains, and every case where it cannot know is
// asserted to answer "unknown" rather than to guess.
//
// The supervisor's own decision table (which wall, which gates, what a timeout does) lives in
// tests/supervisor/caplimitresetchecks.swift, where the loop's dependencies are already compiled.

func runLimitResetChecks() {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)   // 2026-09-21T…, a fixed clock
    let hour: TimeInterval = 3_600
    let day: TimeInterval = 86_400

    // MARK: - The sentences, exactly as the product spells them

    // EVERY ONE OF THESE IS A LITERAL FROM THE BINARY, joined the way the product joins its clauses
    // (a middle dot). They are what the whole feature reads, so they are written out here rather than
    // built from `LimitResetPhrase`: a fixture assembled from the same constant the code matches
    // against would be green for a phrase that had drifted away from what Claude Code actually prints.
    let sentenceReset = "Session limit reset · next reset available Sep 28 at 5am (Asia/Taipei) · "
        + "your weekly limit still applies"
    let sentenceUsed = "Weekly reset used · available again Sep 28 at 5am (Asia/Taipei)"
    let sentenceUnavailable = "A session-limit reset isn't available right now."
    let sentenceLogin = "Couldn't reset your session limit with this login · run /login, then try again"
    let sentenceTransient = "Couldn't reset your session limit right now · try again in a moment"
    let sentenceInProgress = "Your session limit is already being reset · one moment"
    let sentenceNotice = "/limit-reset to reset your session limit now · uses weekly limit · 1/week"
    let sentenceUnknown = "Unknown command: /limit-reset"

    func outcome(_ text: String) -> LimitResetOutcome? { limitResetSignal(inText: text) }

    if case .reset(let next)? = outcome(sentenceReset) {
        expect(true, "the success sentence is read as a reset")
        expect(next != nil, "…and its next-available date is read out of it")
    } else {
        expect(false, "the success sentence is read as a reset")
        expect(false, "…and its next-available date is read out of it")
    }
    if case .alreadyUsed(let again)? = outcome(sentenceUsed) {
        expect(true, "the spent sentence is read as already used")
        expect(again != nil, "…and its return date is read out of it")
    } else {
        expect(false, "the spent sentence is read as already used")
        expect(false, "…and its return date is read out of it")
    }
    expect(outcome(sentenceUnavailable) == .unavailable, "the refusal is read as unavailable")
    expect(outcome(sentenceLogin) == .loginRequired, "the login sentence is read as login required")
    expect(outcome(sentenceTransient) == .transient, "the try-again sentence is read as transient")
    expect(outcome(sentenceInProgress) == .inProgress, "the one-moment sentence is read as in progress")
    expect(outcome(sentenceNotice) == .noticeAvailable, "the wall notice is read as a reset to spend")
    expect(outcome(sentenceUnknown) == .notEnabled,
           "a Claude Code without the command is read as not enabled")

    // THE ONE REFUSAL THAT MUST NOT BE READ AS THIS FEATURE'S. Claude Code prints the same sentence for
    // every slash command it does not know, so a mistyped one would mark the account as outside the
    // rollout for a week.
    expect(outcome("Unknown command: /limti-reset") == nil,
           "another command's Unknown answer says nothing about this account")

    // AND THE SENTENCES THIS FEATURE HAS NOTHING TO DO WITH. The cap message names a session limit in
    // so many words, and it arrives on the very lines this matcher reads.
    expect(outcome("You've hit your session limit · resets 4:20pm (Asia/Taipei)") == nil,
           "the 5-hour wall itself is not a statement about the reset")
    expect(outcome("You've hit your weekly limit · resets 5am (Asia/Taipei) · progress saved") == nil,
           "…nor is the weekly wall")
    expect(outcome("Current session: 63% used · resets Sep 21 at 3:19am (Asia/Taipei)") == nil,
           "…nor is a /usage line")
    expect(outcome("") == nil, "…and an empty string says nothing")

    // PRECEDENCE, which is the one pair that can genuinely collide: a chunk carrying both the notice
    // and the spent line is a session that has spent it.
    expect(outcome(sentenceUsed + "\n" + sentenceNotice) == .alreadyUsed(availableAgain: nil)
            || { if case .alreadyUsed = outcome(sentenceUsed + "\n" + sentenceNotice) { return true }
                 return false }(),
           "a chunk holding both the notice and the spent line reads as spent")

    // MARK: - ANSI, which a TUI puts inside these sentences

    // MEASURED SHAPE, not an invented one: this machine's own transcripts hold
    // `Kept model as \u{1B}[1mFable 5\u{1B}[22m` in a local-command record, so a bolded date inside one
    // of these sentences is the ordinary case rather than the exotic one.
    let bolded = "Session limit reset · next reset available \u{1B}[1mSep 28 at 5am (Asia/Taipei)"
        + "\u{1B}[22m · your weekly limit still applies"
    if case .reset(let next)? = outcome(bolded) {
        expect(true, "a sentence with a bolded date is still read as a reset")
        expect(next != nil, "…and the date inside the escapes is still read")
    } else {
        expect(false, "a sentence with a bolded date is still read as a reset")
        expect(false, "…and the date inside the escapes is still read")
    }
    expect(limitResetPlainText("a\u{1B}[31mb\u{1B}[0mc") == "abc", "CSI sequences are taken out whole")
    expect(limitResetPlainText("plain") == "plain", "…and text without any is untouched")
    expect(limitResetPlainText("a\u{1B}b") == "ab", "…and a lone escape is dropped rather than kept")

    // MARK: - The prefilter, paired against the phrases it has to cover

    // THE PAIRING IS ASSERTED RATHER THAN COMMENTED, because the prefilter is case-sensitive and the
    // success sentence starts with a capital: a token list that missed it would leave the ONE outcome
    // that matters unobserved, with every other check in this file still green (the matcher itself
    // never sees the line).
    for (name, sentence) in [("reset", sentenceReset), ("used", sentenceUsed),
                             ("unavailable", sentenceUnavailable), ("login", sentenceLogin),
                             ("transient", sentenceTransient), ("in progress", sentenceInProgress),
                             ("notice", sentenceNotice), ("unknown command", sentenceUnknown)] {
        expect(limitResetPrefilter.contains { sentence.contains($0) },
               "the prefilter lets the \(name) sentence reach the matcher")
    }

    // MARK: - One transcript line, in the two shapes these sentences arrive in

    /// A `local_command` record, the shape measured on this machine for `/usage`, `/model` and
    /// `/clear`.
    func localCommandLine(_ text: String) -> String {
        let object: [String: Any] = ["type": "system", "subtype": "local_command",
                                     "content": "<local-command-stdout>\(text)</local-command-stdout>"]
        return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    /// An api-error message body, which is how the wall itself arrives.
    func apiErrorLine(_ text: String) -> String {
        let object: [String: Any] = ["type": "assistant", "isApiErrorMessage": true,
                                     "message": ["role": "assistant", "content": text]]
        return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    /// …and the array-of-parts form of the same thing.
    func apiErrorPartsLine(_ text: String) -> String {
        let object: [String: Any] = ["type": "assistant", "isApiErrorMessage": true,
                                     "message": ["role": "assistant",
                                                 "content": [["type": "text", "text": text]]]]
        return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    func lineOutcome(_ line: String) -> LimitResetOutcome? { limitResetSignal(inLine: Substring(line)) }

    expect(lineOutcome(localCommandLine(sentenceUsed)) == .alreadyUsed(availableAgain: nil)
            || { if case .alreadyUsed = lineOutcome(localCommandLine(sentenceUsed)) { return true }
                 return false }(),
           "a local-command record carries the command's answer")
    expect(lineOutcome(apiErrorLine("You've hit your session limit · resets 4:20pm (Asia/Taipei) · "
                                    + sentenceNotice)) == .noticeAvailable,
           "a wall message carrying the notice is read off the api-error body")
    expect(lineOutcome(apiErrorPartsLine(sentenceNotice)) == .noticeAvailable,
           "…and out of the array-of-parts form of that body too")
    expect(lineOutcome(localCommandLine("nothing to do with resets")) == nil,
           "an ordinary local command says nothing")
    expect(lineOutcome("{not json") == nil, "…and a line that is not JSON says nothing rather than trapping")

    // MARK: - Which RECORDS may speak, which is not the same as which lines hold the words

    // THE MEASURED LEAK. A transcript is mostly the CONVERSATION - what a person typed, what the
    // assistant wrote, what a tool returned - and the sentences this feature reads are exactly the text
    // a session working on the feature quotes all day: the transcript of the session that reviewed this
    // file held six lines containing "Weekly reset used", every one of them an ordinary message.
    // Reading those would settle this account's record for the week on the strength of somebody
    // DISCUSSING the reset, and the panel would draw a spent credit that nobody spent. So the record
    // TYPE is the gate: `system`/`local_command` for the command's own answer, `isApiErrorMessage` for
    // the wall notice, and nothing else speaks.

    /// The commonest measured shape of the leak: an assistant turn whose body is a string.
    func conversationLine(_ type: String, _ text: String) -> String {
        let object: [String: Any] = ["type": type, "userType": "external", "isSidechain": false,
                                     "version": "2.1.263",
                                     "message": ["role": type, "content": text]]
        return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    /// …and the array-of-parts form, which is what the six measured lines actually were.
    func conversationPartsLine(_ type: String, _ text: String) -> String {
        let object: [String: Any] = ["type": type, "userType": "external", "isSidechain": false,
                                     "version": "2.1.263",
                                     "message": ["role": type,
                                                 "content": [["type": "text", "text": text]]]]
        return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    /// A working note of the kind those six lines were: prose quoting the product's own sentences.
    let quotingNote = "Read off the 2.1.263 binary: \"Session limit reset · next reset available "
        + "{date}\" for the success case and \"Weekly reset used · available again {date}\" for a week "
        + "whose credit is gone."

    for type in ["user", "assistant"] {
        expect(lineOutcome(conversationLine(type, sentenceUsed)) == nil,
               "a \(type) message saying the spent sentence is not this account spending it")
        expect(lineOutcome(conversationPartsLine(type, sentenceUsed)) == nil,
               "…nor is the array-of-parts form of that message")
        expect(lineOutcome(conversationPartsLine(type, quotingNote)) == nil,
               "…nor is a \(type) note quoting the sentences, which is the shape measured on this machine")
        expect(lineOutcome(conversationLine(type, sentenceReset)) == nil,
               "…and a \(type) message quoting the SUCCESS sentence does not spend the week either")
        expect(lineOutcome(conversationLine(type, sentenceNotice)) == nil,
               "…and one quoting the wall notice does not hand the account a credit")
    }
    // A TOP-LEVEL `content` ON A RECORD THAT IS NOT A LOCAL COMMAND: ten `queue-operation` entries in
    // this machine's history carry one, and what they carry is a quoted wall message.
    expect(lineOutcome(#"{"type":"queue-operation","operation":"enqueue","content":"Weekly reset used · available again Sep 28 at 5am (Asia/Taipei)"}"#) == nil,
           "a queued-message record is not the command's own answer")
    expect(lineOutcome(#"{"type":"system","subtype":"hook_result","content":"Weekly reset used · available again Sep 28 at 5am (Asia/Taipei)"}"#) == nil,
           "…and neither is a system record of some other subtype")
    // AND THE FLAG IS THE FLAG, not the words: an assistant turn is only the product speaking when
    // Claude Code itself marked it as an api error.
    expect(lineOutcome(#"{"type":"assistant","message":{"role":"assistant","content":"You've hit your session limit · /limit-reset to reset your session limit now · uses weekly limit · 1/week"}}"#) == nil,
           "a wall sentence in an unflagged assistant message says nothing")
    // THE TWO THAT MUST STILL SPEAK, asserted here as well so a gate that silenced everything would be
    // caught by this section rather than only by the one above it.
    expect(lineOutcome(localCommandLine(sentenceReset)) != nil,
           "the command's own answer is still read out of a local-command record")
    expect(lineOutcome(apiErrorPartsLine(sentenceNotice)) == .noticeAvailable,
           "…and the wall notice is still read out of a flagged api-error body")

    // MARK: - Which wall a cap was

    // THE MOTHER SET IS COUNTED, NOT IMAGINED: these are the three shapes all 78 `You've …` events in
    // this machine's `~/.claude/projects` fall into.
    expect(capScope(ofBody: "You've hit your session limit · resets 4:20pm (Asia/Taipei)") == .session,
           "the 5-hour wall is named as the session one")
    expect(capScope(ofBody: "You've hit your session limit · resets 2pm (Asia/Taipei) · progress saved")
            == .session, "…including the form that carries the progress tail")
    expect(capScope(ofBody: "You've hit your weekly limit · resets Aug 9 at 5am (Asia/Taipei)") == .weekly,
           "the weekly wall is named as the weekly one")
    expect(capScope(ofBody: "You've reached your Fable 5 limit. Run /usage-credits to continue or "
                    + "switch models with /model.") == .model,
           "a model-tier wall is named as the model one")
    // FAIL-CLOSED FOR THE ONE CONSUMER THIS HAS: only `session` spends a reset, so a sentence this
    // build cannot name must not be one.
    expect(capScope(ofBody: "You've hit some future limit nobody here has seen") == .model,
           "a wall this build cannot name is not read as the one that spends a credit")

    // MARK: - Reading a date out of a sentence

    // The two shapes this product writes a reset stamp in, taken from the same corpus as the walls
    // above. A third shape is possible and answers nil rather than a guess.
    expect(limitResetStamp(after: "available again ",
                           in: "Weekly reset used · available again Sep 28 at 5am (Asia/Taipei)",
                           now: t0) != nil,
           "a dated stamp is read")
    expect(limitResetStamp(after: "available again ",
                           in: "Weekly reset used · available again 5:30am (Asia/Taipei)",
                           now: t0) != nil,
           "…and so is the time-only form")
    expect(limitResetStamp(after: "available again ",
                           in: "Weekly reset used · available again next Tuesday", now: t0) == nil,
           "a shape nobody has observed answers nothing rather than a guess")
    expect(limitResetStamp(after: "available again ", in: "Weekly reset used", now: t0) == nil,
           "…as does a sentence with no date in it at all")
    // A TIME WITH NO DATE IS THE NEXT OCCURRENCE, never the last one. Both markers this reads name a
    // future moment, so "available again 5am" read at 06:00 is TOMORROW's 5am. Read as the closest
    // occurrence in either direction it would be 55 minutes in the past, and a past `nextAvailableAt`
    // is the one value `limitResetEffective` turns back into `available`: a credit spent an hour ago
    // would be drawn as one still there, and the automatic path would spend the wait finding out.
    var taipei = Calendar(identifier: .gregorian)
    taipei.timeZone = TimeZone(identifier: "Asia/Taipei")!
    let sentenceTimeOnly = "Weekly reset used · available again 5am (Asia/Taipei)"
    let sixAM = taipei.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 6))!
    if let stamp = limitResetStamp(after: "available again ", in: sentenceTimeOnly, now: sixAM) {
        expect(stamp > sixAM, "a clock time already past today is read as a future moment")
        expect(taipei.component(.day, from: stamp) == 22 && taipei.component(.hour, from: stamp) == 5,
               "…which is tomorrow at the hour the sentence named")
    } else {
        expect(false, "a clock time already past today is read as a future moment")
        expect(false, "…which is tomorrow at the hour the sentence named")
    }
    let fourAM = taipei.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 4))!
    if let stamp = limitResetStamp(after: "available again ", in: sentenceTimeOnly, now: fourAM) {
        expect(taipei.component(.day, from: stamp) == 21 && taipei.component(.hour, from: stamp) == 5,
               "…and one still to come today is today's, not tomorrow's")
    } else {
        expect(false, "…and one still to come today is today's, not tomorrow's")
    }

    // THE YEAR IS THE CLOSEST OCCURRENCE, past allowed - the rule its app-side sibling established, so
    // a stamp read minutes after its moment stays "just passed" rather than jumping a year.
    if let stamp = limitResetStamp(after: "x ", in: "x Sep 28 at 5am (Asia/Taipei)", now: t0) {
        expect(abs(stamp.timeIntervalSince(t0)) < 200 * day,
               "the year chosen puts the stamp near now rather than a year out")
    } else {
        expect(false, "the year chosen puts the stamp near now rather than a year out")
    }

    // MARK: - Folding an observation into the record

    func fold(_ record: LimitResetRecord?, _ result: LimitResetOutcome,
              at when: Date = t0) -> LimitResetRecord? {
        limitResetFold(record, outcome: result, now: when)
    }

    let afterReset = fold(nil, .reset(nextAvailableAt: t0.addingTimeInterval(7 * day)))
    expect(afterReset?.state == .used,
           "a reset that LANDED spends the week's credit, so the record reads used")
    expect(afterReset?.nextAvailableAt == t0.addingTimeInterval(7 * day),
           "…and carries the date the next one arrives")
    expect(afterReset?.enabledSeenAt == t0, "…and records that this login has the feature")

    expect(fold(nil, .alreadyUsed(availableAgain: t0.addingTimeInterval(2 * day)))?.state == .used,
           "the spent sentence reads used")
    expect(fold(nil, .noticeAvailable)?.state == .available, "the wall notice reads available")
    expect(fold(nil, .noticeAvailable)?.nextAvailableAt == nil,
           "…and names no date, because the notice names none")
    expect(fold(nil, .notEnabled)?.state == .notEnabled, "the unknown-command answer reads not enabled")
    expect(fold(nil, .notEnabled)?.enabledSeenAt == nil,
           "…and records no sighting of a feature this login does not have")
    // THE REFUSAL IS THE INTERESTING ONE: the command clearly exists, and it does not say WHY it
    // refused, so nothing may be concluded about the credit.
    expect(fold(nil, .unavailable)?.state == .unknown,
           "a refusal that names no reason settles nothing about the credit")
    expect(fold(nil, .unavailable)?.enabledSeenAt == t0,
           "…while still recording the one thing it did establish")
    expect(fold(nil, .loginRequired)?.state == .unknown, "a login refusal settles nothing either")

    // AND THE TWO THAT MUST LEAVE THE RECORD ALONE, stamp included: moving `observedAt` on a sentence
    // that decided nothing would keep an ageing state alive on evidence that said nothing.
    let standing = LimitResetRecord(state: .used, nextAvailableAt: nil, enabledSeenAt: t0,
                                    observedAt: t0)
    expect(fold(standing, .inProgress, at: t0.addingTimeInterval(hour)) == standing,
           "an in-progress answer leaves the record exactly as it was")
    expect(fold(standing, .transient, at: t0.addingTimeInterval(hour)) == standing,
           "…and so does a transient failure")

    // WHICH SENTENCE WROTE THE RECORD, which the state alone cannot say. The success line and the
    // "already used" line BOTH fold to `used` and BOTH carry a date, so the app waiting on a press it
    // just sent has no way to tell "your wall is cleared" from "this week's credit was already gone"
    // unless the record remembers which sentence it saw.
    expect(fold(nil, .reset(nextAvailableAt: t0))?.lastSignal == LimitResetSignalName.reset,
           "a reset that landed is remembered as a reset")
    expect(fold(nil, .alreadyUsed(availableAgain: t0))?.lastSignal == LimitResetSignalName.alreadyUsed,
           "…and the spent sentence as already used, though both folded to the same state")
    expect(fold(nil, .reset(nextAvailableAt: t0))?.state
            == fold(nil, .alreadyUsed(availableAgain: t0))?.state,
           "…which matters precisely because the state they fold to is the same one")
    expect(fold(nil, .noticeAvailable)?.lastSignal == LimitResetSignalName.noticeAvailable,
           "the wall notice is remembered as the notice")
    expect(fold(nil, .unavailable)?.lastSignal == LimitResetSignalName.unavailable,
           "a refusal is remembered as a refusal rather than as nothing observed")
    expect(fold(nil, .loginRequired)?.lastSignal == LimitResetSignalName.loginRequired,
           "…and a login refusal as its own answer, though both leave the credit unknown")
    expect(fold(nil, .notEnabled)?.lastSignal == LimitResetSignalName.notEnabled,
           "the unknown-command answer is remembered as not enabled")
    // AND THE TWO THAT SETTLE NOTHING NAME NOTHING, so a record cannot come to carry a signal it was
    // never told: they return the record untouched, stamp and signal included.
    expect(LimitResetOutcome.inProgress.signalName == nil && LimitResetOutcome.transient.signalName == nil,
           "the two sentences that settle nothing have no name in the record")

    // MARK: - What the record MEANS, which is not always what it says

    func effective(_ record: LimitResetRecord?, after seconds: TimeInterval = 0) -> LimitResetState {
        limitResetEffective(record, now: t0.addingTimeInterval(seconds))
    }

    expect(effective(nil) == .unknown, "an account nothing was observed about reads unknown")
    expect(effective(LimitResetRecord(state: .available, observedAt: t0)) == .available,
           "an available record reads available")
    // THE ONE RULE THAT CAN RAISE A STATE, and it fires only on a date Claude Code itself named.
    let dated = LimitResetRecord(state: .used, nextAvailableAt: t0.addingTimeInterval(3 * day),
                                 enabledSeenAt: t0, observedAt: t0)
    expect(effective(dated, after: 2 * day) == .used, "a spent reset stays spent before its return date")
    expect(effective(dated, after: 3 * day) == .available,
           "…and is available again the moment that date arrives")
    expect(effective(dated, after: 4 * day) == .available, "…and stays available after it")
    // A SPENT RECORD WITH NO DATE AGES INTO NOT KNOWING, never into available: the week has certainly
    // turned over, but nothing has said so.
    let undated = LimitResetRecord(state: .used, observedAt: t0)
    expect(effective(undated, after: 6 * day) == .used, "a spent reset with no date holds for a week")
    expect(effective(undated, after: 8 * day) == .unknown, "…and then reads unknown rather than available")
    // AND SO DOES A ROLLOUT VERDICT, in the other direction: the rollout moves, and a badge that never
    // re-asked would be permanent.
    let notEnabled = LimitResetRecord(state: .notEnabled, observedAt: t0)
    expect(effective(notEnabled, after: 6 * day) == .notEnabled, "a not-enabled verdict holds for a week")
    expect(effective(notEnabled, after: 8 * day) == .unknown, "…and then goes back to not knowing")

    // MARK: - The record on disk

    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-limitreset-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let round = LimitResetRecord(state: .used, nextAvailableAt: t0.addingTimeInterval(day),
                                 enabledSeenAt: t0, observedAt: t0)
    writeLimitReset(round, accountID: "claude:.claude5", dir: dir)
    expect(readLimitReset(accountID: "claude:.claude5", dir: dir) == round,
           "a record round-trips through the sidecar")
    expect(readLimitReset(accountID: "claude:.nobody", dir: dir) == nil,
           "an account with no record reads nothing rather than a default")
    // AN ID WITH A SLASH IN IT still names one file rather than a directory that does not exist.
    writeLimitReset(round, accountID: "claude:/opt/homes/five", dir: dir)
    expect(readLimitReset(accountID: "claude:/opt/homes/five", dir: dir) == round,
           "an account id carrying a slash still round-trips")

    // THE SIGNAL TRAVELS WITH THE RECORD, because the process that reads it is not the one that wrote
    // it: a supervisor sees the sentence, the app waiting on a press reads the file.
    let signed = LimitResetRecord(state: .used, nextAvailableAt: t0.addingTimeInterval(day),
                                  enabledSeenAt: t0, observedAt: t0,
                                  lastSignal: LimitResetSignalName.alreadyUsed)
    writeLimitReset(signed, accountID: "claude:.signed", dir: dir)
    expect(readLimitReset(accountID: "claude:.signed", dir: dir) == signed,
           "the sentence a record was written by round-trips with it")

    // ADDITIVE-ONLY, the rule this record is under: a payload written before a field existed has to
    // READ, because a decode failure is treated as "no record" and would forget a spent reset.
    try? Data(#"{"state":"used"}"#.utf8)
        .write(to: limitResetFile(accountID: "claude:.old", dir: dir))
    expect(readLimitReset(accountID: "claude:.old", dir: dir)?.state == .used,
           "a record written before the other fields existed still decodes")
    expect(readLimitReset(accountID: "claude:.old", dir: dir)?.observedAt == .distantPast,
           "…and its missing stamp reads as the distant past rather than as now")
    try? Data("{}".utf8).write(to: limitResetFile(accountID: "claude:.empty", dir: dir))
    expect(readLimitReset(accountID: "claude:.empty", dir: dir)?.state == .unknown,
           "…and an empty document reads unknown")
    expect(readLimitReset(accountID: "claude:.old", dir: dir)?.lastSignal == nil,
           "…and a record from before the signal existed names none rather than failing to decode")

    // MARK: - The settings document

    let settingsFile = dir.appendingPathComponent("settings.json")
    expect(readLimitResetSettings(url: settingsFile).autoReset,
           "a machine with no settings file has the automatic path ON")
    expect(!readLimitResetSettings(url: settingsFile).noticeShown,
           "…and has not yet said its one-time notice")
    writeLimitResetSettings(LimitResetSettings(autoReset: false, noticeShown: true), url: settingsFile)
    expect(!readLimitResetSettings(url: settingsFile).autoReset
            && readLimitResetSettings(url: settingsFile).noticeShown,
           "the switch and the notice round-trip")
    try? Data(#"{"noticeShown":true}"#.utf8).write(to: settingsFile)
    expect(readLimitResetSettings(url: settingsFile).autoReset,
           "a document written before the switch existed still reads as ON")

    // MARK: - Which session the button would type into

    func target(_ key: String, account: String = "A", reporting: Bool = true,
                waiting: Bool = false, at seconds: TimeInterval = 0) -> LimitResetTarget {
        LimitResetTarget(sessionKey: key, accountID: account, isReporting: reporting,
                         waitingOnPerson: waiting, updatedAt: t0.addingTimeInterval(seconds))
    }

    expect(limitResetTarget([], accountID: "A") == nil, "no sessions at all is no target")
    expect(limitResetTarget([target("1", account: "B")], accountID: "A") == nil,
           "a session on another account is not a target for this one")
    expect(limitResetTarget([target("1", waiting: true)], accountID: "A") == nil,
           "a session sitting on a dialog is never typed at")
    expect(limitResetTarget([target("1")], accountID: "A")?.sessionKey == "1",
           "the one session on this account is the target")
    expect(limitResetTarget([target("1", at: 0), target("2", at: 60)],
                            accountID: "A")?.sessionKey == "2",
           "the freshest publisher wins between equals")
    expect(limitResetTarget([target("1", reporting: false, at: 600), target("2", at: 0)],
                            accountID: "A")?.sessionKey == "2",
           "a session that reports nothing about itself comes last, however fresh")
    expect(limitResetTarget([target("1", waiting: true, at: 600), target("2", at: 0)],
                            accountID: "A")?.sessionKey == "2",
           "…and a dialog session is skipped in favour of one that can be typed into")

    // MARK: - The button's enable matrix

    expect(limitResetPressable(state: .available, hasSession: true, busy: false, demo: false),
           "available, with a session to type into: pressable")
    expect(!limitResetPressable(state: .available, hasSession: false, busy: false, demo: false),
           "available with nothing running: nowhere to send the command, so not pressable")
    expect(!limitResetPressable(state: .used, hasSession: true, busy: false, demo: false),
           "already used: not pressable")
    expect(!limitResetPressable(state: .notEnabled, hasSession: true, busy: false, demo: false),
           "not in the rollout: not pressable")
    expect(!limitResetPressable(state: .unknown, hasSession: true, busy: false, demo: false),
           "nothing observed: not pressable")
    expect(!limitResetPressable(state: .available, hasSession: true, busy: true, demo: false),
           "a press already in flight: not pressable again")
    expect(!limitResetPressable(state: .available, hasSession: true, busy: false, demo: true),
           "a demo fixture is never pressable, having no real session behind it")

    // MARK: - The one reading the panel makes of that signal

    // A SOURCE LOCK, on the terms other suites in this repo already lock a view's closure: the wait
    // that reads the answer (`LimitResetStore.waitForAnswer`) is @MainActor app code whose
    // dependencies are the whole app, so it cannot be compiled into this harness - and the rule it has
    // to keep is the exact reason `lastSignal` exists. Locking the two lines costs a file read; not
    // asserting it at all costs a green suite over a card that says "Session limit reset" on a week
    // whose credit was already gone.
    let storeSource = (try? String(contentsOfFile: "Tally/Stores/LimitResetStore.swift",
                                   encoding: .utf8)) ?? ""
    expect(!storeSource.isEmpty, "the store's source is where this expects it")
    let waitBody: String = {
        guard let start = storeSource.range(of: "func waitForAnswer"),
              let end = storeSource.range(of: "private func legacySpend",
                                          range: start.upperBound ..< storeSource.endIndex)
        else { return "" }
        return String(storeSource[start.upperBound ..< end.lowerBound])
    }()
    expect(!waitBody.isEmpty, "…and the wait is still the function this locks")
    expect(waitBody.contains("switch record.lastSignal"),
           "the wait decides on the sentence the supervisor saw")
    expect(waitBody.contains("LimitResetSignalName.reset")
            && waitBody.contains("LimitResetSignalName.alreadyUsed"),
           "…telling a reset that landed from a week already spent by name")
    expect(!waitBody.contains("nextAvailableAt"),
           "…and never by whether a date is present, which both of those sentences carry")

    try? FileManager.default.removeItem(at: dir)
}
