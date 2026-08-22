import Foundation

// WHETHER A HOME HAS TO BE READ AT ALL: which siblings' credentials SECRETS a launch reads, decided
// from attribute probes that read none of them (TallyCLI/MCPSeedGate.swift).
//
// Getting it wrong in one direction costs a Keychain read, and a consent dialog, at every launch for
// ever; in the other it costs a grant that never arrives, on a home that has just been handed a
// session and has authorized nothing. So the seam it turns on - a modification date EQUAL to the
// recorded one, which is what a whole-second resolution shows for two events in one second - is
// asserted here rather than sampled.
//
// Values, checked by calling the rules, exactly as main.swift checks the merge; its own file because
// it is a second subject and that one is already long. wiring.swift is where the ORDERS are, and the
// order is half of this gate: a rule consulted after the reads it exists to avoid saves nothing.

func checkTheFreshnessGate() {
    let sibling2 = "/Users/someone/.claude2"
    let sibling3 = "/Users/someone/.claude3"

    do {
        let two = MCPSeedProbe(home: sibling2, modifiedAt: old)
        let three = MCPSeedProbe(home: sibling3, modifiedAt: recent)
        expect(mcpSeedSourcesToRead(probed: [two, three],
                                    record: [sibling2: old, sibling3: recent]).isEmpty,
               "a launch where no sibling's item has moved reads no secret at all")
        expect(mcpSeedSourcesToRead(probed: [two, three], record: [:]) == [two, three],
               "a home with no record of its siblings reads every one of them")
        // The record is one HOME's merge, so another home's entry answers nothing about this one. This
        // is the case a flat record would get wrong, and it is the case the feature exists for: a cap
        // handoff lands a session on a home that has merged from nobody.
        expect(mcpSeedSourcesToRead(probed: [two], record: ["/Users/someone/.claude9": recent]) == [two],
               "…including on a machine whose other homes have records of their own")
    }

    do {
        let probe = MCPSeedProbe(home: sibling2, modifiedAt: recent)
        expect(mcpSeedSourcesToRead(probed: [probe], record: [sibling2: old]) == [probe],
               "a sibling written since the last merge is read")
        expect(mcpSeedSourcesToRead(probed: [probe], record: [sibling2: recent]).isEmpty,
               "…and one whose item carries the recorded date exactly is not, which is what a write in "
                   + "the same second as the record looks like from outside")
        expect(mcpSeedSourcesToRead(probed: [probe],
                                    record: [sibling2: recent.addingTimeInterval(hour)]).isEmpty,
               "…nor is one older than the record")
        let mute = MCPSeedProbe(home: sibling2, modifiedAt: nil)
        expect(mcpSeedSourcesToRead(probed: [mute], record: [sibling2: recent]) == [mute],
               "a probe macOS would not answer reads as changed, never as unchanged")
    }

    do {
        // The two halves in the order the launcher puts them: the gate lets a sibling through because
        // its item moved, and THAT document is the one the merge then folds in.
        let probe = MCPSeedProbe(home: sibling2, modifiedAt: recent)
        let toRead = mcpSeedSourcesToRead(probed: [probe], record: [sibling2: old])
        let target = blob(["sentry|a": grant("sentry")])
        let source = blob(["sentry|a": grant("sentry"), "notion|b": grant("notion")])
        let seeded = toRead.isEmpty ? nil
            : seededCredentialData(target: target, targetWrittenAt: old,
                                   sources: toRead.map { (source, $0.modifiedAt) })
        expect(seeded?.adopted == ["notion|b"], "a sibling the gate lets through is read and merged")
    }

    // MARK: - Where the record is kept

    do {
        // The record document as the CLI keeps it: target home, to sibling home, to epoch seconds.
        // Another home's entry stands in for the whole rest of the machine's fleet, because the one
        // thing a write here may not do is forget a home it was not about.
        let home = "/Users/someone/.claude"
        let existing: [String: Any] = [sibling3: [sibling2: old.timeIntervalSince1970]]
        let next = mcpSeedDocument(existing, setting: [sibling2: recent], for: home)

        expect(canonical(next[sibling3] as Any) == canonical(existing[sibling3] as Any),
               "recording one home's merge carries every other home's record through untouched")
        expect(mcpSeedRecord(in: next, for: home) == [sibling2: recent],
               "…and the record reads back as the dates that went into it")
        expect(mcpSeedRecord(in: next, for: sibling2).isEmpty, "…for that home and for no other")
        // What is written has to survive the encoder that writes it: a Date left in the document
        // would not encode at all, which is why it holds epoch seconds.
        expect(JSONSerialization.isValidJSONObject(next), "…and what is handed to the encoder is JSON")
        let stored = document((try? JSONSerialization.data(withJSONObject: next)) ?? Data())
        expect(mcpSeedRecord(in: stored, for: home) == [sibling2: recent],
               "…and comes back the same after the round trip through the file")
    }

    do {
        expect(mcpSeedRecord(in: [:], for: "/Users/someone/.claude").isEmpty,
               "a machine that has never recorded anything records nothing, rather than failing")
        expect(mcpSeedRecord(in: ["/Users/someone/.claude": ["/x": "yesterday"]],
                             for: "/Users/someone/.claude").isEmpty,
               "…and an entry that is not a number is skipped rather than read as a date")
    }

    // MARK: - The same-second trap

    // The one way this gate could fail PERMANENTLY rather than for one launch: an item written again
    // inside the second it was read carries the date that was just recorded, and strictly greater
    // then says "unchanged" for ever, because only another write moves the date on.

    do {
        let read = Date(timeIntervalSince1970: 1_800_000_000)
        expect(mcpSeedRecordedDate(read, readingAt: read) == read.addingTimeInterval(-1),
               "an item written in the second this pass is running in is recorded a second early, "
                   + "so the next launch is made to read it again")
        expect(mcpSeedRecordedDate(read, readingAt: read.addingTimeInterval(0.9))
                == read.addingTimeInterval(-1),
               "…and so is one whose second has not yet elapsed when the record is written")
        expect(mcpSeedRecordedDate(read, readingAt: read.addingTimeInterval(1))
                == read,
               "an item from a second that is already over is recorded as it stands")
        expect(mcpSeedRecordedDate(old, readingAt: recent) == old,
               "…and so is every older one, which is nearly all of them")
        // The clamp has to actually reopen the gate, which is the thing it is for: the recorded date
        // must lose to the date the next launch's probe returns.
        let clamped = mcpSeedRecordedDate(read, readingAt: read)
        let probe = MCPSeedProbe(home: sibling2, modifiedAt: read)
        expect(mcpSeedSourcesToRead(probed: [probe], record: [sibling2: clamped]) == [probe],
               "…and the next launch really does read it, on the same date the probe returned")
    }
}
