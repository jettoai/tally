import Foundation

// How Claude Code's OWN `/model` appears in a transcript, and the one thing worth reading out of it.
//
// Split from TranscriptWatcher.swift at that file's size cap. The division is real rather than
// arithmetic: everything here is about a FOREIGN command's output format - a display string written
// by another program, which can change under us - while the watcher is about this session's own
// events. Keeping the two apart is also what keeps the rule below visible: of the three things that
// line says, exactly one is safe to parse.


/// The invocation event's tag, matched whole. Whole because the prefix is shared: `/tally-model`
/// writes `<command-name>/tally-model</command-name>`, which contains neither this string nor any
/// part of it that could be mistaken for it.
let nativeModelCommandTag = "<command-name>/model</command-name>"

/// The prefix of the line that command prints. A prefilter only - the text past it is ANSI-coded,
/// so the reading itself is done on the decoded content.
let nativeModelStdoutPrefix = "<local-command-stdout>Set model to"

/// The argument text of a `/model` invocation record (`<command-args>sonnet</command-args>`), or nil
/// when it carried none (the picker). Every record of `/model sonnet` read on this machine on
/// 2026-11-14 carried it (8 of 8), which is what lets us tell our own typed line from a person's.
func nativeModelCommandArgs(inLine text: String) -> String? {
    guard let open = text.range(of: "<command-args>"),
          let close = text.range(of: "</command-args>", range: open.upperBound ..< text.endIndex)
    else { return nil }
    let args = text[open.upperBound ..< close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    return args.isEmpty ? nil : args
}

/// What the CONTENT of a slash-command invocation opens with, whichever command it is: Claude Code
/// writes `<command-message>` and `<command-name>` in an order that has changed between versions, so
/// only the family is asserted (`lineIsCommandRecord`, TranscriptSignals.swift).
let nativeModelCommandOpening = "<command-"

/// What the content of the picker's own echo opens with.
let nativeModelStdoutOpening = "<local-command-stdout>"

/// The effort Claude Code's own `/model` reported choosing, or nil when it reported none.
///
/// A CLOSED SET, matched whole, and deliberately nothing more. The line is a display string
/// ("Set model to Opus 5 (1M context) and saved as your default for new sessions with xhigh
/// effort"): the model NAME in it is a label that changes with the product and must never be
/// parsed, while the effort is one of the levels the CLI itself enumerates. Matching the whole
/// phrase around each known level is what keeps `high` from claiming a line that says `xhigh`.
///
/// Anything else answers nil rather than a guess, which the caller reads as "leave the effort axis
/// where it is" - the same thing `tally model <model>` with no effort means.
func nativeModelEffort(inStdout text: String, efforts: [String] = claudeEffortNames()) -> String? {
    let plain = strippingANSI(text)
    return efforts.first { plain.lowercased().contains("with \($0.lowercased()) effort") }
}

/// The text with SGR escape sequences removed. The line above arrives with the chosen model and the
/// effort each wrapped in bold, so every reading of it has to strip them first.
func strippingANSI(_ text: String) -> String {
    var out = ""
    var rest = Substring(text)
    while let escape = rest.firstIndex(of: "\u{1B}") {
        out += rest[..<escape]
        // A CSI sequence ends at its final byte, which for the codes here is always a letter.
        guard let end = rest[escape...].firstIndex(where: { $0.isLetter && $0 != "[" }) else {
            return out
        }
        rest = rest[rest.index(after: end)...]
    }
    return out + rest
}
