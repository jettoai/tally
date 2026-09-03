import SwiftUI

// WHAT THE SESSION IS DOING, as the card's first line says it, and the one card on the board that
// is asking for somebody.
//
// Split from SessionCardView.swift on file size, along the seam the card itself reads by: the top
// line answers "what is this doing and does it need me", every line under it answers "what is it,
// who is serving it, what has it spent" - and the second of those already lives in a file of its
// own for the same reason (`SessionCardFootprint.swift`, the one MEASUREMENT on the card).
//
// FOUR CHANNELS SAY THE SAME THING ON THE WAITING CARD, which is the subject this file collects:
// the dot's colour, the word `blocked`, the age ticking beside it, and the card's own red edge
// (`SessionCardView.body`). None of them is redundant - the shape and the words are what a reader
// who cannot separate red from green gets, and the edge is what a reader sweeping a grid of cards
// finds without reading any of them. The sentence BEHIND the wait is the fifth, and it is the one
// thing here that cannot be drawn at this width, so it is said twice in channels neither of the
// other four uses: a hover of the word for a pointer (`sessionStateWord`) and the button's own
// accessibility VALUE for a listener (`SessionWaitSpoken`), off one property. The listener's half
// cannot be the hover's - a card is one accessibility element and a hint inside it reaches nobody,
// which is the correction at the foot of this file.
//
// THE MEMBERS THESE REACH ACROSS THE SEAM ARE NO LONGER `private`, which is what a file split
// costs in Swift: `private` reaches extensions in the same file and no further. The four that had
// to widen are the hover flag the grip reads, the dot's diameter, and the two questions the
// headline asks about the wait; all of them stay internal to the module.

extension SessionCardView {

    /// The card's first line: what this session is, and - on the waiting card - what it is doing and
    /// for how long. Every other card gives the whole line to the name, which truncates at the tail:
    /// these sit side by side, and a name squeezed between two other things is how a column of cards
    /// stops being scannable. The waiting one spends that room on the two things a wait is read for.
    var sessionCardHeadline: some View {
        HStack(spacing: 6) {
            stateDot
            Text(row.title).font(.callout).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            if sessionIsWaiting {
                sessionStateWord
                sessionDuration
            }
            // AT THE TRAILING END, WHERE NOTHING HAS TO BE HELD OPEN FOR IT. It began as a reserved
            // slot between the dot and the name, on the reasoning that a mark arriving must not
            // shunt the title sideways - which held the gap open on EVERY card on the board for the
            // one card that might use it, and read as a layout mistake rather than as a space
            // (Albert, seeing the first live board, 2026-09-03). Past the Spacer nothing is
            // reserved and nothing moves: the title keeps the leading edge whatever else the row is
            // carrying, exactly as the state word and the age already do on the waiting card.
            if marked { Self.flameMark }
            if showsDragHandle { dragHandle }
        }
    }

    /// THE HEAVIEST PROJECT ON THE MACHINE, MARKED ON THE ONE CARD THAT IS SPENDING IT.
    ///
    /// DRAWN ONLY WHEN IT IS TRUE, and nothing is held open for it when it is not. The alternative
    /// was a reserved slot in front of the title, which is how the row this mark came off did it,
    /// and on a grid of cards it is the wrong trade: that row was one of a stack of identical rows,
    /// while a card's title is the thing a reader lands on, so the empty slot showed up as a gap
    /// between the state dot and the name on every card on the board. It costs nothing to leave out
    /// because of where it now sits - at the trailing end of the headline, past the Spacer
    /// (`sessionCardHeadline`), where the things that come and go already live.
    ///
    /// AMBER RATHER THAN RED, on the board's own division: red is reserved for the card that is
    /// ASKING for somebody (`stateDot`, the waiting card's edge), and a checkout burning cores is a
    /// fact to notice rather than one to answer.
    ///
    /// Static, because the unclaimed cards wear the same mark in the same place for the same
    /// project, and one spelling of it is what keeps the two kinds of card saying it alike
    /// (`SessionGhostCardView`).
    static var flameMark: some View {
        Image(systemName: "flame.fill")
            .font(.caption2)
            .foregroundStyle(Self.flameTint)
    }

    /// The flame's colour, spelled once because the mark is no longer the only thing wearing it: the
    /// CPU figure the flame is ABOUT is drawn in it too, one row down, so that a reader who has
    /// found the flamed card can see which of its readings earned the mark
    /// (`SessionCardView.flamed`). A mark and the figure it points at in two different ambers would
    /// read as two unrelated warnings.
    static let flameTint: Color = TallyColor.warning

