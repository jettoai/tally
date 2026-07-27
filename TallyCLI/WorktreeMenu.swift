import Darwin
import Foundation

// Arrow-key selection menu for bare `tally claude -w`: an interactive replacement for the numbered
// stderr prompt in Worktree.swift. Everything here draws to /dev/tty (never stdout, which stays a
// clean pipe for the exec that follows) and leaves the terminal exactly as it found it on every
// exit path. The rendering and key decoding are split into pure functions (`renderRows`,
// `decodeKey`) so the visual layout and the escape-sequence handling are unit-tested without a tty.

/// The user's choice from the menu. `existing(i)` indexes into the rows passed to `selectWorktree`.
enum MenuSelection: Equatable {
    case existing(Int)
    case newWorktree
    case cancelled
}

/// One selectable worktree line, already resolved from git (age is `%cr`, subject is `%s`).
struct MenuRow {
    let branch: String
    let age: String
    let dirty: Bool
    let subject: String
}

/// A decoded keypress. `digit(n)` carries the raw 0-9 typed; the caller maps it to a 1-based row.
enum Key: Equatable {
    case up
    case down
    case enter
    case digit(Int)
    case newKey
    case cancel
    case other
}

// MARK: - Colors (same electric-purple brand vocabulary as Statusline.swift)

private let ansiPurple = "\u{1B}[38;5;135m"
private let ansiDim = "\u{1B}[2m"
private let ansiYellow = "\u{1B}[33m"
private let ansiReset = "\u{1B}[0m"

// MARK: - Pure rendering

/// A subject clipped to at most `max` display characters, with a trailing ellipsis when clipped.
/// Character-based (not byte-based) so multi-byte commit subjects clip on a grapheme boundary.
func truncateSubject(_ subject: String, max: Int = 40) -> String {
    subject.count <= max ? subject : String(subject.prefix(max - 1)) + "\u{2026}"
}

/// Build the menu frame as one line per row plus a trailing "n) new worktree" line. `highlighted`
/// is an index into `[rows..., newWorktreeRow]`: 0..<rows.count marks an existing worktree,
/// rows.count marks the new-worktree line. The highlighted row wears the "▸" cursor and purple
/// branch; a dirty worktree gets a yellow "●"; the subject is dimmed and clipped. Pure: the ANSI
/// codes are literal so tests can assert on "▸"/"●" without a terminal.
func renderRows(_ rows: [MenuRow], highlighted: Int) -> [String] {
    var lines: [String] = []
    for (i, row) in rows.enumerated() {
        let selected = i == highlighted
        let cursor = selected ? "\(ansiPurple)\u{25B8}\(ansiReset)" : " "
        let branch = selected ? "\(ansiPurple)\(row.branch)\(ansiReset)" : row.branch
        let age = "\(ansiDim)(\(row.age.isEmpty ? "no commits" : row.age))\(ansiReset)"
        let dirty = row.dirty ? " \(ansiYellow)\u{25CF}\(ansiReset)" : ""
        let clipped = truncateSubject(row.subject)
        let subject = clipped.isEmpty ? "" : "  \(ansiDim)\(clipped)\(ansiReset)"
        lines.append("\(cursor) \(i + 1)) \(branch)  \(age)\(dirty)\(subject)")
    }
    let newSelected = highlighted == rows.count
    let newCursor = newSelected ? "\(ansiPurple)\u{25B8}\(ansiReset)" : " "
    let newLabel = newSelected ? "\(ansiPurple)n) new worktree\(ansiReset)" : "n) new worktree"
    lines.append("\(newCursor) \(newLabel)")
    return lines
}

// MARK: - Pure width measurement and clipping

