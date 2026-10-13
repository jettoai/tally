import Foundation

// What Codex has drawn before its composer is usable. The startup update menu, sign-in and other
// pickers come up before Codex builds a thread, so no hook or rollout can report them; the PTY bytes
// the relay copies are the only evidence. They are replayed onto a grid the size of the PTY, as the
// terminal shows them: codex redraws only the cells that changed since its last frame, so a word on
// screen can be made of cells written frames apart (codex-cli 0.162.1 keeps the `e` of "Update"
// from the header's "Open"). The sequences interpreted are the ones recorded real windows use
// (tests/codex-supervisor/fixtures); any other leaves the grid `unreliable` until a full clear, and an
// unreliable grid publishes no menu rows, so an unknown sequence can hide the menu but never get a
// key typed. Each cell keeps when it was last written, so whichever kind was drawn LAST decides:
// codex draws a loading composer first and the update menu over it. Only read while no session
// binding exists (the supervisor stops asking once one lands).

let codexStartupStallThreshold: TimeInterval = 20

struct CodexStartupScreen {
    static let promptMarkers = ["Ask Codex to do anything", "Ask a follow-up question", "for shortcuts", "context left"]
    static let screenMarkers = ["Update available", "Sign in with ChatGPT"]

    private(set) var rows: Int
    private(set) var cols: Int
    /// What each cell shows; `wideTail` marks the right half of a two-column character.
    private var cells: [[Character]]
    /// When each cell was last written or erased (a running count).
    private var stamps: [[Int]]
    private var clock = 0
    private var row = 0, col = 0, top = 0, bottom: Int
    private var wrapPending = false
    /// A sequence this model does not interpret, or a size change, since the last full clear.
    private(set) var unreliable = false
    /// An escape sequence or UTF-8 character cut at the end of the last packet.
    private var carry: [UInt8] = []
    private static let wideTail: Character = "\u{0}"
    /// libc's column width under a UTF-8 locale (what the recorded tmux frames agree with). The
    /// `_l` functions are not imported into Swift, so they are reached through `dlsym`; without them
    /// every character counts as one column, which can only misplace a marker, never type a key.
    nonisolated(unsafe) private static let columnWidth: (Unicode.Scalar) -> Int = {
        typealias NewLocale = @convention(c) (Int32, UnsafePointer<CChar>?, OpaquePointer?) -> OpaquePointer?
        typealias Width = @convention(c) (Int32, OpaquePointer?) -> Int32
        let any = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT
        guard let makeSymbol = dlsym(any, "newlocale"), let widthSymbol = dlsym(any, "wcwidth_l"),
              let locale = unsafeBitCast(makeSymbol, to: NewLocale.self)(1 << 1, "en_US.UTF-8", nil)   // LC_CTYPE_MASK
        else { return { _ in 1 } }
        let width = unsafeBitCast(widthSymbol, to: Width.self)
        return { Int(width(Int32(bitPattern: $0.value), locale)) }
    }()

    init(rows: Int, cols: Int) {
        self.rows = rows > 0 ? rows : 24
        self.cols = cols > 0 ? cols : 80
        cells = Array(repeating: Array(repeating: " ", count: self.cols), count: self.rows)
        stamps = Array(repeating: Array(repeating: 0, count: self.cols), count: self.rows)
        bottom = self.rows - 1
    }

    /// Keeps what fits the new size (top left aligned) so a reached prompt stays reached, but publishes
    /// no menu until codex clears and redraws at the new size.
    mutating func resize(rows newRows: Int, cols newCols: Int) {
        let newRows = newRows > 0 ? newRows : 24, newCols = newCols > 0 ? newCols : 80
        guard newRows != rows || newCols != cols else { return }
        cells = (0..<newRows).map { r in
            (0..<newCols).map { c in r < rows && c < cols ? cells[r][c] : " " }
        }
        stamps = (0..<newRows).map { r in
            (0..<newCols).map { c in r < rows && c < cols ? stamps[r][c] : 0 }
        }
        rows = newRows; cols = newCols
        row = min(row, rows - 1); col = min(col, cols - 1)
        top = 0; bottom = rows - 1
        wrapPending = false
        unreliable = true
    }

