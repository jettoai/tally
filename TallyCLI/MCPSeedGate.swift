import Foundation

// WHETHER A CONFIG HOME'S SIBLINGS HAVE TO BE READ AT ALL, which is the question in front of the
// grant seeding (MCPAuthSync.swift). Its own file rather than a section of MCPAuthMerge.swift, which
// decides what a merged document CONTAINS: this decides whether that arithmetic is reached at all,
// and the two share no values. Pure for the same reason its neighbour is - no Keychain and no
// filesystem here, so every rule below is one a test can state (tests/mcpauthsync/gate.swift).
//
// THE COST THIS GATE EXISTS FOR: without it, every launch reads the credentials SECRET of every
// other config home on the machine (four reads here, one per sibling) to answer a question whose
// answer is almost always "nothing has moved since the last launch". Those reads are the expensive
// half of this feature by a wide margin - they are the only place in Tally a secret is read at all,
// and they are what raises the macOS consent dialog on a home whose ACL this binary is not yet on.
//
// So the question is put to ATTRIBUTES first (`KeychainReader.modifiedAt`, which returns no secret
// and prompts nobody), against a record of what each sibling's item looked like when its grants were
// last folded into this home.
//
// WHAT THE MODIFICATION DATE CAN AND CANNOT SEE: macOS keeps it to WHOLE SECONDS (measured
// 2026-08-22 on this machine against an item this process created and then updated: the date moved
// on every update and never carried a fraction). Two writes inside one second are therefore one
// write to this gate, and that is not merely a delay: a sibling written AGAIN in the same second
// this pass read it carries the very date this pass wrote down, so a strictly-greater comparison
// would answer "unchanged" at that home for ever after. Nothing later repairs it, because what moves
// the date is another write and the home in question may sit idle for weeks. The record is therefore
// clamped as it is written (`mcpSeedRecordedDate` states the rule and what it costs), and with that
// in place the worst outcome of the whole gate is a seeding that happens at the next launch instead
// of this one, which is the same outcome as every other fail-open path here (MCPAuthSync.swift's
// header).
//
// WHAT THE GATE DOES CHANGE, stated because it is a real behaviour difference and not only a saving:
// an UNCHANGED sibling is not re-read, so its grants are no longer re-offered to the target on every
// launch. Removing a server in the target home used to be undone at the next launch by whichever
// sibling still had it (the add-only edge MCPAuthMerge.swift's header describes); now it is undone at
// the next launch AFTER that sibling's item is written. The target's own item is deliberately not
// part of the gate: Claude Code rewrites it whenever it refreshes the login token beside the grants,
// so a gate that watched it would open on nearly every launch and save nothing.

/// What one config home last merged from its siblings: sibling home path, to the modification date
/// that sibling's credentials item carried at the moment its grants were folded in.
typealias MCPSeedRecord = [String: Date]

/// One sibling home as an attribute probe found it. No secret was read to build this, and no consent
/// dialog was raised to find it out.
struct MCPSeedProbe: Equatable {
    var home: String
    /// When the item was last written, or nil when macOS would not say - which is the answer a
    /// locked keychain gives, and never the answer "it has not moved".
    var modifiedAt: Date?
}

/// The sibling homes whose credentials SECRET has to be read, out of what the probe found and what
/// was recorded the last time this target home was seeded.
///
/// Three ways to be in the answer, and only one of them is an actual change:
///
///   - NO RECORD for that home. Either this target has never merged from it, or the record file was
///     removed or would not parse. Both mean read: a home that has never merged from its siblings is
///     the case this whole feature exists for, and losing a record may only ever cost a read.
///   - NO MODIFICATION DATE. The probe could not tell, and "cannot tell" must never read as
///     "unchanged" - the direction to be wrong in is the behaviour from before this gate existed.
///   - A modification date STRICTLY LATER than the recorded one. Strictly, because the dates are
///     whole seconds (above): equal means "the same second, and possibly a write this gate cannot
///     see". Reading once too often costs one read; skipping once too often costs a grant that never
///     arrives.
func mcpSeedSourcesToRead(probed: [MCPSeedProbe], record: MCPSeedRecord) -> [MCPSeedProbe] {
    probed.filter { probe in
        guard let lastMerged = record[probe.home], let modifiedAt = probe.modifiedAt else {
            return true
        }
        return modifiedAt > lastMerged
    }
}

// MARK: - Where the record is kept

/// What `home` last merged from, out of the decoded record document (`~/.tally/mcp-seed.json`,
/// MCPAuthSync.swift).
///
/// KEYED BY THE TARGET HOME FIRST and the sibling second, which is the point of the document rather
/// than a detail of its shape: "sibling A was last read at T" is not a fact about the machine, it is
/// a fact about ONE HOME'S MERGE. A flat map would tell a home that has never been seeded that its
/// siblings are unchanged, and the home that has never been seeded is exactly what this feature was
/// built for (a cap handoff lands a session on an account that has authorized nothing).
///
/// Epoch seconds rather than an ISO 8601 string: the value is compared for order and for nothing
/// else, and this repo has already been bitten once by an encoder dropping the fractional part of a
/// date on the way out. A number cannot lose what it was never asked to carry.
func mcpSeedRecord(in document: [String: Any], for home: String) -> MCPSeedRecord {
    guard let mine = document[home] as? [String: Any] else { return [:] }
    return mine.compactMapValues { value in
        guard let seconds = value as? Double, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

/// The document with `home`'s record replaced and every OTHER home's carried through by value.
///
/// Patched rather than rebuilt because two launches can be seeding two different homes in the same
/// moment, and the one that writes second must not publish a document that has forgotten the first.
func mcpSeedDocument(_ document: [String: Any], setting record: MCPSeedRecord,
                     for home: String) -> [String: Any] {
    var next = document
    next[home] = record.mapValues { $0.timeIntervalSince1970 }
    return next
}

/// The date to write down for an item this pass has just read.
///
/// THE SAME-SECOND TRAP, which is the one failure of this gate that would be permanent rather than
/// one launch long. Modification dates have whole-second resolution, so an item written again in the
/// second this pass read it comes back carrying exactly the date that was recorded. Strictly greater
/// then answers "unchanged" at every launch from then on, and nothing repairs it on its own: it is a
/// WRITE that moves the date, not the passing of time, and the home may be idle for weeks.
///
/// So a date landing in the second this pass is running in is recorded ONE SECOND EARLIER than it
/// was read. That second has elapsed by the next launch, which therefore reads the item once more,
/// gets a date it can now trust, and records it unclamped. The whole cost is that one extra read,
/// for a sibling whose item happened to be written in the same second as a launch.
///
/// Only the RECORD is clamped. The date handed to the merge is the one the probe returned, because
/// there it is evidence of which of two documents is newer and moving it by a second would be a lie
/// about that.
func mcpSeedRecordedDate(_ modifiedAt: Date, readingAt now: Date) -> Date {
    guard modifiedAt.timeIntervalSince1970 >= now.timeIntervalSince1970.rounded(.down) else {
        return modifiedAt
    }
    return modifiedAt.addingTimeInterval(-1)
}
