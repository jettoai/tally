import SwiftUI

/// ONE SESSION, ONE CARD: what it is, who is serving it, what it is doing, and the way to its
/// terminal.
///
/// Split out of SessionBoardView for the reason the drag is (SessionBoardReorder.swift): the page is
/// one thing to read and a card is another, and the page's file had run out of room to hold both.
///
/// A VIEW OF ITS OWN RATHER THAN A FUNCTION ON THE PAGE, which is what the grip glyph needs: a
/// hover has to be answered by the card the pointer is actually over, and a `@State` can only live
/// in a view that owns it. It is the shape the account cards' own card already has
/// (`AccountCardView`), down to the two flags below, so the two boards' drag affordances cannot
/// drift apart.
struct SessionCardView: View {
    let row: SessionRosterStore.SessionRow
    /// The account list, for naming the account this session is on (see `sessionIdentityLine`).
    let store: UsageStore
    /// The user's own names for those accounts, and nothing else read from here.
    let settings: SettingsStore
    /// Show the grip glyph. False for a card there is nothing to arrange BY - a session that has
    /// published no directory cannot be dragged, so offering the handle would promise a gesture that
    /// does nothing (`SessionRosterStore.orderKey`).
    var showsDragHandle: Bool = false
    /// Full-brightness grip regardless of hover: the floating drag preview sets it, so the glyph
    /// never blinks out under the very hand that is dragging by it.
    var handleProminent: Bool = false

    @State private var isHovering = false

    /// Colour dot diameter: enough that four states are told apart at a glance, small enough that
    /// the card's first line still reads as a line of text rather than as a bullet list.
    private static let stateDotSize: CGFloat = 7
    /// What a card that cannot report itself is drawn at. Far enough down to read as "this one is
    /// quieter than the others" at a glance, not so far that its own text stops being legible -
    /// the card is still the way to that terminal.
    private static let quietCardOpacity: Double = 0.55

