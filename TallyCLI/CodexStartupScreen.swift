import Foundation

// What Codex has drawn before its composer is usable. The startup update menu, sign-in and other
// pickers come up before Codex builds a thread, so no hook or rollout can report them; the PTY bytes
// the relay copies are the only evidence. Measured against codex-cli 0.162.1
// (tests/codex-supervisor/fixtures): Codex draws a loading composer FIRST and the update menu over
// it, so no signature can be latched on sight. Whichever kind was drawn LAST decides: a composer
// placeholder after the last blocking screen means the prompt is reachable. Only read while no
// session binding exists (the supervisor stops asking once one lands).

let codexStartupStallThreshold: TimeInterval = 20

struct CodexStartupScreen {
    static let promptMarkers = ["Ask Codex to do anything", "Ask a follow-up question", "for shortcuts", "context left"]
    static let screenMarkers = ["Update available", "Sign in with ChatGPT"]

    /// Rolling plain-text tail of what Codex drew, escape sequences removed.
    private(set) var text = ""
    /// An escape sequence or UTF-8 character cut at the end of the last packet.
    private var carry: [UInt8] = []

    mutating func observe(_ bytes: [UInt8]) {
        let input = carry + bytes
        carry = []
        var out: [UInt8] = []
        var i = 0
        scan: while i < input.count {
            let byte = input[i]
            guard byte == 0x1B else {
                if byte == 0x0A || byte == 0x0D { out.append(0x0A) } else if byte >= 0x20, byte != 0x7F { out.append(byte) }
                i += 1
                continue
            }
            guard i + 1 < input.count else { carry = Array(input[i...]); break }
            switch input[i + 1] {
            case 0x5B: // CSI: parameters up to a final byte in 0x40...0x7E
                var j = i + 2
                while j < input.count, !(0x40...0x7E).contains(input[j]) { j += 1 }
                guard j < input.count else { carry = Array(input[i...]); break scan }
                // A cursor move separates what was drawn on either side; a style change does not.
                if input[j] != 0x6D { out.append(0x0A) }
                i = j + 1
            case 0x5D: // OSC: up to BEL or ESC backslash
                var j = i + 2
                var end: Int?
                while j < input.count {
                    if input[j] == 0x07 { end = j + 1; break }
                    if input[j] == 0x1B, j + 1 < input.count, input[j + 1] == 0x5C { end = j + 2; break }
                    j += 1
                }
                guard let end else { carry = Array(input[i...]); break scan }
                i = end
            default:
                i += 2
            }
        }
        if carry.isEmpty { carry = Self.unfinishedUTF8(&out) }
        if carry.count > 4096 { carry = [] }
        text = String((text + String(decoding: out, as: UTF8.self)).suffix(4096))
    }

    /// A composer placeholder drawn after the last blocking screen (or with none drawn at all).
    var reachedPrompt: Bool {
        guard let prompt = Self.last(Self.promptMarkers, in: text) else { return false }
        return !screens.contains { $0.range.lowerBound > prompt.lowerBound }
    }

    /// The screen's name for a wait summary: a named screen drawn since the last composer, else the
    /// selected picker row, nil when nothing recognisable is up.
    var title: String? {
        let prompt = Self.last(Self.promptMarkers, in: text)?.lowerBound ?? text.startIndex
        return screens.first { $0.range.lowerBound >= prompt }?.title
    }

    /// Named screens first, then the picker row, each at its last position in `text`.
    private var screens: [(range: Range<String.Index>, title: String)] {
        var found = Self.screenMarkers.compactMap { marker in
            text.range(of: marker, options: .backwards).map { (range: $0, title: marker) }
        }
        // The selected row of a picker, `› 1. Label`: any numbered choice codex is waiting on.
        if let row = text.range(of: "› ", options: .backwards) {
            let line = text[row.upperBound...].prefix { $0 != "\n" }
            if let dot = line.firstIndex(of: "."), !line[..<dot].isEmpty, line[..<dot].allSatisfy(\.isNumber) {
                let label = line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces)
                if !label.isEmpty { found.append((row, String(label.prefix(60)))) }
            }
        }
        return found
    }

    private static func last(_ markers: [String], in text: String) -> Range<String.Index>? {
        markers.compactMap { text.range(of: $0, options: .backwards) }.max { $0.lowerBound < $1.lowerBound }
    }

    /// Moves a trailing, incomplete UTF-8 sequence out of `bytes` so the next packet completes it.
    private static func unfinishedUTF8(_ bytes: inout [UInt8]) -> [UInt8] {
        guard !bytes.isEmpty else { return [] }
        for back in 1...min(3, bytes.count) {
            let byte = bytes[bytes.count - back]
            guard byte & 0xC0 == 0x80 else {
                let need = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
                guard need > back else { return [] }
                let tail = Array(bytes.suffix(back))
                bytes.removeLast(back)
                return tail
            }
        }
        return []
    }
}

/// The wait a launch that has not reached its prompt by `threshold` stands in, or nil.
func codexStartupStall(screen: CodexStartupScreen, launchedAt: Date, bindingLanded: Bool,
                       now: Date, threshold: TimeInterval = codexStartupStallThreshold)
    -> (since: Date, title: String?)? {
    guard !screen.reachedPrompt, !bindingLanded, now.timeIntervalSince(launchedAt) >= threshold else { return nil }
    return (launchedAt, screen.title)
}