    /// The screen, one string per row, trailing blanks removed.
    var lines: [String] {
        (0..<rows).map { r in
            var line = String(cells[r].filter { $0 != Self.wideTail })
            while line.last == " " { line.removeLast() }
            return line
        }
    }

    mutating func observe(_ bytes: [UInt8]) {
        let input = carry + bytes
        carry = []
        var i = 0
        scan: while i < input.count {
            let byte = input[i]
            switch byte {
            case 0x1B:
                guard i + 1 < input.count else { carry = Array(input[i...]); break scan }
                switch input[i + 1] {
                case 0x5B: // CSI: parameters, intermediates, then a final byte in 0x40...0x7E
                    var j = i + 2
                    while j < input.count, !(0x40...0x7E).contains(input[j]) { j += 1 }
                    guard j < input.count else { carry = Array(input[i...]); break scan }
                    csi(Array(input[(i + 2)..<j]), final: input[j])
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
                case 0x4D: // RI
                    reverseIndex(); i += 2
                default:
                    unreliable = true; i += 2
                }
            case 0x0D: col = 0; wrapPending = false; i += 1
            case 0x0A: lineFeed(); wrapPending = false; i += 1
            case 0x07: i += 1
            case 0x00..<0x20, 0x7F: unreliable = true; i += 1
            case 0x20..<0x80: put(Unicode.Scalar(byte)); i += 1
            default:
                let need = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
                guard i + need <= input.count else { carry = Array(input[i...]); break scan }
                for scalar in String(decoding: input[i..<(i + need)], as: UTF8.self).unicodeScalars { put(scalar) }
                i += need
            }
        }
        if carry.count > 4096 { carry = [] }
    }

    /// A composer placeholder drawn after the last blocking screen (or with none drawn at all).
    var reachedPrompt: Bool {
        guard let prompt = hits(Self.promptMarkers).map(\.stamp).max() else { return false }
        let named = hits(Self.screenMarkers).map(\.stamp).max() ?? 0
        return named <= prompt && (picker?.stamp ?? 0) <= prompt
    }

    /// The screen's name for a wait summary: a named screen drawn since the last composer, else the
    /// selected picker row, nil when nothing recognisable is up.
    var title: String? {
        let prompt = hits(Self.promptMarkers).map(\.stamp).max() ?? 0
        let named = hits(Self.screenMarkers).filter { $0.stamp > prompt }
        if let first = Self.screenMarkers.first(where: { marker in named.contains { $0.marker == marker } }) {
            return first
        }
        guard let picker, picker.stamp > prompt else { return nil }
        return picker.label
    }

    /// The update menu as drawn, one row per line, for a person deciding from elsewhere. Only the
    /// update screen: a sign-in screen can carry a login link and code, so nothing else is published.
    var menuLines: [String]? {
        let named = hits(Self.screenMarkers)
        guard !unreliable, title == "Update available",
              !named.contains(where: { $0.marker != "Update available" }),
              let start = named.max(by: { $0.stamp < $1.stamp })?.row
        else { return nil }
        let rows = lines[start...].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return Array(rows.prefix(12).map { String($0.prefix(120)) })
    }

    /// Names one drawing of the menu, so a choice made while looking at it cannot land on another.
    static func screenID(_ lines: [String]) -> String {
        var hash: UInt64 = 0xcbf29ce484222325   // FNV-1a 64, stable across processes and builds
        for byte in lines.joined(separator: "\n").utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return "scr_" + String(format: "%016llx", hash)
    }

