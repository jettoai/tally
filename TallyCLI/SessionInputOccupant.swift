import Foundation

// WHAT IS AT A SESSION'S INPUT ADDRESS, and what the second caller to reach an occupied one is
// told.
//
// Split from SessionInputCommand.swift for the reason SessionSendWait.swift was split from it
// before: that file is over the size a file in this repo may be. The seam is a subject rather than
// a line count. One session has one input address, and this is the question that address raises on
// its own - is anything still standing at it, and does what is there still count - while the file
// next door decides WHAT WAS ASKED FOR and in what order a send checks it. The order of business
// stays there and calls in here, which is why the refusal below is a pure function rather than a
// `warn` and a return.
//
// PURE, LIKE ITS NEIGHBOURS, for the same reason they are: nothing can call `runSessionSend` in a
// suite without typing into the developer's own live conversation, so what CAN be asserted is the
// reading and the wording rather than the act.

// MARK: - One send at a time at one address

/// What is at this session's address, when something is.
///
/// TWO FILES, ONE ANSWER, and that is the whole point of this type. A send is in flight from the
/// moment its request is written until the moment its answer is COLLECTED, and those are two
/// different documents: the supervisor writes the answer and then unlinks the request, so between
/// a caller's polls there is a window in which the address looks empty while somebody is very much
/// still waiting at it. Asking only about requests is asking half the question (codex review of
/// 3c37831).
enum SessionInputOccupant: Equatable {
    /// A line still on its way: written, and not served yet.
    case request(SessionInputRequest)
    /// A line already served, whose answer the caller that asked for it has not read yet.
    case answer(SessionInputResult)
}

/// What is at this session's address, or nil when nothing there could still be part of a send.
///
/// THE ONE DOOR, deliberately: there is no way left to ask about requests alone, because that
/// question has a right-looking answer that is wrong for half of every send's life.
///
/// EXPIRED ONES DO NOT COUNT, and each half has its own clock because each is waited on by a
/// different thing:
///
///   - A REQUEST is live for `sessionInputQueuedLife`, which is how long the supervisor will still
///     act on it. Past that it is a husk the next tick refuses, and treating it as an occupant would
///     take the address away over a caller that was killed mid-wait. THE TWO CLOCKS ARE THE ONE
///     NUMBER on purpose: the request half of this test asks the same question the supervisor's own
///     expiry does, and a shorter one here would free the address while a live request was still
///     pending at it - which is precisely the overwrite this type exists to refuse.
///   - An ANSWER is live for as long as THAT caller said it would wait, measured from the same
///     stamp, because what makes an answer collectable is not the supervisor's willingness to act
///     but the CALLER's willingness to wait. Since 2026-08-18 every caller says six seconds
///     (`sessionInputGraceSeconds`), so a receipt stops occupying the address almost at once, which
///     is right: nobody is standing at it. A request that named no wait at all is charged
///     `sessionInputWaitSeconds`, the number every answer was charged before the field existed.
///
///     THE CALLER'S OWN NUMBER RATHER THAN ONE FOR EVERYBODY, because every send now leaves early
///     by design and its receipt is written to an address nobody is standing at
///     (`SessionInputRequest.waitSeconds` carries the whole argument and the defect it fixes).
func sessionInputOccupant(sessionKey: String, dir: URL = sessionInputDir, now: Date = Date())
    -> SessionInputOccupant? {
    if let waiting = readSessionInputRequest(sessionKey: sessionKey, dir: dir),
       !sessionInputExpired(epoch: waiting.epoch, now: now) {
        return .request(waiting)
    }
    guard let answer = readSessionInputResult(sessionKey: sessionKey, dir: dir),
          !sessionInputExpired(epoch: answer.epoch, now: now, ttl: sessionInputAnswerLife(answer))
    else { return nil }
    return .answer(answer)
}

/// How long an answer is somebody's to collect: what its caller said it would wait, and the longest
/// wait anybody makes when it said nothing. Its own function because the occupant test and the
/// sentence a second caller is shown must not disagree about when an answer stops mattering.
func sessionInputAnswerLife(_ answer: SessionInputResult) -> TimeInterval {
    answer.waitSeconds.map(TimeInterval.init) ?? sessionInputWaitSeconds
}