    var body: some View {
        Button {
            // THE FOREGROUND IS TAKEN HERE, IN THE PRESS'S OWN TURN, and this is the one line of
            // the jump that cannot be moved into the task below it: an app may activate itself
            // while it is handling a user event, and the task runs after that event is answered.
            // Most of these clicks arrive in a panel that deliberately never activated this app, so
            // without this the terminal is asked to take a foreground nobody is holding out
            // (`TerminalJump.prepare`).
            let handover = TerminalJump.prepare()
            // Detached from the press: the jump can stop for up to two minutes inside the system's
            // "may Tally control this app" question the first time, and the panel must not be
            // frozen behind it.
            Task { await TerminalJump.jump(directory: row.directory,
                                           childPid: row.childPid, from: handover) }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                sessionCardHeadline
                // THE PROVIDER'S MARK LEADS THE LINE, at the size the eight other surfaces
                // that name an account already lead with it (`ProviderIconView`, 11-16pt);
                // this card was the one that did not. `SessionRow.providerID` says why the
                // mark is the only thing on the line that answers "whose model is this".
                //
                // DRAWN WHENEVER THE LINE IS, without asking whether the provider was legible:
                // a mark on some cards and not others would put the identity lines of a grid at
                // two different left edges, which reads worse than the catalog's generic glyph
                // on the one card whose account id has no head.
                sessionCardLine { sessionIdentityRow }
                // THE LAST LINE, AND ONE OF THEM: the two sentences a card can end on take turns in
                // the same slot rather than stacking. EVERY CARD THE SAME HEIGHT is worth more than
                // the stats are: a waiting card that carried both stood a line taller than the ones
                // beside it, and a grid of those reads as a ragged page rather than as hierarchy. So
                // the wait takes the slot on the card that has one - one line of it, red, where a
                // glance at the grid finds it - and the figures it displaced are simply not shown.
                //
                // NOTHING ON THIS CARD ANSWERS A HOVER, which is where those figures, and the rest
                // of a reason too long for the line, used to go. The board is where the pointer
                // WAITS between jumps, so a callout opening under it covers the cards beside it for
                // as long as the hand rests there; that costs more than a truncated line, and the
                // whole of a wait is in the terminal this card is the way to (2026-08-15). What is
                // banned is the LAYER, not the meaning: a card still tells VoiceOver what a click
                // does, and says it in its own hint rather than through a callout's (see below).
                //
                // Written on `sessionIsWaiting` rather than on the reason being there, so the choice
                // is the card's state and not an accident of what got published. A blocked session
                // that named no reason keeps its stats: an empty slot would be the ragged card
                // again, for a sentence nobody wrote.
                sessionCardLine {
                    if sessionIsWaiting, let reason = sessionReason {
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(TallyColor.critical)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else if sessionIsLoading {
                        // The mini indicator is 10pt against the 13pt line box the slot is measured
                        // at, so it turns inside the line rather than setting the card's height.
                        ProgressView().controlSize(.mini)
                    } else {
                        sessionStats
                    }
                }
                // WHAT THIS SESSION IS DOING TO THE MACHINE: a line of its own, because it answers a
                // different question from the ones above it - those say what the session is and what
                // it has spent, this says what is running under it right now. Not a fourth segment
                // on the stats line, which already truncates. The slot is kept on every card for the
                // reason the helper exists (`sessionCardLine`): a card that dropped a row would
                // stand shorter than its neighbours.
                //
                // AND THIS ROW IS EMPTY ON THE ORDINARY CARD, which is deliberate rather than a
                // measurement that failed: what is left here is the fields with no shape - a
                // fan-out and heavy writing - and a session that is doing neither has nothing to say
                // on it. The readings themselves moved one line down when they gained their shapes
                // (`sessionFootprintTrends`) and the ports moved one line up when they gained a
                // reader who acts on them (`sessionIdentityRow`), so the empty slot is holding the
                // board level for the cards that DO have one of those things.
                sessionCardLine { sessionFootprint }
                // AND HOW IT GOT THERE: the same three readings as a shape, with the highest one
                // named (`sessionFootprintTrends`). A second line rather than more segments on the
                // first, because the first already truncates on a narrow card, and a slot of its
                // own on every card for the reason all the others have one - a card that dropped
                // the row while its neighbour drew it would stand a line shorter than the board.
                sessionCardLine { sessionFootprintTrends }
            }
            .padding(.horizontal, TallyMetrics.cardPaddingH)
            .padding(.vertical, TallyMetrics.cardPaddingV)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tallyCard()
            .contentShape(Rectangle())
            // A session that cannot report itself is still a session and still a way to its
            // terminal, so it is dimmed rather than greyed out: quieter than its neighbours, and
            // every bit as clickable.
            .opacity(row.isReporting ? 1 : Self.quietCardOpacity)
        }
        .buttonStyle(.plain)
        // WHAT A CLICK DOES, SPOKEN. VoiceOver reads what the session is off the labels above; the
        // one thing it cannot see is that the whole card is the way to that terminal. The callout
        // used to carry this line and handed it to a hint on its way past (`TallyTooltip`), so
        // taking the callout off took the sentence with it. A hint rather than `.help()`, which is
        // an NSToolTip: the layer is what this board bans, never the meaning.
        .accessibilityHint(Text(L("Click to bring its terminal to the front")))
        // Asked only where the answer is drawn, exactly as the account card asks it: a card with no
        // grip on it would be re-rendering on every pointer crossing for nothing.
        .onHover { if showsDragHandle { isHovering = $0 } }
    }

