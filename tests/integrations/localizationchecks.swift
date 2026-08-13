import Foundation

// The one thing a localized key may never be: BUILT.
//
// `L(...)` uses the English text ITSELF as the catalog key, so interpolating a value into it makes a
// key that only exists in the catalog for whatever that value happened to be on the day someone
// translated it. Renaming `/tally-switch` to `/tally-account` therefore dropped this message's four
// translations back to English, and nothing noticed: the build succeeded, every suite stayed green,
// and a missing key resolves to the key, so the failure renders as a perfectly ordinary English
// sentence in all five languages.
//
// That is why this check is STATIC. There is no runtime observation that separates "translated" from
// "key returned verbatim" for the source language, so the only place the mistake is visible is the
// source line that builds the key. The lock is the general rule rather than this one message,
// because the message was never special: any `L("... \(x) ...")` in these files has the same hole.
func runLocalizationKeyChecks() {
    let root = URL(fileURLWithPath: #filePath)         // tests/integrations/localizationchecks.swift
        .deletingLastPathComponent()                   // tests/integrations
        .deletingLastPathComponent()                   // tests
        .deletingLastPathComponent()                   // repo root
    let sources = ["Tally/Stores/IntegrationsPromptCommand.swift",
                   "Tally/Stores/IntegrationsSkill.swift",
                   "Tally/Stores/IntegrationsStore.swift",
                   "Tally/Stores/IntegrationsCLITool.swift",
                   "Tally/Stores/IntegrationsCompletion.swift"]

    var keys: [String] = []
    var unreadable: [String] = []
    for name in sources {
        guard let text = try? String(contentsOf: root.appendingPathComponent(name),
                                     encoding: .utf8) else {
            unreadable.append(name)
            continue
        }
        var rest = Substring(text)
        while let open = rest.range(of: "L(\"") {
            rest = rest[open.upperBound...]
            guard let close = rest.range(of: "\")") else { break }
            keys.append(String(rest[..<close.lowerBound]))
            rest = rest[close.upperBound...]
        }
    }

    // A scan that found nothing would satisfy every assertion below, so the harvest is asserted
    // first: a moved file or a changed call shape has to fail loudly rather than silently pass.
    check("the localized-key scan actually read the integration sources",
          unreadable.isEmpty && keys.count >= 10)
    check("no localized key is built by interpolation",
          keys.allSatisfy { !$0.contains("\\(") })

    // And the message that taught us the rule, pinned by name: the file name is an ARGUMENT.
    let occupied = keys.filter { $0.hasPrefix("A different command occupies commands/") }
    check("the occupied-command message has exactly one key", occupied.count == 1)
    check("…which takes the file name as an argument, and never spells a command into itself",
          occupied.first.map { $0.contains("%@") && !$0.contains("tally-") } == true)
    // And its twin, which the SKILL folder move would otherwise have taught us a second time: the
    // folder is an argument for the same reason the file name is, so renaming it keeps the four
    // translations that a key spelling the name into itself would have dropped.
    let occupiedSkill = keys.filter { $0.hasPrefix("A different skill occupies skills/") }
    check("the occupied-skill message has exactly one key", occupiedSkill.count == 1)
    check("…which takes the folder as an argument, and never spells it into itself",
          occupiedSkill.first.map { $0.contains("%@") && !$0.contains("tally") } == true)
}