// Scalars a terminal draws two columns wide: a compact heuristic (not the full Unicode
// East_Asian_Width table) good enough for menu lines and the tree's column layout.
//
// The first group is East_Asian_Width=Wide in the classic sense: CJK ideographs, Hangul, and
// fullwidth forms.
//
// The second is emoji, which Unicode also gives East_Asian_Width=Wide and which are exactly the
// code points whose Emoji_Presentation defaults to the coloured glyph (a terminal draws those two
// columns; the text-presentation symbols around them stay one). Counting them as one column made
// the tree misalign every row holding an emoji branch name by a column, and made the menu clip an
// emoji line one column later than its budget. The pictographic planes are listed as blocks and the
// older symbol code points individually, because their neighbours in those blocks are narrow text
// symbols (U+2713 CHECK MARK next to U+2705 WHITE HEAVY CHECK MARK) and widening a whole block
// there would misalign in the other direction.
private let wideScalarRanges: [ClosedRange<UInt32>] = [
    0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
    0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x3FFFD,
    0x231A...0x231B, 0x23E9...0x23EC, 0x23F0...0x23F0, 0x23F3...0x23F3,
    0x25FD...0x25FE, 0x2614...0x2615, 0x2648...0x2653, 0x267F...0x267F,
    0x2693...0x2693, 0x26A1...0x26A1, 0x26AA...0x26AB, 0x26BD...0x26BE,
    0x26C4...0x26C5, 0x26CE...0x26CE, 0x26D4...0x26D4, 0x26EA...0x26EA,
    0x26F2...0x26F3, 0x26F5...0x26F5, 0x26FA...0x26FA, 0x26FD...0x26FD,
    0x2705...0x2705, 0x270A...0x270B, 0x2728...0x2728, 0x274C...0x274C,
    0x274E...0x274E, 0x2753...0x2755, 0x2757...0x2757, 0x2795...0x2797,
    0x27B0...0x27B0, 0x27BF...0x27BF, 0x2B1B...0x2B1C, 0x2B50...0x2B50,
    // Regional indicators: a flag is a PAIR of these and one grapheme cluster, and cluster width is
    // the widest scalar in it, so each has to carry the full two columns the flag is drawn in.
    0x1F1E6...0x1F1FF,
    0x2B55...0x2B55, 0x1F004...0x1F004, 0x1F0CF...0x1F0CF, 0x1F18E...0x1F18E,
    0x1F191...0x1F19A, 0x1F200...0x1F320, 0x1F32D...0x1F335, 0x1F337...0x1F37C,
    0x1F37E...0x1F393, 0x1F3A0...0x1F3CA, 0x1F3CF...0x1F3D3, 0x1F3E0...0x1F3F0,
    0x1F3F4...0x1F3F4, 0x1F3F8...0x1F43E, 0x1F440...0x1F440, 0x1F442...0x1F4FC,
    0x1F4FF...0x1F53D, 0x1F54B...0x1F54E, 0x1F550...0x1F567, 0x1F57A...0x1F57A,
    0x1F595...0x1F596, 0x1F5A4...0x1F5A4, 0x1F5FB...0x1F64F, 0x1F680...0x1F6C5,
    0x1F6CC...0x1F6CC, 0x1F6D0...0x1F6D2, 0x1F6D5...0x1F6D7, 0x1F6DC...0x1F6DF,
    0x1F6EB...0x1F6EC, 0x1F6F4...0x1F6FC, 0x1F7E0...0x1F7EB, 0x1F7F0...0x1F7F0,
    0x1F90C...0x1F93A, 0x1F93C...0x1F945, 0x1F947...0x1F9FF, 0x1FA70...0x1FAFF,
]

/// Scalars that ride along on the character before them and take no column of their own: combining
/// marks, the variation selectors that pick a text or emoji presentation, the zero width joiner that
/// fuses an emoji sequence, the skin tone modifiers, and the tag characters a subdivision flag is
/// spelled with. Counting these as one column each is what made a decomposed "e" plus an accent two
/// columns wide and a joined "woman technologist" five.
private func isZeroWidth(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .nonspacingMark, .enclosingMark, .spacingMark, .format:
        return true
    default:
        break
    }
    return (0xFE00...0xFE0F).contains(scalar.value)      // variation selectors
        || (0x1F3FB...0x1F3FF).contains(scalar.value)    // skin tone modifiers
        || (0xE0020...0xE007F).contains(scalar.value)    // tag characters
}

private func scalarWidth(_ scalar: Unicode.Scalar) -> Int {
    if isZeroWidth(scalar) { return 0 }
    return wideScalarRanges.contains { $0.contains(scalar.value) } ? 2 : 1
}

