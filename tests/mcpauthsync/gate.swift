import Foundation

// WHETHER A HOME HAS TO BE READ AT ALL: which siblings' credentials SECRETS a launch reads, decided
// from attribute probes that read none of them (TallyCLI/MCPAuthMerge.swift).
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
        // A state file as the app publishes it, with the two blocks that are already in it and a key no
        // build of this repo has ever heard of standing in for the ones later builds will add.
        let state: [String: Any] = [
            "version": 1,
            "launch": ["claude": ["mode": "manual", "pinnedHome": "/Users/someone/.claude"]],
            "artifactAccount": "/Users/someone/.claude2",
            "somethingNewerTallyWrote": ["kept": true],
        ]
        let home = "/Users/someone/.claude"
        let next = stateDocumentSettingMCPSeedRecord(state, for: home, record: [sibling2: recent])

        expect(canonical(next["launch"] as Any) == canonical(state["launch"] as Any)
                && next["artifactAccount"] as? String == "/Users/someone/.claude2"
                && next["version"] as? Int == 1
                && canonical(next["somethingNewerTallyWrote"] as Any)
                    == canonical(state["somethingNewerTallyWrote"] as Any),
               "recording a merge carries every other key of the app's document through untouched")
        expect(mcpSeedRecord(in: next, for: home) == [sibling2: recent],
               "…and the record reads back as the dates that went into it")
        expect(mcpSeedRecord(in: next, for: sibling3).isEmpty, "…for that home and for no other")
        // What is written has to survive the encoder that writes it: a Date left in the block would not
        // encode at all, which is why it holds epoch seconds.
        expect(JSONSerialization.isValidJSONObject(next), "…and what is handed to the encoder is JSON")
        let stored = document((try? JSONSerialization.data(withJSONObject: next)) ?? Data())
        expect(mcpSeedRecord(in: stored, for: home) == [sibling2: recent],
               "…and comes back the same after the round trip through the file")
    }

    do {
        expect(mcpSeedRecord(in: ["launch": [:]], for: "/Users/someone/.claude").isEmpty,
               "a state file written before this feature existed records nothing, rather than failing")
        expect(mcpSeedRecord(in: ["mcpSeed": ["/Users/someone/.claude": ["/x": "yesterday"]]],
                             for: "/Users/someone/.claude").isEmpty,
               "…and an entry that is not a number is skipped rather than read as a date")
    }
}
