import Foundation

// Claude Code's own once-a-week session-limit reset (`/limit-reset`), as Tally observes it and as
// Tally spends it.
//
// WHAT THE FEATURE IS, in Anthropic's words rather than ours. A Claude account that has hit its
// 5-hour session wall may clear that wall on the spot, once a week, at the cost of the weekly
// limit it already has. Claude Code exposes it as an interactive slash command; there is no API
// for it, and Tally does not look for one (NORTH_STAR: nothing here impersonates a first-party
// client). Everything below therefore rests on two things a supervised session can see without a
// credential: what the command PRINTS, and what the wall notice says.
//
// SO THIS FILE IS A STATE MACHINE OVER OBSERVATIONS, never over an authority. Nothing here asks
// Anthropic anything. A state is written only when a session actually saw one of the sentences
// listed below, and an account nobody has seen one for reads `unknown` rather than `available` -
// which is the whole discipline this feature is under, because the alternative is a dashboard
// inventing a credit that is not there.
//
// THE ONE BLIND SPOT, named rather than papered over: a reset spent somewhere Tally is not
// watching (claude.ai in a browser, another machine, a bare `claude` outside a supervisor) is
// invisible here until that account next prints a sentence about it. Tally then shows `available`
// while the week's reset is gone, and the automatic path below spends one 20-second attempt
// discovering that before handing the session on exactly as it would have. The cost of the blind
// spot is that attempt; it is not a wrong number anybody acts on twice.
//
// WHY BOTH TARGETS COMPILE THIS, the rule every shared file in this repo is under: the SUPERVISOR
// observes (it is the only process tailing a transcript) and the APP draws and spends, so the two
// speak through `~/.tally/limit-reset/`. A second spelling of these sentences, or of the record,
// would be an app that draws nothing while every session observes correctly. Foundation only, so
// the CLI harness compiles it standalone.

// MARK: - What Claude Code says

/// The command itself, spelled once. Typed into a composer by the automatic path and by the
/// panel's button, and matched in a transcript by the observer, so the three cannot drift.
let limitResetCommand = "/limit-reset"

/// The sentences Claude Code prints, as literal fragments.
///
/// TAKEN FROM THE 2.1.263 BINARY (`strings`), not from documentation and not from a live run: this
/// account fleet is not in the rollout (`tengu_nifty_lemur`), so no machine here can produce one.
/// They are fragments rather than whole lines for two reasons: the product joins them with a
/// middle dot and interpolates a date, and a TUI may bold a word inside one, which puts an ANSI
/// escape in the middle of the sentence (`limitResetPlainText` takes those out first).
///
/// A FRAGMENT THAT STOPS MATCHING COSTS SILENCE, NOT A WRONG ANSWER, which is the direction this
/// whole file fails in: an unrecognised sentence leaves the record where it was, so the state ages
/// into `unknown` and the panel stops claiming anything.
enum LimitResetPhrase {
    /// "Session limit reset · next reset available {date} · your weekly limit still applies"
    static let reset = "Session limit reset"
    static let resetNextMarker = "next reset available "
    /// "Weekly reset used · available again {date}" - printed by the command AND at the wall.
    static let alreadyUsed = "Weekly reset used"
    static let usedAgainMarker = "available again "
    /// "A session-limit reset isn't available right now."
    static let unavailable = "session-limit reset isn't available right now"
    /// "Couldn't reset your session limit with this login · run /login, then try again"
    static let loginRequired = "Couldn't reset your session limit with this login"
    /// "Couldn't reset your session limit right now · try again in a moment"
    static let transient = "Couldn't reset your session limit right now"
    /// "Your session limit is already being reset · one moment"
    static let inProgress = "Your session limit is already being reset"
    /// The wall notice: "/limit-reset to reset your session limit now · uses weekly limit · 1/week"
    static let notice = "to reset your session limit now"
    /// What a Claude Code without the feature answers a slash command it does not know.
    static let unknownCommand = "Unknown command"
}