/// What the second caller is told. Pure, so the wording is assertable.
///
/// REFUSED RATHER THAN WRITTEN OVER, and this is the whole of why. One address holds one send, so
/// a second one lands on top of the first: the first caller is then waiting for something that no
/// longer exists anywhere, gets nothing until its own timeout, and is told "nobody answered" for a
/// line that was in fact thrown away by us. Meanwhile the supervisor serves the second request and
/// writes an answer stamped with ITS epoch, so nothing on either end ever records that an
/// instruction was dropped (codex review of 18b3174). The answer half is the same failure with the
/// same ending, one step later: the text has been typed by then, so the caller that is told nobody
/// answered may reasonably send it again, and the session gets the line twice (codex review of
/// 3c37831).
///
/// AND NOT QUEUED, which is the other obvious answer and the more expensive one. Injection is
/// performed synchronously inside a poll tick, one byte at a time (SessionInput.swift), so a queue
/// turns "one tick may spend six seconds typing" into "one tick may spend as long as the queue is",
/// or else moves the typing off the tick and brings back exactly the concurrency this feature was
/// designed without (section 10 of the design document). Two callers typing into one composer is
/// also a thing neither of them can predict the result of.
///
/// TWO WORDINGS RATHER THAN ONE, because the two states differ in what the caller should do and in
/// what is at stake if they force it. A pending request will be served or expire, and waiting costs
/// the caller a minute; an uncollected answer is somebody's DELIVERY REPORT for text that is
/// already in the session, and the harm of stepping on it is a duplicated line rather than a lost
/// one. A caller reading stderr should be able to tell those apart without reading this file.
/// Both are worded so they cannot be mistaken for a gate refusal (`refused: session is working`
/// and its neighbours), which mean "try again, this may work later"; these mean "nothing of yours
/// was queued at all".
func sessionInputBusyRefusal(_ occupant: SessionInputOccupant, sessionKey: String,
                             now: Date = Date()) -> String {
    /// How long the thing at the address has left, on its own clock.
    ///
    /// CLAMPED, BECAUSE THE INPUT IS NOT OURS. `Int(someDouble)` traps in Swift when the value does
    /// not fit, and every `epoch` reaching this line came out of a file in a directory any process
    /// running as this user can write. A poisoned stamp of 10^30 therefore does not print an absurd
    /// sentence, it kills the command with SIGILL before it prints anything (exit 133 on a codex
    /// probe of `fa9533b`) - and it kills the SECOND send, the one whose whole job is to explain
    /// why the first is still there. Clamping is free and turns that into a number so obviously
    /// wrong that it reads as the diagnosis it is.
    func expiresIn(_ epoch: Int, _ life: TimeInterval) -> Int {
        let seconds = TimeInterval(epoch) / 1000 + life - now.timeIntervalSince1970
        guard seconds > 0 else { return 0 }
        // `TimeInterval(Int.max)` rounds UP to 2^63, so anything strictly below it converts.
        return seconds < TimeInterval(Int.max) ? Int(seconds) : Int.max
    }
    switch occupant {
    case .request(let waiting):
        return "session \(sessionKey) already has a line waiting to be typed into it, so nothing "
            + "was queued for this one: a second request at that address would replace the first, "
            + "and the line somebody queued would be dropped with nothing anywhere recording it. "
            + "That one is typed at the first moment that session is out of its own turn, or "
            + "dropped in \(expiresIn(waiting.epoch, sessionInputQueuedLife))s if no such moment "
            + "arrives; ask again after either"
    case .answer(let answer):
        let left = expiresIn(answer.epoch, sessionInputAnswerLife(answer))
        return "session \(sessionKey) was sent a line already and the answer to it "
            + "(\(answer.outcome)) has not been collected yet, so nothing was queued for this one: "
            + "that answer is what the caller before you is still polling for, and taking it away "
            + "would tell them nobody answered for text that was in fact typed. It goes away when "
            + "they read it, or in \(left)s if they are gone"
    }
}