    /// Esc, which codex-cli 0.162.1 takes as Skip on the update menu whichever row is selected and
    /// without writing `dismissed_version`. The selected row is not read: Esc does not depend on it, so a
    /// menu drawn with any row selected gets the same keys. Nil when no row is labelled
    /// exactly `Skip` (a menu of another shape, where Esc may mean something else).
    static func skipKeys(_ lines: [String]) -> [UInt8]? {
        let hasSkip = lines.contains { line in
            let body = line.hasPrefix("› ") ? line.dropFirst(2) : Substring(line)
            guard let dot = body.firstIndex(of: "."), Int(body[..<dot]) != nil else { return false }
            return body[body.index(after: dot)...].trimmingCharacters(in: .whitespaces) == "Skip"
        }
        return hasSkip ? [0x1B] : nil
    }

    /// Every visible occurrence of `markers`, stamped with the newest cell it covers: a word whose
    /// cells were partly kept from an older frame was drawn when its newest cell was.
    private func hits(_ markers: [String]) -> [(stamp: Int, row: Int, marker: String)] {
        var found: [(stamp: Int, row: Int, marker: String)] = []
        for r in 0..<rows {
            let visible = (0..<cols).filter { cells[r][$0] != Self.wideTail }
            let text = visible.map { cells[r][$0] }
            for marker in markers {
                let wanted = Array(marker)
                guard wanted.count <= text.count else { continue }
                for lo in 0...(text.count - wanted.count) where text[lo..<(lo + wanted.count)].elementsEqual(wanted) {
                    let stamp = visible[lo..<(lo + wanted.count)].map { stamps[r][$0] }.max() ?? 0
                    found.append((stamp, r, marker))
                }
            }
        }
        return found
    }

    /// The selected row of a picker, `› 1. Label`: any numbered choice codex is waiting on. The
    /// newest such row when several are on screen.
    private var picker: (stamp: Int, label: String)? {
        var best: (stamp: Int, label: String)?
        for (r, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("› ") else { continue }
            let body = trimmed.dropFirst(2)
            guard let dot = body.firstIndex(of: "."), !body[..<dot].isEmpty, body[..<dot].allSatisfy(\.isNumber) else { continue }
            let label = body[body.index(after: dot)...].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { continue }
            let stamp = (0..<cols).filter { cells[r][$0] != " " && cells[r][$0] != Self.wideTail }
                .map { stamps[r][$0] }.max() ?? 0
            if best == nil || stamp > best!.stamp { best = (stamp, String(label.prefix(60))) }
        }
        return best
    }

    private mutating func csi(_ body: [UInt8], final: UInt8) {
        let prefix: UInt8? = body.first.flatMap { (0x3C...0x3F).contains($0) ? $0 : nil }
        let text = String(decoding: prefix == nil ? body[...] : body.dropFirst(), as: UTF8.self)
        let numbers = text.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        func arg(_ k: Int, _ fallback: Int) -> Int { k < numbers.count && numbers[k] > 0 ? numbers[k] : fallback }
        switch (prefix, final) {
        case (nil, 0x48), (nil, 0x66):                       // CUP
            row = min(arg(0, 1), rows) - 1; col = min(arg(1, 1), cols) - 1; wrapPending = false
        case (nil, 0x4A): eraseDisplay(numbers.first ?? 0)   // ED
        case (nil, 0x4B): eraseLine(numbers.first ?? 0)      // EL
        case (nil, 0x72):                                    // DECSTBM, cursor home
            let t = arg(0, 1), b = arg(1, rows)
            if t < b, b <= rows { top = t - 1; bottom = b - 1 }
            row = 0; col = 0; wrapPending = false
        case (nil, 0x6D), (0x3E, 0x6D): break                // SGR; XTMODKEYS `>4;0m`
        case (nil, 0x6E), (nil, 0x63): break                 // DSR `6n`; DA `c`
        case (nil, 0x71) where text.hasSuffix(" "): break    // DECSCUSR `n SP q`
        case (0x3E, 0x75), (0x3F, 0x75): break               // kitty keyboard `>5u`, `?u`
        case (0x3F, 0x68) where text == "1049":              // alternate screen: a blank grid
            erase(rows: 0..<rows)
            row = 0; col = 0; top = 0; bottom = rows - 1; wrapPending = false; unreliable = false
        case (0x3F, 0x68), (0x3F, 0x6C):
            if !["25", "1004", "1007", "2004", "2026"].contains(text) { unreliable = true }
        default: unreliable = true
        }
    }