/// What one observed sentence means.
enum LimitResetOutcome: Equatable {
    /// The reset was performed. The week's credit is now SPENT, and the date is when the next one
    /// arrives, so this folds to `used` rather than to anything cheerful.
    case reset(nextAvailableAt: Date?)
    /// This week's reset is already gone.
    case alreadyUsed(availableAgain: Date?)
    /// The wall notice: this login has the feature and has a reset to spend.
    case noticeAvailable
    /// The command ran and refused. It does not say WHY (not at a wall, not eligible, already
    /// spent), so nothing may be concluded about the credit itself.
    case unavailable
    /// The login could not be used. The command exists, so the feature does.
    case loginRequired
    /// A reset is already under way, or the request failed transiently. Neither settles anything.
    case inProgress
    case transient
    /// This Claude Code does not have the command: the account is not in the rollout.
    case notEnabled
}

/// The names a folded outcome is remembered by in the record (`LimitResetRecord.lastSignal`).
/// SPELLED OUT RATHER THAN DERIVED from the case names: these go into a document an older or newer
/// build also reads, so renaming a case must not rename a value two builds agree on.
enum LimitResetSignalName {
    static let reset = "reset"
    static let alreadyUsed = "alreadyUsed"
    static let noticeAvailable = "noticeAvailable"
    static let unavailable = "unavailable"
    static let loginRequired = "loginRequired"
    static let notEnabled = "notEnabled"
}

extension LimitResetOutcome {
    /// What this observation is called in the record; nil for the two that settle nothing.
    var signalName: String? {
        switch self {
        case .reset: return LimitResetSignalName.reset
        case .alreadyUsed: return LimitResetSignalName.alreadyUsed
        case .noticeAvailable: return LimitResetSignalName.noticeAvailable
        case .unavailable: return LimitResetSignalName.unavailable
        case .loginRequired: return LimitResetSignalName.loginRequired
        case .notEnabled: return LimitResetSignalName.notEnabled
        case .inProgress, .transient: return nil
        }
    }
}

/// Strip ANSI escapes so a bolded word inside a sentence cannot break a fragment match.
///
/// Claude Code writes these into `local-command-stdout` (measured in this machine's own history:
/// `Kept model as \u{1B}[1mFable 5\u{1B}[22m`), and the reset sentences interpolate a date, which
/// is exactly the sort of thing a TUI emphasises. CSI sequences only, which is all a terminal
/// colour or weight is.
func limitResetPlainText(_ text: String) -> String {
    var out = ""
    out.reserveCapacity(text.count)
    var iterator = text.makeIterator()
    var pending: Character?
    while let character = pending ?? iterator.next() {
        pending = nil
        guard character == "\u{1B}" else { out.append(character); continue }
        guard let next = iterator.next() else { break }
        guard next == "[" else { pending = next; continue }
        // Consume up to and including the final byte of the CSI sequence (@ through ~).
        while let inner = iterator.next() {
            if inner.asciiValue.map({ $0 >= 0x40 && $0 <= 0x7E }) == true { break }
        }
    }
    return out
}

/// What a piece of text Claude Code printed says about this account's reset, or nil when it says
/// nothing about it at all.
///
/// THE ORDER IS THE PRECEDENCE, and only one pair can genuinely collide: the wall notice and the
/// "already used" line are both about the wall, and a session that prints both in one chunk has
/// spent it. So the settled answers are asked first and the notice last.
func limitResetSignal(inText raw: String) -> LimitResetOutcome? {
    let text = limitResetPlainText(raw)
    if text.contains(LimitResetPhrase.reset) {
        return .reset(nextAvailableAt: limitResetStamp(after: LimitResetPhrase.resetNextMarker,
                                                       in: text))
    }
    if text.contains(LimitResetPhrase.alreadyUsed) {
        return .alreadyUsed(availableAgain: limitResetStamp(after: LimitResetPhrase.usedAgainMarker,
                                                            in: text))
    }
    if text.contains(LimitResetPhrase.loginRequired) { return .loginRequired }
    if text.contains(LimitResetPhrase.transient) { return .transient }
    if text.contains(LimitResetPhrase.inProgress) { return .inProgress }
    if text.contains(LimitResetPhrase.unavailable) { return .unavailable }
    // Only when it is about THIS command: Claude Code prints the same refusal for every slash
    // command it does not know, and a session that mistypes one must not mark the account as
    // outside the rollout.
    if text.contains(LimitResetPhrase.unknownCommand), text.contains(limitResetCommand) {
        return .notEnabled
    }
    if text.contains(LimitResetPhrase.notice) { return .noticeAvailable }
    return nil
}

