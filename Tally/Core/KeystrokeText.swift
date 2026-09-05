import Foundation

// WHAT MAY GO ON A TERMINAL'S INPUT QUEUE, in one place for every sentence this repository types
// into somebody's session.
//
// WHY IT IS A FILE OF ITS OWN RATHER THAN A RULE PER CALLER. Two of the strings that reach that
// queue are built out of text nobody here wrote: an account label comes from a rename popover
// (`quotaKnockName`) and a process name is the last component of an executable path
// (`hostHealthKnockSentence`), and `injectSessionInput` pushes every byte of what it is given in as
// though it had been typed. A newline in the middle of one of those sentences is a Return: the
// first half is submitted as a prompt and the rest is typed into whatever comes up next, and ESC is
// the same accident one step further, since a TUI reads it as a command rather than as text. Two
// spellings of that rule is one refusal and one repair that can come to disagree, and the
// disagreement is silent - a string judged usable by one and rewritten by the other.
//
// FOUNDATION ONLY, so both targets compile it (project.yml states the rule this repository applies
// to every such pair): the app builds the host-health sentence and the CLI is what types it.

/// Whether `text` can go on that queue as it stands.
///
/// Asked THROUGH the strip below rather than beside it, which is what makes the pair one rule: a
/// second predicate would be a second answer to "what does a terminal read as a keystroke".
func keystrokeTypeable(_ text: String) -> Bool {
    !text.isEmpty && keystrokeStripped(text) == text
}

/// The same string with those scalars dropped, for a caller with nothing else to print.
func keystrokeStripped(_ text: String) -> String {
    String(text.unicodeScalars.filter {
        !CharacterSet.controlCharacters.contains($0) && !$0.properties.isDefaultIgnorableCodePoint
    })
}

/// `text` cut to at most `limit` UTF-8 BYTES, never through a character.
///
/// Bytes because bytes are what is being bounded (the channel's limit, and 30ms of the poll loop
/// per one), and characters because a cut inside a multi-byte scalar is not a shorter string, it is
/// a broken one. Whole Characters rather than scalars so an emoji built from several does not lose
/// half of itself either.
func keystrokeClipped(_ text: String, bytes limit: Int) -> String {
    guard text.utf8.count > limit else { return text }
    var out = ""
    var used = 0
    for character in text {
        let size = character.utf8.count
        guard used + size <= limit else { break }
        out.append(character)
        used += size
    }
    return out
}