    /// One of the card's lines, holding its place whether or not there is anything to put on it.
    ///
    /// A LINE THAT IS ABSENT TAKES THE CARD'S HEIGHT WITH IT, which is the same ragged page the
    /// last line's take-turns rule exists to prevent (`body`), arriving by the one route that rule
    /// cannot see: there the card CHOOSES between two sentences, here it has neither and the row
    /// simply is not laid out. Both of the lines under the headline are drawn from what a session
    /// happened to publish, so a session that has published nothing yet - registered, its state and
    /// sidecars still a tick away - collapsed to its headline and sat a third the height of every
    /// card beside it.
    ///
    /// THE HEIGHT IS SPELLED BY THE TYPE rather than by a number: an empty slot is a caption's own
    /// line box, so nothing here has to know what a card is supposed to add up to, and the cards go
    /// on matching if that caption ever changes size. Both things a filled slot carries are shorter
    /// than that box (the provider mark is 11pt, the indicator 10), so the slot is one height for
    /// every state a card can be in.
    private func sessionCardLine<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack(alignment: .leading) {
            Text(verbatim: " ").font(.caption2).hidden()
            content()
        }
    }

    /// Whether this is the card that is ASKING for somebody, which is the only difference left
    /// between two of them. It names its state in words, ticks the age of the wait on its first
    /// line, and spends its last line on what the wait is rather than on what the session has
    /// spent; everything else about it - its cell, its width, its line COUNT - is what every card
    /// has.
    private var sessionIsWaiting: Bool { row.state == .blocked }

    /// Whether this card knows nothing about its session YET, as opposed to being one that has
    /// nothing to say. A supervisor writes its state and its sidecars on its first tick, so for
    /// those seconds there is a live session on the board and not one fact to print about it.
    ///
    /// AN INDICATOR IS THE HONEST READING of that, and an empty card is not: the same blank card
    /// says "this session has nothing" when what is true is "this session has not spoken yet". It
    /// is an indicator rather than the skeleton the panel's own first fetch draws (`EmptyStateView`)
    /// because the card IS the skeleton here: it is already at its full height, in its seat, beside
    /// cards carrying real readings, and only one line of it is still to come.
    ///
    /// ONLY WHEN NOTHING AT ALL IS KNOWN. A supervisor too old to publish a state still names its
    /// account and its model through the sidecars it does write, and turning an indicator under a
    /// card that is already telling you what it is would promise an arrival that is not coming.
    /// That card is quiet on purpose - the whole of what the board says about it is what it knows.
    private var sessionIsLoading: Bool {
        !row.isReporting && sessionIdentityLine == nil && sessionStatsLine(now: .now) == nil
    }

    /// The card's first line: what this session is, and - on the waiting card - what it is doing and
    /// for how long. Every other card gives the whole line to the name, which truncates at the tail:
    /// these sit side by side, and a name squeezed between two other things is how a column of cards
    /// stops being scannable. The waiting one spends that room on the two things a wait is read for.
    private var sessionCardHeadline: some View {
        HStack(spacing: 6) {
            stateDot
            Text(row.title).font(.callout).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            if sessionIsWaiting {
                // Reporting, and red, without asking: `blocked` can only come from a published
                // record (`SessionRow.state`), so the card carrying this word always has one.
                Text(L(row.state.rawValue))
                    .font(.caption2)
                    .foregroundStyle(TallyColor.critical)
                sessionDuration
            }
            if showsDragHandle { dragHandle }
        }
    }

    /// The grip: the same glyph the account cards carry, at the same rest brightness, for the same
    /// reason (`AccountCardView`). Resident but dim rather than hover-only - an affordance that is
    /// not there until the pointer arrives is one nobody finds, and the space it would leave empty
    /// reads as imbalance (2026-07-19). It sits at the trailing end of the headline because that is
    /// where the account cards keep theirs, after the state word and the age on the card that has
    /// them: the name still owns the leading edge of every card on the board.
    ///
    /// The one place it parts from that pattern is the callout: the account card names the gesture
    /// under the pointer, this one names it to VoiceOver only, because no part of a session card may
    /// open a layer over the board (`body`). The glyph itself still answers the hover by brightening,
    /// which is the affordance the words were only repeating.
    private var dragHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .opacity(isHovering || handleProminent ? 1 : 0.35)
            .accessibilityLabel(L("Drag to reorder"))
    }

    /// How long this has been true, ticking.
    ///
    /// THE ONE THING ON THIS CARD THAT MOVES WITHOUT ANYTHING CHANGING. The store deliberately
    /// assigns nothing when a scan finds the board unchanged (a re-render of every surface twice a
    /// second, otherwise), so an age computed in the body would freeze at the last state change and
    /// read as a session stuck at "2m" for an hour. A timeline is the SwiftUI answer to "re-render
    /// because time passed": it drives only this Text, and only while the surface is on screen.
    ///
    /// ONCE A SECOND, WHICH IS THE FINEST THING THE TEXT SAYS: under a minute this counts in
    /// seconds (`sessionAge`), and a two second beat printed those as 1s, 3s, 5s - a clock that
    /// skips is read as a clock that is wrong. Past a minute the text moves in minutes, so the extra
    /// tick recomputes the same string and puts nothing new on screen. It is the rate the panel's
    /// other running clock already keeps (`PopoverHeaderView`).
    ///
    /// Nothing at all for a session that has published no state: it has no moment to count from,
    /// and counting from the file's own age would be dating the supervisor rather than the thing on
    /// screen (that card says when it last MOVED instead - see `sessionStatsLine`).
    @ViewBuilder
    private var sessionDuration: some View {
        if let since = row.since {
            TimelineView(.periodic(from: .now, by: 1)) { tick in
                Text(sessionAge(since, now: tick.date))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// The card's second line: who is serving this session, and what it is HOLDING OPEN.
    ///
    /// THE PORTS ARE UP HERE BECAUSE THEY ARE THE ONE READING SOMEBODY ACTS ON. Everything else the
    /// footprint says is a fact about this session's own cost; a port is a fact about the MACHINE -
    /// it is what the next `pnpm dev` in another window collides with, and it is invisible
    /// everywhere else in this app. Down on the footprint sentence it was the last field of a line
    /// truncated at its tail, so it was the first thing a narrow card dropped (Albert, 2026-08-16).
    ///
    /// AND THE IDENTITY IS WHAT GIVES WAY FOR THEM, by asking for the room LAST rather than by
    /// being one of two candidates: the ports are laid out at their own width (`fixedSize`) and the
    /// identity carries `layoutPriority(-1)`, so a row with too little of it takes the shortfall off
    /// the name and never off the numbers. How many of the ports say what is holding them is decided
    /// before the layout ever runs, on a measured POINT budget (`ProcessTree.portsText`).
    ///
    /// THAT PRIORITY IS LOAD-BEARING HERE AND WAS NOT ON THE TREND ROW, which is worth writing down
    /// because the two were once called one rule. This is a plain `HStack`: when the row is short
    /// something really is compressed, and the priority is what decides which of the two it is. The
    /// culprit names one file over sat inside a `ViewThatFits`, which only ever takes a candidate
    /// whose ideal width ALREADY fits - nothing there was ever asked to give room up, so the same
    /// modifier was dead code and has been removed (`SessionCardView.sessionFootprintTrends`).
    /// Deleting this one on the strength of that reasoning would compress the PORTS instead, and a
    /// truncated port number is a wrong port rather than a shortened name.
    ///
    /// IT WAS A `ViewThatFits` AND THAT WAS WRONG, which is worth keeping written down because the
    /// mistake looks like the idiom: that view chooses by its candidates' IDEAL width, and a
    /// truncating `Text` has the width of its whole untruncated string as its ideal. The fit test
    /// was therefore "does the FULL identity fit beside the named ports", which no ordinary card
    /// passes, so every card fell to the bare candidate and the names this row was built for were
    /// never drawn. A candidate list cannot express "this one shrinks and that one does not"; a
    /// layout priority can.
    ///
    /// A VIEW OF ITS OWN RATHER THAN A SEGMENT OF `sessionIdentityLine`, which is not a style
    /// choice: that string being nil is how this card knows it has nothing at all to say yet and
    /// turns an indicator instead (`sessionIsLoading`), so ports written into it would take the
    /// indicator AWAY from a session that has published nothing but a dev server's port - the card
    /// would read as one that knows what it is and is merely quiet.
    private var sessionIdentityRow: some View {
        HStack(spacing: 4) {
            if let identity = sessionIdentityLine {
                ProviderIconView(providerID: row.providerID ?? "", size: 11)
                // LAST IN THE QUEUE FOR ROOM. A truncated account name still says which account; a
                // truncated port number is a wrong port.
                Text(identity).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail).layoutPriority(-1)
            }
            if let ports = sessionPortsText {
                Spacer(minLength: 6)
                // Held at its own width, so the identity beside it is what the HStack takes the
                // room from; monospaced for the reason every other figure on this card is - the
                // digits are re-read every couple of seconds and must not shuffle the line.
                // WHAT THE BUDGET DROPPED IS STILL SPOKEN IN FULL, the rule the trend row below
                // keeps for its own dropped words (`spokenTrends`): a listener has no width to run
                // out of, and the name a narrow card gave up is the very thing this row was moved
                // up here to say.
                Text(verbatim: ports)
                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                    .lineLimit(1).fixedSize()
                    .accessibilityLabel(sessionPortsSpoken ?? ports)
            }
        }
    }

    /// Who is serving this session: the account, the model, and the effort it is running at. Each is
    /// optional - a session that has not had a turn yet has no observed model, and a supervisor from
    /// before the effort axis publishes none - and the card reads fine without any of them, so
    /// nothing is drawn as a placeholder.
    ///
    /// THE ACCOUNT IS CALLED WHAT THE USER CALLS IT, through the one function every other surface
    /// that names an account asks (`displayLabel`, fourteen call sites): the account card, the fleet
    /// gauge, the menu bar and the advisor all show a renamed account by its new name, and a board
    /// reading the provider's default straight off the list was the one place a rename did not
    /// reach. A single source of truth that one surface reads around is not one.
    ///
    /// The lookup is still what decides whether there IS a name: an id naming no account this build
    /// can see contributes no segment (`SessionRow.accountName` says why it is not the raw id), and
    /// `displayLabel` is asked only about an account that was found - its `fallback` is for "no
    /// override", not for "no account", and handing it the id would print the id.
    private var sessionIdentityLine: String? {
        let account = row.accountName { id in
            store.orderedAccounts.first { $0.id == id }
                .map { settings.displayLabel(accountID: id, fallback: $0.accountLabel) }
        }
        return joined([account, row.model, row.effort])
    }

    /// What this session has spent, and when it was last true of it, drawn on the cards that are not
    /// waiting. The figure comes from the context sidecar, so a session whose file is missing or
    /// unreadable simply has no last line (`SessionSidecar`).
    ///
    /// Inside a timeline whenever it carries a time, at the rate and for both the reasons
    /// `sessionDuration` gives: the store assigns nothing on a tick that finds the board unchanged,
    /// so an age computed in the body would sit frozen at whatever it said when the surface opened,
    /// and this line counts in seconds under the minute too.
    @ViewBuilder
    private var sessionStats: some View {
        if sessionTime(now: .now) != nil {
            TimelineView(.periodic(from: .now, by: 1)) { tick in
                statsText(sessionStatsLine(now: tick.date))
            }
        } else {
            statsText(sessionStatsLine(now: .now))
        }
    }

    /// The same sentence in words rather than in a view, so the card can ask whether there is one to
    /// draw at all before it decides what it is (`sessionIsLoading`): a card that knows nothing yet
    /// turns an indicator, and "nothing to say" has to be answerable without laying the line out.
    private func sessionStatsLine(now: Date) -> String? {
        let context = row.contextTokens
            .map { UsageFormat.compactCount(Int64($0)) + " " + L("context") }
        return joined([context, sessionTime(now: now)])
    }

    @ViewBuilder
    private func statsText(_ text: String?) -> some View {
        if let text {
            Text(text).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.tail)
        }
    }

    /// The time the stats line has room to say. An ordinary card has no state word and no duration
    /// on its first line, so its own duration comes here; the waiting card already ticks one up
    /// there and gives this slot to when the conversation last MOVED instead (a line that is drawn
    /// only on the blocked card that named no reason - `body`). A session publishing no state has no
    /// duration to give either way, and answers the same question the only way it can.
    private func sessionTime(now: Date) -> String? {
        if !sessionIsWaiting, let since = row.since { return sessionAge(since, now: now) }
        return row.lastActivity.map { sessionAge($0, now: now) + " " + L("ago") }
    }

    /// The card's own separator, spelled once: the middle dot the panel already uses between an
    /// account and a model, dropping whatever is absent rather than leaving a stray divider.
    private func joined(_ parts: [String?]) -> String? {
        let kept = parts.compactMap { $0 }.filter { !$0.isEmpty }
        return kept.isEmpty ? nil : kept.joined(separator: pickEffortSeparator)
    }

    /// What a blocked session is waiting for. ONLY while it is blocked: `reason` is what Claude Code
    /// said at the moment it asked, and a sentence still standing under a session that has moved on
    /// would be worse than no sentence at all. Its callers ask `sessionIsWaiting` first all the
    /// same, because there the state is what decides which line a card ends on - this guard is the
    /// belt, not the decision.
    private var sessionReason: String? {
        guard sessionIsWaiting,
              let reason = row.reason?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reason.isEmpty else { return nil }
        return reason
    }

    /// One dot per state, along the axis this board is actually read for: does this one need me?
    /// Red for the session that wants somebody, green for the one that is running and needs nobody,
    /// grey for at rest, and a HOLLOW ring for "cannot say" - which is both the published `unknown`
    /// and a session that has published nothing (the latter reads as `unknown` by construction -
    /// `SessionRow.state`), because both are an absence of information rather than a further
    /// condition. Red against green is the strongest contrasting pair available at 7pt, and those
    /// two are the ends of that question.
    ///
    /// WORKING WAS PURPLE, AND THE PURPLE WAS THE MISPLACED ONE. `TallyColor.ai` means "Tally is
    /// steering this" (the smart pick's badge, the status line's mark), and that is true of EVERY
    /// supervised card on this board, the idle ones drawn in grey included. Spending the identity
    /// accent on one activity state overloaded it, and at 7pt it made the board's one real
    /// distinction two deep warm tones apart.
    ///
    /// The standing objection to green was that the meter palette is one tab away, so a green dot
    /// would read as "this session has room". It does not: the meter's sage fills a bar (a
    /// continuous quantity), this fills a dot in a set of discrete categories, and a session card
    /// carries no quota at all. What had to be avoided was the sage VALUE, which is why this is
    /// `TallyColor.live` rather than `TallyColor.normal`.
    ///
    /// AND COLOUR IS NOT THE ONLY CARRIER, which is the precondition for putting red beside green:
    /// a viewer who cannot separate those two hues still gets the waiting card's state in words and
    /// its reason line, both in red text (`sessionCardHeadline`, `body`).
    @ViewBuilder
    private var stateDot: some View {
        let size = Self.stateDotSize
        switch row.state {
        case .blocked:
            Circle().fill(TallyColor.critical).frame(width: size, height: size)
        case .working:
            Circle().fill(TallyColor.live).frame(width: size, height: size)
        case .idle:
            Circle().fill(Color.secondary.opacity(0.5)).frame(width: size, height: size)
        case .unknown:
            Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1)
                .frame(width: size, height: size)
        }
    }

    /// How long this session has been in this state, at a glance: seconds under a minute, then
    /// minutes, then hours and minutes. Not a countdown and not a date - the question it answers is
    /// "how long has this been true", and past a day the answer is "a long time".
    private func sessionAge(_ since: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d"
    }
}

extension PopoverRootView {
    /// One session's card, built the one way for both places that draw it: the grid, and the
    /// floating copy the drag carries (`sessionLiftPreview`). What the hand is holding cannot drift
    /// from what the grid draws, which is why the preview asks for this rather than for its own.
    ///
    /// - Parameter handleProminent: hold the grip at full brightness. The preview's, so the glyph
    ///   the user grabbed by does not fade out the moment the pointer leaves the card's old seat.
    func sessionCard(_ row: SessionRosterStore.SessionRow,
                     handleProminent: Bool = false) -> some View {
        SessionCardView(row: row, store: store, settings: settings,
                        // A card with no directory has nothing to be arranged by and cannot be
                        // lifted at all, which is the same question the drag asks at the grab
                        // (`sessionsReorderGesture`): one answer, so the affordance and the gesture
                        // cannot disagree about which cards move.
                        showsDragHandle: SessionRosterStore.orderKey(row) != nil,
                        handleProminent: handleProminent)
    }
}