/// The date in "…{marker}{date}…", in the two shapes Claude Code demonstrably writes a reset stamp
/// in, or nil.
///
/// THE MOTHER SET IS THIS MACHINE'S OWN TRANSCRIPTS, not a guess: 78 wall messages and every
/// `/usage` block in `~/.claude/projects` write either "Sep 6 at 4:20pm (Asia/Taipei)" or
/// "4:20pm (Asia/Taipei)" (the on-the-hour form drops the minutes: "5am"). `{date}` in the reset
/// sentences is UNOBSERVED - no account here is in the rollout - so a third shape is possible, and
/// this answers nil for it rather than guessing. A nil date costs the record its expiry and
/// nothing else: the state then ages into `unknown` instead of flipping back to `available` on a
/// day nobody can name (`limitResetEffective`).
///
/// NOT `ClaudeUsageTextMapper.parseReset`, which is the app-only sibling pinned by
/// tests/claudereset. That one is anchored to the start of its string and requires the date half,
/// because it reads a `/usage` line whose shape is fixed; this one has to find a stamp inside a
/// sentence and accept the time-only form. Merging them would mean changing the behaviour of a
/// parser that already has an oracle, to serve one that has no live sample yet.
func limitResetStamp(after marker: String, in text: String, now: Date = Date()) -> Date? {
    guard let range = text.range(of: marker) else { return nil }
    let tail = String(text[range.upperBound...])
    let zone = tail.range(of: #"\(([^)]+)\)"#, options: .regularExpression)
        .map { String(tail[$0].dropFirst().dropLast()) }
        .flatMap(TimeZone.init(identifier:)) ?? .current
    let dated = #"^[A-Z][a-z]{2} \d{1,2} at \d{1,2}(:\d{2})?(am|pm)"#
    let timeOnly = #"^\d{1,2}(:\d{2})?(am|pm)"#
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = zone
    if let stampRange = tail.range(of: dated, options: .regularExpression) {
        formatter.dateFormat = "MMM d 'at' h:mma yyyy"
        return closestOccurrence(of: normalisedLimitResetStamp(String(tail[stampRange])),
                                 formatter: formatter, now: now)
    }
    guard let stampRange = tail.range(of: timeOnly, options: .regularExpression) else { return nil }
    // A time with no date is the NEXT occurrence of that clock time, never the last one: both
    // markers name a future moment, so "available again 5am" read at 06:00 is tomorrow's. Taking
    // the closest occurrence either way put it 55 minutes PAST, and a past date is the one value
    // `limitResetEffective` reads as "the reset is back" - a just-spent credit drawn as available.
    formatter.dateFormat = "MMM d 'at' h:mma yyyy"
    let clock = normalisedLimitResetStamp(String(tail[stampRange]))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return (0 ... 8).compactMap { offset -> Date? in
        guard let day = calendar.date(byAdding: .day, value: offset, to: now) else { return nil }
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = zone
        dayFormatter.dateFormat = "MMM d"
        return formatter.date(from: "\(dayFormatter.string(from: day)) at \(clock) "
                              + "\(calendar.component(.year, from: day))")
    }
    .filter { $0 >= now }
    .min()
}

/// "4am" -> "4:00am", so one format string parses both the on-the-hour and the minutes form. The
/// same normalisation `ClaudeUsageTextMapper` performs on the same product's stamps.
func normalisedLimitResetStamp(_ stamp: String) -> String {
    guard !stamp.contains(":"),
          let meridiem = stamp.range(of: #"(am|pm)$"#, options: .regularExpression)
    else { return stamp }
    var copy = stamp
    copy.insert(contentsOf: ":00", at: meridiem.lowerBound)
    return copy
}

/// The year that puts a bare "Sep 6 at 4:20pm" closest to now, past allowed. The rule
/// `ClaudeUsageTextMapper.parseReset` established: a stamp read minutes after its moment passed
/// must stay "just passed" rather than jumping a year ahead.
private func closestOccurrence(of stamp: String, formatter: DateFormatter, now: Date) -> Date? {
    let year = Calendar.current.component(.year, from: now)
    return (year - 1 ... year + 1)
        .compactMap { formatter.date(from: "\(stamp) \($0)") }
        .min { abs($0.timeIntervalSince(now)) < abs($1.timeIntervalSince(now)) }
}

// MARK: - The record

/// What Tally believes about one account's weekly session-limit reset.
enum LimitResetState: String, Codable, Equatable {
    /// A reset has been seen to be there and has not been seen spent since.
    case available
    /// This week's reset is gone.
    case used
    /// This login answers `/limit-reset` with "Unknown command": it is not in the rollout.
    case notEnabled
    /// Nothing has been observed, or what was observed has aged out of being worth showing. THE
    /// DEFAULT, and the answer the panel draws as no number at all.
    case unknown
}

/// One account's record, written by whichever supervisor saw the sentence.
///
/// EVERY FIELD DECODES KEY BY KEY for the reason `EarlyStartState` gives about its own: the
/// synthesized `Decodable` throws on a missing key, and a reader that treats a decode failure as
/// "no record" would forget an account's spent reset every time a field is added.
struct LimitResetRecord: Codable, Equatable {
    var state: LimitResetState = .unknown
    /// When the next reset arrives, where the sentence named a date. nil is ordinary rather than a
    /// failure: the wall notice names none, and an unparsed `{date}` shape names none either.
    var nextAvailableAt: Date?
    /// When this account was last seen to HAVE the feature at all, which is a different fact from
    /// having a reset to spend: it is what stops a `notEnabled` badge from standing over an account
    /// whose rollout arrived last week.
    var enabledSeenAt: Date?
    /// When this record was written. The clock every ageing rule below is measured against.
    var observedAt: Date = .distantPast
    /// Which sentence last wrote this record (`LimitResetSignalName`), or nil for a record written
    /// before this field existed.
    ///
    /// THE STATE IS NOT THE ANSWER: a reset that LANDED and one ALREADY SPENT both fold to `used`
    /// and both name a date, so a reader waiting on a command it sent cannot tell them apart from
    /// the state (`waitForAnswer` reported the second as the first until this existed).
    var lastSignal: String?
}

extension LimitResetRecord {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decodeIfPresent(LimitResetState.self, forKey: .state) ?? .unknown
        nextAvailableAt = try container.decodeIfPresent(Date.self, forKey: .nextAvailableAt)
        enabledSeenAt = try container.decodeIfPresent(Date.self, forKey: .enabledSeenAt)
        observedAt = try container.decodeIfPresent(Date.self, forKey: .observedAt) ?? .distantPast
        lastSignal = try container.decodeIfPresent(String.self, forKey: .lastSignal)
    }
}

/// How long a settled answer keeps speaking for itself.
///
/// A WEEK, because that is the cycle the feature runs on ("1/week"), and the two states it applies
/// to are the two that would otherwise be wrong for ever. A `used` with no date has nothing to
/// expire against; a `notEnabled` describes a rollout that will one day include this account and
/// says so from a sentence nobody will print again. Both age into `unknown` rather than into
/// `available`: not knowing is what Tally actually has, and `unknown` is the one state that costs
/// a single attempt to resolve rather than a wrong badge.
let limitResetStaleAfter: TimeInterval = 7 * 24 * 60 * 60

/// What the record MEANS right now, which is not always what it says.
///
/// Three rules, and every one of them moves toward saying less rather than more:
///
///  - a spent reset whose return date has arrived is available again (the one rule that can raise
///    a state, and it only fires on a date Claude Code itself named);
///  - a spent reset with no date, past a week, is `unknown`: the week has certainly turned over,
///    but nothing has said so, and "probably available" is not a state this app has;
///  - a `notEnabled` past a week is `unknown` for the same reason in the other direction - the
///    rollout moves, and a badge that never re-asks would be permanent.
func limitResetEffective(_ record: LimitResetRecord?, now: Date = Date()) -> LimitResetState {
    guard let record else { return .unknown }
    switch record.state {
    case .used:
        if let next = record.nextAvailableAt { return now >= next ? .available : .used }
        return now.timeIntervalSince(record.observedAt) > limitResetStaleAfter ? .unknown : .used
    case .notEnabled:
        return now.timeIntervalSince(record.observedAt) > limitResetStaleAfter ? .unknown : .notEnabled
    case .available, .unknown:
        return record.state
    }
}

/// Fold one observation into the record, or leave it exactly as it was.
///
/// `inProgress` and `transient` return the record untouched, INCLUDING its `observedAt`: neither
/// sentence settles anything, and moving the stamp would keep an ageing state alive on evidence
/// that said nothing. `unavailable` is the interesting one: the command clearly exists (it ran and
/// answered), but it does not say why it refused - not at a wall, not eligible, already spent are
/// all the same sentence - so the credit goes to `unknown` while `enabledSeenAt` records the one
/// thing that WAS established.
func limitResetFold(_ record: LimitResetRecord?, outcome: LimitResetOutcome,
                    now: Date = Date()) -> LimitResetRecord? {
    var next = record ?? LimitResetRecord()
    switch outcome {
    case .reset(let nextAvailableAt):
        next.state = .used
        next.nextAvailableAt = nextAvailableAt
        next.enabledSeenAt = now
    case .alreadyUsed(let availableAgain):
        next.state = .used
        next.nextAvailableAt = availableAgain
        next.enabledSeenAt = now
    case .noticeAvailable:
        next.state = .available
        next.nextAvailableAt = nil
        next.enabledSeenAt = now
    case .unavailable, .loginRequired:
        next.state = .unknown
        next.nextAvailableAt = nil
        next.enabledSeenAt = now
    case .notEnabled:
        next.state = .notEnabled
        next.nextAvailableAt = nil
        next.enabledSeenAt = nil
    case .inProgress, .transient:
        return record
    }
    // WHICH SENTENCE THIS WAS: the two `used` outcomes are the pair a reader waiting on a command
    // it sent has to tell apart, and the state they both fold to cannot.
    next.lastSignal = outcome.signalName
    next.observedAt = now
    return next
}

// MARK: - Where it lives

/// Per-account reset records (`~/.tally/limit-reset/<account>`), one file per account for the
/// reason `quarantineDir` states about its own: concurrent supervisors write these, and a shared
/// document is one they can corrupt between them. Each write is atomic (temp + rename).
let limitResetDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/limit-reset")

/// The settings document beside them: whether Tally may answer a 5-hour wall with a reset.
///
/// ITS OWN FILE RATHER THAN A FIELD OF `~/.tally/state.json`, which is the launch-intent contract
/// (which account, which model, which effort). This is not a launch axis, and adding it there
/// would put a feature switch in the document every account pick decodes on every tick.
let limitResetSettingsURL = limitResetDir.appendingPathComponent("settings.json")

/// The one preference this feature has. ON by default, on the same reasoning `EarlyStartStore`
/// gives for its own: the automatic path spends a credit only on a wall the session has ALREADY
/// hit, and clearing that wall is strictly better than moving the conversation to another account
/// - it keeps the account, the context and the model. A switch nobody finds is a switch nobody
/// benefits from; what keeps it from being a surprise is the one-time notice.
struct LimitResetSettings: Codable, Equatable {
    var autoReset: Bool = true
    /// Whether the one-time notice has been shown. The automatic path does not wait on it (the
    /// wall has already happened and the alternative is a restart on another account); what the
    /// flag decides is whether to say so once, the first time it fires.
    var noticeShown: Bool = false
}

extension LimitResetSettings {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoReset = try container.decodeIfPresent(Bool.self, forKey: .autoReset) ?? true
        noticeShown = try container.decodeIfPresent(Bool.self, forKey: .noticeShown) ?? false
    }
}