/// One grapheme cluster's width: the widest scalar in it, since the rest are marks and joiners that
/// draw on top of it rather than beside it. A cluster of nothing but zero-width scalars takes no
/// space at all.
private func clusterWidth(_ character: Character) -> Int {
    character.unicodeScalars.reduce(0) { max($0, scalarWidth($1)) }
}

/// Display columns a string occupies, measured in GRAPHEME CLUSTERS: what a terminal draws as one
/// character costs one cell (or two when it is wide), no matter how many scalars spell it. ANSI
/// escape sequences (ESC [ ... final byte, or ESC + one byte) render to zero width; a CSI runs from
/// ESC [ through the first byte in 0x40...0x7E. Pure, so tests measure clipped output directly.
func displayColumns(_ line: String) -> Int {
    var width = 0
    var index = line.startIndex
    while index < line.endIndex {
        if let next = skipEscapeSequence(in: line, at: index) {
            index = next
            continue
        }
        width += clusterWidth(line[index])
        index = line.index(after: index)
    }
    return width
}

/// The index just past the escape sequence starting at `index`, or nil when nothing starts there.
/// ESC is a control character, so it is always a grapheme cluster of its own and can never be
/// hidden inside one: the sequence is found and skipped whole rather than split.
private func skipEscapeSequence(in line: String, at index: String.Index) -> String.Index? {
    guard line[index].unicodeScalars.first?.value == 0x1B else { return nil }
    var cursor = line.index(after: index)
    guard cursor < line.endIndex else { return cursor }
    guard line[cursor].unicodeScalars.first?.value == 0x5B else { return line.index(after: cursor) }
    cursor = line.index(after: cursor)
    while cursor < line.endIndex {
        let byte = line[cursor].unicodeScalars.first?.value ?? 0
        cursor = line.index(after: cursor)
        if (0x40 ... 0x7E).contains(byte) { break }
    }
    return cursor
}

/// Clip a rendered line so its display width never exceeds `columns`, measuring with
/// `displayColumns` so ANSI codes cost nothing and are never split. A line that already fits is
/// returned untouched. When it does not fit, visible content is kept up to `columns - 1` columns
/// (reserving one for the ellipsis), then a U+2026 and an ANSI reset are appended so a clipped
/// colored segment cannot bleed its color onto the next line.
/// Clipping walks grapheme clusters for the same reason measuring does: a cut between a base
/// character and its accent, or inside a joined emoji, produces a glyph nobody typed.
func clipToDisplayWidth(_ line: String, columns: Int) -> String {
    if columns <= 0 { return "" }
    if displayColumns(line) <= columns { return line }
    var out = ""
    var width = 0
    let budget = columns - 1
    var index = line.startIndex
    while index < line.endIndex {
        if let next = skipEscapeSequence(in: line, at: index) {
            // Copy the whole escape sequence verbatim; zero width, and it must never be split.
            out += line[index ..< next]
            index = next
            continue
        }
        let cluster = line[index]
        let clusterColumns = clusterWidth(cluster)
        if width + clusterColumns > budget { break }
        out.append(cluster)
        width += clusterColumns
        index = line.index(after: index)
    }
    return out + "\u{2026}" + ansiReset
}

// MARK: - Pure key decoding

/// Decode a byte sequence read from the tty into a `Key`. Arrow keys arrive as a 3-byte CSI
/// sequence (ESC [ A/B); a lone ESC is a cancel, distinct from the arrow sequence by length. Both
/// vi-style j/k and the arrows move; n/N opens a new worktree; q or a lone ESC cancels; 0-9 is a
/// direct row pick. Anything else is ignored by the caller.
func decodeKey(_ bytes: [UInt8]) -> Key {
    if bytes.count == 3, bytes[0] == 0x1B, bytes[1] == 0x5B {
        switch bytes[2] {
        case 0x41: return .up      // ESC [ A
        case 0x42: return .down    // ESC [ B
        default: return .other
        }
    }
    guard bytes.count == 1 else { return .other }
    switch bytes[0] {
    case 0x1B, 0x71, 0x51: return .cancel        // ESC, q, Q
    case 0x0D, 0x0A: return .enter               // CR, LF
    case 0x6E, 0x4E: return .newKey              // n, N
    case 0x6A: return .down                      // j
    case 0x6B: return .up                        // k
    case 0x30...0x39: return .digit(Int(bytes[0] - 0x30))
    default: return .other
    }
}

