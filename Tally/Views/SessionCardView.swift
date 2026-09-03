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
    /// Whether this card wears the machine's flame: its project is the heaviest one running, and of
    /// that project's cards this is the one spending the most (`SessionBoardGhosts.marked`). The
    /// mark used to sit on a row in a section above the board, which is where it stopped being
    /// worth the layer it needed (`SessionGhostCardView`).
    var marked: Bool = false
    /// This checkout's leftovers, stated at the end of this card's trend row, on the LAST card of
    /// the project and nowhere else (`SessionBoardGhosts.Seating.footnotes`). Nothing on every other
    /// card, which is most of them.
    ///
    /// IT WAS A FOOTNOTE ALONG THE BOTTOM OF THE CARD for a day, and what it is now is a mark on the
    /// row where this card's other live figures already are (`SessionLeftoversMark` carries the
    /// whole of why).
    var unclaimed: ProjectLoad?
    /// Whether the machine's flame belongs to those leftovers rather than to this session: it is
    /// drawn beside their count and this card's headline stays unmarked
    /// (`SessionBoardGhosts.placement`).
    var unclaimedMarked: Bool = false

    @State var isHovering = false
    /// A need, not a preference: the live figures on this card roll to their new values and the
    /// lines behind them travel, and both are held still for a reader who has asked for that
    /// (`SessionCardView.sessionFootprintTrends`, `FootprintSparklineView`).
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    /// Colour dot diameter: enough that four states are told apart at a glance, small enough that
    /// the card's first line still reads as a line of text rather than as a bullet list.
    static let stateDotSize: CGFloat = 7
    /// What a card that cannot report itself is drawn at. Far enough down to read as "this one is
    /// quieter than the others" at a glance, not so far that its own text stops being legible -
    /// the card is still the way to that terminal.
    ///
    /// Not private, because the board's unclaimed cards are drawn at it too: they are the other
    /// thing on this page that is quieter than a session without being any less true
    /// (`SessionGhostCardView`), and two spellings of one opacity would drift.
    static let quietCardOpacity: Double = 0.55

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
                // THE LAST LINE, AND EVERY CARD NOW SPENDS IT THE SAME WAY. The waiting card used to
                // take this slot for the reason it is waiting, drawn in red and truncated at the
                // tail, and give up its own figures to do it. It does not any more: what the reason
                // said in a clipped line is said in full on a hover of the state word instead, and
                // the figures every other card prints here come back (Albert, 2026-08-17).
                //
                // FOUR CHANNELS ALREADY CARRIED THE WAIT WITHOUT IT, which is what made the line
                // affordable to lose rather than merely long: the dot, the word `blocked`, the age
                // ticking beside it and the card's own red edge. A fifth statement of the same fact,
                // spending the one line on the card that says what the SESSION has, was the cheapest
                // of the five to give up - and it was also the one that could not say the whole
                // thing, being a sentence from a hook in a 236pt column.
                //
                // WHICH IS THE ONE HOVER THIS CARD ANSWERS, and the ban it partly lifts is worth
                // stating rather than quietly dropping. The board was given no callouts at all
                // (2026-08-15) because the pointer WAITS here between jumps, so a layer opening
                // under a resting hand covers the cards beside it. That is still true of the cards'
                // figures, which stay unhovered; what earns the exception is that this reason has
                // nowhere else to be said in full, and that the target is one word on the one card
                // in a state a person is being asked to act on. Nothing else on the card takes a
                // hover.
                sessionCardLine {
                    if sessionIsLoading {
                        // The mini indicator is 10pt against the 13pt line box the slot is measured
                        // at, so it turns inside the line rather than setting the card's height.
                        ProgressView().controlSize(.mini)
                    } else {
                        sessionStatsRow
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
                //
                // AND WHAT IS RUNNING IN THIS CHECKOUT THAT NO SESSION ANSWERS FOR IS AT THE END OF
                // THAT SAME ROW, on the last card of the project and on no other
                // (`SessionLeftoversMark`, which carries why it is no longer a line of its own).
                sessionCardLine { sessionFootprintTrends }
            }
            .padding(.horizontal, TallyMetrics.cardPaddingH)
            .padding(.vertical, TallyMetrics.cardPaddingV)
            // AS TALL AS THE ROW IT IS IN, WITH ITS LINES AGAINST THE TOP. A grid row is as tall as
            // the tallest card in it, and a session card shares its rows with the cards of checkouts
            // nobody is working in any more, which are three lines where this is five
            // (`SessionGhostCardView`): laid out at its own height, the shorter card stopped
            // halfway down its cell and left the row's space showing under it, and so did a session
            // card seated beside a taller one (codex review of b226640). Both kinds of card now
            // answer the row the same way.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // AND THE CARD'S OWN EDGE IS THE FOURTH CHANNEL THE WAIT IS SAID ON, after the dot, the
            // state word and the reason line. Those three are all INSIDE the card, so finding the
            // session that is asking for somebody means reading the cards one by one; an outline is
            // found by a sweep down the board, which is the action this board exists for (Albert,
            // 2026-08-17). Added rather than substituted: the shape and the words are what a reader
            // who cannot separate the hues gets, and they stay exactly as they were.
            //
            // BLOCKED AND NOTHING ELSE WEARS ONE, the machine-level readings on the row below
            // included (`FootprintAlertLevel`). Those are red because they need doing something
            // about, and this is red because it needs doing something about NOW; an edge that also
            // meant "this session is expensive" would be an edge a reader has to look inside the
            // card to interpret, which is the whole of what it buys back.
            .tallyCard(accent: sessionIsWaiting ? TallyColor.critical : nil)
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
        // taking the callout off took the sentence with it (dc39003). A hint rather than `.help()`,
        // which is an NSToolTip - Tally's own callout is what this surface speaks in.
        .accessibilityHint(Text(L("Click to bring its terminal to the front")))
        // AND WHAT IT IS WAITING FOR, ON THIS ELEMENT, WHICH IS THE ONLY ELEMENT THERE IS. The whole
        // card is one `Button`, so everything a listener gets from it is read off THIS node: child
        // LABELS compose into its own (the ports, the trend row and the footprint sentence all
        // arrive that way), and a child's HINT has no such route - it belongs to an element nothing
        // can land on. The reason spent one commit attached to the state word's callout for exactly
        // that reason and was unreachable there (codex review of 22e9dcd), which is the second time
        // this card has lost a sentence by leaving it on something inside the button: the click
        // sentence above was the first (dc39003).
        //
        // A VALUE RATHER THAN A SECOND HINT, and the difference is not decorative. This element has
        // one hint and it is already spoken for, correctly, by what a click does; a second
        // `accessibilityHint` does not join it, it REPLACES it, so the wait would have been bought
        // with the affordance. It is the right channel on its own terms too - a hint says what an
        // action will do, and "Claude needs your permission to use Bash" is a fact about the state
        // this card is in, which is what a value is for. VoiceOver reads it between the composed
        // label and the trait, so the card announces what it is, then what it is waiting for, then
        // that it is a button and what pressing it does.
        //
        // THE CALLOUT IS THE POINTER'S COPY OF THE SAME SENTENCE, from the same property, and is
        // not a second source (`sessionStateWord`, `sessionReason`).
        .modifier(SessionWaitSpoken(reason: sessionReason))
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
    /// line, and answers a hover of that word with what it is waiting FOR; everything else about
    /// it - its cell, its width, its lines and the figures on them - is what every card has. It
    /// used to spend its last line on the wait as well, and that line is what the hover replaced
    /// (`body`).
    var sessionIsWaiting: Bool { row.state == .blocked }

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
                if let scope = row.pinScope { pinMark(scope) }
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

    /// WHY THIS SESSION IS ON THIS ACCOUNT, when something is holding it there.
    ///
    /// THE PROBLEM IT ANSWERS (owner report, 2026-09-01): a pin was invisible on every surface, so a
    /// session sitting somewhere unexpected - or refusing to be rebalanced off a dying account -
    /// read as Tally misbehaving rather than as an instruction being obeyed.
    ///
    /// LEADING THE LINE RATHER THAN TRAILING IT, and held at its own width: it qualifies the name
    /// that follows it, and the identity beside it is what gives room up (`layoutPriority(-1)`), so
    /// a mark laid out after it would be the first casualty of the narrow card it exists for.
    ///
    /// A SCOPE RATHER THAN A DOT, because the three send a reader somewhere different to undo it,
    /// and the hover is where that answer fits. On the LABEL as well as in the callout, for the
    /// reason the supervisor badge states in full: the whole card is one `Button`, so a child's
    /// hint reaches nobody and only what composes into the card's label is spoken.
    private func pinMark(_ scope: SessionPinScope) -> some View {
        let owner = L(sessionPinOwnerKey(scope))
        let release = L(sessionPinReleaseKey(scope))
        return Text(verbatim: "\(sessionPinMark)\(L(sessionPinScopeWord(scope)))")
            .font(.caption2).foregroundStyle(.secondary)
            .lineLimit(1).fixedSize()
            .accessibilityLabel(Text(TallyTooltipContent.lines([owner, release]).spoken))
            .tallyTooltip(owner, detail: release)
    }

    /// The stats slot: what this session has spent, and - on the one card that has it - which build
    /// is still watching it.
    ///
    /// THE BADGE IS NORMALLY NOT THERE AT ALL, which is the whole design (Albert, 2026-08-23). An
    /// app update lands under every live supervisor at once and each replaces itself at its own next
    /// idle moment (SelfUpdate.swift), so for that window the board is the only place the difference
    /// is visible - and for the rest of the week there is nothing here. A resident version on every
    /// card would spend a segment for a reading that is worth acting on for minutes a week.
    ///
    /// IT NAMES THE VERSION AND NOTHING ELSE, in the panel header's own update vocabulary (`↻` and
    /// the build, `PopoverHeaderView`). The line it replaces spelled the whole reading out on the
    /// card, "0.64.3 → updates when idle", which is a sentence of standing ink for an answer that
    /// amounts to "nothing to do". The words are not lost: they are one hover away, in the app's own
    /// callout rather than a third tooltip mechanism (`tallyTooltip`, which this surface hosts).
    ///
    /// QUIET, AND NOT A CONTROL. The header's chip is filled and installs on a click; this one is
    /// `.secondary` text that takes no press, because the replacement happens on its own - the note
    /// that used to say "restart after update" was telling somebody to do by hand what was already
    /// under way (`SupervisionStatus.note` made the same correction inside the terminal).
    ///
    /// ON THIS LINE RATHER THAN ON THE IDENTITY ONE ABOVE, which is where it was first put and where
    /// it does not fit: that row already gives its slack to the ports, and on a compact card the
    /// sentence squeezed the account and the model out of the line and was then truncated itself.
    /// This slot carries one short figure and a duration, and has the room the badge needs.
    ///
    /// HELD AT ITS OWN WIDTH, exactly as the ports one row up are and for the same reason: a
    /// truncated version is a WRONG version, while a stats line that gives up its tail still says
    /// how big the conversation is. It is only ever drawn on the card somebody came for.
    private var sessionStatsRow: some View {
        HStack(spacing: 4) {
            sessionStats
            if let outdated = row.outdatedSupervisorVersion {
                Spacer(minLength: 6)
                supervisorBadge(outdated)
            }
        }
    }

    /// The badge itself. The glyph and the bare build are the same pair the header's update chip
    /// draws, so a reader who has seen one recognises the other; a dotted version is a token and is
    /// not localized, exactly as the header's is not.
    ///
    /// THE CALLOUT CARRIES WHAT THE CHIP CANNOT, in two lines: which supervisor this is, and that it
    /// updates itself. Both of them are the LABEL, not just the first: the chip's own text is a glyph
    /// and three numbers, and the sentence this badge replaced said the whole thing to a listener, so
    /// a label naming only the version would keep the identification and drop the one part that
    /// answers "do I have to do something about it".
    ///
    /// ON THE LABEL BECAUSE THE LABEL IS THE ONLY CHANNEL OUT OF HERE. The whole card is one
    /// `Button`, so a listener gets nothing from this element except what composes into the card's:
    /// child labels do, a child's HINT does not (it belongs to an element nothing can land on), and
    /// the card's own hint and value are both already spoken for - by what a click does and by what
    /// a blocked session is waiting for (`body`, `SessionWaitSpoken`). This card has lost a sentence
    /// twice by leaving it on something inside the button (dc39003, 22e9dcd); this is the same trap,
    /// one badge over. Composed through the callout's own spelling of two lines as one utterance, so
    /// the pointer's copy and the listener's cannot drift.
    ///
    /// Forcible for a capture, which is how the words above get looked at without synthesizing a
    /// hover onto somebody's desktop (`TallyTooltip.previewForced`, `-TallyTooltipPreview
    /// supervisor`). UNDER THE FIXTURES ONLY, which is what keeps that flag's one-target contract
    /// true: a dev build watching real sessions can have several supervisors behind at once, and
    /// every badge on that board would publish into the single preference slot the preview reads,
    /// leaving the capture to whichever the layout traversal reached last. The demo board has
    /// exactly one lagging card by construction (`DemoSessions`), which is the same guarantee the
    /// identity preview buys by naming one fixture account (`AccountFacts.forcesIdentityTooltip`).
    private func supervisorBadge(_ version: String) -> some View {
        let owner = String(format: L("Supervisor %@ is watching this session"), version)
        let update = L("It updates to the installed build at the next idle moment.")
        return Text(verbatim: "↻ \(version)")
            .font(.caption2).foregroundStyle(.secondary)
            .lineLimit(1).fixedSize()
            .accessibilityLabel(Text(TallyTooltipContent.lines([owner, update]).spoken))
            .tallyTooltip(owner, detail: update,
                          forced: DemoUsage.isActive && TallyTooltip.previewForced(.supervisor))
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
    /// there and gives this slot to when the conversation last MOVED instead. That used to be drawn
    /// only on a blocked card whose wait named no reason, every other one having given the slot to
    /// the reason itself; the reason moved to a hover and this is now on every waiting card
    /// (`body`). A session publishing no state has no duration to give either way, and answers the
    /// same question the only way it can.
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
}