/// The filename an account id maps to. The id carries a colon and may carry a slash (`claude:.claude`
/// today, a path-derived id tomorrow), and only the slash is a problem, which is the same
/// substitution `quarantineAccount` makes for the same reason.
func limitResetFile(accountID: String, dir: URL = limitResetDir) -> URL {
    dir.appendingPathComponent(accountID.replacingOccurrences(of: "/", with: "_"))
}

func readLimitReset(accountID: String, dir: URL = limitResetDir) -> LimitResetRecord? {
    guard let data = try? Data(contentsOf: limitResetFile(accountID: accountID, dir: dir))
    else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(LimitResetRecord.self, from: data)
}

/// Write one account's record. Best-effort throughout, the rule every sidecar on this track keeps:
/// a record that cannot be written costs a badge, never a session.
func writeLimitReset(_ record: LimitResetRecord, accountID: String, dir: URL = limitResetDir) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(record) else { return }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? data.write(to: limitResetFile(accountID: accountID, dir: dir), options: .atomic)
}

func readLimitResetSettings(url: URL = limitResetSettingsURL) -> LimitResetSettings {
    guard let data = try? Data(contentsOf: url),
          let settings = try? JSONDecoder().decode(LimitResetSettings.self, from: data)
    else { return LimitResetSettings() }
    return settings
}