    /// The word `blocked`, and the whole of what the session is waiting FOR under a hover of it.
    ///
    /// Reporting, and red, without asking: `blocked` can only come from a published record
    /// (`SessionRow.state`), so the card carrying this word always has one.
    ///
    /// THE REASON IS ON THE WORD BECAUSE THE WORD IS WHAT IT QUALIFIES, and because the sentence
    /// cannot be drawn: it is written by a hook ("Claude needs your permission to use Bash") and can
    /// be any length, so the line it used to have on the card showed its first few words and an
    /// ellipsis (`body`). A callout has no column to run out of. The pointer is already crossing
    /// this card on its way to clicking it, so the one word that says a person is being asked for
    /// something is where a hand is most likely to rest.
    ///
    /// AND IT IS A HOVER, WHICH VOICEOVER DOES NOT HAVE, so this is the pointer's channel and only
    /// the pointer's. The callout does hand its text to an accessibility hint on the element it
    /// wraps (`TallyTooltipTarget.body`), and on this card that element is a `Text` inside a
    /// `Button` - part of one accessibility node that nothing can land on separately, so the hint
    /// goes nowhere. The listener's copy is on the button itself, as its VALUE
    /// (`SessionCardView.body`, `SessionWaitSpoken`), read off the same property so the two cannot
    /// drift. This note is the correction to a claim that stood here for one commit and was not
    /// true (codex review of 22e9dcd).
    ///
    /// A card whose wait named no reason simply has the word, with no target and no empty callout.
    @ViewBuilder
    var sessionStateWord: some View {
        let word = Text(L(row.state.rawValue)).font(.caption2)
            .foregroundStyle(TallyColor.critical)
        if let reason = sessionReason { word.tallyTooltip(reason) } else { word }
    }

    /// The grip: the same glyph the account cards carry, at the same rest brightness, for the same
    /// reason (`AccountCardView`). Resident but dim rather than hover-only - an affordance that is
    /// not there until the pointer arrives is one nobody finds, and the space it would leave empty
    /// reads as imbalance (2026-07-19). It sits at the trailing end of the headline because that is
    /// where the account cards keep theirs, after the state word and the age on the card that has
    /// them: the name still owns the leading edge of every card on the board.
    ///
    /// The one place it parts from that pattern is the callout: the account card names the gesture
    /// under the pointer, this one names it to VoiceOver only. The board's exception is narrow and
    /// this is not it - one word on the waiting card answers a hover, because the sentence behind it
    /// has nowhere else to be said in full (`sessionStateWord`), and "drag to reorder" has the glyph
    /// itself, which answers the hover by brightening. That is the affordance the words were only
    /// repeating, and a callout the pointer meets on every card it crosses is the cost the board
    /// declined to pay (`body`).
    var dragHandle: some View {
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
    var sessionDuration: some View {
        if let since = row.since {
            TimelineView(.periodic(from: .now, by: 1)) { tick in
                Text(sessionAge(since, now: tick.date))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
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
    /// a viewer who cannot separate those two hues still gets the waiting card's state IN WORDS
    /// beside this dot, and the sentence behind it read out as that word's own accessibility hint
    /// (`sessionCardHeadline`, `sessionStateWord`).
    @ViewBuilder
    var stateDot: some View {
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
    func sessionAge(_ since: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d"
    }

    /// What a blocked session is waiting for. ONLY while it is blocked: `reason` is what Claude Code
    /// said at the moment it asked, and a sentence still standing under a session that has moved on
    /// would be worse than no sentence at all.
    ///
    /// WHICH OF THE TWO TESTS BELOW IS DECIDING ANYTHING HAS CHANGED. A line on the card used to be
    /// written on `sessionIsWaiting`, so the state test here merely agreed with the call site and
    /// the reason test was what remained; now the only reader is a hover ON the state word, which is
    /// already inside that same `if` (`sessionStateWord`). So the state test is the belt - kept
    /// because a second reader arriving outside that branch would otherwise print what a session
    /// said before it moved on - and the reason test is the whole decision: a callout with nothing
    /// in it is not a target, so a wait nobody explained gets the word and no hover at all.
    var sessionReason: String? {
        guard sessionIsWaiting,
              let reason = row.reason?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reason.isEmpty else { return nil }
        return reason
    }
}

/// THE WAIT, SAID TO A LISTENER, on the one node a listener can land on.
///
/// A session card is a single `Button`, so its accessibility element is the button and everything
/// spoken about the card has to be an attribute OF it: a child's label composes into the button's
/// own, and a child's hint or value does not compose into anything at all. The reason a session is
/// blocked therefore cannot ride on the state word it qualifies, however right that is for a
/// pointer (`SessionCardView.sessionStateWord`), and this modifier is where it rides instead.
///
/// A MODIFIER RATHER THAN A `.accessibilityValue(Text(reason ?? ""))` IN THE CHAIN, because the two
/// are not the same thing: every card that is not waiting would carry an empty value, and "this
/// element has a value and it is the empty string" is a different state from "this element has no
/// value" for anything reading the tree. Only the waiting card gains an attribute.
struct SessionWaitSpoken: ViewModifier {
    /// What the session is waiting for, or nothing when it is not waiting or named no reason
    /// (`SessionCardView.sessionReason`).
    let reason: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let reason { content.accessibilityValue(Text(reason)) } else { content }
    }
}