    private mutating func eraseDisplay(_ mode: Int) {
        switch mode {
        case 0:
            if row == 0, col == 0 { unreliable = false }
            erase(row: row, cols: col..<cols)
            if row + 1 < rows { erase(rows: (row + 1)..<rows, stamp: clock) }
        case 1:
            erase(rows: 0..<row)
            erase(row: row, cols: 0..<min(col + 1, cols), stamp: clock)
        case 2, 3:
            erase(rows: 0..<rows); unreliable = false
        default: unreliable = true
        }
    }

    private mutating func eraseLine(_ mode: Int) {
        switch mode {
        case 0: erase(row: row, cols: col..<cols)
        case 1: erase(row: row, cols: 0..<min(col + 1, cols))
        case 2: erase(row: row, cols: 0..<cols)
        default: unreliable = true
        }
    }

    /// Blanks cells with one new stamp (or `stamp`, to join the batch just started).
    private mutating func erase(row r: Int, cols range: Range<Int>, stamp: Int? = nil) {
        let stamp = stamp ?? { clock += 1; return clock }()
        for c in range { cells[r][c] = " "; stamps[r][c] = stamp }
    }

    private mutating func erase(rows range: Range<Int>, stamp: Int? = nil) {
        let stamp = stamp ?? { clock += 1; return clock }()
        for r in range { erase(row: r, cols: 0..<cols, stamp: stamp) }
    }

    private mutating func put(_ scalar: Unicode.Scalar) {
        let measured = Self.columnWidth(scalar)
        if measured == 0 { return }                       // combining mark: not modelled
        let width = measured == 2 ? 2 : 1
        if wrapPending || col + width > cols { col = 0; lineFeed(); wrapPending = false }
        clock += 1
        if cells[row][col] == Self.wideTail, col > 0 { cells[row][col - 1] = " " }   // split a wide pair
        if col + 1 < cols, cells[row][col + 1] == Self.wideTail, width == 1 { cells[row][col + 1] = " " }
        cells[row][col] = Character(scalar); stamps[row][col] = clock
        if width == 2, col + 1 < cols { cells[row][col + 1] = Self.wideTail; stamps[row][col + 1] = clock }
        col += width
        if col >= cols { col = cols - 1; wrapPending = true }
    }

    private mutating func lineFeed() {
        if row == bottom { scroll(removing: top, inserting: bottom) } else if row < rows - 1 { row += 1 }
    }

    private mutating func reverseIndex() {
        if row == top { scroll(removing: bottom, inserting: top) } else if row > 0 { row -= 1 }
    }

    /// Scrolls the region one row: removes one edge row and inserts a blank one at the other.
    private mutating func scroll(removing gone: Int, inserting blank: Int) {
        cells.remove(at: gone); stamps.remove(at: gone)
        cells.insert(Array(repeating: " ", count: cols), at: blank)
        stamps.insert(Array(repeating: 0, count: cols), at: blank)
    }
}

/// The wait a launch that has not reached its prompt by `threshold` stands in, or nil.
func codexStartupStall(screen: CodexStartupScreen, launchedAt: Date, bindingLanded: Bool,
                       now: Date, threshold: TimeInterval = codexStartupStallThreshold)
    -> (since: Date, title: String?)? {
    guard !screen.reachedPrompt, !bindingLanded, now.timeIntervalSince(launchedAt) >= threshold else { return nil }
    return (launchedAt, screen.title)
}

/// What the state file carries for one tick: nil once the launch reached its prompt or bound a session.
func codexStartupScreenRecord(_ screen: CodexStartupScreen, stall: (since: Date, title: String?)?)
    -> CodexStartupScreenRecord? {
    guard let stall else { return nil }
    let lines = screen.menuLines
    return CodexStartupScreenRecord(title: stall.title, lines: lines,
                                    screenID: lines.map(CodexStartupScreen.screenID), since: stall.since)
}