func writeLimitResetSettings(_ settings: LimitResetSettings, url: URL = limitResetSettingsURL) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(settings) else { return }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    try? data.write(to: url, options: .atomic)
}

// MARK: - Which session may be asked

/// One supervised session, as the chooser behind the panel's button sees it.
struct LimitResetTarget: Equatable {
    var sessionKey: String
    var accountID: String
    /// Whether that session's supervisor publishes a state at all. One too old to do so is one
    /// whose build may also be too old to read the request (`liveRequestHonourability` refuses it
    /// on the CLI side), so it is the last candidate rather than the first.
    var isReporting: Bool
    /// Whether the session is sitting on a question only a person can answer. A dialog reads
    /// KEYSTROKES and drops a paste on the floor (memory `tally-paste-vs-dialog`), so a slash
    /// command typed at one answers the dialog with rubbish. Never a candidate.
    var waitingOnPerson: Bool
    /// When it last published anything, as the freshness tie-break.
    var updatedAt: Date?
}

/// Whether the panel's session-limit control may be pressed.
///
/// PURE AND HERE rather than spelled inside a view body, because it is a truth table with four
/// inputs and two surfaces (the card and the compact row) draw it. Spelled twice, the two would
/// come to grey different things, which is exactly what `AccountFacts` exists to stop for every
/// other affordance on those surfaces.
///
/// A DEMO FIXTURE IS NEVER PRESSABLE, the rule the whole fixture file is under: it stands for an
/// account that does not exist on this machine, so every affordance that would touch a real one
/// stays greyed.
func limitResetPressable(state: LimitResetState, hasSession: Bool, busy: Bool,
                         demo: Bool) -> Bool {
    guard !demo, !busy, state == .available else { return false }
    return hasSession
}

/// The session to type `/limit-reset` into for `accountID`, or nil when there is none.
///
/// WHAT THIS ORDERS BY, AND WHAT IT DELIBERATELY DOES NOT. The brief for this feature asked for
/// "the session at the wall first", and being at the wall is an ACCOUNT-level fact: every session
/// on a capped account is at that wall, so it separates none of them. What does separate them is
/// whether the line can be typed at all, so that is the order: a session behind a dialog is
/// excluded outright, one whose supervisor reports nothing comes last, and the freshest publisher
/// wins between equals. The supervisor's own gates decide the rest a tick later.
func limitResetTarget(_ candidates: [LimitResetTarget], accountID: String) -> LimitResetTarget? {
    candidates
        .filter { $0.accountID == accountID && !$0.waitingOnPerson }
        .max { left, right in
            if left.isReporting != right.isReporting { return !left.isReporting }
            return (left.updatedAt ?? .distantPast) < (right.updatedAt ?? .distantPast)
        }
}