// MARK: - Pure state transition

/// Fold one decoded key into the menu state. `rowCount` excludes the trailing new-worktree line, so
/// the valid highlight range is 0...rowCount (rowCount marks the new-worktree line). A non-nil
/// selection means the key committed a choice and the loop should stop; nil means keep going with
/// the returned highlight. Pure, so the whole key-to-selection path is tested without a tty.
func applyKey(_ key: Key, highlighted: Int, rowCount: Int) -> (highlighted: Int, selection: MenuSelection?) {
    let lineCount = rowCount + 1
    switch key {
    case .up:
        return ((highlighted - 1 + lineCount) % lineCount, nil)
    case .down:
        return ((highlighted + 1) % lineCount, nil)
    case .enter:
        return (highlighted, highlighted == rowCount ? .newWorktree : .existing(highlighted))
    case .digit(let n):
        return n >= 1 && n <= rowCount ? (highlighted, .existing(n - 1)) : (highlighted, nil)
    case .newKey:
        return (highlighted, .newWorktree)
    case .cancel:
        return (highlighted, .cancelled)
    case .other:
        return (highlighted, nil)
    }
}

// MARK: - Terminal state for the SIGINT handler

// A signal handler is a bare C function that cannot capture, so the tty fd and the saved terminal
// mode live in file-scope state it can reach. `nonisolated(unsafe)` is the sanctioned escape hatch
// for this C-interop pattern under strict concurrency: signal delivery is inherently unsynchronized
// and tcsetattr/write/_exit are all async-signal-safe.
private nonisolated(unsafe) var menuSavedFD: Int32 = -1
private nonisolated(unsafe) var menuSavedTermios = termios()
private nonisolated(unsafe) var menuTermiosValid = false

/// SIGINT during the menu: restore the cooked terminal mode and show the cursor before exiting 130,
/// so a Ctrl-C never leaves the shell in raw mode with a hidden cursor.
private func menuSigintHandler(_ signal: Int32) {
    if menuTermiosValid, menuSavedFD >= 0 {
        _ = tcsetattr(menuSavedFD, TCSANOW, &menuSavedTermios)
        _ = "\u{1B}[?25h".withCString { Darwin.write(menuSavedFD, $0, strlen($0)) }
    }
    _exit(130)
}

// MARK: - Interactive selection

/// Present the arrow-key menu on /dev/tty and return the choice, or nil when an interactive menu is
/// not possible (no tty, a dumb terminal, or raw mode could not be set) so the caller falls back to
/// the numbered prompt. The terminal is always restored: a `defer` covers every normal and error
/// path, and a SIGINT handler covers Ctrl-C.
func selectWorktree(rows: [MenuRow]) -> MenuSelection? {
    if ProcessInfo.processInfo.environment["TERM"] == "dumb" { return nil }
    let fd = open("/dev/tty", O_RDWR)
    guard fd >= 0 else { return nil }
    guard isatty(fd) == 1 else { close(fd); return nil }

    var original = termios()
    guard tcgetattr(fd, &original) == 0 else { close(fd); return nil }
    var raw = original
    raw.c_lflag &= ~(tcflag_t(ICANON) | tcflag_t(ECHO))
    raw.c_cc.16 = 1   // VMIN: block until at least one byte
    raw.c_cc.17 = 0   // VTIME: no inter-byte timer
    guard tcsetattr(fd, TCSANOW, &raw) == 0 else { close(fd); return nil }

    menuSavedFD = fd
    menuSavedTermios = original
    menuTermiosValid = true
    let previousSigint = signal(SIGINT, menuSigintHandler)
    defer {
        tcsetattr(fd, TCSANOW, &original)
        menuTermiosValid = false
        menuSavedFD = -1
        signal(SIGINT, previousSigint)
        writeTTY(fd, "\u{1B}[?25h")   // show the cursor again
        close(fd)
    }

    // Measured once: the menu is short-lived, so a live resize mid-selection is not handled. Every
    // line is clipped to width - 1 so it never wraps into a second physical line (which would break
    // the cursor-up redraw math). This matters for the CJK commit subjects in Albert's repos, where
    // 40 graphemes are roughly 80 columns.
    let columns = max(1, terminalWidth(fd) - 1)
    let lineCount = rows.count + 1
    var highlighted = 0
    writeTTY(fd, "\u{1B}[?25l")                 // hide the cursor while the menu is live
    writeTTY(fd, frame(rows: rows, highlighted: highlighted, redraw: false, columns: columns))

    var result: MenuSelection = .cancelled
    while true {
        guard let bytes = readKeySequence(fd) else { break }   // EOF: leave as cancelled
        let (moved, selection) = applyKey(decodeKey(bytes), highlighted: highlighted, rowCount: rows.count)
        if let selection { result = selection; break }
        guard moved != highlighted else { continue }   // ignored key: no redraw
        highlighted = moved
        writeTTY(fd, frame(rows: rows, highlighted: highlighted, redraw: true, columns: columns))
    }

    // Wipe the menu, then leave a one-line dim summary of what was chosen.
    writeTTY(fd, "\u{1B}[\(lineCount)A\r\u{1B}[J")
    switch result {
    case .existing(let i):
        writeTTY(fd, "\(ansiDim)\u{2192} \(rows[i].branch)\(ansiReset)\r\n")
    case .newWorktree:
        writeTTY(fd, "\(ansiDim)\u{2192} new worktree\(ansiReset)\r\n")
    case .cancelled:
        break
    }
    return result
}

/// One frame written in a single tty write to avoid flicker. On a redraw it first moves the cursor
/// up `rows.count + 1` lines (back to the top of the menu), then reprints each line clearing to the
/// end first so a now-shorter line leaves no tail. Each line is clipped to `columns` display columns
/// so none wraps (a wrapped line would desync the cursor-up count). OPOST stays enabled (only
/// ICANON/ECHO are off), so a bare "\n" still maps to CR+LF.
private func frame(rows: [MenuRow], highlighted: Int, redraw: Bool, columns: Int) -> String {
    var out = redraw ? "\u{1B}[\(rows.count + 1)A" : ""
    for line in renderRows(rows, highlighted: highlighted) {
        out += "\r\u{1B}[K\(clipToDisplayWidth(line, columns: columns))\n"
    }
    return out
}

/// The terminal's column count via TIOCGWINSZ, or 80 when the ioctl fails or reports zero (a pipe,
/// or a terminal that does not answer).
private func terminalWidth(_ fd: Int32) -> Int {
    var ws = winsize()
    if ioctl(fd, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 {
        return Int(ws.ws_col)
    }
    return 80
}

/// Read one keypress. A non-ESC byte returns immediately; an ESC polls briefly for the rest of an
/// escape sequence so a lone ESC (cancel) is told apart from an arrow key without blocking. A CSI
/// sequence (ESC [) is consumed through its final byte (0x40-0x7E) even when longer than a plain
/// arrow: a modified arrow like Shift-Up (ESC [ 1 ; 2 A) must not leave its parameter digits in the
/// buffer, where a later read would misread them as a spurious row pick. Returns nil on EOF/error
/// so the caller stops rather than spinning.
private func readKeySequence(_ fd: Int32) -> [UInt8]? {
    var first: UInt8 = 0
    let n = read(fd, &first, 1)
    guard n == 1 else { return nil }
    guard first == 0x1B else { return [first] }
    var seq: [UInt8] = [0x1B]
    while seq.count < 8 {
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&poller, 1, 30) > 0 else { break }   // 30ms: no more bytes means a lone ESC
        var next: UInt8 = 0
        guard read(fd, &next, 1) == 1 else { break }
        seq.append(next)
        if seq[1] == 0x5B {
            // CSI: parameter and intermediate bytes are 0x20-0x3F; the first 0x40-0x7E byte ends it.
            if seq.count >= 3, (0x40 ... 0x7E).contains(next) { break }
        } else if seq.count >= 3 || next != 0x4F {
            // Not CSI: ESC O (SS3) carries one more byte; any other ESC-prefixed pair is complete.
            break
        }
    }
    return seq
}

/// Write a UTF-8 string to the tty fd; partial writes are unlikely for these tiny frames and a lost
/// byte only smudges one render, never the terminal state.
private func writeTTY(_ fd: Int32, _ string: String) {
    let bytes = Array(string.utf8)
    _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
}
